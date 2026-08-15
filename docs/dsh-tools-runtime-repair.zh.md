# DSH `dsh-tools` 运行时漂移故障处理手册

[English](dsh-tools-runtime-repair.md) | 中文

适用症状：DSH Web 可以启动或曾经启动，但对话开始后中断，并出现以下一项或多项错误：

```text
Cannot read properties of undefined (reading 'prepare')
An assistant message with 'tool_calls' must be followed by tool messages
responding to each 'tool_call_id'
```

本文针对 Windows + `npx @deepseek-ai/dsh web` + 本地 profile/plugin 的组合。它不用于 API 404、模型鉴权失败、普通 MCP 启动 warning，或 session 文件损坏。

## 0. 先判断边界

这两个错误通常是一条因果链，而不是两个独立问题：

```text
profile 与 DSH 运行时加载了两份 dsh-tools
    -> 共享 scheduler Symbol 不相等
    -> agent loop 读取 scheduler 得到 undefined
    -> 调用 undefined.prepare() 失败
    -> 已写出的 tool/call 来不及写 tool/result
    -> LLM 提供方拒绝不完整的 tool_calls 历史
```

已经写入不完整 `tool/call` 的旧 session 可能在运行时修复后仍不能继续。这是历史记录问题，不能靠重启或伪造 `tool/result` 修复；先用新会话验证当前运行时，再按会话恢复流程单独处置旧会话。

不要手工编辑 `~/.dsh/sessions/**/session.jsonl.zstd`，也不要删除 session、profile 或整个 npm cache。

## 1. 按诊断 skill 建立反馈回路

目标不是“Web 首页能打开”，而是确认一次真实工具调用完整结束。一个有效的反馈回路应满足：

1. 新建空白会话。
2. 发送会触发一个简单本地工具的请求，例如“用 pwsh 输出当前目录”。
3. 在会话事件或 UI 中确认顺序是 `tool/call`、`tool/result`、`turn/end: completed`。
4. 以下任一结果判红：`.prepare`、`tool_calls` 协议错误，或 `tool/call` 后没有 `tool/result`。

启动后先做以下只读检查，记录输出中的 PID、运行时目录和 Junction 目标：

```powershell
$listener = Get-NetTCPConnection -State Listen -LocalPort 3080
$listener | Select-Object LocalAddress, LocalPort, OwningProcess

$process = Get-CimInstance Win32_Process |
  Where-Object { $_.ProcessId -eq $listener.OwningProcess }
$process | Select-Object ProcessId, ParentProcessId, CommandLine | Format-List

$link = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools'
(Get-Item $link) | Select-Object FullName, LinkType, Target
```

运行中的 DSH 命令行通常包含类似路径：

```text
C:\Users\<user>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js web
```

这里的 `<hash>` 是本次运行时的真实根目录，不能从历史日志、旧 Junction 或旧终端复制。

## 2. 复现并最小化

只保留如下最小条件：

| 条件 | 必要性 |
| --- | --- |
| 正在监听 3080 的 DSH Node 进程 | 必须，用它确定当前 runtime |
| web profile 中的 `@deepseek-ai/dsh-tools` | 必须，本地插件从这里解析 peer dependency |
| 一个新会话的一次工具调用 | 必须，首页 200 不能覆盖 agent loop |
| 旧 session、全部插件、MCP 服务器 | 先不要改动，通常不是最小复现条件 |

从 DSH 命令行得到 `<hash>` 后，检查当前 runtime 是否实际包含工具包：

```powershell
$runtimeTools = 'C:\Users\<user>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh-tools'
Test-Path (Join-Path $runtimeTools 'package.json')
```

结果必须是 `True`。若 profile Junction 的 `Target` 与 `$runtimeTools` 不同，即得到可重复、可修复的红色信号。

## 3. 假设与分流

先按报错文本分流，不要用一次重启同时处理所有问题。

| 优先级 | 假设 | 预测 | 验证/处理 |
| --- | --- | --- | --- |
| 1 | `dsh-tools` 副本漂移 | profile Junction 指向旧 `_npx/<hash>`，`sameSymbol=false` | 按第 4 节重新建 Junction |
| 2 | 旧 session 有不完整工具调用 | 新会话正常，旧会话仍报 `tool_calls` | 保留旧日志；新会话继续工作，旧会话走单独恢复流程 |
| 3 | 两个 agent preset 同时注册工具 | 报 `tool "pwsh" is already registered`、`read` 或 `glob` | 统一 default preset，见第 6 节 A |
| 4 | 第二个 DSH 实例抢占 3080 | 启动日志报 `EADDRINUSE` | 找到监听 PID，停止已确认的冗余 DSH，而不是反复重启 |
| 5 | 插件缺依赖或客户端 bundle 故障 | 报 `Cannot find package`、`loaded without registering` 等 | 使用 Web doctor 的 bundle/依赖检查；这不是本手册的 Junction 修复范围 |

## 4. 修复：让 profile 与当前 runtime 共享同一份 `dsh-tools`

### 4.1 安全前置检查

以下动作只允许在 profile 项是 `Junction` 时执行。普通目录可能含用户安装的包，不能直接删除。

```powershell
$link = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools'
$item = Get-Item $link -ErrorAction Stop
if ($item.LinkType -ne 'Junction') {
  throw "Refuse to replace non-Junction: $link"
}
```

确定当前 `<hash>` 后设置目标：

```powershell
$target = 'C:\Users\<user>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh-tools'
if (-not (Test-Path (Join-Path $target 'package.json'))) {
  throw "Current runtime dsh-tools is missing: $target"
}
```

### 4.2 重建 Junction

在 `cmd.exe` 中执行。`rmdir` 作用于 Junction 本身，不递归删除其目标；不要在这里增加 `/s`。

```cmd
rmdir C:\Users\<user>\.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools
mklink /J C:\Users\<user>\.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools C:\Users\<user>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh-tools
```

立即复查：

```powershell
(Get-Item $link) | Select-Object FullName, LinkType, Target
```

### 4.3 验证模块身份，而非只比版本号

两个包即使都显示 `0.1.0-rc.6`，也仍可能是不同 ESM module 实例。必须比较导出的 Symbol：

```powershell
node --input-type=module -e "import {pathToFileURL} from 'node:url'; const a=await import(pathToFileURL('C:/Users/<user>/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-tools/lib/index.js').href); const b=await import(pathToFileURL('C:/Users/<user>/AppData/Local/npm-cache/_npx/<hash>/node_modules/@deepseek-ai/dsh-tools/lib/index.js').href); console.log('sameSymbol='+String(a.TOOL_RUNTIME_SCHEDULER===b.TOOL_RUNTIME_SCHEDULER));"
```

预期唯一正确结果：

```text
sameSymbol=true
```

若为 `false`，不要重启，先重新检查 `<hash>` 是否来自监听 3080 的 PID，而非失败的 npx wrapper 或历史缓存。

## 5. 重启和验收

1. 先确认哪个 PID 正在监听 3080。
2. 只停止已确认属于 DSH 的监听进程；不要按进程名批量杀 Node、Python 或 MCP 子进程。
3. 启动 DSH 后再次读取实际运行命令行。若 `npx` 选择了新的 `_npx/<new-hash>`，必须重新执行第 4 节，不能假定旧 Junction 仍有效。
4. 验收分两层：

```powershell
Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3080/' | Select-Object StatusCode
```

期望 `200`。随后用第 1 节的新会话工具调用检查 `tool/result` 与 `turn/end: completed`。

`HTTP 200` 仅证明 Web server 存活，不能证明 `agent-loop`、工具 scheduler 或模型协议已经恢复。

## 6. 相关但不同的故障

### A. `tool "pwsh" is already registered` / `read` / `glob`

这表示两个 preset 或 host/preset 同时注册同名工具，不是 `dsh-tools` Symbol 漂移。Web 模式下 host 工具应禁用，由单一 agent preset 提供。检查最终配置：

```powershell
npx @deepseek-ai/dsh --profile web --dump-config
```

确认 host 的 `tool-pwsh`、`tool-fs`、`tool-fs-search` 为 `disabled: true`。若实际会话使用 `router-standard`，将 profile patch 的默认 preset 同步为它：

```yaml
- id: agent-presets
  config:
    default: router-standard
```

不要在同一进程中同时热挂载 `standard` 与 `router-standard`。

### B. `EADDRINUSE: 127.0.0.1:3080`

这只表示已有服务监听端口。优先检查监听者，而不是立即再启动一个实例：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 3080 |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

若监听者已是修复后的 runtime，保留它并让失败的新实例退出。反复启动会制造更多 MCP 子进程和更难读的日志。

### C. 旧 session 仍报 `tool_calls`

这是历史轨迹残留。新 session 通过工具回归后，旧 session 仍报错说明它记录了没有配对 `tool/result` 的 `tool/call`。保留原始日志，导出/参考其内容，必要时按 `dsh-session-recovery` 的无损流程检查；不要手工改压缩 JSONL 或人为插入事件。

## 7. 复盘与预防

### 为什么会反复出现

`npx` 的缓存根目录不是稳定 API。一次重启、缓存清理或安装解析都可能使：

```text
_npx\old-hash\node_modules\@deepseek-ai\dsh-tools
```

变为新的路径。profile 的 Junction 若仍指向旧 hash，就重新引入双副本问题。

### 长期措施

1. 启动脚本不要硬编码 `_npx/<hash>`。
2. 每次用 `npx` 启动或升级 DSH 后，先从监听 PID 的命令行解析当前 runtime，再检查 Junction 目标。
3. 更稳妥的部署方式是使用一个固定的 DSH 安装目录/受控 launcher；profile 和 DSH runtime 始终解析到同一依赖树。
4. 将第 1 节的 PID、Junction target、`sameSymbol` 和一次新会话工具调用纳入重启后验收。
5. 对已失败的会话与当前 runtime 分开处理：前者是数据恢复问题，后者是依赖解析问题。
6. 防线已自动化（见下节），但仍保留人工验收习惯：每次升级/重启后跑一次
   `dsh-tools-sync.ps1` 确认 `status=aligned`。

### 自动防线（Windows 已落地，dsh-web-guard-win）

「事后修复」已升级为「拉起前自动对齐」，三层防线：

1. **守护拉起前自动同步**：`dsh-web-guard.ps1` 每次 `Start-Web` 前调用
   `dsh-tools-sync.ps1`，把 profile Junction 对齐到**本次将要启动**的 runtime
   （从 `$CliJs` 向上 5 级解析出 `_npx/<hash>`）。守护解析到新 hash 时，同步
   先完成，不存在「新 runtime + 旧 Junction」的双副本窗口。
2. **安装/升级后同步**：`install.ps1` 安装完成自动跑一次同步，收敛
   `dsh plugin add/update` 重写 node_modules 造成的漂移窗口。
3. **独立自愈脚本**：`dsh-tools-sync.ps1` 可单独运行（诊断/验证/手工修复），
   缺省自动从 3080 监听 PID 解析 runtime（手册 1 节规则）；`-DryRun` 预演；
   退出码 0/2/3/4/5 语义见脚本头注释。

安全红线不变（4.1 节）：仅当 profile 项是 **Junction** 时自动重建
（`cmd /c rmdir` + `mklink /J`，rmdir 不递归）；普通目录可能含用户安装的包，
只告警、绝不删除。同步失败只记日志，不阻断守护拉起（守护尽力而为）。

一键验证（对当前 runtime）：

```powershell
powershell -ExecutionPolicy Bypass -File <dsh-web-guard-win 目录>\dsh-tools-sync.ps1
# 期望输出 status=aligned（健康）/ repaired（刚修复）；-DryRun 为 would-repair 预演
```

## 8. 事故记录模板

每次发生时至少记录以下内容，便于快速判断是否同一问题：

```text
时间：
症状：
3080 监听 PID：
DSH runtime 路径（从 PID CommandLine 获取）：
profile dsh-tools Junction Target：
sameSymbol：true / false
自动防线：dsh-tools-sync exit（0 = 对齐/修复；非 0 见 guard 日志 dsh-tools-sync 行）
新会话工具调用：tool/call -> tool/result -> turn/end completed / failed
旧会话是否仍有 tool_calls 协议错误：
采取动作与备份位置：
```

