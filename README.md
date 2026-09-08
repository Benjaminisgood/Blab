# Blab · 个人生活管理

Blab 是一个 macOS 原生生活管理应用，使用 Swift、SwiftUI 和 SwiftData，把日程、物品、空间和衣橱放在同一个本地工作台。你可以先把生活记录好，再按需要使用自然语言助手。

## 现在可以做什么

- **看清今天。** 今日概览集中展示进行中、当天、后续与未排期事项，并提供常用页面入口。
- **管理自己的衣橱。** 记录衣物类别、颜色、厚薄、季节、场合及可穿 / 待洗 / 归档状态；可关联由自己负责的既有物品。
- **用真实照片搭配。** 导入衣物照片，可使用 Apple Vision 在本机去除背景；照片保存在本机。
- **得到每日搭配建议。** 填写参考气温、日期、季节和场合，应用根据现有可穿衣物与实际穿着记录提供最多三套建议，并说明搭配依据。
- **自由组合并导出。** 手动选择单品，查看二维穿搭图，导出 PNG 或保存为穿搭计划。
- **记录真正穿过的搭配。** 保存计划不会增加穿着次数；点击“今天穿了”才写入实际穿着记录，供后续轮换推荐参考。
- **继续管理日程、物品和空间。** 原有成员、附件、反馈与日志功能保留；自然语言助手继续作为可选的操作入口。

穿搭推荐与图片处理不需要 API Key。参考气温由用户填写，当前没有自动天气查询。渲染是衣物的二维组合预览，不能代表真人试衣、尺码匹配或三维布料效果；没有照片的衣物显示类别示意。

首次正常启动只建立“我”的本地资料和默认设置，不向真实生活记录写入示例衣物、社区物品或活动。已有数据库继续使用原有资料。成员切换是本机记录身份选择，不是账号登录认证。

## 开始使用

需要 macOS 26.1 或更新版本与完整 Xcode。

```bash
# 构建并启动正常版本
./script/build_and_run.sh

# 使用独立示例数据体验，关闭后不保留预览数据库
./script/build_and_run.sh --preview --verify

# 只编译，不启动应用
./script/build_and_run.sh --build-only
```

Codex 的 Run 按钮也调用同一个脚本。预览使用独立 bundle ID、内存数据库、隔离偏好与临时照片目录，并禁用 Runtime 和通知。开发脚本不会修改全局 Xcode 选择，且只关闭本工作区相同构建路径的 Blab 进程。

打开“衣橱与穿搭”，先添加自己的上装、下装（或连体装）和鞋履，再进入搭配工作台。也可先运行预览体验示例衣橱。去背景效果需要用实际衣物照片判断，背景简单、单件平铺的照片通常更适合。

架构、开发边界与已知后续事项见 [架构说明](docs/ARCHITECTURE.md)；已执行检查及待验证项目见 [验证记录](docs/QA.md)。目前已完成原生预览启动、主要页面操作、保存与标记穿着、实际 PNG 导出，以及临时数据库的增量迁移检查；这些不代表真实用户历史数据库或真实衣物分割质量已通过验收。

## 可选自然语言助手

以下保留已有助手与 Runtime 的使用说明。助手根据设置中的模型服务生成计划；启用外部模型时，相关请求会发送给该服务。衣橱本地功能独立于助手运行。

助手使用 **OpenClaw 风格 Agent Loop**：

- 决策循环：`Tool -> Observe -> Replan`
- 自然语言补充：用户始终可用自然语言继续
- 执行能力：支持 `create / update / delete`
- 目标校验：执行后自动做 post-condition verifier
- 可观测性：前端与 Runtime 都可查看 `agentTrace` + `agentStats`

## 1. 助手架构

### 1.1 总体流程

1. 用户输入自然语言指令
2. Agent Loop 进行多轮决策（是否检索、是否可规划、是否必须追问）
3. 生成结构化计划 `AgentPlan`
4. 可选执行计划（写入 SwiftData）
5. 可选自动修复失败项（重规划 + 重试一次）

### 1.2 核心模块

- `Blab/Services/HousekeeperAgentLoopService.swift`
  - Agent 循环编排
  - 工具调用与观察结果回填
  - 循环守卫（最大轮次、重复调用拦截）
- `Blab/Services/AgentPlannerService.swift`
  - 将自然语言 + 观察结果转换为结构化计划 JSON
- `Blab/Services/AgentExecutorService.swift`
  - 执行 `create / update / delete`
  - 失败隔离与结果汇总
- `Blab/Services/HousekeeperRuntimeService.swift`
  - 本地 Runtime 接口（`localhost:48765`）
  - 幂等、鉴权、状态返回
- `Blab/Views/Components/DashboardHousekeeperCard.swift`
  - 前端交互入口
  - 展示执行计划 + 智能推理轨迹

## 2. Agent Loop 设计（OpenClaw 风格）

### 2.1 决策类型

每一轮模型只返回一个 JSON 决策：

- `tool`：调用只读工具获取上下文
- `plan`：信息足够，进入计划生成
- `clarification`：信息不足，向用户追问

### 2.2 内置工具（当前）

- 搜索工具：`search_items / search_locations / search_events / search_members`
- 精确获取：`get_item / get_location / get_event / get_member`

工具目前是“应用内本地工具”，不直接暴露给外部。

现在工具定义采用**单一注册表**（`LoopTool`）驱动：

- prompt 中的 tool schema 自动由注册表生成
- 决策参数校验由同一注册表生成
- 执行分发由同一注册表分发

这样新增/删除工具不会再出现 prompt/执行器漂移。

### 2.3 循环守卫

- 最大轮次：默认 6 轮
- 重复调用拦截：同一工具签名超过阈值直接转追问
- 无进展兜底：达到最大轮次后进入兜底规划
- 决策修复：当模型输出非法 JSON 时，会自动发起一次“修复决策”重试
- 参数自纠：工具参数缺失不会中断流程，而是写入观察并让模型下一轮自主改路

### 2.4 保姆说明书（项目级）

- 新增项目级规范文件：`HOUSEKEEPER_PLAYBOOK.md`
- Loop 与 Planner 的系统提示统一注入该规范（`HousekeeperPromptGuide`）
- 目标是把“角色边界 + 决策顺序 + 输出约束”固定化，减少模型自由发挥导致的失稳

## 3. 计划与执行能力

### 3.1 支持动作

- `create`
- `update`
- `delete`

### 3.2 安全/约束（执行侧）

- 删除私有物品时校验负责人权限
- 删除空间时校验负责人权限
- 删除事项时校验负责人权限
- 禁止删除当前登录成员
- 写入成功后再清理附件文件

### 3.3 自动修复

当执行存在失败项且开启 `autoRepair` 时：

1. 汇总失败原因
2. 重规划失败操作
3. 若可执行则重试一次

### 3.4 目标达成校验（新增）

执行完成后会做一轮本地 post-condition 校验：

- 对 `create`：检查目标数量是否增加，并核对关键字段
- 对 `update`：按目标定位并核对关键字段是否已生效
- 对 `delete`：检查目标是否确实不存在

若校验失败，响应仍为 `executed`，但 `ok=false`，并在 `verification` 中给出失败项。

## 4. 前端行为（Dashboard）

- 生成计划已改走 Agent Loop
- “待澄清”交互改为单一自然语言补充框
- 新增“智能推理轨迹”折叠展示（`agentTrace`）
- 新增 Agent 统计摘要（轮次、工具调用、空结果、修复次数）

助手入口支持自然语言继续补充信息；生活数据也可以直接在各功能页编辑。

## 5. Runtime API

### 5.1 监听地址

- `127.0.0.1:48765`

### 5.2 接口

- `GET /housekeeper/health`
- `GET /housekeeper/self-check`
- `POST /housekeeper/execute`

### 5.3 请求体

```json
{
  "instruction": "把示波器状态改成借出并由 Ben 负责",
  "autoExecute": true,
  "autoRepair": true,
  "actorUsername": "ben"
}
```

### 5.4 响应状态

- `clarification_required`
- `planned`
- `executed`

### 5.5 新增可观测字段

- `agentTrace: string[]`（可选）
  - 表示 Agent Loop 每一轮决策与工具观察
- `agentStats`（可选）
  - `rounds / toolCalls / emptyToolResults / invalidDecisionCount / repairedDecisionCount / repeatedToolBlocked / usedFallbackPlan`
- `verification`（可选）
  - `successCount / failureCount / summary / entries[]`

### 5.6 请求头建议

- `Idempotency-Key`：业务请求幂等键
- `X-Request-ID`：链路追踪 ID
- `Authorization: Bearer <token>`（若设置 `BLAB_HOUSEKEEPER_TOKEN`）

### 5.7 自检守卫

`GET /housekeeper/self-check` 会执行内置守卫检查（不依赖外部 LLM）：

- 决策 JSON 解析（直出 / fenced / 嵌入块 / 非法拒绝）
- 循环守卫（重复工具拦截、最大轮次兜底）
- 工具注册表一致性（schema / 校验 / 分发元信息）

当任一检查失败时，接口返回 `HTTP 500` 且 `ok=false`，可直接接入 CI 或本地 preflight。

## 6. 使用示例

### 6.1 健康检查

```bash
curl -s http://127.0.0.1:48765/housekeeper/health
```

### 6.2 执行任务

```bash
curl -s -X POST http://127.0.0.1:48765/housekeeper/execute \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: hk-demo-001' \
  -H 'X-Request-ID: req-demo-001' \
  -d '{"instruction":"删除成员 @temp_user","autoExecute":true,"autoRepair":true,"actorUsername":"ben"}'
```

## 7. openclaw 本地脚本

可直接使用：

- `scripts/openclaw_housekeeper_client.py`
- `scripts/run_housekeeper_self_check.py`

能力：

- 自动健康检查重试
- 幂等键注入
- token 鉴权
- 依据 `status` 返回退出码（`21` 表示需要补充信息，`23` 表示执行成功但目标校验失败）
- 可选交互追问重试（`--interactive-clarification`，自然语言补充后自动续跑）
- 可选输出 Agent 统计（`--show-agent-stats`）
- 可选输出目标校验摘要（`--show-verification`）
- 可选执行 Loop 自检守卫（`run_housekeeper_self_check.py`，失败自动返回非 0）

## 8. 一键构建 DMG

新增脚本：

- `scripts/build_dmg.sh`

执行方式：

```bash
./scripts/build_dmg.sh
```

默认行为：

- 使用 `Release` 配置构建 `Blab`
- 默认构建当前机器架构；需要 universal 时可传入 `BUILD_ARCHS="arm64 x86_64"`
- 自动生成 DMG 到 `dist/`
- 输出带时间戳的版本归档与 latest 命名产物，并生成 `sha256` 文件

可选环境变量：

- `CONFIGURATION`（默认 `Release`）
- `BUILD_ARCHS`（默认当前机器架构）
- `DIST_DIR`（默认 `./dist`）
- `BUILD_LOG`（默认 `./build/blab_build.log`）
- `DERIVED_DATA_PATH`（默认 `./build/DerivedData`）

## 9. 既有助手功能

- [x] 删除操作全链路支持（planner + executor + UI 摘要）
- [x] 澄清交互改为自然语言补充
- [x] 引入 Agent Loop（工具检索 + 多轮决策）
- [x] Runtime 与 Dashboard 接入 Agent Loop
- [x] 增加 `agentTrace` 可观测性
- [x] 增加 `agentStats` 可观测性
- [x] 增加决策修复与参数自纠
- [x] 引入 post-condition verifier（执行后目标达成校验）
- [x] `repairPlan` 升级为 Loop 驱动（自动修复也支持 Tool->Observe->Replan）

## 10. 助手后续事项

### P1 稳定性

- [ ] 增加 Agent Loop 单元测试（决策解析、重复调用守卫、轮次上限）
- [ ] 增加执行回归用例（create/update/delete 权限与附件清理）
- [x] 为 `agentTrace` 增加长度上限与脱敏策略

### P2 能力

- [x] 引入“目标达成校验器”（post-condition verifier）
- [x] 将 `repairPlan` 也升级为 Loop 驱动
- [ ] 增加更细粒度读工具（按 owner/时间范围查询）

### P3 工程化

- [ ] Runtime 增加结构化 metrics（每轮耗时、工具调用次数、失败分布）
- [ ] 提供 debug 开关：导出完整决策快照
- [ ] Hooks事件出发，提供“高风险动作审批模式”（删除前二次确认策略）

## 11. 关键事实与边界

- 当前不是“远端原生 function calling”模式，而是“本地工具编排 + 本地执行器”模式。
- 该模式的优势：可控、可审计、可离线演进。
- 该模式的限制：工具策略与守卫需持续迭代，否则模型仍可能次优决策。
