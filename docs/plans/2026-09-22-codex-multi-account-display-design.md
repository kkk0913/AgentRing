# Codex 多账号同时显示 · 设计文档

日期：2026-09-22
状态：已评审定稿

## 背景与目标

当前应用支持配置多个 Codex 账号（`UserSettings.codexAccounts`），但整条数据链路是单账号的：`DataRefreshManager` 只拉取"当前账号"（`currentCodexAccountId`）的用量，产出单个 `CodexUsageData`，弹窗、菜单栏、通知、蓝牙副屏均只消费这一个数据。切换账号依赖菜单栏子菜单手动切换。

**目标**：多个 Codex 账号的用量**同时拉取、同时展示**——弹窗面板每账号一列，菜单栏每账号一组圆环簇，视觉与交互完全复用现有的"多平台并排"模式。

## 已确认的决策

| 决策点 | 结论 |
| :--- | :--- |
| 展示范围 | 弹窗面板 + 菜单栏图标同时多账号展示；蓝牙副屏协议不变 |
| 菜单栏形态 | 每账号一组圆环簇横向并排，复用多平台模式；不加账号标识 |
| 弹窗形态 | 全部平铺并排；5 列及以上封顶 1040pt 并折成两行网格 |
| 账号顺序 | 默认 = 配置顺序；认证设置页账号列表支持拖拽排序 |
| 选中语义 | 认证页账号单选框改**复选框**：勾选 = 启用（拉取 + 展示），未勾选 = 保留登录态但不参与 |
| 蓝牙副屏 | 只推**勾选中的第一个**账号，JSON 帧格式不变，三个副屏仓库零改动 |
| 通知 | 按账号独立触发，文案带账号别名 |
| 当前账号机制 | 移除 `currentCodexAccountId` 与"切换账号"子菜单 |
| 菜单栏 tooltip | 显示单元清单（别名 + 百分比） |

## 1. 数据模型与刷新层

新增按账号的用量容器：

```swift
struct CodexAccountUsage: Identifiable {
    let accountId: UUID
    var usage: CodexUsageData?      // 该账号用量
    var needsRelogin: Bool          // 该账号 session 过期
    var errorMessage: String?
}
```

- `DataRefreshManager` 中 `@Published var codexUsageData: CodexUsageData?` 替换为 `@Published var codexAccountUsages: [CodexAccountUsage]`。
- **数组顺序 = 启用账号（勾选）在 `UserSettings.codexAccounts` 中的配置顺序**；弹窗、菜单栏、副屏（取第一个）统一从这里取，不再查询"当前账号"。
- **并发拉取**：`CodexAPIService` 保持单实例职责不变，改为按账号持有实例池 `[UUID: CodexAPIService]`。每次刷新对所有启用账号并行发起 `fetchUsage`；accessToken 缓存、OAuth 单飞合并、`refresh_token` 轮换写回均按实例隔离，写回目标为对应账号的 `Account.credentialToken`。
- 账号启用/新增时创建实例；停用/删除时清掉该账号的用量、token 缓存与定时器。未勾选账号不拉取、不展示。

## 2. 认证、过期处理与通知

- **过期隔离**：session 过期只把对应 `CodexAccountUsage.needsRelogin = true` 并清该账号 `usage`，其他账号照常刷新。弹窗该账号列显示"重新登录"（复用现有列内 UI，按列绑定）；重新登录成功后仅重置并刷新该账号。
- **Token 主动刷新**：10 分钟定时器 `proactivelyRefreshIfNeeded` 遍历实例池逐账号保活；`refresh_token` 轮换静默写回落到各自账号。
- **通知**：`NotificationManager` 传入"发起检查的账号 id"（key 已是 `provider:accountId:type` 格式），多账号并行拉取后逐账号 `checkAndNotify`，通知文案带账号别名（如"工作号 已用 90%"）。告急阈值判断、重置验证定时器按账号各挂一套，定时器 id 加账号 id 后缀。
- **失败降级**：单账号网络失败不影响其他账号的 `pendingFetches` 与刷新节奏；全部启用账号失败才走整体错误提示。

## 3. 弹窗面板布局

- 渲染粒度从"平台"换成**展示单元**（平台 + 账号）：`[Codex账号1, Codex账号2, …, Cursor, Antigravity…]`，Codex 账号顺序 = 配置顺序。
- 账号列直接复用 `CodexColumnView`（接收单个 `CodexUsageData`）；列标题显示账号别名（无别名显示账号名）；多列顶部保留"Agent Ring · 已用/剩余"总标题行。
- **宽度档位**：1 列 320pt、2 列 580、3 列 860、4 列 1040；**5 列及以上封顶 1040pt，折成两行网格**（放不下的往下排，列宽按行内列数取档）。
- **排序**：跨平台拖拽排序（`orderedProviders`）保留，粒度为平台组（整组 Codex 账号一起移动）；组内账号顺序跟随认证设置页拖拽结果。
- **加载态**：刷新中动画、过期重登录按账号粒度独立显示（`isRefreshingProvider` 带账号粒度）。

## 4. 菜单栏图标

- `MenuBarIconRenderer.buildIcon` 遍历展示单元列表：每个 Codex 账号生成一组圆环簇（复用 `buildCodexCluster`，传入该账号 `CodexUsageData`），统一 4px 间距横排，顺序 = 配置顺序，**不加账号标识**。
- 显示模式全部保持：`iconOnly` 下品牌 logo 只出现一次（不按账号重复）；`percentageOnly` / `both` 规则不变；单色模板、虚线底轨不动。
- 无数据/过期的单元跳过不画；全部单元无数据才显示占位灰环。
- 宽度随单元数线性增长（约 26pt/单元），不做封顶或轮播；超过 6 个单元在设置页提示文案。
- `NSStatusBarButton.toolTip` 显示单元清单（别名 + 百分比）。

## 5. 认证设置页

- 账号卡片的单选框改为**复选框**：勾选 = 启用监控与展示，未勾选 = 保留登录态但不拉取、不展示。副屏同步"第一个"= 勾选中的第一个。
- 账号列表支持**拖拽排序**（SwiftUI `List` 的 `.onMove`），持久化为 `codexAccounts` 数组顺序；新增 `UserSettings.moveCodexAccount(from:to:)`。
- 卡片内加一行说明文案，提示"仅勾选账号参与展示；副屏同步勾选中的第一个账号"。
- 范围说明：复选框与拖拽排序**仅作用于 Codex 账号卡片**（本期范围）；Cursor 账号卡片维持现状单选。（待确认项，如需 Cursor 同步支持可另行扩展。）

## 6. 副屏、兼容与诊断

- **蓝牙/BLE 副屏**：`BluetoothPayload` / `BLESyncService` 取 `codexAccountUsages.first` 组装 payload，JSON 帧格式不变；蓝牙设置卡片加一行"当前同步账号：xxx（勾选中的第一个）"。
- **数据兼容**：`Account` 钥匙串存储结构不动，无迁移。移除 `currentCodexAccountId` 时清理旧 UserDefaults key。升级后首次启动多账号即同时拉取。
- **诊断**：`DiagnosticManager` 遍历所有启用账号逐个出结果（复用 `ProviderDiagnosticResult`，带账号别名），多账号过期可各自定位。

## 7. 测试与验收

单测（延续 `Tests/` 现有风格）：

1. 多账号并行拉取：mock API 验证 N 账号各自入库、顺序 = 配置顺序
2. 单账号过期隔离：账号 A 401 不影响账号 B，A 列单独显示重登录
3. `refresh_token` 轮换写回落到正确账号
4. 停用/删除账号后其用量、定时器、通知状态清理干净
5. 副屏 payload 与改动前逐字节一致（取第一个启用账号时）
6. 复选框停用账号不拉取、不展示，登录态保留

手动验收：

- 菜单栏多簇顺序与配置一致、无冗余 logo、tooltip 清单正确
- 弹窗 5+ 列折成两行、列标题显示别名、每列独立刷新/过期态
- 通知文案带账号别名、按账号独立触发
- 副屏显示勾选中的第一个账号

## 8. 开发顺序

1. 数据层（§1）→ 2. 认证与通知（§2）→ 3. 弹窗（§3）→ 4. 菜单栏（§4）→ 5. 认证设置页（§5）→ 6. 副屏与收尾（§6、§7）

每步可独立编译；数据层落地时同步移除 `currentCodexAccountId` 及切换子菜单。
