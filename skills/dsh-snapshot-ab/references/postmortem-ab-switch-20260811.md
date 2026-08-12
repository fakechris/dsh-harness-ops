# AB 切换事故复盘（2026-08-11 → 08-12）

> 事故：0811 快照 A/B 切换，dryrun 全绿且结论"可以安全重启"，切换后生产 web 起不来，
> 手工修复（bin/dsh 包装器 + dsh-llm 手工 relink）后才恢复。3080 停机约 9 分钟。
> English version: [postmortem-ab-switch-20260811.en.md](postmortem-ab-switch-20260811.en.md)

---

## 一、事故时间线（本地时间 PDT）

| 时间 | 事件 |
|---|---|
| 15:57:42 | dsh-track 迁移 PR #29 合并 —— `src/sync/llm.ts` 新增 `import @deepseek-ai/dsh-llm`；**ab-config relink 未同步** |
| 15:55–16:00 | 第一次 `ab.sh prepare`（旧版 ab.sh）→ **冒烟失败**：`nohup: ./bin/dsh: No such file or directory`（0811 快照删了 bin/dsh） |
| 16:00–16:04 | agent 修 ab.sh：PR #8 `ab_boot_cmd`（bin/dsh 缺失时 **tsx 直启**）→ 第二次 prepare 全绿：扩展 154/154、**冒烟 HTTP 200（2s）**、client manifest 含 dsh-track → phase=prepared |
| 17:47:18 | 用户批准："switch" → handoff → 17:47:54 第一次 switch 被 gate 拦下（`[ -d "$dir/bin" ]`） |
| 17:48–17:49 | 修 gate（PR #9）→ 同步 ab.sh → 17:49:54 重试 switch → **cutover 成功（current→slot-a）** → 重启 web 失败（`nohup: dsh` / `exec: node: not found`，11 次）→ 会话被杀 |
| 17:52–17:58 | 恢复后诊断：launcher 链断（`dsh: command not found`）→ 手工建 slot-a/bin/dsh 包装器 → `dsh web` 报 **`ERR_MODULE_NOT_FOUND: @deepseek-ai/dsh-llm`** → 手工 `ln -sfn` 补链接 |
| 17:59:00 | `dsh web` 起来（纯 node `apps/cli/lib/bin.js`），HTTP 200，dsh-track 挂载 |

---

## 二、为什么 dryrun 全绿、却说"可以安全重启"——根因链

### 根因 1（核心）：四个环境对 `@deepseek-ai/*` 的解析机制不一致，只有生产"诚实"

同一段 `import @deepseek-ai/dsh-llm`，在验收链的每一环都被不同机制"接住"：

| 环节 | 解析机制 | dsh-llm 结果 |
|---|---|---|
| 扩展 typecheck/build | tsconfig.json `paths`（含 dsh-llm → 槽的 packages） | ✅ 通过 |
| 扩展测试（vitest 154/154） | vitest.config.ts `resolve.alias`（含 dsh-llm → 槽的 packages） | ✅ 通过 |
| **web 冒烟（staging 3081）** | **ab_boot_cmd = tsx 直启，tsx 读 `TSX_TSCONFIG_PATH` 的 tsconfig paths**（`resolveTsPaths` 对非 node_modules 父模块生效） | ✅ HTTP 200 |
| **生产 / 手工启动** | **纯 node ESM（`apps/cli/lib/bin.js`）→ 只查 node_modules** | ❌ `ERR_MODULE_NOT_FOUND` |

- 前三个环境全部**绕开 node_modules** 解析成功（等价于"链接存在"的幻觉）；
- 只有生产环境老老实实查 `dsh-involute/node_modules/@deepseek-ai/dsh-llm`，而 ab-config relink 列表里没有它 → 挂。
- **prepare 没有任何一步用"生产等价解析路径"验证扩展依赖**。冒烟验证的是 tsx 路径，不是 node ESM 路径。

> **一句话根因**：`build/test/冒烟` 的模块解析（paths/alias）与 `生产运行` 的模块解析（node_modules symlink）是两套世界，
> 两套世界的"包清单"（tsconfig/vitest paths vs ab-config relink）各自手维护、不同步；
> 扩展新增依赖时只更新了前者，漏了后者，而唯一能戳破幻象的 gate（生产等价路径冒烟）不存在。

### 根因 2：launcher 链不在任何 gate 覆盖内，且被"绕过式修复"掩盖

- `~/.local/bin/dsh → ~/.dsh/source/current/bin/dsh` 是固定 symlink；0811 快照删了 `bin/dsh` → 切换后 current→slot-a 无 bin/dsh → **`dsh` 命令直接消失**。
- 第一次 prepare 的冒烟**其实抓到了** `./bin/dsh: No such file`——但当时修复方向是 `ab_boot_cmd` 用 tsx **绕过** bin/dsh（ab.sh 内部能启动即可），**没有修复 launcher 链本身**。结果：ab.sh 自己的启动活了，用户/guard 的 `dsh` 命令仍然断。
- switch 的 gate 验证的是 `$(ab_boot_cmd) --version`（tsx 路径），不是 `dsh --version`（launcher 链路径）→ 断链无感通过。

### 根因 3：restart 环境的 PATH 无 node/dsh

- 17:49:54 重启失败在 nohup 层面：`nohup: dsh: No such file or directory` / `exec: node: not found`。
- ab.sh restart 的 nohup 子 shell PATH 未含 node 安装目录 → 即使依赖问题不存在，web 也起不来。
- （独立于根因 1/2 的第三个坑：重启环境的 PATH 假设了登录 shell 的 PATH。）

### 根因 4（流程）：验收 gate 清单的"验证力"没有被审视

"可以安全重启"的结论 = gate 全绿（154/154 + 冒烟 200 + manifest）。但回看每个 gate 的实际覆盖：

| gate | 验证了什么 | 没验证什么 |
|---|---|---|
| 扩展 typecheck/build | 类型/语法、产物生成 | 运行时依赖在 node_modules 的可用性（paths 兜底） |
| 扩展测试 154/154 | 逻辑正确性 | 模块解析与生产一致（alias 兜底） |
| 冒烟 HTTP 200 + manifest | tsx 启动路径能起、client 行在 | **纯 node ESM 启动**、launcher 链、node_modules 依赖完整性 |
| switch launcher 验证 | `ab_boot_cmd --version`（tsx） | `dsh`（launcher 链） |

**教训**：验收"全绿"只说明 gate 覆盖的维度绿。**gate 没有验证"生产等价启动路径"这个维度，而这个维度恰好是切换后唯一重要的维度。**

---

## 三、防复发修复（已落地）

**机制修复（dsh-harness-ops）：**

1. **`ext_check_runtime_deps`（新 gate，PR #10）**：prepare 扫描扩展构建产物里的裸 `@deepseek-ai/*` / `cordis` import，凡扩展 `node_modules` 缺失的**直接 prepare 失败**并提示补 `extensions[].relink`。唯一不被 tsconfig paths / vitest alias 骗过的 gate。
2. **`ab_boot_cmd` 优先级改为生产等价路径（PR #10）**：`bin/dsh` → `apps/cli/lib/bin.js`（纯 node ESM）→ tsx（仅兜底）。冒烟/e2e/stage/restart 全部走生产路径 → 漏链在冒烟即挂。
3. **`ab_ensure_slot_launcher`（PR #10）**：prepare 给无 bin/dsh 的槽自动生成 `bin/dsh` 包装器（指向 `lib/bin.js`）→ launcher 链切换后保持可用；switch 时校验。
4. **`ab_restart_web`（PR #10）**：nohup 环境 node 不在 PATH 时回退 `/opt/homebrew/bin`、`/usr/local/bin`。
5. **`ab.sh confirm` = 生产验收 gate（本次）**：确认前必须通过四项生产验收——生产端口 HTTP 200、运行进程来自当前槽、`dsh` launcher 链解析进当前槽、扩展 client manifest 在页面上。任一不过 → 拒绝确认。
6. **`ab_detect_web` / restart 进程匹配（本次）**：同时匹配 tsx 源码启动与编译产物启动两种进程形态。

**本机配置：**
7. `~/.dsh/source/ab-config.json` relink 补 `"node_modules/@deepseek-ai/dsh-llm": "packages/llm/llm"`。

**验证（实测）：**
- `ext_check_runtime_deps`：链接在 → 通过；临时移除 → 精确报 `@deepseek-ai/dsh-llm`（exit 1）。
- 无 bin/dsh 槽（有 lib/bin.js）→ `ab_boot_cmd` 走编译产物；`ab_ensure_slot_launcher` 幂等。
- `ab.sh confirm` 在"进程 argv 用 current 符号路径"的误报修正后，四项验收全绿才写入 confirmed=true。

---

## 四、给未来的三条铁律

1. **验收必须走生产等价路径**：冒烟/启动类 gate 一律用与生产相同的解析环境（纯 node ESM + node_modules），禁止用 tsx/tsconfig paths 这类"更宽容"的路径做唯一验证——宽容的路径只能作为兜底，不能作为 gate。**确认（confirm）同样必须基于生产验收。**
2. **依赖清单三处必须一致**：扩展新增 `@deepseek-ai/*` 依赖时，tsconfig paths、vitest alias、ab-config relink **三处同改**。`ext_check_runtime_deps` 会在漏改 relink 时拦下 prepare。
3. **"绕过"不是修复**：任何"某条路径起不来就换条路径"的修复，必须同时检查那条路径本身（如 launcher 链 `dsh --version`）是否对用户/guard 可用。

---

## 后续（2026-08-12 补）：同一个问题两次复发，催生了 out-of-band doctor

1. **dsh-llm 链接当天夜里又被外部清理**（20:44–22:52）：手工 `ln` 的链接是无主资产，
   不在任何管理机制内，被碰 `node_modules/@deepseek-ai/` 的操作清掉后**无任何机制发现**，
   直到用户手动 `dsh web` 再挂一次（22:52）——**同一个病，第二次发作**。
2. **6 个旧会话打不开**（0810 时期 dsh-track 写进 session 的自定义事件，0811 白名单不认，
   `SessionFormatUnsupportedError`）。
3. 现场修复每一步（查 session 尾部 → 找根因 → 修 relink → 修会话 → 拉起 web）**都能脚本化**，
   且 **agent 跑在 web 里，web 挂 = 没有 agent 能帮我**——于是做了 out-of-band 的
   **`dsh-web-doctor`**（`dsh-doctor` 一条命令：诊断 9 项 → 机械修复配置 → LLM 深度检测修复
   [完整思维链实时展示] → 拉起 web），并给 ab.sh 加了 **relink 自愈**（status/verify/confirm/
   restart 每次校验并自动重建缺失链接）。动机与完整事故链：
   `docs/web-doctor-motivation.md`。
