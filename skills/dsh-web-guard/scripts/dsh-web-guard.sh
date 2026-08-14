#!/bin/bash
# dsh-web-guard — 常驻守护：检测 dsh web 端口无监听时，用完整环境自动拉起。
#
# 这是"agent 自杀式重启"问题的正解：agent 运行在 dsh web 进程内，
# kill 掉 3080 = 杀掉自己，无法自救。守护由系统服务管理器（launchd /
# systemd）托管，与 agent 进程树完全无关，任何 kill/崩溃/重启机器都能
# 自动恢复，无需人工干预。
#
# 关键设计（每条都踩过坑，勿改）：
#  1. 显式 export PATH —— launchd/systemd 环境 PATH 极简，没有 node（nvm）
#     和 dsh（~/.local/bin）。缺了就是 "exec: node: not found"。
#  2. 全绝对路径 —— 脚本可能在任何 cwd 下被拉起。
#  3. nohup + & + </dev/null —— 新 web 进程彻底脱离守护的会话，
#     守护退出不影响它；stdout/stderr 全重定向避免管道等待。
#  4. 常驻 while 循环 —— 守护本身不死，web 死了拉 web；
#     系统服务管理器的 KeepAlive 管守护（守护崩溃才拉起守护），
#     不会形成"web 起不来→管理器反复拉起"的循环。
#  5. 端口空闲才拉起 —— 有监听就不动（与 ab.sh switch 等协调，
#     不会抢/杀对方拉起的进程）。
#  6. 空闲判定用 `-sTCP:LISTEN`（2026-08-14 踩坑）：`lsof -ti :PORT` 会匹配
#     浏览器侧的连接（远端端口 = PORT），web 死后浏览器还挂着页面/websocket
#     重连时，端口永远"看起来被占用"，守护 20 分钟不拉起。只看监听态 socket
#     才能正确判断"web 真的死了"。
#
# 环境变量：
#   DGW_PORT  要守护的端口（默认 3080）
#   DGW_LOG   日志文件（默认 /tmp/dsh-web-guard.log）
#   DGW_DSH   dsh launcher 绝对路径（默认自动解析）
#   DGW_WS    启动 web 的工作目录（默认 ~/source/dsh/explorer）
set -u

# ── 1. 完整环境（踩坑点 1）───────────────────────────────────────────────
# node 在 nvm 下可能有多个版本；dsh launcher 用 `node --import`（需 node≥20），
# 必须把**最新版本**的 bin 排在 PATH 最前（sort -Vr：v22 > v16）。
# 找不到 node 就报错退出（宁可不拉起也不要半残环境）。
NODE_DIRS=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -Vr | tr '\n' ':')
export PATH="${NODE_DIRS}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-/Users/chris}"
export DSH_TELEMETRY_DISABLED=1

PORT="${DGW_PORT:-3080}"
LOG="${DGW_LOG:-/tmp/dsh-web-guard.log}"
DSH_BIN="${DGW_DSH:-$HOME/.local/bin/dsh}"
WS="${DGW_WS:-$HOME/source/dsh/explorer}"

# ── 2. 前置校验（踩坑点 2：绝对路径存在才继续）───────────────────────────
if [ ! -x "$DSH_BIN" ]; then
  echo "$(date '+%H:%M:%S') guard: dsh not found at $DSH_BIN — aborting" >> "$LOG"
  exit 1
fi
command -v node >/dev/null 2>&1 || {
  echo "$(date '+%H:%M:%S') guard: node not on PATH (NODE_DIRS=$NODE_DIRS) — aborting" >> "$LOG"
  exit 1
}
[ -d "$WS" ] || { echo "$(date '+%H:%M:%S') guard: workspace $WS missing" >> "$LOG"; WS="$HOME"; }

echo "$(date '+%H:%M:%S') guard up pid=$$ port=$PORT dsh=$DSH_BIN node=$(command -v node)" >> "$LOG"

# ── 3. 常驻循环（踩坑点 3/4/5）───────────────────────────────────────────
while true; do
  # 只认 LISTEN 态 socket（踩坑点 6）：浏览器对 3080 的 ESTABLISHED/重连连接
  # 不算"web 活着"，否则 web 死后守护会被浏览器的连接挡住，永远不拉起。
  if ! lsof -ti :"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "$(date '+%H:%M:%S') port $PORT free — starting dsh web" >> "$LOG"
    ( cd "$WS" && nohup "$DSH_BIN" web --port "$PORT" >> "$LOG" 2>&1 < /dev/null & )
    echo "$(date '+%H:%M:%S')   spawn issued for $PORT" >> "$LOG"
  fi
  sleep "${DGW_INTERVAL:-10}"
done
