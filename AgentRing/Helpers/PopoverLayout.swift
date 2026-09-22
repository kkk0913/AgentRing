//
//  PopoverLayout.swift
//  Agent Ring
//

import Foundation
import AppKit

/// 弹窗面板的尺寸计算（NSPopover 窗口与 SwiftUI 内容共用，避免两处口径漂移）。
/// 支持多账号平铺列 + 超过 4 列折成多行。
enum PopoverLayout {
    /// 展示单元列数 → 每行至多 4 列的折行分布
    static func wrapRows(unitCount: Int) -> [Int] {
        MultiAccountPlanning.rowWidths(unitCount: unitCount)
    }

    /// NSPopover 窗口宽度（比视图宽度略窄 20pt，沿用历史口径）
    static func windowWidth(maxRowColumns: Int) -> CGFloat {
        switch maxRowColumns {
        case 4...: return 1020
        case 3: return 860
        case 2: return 580
        default: return 320
        }
    }

    /// SwiftUI 内容宽度
    static func viewWidth(maxRowColumns: Int) -> CGFloat {
        switch maxRowColumns {
        case 4...: return 1040
        case 3: return 860
        case 2: return 580
        default: return 320
        }
    }

    /// 行内列数 → 单列宽度
    static func columnWidth(columnCount: Int) -> CGFloat {
        switch columnCount {
        case 4...: return 245
        case 3: return 272
        case 2: return 276
        default: return 290
        }
    }

    /// 展示单元总数（Codex 每账号一列；无数据时该平台保留一列占位）
    static func unitCount(providers: [ProviderType], codexAccountCount: Int) -> Int {
        var count = 0
        for provider in providers {
            switch provider {
            case .codex:
                count += max(1, codexAccountCount)
            case .cursor, .antigravity, .antigravityThird:
                count += 1
            }
        }
        return count
    }

    /// 明细行数（各列取最大，不加总）
    static func limitRowCount(
        codexUsages: [CodexUsageData?],
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?
    ) -> Int {
        let settings = UserSettings.shared
        var rows: [Int] = codexUsages.map {
            settings.getActiveCodexDisplayTypes(codexUsageData: $0).count
        }
        if cursorUsageData != nil {
            rows.append(settings.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData).count)
        }
        if antigravityUsageData != nil {
            rows.append(settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravity).count)
            rows.append(settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravityThird).count)
        }
        return rows.max() ?? 0
    }

    /// 高度：每个折行块 = 底座 + 明细行，块间 12pt
    static func contentHeight(wrapRowCount: Int, limitRowCount: Int, showsMultiple: Bool) -> CGFloat {
        let baseHeight: CGFloat = showsMultiple ? 222 : 190
        let blockHeight = baseHeight + UnifiedLimitRowMetrics.textHeight(rowCount: limitRowCount)
        return blockHeight * CGFloat(max(1, wrapRowCount)) + 12 * CGFloat(max(0, wrapRowCount - 1))
    }
}
