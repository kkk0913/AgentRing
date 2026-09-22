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

        // 编译器要求的最小补充：checks 中数组字面量 [.codexAccount(a), ...] 按 [DisplayUnit]
        // 隐式成员表达式解析，而 case 在嵌套 Source 上，故补同名静态成员供其构造。
        static func codexAccount(_ accountId: UUID) -> DisplayUnit { DisplayUnit(source: .codexAccount(accountId)) }
        static var cursor: DisplayUnit { DisplayUnit(source: .cursor) }
        static var antigravity: DisplayUnit { DisplayUnit(source: .antigravity) }
        static var antigravityThird: DisplayUnit { DisplayUnit(source: .antigravityThird) }
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
