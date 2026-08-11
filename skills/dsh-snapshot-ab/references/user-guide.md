# DSH 快照 A/B 轮换 — 用户菜单（User Menu）

> 配合 skill `dsh-snapshot-ab` 使用。本文是**给"人"看的操作菜单**：谁是 A、谁是 B、
> 怎么启动 A、怎么启动 B、切换后世界变成什么样、每天怎么过。命令里的 `AB` 指：
> `AB=~/.dsh/skills/dsh-snapshot-ab/scripts/ab.sh`（已装入 `~/.dsh/skills/`）。

---

## 0. 一句话

我们的 DSH 安装 = 一个 `current` 符号链接 + 两个槽目录（`slot-a` / `slot-b`）。
**`current` 指向谁，生产（http://127.0.0.1:3080）就跑谁。** 槽的"身份"（A/B）固定，
但**每天里面装的内容互换**：旧版本留在当前槽继续跑，新快照在另一个槽构建+验收，
通过后把 `current` 指过去；下一天角色对调。

## 1. 谁是谁（当前状态，2026-08-11）

| 槽 | 内容 | 现在 |
|---|---|---|
| **slot-a** | 20260809 快照 + 本地 loader fix（`be90233`）= 旧版 | 🟢 **当前生产**（`current → slot-a`） |
| **slot-b** | 20260810 官方快照（`4cdb149`），已构建 + 扩展 75/75 测试 + 冒烟 200 | 🟡 候选（prepared，**未**在生产） |

`ab.sh status` 随时可看最新状态（谁在生产、phase、扩展脏文件数）。

## 2. 怎么启动 A / 启动 B

**生产（3080 端口）：永远只有一个实例，跑的永远是 `current` 指向的槽。** 启动命令就是：

```sh
dsh web          # 或 launcher（~/.local/bin/dsh）——不需要也不能指定 A/B
```

**⚠️ 能不能两个槽同时跑？（核实过的边界）**

- **进程层面可以**：每个槽有自己的 `bin/dsh`，能从自己 checkout 启动在**不同端口**。
  机制自己就这么用——验收冒烟时生产（slot-a / 3080）与候选（slot-b / 3081）**同时在线**
  （都 HTTP 200）。
- **但不是受支持的运行模式**，原因：
  1. 两个实例共享 `~/.dsh/sessions`：同一会话文件是 append-only，双进程同时 append
     可能撕裂帧 → 正是之前 session 事故的同类风险；
  2. 共享 `~/.dsh/storages`（track.json / workspace.json）：KV 是**单进程串行写链**
     设计（dsh-track `src/store.ts`），双实例各持一份内存缓存会互相覆盖；
  3. 官方持久层对整文件替换做了并发安全（temp+link 原子发布），但**这不是让你双常驻**，
     只是防崩溃/防意外。
- **所以规则是**：**一个生产实例常驻**；另一个槽只用于「验收 / 临时查看」，
  在 staging 端口（3081）起、**看完就关**，期间只读不写。

要让**特定槽**成为生产（平时不要手动做，除非兜底）：

```sh
# 强制 A 当生产：把 current 指到 slot-a，然后重启 web
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current && 重启 dsh web
# 强制 B 当生产：同上但指 slot-b（等价于 ab.sh switch --yes）
ln -sfn ~/.dsh/source/slot-b ~/.dsh/source/current && 重启 dsh web
# 推荐的切回方式
$AB rollback --yes     # current 指回上一个版本并重启
```

**临时查看某个槽的界面（不碰生产，staging 端口）——用 `ab.sh stage`，有护栏**：

```sh
$AB stage --slot b [--port 3082]            # 前台跑，Ctrl-C 停止
$AB stage --slot a --port 3082 --keep --yes # 后台跑（nohup + pid/日志），按提示停止
```

`stage` 会**先检测**：如果已经有 web 实例在跑（比如生产 3080），会明确警告"第二个实例共享
`~/.dsh`，只读查看"，并**要求你 `--yes` 明确确认后才启动**；不带 `--yes` 直接拒绝。
（`prepare` 的自动冒烟同理会打印这个警告；只有 `--keep` 保留实例时才强制要确认。）

⚠️ 兜底：即使不用 `ab.sh`，两个实例共享 `~/.dsh`（sessions/storages/profiles），
临时实例只用来**看**，别同时做写操作，看完就关。

## 3. 切换（switch）之后，你的场景会变成什么样

执行 `$AB switch --yes` 的那一刻：

1. `current` 原子指到 **slot-b**；
2. `dsh web` 自动重启 → 重启后 3080 端口跑的是 **20260810 新版**；
3. **你当前这个会话会断**（重启的就是托管的 web）——这是预期内的；
4. **slot-a 原封不动**留着 = 一键回滚点。

切换后打开 http://127.0.0.1:3080：

- **先硬刷新（Cmd+Shift+R）**——旧 tab 里是切换前加载的 boot manifest，新 client 面板
  （dsh-track 的 ◆）只在刷新后的页面出现（2026-08-11 实测坑）；
- 你会看到一个**全新会话列表**（会话都存在磁盘上，重启后重新索引——不会丢）；
- 找一个**新的会话**说"继续 snapshot-ab"，agent 会读 skill + 本目录的
  `HANDOFF-snapshot-ab.md` / `USER-GUIDE-snapshot-ab.md` 接上；
- 或者你自己跑 `$AB status` 看：`current=b`、`phase=switched`、`confirmed=false`。
- dsh-track 右侧面板默认**收起**：点右下角 ◆ 悬浮按钮展开（开合状态浏览器会记住）。

**切换后第一件事**（新版本跑起来、你验证没问题后）：

```sh
$AB confirm      # 标记稳定 → 之后回滚槽（slot-a）才允许被下一天回收
```

## 4. 每天的日常循环（从明天开始重复）

```sh
$AB status       # 1. 看当前状态
$AB discover     # 2. fetch 上游，看官方今天发了什么新快照
$AB prepare      # 3. 自动选"非当前槽"构建新快照 + 挂接扩展 + 冒烟（不动生产）
#    —— 验收不通过：看证据，不切换；通过：继续
$AB switch --yes # 4. 你批准后切换（会重启 web，断当前会话，先读 HANDOFF）
$AB confirm      # 5. 稳定后确认，解锁下一天的轮换
```

**注意**：`prepare` 在"切换后未 confirm"期间会拒绝回收回滚槽（那是唯一保底）。

## 5. 回滚（新版本有问题）

```sh
$AB rollback --yes   # current 指回上一个版本（slot-a）+ 重启 web（同样会断会话）
```

手动兜底（ab.sh 不可用时）：

```sh
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current   # 指回旧版
kill <web pid> && cd ~/source/test-fakechris && nohup dsh web &   # 重启
```

## 6. 出问题去哪里找

| 想找什么 | 位置 |
|---|---|
| 机制状态（谁生产、phase、证据） | `~/.dsh/source/ab-state.json`（`$AB status --json`） |
| 配置（扩展列表、端口、冒烟路径） | `~/.dsh/source/ab-config.json` |
| web 重启日志 | `~/.dsh/source/web.log` |
| 冒烟日志 | `/var/folders/.../dsh-ab-smoke.*.log`（`$AB verify` 会打印） |
| skill 全手册 | `~/.dsh/skills/dsh-snapshot-ab/SKILL.md`（agent 会加载） |
| 设计/研究记录 | `~/.dsh/skills/dsh-snapshot-ab/references/mechanism-design.md` |
| 恢复指引 | 本目录 `HANDOFF-snapshot-ab.md` |
