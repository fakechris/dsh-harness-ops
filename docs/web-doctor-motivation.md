# dsh-web-doctor 动机与事故链（2026-08-11 → 08-12）

> English: [web-doctor-motivation.en.md](web-doctor-motivation.en.md)

## 为什么有这个东西

2026-08-11 一天之内，同一台机器上发生了**三次**与"web 起不来"相关的事故，现场手工修复
每次都要数十分钟到数小时。事后回看，**每一步其实都能脚本化**——缺的只是一个不依赖 web
进程的一键入口。doctor 就是补上这个缺口的产物。

## 事故链（为什么我们痛）

### 事故 1：AB 切换后 web 起不来（08-11 17:49）

- 0811 快照切换（`ab.sh switch`）成功，`current → slot-a`，但 web 重启失败，3080 停机约 9 分钟
- **根因 A**：0811 快照**删除了 `bin/dsh`**（启动方式从 `bin/dsh` tsx 源码运行改为编译产物
  `apps/cli/lib/bin.js`），launcher 链 `~/.local/bin/dsh → current/bin/dsh` 断掉
- **根因 B（更深）**：扩展 `dsh-track` 新增依赖 `@deepseek-ai/dsh-llm`，但 ab-config 的 relink
  列表漏了它。**build/test/冒烟全绿却生产挂**——因为 build/test 走 tsconfig paths / vitest
  alias、冒烟走 tsx（tsx 也读 tsconfig paths），**只有生产是纯 node ESM（只认 node_modules）**
- 手工修复：补 `bin/dsh` 包装器 + `ln -sfn` dsh-llm

### 事故 2：同一个 dsh-llm 链接又被外部清理（08-11 20:44–22:52）

- 手工 `ln` 建的链接是**无主资产**（不在 pnpm、不在 ab.sh 管理内），被某个碰
  `node_modules/@deepseek-ai/` 的操作清掉；**没有任何机制发现或恢复**，直到用户手动
  `dsh web` 再挂一次（22:52）才发现

### 事故 3：session 打不开（08-11 晚）

- 0810 时期 dsh-track 写进会话日志的自定义事件（`track/sync-preview` 等），0811 快照的事件
  白名单不认识 → `SessionFormatUnsupportedError`，6 个旧会话历史读不出（官方立场：宁拒读不误读）

## 现场修复过程（手工版，耗时点）

1. **查 session 最后发生的事**：解压 session.jsonl.zstd 看尾部事件 → 判断"挂之前系统在做什么"
2. **找根因**：web.log / launcher 链 / relink 存在性逐项排查
3. **修 relink / 补 bin/dsh / 修 session 格式**
4. **拉起 web** + 验证 200

每一步都能写成脚本，但当时是逐条命令手工跑 + 靠人（或 LLM）判断。

## 关键洞察：为什么必须 out-of-band

- **agent 由 web 进程托管**——web 挂了 = GUI 和 agent 全部不可用，没有任何"智能"能帮你
- 所以救火工具必须**纯终端 + 本机工具**（node/zstd/jq/curl/ps/lsof），零 web 依赖
- 但纯确定性脚本有个致命伤：**写死的规则会随 DSH 改版失效**（0811 就删了 `bin/dsh`），
  新故障模式规则想不到

## 为什么"确定性 + LLM"分层

| 层 | 为什么需要 | 局限 |
|---|---|---|
| **确定性**（检查原语 + 修复原语） | 秒级、零 LLM 成本、web 挂得再彻底也能跑；给 LLM 提供可靠事实和可执行动作 | 规则会过时；新故障想不到 |
| **LLM 大脑**（headless one-shot agent） | 读报告+日志自己推理根因；DSH 改版/核心不兼容/插件配置被改乱都能适应 | 依赖 harness 本身（编译产物+凭据）能跑；慢、烧 token |

实测 LLM 价值：健康系统上它读完报告后**自己判断出** web.log 的 `node: not found` 是
8/10 历史残留而非当前故障——这是确定性规则做不到的（规则只会罗列）。

## 演进历史（一天内从脚本到完整工具）

1. `doctor.sh`：9 项确定性诊断 + 修复 + 拉起（out-of-band 构造）
2. 极小依赖分层：L0 自包含（node 内置+zstd，不加载编译产物）/ L1 深度可降级
3. `dsh-doctor` 短命令入口（PATH）+ 槽 bin 双入口 + `--help`
4. 交互菜单（无参数即用，默认英文可切中文）
5. LLM 大脑 `--agent`（headless one-shot + 自愈 prompt）
6. 通用插件覆盖 `plugin-deps-check`（profile 驱动，不认 ab-config，任何插件都查）
7. LLM 凭据修复（交互补 key / 配置备份重置 / 权限归一化）
8. 诚实化：无故障跳过修复；web.log 历史 vs 当前分类；菜单如实描述能力

## 现状能力与诚实边界

**能自动做**：诊断 9 项 → 修复已知配置故障（relink/插件依赖/launcher/session/LLM 凭据）→
LLM 推理未知问题 → 拉起 web → 验证。

**做不了（如实说）**：LLM API key 本身只能用户提供（doctor 引导输入并代为配置，绝不臆造）；
key 失效/欠费等外部原因只能提示；真正需要人决策的（如"要不要回滚槽"）会明确报告而不是擅动。

## 相关文档

- `skills/dsh-web-doctor/SKILL.md` — 使用手册（双语菜单、诊断项、分层、边界）
- `skills/dsh-snapshot-ab/references/postmortem-ab-switch-20260811.md` — 事故 1 完整复盘
- `skills/dsh-session-recovery/SKILL.md` — 会话修复（事故 3）
