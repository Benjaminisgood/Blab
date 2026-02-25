# Blab

Blab 是原 `Benlab`（Python/Flask）项目的原生 macOS 重写版本，采用 `Swift + SwiftUI + SwiftData`，仅使用本地存储。

## 项目目标

- 完整转向 macOS 原生体验
- 数据本地持久化（不使用 OSS）
- 不做旧 SQLite 迁移，直接使用新数据模型
- 保留原项目核心业务语义（成员、物品、空间、事项、日志、配置）

## 技术栈

- Swift 5
- SwiftUI
- SwiftData（本地持久化）
- App Sandbox（容器内存储）

## 功能概览

- 总览页（Dashboard）
- 事项管理（Events）
- 物品管理（Items）
- 空间管理（Locations）
- 成员管理（Members）
- 操作日志（Logs）
- 设置页（Settings）
- AI 模型/API 可视化配置与连通性测试
- 保姆（自然语言任务规划与执行）
- 本地保姆 Runtime 接口（`localhost`）

## 项目结构

- `Blab/BlabApp.swift`：应用入口与 SwiftData 容器初始化
- `Blab/ContentView.swift`：主导航与页面路由
- `Blab/Models/`：领域模型与编码/解析逻辑
- `Blab/Services/`：附件存储、种子数据、AI 调用、保姆 Runtime
- `Blab/Views/Sections/`：各业务页面
- `Blab/Views/Components/`：可复用 UI 组件

## 保姆 Runtime 接口（仅一个业务入口）

Blab 在应用启动后会尝试监听本地端口：

- `127.0.0.1:48765`

当前对外接口：

- `GET /housekeeper/health`：健康检查
- `POST /housekeeper/execute`：自然语言任务入口（保姆唯一业务入口）

请求体（`POST /housekeeper/execute`）：

```json
{
  "instruction": "新增成员小王，用户名 wangx",
  "autoExecute": true,
  "actorUsername": "ben"
}
```

字段说明：

- `instruction`：自然语言任务（必填）
- `autoExecute`：`false` 时仅返回计划，不执行写入（可选，默认 `true`）
- `actorUsername`：执行日志归属成员用户名（可选）

请求头（建议）：

- `Idempotency-Key`：幂等键，建议每个业务请求唯一（重试同一请求时保持不变）
- `X-Request-ID`：请求追踪 ID（可选，建议由调用方生成）
- `Authorization: Bearer <token>`：当配置了 `BLAB_HOUSEKEEPER_TOKEN` 时必填

关键响应头：

- `X-Idempotency-Replayed: true|false`：是否命中幂等回放
- `Idempotency-Key`：服务端回显的幂等键
- `X-Request-ID`：服务端回显/分配的请求 ID

示例：

```bash
curl -s http://127.0.0.1:48765/housekeeper/health
```

```bash
curl -s -X POST http://127.0.0.1:48765/housekeeper/execute \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: hk-demo-001' \
  -H 'X-Request-ID: req-demo-001' \
  -d '{"instruction":"把示波器状态改成借出并由 Ben 负责","autoExecute":true,"actorUsername":"ben"}'
```

鉴权（可选）：

- 如果启动进程设置了环境变量 `BLAB_HOUSEKEEPER_TOKEN`，则请求需提供：
- `Authorization: Bearer <token>` 或 `X-Blab-Token: <token>`

### 与 openclaw 对接建议

推荐调用顺序：

1. 先调 `GET /housekeeper/health`，确认 `ok=true`。
2. 再调 `POST /housekeeper/execute`。
3. 根据返回 `status` 分支处理：
   - `clarification_required`：把 `clarification` 反馈给用户，拿到补充信息后重试。
   - `planned`：仅生成计划，适合“先确认再写入”模式。
   - `executed`：已执行，检查 `execution.failureCount` 是否为 `0`。
4. 发起写入请求时始终携带 `Idempotency-Key`，避免网络重试导致重复写入。

`openclaw` 请求模板：

```json
{
  "instruction": "把示波器状态改成借出并由 Ben 负责",
  "autoExecute": true,
  "actorUsername": "ben"
}
```

返回示例（已执行）：

```json
{
  "ok": true,
  "status": "executed",
  "message": "执行完成：成功 1 条，失败 0 条。",
  "clarification": null,
  "plan": { "operations": [] },
  "execution": {
    "successCount": 1,
    "failureCount": 0,
    "summary": "执行完成：成功 1 条，失败 0 条。",
    "entries": []
  }
}
```

调用策略建议：

- `health` 可短超时（例如 2~3 秒）并允许重试。
- `execute` 涉及写入时，不建议自动重试同一请求；应先检查上次执行结果再决定是否补发。
- 若必须重试同一业务请求，请复用同一个 `Idempotency-Key`，并检查响应头 `X-Idempotency-Replayed`。

### openclaw 本地适配脚本

提供了一个可直接复用的脚本：

- `scripts/openclaw_housekeeper_client.py`

脚本能力：

- 自动健康检查重试
- 自动注入幂等键（可自定义）
- 支持 `--request-id` 透传 `X-Request-ID`
- 可选 Token 鉴权
- 标准错误输出请求追踪摘要（`request_id / idempotency_key / replayed`）
- 根据 `clarification/planned/executed` 返回不同退出码

退出码约定：

- `0`：成功（`planned` 或 `executed` 且失败数为 0）
- `10`：健康检查失败
- `20`：HTTP 错误（4xx/5xx）
- `21`：需要补充信息（`clarification_required`）
- `22`：执行已完成但存在失败项

示例（执行模式）：

```bash
./scripts/openclaw_housekeeper_client.py \
  --instruction "把示波器状态改成借出并由 Ben 负责" \
  --actor-username ben
```

示例（只生成计划）：

```bash
./scripts/openclaw_housekeeper_client.py \
  --instruction "新增成员小王，用户名 wangx" \
  --plan-only
```

## 运行方式

### 使用 Xcode

1. 打开 `Blab.xcodeproj`
2. 选择 Scheme：`Blab`
3. 选择运行目标：`My Mac`
4. Run

### 命令行构建

```bash
xcodebuild -project Blab.xcodeproj -scheme Blab -destination 'platform=macOS' build
```

## 数据存储说明

### SwiftData 数据库（非附件）

默认位于应用容器的 Application Support 下：

- `~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application Support/default.store`
- `~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application Support/default.store-wal`
- `~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application Support/default.store-shm`

### 附件目录

- `~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application Support/Blab/attachments`

## 数据库导出与复用

请在应用退出后执行，建议始终一起备份 `store + wal + shm` 三个文件。

```bash
mkdir -p ~/Desktop/BlabDBBackup
cp ~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application\ Support/default.store* ~/Desktop/BlabDBBackup/
```

恢复（目标应用退出状态）：

```bash
cp ~/Desktop/BlabDBBackup/default.store* ~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application\ Support/
```

## 设计约束

- 仅本地存储
- 不接入 OSS
- 不包含旧数据库自动迁移
- 默认面向最新 macOS 版本
- 对外仅暴露保姆入口，不直接暴露内部领域写入接口

## 实施记录（动态）

### 2026-02-25

- 决策：对外 Runtime 仅保留 `POST /housekeeper/execute`，避免直接暴露内部领域 API。
- 实施：新增 `HousekeeperRuntimeService`，在应用启动时自动监听本地端口并接入现有计划/执行链路。
- 改名：UI 与系统提示中的“助理”调整为“保姆”。
- 安全：默认只允许本机回环地址连接；支持可选 token 鉴权（`BLAB_HOUSEKEEPER_TOKEN`）。
- 验证：`xcodebuild` 编译通过，并已通过 `curl http://127.0.0.1:48765/housekeeper/health` 返回 JSON 健康状态。
- 联调：`/housekeeper/execute` 已通到保姆链路；若上游 AI 配置异常（如 TLS/API Key）会按错误原样返回。
- 增强：设置页新增 Runtime 状态卡（监听状态、请求统计、鉴权提示、命令复制）。
- 文档：补充 openclaw 对接顺序、状态分支处理与调用模板。
- 运行观测：服务侧新增 Runtime 快照（状态文本、最近请求、返回码、最近错误）。
- 回归验证：二次构建通过，并再次确认 `GET /housekeeper/health` 正常返回。
- 防重写入：`POST /housekeeper/execute` 支持 `Idempotency-Key`，重复请求可回放上次结果。
- 接入工具：新增 `scripts/openclaw_housekeeper_client.py`（健康检查、幂等、鉴权、状态分支退出码）。
- 联调验证：同一幂等键二次请求返回 `X-Idempotency-Replayed: true`；同键不同请求返回 `409`。
- 脚本验证：`openclaw_housekeeper_client.py` 在 `clarification_required` 场景返回退出码 `21`，二次同键请求 `replayed=true`。
- 链路追踪：`execute` 响应支持 `requestID` 字段与 `X-Request-ID` 响应头，执行日志会附带 `request_id`。
- 持久幂等：幂等缓存落盘到本地 Application Support，应用重启后仍可命中回放。
- 修复：持久幂等恢复时补齐 `JSONDecoder.iso8601` 日期解码，解决重启后缓存读取失败问题。
- 复测：`Idempotency-Key=hk-persist-test-002` 跨重启复发同请求返回 `X-Idempotency-Replayed: true`，请求追踪头为新值。
- 一致性：幂等回放响应会重写 JSON body 的 `requestID` 为当前请求 ID，避免 header/body 不一致。
- 验证：`Idempotency-Key=hk-replay-id-sync-002` 二次请求返回 `X-Idempotency-Replayed: true`，且 body 中 `requestID=req-sync2-b`。
