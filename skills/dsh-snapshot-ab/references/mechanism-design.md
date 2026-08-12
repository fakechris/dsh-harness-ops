# DSH 快照 A/B 轮换 — 机制设计与研究记录

> 日期：2026-08-10 · 作者：dsh-snapshot-ab skill
> 背景：官方 `dsh2026/test-fakechris` 每天发布一个新的 snapshot 分支；我们在旧快照上开发
> 扩展（dsh-track），不能每天直接 rebase/切换（风险大），需要一个"A/B 双槽 + 验收后切换"的机制。

---

## 一、研究结论

### 1.1 上游的发布形态（已实证）

`git ls-remote https://github.com/dsh2026/test-fakechris` 显示官方以**每日快照分支**发布：

```
refs/heads/snapshots/20260809T140917Z-a6bb5a95ba    ← 我们正在运行的旧快照
refs/heads/snapshots/20260810T155924Z-8ec407cd64    ← 当天新快照（已存在）
refs/heads/dsh-staging/20260809T141636Z             ← 官方 staging（含后续 fix）
```

命名 = `snapshots/YYYYMMDDTHHMMSSZ-<sha>`，时间戳字典序即时间序。**每天一个**，这是本机制的
输入。本地当前运行版本 = `dsh-staging/20260809T141636Z`（20260809 快照 + 一个本地修复提交
`fix(loader): serialize entry creation...`），通过 `~/.dsh/source/current` 符号链接生效。

### 1.2 安装布局（dsh-customize 惯例，已实测）

```
~/.local/bin/dsh                    PATH launcher（符号链接）
  → ~/.dsh/source/current/bin/dsh    current = 符号链接 → 生效的 worktree
      → ~/.dsh/source/staging-*      各 staging worktree（git worktree，共享对象库）
~/source/test-fakechris             主克隆（唯一真实 clone，对象库 + worktree 宿主）
~/.dsh/profiles/{web,tui}            profile：bundles + 扩展 link 依赖 + cordis.patch.yml
~/.dsh/skills/                       用户 skill（dsh-track、dsh-session-recovery…）
```

关键事实：**`current` 是一个符号链接**，launcher 永远解析它 → 切换 = 一次原子 `ln -sfn`。
`bin/dsh` 是 shell 脚本，解析自身路径后用 tsx 从该 checkout 的源码直接运行 → 直接执行
`<槽>/bin/dsh web --port N` 即可在不动 `current` 的前提下冒烟候选槽。

### 1.3 已有官方机制（为什么不够）

- `skills/dsh-upgrade`：把个人 staging rebase 到上游 **master**，单 staging + `current` 原子
  切换 + recovery ref。它解决"整合到主干"，**不解决**"官方每日快照 + 扩展外挂、不 rebase"。
- `skills/dsh-customize`：布局解析与 `.agents/merge.lock` 纪律（本机制复用了它的解析链）。
- `skills/dsh-upstream-customization`：把个人定制分类并向上游提 PR（不相关）。

官方 `dsh-upgrade` 的存在说明 `current` 符号链接 + worktree 的原子切换是**官方认可的模式**；
本机制把它推广为双槽（蓝绿），且槽内容 = 官方快照原样 + 扩展外挂，而非 rebase 结果。

### 1.4 社区有没有类似的 skill？（已用本机 gh token 查证：无同类，但有相邻项目）

> 勘误：早前用**匿名** GitHub API 查 `dsh-external` 得到 `public_repos = 0`，据此误判"无任何仓库"。
> 用本机 `gh`（账号 fakechris，token 有 `read:org`/`repo` 权限）复查：**该 org 实际有 215 个私有仓库**（0 公开），
> 是内测插件生态，一直在活跃发布（仅 2026-08-10 一天就有大量新仓库）。

- 检索全部 215 个仓库（`gh repo list dsh-external --limit 300`）+ `hub` 仓库的统一 `catalog.json`（171KB，全组织索引）：
  **没有任何仓库实现"A/B 双槽 + 每日快照轮换 + 扩展重挂接 + 验收后切换"**。
- 找到两个**相邻**项目（不是同类，但值得交叉引用）：
  1. `dsh-external-research/.agents/skills/mainline-compat`：**生态兼容性监控引擎**——
     拉当日 mainline 最新快照分支，对比 org 全部仓库的锚定/补丁/seam/peerDeps 四维，产出按日兼容性报告。
     ⚠️ 它监控"插件 vs 当日 mainline 是否兼容"，**不**轮换 harness 本身、不重建扩展、不做 A/B 双版本切换。
  2. `dshx-update-check`：commit SHA 对比**检测**插件更新（只检测不自动更新）。
- 结论：**A/B 快照轮换机制是空白，自建**（本 skill）。与 `mainline-compat` 互补：
  那个回答"插件还能不能用"，本机制回答"怎么安全地切到新版本"。

### 1.5 扩展（dsh-track）与 harness 的耦合点（已实测）

`~/source/dsh-involute`（包名 `@deepseek-ai/dsh-track`）硬编码 `~/.dsh/source/current` 于：

| 位置 | 内容 |
|---|---|
| `package.json` scripts | tsc/tsdown/vitest 从 `current/node_modules/...` 解析 |
| `tsconfig.json` | `paths` / `typeRoots` 全部指向 `current/packages/*/lib/types` |
| `vitest.config.ts` | `const DSH = '/Users/chris/.dsh/source/current'` + alias |
| `node_modules/@deepseek-ai/*`、`node_modules/cordis` | 符号链接指向 `current/packages/...`、`current/vendor/cordis` |

要"先对着 B 槽构建测试、再切换"，就必须参数化。本机制做了最小改造（见下文"扩展参数化"），
默认行为不变（`DSH_SOURCE` 缺省 = `current`），日常开发零感知。

---

## 二、机制设计

### 2.1 概念

- **两个槽** `slot-a` / `slot-b`（`$DSH_SOURCE/slot-*`，git worktree，分支 `dsh-ab/a|b`）。
- **current**：符号链接，指向当前生效槽。**恰好一个槽是 current**；另一个槽 = 上一个版本
  （回滚点），下个周期被回收为候选。
- **扩展在槽外**，通过符号链接 + `DSH_SOURCE` + 生成的 `tsconfig.ab.json` 指向目标槽。
- **状态机**（`ab-state.json` 的 `phase`）：
  `idle → preparing → prepared → switched →(confirm)→ confirmed(idle 语义)`；
  `switched` 且未 `confirm` 时，**回滚槽禁止回收**（唯一保底）。

### 2.2 命令（`scripts/ab.sh`）

| 命令 | 作用 | 改什么 |
|---|---|---|
| `status` | 布局/槽/phase/运行中 web/扩展脏文件 | 只读 |
| `discover` | fetch 上游、列快照、算候选、diff stat；候选比当前新时附官方 changelog（新增 agent notes） | 只 fetch |
| `notes [--from \|--to <ref>] [--full] [--json]` | 打印两个快照间的官方 changelog（`.agents/notes/implemented` 新增笔记；默认 运行 tip → 最新，无新快照时显示当前运行对） | 只 fetch |
| `init --yes` | 把当前运行版本收编为 slot-a（新 worktree + 装依赖 + **完整构建** build:lib+build:web + 重指 current，**不重启**） | current |
| `prepare [--slot a\|b]` | 候选槽：检出快照 → install → build → 扩展挂接构建测试 → 冒烟（3081） | 仅候选槽 |
| `verify` | 对 prepared 候选重跑扩展测试 + 冒烟 | 只读 |
| `switch --yes` | `ln -sfn current -> 候选槽` + launcher 验证 + 重启 web | current + 服务 |
| `confirm` | **生产验收 gate**（2026-08-11 事故后）：HTTP 200 + 进程来自当前槽 + launcher 链 + client manifest 四项实测全过才 confirmed=true（解锁回滚槽回收） | state + 实测 |
| `rollback --yes` | current 指回 `lastSwitch.previousTarget` + 重启 web | current + 服务 |
| `cleanup [--yes] dir...` | 列出/移除旧 worktree（绝不删 current） | worktrees |

`--yes` / `AB_APPROVED=1` 表示"用户已明确批准"（agent 在 switch/rollback/init 前必须先拿到
用户的明确同意，并写 handoff —— 因为重启 `dsh web` 会终止发起者的会话）。

### 2.3 prepare 流水线（验收门）

1. 锁（`~/.dsh/source/.ab.lock`，python3 fcntl；macOS 无 flock）。
2. 守卫：候选槽 ≠ current；`switched` 未 `confirm` 时拒绝回收回滚槽（除非 `--force`）。
3. 检出：worktree 不存在则 `git worktree add -B dsh-ab/<s> <dir> <snapRef>`；存在则
   `checkout -B` + `clean -fdx`（每快照全新依赖）。
4. `pnpm install --frozen-lockfile`（锁定文件保证与快照一致）。
5. `npm run build:lib`（host+client 的 lib/ 类型与运行时，扩展编译依赖）+
   `npm run build:web`（GUI bundle；`--skip-web` 可省）。
6. 扩展挂接（每个配置项）：
   - relink `node_modules/@deepseek-ai/*`（含 `@deepseek-ai/cordis` → 候选槽 vendor/cordis；20260811+ 官方用 scoped 名，无裸 `cordis` 包）→ 候选槽（记录旧目标，失败还原）；
   - 生成 `tsconfig.ab.json`（替换 tsconfig 中的 current 前缀 → 候选槽）；
   - `DSH_SOURCE=<候选槽> DSH_TSCONFIG=tsconfig.ab.json` 跑 typecheck/build/test；
   - 同步 skills → `~/.dsh/skills/`。
6.5 运行时依赖 gate（2026-08-11 事故后新增）：`ext_check_runtime_deps` 扫描扩展构建产物
   的裸 `@deepseek-ai/*` / `cordis` import，凡扩展 node_modules 缺失的**直接 prepare 失败**
   并提示补 `extensions[].relink`——tsconfig paths / vitest alias 解析不了这个洞，只有生产
   纯 node ESM 诚实（漏链在 dryrun 即挂，而不是切换后 ERR_MODULE_NOT_FOUND）。client bundle
   分块（`lib/client/`）除外：client 侧由 profile pnpm 闭包提供、不经 relink。
6.6 槽 launcher 补位：20260811+ 快照删了 `bin/dsh`，prepare 用 `ab_ensure_slot_launcher` 给
   无 launcher 的槽生成 `bin/dsh` 包装器（指向编译产物 `apps/cli/lib/bin.js`），保证切后
   `dsh` 命令链（`~/.local/bin/dsh → current/bin/dsh`）不断。
7. 冒烟（**生产等价路径**，2026-08-11 事故后）：`ab_boot_cmd` 启动——优先 `bin/dsh`（有则）
   或 `apps/cli/lib/bin.js` 纯 node ESM（0811+ 生产入口），**不用 tsx 兜底做 gate**（tsx 读
   tsconfig paths，会掩盖漏链）；`--workspace-root` 仅探测（final 已删该标志，探测到才传）；
   轮询 HTTP 200 + smokePaths + **client-manifest 断言**（`web.smokeClientIds`：抓 `/` 解析
   `window.__DSH_BOOT__`，逐一断言扩展 client id 在场）；`--keep` 保留给人工浏览器验收。
   > 教训（2026-08-11 事故）：仅 HTTP 200 会漏掉上游对 package.json 声明键的改名
   > （20260810 快照把 `dshClient` 改为 `dsh.client`）——host 插件照常加载、扩展测试全绿、
   > 冒烟 200，但扩展的 client 行被静默丢弃 → 面板消失。manifest 断言补上了这个洞。
   > 事故二：dryrun 全绿却生产起不来——扩展 build/test/冒烟各自被 paths/alias/tsx 的"更宽容
   > 解析"接住，只有生产纯 node ESM 老实查 node_modules（dsh-llm relink 漏链）。冒烟必须走
   > 与生产相同的解析路径（见 6.5/7），tsx 只能兜底。
8. 全绿 → phase=`prepared`，证据（快照/tip/扩展结果/时间）写入 state；任一失败 → 还原
   relink/tsconfig、phase 回 `idle`、**current 与运行服务不动**。

### 2.4 切换与回滚

- 切换：`ln -sfn <候选槽> current` → `dsh --version` 验证 launcher → 重启 web（TERM 旧 PID
  → 等端口释放 → nohup `dsh web` → 轮询 3080 HTTP 200）→ state 记录 `lastSwitch.previousTarget`。
- 回滚：`current` 指回 `previousTarget` → 重启 → phase=`rolled-back`。旧槽（上一个版本）
  保持完整可回滚；`cleanup` 只列不删，删除留给人。

### 2.5 扩展参数化（本机制对 dsh-track 的最小改造）

- 新增 `scripts/dsh-env.mjs`：`DSH_SOURCE`（默认 `~/.dsh/source/current`）解析
  `node_modules/.bin/<cmd>` 并 spawn；`package.json` 的 build/test/typecheck 全部改经它，
  `DSH_TSCONFIG` 可选指定槽专用 tsconfig。
- `vitest.config.ts`：`DSH_SOURCE ?? '~/.dsh/source/current'`。
- `.gitignore`：追加 `tsconfig.ab.json` / `tsconfig.ab-*.json`。
- 行为兼容：不设 `DSH_SOURCE` 时与改造前完全一致（已回归验证 typecheck+build）。

### 2.6 为什么用 worktree + 共享对象库而不是 clone

- `git worktree` 与官方 `dsh-upgrade` 同构（同一对象库，`current` 切换点不变）；
- 快照分支 fetch 进主克隆即可，槽之间、槽与主克隆零重复下载；
- 一个 worktree 一份 checkout，互不干扰，`clean -fdx` 只清自己。

---

## 三、验收标准（本机制自测）

- [x] `ab.sh status` 正确解析 launcher → current → 主克隆，显示槽/phase/扩展脏文件。
- [x] `ab.sh discover` fetch 上游并正确选出 `snapshots/20260810T155924Z-8ec407cd64` 为候选。
- [x] `ab.sh init --yes` 收编当前版本为 slot-a，重指 `current`，运行中服务不受影响（HTTP 200）。
      *BUG 修复（2026-08-11）：init 只跑了 `pnpm install` 没跑构建 → 新 worktree 缺失全部
      `lib/` 与 `apps/web/dist`，`dsh web` 无法正常服务。已改为 install + 完整构建后才重指
      current。*
- [x] 扩展参数化无回归（默认 DSH_SOURCE 下 typecheck + build 通过）；已被提交
      （dsh-involute `5a97f78 chore(ab): parameterize build/test toolchain...`）。
- [x] `ab.sh prepare --slot b` 全链路（20260810 快照：检出/install/build/扩展/冒烟）→ 记录证据。
      *首次实跑曾暴露并修复三处机制 bug：per-slot tsconfig 写到错误 cwd、失败路径未定义
      （`goto_fail` 作用域）、web 冒烟 curl 对 000 的处理与 `--workspace-root` 标志在
      20260810 快照被上游移除（验收真实捕获到上游 CLI 变更）。均已修复并复跑通过。*
- [x] `ab.sh verify` 对 prepared 候选重跑扩展测试（75/75）与冒烟（HTTP 200）。
- [ ] `ab.sh switch --yes` 原子切换 + web 重启 + 200（需用户批准后执行）。
- [ ] `ab.sh rollback --yes` 回到上一版本（需用户批准后执行）。
