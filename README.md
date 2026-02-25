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

示例：

```bash
curl -s http://127.0.0.1:48765/housekeeper/health
```

```bash
curl -s -X POST http://127.0.0.1:48765/housekeeper/execute \
  -H 'Content-Type: application/json' \
  -d '{"instruction":"把示波器状态改成借出并由 Ben 负责","autoExecute":true,"actorUsername":"ben"}'
```

鉴权（可选）：

- 如果启动进程设置了环境变量 `BLAB_HOUSEKEEPER_TOKEN`，则请求需提供：
- `Authorization: Bearer <token>` 或 `X-Blab-Token: <token>`

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
