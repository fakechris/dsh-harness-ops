---
name: dsh-web-doctor
description: >-
  dsh web 挂了/A/B 双槽都起不来时的 out-of-band 医生：不依赖 web 进程，纯终端一键诊断
  （web 健康、launcher 链、扩展 relink、**任意插件的依赖完整性**、槽可启动性、session 存储、web.log、最近会话最后发生的事）
  → 确定性自动修复（relink 自愈、**任意插件依赖自愈**、bin/dsh 补位、未知事件 ignorable、损坏日志修复）→ 把 web 拉回来并验证；
  或 --agent 模式交给 headless LLM agent（读报告+日志推理根因、自适应修复、验证），应对 DSH 改版与新故障模式；
  或 --guide mini TUI（全屏交互终端：诊断流式输出 → 自动修复 → LLM 自动运行，CoT/prompt 用
  markdown 渲染，随时 Ctrl-C 打断并输入指引），适合"不放心无人长跑"的场景。
  当用户说"web 挂了怎么查"、"dsh web 起不来"、"3080 挂了"、"怎么自愈"、"跑一下 doctor"、
  "看看系统为什么挂了"时使用，即使 GUI/agent 都不可用（终端跑 dsh-doctor，无参数即交互菜单：体检/机械修复/LLM 自愈/引导模式+拉起）。
  English: out-of-band doctor for dsh web when it is down or won't boot (both A/B slots
  broken, GUI/agent unavailable). One terminal command diagnoses (web health, launcher
  chain, extension relinks, slot bootability, session store, web.log, last activity in
  recent sessions), auto-fixes known issues (relink self-heal, slot launcher, unknown
  session-event ignorable marking, corrupt-log repair), then relaunches web and verifies
  HTTP 200. A --guide mini-TUI (full-screen curses: streaming diagnosis, auto-fix, autonomous
  LLM with markdown-rendered CoT, interrupt-and-steer via Ctrl-C). Use when the user reports
  web down,
  dsh web failing to boot, 3080 not responding, or asks for a doctor/self-heal run.
---

# dsh web Doctor（out-of-band 自愈）

当 **web（3080）挂了或起不来**——包括 A/B 双槽都坏、GUI/agent 都不可用的最坏情况——用本
skill。它是 **out-of-band** 的：只靠终端 + 本机工具（node/zstd/jq/curl/ps/lsof）和已安装
skills 的脚本，**不依赖任何 web 进程**。

诞生背景（2026-08-11）：切换事故 + 扩展链接消失事故的现场修复（查 session → 找根因 →
修 relink/会话 → 拉起 web）每一步都能脚本化，但缺一个不依赖 web 的一键入口——浪费了数小时
人工。本 skill 把它自动化。

教训（2026-08-13）：`--agent` 有一次**无人值守跑满 300s 超时**——被一个误报的插件依赖
（子路径导入被当成 MISSING）和一个误导性的 "deep check unavailable（槽可能坏了）" 提示带偏，
什么都没修成。结论：**没有人 guide 的 doctor 长任务不靠谱** → 新增 **mini TUI 引导模式**
（`--guide` / 菜单 5），LLM 自动判断修复、用户看 CoT 随时打断；同时修掉那两个误导源
（plugin-deps-check 按 exports map 解析子路径、deep-check 失败显示真实报错而不是断言槽坏了）。

## 何时用

- `dsh web` 起不来 / 3080 无响应 / 白屏。
- A/B 槽切换后 web 没起来（cutover 成功但 restart 失败）。
- 报错形如：`ERR_MODULE_NOT_FOUND: @deepseek-ai/...`（扩展 relink 缺失）、
  `dsh: command not found`（launcher 链断）、`SessionFormatUnsupportedError ... unknown ...
  not marked ignorable`（会话未知事件）、`corrupt Zstandard session log`。
- 用户问"系统为什么挂了 / 怎么自愈 / 跑一下 doctor"。
- **web 挂时 agent 也不可用**（agent 由 web 托管）——直接让用户在终端跑 doctor.sh，或把
  本 skill 的自愈 prompt 粘给任何可用的 agent。

## 用法（用户角度：一条短命令，无参数即交互菜单）

**入口（两个都行，挑顺手的）**：

```sh
dsh-doctor                          # ① PATH 命令（装好后 ~/.local/bin/dsh-doctor，与 dsh 同目录）
~/.dsh/source/current/bin/dsh-doctor # ② 槽 bin 内（prepare 后自动保留）
```

**web 挂的时候直接敲 `dsh-doctor`（不带任何路径），不用记参数**——它会显示双语菜单
（**默认英文**，菜单里选 `6` 切换中英文；或用环境变量 `DSH_DOCTOR_LANG=zh` 固定中文）：

```
=============================================================
  dsh web Doctor — one-shot rescue        // dsh web 医生 — 一键救火
  web(:3080): ✅ healthy                  // 当前 web: ✅ 正常
=============================================================
  1) Quick check (diagnose only)          // 快速体检（只读）
  2) Fix config issues (mechanical)      // 修复配置问题（机械，不依赖 LLM）：
     incl. relaunch web                  //   relink/插件依赖/launcher/session/
                                          //   LLM 凭据等已知配置故障
  3) LLM repair (recommended)            // LLM 修复（推荐）：LLM 读诊断+日志
                                          //   推理根因，发现/修复任意插件问题
  4) Deep LLM check & repair (always)   // LLM 深度检测和修复（每次都跑，
                                          //   不因诊断全绿而跳过）
  5) Mini TUI (guided)                   // 全屏交互终端：自动修复 + LLM
                                          //   对话（看完整 CoT，随时打断指引）
  6) Switch language 中文                 // 切换语言
  7) Exit                                 // 退出
  choose [1-7]:
```

- 不确定选什么 → **选 3**（大模型自动修复，推荐——能发现/修复任意插件问题）
- 想先看看情况 → **选 1**；web 起不来且没 LLM → **选 2**（机械修复配置问题）
- **不放心无人长跑 / 上次 --agent 被带偏过** → **选 5**（mini TUI：全屏交互，随时打断和 LLM 对话）
- **要 LLM 深度检测和修复**（不因诊断全绿跳过，LLM 独立交叉验证每一项）→ **选 4**，或命令行 `dsh-doctor --agent --force`
- 诊断全绿时 `--fix` 会**跳过修复**（"no problems — skipping repair"），不做无意义操作；`--agent` 同理，除非 `--force`
- 菜单每次跑完回到菜单，按 `7` 退出（Exit 永远在最后）

## LLM 配置修复（检查什么 / 处理什么 / 工作流）

**目标**：LLM 凭据/配置坏了，doctor 要**帮你配起来**，不是只提示。

**检查（凭据链 = 进程环境 → cwd/.env → `~/.dsh/.env`）**：
1. `~/.dsh/.env` 是否存在
2. `DEEPSEEK_API_KEY` 是否非空（**不打印 key**）
3. `~/.dsh/settings.yaml` 是否存在、非空（空/损坏会拖垮 web 启动）

**处理（`--fix` / 菜单 2 自动做）**：
1. **key 缺失/为空 + 交互终端** → 提示粘贴 key（`read -s` 隐藏输入）→ 备份旧 `.env`
   → 写入/去重 `DEEPSEEK_API_KEY` → `chmod 600` → 完成配置
2. **key 缺失 + 非交互**（脚本/管道）→ 打印精确命令：`echo 'DEEPSEEK_API_KEY=<key>' >> ~/.dsh/.env`
3. **settings.yaml 空/损坏** → 备份（`.bak-时间戳`）→ 重置为最小 `{}`（临时修复，先让 web 起来）
4. **key 已存在** → 权限归一化 600

**工作流**：诊断（3i）发现缺失 → `--fix` 进入 repair → 交互输入或命令提示 → 写入+权限 →
（`--agent` 跑 headless 即真实验证 LLM 通）→ 重启 web 生效。

**边界（诚实）**：key 是**用户自己的秘密**，doctor 引导输入并代为配置，**绝不臆造/猜测 key**；
配置**格式/权限**类损坏 doctor 能自动修（备份+重置+权限），**key 失效/欠费**等外部原因只能
提示。

**参数模式**（脚本/自动化/高级用，等价于菜单项；普通用户不需要）：

```sh
dsh-doctor                    # 交互菜单（终端下）；脚本/管道下 = 只读诊断
dsh-doctor --guide            # mini TUI：诊断流式 → 自动修复 → LLM 自动运行（看 CoT，随时打断）
dsh-doctor --agent            # = 菜单 3（LLM 主脑；全绿时自动跳过）
dsh-doctor --agent --force    # = 菜单 4（LLM 深度检测和修复，全绿也跑）
dsh-doctor --fix --restart    # = 菜单 2（确定性修复 + 拉起）
dsh-doctor --fix              # 只确定性修复，不拉起
dsh-doctor --quiet            # 少输出
```

底层脚本在 `~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh`（也可直接 `bash` 它），
源码在 dsh-harness-ops 仓库 `skills/dsh-web-doctor/`。

| Flag | 作用 |
|---|---|
| （无） | 交互菜单（终端）；管道/脚本下退化为只读诊断 |
| `--guide` | **mini TUI（真正的全屏 TUI）**：python3+curses（stdlib，无第三方依赖），终端有 TTY 时自动启用；无 TTY/无 curses 回退为非交互逐步模式。**流程**：诊断先在普通终端流式输出（不黑屏）→ 进 TUI 后已知问题**确定性自动修复**（无逐项确认）→ **LLM 自动运行**（0 问题 = 只读自动验收 "✅ 验收通过"；残留问题 = 自动诊断修复；只有 LLM 无法判断时才问用户）。布局 = 顶栏状态（web/槽/阶段/agent 状态）+ 中部滚动主区（CoT/prompt/终答 **markdown 渲染**：标题/粗体/行内代码/代码块/列表/引用，工具调用 `[tool]` 行）+ 底部输入条。**交互 = 看 CoT + 随时打断**：Ctrl-C 打断运行中的 agent → 输入指引回车续聊（上下文 `/tmp/dsh-doctor-chat.txt` 跨轮携带）；PgUp/PgDn/Home/End 滚动，Ctrl-L 清屏，`/help` `/quit`。超时 `DSH_DOCTOR_AGENT_TIMEOUT`（默认 300s） |
| `--agent` | **LLM 主脑**：体检报告 tee 到 `/tmp/dsh-doctor-report.txt` → `dsh --profile headless` 起 one-shot LLM agent（内置自愈 prompt，含 2026-08-13 纪律：不把环境性噪音当槽坏了、连续 3-4 步无进展就停下报告）→ **实时显示 agent 的活动**（tail 它自己的 session 日志：推理/工具调用/生成）→ 读报告+日志推理根因 → 修复 → 验证 200 → 输出结论。健康时自动跳过（不烧 token）；`DSH_DOCTOR_AGENT_TIMEOUT` 可调超时（默认 300s），超时提示回退 `--fix`；Ctrl-C 会同时杀掉 agent |
| `--fix` | 确定性自动修复：relink 自愈 → **任意插件依赖自愈**（plugin-deps-check）→ bin/dsh 补位 → 会话未知事件 ignorable → 损坏日志修复 → **LLM 凭据检测**（权限归一化；key 缺失则明确提示补，不臆造）→ **verify 重查**（不依赖 LLM） |
| `--restart` | 修复后拉起 web（kill 旧 + nohup 重启 + 轮询 HTTP 200）；web 已 200 则跳过 |

## 分层：确定性是"手和眼"，LLM 是"大脑"

| 层 | 什么 | 为什么需要 |
|---|---|---|
| **L0/L1 确定性**（`--fix`） | 检查原语（curl/readlink/文件存在性/zstd+JSONL）+ 修复原语（ln -sfn/写包装器/restart） | 秒级、零 LLM 成本、web 挂得再彻底也能跑；给 LLM 提供**可靠的事实和可执行动作** |
| **LLM 主脑**（`--agent`） | headless one-shot agent：读报告/session 尾部/web.log → 推理根因 → 决策修复 → 验证 | **适应未知与新版本**：DSH 改版、新故障模式，确定性规则想不到——LLM 读新症状自己推理（实测：它识别出 web.log 的 `node: not found` 是 8/10 历史残留而非当前故障） |

**为什么不能只有确定性**：写死的规则（产物路径、错误形态、配置格式）会随 DSH 改版失效
（0811 就删过 `bin/dsh`）；新故障模式规则想不到。
**为什么不能只有 LLM**：web 挂时 agent 起不来（headless 也依赖 harness 本身）；让 LLM 逐个扫
所有 session 太慢太贵；修复需要不变的操作原语。**确定性传感器 + LLM 大脑是正解。**

### mini TUI 引导模式（`--guide` / 菜单 5，2026-08-13 教训）

**背景**：0813 一次 `--agent` 无人值守长跑失败——被误报带偏、超时杀进程、什么都没修成。
**原则**：**没有人 guide 的 doctor 长任务不靠谱** → 默认不做无人长跑。

**它是真正的 TUI**（不是菜单，也不是"每步确认"）：`dsh-doctor --guide` 先让**诊断在普通终端
流式输出**（看得见进度，绝不黑屏），然后把结果交给 python3+curses 全屏界面（stdlib only，
无 pip 依赖；无 TTY 时回退逐步模式）：

```
┌ doctor-tui | web:200 | phase:llm | agent:running | current:slot-b | PgUp/Dn=scroll ┐
│ ── 自动运行：LLM 自愈/验收（CoT 实时渲染）──                                            │
│ 让我理解当前任务：1. 我是 dsh web 的 out-of-band 自愈 agent …（CoT 流式 markdown）      │
│ [tool] skill {"name":"dsh-web-doctor"}                                                │
│ **健康。** web（:3080 返回 200）、扩展 relink 全部完好…（终答 markdown 渲染）           │
└ you → agent (Enter=send ^C=interrupt /help) > _                                      ┘
```

**分工（2026-08-13 第 3 次修正）**：**LLM 自动判断、自动修复**——用户不逐项确认。
- 已知问题 → **确定性自动修复**（`doctor.sh --fix`，可逆带备份，无逐项确认）
- 0 问题 → **LLM 自动只读交叉验证**，输出"✅ 验收通过"+证据清单
- 有残留问题 → **LLM 自动诊断根因并修复**（优先复用确定性原语）
- **只有 LLM 真正无法判断/需要用户决策时才问**（如缺 API key、不确定删除/改动）
- **交互的意义 = 让用户看清完整 CoT**：全屏实时渲染推理/工具调用/终答（markdown），
  用户随时 **Ctrl-C 打断并输入指引**，agent 按指引继续；PgUp/PgDn 滚动回看。

上下文文件 `/tmp/dsh-doctor-chat.txt` 跨轮携带（每会话重置）；`DSH_DOCTOR_AGENT_TIMEOUT`
（默认 300s）兜底。界面提示**双语**（主语言在前，`DSH_DOCTOR_LANG=en|zh` 默认 en，会话内 `/lang` 切换；菜单语言切换后进 TUI 自动继承）。任何修复可逆；`q`/`/quit`/空闲 Ctrl-C 退出。

## 诊断项（doctor 查什么）

1. **web 健康**：`:3080` HTTP 状态。
2. **launcher 链**：`command -v dsh` → 解析（接受 `current/...` 符号路径）。
3. **扩展 relink**：ab-config 里每个 `extensions[].relink` 是否存在（缺失 = 未来 `dsh web`
   必挂，正是 2026-08-11 事故）。
4. **槽可启动**：current 有 `bin/dsh` 或编译产物 `apps/cli/lib/bin.js`。
5. **session 存储（L0 文件层）**：`session-store-check.mjs` 逐日志校验可解压、header 正确、
   尾部合法 JSON——**只用 node 标准库 + zstd CLI，不加载任何 DSH 编译包**。
6. **web.log 尾部 + boot 失败提示**：`tail` 最近失败 + 自动提取 `Cannot find package` /
   `failed to import loader entry` / `plugin tree failed to load` 关键错误（插件类故障的直接线索）。
7. **profile bundles 依赖检查（任何插件）**：`plugin-deps-check.mjs` 读 web profile 的
   `dependencies`（out-of-tree bundles），扫描每个插件 `lib/` 产物的 `@deepseek-ai/*` /
   `cordis` import vs 其 node_modules——**不依赖 ab-config**，未来装的任何插件（dsh-loop、
   dsh-kb-sieve…）缺失依赖都会被抓住；缺失时自动从 current 槽 packages 按包名找修复来源
   （`FIXABLE`）或报告无来源（`MISSING`）。**子路径导入按包名 + exports map 解析**
   （0813 修：`@deepseek-ai/dsh-x/client` 这类子路径由包自身 exports 提供，不是
   node_modules 下的独立条目——旧版把健康的 client-runtime 误报成 MISSING，带偏过 LLM）。
8. **LLM 配置健康**：凭据读取链 = 进程环境 → cwd/.env → `~/.dsh/.env`（`DEEPSEEK_API_KEY`）。
   doctor 检查 `.env` 存在、key 非空（**不打印 key 本身**）——web 和 headless 都依赖它。
9. **最近会话"最后发生的事"**：`session-last-activity.mjs` 列最近活跃会话的最后事件
   （类型/seq/时间/内容提示）——"挂了之前系统在做什么"。

## 依赖分层（极小依赖设计）

doctor 是**最后一道防线**，它自己不能依赖"可能已经被弄坏的东西"（current 槽的编译产物、
扩展 bundle）。分两层：

| 层 | 依赖 | 覆盖 | 失败影响 |
|---|---|---|---|
| **L0（自包含）** | 系统工具（node 内置/zstd CLI/jq/curl/ps/lsof）+ 纯文件操作 | 布局快照、web 健康、launcher 链、relink 存在性、槽可启动、**session 文件层检查**、最近活动、relink/launcher 修复、**内置 restart 兜底** | **永不因自身依赖失败**——即使 current 槽的编译产物整个没了也能跑 |
| **L1（深度，可降级）** | current 槽编译产物（`@deepseek-ai/dsh-session-persistence-jsonl` 等） | `check-all-sessions` 全量读取校验、`repair-unknown-events` ignorable 修复 | 加载失败 → 报告**真实报错** + "这是增强检查，文件层结论仍权威，且失败通常是环境噪音而非槽坏了"（0813 起不再断言"槽可能坏了"），L0 结论仍权威，doctor 继续 |

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
