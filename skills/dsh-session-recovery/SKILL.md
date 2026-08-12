---
name: dsh-session-recovery
description: "诊断并修复 DeepSeek Harness 会话丢失/消失事故：GUI 侧边栏显示 \"0 sessions\"、会话列表为空、session 全部不见了、或出现 \"corrupt Zstandard session log\" / \"first frame is not exactly one header line\" / \"torn JSONL record\" 等校验错误。覆盖损坏 session 日志（session.jsonl.zstd）的定位与无损修复、备份与回滚、重启 dsh web 前写 handoff、修复后验证。当用户提到会话丢失、session 消失、0 sessions、日志损坏、重启后会话没了、或 session 相关校验报错时，务必使用本 skill，即使问题看起来像是\"系统崩溃\"或\"integration 校验挂了\" English: diagnose and repair DeepSeek Harness session-loss incidents (0 sessions, empty session list, corrupted Zstandard session log, torn JSONL records); use whenever the user reports lost sessions, 0 sessions, corrupted logs, or session-related validation errors, even when it looks like a crash or a broken integration check。"
license: BSD-3-Clause
metadata:
  version: 1.0.0
  author: fakechris
---

# DSH Session Recovery — 会话丢失事故的定位与无损修复

本 skill 来自一次真实事故（见 `references/incident-20260809-session-loss.md`）：
某个 session 日志被外部工具重压成单帧，导致 DSH 强校验在 `list()` 阶段整体抛错，
**全部**会话在 GUI 里消失（磁盘文件其实都在）。

## 核心心智模型（先理解再动手）

1. **DSH 的 session 日志是强校验的 append-only 格式**（`session-persistence-jsonl`）：
   - 文件 = 多个独立 zstd frame 拼接；
   - **第 1 个 frame 必须恰好只含 header 那一行**（`assertZstdHeaderFrame`）；
   - 后续每个 frame 必须在记录边界结束（换行符结尾），否则报 torn JSONL record；
   - 每个 frame 带 XXH64 content checksum。
2. **`persistence.list()` 一个文件校验失败就整体 throw** —— 一个坏文件能让所有会话从 GUI 消失。
3. **workspace 注册表只在服务启动时构建 session 索引**（`sessionPaths` map）：
   修复文件后**必须重启 dsh web**，运行中的服务不会自动重扫磁盘。
4. **重启可能杀死当前 agent 运行时**（agent 会话由 web 服务托管）——重启前必须写 handoff。

## 触发场景

- 用户说：会话不见了 / 全部没了 / 0 sessions / sessions 消失 / 重启后会话没了。
- GUI 侧边栏 workspace 下显示 "0 sessions"，但磁盘上 session 文件还在。
- 任何 `corrupt Zstandard session log` / `first frame is not exactly one header line` /
  `torn JSONL record` / `seq gap in committed region` / `invalid frame magic` 错误。
- **`SessionFormatUnsupportedError: ... event type "X" ... unknown to this harness and
  not marked ignorable`**（2026-08-11 事故）：日志含当前 harness 不认识的事件类型
  （如旧 dsh-track 的 `track/sync-preview` / `track/decision`，0811 迁移移除），
  读取器拒绝解释。用 `repair-unknown-events.mjs` 给这类事件加 `ignorable: true`
  （官方 vocabulary-growth 通道，对话内容零改动）。

## 诊断流程

所有脚本都在本 skill 的 `scripts/` 下，用 DSH **编译产物**（与运行中服务同款代码）校验。

### 1. 确认磁盘状态（数据是否还在）

```sh
ls ~/.dsh/sessions/                          # 会话根目录（每个项目一个 --path-- 目录）
cat ~/.dsh/storages/workspace.json           # workspace 登记了哪些 sessionId（别改它）
ls ~/.dsh/sessions/--<project>--/<session-id>/
```

文件还在 + workspace.json 还登记 → 是"索引/校验"问题，不是数据丢失。别慌，可无损修复。

### 2. 逐文件定位坏日志

```sh
node scripts/validate-sessions.mjs            # 逐文件校验首个 frame 是否为单行 header
```

- 输出 `FAIL — corrupt Zstandard session log: first frame is not exactly one header line`
  → 该文件帧结构坏了（典型：被 `zstd` CLI 整文件重压成单帧）。
- 输出 `header frame OK` 的文件没问题，**不要动它们**。

### 3. 确认损坏形态（顺手做的证据）

```sh
zstd -lv <坏文件>      # 看 "Zstandard Frames: N" —— 正常应 >1（几十~上百），坏文件常为 1
zstd -dc <坏文件> | wc -l   # 明文行数仍在 = 内容没丢，只是帧结构错
```

## 修复流程（内容零丢失）

```sh
node scripts/repair-session-log.mjs --id <session-id>
# 或 --dir /Users/.../session-xxxx/session.jsonl.zstd
```

脚本自动完成（每一步失败都回滚）：
1. 解压 → 校验 header（id/cwd 必须匹配）、所有行是合法 JSON；
2. **备份**坏文件到工作目录 `backups/`；
3. 用 DSH 同款压缩器（`node:zlib zstdCompress` + `ZSTD_c_checksumFlag=1`）逐行重排：
   frame1 = 仅 header 行；其余按行对齐分帧（每帧以换行结尾）；
4. 两步可逆交换（`rename 原文件 → .orig-in-place`，再 `rename 新文件 → 原位`）；
5. 用 DSH 读取器在**规范路径**上做全量校验（`readPrefix`：无 torn record、seq 连续）
   并通过 `decodeStorageRecord` 对原始明文逐事件比对（**注意：行数 ≠ 事件数**，
   日志里 chunk 行是打包的，`readPrefix` 会解包，事件数可比行数多十几倍）；
6. 全部通过才删除 `.orig-in-place`。

⚠️ **绝不要**用系统 `zstd` CLI 重压 session 日志 —— 它默认整文件单帧，正好触发本事故。
⚠️ **绝不要**手工编辑 session 日志或改动文件里的行。

## 重启 + handoff（重中之重的纪律）

修复后 workspace 索引仍为空，必须重启 `dsh web`。顺序：

1. **先写 handoff**（哪怕只是临时文件）：
   - 症状、根因、已做修复、备份位置、待办、验证方法、回滚方法；
   - 明确写出"重启会杀死当前 agent 运行时"这一事实。
2. 重启：
   ```sh
   sh scripts/restart-dsh-web.sh            # 默认杀旧 PID、nohup 重启、轮询 HTTP 200
   ```
   - 用 `nohup ... &` 启动，保证即使 agent 进程随旧服务一起死掉，新服务也能存活；
   - 启动目录与原服务一致（`dsh web` 的 cwd 会影响默认 workspace）。
3. 验证（重启后立刻）：
   ```sh
   curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/   # 期望 200
   node scripts/check-all-sessions.mjs      # 22/22 全量读取通过
   ```
   并在 GUI 里确认 workspace 下 session 数量恢复、标题正确。

## 排查同类问题的其他线索

- `~/.dsh/storages/session_projcache.json` 存了标题/目标/todos——它没坏的话，恢复后标题都在。
- 服务进程：`lsof -iTCP:3080 -sTCP:LISTEN`；启动方式看 `~/.zsh_history` 里的 `dsh web`。
- DSH 配置：会话根目录在 `packages/bundle/base/cordis.patch.yml`（`root: dshHomePath('sessions')`）；
  API key 等从 `~/.dsh/.env` 读取，新服务自动继承，无需担心环境变量。
- 若 `list()` 抛的不是帧结构错误（如 `legacy flat-file layout` / `encoding mismatch`），
  是文件放错目录/压缩模式冲突，先看 `session-persistence-jsonl` 的 `listArtifacts()` 逻辑再动手。

## 预防

- 需要改 session 日志时，走 DSH 自身写入路径（append/打包），或本 skill 的 repair 脚本。
- 对 `~/.dsh/sessions` 的任何写操作：先备份 → 先校验 → 原子 rename + 可回滚两步交换。
- 定期备份 `~/.dsh/sessions/`（本事故中"修复前的多帧版本"没有副本，只有坏掉的单帧版）。
- **插件不要往 session 日志写自定义事件**：外部插件事件不在 harness 的事件白名单
  （`KNOWN_SESSION_EVENT_TYPES`，编译期生成），读取时无 `ignorable` 标记会**拒读整份日志**
  （2026-08-11 事故：旧 dsh-track 的 `track/*` 事件让 6 个会话打不开）。业务数据写插件
  自己的 storage；观察会话走官方事件（`session/event`）；确需旁路数据必须带 `ignorable: true`
  且不承载关键数据。存量旧日志含未知事件 → `repair-unknown-events.mjs --id <session-id>`。
- 插件扩展 relink（`~/.dsh/source/current` 下的 node_modules 链接）由 ab.sh 自愈守护，
  不要手工 ln 后放任无主——手工建链被外部清理会直接挂 `dsh web`（见 dsh-snapshot-ab
  的 `ab_verify_relinks`）。

## 参考

- `references/incident-20260809-session-loss.md` — 本次事故完整复盘（症状→定位→修复→重启→验证）。
- `scripts/validate-sessions.mjs` — 逐文件 header 校验。
- `scripts/check-all-sessions.mjs` — 全量读取校验。
- `scripts/repair-session-log.mjs` — 无损修复（通用化，按 id 或目录）。
- `scripts/restart-dsh-web.sh` — 重启 + 验证。
