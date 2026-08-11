# 事故复盘：2026-08-09 会话集体消失（"0 sessions"）

> 本文是 `dsh-session-recovery` skill 的出处。记录一次真实事故的完整过程：
> 症状 → 定位 → 修复 → 重启 → 验证，以及所有踩过的坑。

## 时间线

| 时间 | 事件 |
|---|---|
| 12:04 | 某次"修复"把 `session-026b244d.../session.jsonl.zstd` 整体重压成 **单个 zstd frame**（1.7MB，15,622 行明文） |
| 12:05 | `dsh web` 重启；启动时 `persistence.list()` 遇到该坏文件**整体 throw** → session 索引为空 |
| 12:05 | GUI 侧边栏所有 workspace 显示 **"0 sessions"**（5 个 explorer 会话"全部消失"） |
| 12:0x | 用户报告："修复半天的 session 全部不见了！怀疑系统有 integration 校验" |
| 12:16 | 定位根因：唯一坏文件 = 首帧非单行 header → 重排修复 → 22/22 全量校验通过 |
| 12:17 | 写 handoff → 重启服务 → GUI 恢复显示 6 sessions（5 个 + 当前会话） |

## 症状

- GUI 侧边栏：`Workspaces → explorer → 0 sessions`。
- 磁盘上 5 个 session 文件全在，`~/.dsh/storages/workspace.json` 也登记了全部 5 个 sessionId。
- 数据其实**没有任何丢失** —— 消失的只是"索引"。

## 根因（机制）

DSH 的 JSONL session 持久化（`packages/session/session-persistence-jsonl`）强校验：

1. 文件 = 多个独立 zstd frame 拼接（每个 frame 带 XXH64 content checksum）。
2. **第 1 个 frame 必须恰好只含 header 一行**（`assertZstdHeaderFrame`：
   解压后唯一换行符必须是最后一个字节）。
3. 后续每个 frame 必须在记录边界结束，否则报 torn JSONL record。
4. 每条记录的 `seq` 必须连续，否则报 seq gap。

`SessionPersistenceJsonl.list()` 遍历所有文件，**任何文件校验失败都直接 throw**，
导致：
- 服务启动时 session 索引构建失败 → workspace 的 `sessionIds` 投影全被过滤 → GUI 显示 0 sessions；
- 其他 21 个文件全是好的，被一个坏文件连累。

坏文件形态（`zstd -lv` 实测）：
```
# Zstandard Frames: 1        ← 正常应 ~80 帧
Check: XXH64
```
即整个日志被 `zstd` CLI（或等价物）默认整文件单帧重压了。

## 定位方法（当时实际用的）

1. 确认文件都在、workspace.json 登记完好 → 判定为"索引/校验"问题。
2. 用 DSH 编译产物直接调 `persistence.list()` → 复现 `corrupt Zstandard session log:
   first frame is not exactly one header line`。
3. 逐文件调 `readFirstZstdLine()` → 精确定位唯一坏文件（026b244d）。
4. `zstd -lv` 确认单帧形态；`zstd -dc | wc -l` 确认明文完整（15,622 行）。

## 修复方法（内容零丢失）

1. 解压 → 校验 header（id/cwd 匹配）、全部行是合法 JSON。
2. 备份坏文件。
3. 用 DSH 同款压缩器重排帧：
   - frame1 = 仅 header 行；
   - 其余按 200 行/帧，每帧以换行结尾；
   - 压缩参数 `node:zlib zstdCompress + { [ZSTD_c_checksumFlag]: 1 }`（与 DSH 写路径完全一致）。
4. 两步可逆交换：`原文件 → .orig-in-place`，`新文件 → 原位`。
5. 用 DSH 读取器在规范路径 `readPrefix()` 全量校验（无 torn record、seq 连续），
   并对原始明文逐事件比对（`decodeStorageRecord` 解包）。
   - ⚠️ **坑**：行数 ≠ 事件数。日志里 chunk 行是打包的，`readPrefix` 会解包——
     15,621 行明文 = 235,257 个事件。第一次校验用"行数 == 事件数"判断，误报失败回滚了一次。
6. 全部通过才删除 `.orig-in-place`。

## 重启（为什么必须 + 怎么安全做）

- **为什么必须**：workspace 注册表的 `sessionPaths` 索引只在启动时从 live sessions 构建，
  运行中的服务不会自动重扫磁盘。文件修好后索引仍空 → 必须重启。
- **为什么危险**：`dsh web` 托管了当前 agent 的会话（本会话日志由它写入）。
  重启会杀死 agent 运行时。
- **怎么安全做**：
  1. 先写 handoff（症状/根因/修复/备份/待办/回滚/验证）；
  2. 一个脚本内完成 kill → 等端口释放 → `nohup dsh web &`（新服务脱离 agent 存活）；
  3. 轮询 HTTP 200 验证；
  4. 用浏览器确认 GUI 侧边栏 session 数恢复。
- 本机实际：`dsh web` 从 `/Users/chris/source/test-fakechris` 启动（shell 历史可查），
  端口 3080 默认。`dsh` → `~/.local/bin/dsh` → `~/.dsh/source/current/bin/dsh`。

## 验证结果

- `persistence.list()` → 22 sessions（修复前 throw）。
- `check-all-sessions.mjs` → 22/22 全量读取通过，0 失败。
- GUI → explorer 6 sessions（5 个历史会话 + 当前会话），标题/目标来自
  `session_projcache.json`（未损坏，无需恢复）。

## 教训

1. **绝不用系统 zstd CLI 重压 session 日志** —— 默认单帧，恰好触发本事故。
2. `persistence.list()` 是"一个坏文件全盘 throw"的强校验 —— 排查消失问题时
   先逐文件定位坏文件，不要急着改配置或删数据。
3. 事件数 ≠ 行数（打包 chunk 行）—— 用 DSH 的解包逻辑比对，别用朴素行数。
4. 写 `~/.dsh/sessions` 前先备份、先校验、用可回滚的两步交换。
5. 重启前必写 handoff —— 服务器可能就是你所在的运行时。

## 相关文件（本次事故产物，已并入 skill）

- `scripts/validate-sessions.mjs` — 逐文件首帧校验。
- `scripts/check-all-sessions.mjs` — 全量读取校验。
- `scripts/repair-session-log.mjs` — 无损重排修复。
- `scripts/restart-dsh-web.sh` — 安全重启 + 验证。
