# RELEASE 规范 —— DSH 插件发布机制研究 + dsh-harness-ops 发布规范

> 本文回答三个问题：**每次更新要重新打包吗？版本号/发布机制是什么？以后要进 npm 吗？**
> English: [RELEASE.en.md](RELEASE.en.md)

---

## 一、官方机制（研究结论，基于官方文档 + 实测）

### 1.1 两个概念

官方插件生态建立在两个概念上（[官方发布指南](../.dsh/source/slot-a/docs/user/develop/basic/publish.md) 原话"Two concepts, two manifests"）：

| 概念 | manifest | 回答的问题 |
|---|---|---|
| **bundle**（插件） | `dsh.bundle`（patch 文件） | "这个包贡献什么"——一个配置层（cordis.patch.yml），由 npm 包分发 |
| **profile**（可运行组合） | `dsh.profile`（bundles 列表） | "哪些 bundle 按什么顺序组成这个运行实例" |

bundle 是**作者分发**的单元；profile 是**用户启动**的单元。`dsh plugin` 命令维护 profile。

### 1.2 安装命令：`dsh plugin --profile <name> <pnpm 参数>`

官方实现：`dsh plugin` 把参数**原样转发给 pnpm 在 profile 目录执行**（`apps/cli/src/args.ts`：`Manage a profile's plugins: forward args to pnpm inside the profile directory`）。因此四种安装来源都合法：

```sh
dsh plugin --profile web add .                      # 本地 checkout（pnpm link:）
dsh plugin --profile web add github:you/repo#<sha>  # git 直装（拉源码，非产物）
dsh plugin --profile web add your-npm-package       # npm 包（预构建 lib/）
dsh plugin --profile web add ./pkg-0.1.0.tgz        # pnpm pack 的 tarball
```

**实测验证**（本机 2026-08-12）：`dsh plugin --profile demo add .` 自动初始化 profile、
`pnpm link` 插件、把 bundle 追加进 `dsh.profile.bundles`；`dsh --profile demo --dump-config`
显示 `# == @deepseek-ai/dsh-restart-recover` 层。生产 `web` profile 已按此机制管理
（bundles: `dsh-base / dsh-web-app / dsh-track / dsh-restart-recover`）。

### 1.3 git 直装的"构建脚本陷阱"（官方原文 "the build-script catch"）

git 安装拉的是**源码不是构建产物**：TypeScript 包到达时没有 `lib/`，无法加载。两边各需一步：

- **作者**：bundle 包必须带 `prepare` 脚本（pnpm 在 git 安装后运行），**自包含**地构建入口
  （不依赖 dev-only 环境，如兄弟 monorepo checkout）。官方示例：[turtle-ui](https://github.com/deepseek-harness/turtle-ui)。
- **用户**：pnpm ≥10 默认拒绝执行 git 依赖的 `prepare`，需在 profile 的 `pnpm-workspace.yaml`
  显式 `allowBuilds`，并建议 **pin commit**（`github:you/repo#<sha>`）防止后续 push 静默改变行为。

**免构建权限的替代**（官方原文 "If you would rather not ask users for the allowance"）：
- **发布 npm**：`pnpm publish` 时带构建好的 `lib/`，`dsh plugin add your-package` 装预构建代码；
- **发 tarball**：`pnpm pack`，用户 `dsh plugin add ./pkg.tgz`。

### 1.4 官方立场：registry 非必需

> "Publishing to a registry is not required — users can install straight from a git host."
> （官方 publish.md 原文）

npm registry 现状：`@deepseek-ai/*` scope 在 npm 上**无任何包**（`npm view @deepseek-ai/dsh-track` → 404）。
官方主仓库 version 为 `0.0.1-rc.1`（pre-release），版本锚点是**快照日期分支**
（`snapshots/YYYYMMDDTHHMMSSZ-*`），无 semver tag 惯例。

### 1.5 bundle 格式（官方模板 plugin-template 确认）

`package.json` 关键字段：`dsh.bundle.patch`（指向 cordis.patch.yml）、`main`/`exports`（lib/）、
`files`（发布内容白名单）、`private: true`（**默认不发布 npm**）、`prepare` 脚本（git 安装自动构建）、
`verify:self-contained` 脚本（自包含验证）。

### 1.6 bundle 依赖与产物（官方 make-dsh-plugin / bundle-plugins.md 确认）

- **依赖声明为空是设计**：bundle 插件 `dependencies` 不声明 `@deepseek-ai/*`（由 profile 的
  pnpm 闭包挂载时注入；声明了公共 npm 解析不到反而失败）。repository 插件相反——两类相反。
- **git 源安装语法**：`dsh plugin --profile web add "github:owner/repo#<commit>&path:/<子目录>"`，
  指向 bundle 包目录（`&path:/` + 前导 `/`）；不要指向仓库根。
- **产物两条路线**：
  - **产物入库（官方推荐）**：`lib/` 等 `files` 声明内容提交进仓库 → git 安装不跑构建，
    真一行安装，零额外步骤；
  - **prepare 自构建（备选）**：`prepare` 脚本在 git 安装时构建——但 pnpm ≥10 默认阻止，
    用户需在 profile `pnpm-workspace.yaml` 的 `allowBuilds` 放行（多一步交互）。
- 本仓库 `plugins/dsh-restart-recover` 当前走 **prepare 路线**（`lib/` 在 .gitignore）；
  本机/org 内用 `install.sh`（本地 checkout + pnpm link）无 allowBuilds 摩擦，
  若未来公开 git 源分发再切"产物入库"。

---

## 二、dsh-harness-ops 发布规范（本仓库）

### 2.1 回答"每次更新要重新打包吗？"

**不需要手工打包。** 本仓库是**混合仓库**（4 个 skill + 1 个 bundle 插件），各走各的机制：

| 组件 | 类型 | 分发/安装机制 | 更新动作 |
|---|---|---|---|
| `skills/dsh-snapshot-ab`、`dsh-web-guard`、`dsh-session-recovery` | skill | 目录复制到 `~/.dsh/skills/`（官方扫描目录） | `install.sh` 重拷 |
| `plugins/dsh-restart-recover` | bundle 插件 | `dsh plugin --profile web add .`（pnpm link + bundle 注册） | `update.sh` 重建 lib + 重装 |

bundle 插件自带 `prepare` 脚本（`node scripts/dsh-env.mjs tsc -p tsconfig.json`），
**git 拉源码后自动构建 lib/** —— 这正是官方 git 直装的要求。skills 无需构建。

**`bash scripts/update.sh` 一条命令完成全部更新**：`git pull --ff-only → 重建插件 lib → 重跑 install.sh`。

### 2.2 版本号管理

- 根目录 `VERSION` 文件（SemVer，当前 `0.3.0`）
- git tag：`vX.Y.Z`（`v0.3.0`），每个发布打一个
- `CHANGELOG.md`：每个版本一节，链接 squash-merged PR
- 规则：`fix:` → patch；`feat:` → minor；破坏性 → major（bump 时机：合并后、tag 前）

### 2.3 发布流程（正规化后）

```sh
# 1) 改动走 PR（squash merge，见 AGENTS.md L4）
# 2) merge 后 bump 版本 + 更新 CHANGELOG（单独小 PR 或随最后改动）
echo "0.3.0" > VERSION   # 或 minor/major
# 3) 打 tag 发布
git add VERSION CHANGELOG.md && git commit -m "chore(release): v0.3.0"
git tag v0.3.0 && git push origin main --tags
# 4) 消费端更新
bash scripts/update.sh
```

**发布 = git push + tag**（仓库本身即分发单元）；bundle 包（`plugins/dsh-restart-recover`）另可发 npm（见 §三 2026-08-13 更新）。

### 2.4 安装

```sh
git clone https://github.com/dsh-external/dsh-harness-ops.git
bash scripts/install.sh          # skills → ~/.dsh/skills + bundle → web profile
bash skills/dsh-web-guard/scripts/install.sh   # 可选：自愈守护
```

---

## 三、以后要进 npm 吗？

### 结论（2026-08-13 更新）：bundle 包已迁 `@fakechris` scope、可发 npm；skills 仍是目录机制。

> 更新：用户拥有 `@fakechris` / `@turnkeyai` 两个 npm scope。`plugins/dsh-restart-recover`
> 已改名为 `@deepseek-ai/dsh-restart-recover` + `publishConfig.access=public`，`npm pack`
> 验证通过（lib + cordis.patch.yml），发布命令：
> ```sh
> cd plugins/dsh-restart-recover && npm publish --registry=https://registry.npmjs.org
> ```
> 消费端：`dsh plugin --profile web add @deepseek-ai/dsh-restart-recover`（npm 预构建，无需
> allowBuilds）。skills（dsh-snapshot-ab / dsh-web-guard / dsh-session-recovery / dsh-web-doctor）
> 仍是 `~/.dsh/skills/` 目录机制，不进 npm，走 `bash scripts/install.sh`。

历史理由（保留）：

理由：

1. **官方明确 registry 非必需**（1.4 节原文）——GitHub 即分发单元，私有 org 内完全够用。
2. **混合仓库的 npm 化局限**：skills 是**目录机制**（`~/.dsh/skills/` 扫描），
   **无法用 npm 分发**；能 publish 的只有 `plugins/dsh-restart-recover` 这一个 bundle 包。
   为一个子组件引入 npm 发布 = 多一套 semver/CI/权限管理，收益有限。
3. 目前 `private: true` + profile pnpm link 已经满足本机/团队安装。
4. **官方自身的 npm 是私有 restricted scope**（2026-08-12 调研确认）：官方主仓库发布到
   npmjs.com 的 `@deepseek-ai` **私有 scope**（211 包、`0.0.1-rc.1`、NPM_TOKEN 访问、
   GitHub Actions 从 `dsh-v*` tag 手动 dispatch）。公共 npm 全 404 是 restricted 设计，
   不是"没发布"。**第三方（我们）目前拿不到私有库访问权**（官方 devDep
   `dsh-repository-plugin` 在私有库都仍 404），所以公共/私有 npm 对第三方插件都不现实。

### 何时值得进 npm（触发条件，满足其一再动）：

- **官方开放私有库给 org**（未来主流分发据官方决策笔记是私有 npm 库
  `npx -p @deepseek-ai/dsh@0.0.1-rc.1 dsh web`）——届时跟随官方通道；
- **公开分发** bundle 给 org 外用户（git 安装要用户 `allowBuilds`，npm 预构建免这一步）；
- 需要 **semver range 依赖解析**（profile 里写 `^0.3.0` 而不是 pin commit）；
- 需要 **pnpm pack tarball** 给离线环境。

届时只 publish `plugins/dsh-restart-recover`（去掉 `private: true`、`pnpm publish` 前构建 lib/），
仓库级版本（VERSION/tag）与 npm 包版本可各自独立演进。

---

## 四、hub 收录（发布后自动生效，注意合规）

- **机制**（dsh-external/hub，私有）：`catalog.source.json`（人工分类层）+ `scripts/generate.mjs`
  （自动层：GitHub API 抓 description/language/updated，**Agent Loop 每 2 小时刷新**，当前 241 仓库）。
- 未在 `catalog.source.json` 人工分类的仓库会生成"请加入分类"警告——分类不是发布必需，但建议补。
- **description / topics 合规**（官方模板）：
  - description 一行「是什么 + 怎么装」，模板：
    `DSH plugin: <what it does>; install via <install-command>`；
  - topics：生态标签（`dsh` / `deepseek-harness`，bundle 加 `dsh-bundle`）+ 功能标签，共 3–6 个；
  - `gh repo edit <owner>/<repo> --add-topic ...`。
- **现状自查**（2026-08-12）：dsh-harness-ops topics 6 个合规
  （`deepseek-harness` `dsh` `ops` `restart` `self-heal` `snapshot-ab`）；description 有"是什么"
  缺"怎么装"——下次修订补 `install via: git clone + bash scripts/install.sh`。
  仓库在 hub 自动层可见，人工分类尚未加入 catalog.source.json。

---

## 四、相关参考

- 官方发布指南（权威）：`~/.dsh/source/slot-a/docs/user/develop/basic/publish.md`（.zh.md 中文）
- 官方插件模板：`dsh-external/plugin-template`（make-dsh-plugin skill 引用）
- 插件生态基建：`dsh-external/plugin-registry`（make-dsh-plugin skill / hub 收录）
- 官方 cordis 教程：`~/.dsh/source/slot-a/docs/cordis-tutorial/`（01–07 章）
