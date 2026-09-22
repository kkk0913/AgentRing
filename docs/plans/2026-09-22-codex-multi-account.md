# Codex 多账号同时显示 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use the executing-plans skill to implement this plan task-by-task.

**Goal:** 多个 Codex 账号同时拉取并同时展示——弹窗每账号一列、菜单栏每账号一组圆环簇，复用现有"多平台并排"视觉；认证页单选改复选 + 拖拽排序；副屏协议不变、只推勾选中的第一个账号。

**Architecture:** 数据层把单个 `CodexUsageData?` 换成按账号的 `codexAccountUsages: [CodexAccountUsage]`（顺序 = 配置顺序），`CodexAPIService` 改为按账号持有实例池并行拉取，token 缓存/轮换写回按账号隔离。展示层引入"展示单元"（Codex 账号 / Cursor / Antigravity）概念，菜单栏与弹窗都按单元并排渲染。纯决策逻辑集中在 `MultiAccountPlanning`（Foundation-only），用项目现有的 Checks 脚本风格做 TDD。

**Tech Stack:** Swift 5 / SwiftUI / AppKit（NSStatusItem、NSPopover）/ Combine；测试 = `swift` 直跑的 Checks 脚本（`Scripts/test-*.sh` + `Tests/*Checks.swift`）；构建 = `xcodebuild -project AgentRing.xcodeproj -scheme AgentRing`。

**设计文档:** `docs/plans/2026-09-22-codex-multi-account-display-design.md`（决策依据，冲突时以它为准）

**约定:**
- 所有路径相对仓库根（`AgentRing/`）。
- 每个 Task 结束 commit（`feat:` / `refactor:` 前缀，中文或英文均可，参考 `git log` 风格）。
- 编译验证命令：`xcodebuild -project AgentRing.xcodeproj -scheme AgentRing -configuration Debug -derivedDataPath ./build-temp build`（下文简称 **BUILD**）。执行任务的环境若无 Xcode，把编译验证降级为 `swiftc -parse` 语法检查并在最终报告注明。
- 本地化：所有用户可见文案必须同时加 `AgentRing/AgentRing/Resources/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`，并通过 `L.xxx`（`Helpers/LocalizationHelper.swift`）访问。新增 L 键时照抄现有键的包装方式。

---

## Task 1: 纯逻辑核心 `MultiAccountPlanning`（TDD）

**Files:**
- Create: `AgentRing/AgentRing/Models/MultiAccountPlanning.swift`
- Test: `Tests/MultiAccountPlanningChecks.swift`
- Create: `Scripts/test-multi-account-planning.sh`
- Modify: `.github/workflows/ci.yml`

**背景:** 项目的测试风格是：`Tests/*Checks.swift` 为自包含 swift 脚本，带 `check(_:_:)` 断言助手（见 `Tests/RingDisplayChecks.swift` 尾部），由 `Scripts/test-*.sh` 执行，CI 逐个调用。本 Task 用"纯逻辑文件 + 检查文件 cat 后 `swift` 直跑"的方式避免复制逻辑（DRY）。

**Step 1: 写失败的检查**

创建 `Tests/MultiAccountPlanningChecks.swift`（不含实现，只含断言）：

```swift
import Foundation

// 与 AgentRing/Models/MultiAccountPlanning.swift 由 Scripts/test-multi-account-planning.sh
// 拼接后一起执行。

func check(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
    print("PASS: \(msg)")
}

let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
let c = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

// 1. 启用账号顺序 = 配置顺序（不是 Set 顺序）
check(
    MultiAccountPlanning.enabledAccountIDs(accountIDs: [a, b, c], disabledIDs: [c]) == [a, b],
    "enabled accounts keep config order"
)

// 2. 全部禁用 / 全部启用 / 空表
check(
    MultiAccountPlanning.enabledAccountIDs(accountIDs: [a, b], disabledIDs: [a, b]).isEmpty,
    "all disabled yields empty"
)
check(
    MultiAccountPlanning.enabledAccountIDs(accountIDs: [a, b], disabledIDs: []) == [a, b],
    "no disabled keeps order"
)
check(
    MultiAccountPlanning.enabledAccountIDs(accountIDs: [], disabledIDs: [a]).isEmpty,
    "empty accounts yields empty"
)

// 3. 副屏同步账号 = 勾选中的第一个
check(
    MultiAccountPlanning.bluetoothCodexAccountID(accountIDs: [a, b, c], disabledIDs: [a]) == b,
    "bluetooth picks first enabled account"
)
check(
    MultiAccountPlanning.bluetoothCodexAccountID(accountIDs: [a, b], disabledIDs: [a, b]) == nil,
    "bluetooth nil when none enabled"
)

// 4. 弹窗折行：≤4 一行；≥5 封顶每行 4 个，余数成第二行
check(MultiAccountPlanning.rowWidths(unitCount: 1) == [1], "1 unit single row")
check(MultiAccountPlanning.rowWidths(unitCount: 4) == [4], "4 units single row")
check(MultiAccountPlanning.rowWidths(unitCount: 5) == [4, 1], "5 units wrap to 2 rows")
check(MultiAccountPlanning.rowWidths(unitCount: 8) == [4, 4], "8 units two even rows")
check(MultiAccountPlanning.rowWidths(unitCount: 0) == [], "0 units no rows")

// 5. 展示单元顺序：Codex 账号（配置顺序）→ Cursor → Antigravity 两个
let units = MultiAccountPlanning.displayUnits(
    codexAccountIDs: [a, b],
    disabledCodexIDs: [],
    hasCursor: true,
    hasAntigravity: true
)
check(
    units == [.codexAccount(a), .codexAccount(b), .cursor, .antigravity, .antigravityThird],
    "display units: codex accounts in order then other providers"
)

// 6. 展示单元：禁用账号不出现在展示单元里
let units2 = MultiAccountPlanning.displayUnits(
    codexAccountIDs: [a, b],
    disabledCodexIDs: [a],
    hasCursor: false,
    hasAntigravity: false
)
check(units2 == [.codexAccount(b)], "disabled account excluded from display units")
```

**Step 2: 写 runner 并确认失败**

创建 `Scripts/test-multi-account-planning.sh`：

```bash
#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -t multi-account-planning)"
trap 'rm -f "$TMP"' EXIT

# 纯逻辑与检查拼成单文件执行（swift 脚本模式只接受一个输入文件）
cat "$REPO_ROOT/AgentRing/AgentRing/Models/MultiAccountPlanning.swift" \
    "$REPO_ROOT/Tests/MultiAccountPlanningChecks.swift" > "$TMP"
swift "$TMP"
```

`chmod +x Scripts/test-multi-account-planning.sh`，运行 `bash Scripts/test-multi-account-planning.sh`。
Expected: 编译失败 `cannot find 'MultiAccountPlanning' in scope`。

**Step 3: 最小实现**

创建 `AgentRing/AgentRing/Models/MultiAccountPlanning.swift`（注意：本文件会被 cat 进 swift 脚本执行，**只能依赖 Foundation，禁止 AppKit/SwiftUI/UserSettings**，且不要写 `import` 之外的顶层语句）：

```swift
//
//  MultiAccountPlanning.swift
//  Agent Ring
//

import Foundation

/// 多账号展示/同步的纯决策逻辑（顺序、启停过滤、折行），供 UI、菜单栏、副屏共用。
/// 仅依赖 Foundation，可被 Tests 直接拼接执行（见 Scripts/test-multi-account-planning.sh）。
enum MultiAccountPlanning {
    /// 每个展示单元在菜单栏约占 22pt（圆环）+ 4pt 间距
    static let menuBarUnitWidth: CGFloat = 26
    /// 弹窗单行最多 4 列，超出折行
    static let maxColumnsPerRow = 4

    struct DisplayUnit: Equatable {
        enum Source: Equatable {
            case codexAccount(UUID)
            case cursor
            case antigravity
            case antigravityThird
        }
        let source: Source
    }

    /// 启用的 Codex 账号 id，顺序 = 配置顺序（disabledIDs 中的被过滤）
    static func enabledAccountIDs(accountIDs: [UUID], disabledIDs: Set<UUID>) -> [UUID] {
        accountIDs.filter { !disabledIDs.contains($0) }
    }

    /// 副屏同步的 Codex 账号：勾选中的第一个；全禁用/无账号时为 nil
    static func bluetoothCodexAccountID(accountIDs: [UUID], disabledIDs: Set<UUID>) -> UUID? {
        enabledAccountIDs(accountIDs: accountIDs, disabledIDs: disabledIDs).first
    }

    /// 展示单元序列：Codex 账号（配置顺序）→ Cursor → Antigravity → AntigravityThird
    static func displayUnits(
        codexAccountIDs: [UUID],
        disabledCodexIDs: Set<UUID>,
        hasCursor: Bool,
        hasAntigravity: Bool
    ) -> [DisplayUnit] {
        var units: [DisplayUnit] = enabledAccountIDs(accountIDs: codexAccountIDs, disabledIDs: disabledCodexIDs)
            .map { DisplayUnit(source: .codexAccount($0)) }
        if hasCursor { units.append(DisplayUnit(source: .cursor)) }
        if hasAntigravity {
            units.append(DisplayUnit(source: .antigravity))
            units.append(DisplayUnit(source: .antigravityThird))
        }
        return units
    }

    /// 弹窗折行：每行至多 maxColumnsPerRow 列，返回每行的列数
    static func rowWidths(unitCount: Int, maxPerRow: Int = maxColumnsPerRow) -> [Int] {
        guard unitCount > 0, maxPerRow > 0 else { return [] }
        var rows: [Int] = []
        var remaining = unitCount
        while remaining > 0 {
            let row = min(maxPerRow, remaining)
            rows.append(row)
            remaining -= row
        }
        return rows
    }
}
```

`DisplayUnit` 补 `init(source:)` 合成（用 `let source` 即可，`DisplayUnit(source:)` 自动可用）；若 checks 中 `[.codexAccount(a), ...]` 推断失败，把 checks 中的数组显式标为 `[MultiAccountPlanning.DisplayUnit]`。

**Step 4: 跑检查确认通过**

Run: `bash Scripts/test-multi-account-planning.sh`
Expected: 全部 `PASS:`，exit 0。

**Step 5: 接入 CI**

`.github/workflows/ci.yml` 的 "Validate ring display logic" 步骤后加：

```yaml
      - name: Validate multi-account planning
        run: bash Scripts/test-multi-account-planning.sh
```

**Step 6: Commit**

```bash
git add AgentRing/AgentRing/Models/MultiAccountPlanning.swift \
        Tests/MultiAccountPlanningChecks.swift \
        Scripts/test-multi-account-planning.sh \
        .github/workflows/ci.yml
git commit -m "feat: add MultiAccountPlanning pure core with checks"
```

---

## Task 2: 数据模型 `CodexAccountUsage` + UserSettings 启停与排序

**Files:**
- Create: `AgentRing/AgentRing/Models/CodexAccountUsage.swift`
- Modify: `AgentRing/AgentRing/Models/UserSettings.swift`
- Modify: `AgentRing/AgentRing/Resources/zh-Hans.lproj/Localizable.strings`、`en.lproj/Localizable.strings`（本 Task 可先不加文案，Task 11 统一加；如编译需要 L 键则随手补）

**Step 1: 创建按账号的用量容器**

`AgentRing/AgentRing/Models/CodexAccountUsage.swift`：

```swift
//
//  CodexAccountUsage.swift
//  Agent Ring
//

import Foundation

/// 单个 Codex 账号的用量与状态。
struct CodexAccountUsage: Identifiable, Equatable {
    let accountId: UUID
    var displayName: String
    var usage: CodexUsageData?
    var needsRelogin: Bool = false
    var errorMessage: String?

    var id: UUID { accountId }
}
```

（`CodexUsageData` 是 struct 且字段都是值类型，`Equatable` 若因 `CodexUsageData` 缺声明而失败，给 `CodexUsageData` 加空扩展 `extension CodexUsageData: Equatable {}` 或在 `Models/CodexUsageData.swift` 的声明处补 `Equatable`。）

**Step 2: UserSettings 增加启停集合与排序/访问方法**

在 `Models/UserSettings.swift`：

1. 新增存储属性（放在 `codexAccounts` 附近）：

```swift
    /// 停用的 Codex 账号 id（持久化到 UserDefaults；缺省空集 = 全部启用，兼容旧数据）
    @Published var disabledCodexAccountIds: Set<UUID> = [] {
        didSet {
            defaults.set(disabledCodexAccountIds.map(\.uuidString), forKey: "disabledCodexAccountIds")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }
```

2. `init()` 中在 `codexAccounts` 赋值之后加载：

```swift
        if let rawDisabled = defaults.array(forKey: "disabledCodexAccountIds") as? [String] {
            disabledCodexAccountIds = Set(rawDisabled.compactMap(UUID.init(uuidString:)))
        } else {
            disabledCodexAccountIds = []
        }
```

3. 新增计算属性与方法（放在 `removeCodexAccount` 附近）：

```swift
    /// 启用且有凭据的 Codex 账号，顺序 = 配置顺序
    var enabledCodexAccounts: [Account] {
        MultiAccountPlanning.enabledAccountIDs(
            accountIDs: codexAccounts.map(\.id),
            disabledIDs: disabledCodexAccountIds
        ).compactMap { id in codexAccounts.first { $0.id == id } }
    }

    /// 副屏同步账号：勾选中的第一个
    var bluetoothCodexAccount: Account? {
        guard let id = MultiAccountPlanning.bluetoothCodexAccountID(
            accountIDs: codexAccounts.map(\.id),
            disabledIDs: disabledCodexAccountIds
        ) else { return nil }
        return codexAccounts.first { $0.id == id }
    }

    /// 按账号取凭据（多账号并行拉取用）
    func codexAccountToken(_ accountId: UUID) -> String {
        codexAccounts.first { $0.id == accountId }?.credentialToken ?? ""
    }

    func isCodexAccountEnabled(_ accountId: UUID) -> Bool {
        !disabledCodexAccountIds.contains(accountId)
    }

    func setCodexAccountEnabled(_ account: Account, enabled: Bool) {
        if enabled {
            disabledCodexAccountIds.remove(account.id)
        } else {
            disabledCodexAccountIds.insert(account.id)
        }
        postAccountChanged()
    }

    /// 拖拽排序：按 fromOffsets 移动到 toOffset（SwiftUI List .onMove 回调原样传入）
    func moveCodexAccounts(from source: IndexSet, to destination: Int) {
        codexAccounts.move(fromOffsets: source, toOffset: destination)
        postAccountChanged()
    }

    /// 按账号静默更新 session-token（refresh_token 轮换写回）
    func silentlyUpdateCodexSessionToken(accountId: UUID, token: String) {
        guard let index = codexAccounts.firstIndex(where: { $0.id == accountId }),
              codexAccounts[index].credentialToken != token else { return }
        codexAccounts[index].credentialToken = token
        Logger.settings.notice("Codex session-token 已静默更新（账号: \(self.codexAccounts[index].displayName, privacy: .public)）")
    }
```

4. 修改 `hasValidCodexCredentials`（现在语义 = 存在任一启用账号）：

```swift
    var hasValidCodexCredentials: Bool {
        !enabledCodexAccounts.isEmpty
            && enabledCodexAccounts.contains { !$0.credentialToken.isEmpty }
    }
```

（`codexSessionToken` 暂留——Task 4 才把 `CodexAPIService` 切到按账号；Task 4 完成后删除它。）

**Step 3: BUILD 编译通过**

注意 `UserSettings.swift` 里 `silentlyUpdateCurrentCodexSessionToken` 保留到 Task 4（协调器还在用），Task 4 一并删除。

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: add per-account usage model and codex account enable/order management"
```

---

## Task 3: 移除 `currentCodexAccountId`（Codex 部分）

**Files:**
- Modify: `AgentRing/AgentRing/Models/UserSettings.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarUI.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarManager.swift`
- Modify: `AgentRing/AgentRing/Views/Settings/Tabs/AuthSettingsView.swift`
- Modify: `AgentRing/AgentRing/Views/WebLogin/CodexOAuthCoordinator.swift`、`CodexWebLoginCoordinator.swift`
- Modify: `AgentRing/AgentRing/Services/NotificationManager.swift`（`notificationKey` 里 `currentCodexAccountId` 的引用）

**注意:** `currentCursorAccountId` **保持不动**（本期 Cursor 维持现状）。

**Step 1:** `UserSettings.swift` 删除：`currentCodexAccountId` 属性及其 didSet、`currentCodexAccount` 计算属性、`currentCodexAccountIdKey`、`switchToCodexAccount`、`silentlyUpdateCurrentCodexSessionToken`；`init()` 中 `currentCodexAccountId` 赋值块替换为旧 key 清理：

```swift
        // 清理已废弃的"当前账号"遗留 key
        defaults.removeObject(forKey: "currentCodexAccountId")
        defaults.removeObject(forKey: "DEBUG_currentCodexAccountId")
```

`addCodexAccount` 中 `if currentCodexAccountId == nil {...}`、`if codexAccounts.count == 1 {...}` 两处赋值块删除；`removeCodexAccount` 中 `wasCurrent` 逻辑改为无条件 `postAccountChanged()`。

**Step 2:** `CodexOAuthCoordinator.swift`（L158-159）与 `CodexWebLoginCoordinator.swift`（L199-200）删掉 `UserSettings.shared.switchToCodexAccount(stored)`（保留 `addCodexAccount`）。

**Step 3:** `MenuBarUI.createStandardMenu` 删掉 Codex 账号切换子菜单块（L160-167 的 `if settings.codexAccounts.count > 1` 段）；L178 条件里去掉 `settings.codexAccounts.count > 1`（只剩 cursor 条件）。`createAccountSubmenu` 保留（Cursor 还在用）。`MenuBarManager.swift` L291-295 删 `switchCodexAccount(_:)`。

**Step 4:** `AuthSettingsView.swift`：Codex 分支（L32-41）临时把 `currentId: settings.currentCodexAccountId` 改为 `currentId: nil`、`onSelect: { _ in }`（Task 9 会把单选彻底改成复选 + 详情展开状态）。

**Step 5:** `NotificationManager.notificationKey`（L106-116）：签名改为 `notificationKey(for type: LimitType, accountId: UUID?, suffix: String? = nil)`，删除内部对 `currentCodexAccountId` 的取值；其调用方在 Task 5 传入账号 id。此 Task 内先把调用处（`checkLimit` 内 3 处）临时传 `nil` 保持编译，Task 5 接上真实账号。

**Step 6:** BUILD，处理所有 `currentCodexAccount` 残留引用（grep 确认 0 命中，除 `currentCursor*`）：

```bash
grep -rn "currentCodexAccount" AgentRing/ --include="*.swift"
```

**Step 7: Commit** `git commit -am "refactor: remove currentCodexAccountId switching mechanism"`

---

## Task 4: `CodexAPIService` 按账号实例化

**Files:**
- Modify: `AgentRing/AgentRing/Services/CodexAPIService.swift`
- Modify: `AgentRing/AgentRing/Views/WebLogin/CodexTokenRefreshCoordinator.swift`、`CodexSilentRefreshCoordinator.swift`

**思路:** 单实例职责不变（token 缓存 + OAuth 单飞合并本来就该按账号隔离），改为构造时绑定账号 id，内部一切 `settings.codexSessionToken` 改为 `settings.codexAccountToken(accountId)`，写回改 `silentlyUpdateCodexSessionToken(accountId:token:)`。

**Step 1:** `CodexAPIService`：

```swift
    /// 本服务实例绑定的账号；nil 表示旧式"当前账号"（仅遗留调用，最终全量迁移）
    let accountId: UUID?

    init(accountId: UUID? = nil) {
        self.accountId = accountId
        ... // 原 init 其余不变
    }

    /// 本实例账号的凭据
    private var sessionTokenForAccount: String {
        if let accountId { return settings.codexAccountToken(accountId) }
        return settings.codexSessionToken   // 遗留分支（Task 5 后无人使用，Task 6 删）
    }
```

逐处替换：
- `hasCachedValidToken` 中 `forToken == settings.codexSessionToken` → `forToken == sessionTokenForAccount`
- `fetchUsage()` 中 `guard settings.hasValidCodexCredentials` → `guard !sessionTokenForAccount.isEmpty`；`let sessionToken = settings.codexSessionToken` → `= sessionTokenForAccount`
- `proactivelyRefreshIfNeeded()` 中同理替换两处
- refresh_token 轮换写回（L322-327 附近的"静默写回"）：改为

```swift
                if newRefresh != refreshToken {
                    Logger.api.notice("Codex OAuth: refresh_token 已轮换，静默写回")
                    if let accountId {
                        self.settings.silentlyUpdateCodexSessionToken(accountId: accountId, token: newRefresh)
                    }
                }
```

- session-token 新值写回（"检测到新 session-token，静默写回"两处）同样按 `accountId` 写回；无 `accountId` 时保持旧调用。

**Step 2:** 两个 Coordinator（`CodexTokenRefreshCoordinator` / `CodexSilentRefreshCoordinator`，均是遗留 session-token 账号的 WebView 刷新链）：`refresh` 加 `accountId: UUID? = nil` 参数并贯穿，L40/L47、L108/L167 的 `UserSettings.shared.codexSessionToken` 改为 `accountId.map { UserSettings.shared.codexAccountToken($0) } ?? UserSettings.shared.codexSessionToken`，写回处（L112/L170）同理改为按账号写回。WebView cookie 是全局共享的，遗留账号并发刷新可能互相串——在两个 Coordinator 的注释里注明"遗留 session-token 账号刷新按调用串行使用；OAuth 账号不受影响"，并发安全兜底是失败后按账号标 needsRelogin。

**Step 3:** BUILD；grep 确认 `CodexAPIService` 内不再直接引用 `settings.codexSessionToken`（只在 `sessionTokenForAccount` 的遗留分支）。

**Step 4: Commit** `git commit -am "refactor: bind CodexAPIService instances to specific accounts"`

---

## Task 5: `DataRefreshManager` 多账号并行拉取

**Files:**
- Modify: `AgentRing/AgentRing/Helpers/DataRefreshManager.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarManager.swift`（镜像属性）

**Step 1: 状态与实例池**

- 删 `private let codexApiService = CodexAPIService()` 与 `@Published var codexUsageData: CodexUsageData?`、`@Published private(set) var codexNeedsRelogin = false`、`lastCodexResetsAt`、`codexSessionExpiredNotified`。
- 新增：

```swift
    /// 按账号的 API 服务实例池（token 缓存/单飞按实例隔离）
    private var codexApiServices: [UUID: CodexAPIService] = [:]
    /// 每账号上次 primary resetsAt（重置验证定时器按账号挂）
    private var lastCodexResetsAtByAccount: [UUID: Date] = [:]
    private var codexSessionExpiredNotifiedAccounts: Set<UUID> = []

    /// 多账号用量（顺序 = 启用账号配置顺序）
    @Published var codexAccountUsages: [CodexAccountUsage] = []

    /// 当前应拉取的启用账号
    private var fetchableCodexAccounts: [Account] {
        #if DEBUG
        if shouldSuppressDebugCodexUsageForDisplayOptions { return [] }
        if settings.debugModeEnabled {
            // DEBUG mock：合成 3 个假账号，方便预览多列布局
            return (0..<3).map { i in
                Account(id: UUID(uuidString: String(format: "%08X-0000-0000-0000-00000000000%d", 0xdeb00000 + i, i + 1))!,
                        credentialToken: "mock", accountIdentifier: "mock\(i)", accountName: "Mock \(i + 1)", alias: nil, createdAt: Date(), provider: .codex)
            }
        }
        #endif
        return settings.enabledCodexAccounts.filter { !$0.credentialToken.isEmpty }
    }
```

（`Account` 的 memberwise init 可见性以 `Models/Account.swift` 实际为准；若其自定义 init 参数名不同，照该文件 L74-100 的 init 签名构造，或用 `Account(credentialToken:accountIdentifier:accountName:...)`。DEBUG mock 若构造太绕可简化为 1 个 mock 账号。）

- `codexApiService(for:)`：

```swift
    private func codexApiService(for accountId: UUID) -> CodexAPIService {
        if let service = codexApiServices[accountId] { return service }
        let service = CodexAPIService(accountId: accountId)
        codexApiServices[accountId] = service
        return service
    }
```

**Step 2: 拉取循环多账号化**

`fetchUsage()`：
- `let fetchCodex = shouldFetchCodexUsage` 改为 `let codexAccountsToFetch = fetchableCodexAccounts`（DEBUG 门控逻辑并入 `fetchableCodexAccounts`），`shouldFetchCodexUsage` 计算属性改为 `!fetchableCodexAccounts.isEmpty`（保留名字，其他引用处不用动）。
- `pendingFetches = codexAccountsToFetch.count + (fetchCursor ? 1 : 0) + (fetchAntigravity ? 1 : 0)`
- 循环 `for account in codexAccountsToFetch { fetchCodexUsage(account) }`
- guard 分支的 `clearCodexUsageState()` → `clearCodexUsageState()`（改为清空整个 `codexAccountUsages` + 各账号定时器）

`fetchCodexUsage(_ account: Account)`：

```swift
    private func fetchCodexUsage(_ account: Account) {
        codexApiService(for: account.id).fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.processCodexSuccess(data, account: account)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.attemptTokenRefreshAndRetry(account)
                    } else {
                        self.setCodexAccountError(account, error.localizedDescription)
                        Logger.menuBar.info("Codex 请求失败(\(account.displayName, privacy: .public)): \(error.localizedDescription)")
                    }
                }
                self.noteFetchFinished()
            }
        }
    }
```

`processCodexSuccess(_ data:account:)`：原逻辑按账号化——
- `previousData` 从 `codexAccountUsages` 里该账号的 `usage` 取
- upsert 到 `codexAccountUsages`（存在则更新 `usage`、`needsRelogin = false`、`errorMessage = nil`；不存在则按 `fetchableCodexAccounts` 顺序重排插入），保持数组顺序 = 启用账号顺序的方法：

```swift
    private func upsertCodexUsage(_ data: CodexUsageData, account: Account) {
        var map = Dictionary(uniqueKeysWithValues: codexAccountUsages.map { ($0.accountId, $0) })
        map[account.id] = CodexAccountUsage(
            accountId: account.id,
            displayName: account.displayName,
            usage: data,
            needsRelogin: false,
            errorMessage: nil
        )
        // 顺序 = 启用账号配置顺序；已不在启用列表的残留项丢弃
        codexAccountUsages = settings.enabledCodexAccounts.compactMap { map[$0.id] }
    }
```

- 通知：`NotificationManager.shared.checkAndNotify(codexUsageData: data, previousData: previousData, account: account)`（Task 6 改签名；先改这里调用处）
- 重置验证：`lastCodexResetsAtByAccount[account.id]` + `scheduleCodexResetVerification(resetsAt:accountId:)`，定时器 id 加后缀：

```swift
    private static func codexResetTimerIds(_ accountId: UUID) -> [String] {
        ["codexResetVerify1", "codexResetVerify2", "codexResetVerify3"].map { "\($0)_\(accountId.uuidString)" }
    }
```

`cancelCodexResetVerification(accountId:)` 按 id 失效。三个验证回调从 `fetchUsage()` 改为 `fetchCodexUsage(account)`（只刷该账号）——需把 `account` 捕获进闭包。

- `errorMessage = nil` 的清理条件从"全局成功"改为：`codexAccountUsages.allSatisfy { $0.errorMessage == nil }` 时清 `errorMessage`。

**Step 3: 过期与恢复按账号**

- `markCodexNeedsRelogin(_ account: Account)`：置该账号 `needsRelogin = true`（upsert 一条 usage 为 nil 的记录），发过期通知（带账号别名，Task 6），清该账号 `lastCodexResetsAtByAccount` 与重置定时器；`errorMessage` 仅当**所有**账号都无数据/过期时才设置。
- `resetCodexReloginState()` → `resetCodexReloginState()` 遍历清全部账号的 needsRelogin（手动刷新时调用不变）。
- `attemptTokenRefreshAndRetry(_ account: Account)` / `attemptLevel1SSRRefresh` / `attemptLevel2WebViewRefresh` / `retryCodexWithAccessToken`：全部带 `account` 参数贯穿；两个 Coordinator 调用改为 `CodexTokenRefreshCoordinator.shared.refresh(accountId: account.id) {...}`、`CodexSilentRefreshCoordinator.shared.refresh(accountId: account.id) {...}`；`attemptLevel2WebViewRefresh` 成功回调从 `fetchUsage()` 改 `fetchCodexUsage(account)`；`CodexAPIService.isOAuthRefreshToken(settings.codexSessionToken)` 改 `isOAuthRefreshToken(settings.codexAccountToken(account.id))`；`retryCodexWithAccessToken` 用 `codexApiService(for: account.id).fetchUsageWithAccessToken(...)`。
- `clearCodexUsageState()`：

```swift
    private func clearCodexUsageState(clearError: Bool = true) {
        codexAccountUsages = []
        if clearError { errorMessage = nil }
        lastCodexResetsAtByAccount.removeAll()
        for accountId in codexApiServices.keys {
            timerManager.invalidate(Self.codexResetTimerIds(accountId))
        }
    }
```

- `setCodexAccountError(_ account: Account, _ message: String)`：该账号记录的 `errorMessage` 置位；若**全部**启用账号都无 usage 才写全局 `errorMessage`（保持"单账号网络瞬断不打扰"）。

**Step 4: 其他收口**

- `handleManualRefresh()`：`refreshState.refreshingProvider` 逻辑改为 `fetchableCodexAccounts.count + fetchCursor + fetchAntigravity >= 2 ? nil : (单个目标的 provider)`；多 Codex 账号也算多目标（`nil` = 全部一起转）。
- `startCodexTokenRefreshTimer()`：遍历 `codexApiServices.values`（或 `fetchableCodexAccounts`）逐账号 `proactivelyRefreshIfNeeded()`。
- `handleAccountChanged(provider:)` 的 codex 分支：改为 `for service in codexApiServices.values { service.clearAccessTokenCache() }`；再 `pruneCodexServices()`（把不在 `settings.codexAccounts` 的实例从 `codexApiServices`/`lastCodexResetsAtByAccount`/`codexSessionExpiredNotifiedAccounts` 移除并失效其定时器）；然后 `clearCodexUsageState()`。
- `publishSmartMonitoringUtilizations()`：codex 的 utilization 取所有账号 `monitoringUtilization` 的 **max**（告急优先），仍记在 `utilizations[.codex]` 一个键下（智能刷新节奏不按账号拆分，YAGNI）。
- `pushBluetoothSync()`：`let codex = bluetoothCodexUsage`——新增 `private var bluetoothCodexUsage: CodexUsageData? { codexAccountUsages.first { $0.accountId == settings.bluetoothCodexAccount?.id }?.usage }`。
- `UserSettings.postBluetoothImmediatePush()`（`Models/UserSettings.swift` L477-495）同步改为取第一个启用账号的 usage（通过 `menuBarManager?.dataManagerForBluetooth` 新形态，见 Step 5）。

**Step 5: MenuBarManager 镜像**

`App/MenuBarManager.swift`：`@Published var codexUsageData` → `@Published var codexAccountUsages: [CodexAccountUsage]`，订阅 `dataManager.$codexAccountUsages`；`dataManagerForBluetooth` 的 `codexData` 项改为 `codexAccountUsages`（或直接暴露第一个启用账号的 usage——选改动小的：元组里放 `codexAccountUsages: [CodexAccountUsage]`，由调用方取第一个）。所有 `codexUsageData != nil` 的判断改为 `!codexAccountUsages.isEmpty`。

**Step 6:** BUILD（此步会连带把 `UsageDetailView`/`MenuBarIconRenderer`/`BluetoothPayload` 等下游编译错误暴露出来——**本 Task 允许把下游调用点做最小适配**：`UsageDetailView` 的 `@Binding var codexUsageData` 暂改为传 `codexAccountUsages.first?.usage`（Task 7 复原多列），`MenuBarIconRenderer.createIcon` 同理传第一个账号 usage（Task 8 复原多簇），`pushPayload(codexUsageData:)` 传 `bluetoothCodexUsage`（Task 10 收口）。原则：**每一步结束必须 BUILD 通过**，不许留红。

**Step 7: Commit** `git commit -am "feat: fetch and track codex usage per account concurrently"`

---

## Task 6: 通知按账号

**Files:**
- Modify: `AgentRing/AgentRing/Services/NotificationManager.swift`
- Modify: `AgentRing/AgentRing/Resources/zh-Hans.lproj/Localizable.strings`、`en.lproj/Localizable.strings`
- Modify: `AgentRing/AgentRing/Helpers/LocalizationHelper.swift`（如需新 L 键）

**Step 1:** `checkAndNotify(codexUsageData:previousData:)` 签名加 `account: Account`：

```swift
    func checkAndNotify(codexUsageData: CodexUsageData, previousData: CodexUsageData?, account: Account) {
        let accountId = account.id
        let label = account.displayName
        checkLimit(type: .codexPrimary, ..., accountId: accountId, accountLabel: label)
        // 三个 checkLimit 同样传
    }
```

`checkLimit` 加 `accountId: UUID? = nil, accountLabel: String? = nil`；`notificationKey(for:suffix:)` 调用传 `accountId`（把 Task 3 的临时 `nil` 接上；Cursor 调用传 `UserSettings.shared.currentCursorAccountId`）。`sendUsageWarning`/`sendResetNotification` 在正文前缀账号标签：

```swift
        if let accountLabel {
            content.body = "\(accountLabel) · " + content.body
        }
```

**Step 2:** `sendCodexSessionExpiredNotification()` 加 `accountLabel: String? = nil` 参数，body 前缀同上；通知 identifier 从固定 `"codex_session_expired"` 改为 `"codex_session_expired_\(accountLabel ?? "all")"`（避免多账号互相顶掉）。

**Step 3:** `DataRefreshManager` 调用处传 `account`（Task 5 已留好形参位）。

**Step 4:** BUILD + Commit `git commit -am "feat: per-account usage notifications with account labels"`

---

## Task 7: 弹窗多列（UsageDetailView + CodexColumnView）

**Files:**
- Modify: `AgentRing/AgentRing/Views/UsageDetailView.swift`
- Modify: `AgentRing/AgentRing/Views/Components/CodexColumnView.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarManager.swift`（popover 内容绑定）

**Step 1: 展示单元列表**

`UsageDetailView`：
- `@Binding var codexUsageData: CodexUsageData?` → `@Binding var codexAccountUsages: [CodexAccountUsage]`
- 新增：

```swift
    private struct ColumnUnit: Identifiable {
        enum Source: Equatable {
            case codex(UUID)
            case cursor
            case antigravity
            case antigravityThird
        }
        let source: Source
        var id: String { "\(source)" }
    }

    private var columnUnits: [ColumnUnit] {
        // Codex 账号列按启用顺序；provider 组位置沿用现有跨平台拖拽排序（orderedProviders）
        var units: [ColumnUnit] = []
        for provider in displayProviders {
            switch provider {
            case .codex:
                units.append(contentsOf: codexAccountUsages.map { ColumnUnit(source: .codex($0.accountId)) })
            case .cursor: units.append(ColumnUnit(source: .cursor))
            case .antigravity: units.append(ColumnUnit(source: .antigravity))
            case .antigravityThird: units.append(ColumnUnit(source: .antigravityThird))
            }
        }
        return units
    }
```

`activeProviders` 的判断改为 `!codexAccountUsages.isEmpty` 对应 `.codex`。`orderedProviders` 拖拽逻辑（`ProviderDropDelegate`）**不动**（平台组粒度）。

**Step 2: 宽度与折行**

- `providerColumnWidth`/`popoverWidth` 改为按 `MultiAccountPlanning.rowWidths(unitCount:)` 的行内列数取档：

```swift
    private func columnWidth(forRowCount count: Int) -> CGFloat {
        switch count {
        case 4...: return 245
        case 3: return 272
        case 2: return 276
        default: return 290
        }
    }
    private var popoverWidth: CGFloat {
        let rows = MultiAccountPlanning.rowWidths(unitCount: columnUnits.count)
        let maxRow = rows.max() ?? 1
        switch maxRow {
        case 4...: return 1040
        case 3: return 860
        case 2: return 580
        default: return 320
        }
    }
```

- `mainContent` 的多列 `HStack` 改为：按 `rowWidths` 切分 `columnUnits` 成行，行内 `HStack`（保留 `ProviderDivider`），行间 `VStack(spacing: 12)`；每列 `frame(width: columnWidth(forRowCount: 行内列数))`。
- `contentHeight`：行数 >1 时高度乘上行数近似（`baseHeight * rows.count` 或每行内容高 + 间距；以视觉不裁切为准，调到合理值）。
- 单列且单平台现状分支保留。

**Step 3: 列渲染**

- `providerColumnBody(for:)` 拆出 `columnBody(for unit: ColumnUnit)`：
  - `.codex(id)`：从 `codexAccountUsages.first { $0.accountId == id }` 取数据，有 `usage` → `CodexColumnView(...)`；`needsRelogin` → `errorState(..., reloginAction: .codexRelogin)`；有 `errorMessage` → 该账号错误文案；否则 loading。
  - 列标题 `providerHeader`：Codex 列显示 `account.displayName`（`CodexAccountUsage.displayName`，Task 5 已带），其他平台维持 `providerTitle`。
- `CodexColumnView` 增加 `var accountId: UUID?`（默认 nil）与 `var isRefreshingOverride: Bool?`；`isCodexRefreshing` 优先用 override（Task 5 的 `refreshState.isRefreshingProvider` 仍是平台粒度，账号粒度刷新态后续增强，先用"平台在刷新即该列转"的近似——在代码注释中注明）。`UserSettings.shared.getActiveDisplayTypes(codexUsageData:)` 调用不用动（本来就按传入数据分析）。

**Step 4:** `MenuBarManager` L433 附近 popover 绑定改传 `codexAccountUsages`。BUILD 后手动核对 `#Preview`（UsageDetailView 尾部）改为 `@State static var sampleCodexUsages: [CodexAccountUsage]` 构造 2-3 个假账号。

**Step 5: Commit** `git commit -am "feat: popover renders one column per codex account with row wrapping"`

---

## Task 8: 菜单栏多簇（MenuBarIconRenderer + tooltip）

**Files:**
- Modify: `AgentRing/AgentRing/App/MenuBarIconRenderer.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarUI.swift`
- Modify: `AgentRing/AgentRing/App/MenuBarManager.swift`

**Step 1:** `createIcon`/`buildIcon` 的 `codexUsageData: CodexUsageData?` 参数改为 `codexAccountUsages: [CodexAccountUsage]`。`buildIcon` 中 `case .codex` 分支改为**对每个有 usage 的账号**调 `buildCodexCluster(codex:...)` 依次 append（顺序 = 数组顺序）；品牌 logo（`includeBrand` 时的 CodexIcon）**只画一次**——在循环前画（当 `codexAccountUsages` 非空时），不再随账号重复。空数据占位逻辑：`ordered` 为空且所有 unit 无数据才 `createEmptyPlaceholder`。

**Step 2:** 跨平台顺序维持现有 `orderedActiveProviders`（平台组内账号按顺序展开）；把展开逻辑抽一个小函数方便复用：

```swift
    private func expandedCodexClusters(
        usages: [CodexAccountUsage],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> [NSImage] {
        usages.compactMap { $0.usage }.flatMap {
            buildCodexCluster(codex: $0, isMonochrome: isMonochrome, button: button)
        }
    }
```

**Step 3:** `MenuBarUI.updateMenuBarIcon` 与 `generateCacheKey` 的 codex 参数改 `codexAccountUsages`：cache key 里每账号追加 `"_cx\(accountId.uuidString.prefix(8))_p..._s..._e..."` 片段。

**Step 4: tooltip**——`updateMenuBarIcon` 内设置 `button.toolTip`：

```swift
        button.toolTip = buildTooltip(
            codexAccountUsages: codexAccountUsages,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
```

`buildTooltip` 每行 `"\(displayName)  \(UsageRingDisplay.percentLabel(usedPercentage: pct, showRemainingMode: settings.showRemainingMode))"`（Codex 每账号取 primary 百分比，无 primary 取 secondary/extra 的 max；Cursor/Antigravity 各一行），行间 `\n`。`MenuBarIconRenderer` 里给 `buildCodexCluster` 用到的百分比逻辑照旧。

**Step 5:** BUILD + Commit `git commit -am "feat: menu bar renders one ring cluster per codex account with tooltip"`

---

## Task 9: 认证页复选 + 拖拽排序

**Files:**
- Modify: `AgentRing/AgentRing/Views/Settings/Tabs/AuthSettingsView.swift`
- Modify: `AgentRing/AgentRing/Resources/zh-Hans.lproj/Localizable.strings`、`en.lproj/Localizable.strings`、`Helpers/LocalizationHelper.swift`
- Modify: `.github/workflows/ci.yml`（无）/ `Tests/MultiAccountPlanningChecks.swift`（无）

**Step 1: 文案**（两个 lproj 都加，键名照 `L.Account.*` 现有格式挂到 `LocalizationHelper.swift`）：

| 键 | zh-Hans | en |
| :--- | :--- | :--- |
| `Account.multiSelectHint` | 勾选的账号参与用量展示与刷新；副屏同步勾选中的第一个账号 | Checked accounts are monitored and displayed; the first checked account syncs to companion displays |
| `Account.dragToReorder` | 拖拽调整顺序 | Drag to reorder |
| `Account.enableAccount` | 启用此账号 | Enable this account |

**Step 2: Codex 卡片改造**——`providerAccountsCard` 增加参数 `multiSelect: Bool` 与 `onMove: ((IndexSet, Int) -> Void)?`、`onToggle: ((Account, Bool) -> Void)?`、`isExpandedId: State<UUID?>` 的等价物（在 `AuthSettingsView` 加 `@State private var expandedCodexAccountId: UUID?`）。Codex 分支传 `multiSelect: true`：

- 行左侧图标改为**复选框语义**：`Button { onToggle(account, !isEnabled) }`，图标 `isEnabled ? "checkmark.circle.fill" : "circle"`（`isEnabled = settings.isCodexAccountEnabled(account.id)`）。
- 点行主体 = 展开/收起该账号详情（`expandedCodexAccountId`），替代原 `isSelected` 逻辑；别名、token、删除按钮在展开区显示。
- Cursor 分支 `multiSelect: false` 保持单选行为（传原 `onSelect`）。
- 列表行加 `.onMove`（SwiftUI `List` 才原生支持；当前是 VStack+ForEach——**加 `help(L.Account.dragToReorder)` 与行尾 `Image(systemName: "line.3.horizontal")` 作为拖拽手柄提示**，用 `.onDrag/.onDrop` 复用 `UsageDetailView` 的 `ProviderDropDelegate` 模式实现账号排序，或改用 `List` + `.listStyle(.plain)` + `.onMove`——**优先 List 方案**，改动小、体验标准；注意 SettingCard 内嵌 List 的高度自适应，用 `frame(height:)` 按行数估算或 `.scrollContentBackground(.hidden)`）。
- `onMove` 回调接 `settings.moveCodexAccounts(from:to:)`。
- 卡片底部加说明文案 `Text(L.Account.multiSelectHint)`。

**Step 3:** `UserSettings.addCodexAccount` 新增/更新账号后：若账号在 `disabledCodexAccountIds` 中且是**新登录**（新增分支），自动启用（`disabledCodexAccountIds.remove(id)`）；更新分支保持用户勾选状态。

**Step 4:** 手动验收清单（写进 commit message 或 PR 描述）：勾/去勾立即影响弹窗与菜单栏；拖拽顺序立即生效；重启后状态保持。

**Step 5: Commit** `git commit -am "feat: auth settings codex accounts get checkboxes and drag reordering"`

---

## Task 10: 副屏取第一个启用账号 + 设置页提示

**Files:**
- Modify: `AgentRing/AgentRing/Helpers/DataRefreshManager.swift`（`pushBluetoothSync` 已在 Task 5 改；本 Task 核查）
- Modify: `AgentRing/AgentRing/Models/UserSettings.swift`（`postBluetoothImmediatePush` 核查）
- Modify: `AgentRing/AgentRing/Views/Settings/Tabs/BluetoothSettingsView.swift`
- Modify: `AgentRing/AgentRing/Resources/.../Localizable.strings`、`Helpers/LocalizationHelper.swift`

**Step 1:** 核查 `BluetoothPayload.swift` / `BLESyncService.swift` / `BluetoothSyncService.swift` 的 `codexUsageData:` 入参全部传 `bluetoothCodexUsage`（第一个启用账号的 usage）。**JSON 帧格式零改动**——`Tests/BluetoothPayload` 无现有测试，用 Task 1 的 checks 验证 `bluetoothCodexAccountID`（已覆盖）。

**Step 2:** `BluetoothSettingsView` 的同步卡片加一行状态文案：

```swift
                Text(L.SettingsBluetooth.syncAccount(settings.bluetoothCodexAccount?.displayName ?? L.SettingsBluetooth.syncAccountNone))
                    .font(.caption)
                    .foregroundColor(.secondary)
```

文案：`syncAccount` = "当前同步账号：%@（勾选中的第一个）" / "Syncing account: %@ (first checked)"; `syncAccountNone` = "无可用账号" / "No account"。

**Step 3:** BUILD + Commit `git commit -am "feat: bluetooth sync surfaces which codex account is pushed"`

---

## Task 11: 诊断按账号 + 本地化收尾

**Files:**
- Modify: `AgentRing/AgentRing/Helpers/DiagnosticManager.swift`
- Modify: `AgentRing/AgentRing/Resources/.../Localizable.strings`

**Step 1:** `DiagnosticManager`（L36、L91 附近）：从"取当前 Codex 账号"改为遍历 `settings.enabledCodexAccounts`，每个账号出一个 `ProviderDiagnosticResult`（名称 = 账号 `displayName`；复用现有构造逻辑，账号 token 用 `settings.codexAccountToken(id)`）。无启用账号时走 `buildNoAccountsReport()`。

**Step 2:** grep 检查所有新增用户可见字符串都有 zh-Hans/en 双份（`grep -rn "Text(\"" AgentRing/AgentRing/Views | grep -v "L\."` 排查硬编码）。

**Step 3:** BUILD + Commit `git commit -am "feat: diagnostics report per enabled codex account"`

---

## Task 12: 全量验证与手动验收

**Step 1: 全部自动化检查**

```bash
bash Scripts/test-multi-account-planning.sh
bash Scripts/test-ring-display.sh
bash Scripts/test-credential-store.sh
bash Scripts/test-changelog.sh
bash Scripts/test-release-tools.sh
```
全部 PASS。

**Step 2: BUILD（Release 也过一遍）**

```bash
xcodebuild -project AgentRing.xcodeproj -scheme AgentRing -configuration Debug -derivedDataPath ./build-temp build
xcodebuild -project AgentRing.xcodeproj -scheme AgentRing -configuration Release -derivedDataPath ./build-temp-rel build
```

**Step 3: 手动验收**（有 GUI 环境时；否则在最终报告列为待办）——按设计文档 §7 的手动验收清单：

1. 登录 2-3 个 Codex 账号 → 弹窗并排多列、标题为别名、顺序 = 认证页顺序
2. 菜单栏多组圆环簇横排、无重复 logo、tooltip 清单正确
3. 停用一个账号（去勾）→ 其列/簇消失，重新勾选恢复，登录态保留
4. 拖拽排序 → 弹窗列序、菜单栏簇序、副屏"第一个"同步变化
5. 单账号改密码/吊销 → 只有该列显示重登录，其他账号照常
6. 告急通知带账号别名
7. 5+ 单元（3 账号 + Cursor + Antigravity×2）→ 弹窗折两行、宽 1040
8. 副屏显示勾选中的第一个账号；老固件（如有）显示正常

**Step 4:** 全部通过后 commit（如有收尾小修）并汇报。若走 PR：描述引用设计文档与手动验收清单。

---

## 风险与备注

- **遗留 session-token 账号**（非 OAuth）的 WebView 刷新链共享 cookie jar，多账号并发刷新可能互串；兜底 = 按账号标 needsRelogin。新登录账号均为 OAuth refresh_token（`CodexOAuthCoordinator`），不受影响。
- **图标宽度**：每账号约 26pt；6+ 单元菜单栏偏宽。设计已确认不做裁剪，GeneralSettings 可后续加提示（非本期）。
- **Cursor 多账号**仍为单账号展示（本期范围外）；复选框仅 Codex。
- Task 5 是最大的一步；若一次改不完，按"Step 1-2（拉取）→ Step 3（过期）→ Step 4-6（收口）"拆成 3 个 commit，每步 BUILD 绿。
