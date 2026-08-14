---
name: dsh-snapshot-ab
description: >-
  官方 DeepSeek Harness 的 A/B 双槽轮换（npm 生态版）+ 版本检测机制。上游真相 = npm registry：
  检测 @deepseek-ai/dsh 的 dist-tag（next/latest），新版本装进另一槽（DSH_HOME + 扩展 npm 包），
  验收（冒烟/浏览器 e2e）通过后原子切换 current，旧版本保留回滚；也支持 --source 手动源码路径
  （git master / 快照分支）。用户说"官方发新版了吗 / 检查 npm 更新 / 升级到最新版 / AB 双版本轮换 /
  切换新版本 / 跑一下更新"触发；说"官方今天改了啥 / 分析版本差异"触发版本对比。English: official
  DeepSeek Harness A/B dual-slot rotation on the npm ecosystem — npm registry dist-tags are the
  upstream truth; a new @deepseek-ai/dsh version is installed into the other slot (DSH_HOME plus
  extension npm packages), verified (smoke / browser e2e), then current is switched atomically with
  the old version kept for rollback; --source offers the legacy git path. Use when the user asks to
  check for a new official npm release, upgrade to the latest version, rotate A/B versions, or diff
  official versions。
---

# DSH A/B Rotation — npm ecosystem（npm 生态版 A/B 轮换）

官方 2026-08-13 起从私有快照转为公开仓库 + npm 发布：**npm registry 是唯一发布真相**
（master 可能落后 npm、无 git tag）。本机制不再跟随 git 快照分支，而是检测 `@deepseek-ai/dsh`
的 dist-tag（`next` = 最新 rc，`latest` = 正式版），把新版本装进另一个槽（独立 DSH_HOME +
扩展 npm 包），验收通过后原子切换 `current`，旧版本保留回滚。

## 何时用

- 官方发布了新 npm 版本（dist-tag 变化），要把运行版本换成新的。
- 需要评估某 npm 版本对我们扩展（dsh-track 等）的兼容性（安装/冒烟/e2e）。
- 需要回滚到上一个 npm 版本。
- （手动）`--source` 走源码路径：git master / 快照分支 + 源码构建 + 扩展 relink。

不要用本 skill 做 rebase 到 master 的升级（那是 `dsh-upgrade`）、或修改 harness 源码（那是 `dsh-customize`）。

## 用户怎么触发（对话说法 → 动作）

你不必碰命令行；在对话里说下面的话，agent 会自动跑对应的 ab.sh 流程：

| 你说 | agent 做 |
|---|---|
| "官方今天发新快照了吗" / "看下今天的快照" | `ab.sh discover`（列快照分支；候选更新时自动附官方 changelog） |
| "分析一下今天和昨天的快照" / "今天官方改了啥" / "提炼一下官方改了什么" / "看看今天的 changelog" | `ab.sh discover` + `ab.sh notes`（官方 changelog）→ 按「notes 意图 → 代码 diff 事实」分析 → 产出 `snapshot-diff-report-YYYYMMDD.md` 并给影响评估 |
| "跑一下 daily 快照更新" / "升级到今天的快照" | 完整轮换：`discover → prepare → e2e/验收 → switch --yes → confirm` |
| "切换新快照" / "AB 双版本轮换" | 轮换/回滚流程（`prepare/switch/rollback`；重启 web 前先写 handoff） |

注意：说"官方改了啥"一类话术时**默认只分析、不改运行版本**；要真正升级再说"升级/切换/跑一下 daily"。

## 布局（先解析，别假设）

- launcher：`command -v dsh`（如 `~/.local/bin/dsh`）→ 解析符号链接链 → `~/.dsh/source/current/bin/dsh`。
- `current` 是一个**符号链接**，指向当前生效的槽目录；launcher 永远解析 `current`。切换 = 一次原子 `ln -sfn`。
- 槽：`$DSH_SOURCE/slot-a`、`$DSH_SOURCE/slot-b`，是主克隆（`~/source/test-fakechris`）的 git worktree，分支 `dsh-ab/a`、`dsh-ab/b`。
- 主克隆是唯一真实 clone（共享对象库），只做 fetch / worktree 托管，绝不作为运行目标。
- 状态：`$DSH_SOURCE/ab-state.json`（槽、快照、current、phase、confirmed、历史）。
- 配置：`$DSH_SOURCE/ab-config.json`（upstream、扩展列表、web 冒烟参数）。
- 扩展（如 dsh-track）在槽**之外**（`~/source/dsh-involute`），通过 node_modules 符号链接 + 生成的 `tsconfig.ab.json` + `DSH_SOURCE` 环境变量指向当前目标槽，因此可以"先对着 B 槽构建测试，再切换"。

## 每日工作流

1. **`ab.sh status`** — 确认当前状态（slots、phase、running web、扩展脏文件数）。phase 应为 `idle` 且 current 已设置；若未初始化先做 `ab.sh init --yes`（把当前运行版本收编为 slot-a：新建 worktree + `pnpm install` + **完整构建 build:lib+build:web**（数分钟，`dsh web` 依赖构建产物），不重启服务）。
2. **`ab.sh discover`** — fetch 上游，列出快照分支，指出下一个候选，并打印与当前的 diff stat；当候选**比当前更新**时，还会打印官方 changelog（见下）。人工（agent）按「**先读官方 changelog，再读代码 diff**」的顺序分析：notes 给出意图（为什么、放弃了什么），diff 给出事实；两者对不上时以代码为准并回报。参考已有的 snapshot-diff 研究流程与产出物（`snapshot-diff-report-*.md`）。

### 官方 changelog：agent notes（先读这个，再读 diff）

官方仓库**没有** CHANGELOG 文档，但强制每个非平凡改动写一篇 **Agent Note**
（`.agents/notes/implemented/<class>/yyyy-mm-dd-<topic>.md`，class ∈ feature /
bug-fix / simplification / architecture / process / testing；每篇带 `.zh.md` +
`.i18n.yaml`，统一格式 Problem / Decision / Consequences / Alternatives）。因此
**两个快照之间新增的 notes 就是官方对该快照的 changelog**。

- `ab.sh discover`：候选比当前新时直接打印这段 changelog（当前 tip → 候选）。
- 单独查看：**`ab.sh notes`** — 默认 运行中快照 tip → 最新快照；没有新快照时
  自动显示「当前运行对」（另一槽 → 当前）。`--full` 连笔记正文一起打印；
  `--from/--to <ref>` 指定区间；`--json` 输出结构化列表（纯 JSON，stdout 无日志）。
- 脚本/agent 流程：读 changelog 条目 → 按需 `git show <ref>:<path>` 看全文 →
  代码 diff 验证 → 写 `snapshot-diff-report-YYYYMMDD.md`。
3. **`ab.sh prepare [--slot b] [--skip-web]`** — 在**非当前槽**执行完整流水线：
   - 检出候选快照（worktree reset / 新建）→ `pnpm install --frozen-lockfile` → harness `build:lib`（+`build:web`，除非 `--skip-web`）。
   - 扩展挂接：relink node_modules → 候选槽；生成 `tsconfig.ab.json`（把扩展 tsconfig 里的 `/Users/chris/.dsh/source/current` 前缀替换为候选槽）；用 `DSH_SOURCE=<候选槽>` 跑扩展的 typecheck/build/test；同步 skills 到 `~/.dsh/skills/`。
   - **扩展运行时依赖检查**：扩展的 build/test 走 tsconfig paths / vitest alias 解析 `@deepseek-ai/*`，而生产 node ESM 只认扩展 node_modules 的 relink 链接——两者不同步时（如扩展新增依赖但 ab-config relink 没加）测试全绿、生产却 `ERR_MODULE_NOT_FOUND`（2026-08-11 dsh-llm 事故）。prepare 会扫描扩展构建产物的裸 import，缺链接直接失败并提示补 `extensions[].relink`。
   - **槽 launcher 补位**：20260811+ 快照删了 `bin/dsh`，prepare 会给无 launcher 的槽生成 `bin/dsh` 包装器（指向编译产物 `apps/cli/lib/bin.js`），保证切后 `dsh` 命令链（`~/.local/bin/dsh → current/bin/dsh`）不断。
   - 候选槽在 **staging 端口**（默认 3081）冒烟：**启动路径与生产一致**（优先 `lib/bin.js` 纯 node ESM，不用 tsx——tsx 会读 tsconfig paths，掩盖漏链）→ HTTP 200 + 配置的 smokePaths；`--keep` 保留 staging 服务器供人工浏览器验收。
   - 任何一步失败：恢复扩展 relink/tsconfig，`current` 不动，phase 回 `idle`，**不切换**。
   - 成功后 phase=`prepared`，证据写入 ab-state.json（快照、tip、扩展构建结果）。
4. **`ab.sh verify`** — 对已 prepared 的候选重跑扩展测试 + web 冒烟（不改状态），用于复查。
5. **`ab.sh e2e`** — **真实浏览器前端挂接验收**：把候选起在 staging 端口，用 agent-browser 打开页面，
   按 `acceptance.e2e.checks`（如 `#dsh-track-fab` 存在）逐一断言**前端真的渲染了插件的 UI**——这是
   manifest 断言也证明不了的最后一环（manifest 有行 ≠ 浏览器里挂上了）。通过后证据
   `candidateEvidence.e2e.ok=true` 写入 state。需要 `agent-browser` 在 PATH。
6. **验收模式开关**（`ab-config.json` 的 `acceptance.mode`）：
   - **`manual`**（默认）：第 7 步切换前必须拿到用户明确同意（`--yes`）。
   - **`auto`**：E2E 通过即视为用户已授权，切换不再要求交互确认（仍会写 handoff、重启 web）。
     用户随时改配置切换模式；`switch` 在 auto 模式但 e2e 未过时会拒绝执行。
7. **切换**：
   - 先写 handoff 说明（`dsh web` 重启会终止当前 agent 会话本身）。
   - **`ab.sh switch`**（manual 模式需 `--yes`；auto 模式需 e2e 已过）— 原子 `ln -sfn current -> 候选槽` → 验证 launcher 可启动 → 重启 web（自动杀旧 PID、nohup 启动、轮询 HTTP 200）→ phase=`switched`、confirmed=`false`。旧槽原样保留 = 回滚点。
   - **装了 `dsh-web-guard` 时**：ab.sh 杀 web 后守护会自动用完整环境拉起新 current（更可靠的兜底）；ab.sh 自己先启动成功则守护不抢。无论谁拉起，**切换后浏览器必须硬刷新（Cmd+Shift+R）**——旧 tab 里是切换前加载的 boot manifest，新 client 插件/面板（如 dsh-track 的 ◆）只在刷新后的页面出现（2026-08-11 实测坑）。
8. **确认稳定 = 生产验收**：**`ab.sh confirm`** 内置生产验收 gate（2026-08-11 事故后新增）——生产端口 HTTP 200、运行 web 进程来自当前槽、`dsh` launcher 链解析进当前槽、扩展 client manifest 在页面上，四项全过才写 `confirmed=true`（confirmed=true 后 `prepare` 才允许回收回滚槽）。**任何一项不过即拒绝确认**——"确认"不再是口头背书，而是对生产等价路径的实测。
9. 下一天：A/B 角色互换，`prepare` 自动选非当前槽。

> 事故复盘：2026-08-11 切换事故（dryrun 全绿但生产起不来）的完整根因链与防复发措施见
> [`references/postmortem-ab-switch-20260811.md`](references/postmortem-ab-switch-20260811.md)（中）/ 
> [`references/postmortem-ab-switch-20260811.en.md`](references/postmortem-ab-switch-20260811.en.md)（英）。

## 回滚

- 切换后、确认前发现问题：**`ab.sh rollback --yes`** — `current` 指回 `lastSwitch.previousTarget`，重启 web，phase=`rolled-back`。
- 回滚后旧版本（含本地 fix 提交）仍在回滚槽里，可继续排查新快照的问题。
- 旧 worktree 清理：`ab.sh cleanup`（只列出）；`ab.sh cleanup --yes <dir>...`（明确指定的、且不是当前槽的）。绝不删未知目录。

## 安全规则（违反即停）

1. **锁**：prepare/switch/rollback 用 `~/.dsh/source/.ab.lock`（flock 语义，python3 fcntl 实现）；拿不到锁就停下来，不重试破坏性操作。
2. **绝不改动当前槽**：`current` 指向的目录在整个流程中只读；只动另一个槽。
3. **确认窗口**：`switched` 且未 `confirm` 时，回滚槽是唯一保底——禁止回收它。
4. **重启即断线**：`switch`/`rollback` 重启 `dsh web`，会终止发起者的会话。先写 handoff，再执行；恢复后按 handoff 继续。
5. **不 stash、不硬删**：扩展仓库有未提交 WIP 时照常构建（构建的是工作区内容）；失败只恢复我们改过的东西（relink、tsconfig.ab.json），不动其它文件。
6. **验收不过不切换**：任何 gate（install/build/扩展测试/web 冒烟）失败即停止，把失败证据报告给用户，绝不带病切换。
7. **单实例原则**：两个槽可同起（不同端口），但共享 `~/.dsh` sessions/storages——**一个生产实例常驻**；另一个槽只用于验收/临时查看（`stage`/冒烟），检测到已有实例时必须让用户明确确认（`--yes`）后才启动，看完即关、只读不写。
8. **验收含 client manifest**：冒烟不止 HTTP 200——`web.smokeClientIds` 断言扩展 client 出现在 `window.__DSH_BOOT__`（20260810 快照把声明键 `dshClient` 改为 `dsh.client`，扩展未适配时 host 正常、测试全绿但 client 静默丢失，面板消失——就是这个门抓出来的）。扩展**统一声明新版 `dsh.client` 键**；旧键 `dshClient`（20260809 及更早快照用）不做兼容——旧版确认稳定后随轮换淘汰。

## 扩展的 DSH_SOURCE 参数化（机制的一部分）

扩展的构建/测试工具链必须在**任意槽**上运行。dsh-track 已改为：

- `scripts/dsh-env.mjs`：从 `DSH_SOURCE`（默认 `~/.dsh/source/current`）解析 `node_modules/.bin/<cmd>` 并 spawn；package.json 的 build/test/typecheck 都经它。
- `vitest.config.ts`：`const DSH = process.env.DSH_SOURCE ?? '...current'`。
- 每槽 tsconfig（`tsconfig.ab.json`，gitignored）由 `ab.sh prepare` 生成，`DSH_TSCONFIG` 指定。
- node_modules 的 `@deepseek-ai/*` / `cordis` 符号链接由 `ab.sh` 在 prepare 时指向候选槽、失败时还原。

新扩展接入：在 `ab-config.json` 的 `extensions[]` 里加一条（repo、skills、relink 映射、tsconfig、build/test/typecheck 命令），并保证其构建方式与上述参数化一致（或提供等效机制）。

## 与官方 skill 的关系

- `dsh-customize`：本机制复用它的布局解析纪律（launcher → current → worktree → 主克隆）与"staging 不可直接改"原则。
- `dsh-upgrade`：那是 rebase 到上游 master 的升级流程；本机制是"官方每日快照 + 扩展外挂"的轮换。两者可共存：日常用 AB 轮换，偶发的 master 整合才走 dsh-upgrade。
