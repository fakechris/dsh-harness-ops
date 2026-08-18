# dsh-harness-ops — DeepSeek Harness 运维工具箱（自愈 + 版本轮换）
[English](README.en.md) | 中文


> **升级、重启、故障——都变成"不用操心"的事**。给 DSH 用户 / 插件开发者 / 部署运维者。
>
> **① 官方每天发新快照，升级怎么不翻车？** A/B 双槽轮换：新快照进隔离槽，旧插件自动迁移、
> 构建 + 扩展测试 + web 冒烟全过才原子切换；任何一步失败不动生产，**一键回滚**。升级有退路，
> 永远有一个验证过的旧版本兜底。
>
> **② 开发/运维要重启 web，工作会断吗？** 双层自愈：守护 10 秒内自动拉起 web，agent 从
> **被打断的那一步**自动续接、带着完整上下文继续。重启是**无人值守**的，工作流不被打断。
>
> **③ web 彻底起不来、连 agent 都没有了，怎么办？** out-of-band 医生 `dsh-doctor`——纯终端、
> 零 web 依赖，一条命令：九项诊断 → 机械修复已知配置故障 → LLM **深度检测修复**（完整推理
> 过程实时展示，不是黑盒）→ 拉起 web 并验证。故障从"求助"变成"**自助**"。
>
> **组件**（自愈 + 版本轮换的完整拼图）：
>
> | 组件 | 类型 | 管什么 |
> |---|---|---|
> | **`skills/dsh-snapshot-ab`** | skill | 官方每日快照 A/B 双槽轮换 —— 升级"切对版本" |
> | **`skills/dsh-web-guard`** | skill | 自愈守护 —— web 死后 10s 自动拉起 |
> | **`skills/dsh-session-recovery`** | skill | 会话丢失诊断 —— “0 sessions”/日志损坏时的定位与无损修复 |
> | **`skills/dsh-web-doctor`** | skill | out-of-band 医生 —— web/A/B 全挂时终端一键诊断→修复→拉起 |
> | **`plugins/dsh-restart-recover`** | cordis 插件 | 重启续接 —— 被中断的 turn 自动继续 |
>
> 合起来回答五个问题：**web 挂了谁拉起？拉起后工作继续吗？会话看起来丢了怎么办？官方发新版本怎么安全切换？A/B 都挂了怎么一键救？**
> 三者互补：`ab.sh switch/rollback` 杀 web → `dsh-web-guard` 拉起 → `dsh-restart-recover` 续接；
> 全挂兜底走 `dsh-web-doctor`（终端 `dsh-doctor --fix --restart`）。
>
> > 曾用名 `dsh-skill-snapshot-ab`（2026-08-11 更名）—— 仓库从"纯 AB 轮换 skill"长成了
> > "skill + 插件"混合工具箱，名字不再贴切。skill 目录名 `dsh-snapshot-ab` 保持不变
> > （它是 skill 触发名 + ab.sh 安装路径，改了破坏机制）。
>
> 本 README 是**人读的操作手册**（场景化，含每条命令）。Agent 读各 skill 的 `SKILL.md`。

---

## 📦 能力地图

```
dsh-harness-ops（本仓库）
├── skills/dsh-snapshot-ab/        AB 轮换：官方快照 A/B 双槽，旧版保底、验收后原子切换
│   └── scripts/ab.sh              主命令（status/discover/notes/prepare/verify/switch/confirm/rollback）
├── skills/dsh-web-guard/          自愈守护：launchd/systemd 托管，端口空闲 10s 内拉起 web
│   └── scripts/install.sh         跨平台安装（macOS launchd / Linux systemd）
├── skills/dsh-session-recovery/  会话丢失诊断：0 sessions/日志损坏 → 定位 → 无损修复 → 重启
│   └── scripts/                   validate-sessions / repair-session-log / check-all-sessions / repair-unknown-events
├── skills/dsh-web-doctor/        out-of-band 医生：web/A/B 全挂时终端一键诊断→修复→拉起
│   └── scripts/                   doctor.sh / doctor-tui.py / session-last-activity.mjs
└── plugins/dsh-restart-recover/   重启续接插件：agent/created 检测 interrupted → 自动注入续接
    └── src/index.ts               cordis 插件（监听 agent/created，零 dsh-track 依赖）
```

**日常用得最多的入口**：
- 看状态：`$AB status`
- 每日分析（官方改了啥）：`$AB discover` / `$AB notes`（官方 changelog）→ 见「场景 C′」
- 每日升级：`$AB discover → prepare → switch --yes → confirm`
- 自愈验证：`kill $(lsof -ti :3080)` → 10s 内自动拉起 → 会话自动继续（无需手动）

## 🚑 全挂兜底：dsh-web-doctor（web/A/B 全挂时的一键救火）

> 为什么有它：2026-08-11 两次事故（切换后 web 起不来、扩展链接被外部清理）现场修复耗了数小时——
> 每一步（查 session 最后事件 → 找根因 → 修 relink → 修会话 → 拉起 web）其实都能脚本化，缺的
> 是一个**不依赖 web 的一键入口**。完整动机与事故链见 [`docs/web-doctor-motivation.md`](docs/web-doctor-motivation.md)。

**什么时候用**：web（3080）挂了 / 起不来 / A/B 双槽都坏 / GUI 和 agent 都不可用
（agent 由 web 托管，web 挂 = 没有 agent 可用）。它是 **out-of-band** 的：纯终端 + 本机工具
（node/zstd/jq/curl/ps/lsof），**不依赖 web 进程、不加载任何扩展**。

**怎么用**（用户角度，不用记参数）：

```sh
dsh-doctor                    # 交互菜单（默认英文，菜单里选 6 切中文）
dsh-doctor --guide            # mini TUI 引导模式：逐步确认每个修复（人机协同）
```

```
=============================================================
  dsh web Doctor — one-shot rescue        // dsh web 医生 — 一键救火
  web(:3080): ✅ healthy                  // 当前 web: ✅ 正常
=============================================================
  1) Quick check (diagnose only)          // 快速体检（只读）
  2) Fix config issues (mechanical)      // 修复配置问题（机械，不依赖 LLM）：relink/
     incl. relaunch web                  //   插件依赖/launcher/session/LLM 凭据等
                                          //   已知配置故障
  3) LLM repair (recommended)            // LLM 修复（推荐）：LLM 读诊断+日志推理根因，
                                          //   发现/修复任意插件问题（含核心不兼容、
                                          //   插件配置被改乱）
  4) Deep LLM check & repair (always)   // LLM 深度检测和修复（每次都跑，不因诊断
                                          //   全绿跳过；完整思维链实时展示）
  5) Mini TUI (guided)                   // 全屏交互终端：自动修复 + LLM
                                          //   对话（看完整 CoT，随时打断指引）
  6) Switch language 中文                 // 切换语言
  7) Exit                                 // 退出
  choose [1-7]:
```

**LLM 深度检测/修复时**，`[llm]` 流式输出**完整思维链**——它怎么想（推理全文）、决定跑什么
命令（工具 + 完整命令）、得到什么结果，全程可见，不是黑盒。

### mini TUI：设计与使用（`dsh-doctor --guide` / 菜单 5）

**为什么是 TUI**（2026-08-13 教训）：一次无人值守的 `--agent` 长跑失败——被误报带偏、超时
被杀、什么都没修成。**没有人 guide 的 doctor 长任务不靠谱**。mini TUI 是"有人看着的自愈"：
LLM 自动干活，你看着它怎么想，觉得不对就打断。

**三条设计原则**：

1. **LLM 自动判断、自动修复**——已知问题确定性自动修复（无逐项确认）；0 问题自动只读验收
   （输出"✅ 验收通过"+证据清单）；残留问题 LLM 自动诊断根因并修复。
2. **交互 = 看清完整 CoT + 随时打断**——完整推理链 markdown 实时渲染；**Ctrl-C 打断运行中的
   agent**，输入指引后回车，agent 按指引继续（上下文跨轮携带）。
3. **只有 LLM 真正卡住/需要决策时才问用户**（缺 API key、不确定的破坏性操作）——否则绝不把
   决策扔给你。全绿跑完自动出结论，5 秒后自动退出。

**界面**（python3+curses，零第三方依赖；无终端时自动回退逐步模式）：

```
┌ doctor-tui | web:200 | phase:llm | agent:thinking ⠋ | current:slot-b | PgUp/Dn=scroll ┐
│ ── 自动运行：LLM 自愈/验收（CoT 实时渲染）──                                             │
│ 让我理解当前任务：1. 我是 dsh web 的 out-of-band 自愈 agent …（CoT markdown 流式）       │
│ [tool] skill {"name":"dsh-web-doctor"}                                                  │
│ **健康。** web（:3080 返回 200）、扩展 relink 全部完好…（终答 markdown 渲染）             │
│ ✅ 验收通过：web 正常、无残留问题 — 无需任何操作                                          │
│ ✅ 无问题 — 5 秒后自动退出（按任意键取消）                                                │
└ you → agent (Enter=send ^C=interrupt /help) > _                                        ┘
```

**使用流程**：

```sh
dsh-doctor --guide          # 或菜单 5
```

1. **诊断**先在普通终端流式输出（一行行可见，绝不黑屏）
2. 进 TUI：已知问题**确定性自动修复**（relink/插件依赖/launcher/会话，可逆带备份）
3. **LLM 自动运行**：0 问题 → 只读交叉验证出"✅ 验收通过"；有残留 → 自动诊断修复
4. **收尾**：全绿 → 5 秒倒计时自动退出（按任意键取消，继续对话）；有问题 → 明确提示继续或退出

**按键**：

| 键 | 作用 |
|---|---|
| 输入 + Enter | 给 LLM 发消息/指引（agent 运行中会先打断） |
| Ctrl-C | 打断运行中的 agent（空闲时退出） |
| ←/→ Home/End | 输入光标移动（行内编辑，中文安全） |
| ⌫ / Delete | 删除光标前/后 |
| PgUp/PgDn | 滚动回看完整 CoT |
| Ctrl-L | 清屏 |
| `/help` `/quit` `/lang` | 按键帮助 / 退出 / 切换语言（en⇄zh，默认 en，也可 `DSH_DOCTOR_LANG=zh`） |

**渲染**：CoT/prompt/终答按 **markdown** 渲染（标题/粗体/斜体/行内代码/代码块/列表/引用），
工具调用显示为 `[tool]` 行；agent 运行时状态栏有 `thinking ⠋` 动态指示。**中文（CJK）
输入/编辑完整支持**（UTF-8 locale、宽字符列宽、行内光标编辑）。

**分层设计**（为什么这样）：
- **确定性层**（菜单 2）：传感器+执行器——秒级、零 LLM 成本、web 挂得再彻底也能跑；
  覆盖已知配置故障（relink/插件依赖/launcher/session/LLM 凭据）；诊断全绿时自动跳过修复
- **LLM 大脑**（菜单 3/4）：`dsh --profile headless` 起 one-shot agent，读报告+日志推理根因，
  **能发现/修复确定性规则想不到的问题**（DSH 核心不兼容改动、插件配置被改乱、新故障模式）；
  headless 不加载 web 的扩展 bundle，所以扩展故障不影响它；菜单 4 强制深度检测（全绿也跑）
- **引导模式**（菜单 5）：确定性 + LLM 的**人机协同入口**——LLM 自动判断修复，
  用户看完整 CoT 随时打断指引；适合不放心无人长跑的场景

**诊断 9 项**：web 健康 / launcher 链 / 扩展 relink / 槽可启动 / session 文件层（逐日志校验）/
web.log（分类历史残留 vs 当前故障）/ profile bundles 依赖（任意插件，子路径按 exports map
解析）/ LLM 配置（.env key）/ 最近会话最后发生的事。

---

**官方改动提炼（每日分析）**：官方仓库没有 CHANGELOG 文档，但**强制**每个非平凡改动写一篇
**Agent Note**（`.agents/notes/implemented/<class>/yyyy-mm-dd-<topic>.md`，class ∈ feature /
bug-fix / simplification / architecture / process / testing，每篇带 `.zh.md` + `.i18n.yaml`，
内容为 Problem / Decision / Consequences / Alternatives）。因此**两个快照之间新增的笔记就是
官方对该快照的 changelog**。`ab.sh discover`（候选更新时自动打印）+ `ab.sh notes`（单独查看）
把这段 changelog 直接列出来——先读官方"为什么"，再读代码 diff 验证，产出
`snapshot-diff-report-YYYYMMDD.md`。

---

## 0. 先懂一个心智模型（AB 轮换）

```
~/.local/bin/dsh  (PATH launcher)
   └─> ~/.dsh/source/current   ← 符号链接，指向"当前生效的槽"
            └─> slot-a/  ── 旧版（20260809 快照 + 本地 fix）    ← 当前生产
            └─> slot-b/  ── 新版（20260810 快照，已构建+验收）  ← 候选
```

- **生产（http://127.0.0.1:3080）永远只跑 `current` 指向的那个槽。**
- 切换 = 一次原子 `ln -sfn current <槽>` + 重启 `dsh web`。
- A/B 是**槽位身份**（目录名固定），**内容每天互换**：旧版占一个槽，新快照进另一个槽。
- 两个槽都能"同时起进程"（不同端口），但共享 `~/.dsh` 的 sessions/storages ——
  **一个生产实例常驻，另一个槽只用于验收/临时查看（只读、看完就关）**，详见场景 E。

约定：下文 `$AB` 指 `~/.dsh/skills/dsh-snapshot-ab/scripts/ab.sh`（装好 skill 后就在）。

---

## 1. 安装

```sh
# 一键安装：4 个 skill 进 ~/.dsh/skills + dsh-restart-recover bundle 进 web profile
git clone https://github.com/dsh-external/dsh-harness-ops.git
cd dsh-harness-ops
bash scripts/install.sh

# 可选：自愈守护（launchd/systemd，web 死后 10s 自动拉起）
bash skills/dsh-web-guard/scripts/install.sh
#   v0.3.1 起判活只认 LISTEN 态 socket（-sTCP:LISTEN）——浏览器页面挂着的连接
#   不会再把端口误判为"被占用"，web 死后守护必定拉起

# 配置（首次会自动读，示例见 skills/dsh-snapshot-ab/references/ab-config.example.json）
# 通常只需确认 ab-config.json 里的 extensions（包括 dsh-restart-recover）与 web 端口
vi ~/.dsh/source/ab-config.json

# 验证
$AB status
```

> **版本与发布**：仓库是发布单元（GitHub 即分发）——skills（目录机制）不进 npm；
> bundle 插件 `@fakechris/dsh-restart-recover` 已发 **npm**（官方立场见
> [`docs/RELEASE.md`](docs/RELEASE.md)）。版本 = 根目录 `VERSION` + git tag `vX.Y.Z` +
> [`CHANGELOG.md`](CHANGELOG.md)（SemVer）。
> **更新不需要本地构建插件**：`bash scripts/update.sh` 一条命令完成
> `git pull → 重装 skills → 从 npm 重装 bundle`。生产 profile 固定使用已发布的
> `@fakechris/dsh-restart-recover`，不会再链接仓库中可能被清理的 `lib/`。

```sh
# 之后每次更新
cd dsh-harness-ops && bash scripts/update.sh
```

`ab-config.json` 关键字段：`upstream`（官方仓库）、`extensions[]`（扩展列表：repo/relink/构建命令）、
`web.port`（staging 冒烟端口，默认 3081）、`web.productionPort`（默认 3080）、
`web.smokeClientIds`（client-manifest 断言）、**`acceptance`**（验收开关，见下）。
示例把 `dsh-restart-recover` 也列为 npm 扩展，保证新候选槽安装正式包，而不是只修当前槽。

### 验收模式开关（`acceptance`）

```json
"acceptance": {
  "mode": "manual",                    // "manual"（默认，切换前必须你确认）| "auto"（e2e 过即切）
  "e2e": {
    "enabled": true,                   // 需 agent-browser 在 PATH
    "checks": [ { "id": "@deepseek-ai/dsh-track", "selector": "#dsh-track-fab", "expect": "present" } ]
  }
}
```

- **`e2e`**：真实浏览器打开候选，断言这些 UI 元素存在——证明 client 插件**真的渲染**了
  （manifest 有行 ≠ 浏览器挂上了；今天的 ◆ 面板事故就是例子）。
- **`mode: manual`**：`switch` 仍需 `--yes`（用户确认）；**`mode: auto`**：e2e 通过即视为
  用户已授权，`switch` 不再要交互确认（仍会写 handoff、重启 web）。随时可改；auto 模式下
  e2e 未过时 `switch` 会拒绝执行。

---

## 2. 场景手册（按故事走，命令可直接抄）

### 场景 A · 第一次部署：把当前运行版本收编为 slot-a

> 目标：让机制接管现有安装 —— 当前正在跑的版本变成 A 槽，机制状态落盘。**不会重启服务。**

```sh
$AB status        # 确认 current 指向、slots 为空、phase=idle
$AB init --yes    # 新建 slot-a worktree + pnpm install + 完整构建（build:lib+build:web，约几分钟）
                  # 完成后 current -> slot-a；正在跑的服务不受影响（下次重启才走新槽）
$AB status        # slot a* 有内容，current=a，phase=idle
```

`init` 只做一次。它会**完整构建**收编槽（`dsh web` 依赖 `lib/` 与 `apps/web/dist`，
新 worktree 没有这些 gitignored 产物），构建失败会中止且不碰 `current`。

### 场景 B · 日常启动（每天都一样）

```sh
dsh web           # 启动生产。永远不需要指定 A/B —— 跑的是 current 指向的槽
```

- 启动/重启命令就是 `dsh web`（或 PATH 上的 launcher），从任何目录都行。
- 想看现在跑的是哪个版本：`readlink ~/.dsh/source/current` 或 `$AB status`。
- 想确认服务健康：`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/` → `200`。

### 场景 C′ · 官方改了啥 → 每日分析（changelog → diff → 报告）

**只分析，不改运行版本。** 想知道官方某天快照改了什么、影响什么，在对话里直接说
「**分析一下今天和昨天的快照** / 今天官方改了啥 / 官方改了什么 / 看下今天的 changelog」即可
触发（等价命令如下）：

```sh
# 1) 官方 changelog（"为什么、放弃了什么"）——先读这个，再读 diff
$AB discover               # 列快照分支；候选比当前新时直接打印官方 changelog（当前 tip → 候选）
$AB notes                  # 单独打印：默认 运行 tip → 最新快照；没有新快照时自动显示"当前运行对"
                           #   --full   连笔记正文（Problem/Decision/Consequences/Alternatives）
                           #   --from/--to <ref>   指定区间
                           #   --json   纯 JSON（stdout 无日志，机器可解析）
                           # 输出形如：feature  2026-08-08-windows-acl-restricted-token-sandbox  —  Windows sandbox rung: ...

# 2) 代码 diff 验证（notes 是意图，diff 是事实；两者对不上以代码为准并回报）
#    git diff <old-tip> <new-tip> 按需深挖

# 3) 产出：snapshot-diff-report-YYYYMMDD.md（官方改动五大主题 + 核心改动 + 对 dsh-track/我们的影响评估）
```

**触发话术速查**（对话里说，不用碰命令行）：

| 你说 | agent 做 |
|---|---|
| "官方今天发新快照了吗" / "看下今天的快照" | `ab.sh discover`（列快照 + 候选更新时附官方 changelog） |
| "分析一下今天和昨天的快照" / "今天官方改了啥" / "官方改了什么" / "看下今天的 changelog" | `discover` + `notes` → 按「notes 意图 → diff 事实」分析 → 产出报告 + 影响评估 |
| "跑一下 daily 快照更新" / "升级到今天的快照" | 完整轮换：`discover → prepare → 验收 → switch → confirm` |
| "切换新快照" / "AB 双版本轮换" | 轮换/回滚流程（重启 web 前先写 handoff） |

> 说"官方改了啥"一类话术时**默认只分析、不改运行版本**；要真正升级再说"升级/切换/跑一下 daily"。

### 场景 C · 官方发了新快照 → 每日轮换（核心流程）

> 官方每天发一个新 `snapshots/...` 分支。目标是：**在不动生产的前提下**，把新快照构建好、
> 挂上我们的扩展、验收通过，然后你批准才切换。

```sh
# 1) 看状态
$AB status                 # 谁在生产、phase、扩展脏文件数

# 2) 看官方今天发了什么
$AB discover               # fetch 上游 → 列出快照分支 → 指出下一个候选 + 与当前的 diff 摘要
                           # + 官方 changelog（候选更新时：新增的 agent notes，即官方"为什么"）
                           # 输出类似：next candidate: snapshots/20260810T155924Z-8ec407cd64
$AB notes                  # 单独打印 changelog：默认 运行 tip → 最新；无新快照时显示当前运行对
                           # --full 连笔记正文；--json 纯 JSON

# 3) 在"非当前槽"构建 + 挂扩展 + 冒烟（全程不动生产）
$AB prepare                # 自动选非当前槽；也可显式 --slot b / --snapshot <ref>
                           # 流水线：检出快照 → pnpm install --frozen-lockfile
                           #        → build:lib + build:web
                           #        → 扩展 relink + 生成 tsconfig.ab.json + typecheck/build/test（DSH_SOURCE=候选槽）
                           #        → 扩展运行时依赖检查（扫产物裸 import vs node_modules，缺链接即失败——
                           #          build/test 走 tsconfig paths/vitest alias 会掩盖漏链，生产 node ESM 不会）
                           #        → 无 bin/dsh 的槽自动生成 launcher 包装器（20260811+ 快照删了 bin/dsh）
                           #        → 候选在 staging 端口(3081)冒烟 HTTP 200（启动路径与生产一致，纯 node ESM）
                           # 全绿 → phase=prepared，证据写入 ab-state.json
                           # 任何一步失败 → 还原扩展 relink、current 不动、phase 回 idle（见场景 G）

# 4) 复查（可选）
$AB verify                 # 对已 prepared 的候选重跑扩展测试 + 冒烟

# 5) E2E 前端挂接验收（推荐，唯一能证明"前端真的挂上了"的一步）
$AB e2e                    # 真实浏览器打开候选，断言 acceptance.e2e.checks 里的 UI 元素存在
                           # （如 #dsh-track-fab）；通过后证据 candidateEvidence.e2e.ok=true

# 6) 切换 —— 开关决定这一步要不要你确认（见"验收模式"）
#    manual 模式：你批准后 $AB switch --yes
#    auto 模式：e2e 通过后 $AB switch（无需交互确认）
$AB switch --yes           # manual 模式的切法（auto 模式直接 $AB switch）
```

**`prepare` 的三条硬规则**（脚本内置，但你要知道）：
- 候选槽 ≠ 当前槽；
- 切换后未 `confirm` 前，**拒绝回收回滚槽**（那是唯一保底），除非 `--force`；
- 验收不过绝不切换。

### 场景 D · 切换那一刻（会断会话，先读这个）

> `switch` 做的事：`current` 原子指到候选槽 → 验证 launcher → 重启 `dsh web`。
> **重启 = 你当前所在的 agent 会话会断**（托管 web 的就是它自己）。这是预期，不是故障。

**切换前（3 件事）**：
```sh
# ① 把要说的话说完 / 写好 handoff（仓库目录下的 HANDOFF-snapshot-ab.md 就是恢复入口）
# ② 确认候选已 prepared 且你验收过
$AB status                 # phase=prepared, candidate=b
# ③ 想保留 staging 人工复查的实例？先关掉（见场景 E），避免双实例
```

**切换**：
```sh
$AB switch --yes
# 输出会显示：CUTOVER → 停旧 web → 起新 web（nohup，日志 ~/.dsh/source/web.log）→ HTTP 200
# 装了 dsh-web-guard 时：ab.sh 杀 web 后守护会自动拉起新 current（兜底，更可靠）
```

**切换后（重启完成，打开 http://127.0.0.1:3080）**：
```sh
# ① 确认跑的是新版
readlink ~/.dsh/source/current          # 应 = .../slot-b
$AB status                              # current=b, phase=switched, confirmed=false
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/   # 200

# ② ⚠️ 浏览器硬刷新（Cmd+Shift+R）—— 不是普通刷新！
#    旧 tab 里是切换前加载的 boot manifest；新 client 插件/面板（如 dsh-track 的 ◆）
#    只在刷新后的页面出现。2026-08-11 实测坑：不刷新，◆ 悬浮按钮一直不出现。

# ③ 用几天/一会儿，确认新版没问题
# ④ 没问题 → 标记稳定（解锁下一天回收回滚槽）
$AB confirm
```

**面板（dsh-track）注意**：右侧面板默认**收起**，右下角 ◆ 悬浮按钮点击展开，开合状态记在
浏览器 localStorage（`dsh.track.open`）。"面板不见了"先按顺序查：manifest 有 dsh-track 吗 →
硬刷新了吗 → 点 ◆ 了吗。

**找回"之前那个会话"**：会话都存在磁盘上（`~/.dsh/sessions/`），重启后重新索引，一个都不丢。
在 GUI 里找到本工作区（如 `~/source/dsh/explorer`）的历史会话即可；新会话会自动读到
该目录的 `AGENTS.md` → `HANDOFF-snapshot-ab.md`，知道从哪继续。

### 场景 E · 临时查看另一个版本（有护栏，别裸跑）

> 生产在跑的时候，你想看看另一个槽的界面（验收 / 对比）。**不要直接**
> `<候选槽>/bin/dsh web --port 3081` 裸跑 —— 用 `stage`，它会检测并要你确认。

```sh
$AB stage --slot b --port 3082            # 前台跑，Ctrl-C 停止
$AB stage --slot a --port 3082 --keep --yes   # 后台跑（nohup），停止用它打印的命令
```

`stage` 的行为：
- **先检测**：已有 web 实例在跑（如生产 3080）→ 打印警告"第二个实例共享 ~/.dsh，只读查看"；
- **要求你 `--yes` 明确确认**才启动；不带 `--yes` 直接拒绝并退出；
- 目标端口被占 → 直接报错让你换 `--port`；
- `--keep` 后台跑并打印日志路径与停止命令（`kill $(lsof -tiTCP:<port> -sTCP:LISTEN)`）。

⚠️ 临时实例期间：**只读**，别同时做写操作，看完就关。

### 场景 F · 新版有问题 → 回滚（随时可回）

```sh
$AB rollback --yes     # current 指回 lastSwitch.previousTarget（上一版）+ 重启 web
                       # 同样会断当前会话；重启后从 HANDOFF 继续
$AB status             # phase=rolled-back, current 回到旧槽
```

回滚后旧版本（含本地 fix）完整保留在回滚槽；新快照的问题可以慢慢查，不影响生产。
手动兜底（`ab.sh` 不可用时）：
```sh
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current
kill <web pid> && cd ~/source/test-fakechris && nohup dsh web &
```

### 场景 G · prepare 失败 → 排查

`prepare` 任何一步失败都会：还原扩展 relink/tsconfig、`current` 不动、phase 回 `idle`。
按输出定位：

| 失败在哪 | 含义 | 怎么处理 |
|---|---|---|
| `pnpm install failed` | 依赖装不上（网络/锁文件） | 查网络；`$AB prepare` 重试（会自动 `clean -fdx` 全新安装） |
| `harness build failed` | 新快照本身构建不过 | 这是**上游问题**，别切换；把 build 输出尾部报告给用户/上游 |
| `extension ... FAILED` | 我们的扩展与快照 API 不兼容（typecheck/build/test 红） | 这就是验收的意义：**不切换**；在扩展仓库修兼容后重跑 prepare |
| `web smoke FAILED` | 候选 web 起不来 / 端口被占 | 看冒烟日志（输出会打印）；端口被占换 `web.port` |

常见修复后重试：`$AB prepare`（槽已在目标快照且有构建产物时会走**复用快路径**，只重跑扩展+冒烟）。

### 场景 H · web 起不来 / 缺构建产物

症状：`dsh web` 起来但页面空白 / 报缺 `lib`、`dist`。
原因：新 worktree 的 `lib/` 与 `apps/web/dist` 是 gitignored 构建产物，**只 `pnpm install` 不够**。
解决：
```sh
cd ~/.dsh/source/<槽> && pnpm run build     # = build:lib（tsc+tsdown）+ build:web（vite）
```
（`ab.sh init` 与 `ab.sh prepare` 都会自动做完整构建；只有手动建的 worktree 才需要这个。）

### 场景 I · 端口冲突 / 双实例 / 锁被占

```sh
# 端口被占
lsof -iTCP:3081 -sTCP:LISTEN        # 谁占着；stage/smoke 换 --port / web.port
# 误开了第二个实例（忘了关）
lsof -tiTCP:<port> -sTCP:LISTEN | xargs kill
# 锁被占（另一个 A/B 操作进行中）
# → 输出 "another A/B operation holds the lock"，等它结束或确认没有僵尸后重试
#   锁文件：~/.dsh/source/.ab.lock（flock 语义；macOS 用 python3 fcntl 实现）
```

### 场景 J · 重启后会话"找不回来"

- 会话不丢：`~/.dsh/sessions/` 按工作区存放，重启后重新索引。GUI 侧边栏应有全部历史。
- 仍看不到？用同仓库的 `skills/dsh-session-recovery` skill（专门的诊断/修复流程）。
- 想从断点继续：新会话里说"继续 snapshot-ab"，agent 会加载本 skill 并读
  `HANDOFF-snapshot-ab.md` / `USER-GUIDE-snapshot-ab.md`。

### 场景 K · `current` 或 launcher 坏了（手动兜底）

```sh
# current 丢了/指错
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current   # 指回已知好槽
dsh --version                                        # 验证 launcher 能启动

# PATH 上的 dsh 失效
ls -l ~/.local/bin/dsh                               # 应 -> ~/.dsh/source/current/bin/dsh
ln -sfn ~/.dsh/source/current/bin/dsh ~/.local/bin/dsh
```

---

## 3. 命令速查

| 命令 | 作用 | 动什么 |
|---|---|---|
| `$AB status` | 布局/槽/phase/运行中 web/扩展脏文件 | 只读 |
| `$AB discover` | fetch 上游、列快照、算候选、diff 摘要；候选更新时附官方 changelog（新增 agent notes） | 只 fetch |
| `$AB notes [--from\|--to] [--full] [--json]` | 两个快照间的官方 changelog（`.agents/notes/implemented` 新增笔记；默认 运行 tip → 最新） | 只 fetch |
| `$AB init --yes` | 收编当前版本为 slot-a（worktree+install+**完整构建**），不重启 | current |
| `$AB prepare [--slot a\|b] [--snapshot <ref>] [--skip-web] [--keep] [--force]` | 候选槽全流水线（构建+扩展+冒烟），不动生产 | 仅候选槽 |
| `$AB verify` | 对 prepared 候选重跑扩展测试+冒烟 | 只读 |
| `$AB e2e [--slot a\|b] [--port N]` | **真实浏览器前端挂接验收**（agent-browser 断言 `acceptance.e2e.checks` 的 UI 元素存在，如 `#dsh-track-fab`）；auto 模式切换的前置 | 临时实例 + 证据 |
| `$AB stage --slot a\|b [--port N] [--keep]` | 临时起某槽到 staging 端口（检测到已有实例须 `--yes`） | 临时实例 |
| `$AB switch [--yes]` | 原子切换 current → 候选 + 重启 web（**断会话**）；manual 模式须 `--yes`，auto 模式须 e2e 已过 | current + 服务 |
| `$AB confirm` | 标记当前稳定，解锁下一天回收回滚槽 | state |
| `$AB rollback --yes` | current 指回上一版 + 重启 web（**断会话**） | current + 服务 |
| `$AB cleanup [--yes] [dir...]` | 列出/移除旧 worktree（绝不删当前槽） | worktrees |

## 4. 布局与文件

| 路径 | 是什么 |
|---|---|
| `~/.dsh/source/current` | 符号链接 → 当前生效槽（生产 = 它） |
| `~/.dsh/source/slot-a` / `slot-b` | 两个槽（git worktree，主克隆的共享对象库） |
| `~/source/test-fakechris` | 主克隆（对象库 + worktree 宿主，**从不作为运行目标**） |
| `~/.dsh/source/ab-state.json` | 机制状态（slots/current/phase/evidence/history） |
| `~/.dsh/source/ab-config.json` | 配置（upstream/扩展列表/web 端口） |
| `~/.dsh/source/web.log` | 生产 web 重启日志 |
| `~/.dsh/skills/dsh-snapshot-ab/` | 本 skill（SKILL.md=agent 手册，references/=设计+用户菜单） |

## 5. 设计原则（为什么这样做）

1. **`current` 符号链接 + git worktree**：与官方 `dsh-upgrade` 同构；切换是一次原子 `ln -sfn`，
   主克隆只做对象库和 worktree 宿主，从不被运行。
2. **扩展在槽外、按槽参数化**：扩展（如 dsh-track）通过 `DSH_SOURCE` / 生成的 `tsconfig.ab.json`
   / node_modules 符号链接指向目标槽 → 能在**切换前**就对着新快照构建测试。
3. **验收门**：install / build / 扩展测试 / web 冒烟全绿才算 prepared；验收不过不切换。
   冒烟不止 HTTP 200 —— `web.smokeClientIds` 断言扩展 client 出现在 `window.__DSH_BOOT__`
   （20260810 把声明键 `dshClient` 改为 `dsh.client`，只有 HTTP 200 会漏掉这个洞）。
4. **单实例原则**：两个槽共享 `~/.dsh`（sessions 是 append-only 共享文件、storages KV 是
   单进程串行写链）——一个生产常驻，另一个槽只在 `stage`/冒烟时短起、只读、看完即关。
5. **确认窗口**：`switch` 后必须 `confirm` 才允许回收回滚槽；回滚永远可用。
6. **与 `dsh-web-guard` 配合**：guard 是"带外"自愈守护（launchd/systemd 托管，PPID=1，
   端口空闲 10s 内拉起）——ab.sh 杀 web 后 guard 自动拉起新 current，无需手动启动；
   ab.sh 自己启动成功则 guard 不抢。切换/重启后**浏览器硬刷新**才看得到新 client 面板。

## 6. 与相邻项目的关系

- 官方 `dsh-upgrade`：rebase 到上游 master 的整合流程（偶尔用）；本机制是"官方每日快照 +
  扩展外挂"的日常轮换，两者可共存。
- **`dsh-web-guard`（同仓库的另一个 skill）+ `plugins/dsh-restart-recover`**：完整的重启自愈——
  AB 切换负责"切对版本"，guard（skill 的守护脚本）负责"重启后必定拉起 web"，restart-recover
  （cordis 插件）负责"重启后自动继续被中断的 turn"（监听 `agent/created`，注入续接消息，
  用户零输入）。三者互补：`ab.sh switch/rollback` 杀 web → guard 拉起 → recover 续接。
  插件从 dsh-track 独立出来（2026-08-11），因为它和 guard 一样是**平台级自愈能力**，
  不该绑在业务插件 dsh-track 上。
- **`dsh-session-recovery`（同仓库 skill，2026-08-11 并入）**：会话丢失的诊断/修复/重启流程，事故复盘见 `skills/dsh-session-recovery/references/incident-20260809-session-loss.md`。
- 社区 `mainline-compat`（dsh-external-research）：插件 ↔ 当日 mainline 的**兼容性监控/报告**；
  它答"插件还能不能用"，本机制答"怎么安全地切过去"。
- `dshx-update-check`：commit SHA 对比**检测**更新（只检测）。

---

## 附：本次实测记录（2026-08-11）

- `init` 收编旧版（be90233）为 slot-a，`current` 重指，生产未重启 ✅
- `prepare`+`verify` 在 slot-b 构建 20260810 快照（4cdb149）：扩展 typecheck/build/**75 测试全过**、
  冒烟 **HTTP 200** ✅
- 验收门真实捕获上游变更：20260810 快照移除了 `dsh web --workspace-root` 标志（冒烟自动适配）✅
- 修复的机制 bug：init 缺完整构建（见场景 H）、stage 缺共存护栏（见场景 E）、冒烟清理残留进程 ✅
- **20260810 上游声明键改名事故（已修复）**：快照把 client-modules 声明键 `dshClient` 改为
  `dsh.client`，扩展未适配 → host 插件正常、扩展测试全绿、冒烟 200，但 client 面板消失。
  修复：扩展统一声明新版 `dsh.client` 键（旧键 `dshClient` 不做兼容，旧版随轮换淘汰）+
  验收门新增 **client-manifest 断言**（`web.smokeClientIds`，解析 `__DSH_BOOT__` 逐 id 校验）✅
- **面板回归验证（浏览器实测）**：修复后 slot-b 的 `__DSH_BOOT__` 含 `@deepseek-ai/dsh-track`、
  `/plugins/.../client.js` 200、插件 apply() 执行（◆ FAB 与 panel DOM 存在）、点 FAB 面板展开
  且拉到真实数据 ✅
- **"重启后看不到 ◆"= 旧 tab 未刷新**（教训）：boot manifest 在页面加载时取，重启后旧 tab
  一直是旧 manifest；硬刷新（Cmd+Shift+R）即出现。已写进两个 skill 的验证/排查节 ✅
