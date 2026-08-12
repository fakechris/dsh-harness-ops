# AGENTS.md — dsh-harness-ops 仓库速记

本仓库是 DSH 运维插件/技能集合（GitHub: `dsh-external/dsh-harness-ops`）的主 checkout。

- **主 checkout 目录名是历史遗留的 `dsh-skill-snapshot-ab`，不要改名**；开发 worktree 在 `.worktrees/<name>`（通用纪律见全局 `~/.dsh/AGENTS.md` L5，不在此重复）
- **技能**（`skills/`，每个子目录一个）：dsh-session-recovery / dsh-snapshot-ab / dsh-web-doctor / dsh-web-guard。SKILL.md 规范（frontmatter + <500 行 + references/）见全局 L2；description 中英双语（L6）
- **插件**（`plugins/`）：dsh-restart-recover（bundle 插件：`dependencies`/`peerDependencies` 声明为空是设计，prepare 构建走 DSH 工具链，不能裸 tsc）
- **安装/升级**：`scripts/install.sh` / `scripts/update.sh`（dsh-web-guard 装成 launchd/systemd 守护，web 死后自动拉起）
- **文档**：README 与 docs/ 中英双语（`README.md` + `README.en.md`，切换行 `[English](README.en.md) | 中文`）；`VERSION`/`CHANGELOG.md` 随发布更新
- **发布**：推到 GitHub 即分发；仓库 description/topics 按全局 L2 合规
- **提交**：全局 L4（branch → push → PR → squash merge，禁止 main 直推）；3080 加载主 checkout 的构建产物，worktree 内构建只服务开发期验证（L5）
