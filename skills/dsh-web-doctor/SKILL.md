---
name: dsh-web-doctor
description: >-
  dsh web 挂了/A/B 双槽都起不来时的 out-of-band 医生：不依赖 web 进程，纯终端一键诊断
  （web 健康、launcher 链、扩展 relink、槽可启动性、session 存储、web.log、最近会话最后发生的事）
  → 自动修复（relink 自愈、bin/dsh 补位、未知事件 ignorable、损坏日志修复）→ 把 web 拉回来并验证。
  当用户说"web 挂了怎么查"、"dsh web 起不来"、"3080 挂了"、"怎么自愈"、"跑一下 doctor"、
  "看看系统为什么挂了"时使用，即使 GUI/agent 都不可用（在终端跑 scripts/doctor.sh）。
  English: out-of-band doctor for dsh web when it is down or won't boot (both A/B slots
  broken, GUI/agent unavailable). One terminal command diagnoses (web health, launcher
  chain, extension relinks, slot bootability, session store, web.log, last activity in
  recent sessions), auto-fixes known issues (relink self-heal, slot launcher, unknown
  session-event ignorable marking, corrupt-log repair), then relaunches web and verifies
  HTTP 200. Use when the user reports web down, dsh web failing to boot, 3080 not
  responding, or asks for a doctor/self-heal run.
---

# dsh web Doctor（out-of-band 自愈）

当 **web（3080）挂了或起不来**——包括 A/B 双槽都坏、GUI/agent 都不可用的最坏情况——用本
skill。它是 **out-of-band** 的：只靠终端 + 本机工具（node/zstd/jq/curl/ps/lsof）和已安装
skills 的脚本，**不依赖任何 web 进程**。

诞生背景（2026-08-11）：切换事故 + 扩展链接消失事故的现场修复（查 session → 找根因 →
修 relink/会话 → 拉起 web）每一步都能脚本化，但缺一个不依赖 web 的一键入口——浪费了数小时
人工。本 skill 把它自动化。

## 何时用

- `dsh web` 起不来 / 3080 无响应 / 白屏。
- A/B 槽切换后 web 没起来（cutover 成功但 restart 失败）。
- 报错形如：`ERR_MODULE_NOT_FOUND: @deepseek-ai/...`（扩展 relink 缺失）、
  `dsh: command not found`（launcher 链断）、`SessionFormatUnsupportedError ... unknown ...
  not marked ignorable`（会话未知事件）、`corrupt Zstandard session log`。
- 用户问"系统为什么挂了 / 怎么自愈 / 跑一下 doctor"。
- **web 挂时 agent 也不可用**（agent 由 web 托管）——直接让用户在终端跑 doctor.sh，或把
  本 skill 的自愈 prompt 粘给任何可用的 agent。

## 用法

```sh
bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh             # 只诊断（只读）
bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh --fix       # 诊断 + 自动修复
bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh --fix --restart  # 诊断 + 修复 + 拉起 web
```

| Flag | 作用 |
|---|---|
| （无） | 只读诊断，报告问题清单（exit 0 全好 / exit 1 有问题） |
| `--fix` | 自动修复：relink 自愈 → bin/dsh 补位 → 会话未知事件 ignorable → 损坏日志修复 → **verify 重查** |
| `--restart` | 修复后拉起 web（kill 旧 + nohup 重启 + 轮询 HTTP 200）；web 已 200 则跳过 |

## 诊断项（doctor 查什么）

1. **web 健康**：`:3080` HTTP 状态。
2. **launcher 链**：`command -v dsh` → 解析（接受 `current/...` 符号路径）。
3. **扩展 relink**：ab-config 里每个 `extensions[].relink` 是否存在（缺失 = 未来 `dsh web`
   必挂，正是 2026-08-11 事故）。
4. **槽可启动**：current 有 `bin/dsh` 或编译产物 `apps/cli/lib/bin.js`。
5. **session 存储**：全量 `check-all-sessions.mjs`（92 会话示例：全过）。
6. **web.log 尾部**：最近启动失败的直接证据。
7. **最近会话"最后发生的事"**：`session-last-activity.mjs` 列最近活跃会话的最后事件
   （类型/seq/时间/内容提示）——"挂了之前系统在做什么"。

## 自愈 prompt（web 恢复后 / 给其它 agent）

用户（或任何可用 agent）把下面这段粘给恢复后的会话，即可接续排查：

```text
dsh web 之前挂了，已跑 doctor.sh 自愈。请：
1. 看 doctor 报告：bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh
2. 若还有残留问题：读 ~/.dsh/skills/dsh-session-recovery/SKILL.md（会话问题）和
   ~/.dsh/skills/dsh-snapshot-ab/SKILL.md（A/B 切换问题）
3. 用 session-last-activity 看挂之前的最后操作，定位人为/外部原因
4. 修完验证：curl http://127.0.0.1:3080/ 应 200，ab.sh status 应正常
```

## 边界与安全

- **只读诊断**永远安全；`--fix` 的每步都是可逆/有备份的（relink 重建、launcher 补位、
  ignorable 标记——修复脚本自身做备份 + 校验 + 可回滚交换）。
- doctor **不碰** web 进程内部的会话数据；重启走 `dsh-session-recovery/restart-dsh-web.sh`
  （kill + nohup + 轮询）。
- 依赖的脚本：`dsh-snapshot-ab`（ab.sh status 触发 relink 自愈）、`dsh-session-recovery`
  （check-all-sessions / repair-unknown-events / repair-session-log / restart-dsh-web）。
  这些 skill 需已安装（`dsh-harness-ops` 仓库 `scripts/install.sh`）。

## 参考

- 事故复盘：`dsh-snapshot-ab/references/postmortem-ab-switch-20260811.md`
- 会话修复：`dsh-session-recovery/SKILL.md`
- A/B 轮换：`dsh-snapshot-ab/SKILL.md`
