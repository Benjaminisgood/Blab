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

## 项目结构

- `Blab/BlabApp.swift`：应用入口与 SwiftData 容器初始化
- `Blab/ContentView.swift`：主导航与页面路由
- `Blab/Models/`：领域模型与编码/解析逻辑
- `Blab/Services/`：附件存储、种子数据、AI 调用
- `Blab/Views/Sections/`：各业务页面
- `Blab/Views/Components/`：可复用 UI 组件

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

- `~/Library/Containers/BenBenBuBen.Blab/Data/Library/Application Support/Benlab/attachments`

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

