---
name: dsh-web-doctor
description: >-
  dsh web 挂了/A/B 双槽都起不来时的 out-of-band 医生：不依赖 web 进程，纯终端一键诊断
  （web 健康、launcher 链、扩展 relink、槽可启动性、session 存储、web.log、最近会话最后发生的事）
  → 确定性自动修复（relink 自愈、bin/dsh 补位、未知事件 ignorable、损坏日志修复）→ 把 web 拉回来并验证；
  或 --agent 模式交给 headless LLM agent（读报告+日志推理根因、自适应修复、验证），应对 DSH 改版与新故障模式。
  当用户说"web 挂了怎么查"、"dsh web 起不来"、"3080 挂了"、"怎么自愈"、"跑一下 doctor"、
  "看看系统为什么挂了"时使用，即使 GUI/agent 都不可用（在终端跑 dsh-doctor（或 bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh））。
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

## 用法（用户角度：一条短命令）

装好（`install.sh`）后，`dsh-doctor` 就在 PATH 上（`~/.local/bin/dsh-doctor`），**web 挂的时候
直接在终端敲**：

```sh
dsh-doctor                    # 只诊断（只读，秒级）
dsh-doctor --fix              # 诊断 + 确定性自动修复（保底，不依赖 LLM）
dsh-doctor --fix --restart    # 诊断 + 修复 + 拉起 web（救火一条龙）
dsh-doctor --agent            # LLM 主脑：体检 → 交给 headless LLM agent 找根因/修复/拉回
```

底层脚本在 `~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh`（也可直接 `bash` 它），
源码在 dsh-harness-ops 仓库 `skills/dsh-web-doctor/`。

| Flag | 作用 |
|---|---|
| （无） | 只读诊断，报告问题清单（exit 0 全好 / exit 1 有问题） |
| `--fix` | 确定性自动修复：relink 自愈 → bin/dsh 补位 → 会话未知事件 ignorable → 损坏日志修复 → **verify 重查**（不依赖 LLM） |
| `--restart` | 修复后拉起 web（kill 旧 + nohup 重启 + 轮询 HTTP 200）；web 已 200 则跳过 |
| `--agent` | **LLM 主脑**：体检报告 tee 到 `/tmp/dsh-doctor-report.txt` → `dsh --profile headless` 起 one-shot LLM agent（内置自愈 prompt）→ 读报告+日志推理根因 → 用确定性原语（或直接命令）修复 → 验证 200 → 输出结论 |

## 分层：确定性是"手和眼"，LLM 是"大脑"

| 层 | 什么 | 为什么需要 |
|---|---|---|
| **L0/L1 确定性**（`--fix`） | 检查原语（curl/readlink/文件存在性/zstd+JSONL）+ 修复原语（ln -sfn/写包装器/restart） | 秒级、零 LLM 成本、web 挂得再彻底也能跑；给 LLM 提供**可靠的事实和可执行动作** |
| **LLM 主脑**（`--agent`） | headless one-shot agent：读报告/session 尾部/web.log → 推理根因 → 决策修复 → 验证 | **适应未知与新版本**：DSH 改版、新故障模式，确定性规则想不到——LLM 读新症状自己推理（实测：它识别出 web.log 的 `node: not found` 是 8/10 历史残留而非当前故障） |

**为什么不能只有确定性**：写死的规则（产物路径、错误形态、配置格式）会随 DSH 改版失效
（0811 就删过 `bin/dsh`）；新故障模式规则想不到。
**为什么不能只有 LLM**：web 挂时 agent 起不来（headless 也依赖 harness 本身）；让 LLM 扫 92 个
session 太慢太贵；修复需要不变的操作原语。**确定性传感器 + LLM 大脑是正解。**

## 诊断项（doctor 查什么）

1. **web 健康**：`:3080` HTTP 状态。
2. **launcher 链**：`command -v dsh` → 解析（接受 `current/...` 符号路径）。
3. **扩展 relink**：ab-config 里每个 `extensions[].relink` 是否存在（缺失 = 未来 `dsh web`
   必挂，正是 2026-08-11 事故）。
4. **槽可启动**：current 有 `bin/dsh` 或编译产物 `apps/cli/lib/bin.js`。
5. **session 存储（L0 文件层）**：`session-store-check.mjs` 逐日志校验可解压、header 正确、
   尾部合法 JSON——**只用 node 标准库 + zstd CLI，不加载任何 DSH 编译包**。
6. **web.log 尾部**：最近启动失败的直接证据。
7. **最近会话"最后发生的事"**：`session-last-activity.mjs` 列最近活跃会话的最后事件
   （类型/seq/时间/内容提示）——"挂了之前系统在做什么"。

## 依赖分层（极小依赖设计）

doctor 是**最后一道防线**，它自己不能依赖"可能已经被弄坏的东西"（current 槽的编译产物、
扩展 bundle）。分两层：

| 层 | 依赖 | 覆盖 | 失败影响 |
|---|---|---|---|
| **L0（自包含）** | 系统工具（node 内置/zstd CLI/jq/curl/ps/lsof）+ 纯文件操作 | 布局快照、web 健康、launcher 链、relink 存在性、槽可启动、**session 文件层检查**、最近活动、relink/launcher 修复、**内置 restart 兜底** | **永不因自身依赖失败**——即使 current 槽的编译产物整个没了也能跑 |
| **L1（深度，可降级）** | current 槽编译产物（`@deepseek-ai/dsh-session-persistence-jsonl` 等） | `check-all-sessions` 全量读取校验、`repair-unknown-events` ignorable 修复 | 加载失败 → 明确报告"deep check unavailable（current slot 可能坏了）"，L0 结论仍权威，doctor 继续 |

**设计契约**：doctor 的 L0 路径**绝不 import 任何 `@deepseek-ai/*` 编译包、绝不加载扩展插件**。
L1 只是增强，加载不了就降级——救火工具必须在自己要修的故障里也活着。

## 自愈 prompt（web 恢复后 / 给其它 agent）

`dsh-doctor --agent` 已内置完整自愈 prompt 并自动调 headless LLM。以下文本用于**没有
headless**（或想手动把上下文交给 web 恢复后的会话）时：

```text
dsh web 之前挂了，已跑 dsh-doctor 自愈。请：
1. 看 doctor 报告：dsh-doctor（或 /tmp/dsh-doctor-report.txt）
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
