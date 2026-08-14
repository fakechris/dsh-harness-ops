# DSH 快照 A/B 轮换 — npm 生态版机制设计

> 日期：2026-08-14 · 作者：dsh-snapshot-ab skill
> 背景：官方从私有快照发布（`dsh2026/test-fakechris` snapshots/*）转为**公开正式仓库
> （`deepseek-ai/deepseek-harness`）+ npm 发布**。本设计把 A/B 轮换从「源码快照」转型为
> 「npm 包形态」，与官方 npm 发布节奏精确同步。

---

## 一、官方发布机制（已实证，2026-08-14）

### 1.1 npm 是唯一发布真相

- 官方发布管线：`scripts/release/`（bump → 提交 → CI pack → 发布 npm），版本号写入 git，
  但 **npm registry 才是消费端标准**（官方 README 第一运行方式 `npx @deepseek-ai/dsh web`）。
- **npm 领先 master**：实测 npm `0.1.0-rc.6`（2026-08-13T12:35Z）发布时，master 最新
  release commit 是 `0.1.0-rc.5`（10:49Z）——rc.6 的 commit 尚未合并/推送 master。
- **无 git tag**：官方 `gh api tags` 为空（Agent Note 声明的 `dsh-v<version>` tag 未实际创建）。
- 结论：**跟随 npm dist-tag，不能跟随 git master**。

### 1.2 dist-tag 语义（官方 publish 规则）

- prerelease 版本（如 `0.1.0-rc.6`）→ `--tag next`
- 正式版（如 `0.1.0`）→ `--tag latest`
- 消费侧：日常用 `next`（最新 rc），正式发布后切 `latest`。

### 1.3 消费形态（官方 README + 生态）

- 官方包 `@deepseek-ai/dsh`（元包）→ `npx @deepseek-ai/dsh web`
- 生态扩展（我们的 dsh-track）→ npm 包 `@fakechris/dsh-track` → `dsh plugin add`
- 官方 `@deepseek-ai/*` 子包（dsh-session/dsh-tools/dsh-llm/cordis…）全部在 npm，profile 闭包注入。

---

## 二、转型：源码槽 → npm 包槽

### 2.1 为什么不能保留源码槽

| 维度 | 源码槽（旧） | npm 包槽（新） |
|---|---|---|
| 内容来源 | git 快照分支 / master | npm tarball（`@deepseek-ai/dsh@<ver>` + 闭包） |
| 版本对应 | master 落后 npm，无 tag | **精确对应 npm 版本** |
| 构建 | 需 pnpm install + build:lib + build:web | **即装即用**（npm 包已编译） |
| 扩展挂接 | relink node_modules → 槽源码 packages/ | 扩展 npm 包装入 profile |
| 验收 | staging 起 lib/bin.js + 冒烟 | 同左（profile 声明换成 npm 包） |

### 2.2 新布局

```
~/.dsh/source/current          符号链接 → 生效槽（保留，语义不变）
~/.dsh/source/slot-a/          槽 = 独立 DSH_HOME（profiles/ + node_modules）
  └── profiles/web/            bundles: @deepseek-ai/dsh-base + dsh-web-app + <ext-npm 包>
~/.dsh/source/slot-b/          另一版本（回滚点）
~/.dsh/npm-cache/              npm pack 缓存（tarball，避免重复下载）
```

- 槽不再是 git worktree，是**两个隔离的 DSH_HOME 目录**，各装一个 npm 版本。
- `current` 符号链接语义不变：切换 = 原子 `ln -sfn`。
- launcher：`~/.local/bin/dsh → current/bin/dsh`（槽内生成 wrapper → npm 闭包 bin.js）。

### 2.3 扩展挂接（npm 形态）

- ab-config `extensions[].npm`（如 `@fakechris/dsh-track`）→ prepare 时 `pnpm add` 进候选槽 profile。
- 兼容：`--source` 手动路径仍走**源码 relink**（保留旧 extension.sh 逻辑）。

---

## 三、命令改造

### 3.1 discover — npm dist-tag 检测

```
ab.sh discover
  → npm view @deepseek-ai/dsh dist-tags   # next / latest
  → 对比 current 槽版本
  → 有更新：打印候选版本 + 变更摘要（npm 无 changelog，展示版本号 + 发布时间）
  → 无更新：up to date
```

### 3.2 prepare — 双模式

```
ab.sh prepare [--source <ref>]   # 默认 npm；--source 走源码
  npm 模式：
    → npm pack @deepseek-ai/dsh@<version> 到缓存
    → 解压为候选槽 DSH_HOME（profiles/web + 依赖闭包）
    → 扩展：pnpm add @fakechris/<ext>@<ver>（extensions[].npm）
    → 槽 launcher 生成（current/bin/dsh → npm bin）
    → staging 冒烟（HTTP 200 + client manifest + e2e）
  source 模式：
    → 保留旧逻辑：checkout master + install + build + relink 扩展 + 冒烟
```

### 3.3 switch / rollback / confirm

- switch：原子 `ln -sfn current -> 候选槽` + 验证 launcher + 重启 web（不变）。
- rollback：current 指回 previousTarget（另一槽 = 旧 npm 版本，保留）。
- confirm：生产 gate（HTTP 200 + manifest + launcher 链）不变。

---

## 四、配置（ab-config.json 扩展）

```jsonc
{
  "upstream": "npm:@deepseek-ai/dsh",          // 不再用 git URL
  "npm": {
    "distTag": "next",                          // 跟随 next（rc 流）；正式版后改 latest
    "registry": "https://registry.npmjs.org/",
    "cacheDir": "~/.dsh/npm-cache"
  },
  "extensions": [
    {
      "name": "dsh-track",
      "npm": "@fakechris/dsh-track",            // npm 形态包名（不写死，可配任意 scope）
      "profile": "web",
      "skills": ["skills/dsh-track"],
      // 旧 relink/tsconfig/build 字段保留，仅 --source 源码模式用
    }
  ]
}
```

---

## 五、兼容与迁移

- **旧源码槽保留**：slot-a 已是官方 master（0.1.0-rc.5）——`--source` 模式可直接用它，
  不浪费。
- **回滚链**：确认前旧槽（slot-b 私有快照 20260812 或 npm 旧版）保留。
- **SKILL.md / 用户引导**：更新「何时用」触发词（官方发 npm 新版 → AB 轮换）。
- **双语**：机制文档 + SKILL.md description 中英同步。

---

## 六、遗留问题

1. npm 包闭包体积（`@deepseek-ai/dsh` 依赖 ~50 子包）——槽初始化比 git checkout 慢？
   实测 `npx -p @deepseek-ai/dsh@0.1.0-rc.6 dsh --version` 首次 ~30s，可接受。
2. `--source` 与 npm 模式的「当前版本」对比基准不同（git tip vs npm version）——
   discover 需按当前槽的形态分别判断。
3. 官方若恢复打 tag（`dsh-v<version>`），可加 `--tag` 源码模式精确对应 npm 版本。
