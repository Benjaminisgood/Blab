# Blab 架构与本地开发

Blab 的核心是 macOS 上的个人生活数据：日程、物品、空间、成员，以及衣橱与穿搭。SwiftUI 负责交互，SwiftData 负责本地持久化。自然语言助手是可选入口；手动记录、今日概览和衣橱建议不依赖模型服务。

## 分层与数据流

```text
BlabApp → AppPersistence → SwiftData ModelContainer
   └─ ContentView：侧栏、当前成员、通知导航
       ├─ DashboardSectionView → LifeOverview → 今日 / 后续 / 未排期
       ├─ WardrobeSectionView → 衣物、搭配建议、预览、穿搭记录
       ├─ Events / Items / Locations / Members / Logs
       └─ DashboardHousekeeperCard → Agent Loop → Plan → Executor

衣物照片 → ImageIO 限尺寸解码 → 可选 Vision 去背景
         → 本地 PNG 文件 → SwiftData 中的相对文件引用

可选自然语言指令 → HousekeeperAgentLoopService
                  → 应用内只读检索 → AgentPlannerService
                  → 可审阅的 AgentPlan → AgentExecutorService
                  → SwiftData 写入 → HousekeeperPostConditionVerifier
```

| 层 | 主要代码 | 责任 |
| --- | --- | --- |
| 应用入口 | `Blab/BlabApp.swift`、`Blab/App/AppPersistence.swift` | 生命周期、统一模型注册、持久化与预览隔离 |
| 导航 | `Blab/ContentView.swift`、`Blab/App/SidebarSection.swift` | 侧栏、当前成员、页面入口 |
| 既有领域 | `Blab/Models/DomainModels.swift`、`DomainTypes.swift` | 成员、事项、物品、空间、附件、日志、AI 设置 |
| 今日概览 | `Blab/Services/LifeOverview.swift` | 可独立验证的日期区间计算；跨天事项、进行中、未排期 |
| 衣橱 | `WardrobeModels.swift`、`WardrobeTypes.swift`、`OutfitRecommendationService.swift`、`WardrobeSectionView.swift` | 在既有生活数据上增加衣物与穿搭记录；用值类型快照连接持久化、推荐与渲染 |
| 图片处理 | `Blab/Services/WardrobePhotoService.swift` | 本地图片解码、前景分割、PNG 转换与照片文件存取 |
| 可选助手 | `Blab/Services/Housekeeper*.swift`、`Agent*.swift` | 规划、执行、结果校验及本地 Runtime |

现有通用 CRUD 页面仍直接使用 `ModelContext`。本轮增加的日程计算和图片处理从视图中独立出来，衣橱写入使用单独的 `ModelContext`，关闭自动保存，失败时回滚该次操作。图片保存失败或模型写入失败会清理本次尚未提交的照片文件，避免回滚其他窗口的编辑。后续功能可沿用“持久化模型 + 独立规则服务 + 页面”的结构，再按实际复杂度提取事务与仓储边界。

## 衣橱与渲染边界

衣橱作为独立领域增量加入同一个本地 schema，旧物品和衣物可以并存。现有物品不会自动被推断或转换为衣物。

推荐按当前成员、衣物状态、关联物品可用性、温度、季节与场合筛选，再考虑颜色和穿着轮换。推荐结果与已保存记录使用值类型快照；保存计划不会记录已穿。日期选择器只显示日期，推荐会将所选“今天”解析为当前时间，使刚标记的实际穿着可以立即参与推荐。

照片处理使用 Apple 的 ImageIO、Vision 和 Core Image，在设备上执行。输入图片先限尺寸解码；去背景失败时应保留原图并让用户选择继续。衣物照片保存在应用管理的目录，模型保存文件名引用，不将大图塞进通用 JSON 字段。

穿搭渲染目前是衣物搭配的二维视觉预览。搭配建议依据用户输入的衣物属性、温度和场景生成。它不是人体尺寸测量、三维布料仿真或真人虚拟试衣，也不自动查询天气。今后接入天气或生成式试衣应作为明确可选的服务，标明上传内容、结果来源与成本。

## 存储与兼容

- `AppPersistence.schema` 集中注册既有模型与衣橱模型，应用和存储校验共享同一份注册表。
- 正常运行继续使用应用的 SwiftData 持久化存储，不删除或重建用户已有数据库。
- 既有附件由 `AttachmentStore` 管理，衣橱照片存于其应用支持目录下的 `wardrobe/`。
- 已使用临时数据库完成旧 schema 创建、增量加入衣橱模型、保存和重开检查。该证据覆盖生成的测试数据库，不代表用户真实历史数据库已验证。
- `SeedDataService` 仅在没有成员时创建“我”的本机资料，不再向正常存储填充示例社区物品和活动；`PreviewDataService` 只在独立预览中创建示例衣橱与日程。
- 当前成员是本机数据的交互身份。成员切换不构成账号登录认证，不能把它当作多用户安全隔离。

## 可选 AI 与 Runtime

`AIChatService` 将明确触发的助手请求发送给设置中的模型服务。模型提供商、地址与凭据沿用已有配置；衣橱本地处理不需要这些配置。

Runtime 使用 Network.framework，端口为 `48765`，提供健康检查、自检和执行接口。连接处理只接受 loopback 来源，`BLAB_HOUSEKEEPER_TOKEN` 设置后要求 Bearer token。它面向受信任的本机客户端，并不是公网服务或独立用户权限系统。

助手的目标校验是执行证据：可以检测部分操作未达成，不能将它视为用户认可。自然语言输入、结构化计划、执行结果和最终用户选择应保持区分。

## 已有架构中仍需处理的事项

以下是源代码审阅发现的后续工程重点，不表示本轮已经实现：

1. **执行事务边界。** `AgentExecutorService` 当前按操作捕获错误，但部分字段可能先被修改、后续校验才失败；失败操作没有独立回滚。应先完整校验操作，再在明确事务中写入；保存失败时也应避免把相关条目标记为成功。
2. **凭据存储。** `AISettings.apiKey` 与成员中名为 `passwordHash` 的字段目前存在直接存值路径。迁入 Keychain 或移除不需要的口令流程，应单独设计兼容与恢复策略。
3. **错误反馈。** 部分既有页面使用 `try? modelContext.save()`，失败没有用户可见反馈。应逐个写入入口改成可恢复的错误处理。
4. **Runtime 可靠性。** 当前幂等缓存保存已完成响应；并发的同 key 请求在缓存写入前仍可能同时开始处理。后续应增加运行中请求去重和连接超时，并验证执行失败后的状态一致性。

## 开发与验证

工程为 `Blab.xcodeproj`，可运行 scheme 为 `Blab`，最低部署版本为 macOS 26.1。需要完整 Xcode；仅安装 Command Line Tools 不够。

```bash
# 正常开发运行：仅关闭本工作区相同构建路径的进程，然后构建并启动
./script/build_and_run.sh

# 独立预览：适合 UI 检查，不打开正常数据库
./script/build_and_run.sh --preview --verify

# 编译检查，不停止或启动应用
./script/build_and_run.sh --build-only

# 调试或查看日志
./script/build_and_run.sh --preview --debug
./script/build_and_run.sh --preview --logs
```

脚本使用本命令的 `DEVELOPER_DIR`；如果系统选择的是 Command Line Tools，会尝试 `/Applications/Xcode.app`。不会修改全局 `xcode-select`。使用其他 Xcode 安装时可显式传入 `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`。

本地 Debug 构建使用 ad hoc 签名以保留沙盒配置，不要求原作者的签名身份。这不是用于分发或公证的产物。原有 `scripts/build_dmg.sh` 仍是独立的打包入口。

正常构建产物在 `build/DerivedData/`；预览产物在 `build/PreviewDerivedData/`，使用独立 bundle ID `BenBenBuBen.Blab.Preview`。预览通过 `open --env BLAB_PREVIEW=1` 启用内存数据库、隔离偏好和临时附件目录，并禁用 Runtime 与通知。预览数据不写入正常生活记录，退出后不保留数据库。

`--verify` 只确认这次构建的准确可执行文件持续运行，不能代替窗口检查或功能测试。构建日志分别是 `build/development-build.log` 与 `build/preview-build.log`。Codex 的 Run 按钮通过 `.codex/environments/environment.toml` 调用同一个脚本。

已完成正常版本编译、原生预览构建与启动、深色外观下的主要页面操作、自由搭配、真实保存面板 PNG 导出，以及本地 PNG 导入与 Vision 动作执行。自动化检查共 91 项，包含 79 项衣橱 / 存储检查和 12 项日程检查；存储检查使用与应用相同的 `AppPersistence.schema`，并覆盖正常新库的干净初始化与幂等性。具体范围及最终集成状态见 [QA.md](QA.md)。
