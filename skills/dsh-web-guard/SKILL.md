---
name: dsh-web-guard
description: dsh web 自愈守护——agent 运行在 dsh web 进程内，kill 掉 3080 等于杀掉自己，无法自救。本 skill 提供"带外重启"能力：把守护脚本装成系统服务（macOS launchd / Linux systemd），守护与 agent 进程树完全无关，任何 kill/崩溃/重启机器都会在 10 秒内用完整环境自动拉起 dsh web，无需人工干预。当用户说"重启 3080 / web 挂了怎么自动拉起来 / 切换后自己把自己拉起来 / kill 后不用手动启动 / 做重启守护"时使用。
---

# dsh-web-guard — dsh web 自愈守护（带外重启）

## 问题：为什么"重启 3080"会反复失败

agent 运行在 dsh web 进程（3080）**内部**。任何 `kill $(lsof -ti :3080)` 都是在**杀自己的宿主进程**：

1. kill 生效瞬间，agent 的执行环境被破坏 —— 同一条命令里后续的启动命令往往来不及执行（表现为"interrupted"、日志丢失、进程没起来）。
2. 新进程如果挂在 agent 的 shell 下（`dsh web &`），agent 一死它也跟着死 —— 除非脱离进程树。
3. 用 `launchctl submit` 一次性 job 重启有 KeepAlive 循环坑：脚本启动失败（找不到 node/dsh）→ 进程退出 → launchd 又拉起 → 又失败 → **无限循环**，且每次循环会 kill 当前 3080（误杀用户手动起的进程）。

**结论：agent 无法自救。必须有一个与 agent 进程树完全无关的"带外监督者"。**

## 方案：系统服务常驻守护

守护脚本（`scripts/dsh-web-guard.sh`）由系统服务管理器（launchd / systemd）托管，**PPID=1**，与 agent 进程树毫无关系。它每 10 秒检查端口，无监听就用完整环境拉起 dsh web。

```
kill/崩溃/重启机器
      │
      ▼
系统服务管理器（launchd/systemd，PPID=1）── 守护脚本常驻
      │  每 10s 检查端口
      ▼
端口空闲？──是──→ nohup dsh web（完整环境）→ 拉起
      │否
      └── 有监听就不动（与 ab.sh switch 协调）
```

## 关键设计（每条都是踩坑换来的，勿改）

| # | 设计 | 为什么 |
|---|---|---|
| 1 | **显式 export PATH**（含 nvm node + `~/.local/bin`） | launchd/systemd 环境 PATH 极简，没有 node/dsh。缺了就是 `exec: node: not found`（实测踩过 9 次） |
| 2 | **全绝对路径**（`$DSH_BIN`、`$WS`、日志） | 脚本可能在任何 cwd 下被拉起，宿主死后环境可能失效 |
| 3 | **`nohup + & + </dev/null` + 全 fd 重定向** | 新 web 彻底脱离守护会话；stdout/stderr 重定向避免管道等待挂起 |
| 4 | **常驻 `while true` 循环** | 守护本身不死 → 管理器的 KeepAlive 不触发 → 不会循环。web 死了由循环内拉起（10s 间隔） |
| 5 | **端口空闲才拉起** | 有监听就不动 —— 与 ab.sh switch/rollback 协调，不抢不杀对方拉起的进程 |
| 6 | **前置校验**（dsh/node 存在才启动） | 环境不完整时宁可退出（触发 KeepAlive 重试），也不要半残拉起 |

## 安装（scripts/install.sh，跨平台）

```sh
# macOS（launchd）—— 本机实测过
bash scripts/install.sh                     # 装 + 启动
bash scripts/install.sh --port 3080         # 指定端口
bash scripts/install.sh --status            # 看服务状态
bash scripts/install.sh --uninstall         # 卸载

# Linux（systemd user service）—— 已写好，未在 Linux 实测过
bash scripts/install.sh                     # 自动检测 systemd 并安装
```

macOS 生成 `~/Library/LaunchAgents/com.dsh.webguard.plist`（`RunAtLoad` + `KeepAlive` + `ThrottleInterval=10`），Linux 生成 `~/.config/systemd/user/com.dsh.webguard.service`（`Restart=always` + `RestartSec=10`）。

## 验证（安装后必做）

```sh
# 1. 守护起来了？
ps aux | grep dsh-web-guard | grep -v grep      # 应见 PPID=1
launchctl print gui/$(id -u)/com.dsh.webguard   # macOS: state=running

# 2. 核心验证：kill 掉 3080，守护应 10s 内自动拉起（实测通过）
lsof -ti :3080 | xargs kill
sleep 15
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/   # 应 200
tail /tmp/dsh-web-guard.log                     # 应见 "port free — starting"
```

## 与 dsh-snapshot-ab 的关系

- **ab.sh switch/rollback 杀 web 后，守护会自动拉起新 current** —— 切换不再需要手动启动，也不需要 ab.sh 自己 nohup（守护是更可靠的兜底）。
- 如果 ab.sh 自己启动先成功，守护检测到端口已占就不动 —— 两者天然互补，无需改 ab.sh。
- 建议：切到新槽后 `curl :3080` 确认 200，守护日志确认 `spawn issued`。

## 故障排查

| 现象 | 原因 | 修法 |
|---|---|---|
| `exec: node: not found` | PATH 没含 nvm node | 检查 `$HOME/.nvm/versions/node/*/bin` 是否在脚本 NODE_DIRS |
| 无限循环重启 | 用了 `launchctl submit` 一次性 job（有 KeepAlive） | 改用本 skill 的 LaunchAgent plist（KeepAlive 管守护，不管 web） |
| 守护反复杀手动起的 3080 | 脚本 kill 逻辑错误 | 本脚本**从不 kill**，只检查端口后拉起；确认用的是本脚本 |
| 日志在 `/tmp/dsh-web-guard.log` | 守护自身的日志 | web 进程日志追加在同一文件（`>>`），可一并排查 |

## 已知限制

- **Linux systemd 未实测**：脚本逻辑已按 systemd user unit 写好（Type=simple + Restart=always），但本机是 macOS，`install_systemd` 分支未验证。装到 Linux 后先跑 `--status` 确认。
- `lsof` 在 Linux 可用（部分发行版需 `lsof` 包）；若没有，可换 `ss -ltn`（脚本里已留扩展点）。
- 守护只负责"端口无监听就拉起"，**不负责**健康检查（HTTP 200 但进程假死时不会主动重启）—— 这是有意的：避免误杀运行中的 web。
