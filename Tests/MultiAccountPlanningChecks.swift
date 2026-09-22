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
