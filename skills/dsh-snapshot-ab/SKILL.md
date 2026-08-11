---
name: dsh-snapshot-ab
description: 每日上游快照的 A/B 双槽轮换机制。上游官方（dsh2026/test-fakechris）每天发布新的 snapshots/YYYYMMDDTHHMMSSZ-* 分支时，在保留当前运行版本（A 槽）不动的前提下，把新快照检出到另一个槽（B 槽），重新挂接我们的扩展（如 dsh-track），构建+验收通过后才原子切换 current 符号链接；下一天角色互换。当用户说"官方发了新 branch / 切换新快照 / 升级到今天的 snapshot / AB 双版本轮换 / 跑一下 daily 快照更新"时使用。
---

# DSH Snapshot A/B Rotation（快照 A/B 轮换）

上游官方每天发布一个新的 snapshot 分支（`snapshots/YYYYMMDDTHHMMSSZ-<sha>`），我们不做 rebase 式升级，而是把官方快照**原样**放入一个槽，在它之上重新挂接我们的扩展，验收通过再切换。两个槽 A/B 轮流当"当前版本"，任何时刻都有一个未动的旧版本可回滚。

## 何时用

- 官方发布了新快照，要把运行版本换成新的（每天例行）。
- 需要评估某个快照对我们扩展（dsh-track 等）的兼容性（构建/测试/冒烟）。
- 需要回滚到上一个快照。

不要用本 skill 做 rebase 到 master 的升级（那是 `dsh-upgrade`）、或修改 harness 源码（那是 `dsh-customize`）。

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
2. **`ab.sh discover`** — fetch 上游，列出快照分支，指出下一个候选。人工（agent）阅读 snapshot diff，判断上游这天的变化对扩展/我们的使用是否有影响（可参考已有的 snapshot-diff 研究流程）。
3. **`ab.sh prepare [--slot b] [--skip-web]`** — 在**非当前槽**执行完整流水线：
   - 检出候选快照（worktree reset / 新建）→ `pnpm install --frozen-lockfile` → harness `build:lib`（+`build:web`，除非 `--skip-web`）。
   - 扩展挂接：relink node_modules → 候选槽；生成 `tsconfig.ab.json`（把扩展 tsconfig 里的 `/Users/chris/.dsh/source/current` 前缀替换为候选槽）；用 `DSH_SOURCE=<候选槽>` 跑扩展的 typecheck/build/test；同步 skills 到 `~/.dsh/skills/`。
   - 候选槽 `bin/dsh web` 在**staging 端口**（默认 3081）冒烟：HTTP 200 + 配置的 smokePaths；`--keep` 保留 staging 服务器供人工浏览器验收。
   - 任何一步失败：恢复扩展 relink/tsconfig，`current` 不动，phase 回 `idle`，**不切换**。
   - 成功后 phase=`prepared`，证据写入 ab-state.json（快照、tip、扩展构建结果）。
4. **`ab.sh verify`** — 对已 prepared 的候选重跑扩展测试 + web 冒烟（不改状态），用于复查。
5. **人工验收**（不可跳过）：审查 prepare 证据；必要时用 **`ab.sh stage --slot b --port 3082 [--keep --yes]`** 在 staging 端口手工检查。`stage` 会**检测已有 web 实例**：若生产在跑，会警告"第二个实例共享 ~/.dsh、只读查看"并要求用户 `--yes` 明确确认后才启动；不带 `--yes` 拒绝启动。**拿到用户明确同意后再切换**。
6. **切换**：
   - 先写 handoff 说明（`dsh web` 重启会终止当前 agent 会话本身）。
   - **`ab.sh switch --yes`** — 原子 `ln -sfn current -> 候选槽` → 验证 launcher 可启动 → 重启 web（自动杀旧 PID、nohup 启动、轮询 HTTP 200）→ phase=`switched`、confirmed=`false`。旧槽原样保留 = 回滚点。
   - **装了 `dsh-web-guard` 时**：ab.sh 杀 web 后守护会自动用完整环境拉起新 current（更可靠的兜底）；ab.sh 自己先启动成功则守护不抢。无论谁拉起，**切换后浏览器必须硬刷新（Cmd+Shift+R）**——旧 tab 里是切换前加载的 boot manifest，新 client 插件/面板（如 dsh-track 的 ◆）只在刷新后的页面出现（2026-08-11 实测坑）。
7. **确认稳定**：用户确认新版本可用后 **`ab.sh confirm`**（confirmed=true）。在此之前 `prepare` 拒绝回收回滚槽（除非 `--force`）。
8. 下一天：A/B 角色互换，`prepare` 自动选非当前槽。

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
