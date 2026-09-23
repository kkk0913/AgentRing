//
//  PopoverLayout.swift
//  Agent Ring
//

import Foundation
import AppKit

/// 弹窗面板的尺寸计算（NSPopover 窗口与 SwiftUI 内容共用，避免两处口径漂移）。
/// 支持多账号平铺列 + 超过 4 列折成多行。
enum PopoverLayout {
    /// Use the same width for the hosting view and its popover window.
    static func wrapRows(unitCount: Int, availableWidth: CGFloat = 1048) -> [Int] {
        let columns = MultiAccountPlanning.popoverColumns(availableWidth: availableWidth)
        return MultiAccountPlanning.rowWidths(unitCount: max(1, unitCount), maxPerRow: columns)
    }

    static func windowWidth(maxRowColumns: Int) -> CGFloat {
        MultiAccountPlanning.popoverWidth(columns: maxRowColumns)
    }

    static func viewWidth(maxRowColumns: Int) -> CGFloat {
        windowWidth(maxRowColumns: maxRowColumns)
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
    static func unitCount(providers: [ProviderType], codexAccountCount: Int, cursorAccountCount: Int = 1) -> Int {
        var count = 0
        for provider in providers {
            switch provider {
            case .codex:
                count += max(1, codexAccountCount)
            case .cursor:
                count += max(1, cursorAccountCount)
            case .antigravity, .antigravityThird, .kimi, .glm:
                count += 1
            }
        }
        return count
    }

    /// 明细行数（各列取最大，不加总）
    static func limitRowCount(
        codexUsages: [CodexUsageData?],
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?,
        cursorUsages: [CursorUsageData] = [],
        planQuotas: [PlanQuota] = []
    ) -> Int {
        let settings = UserSettings.shared
        var rows: [Int] = codexUsages.map {
            settings.getActiveCodexDisplayTypes(codexUsageData: $0).count
        }
        for usage in cursorUsages + [cursorUsageData].compactMap({ $0 }) {
            rows.append(settings.getActiveCursorDisplayTypes(cursorUsageData: usage).count)
        }
        if antigravityUsageData != nil {
            rows.append(settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravity).count)
            rows.append(settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravityThird).count)
        }
        rows += planQuotas.map { $0.windows.count }
        return rows.max() ?? 0
    }

    // Shared with the view: header (16 + 28), section gap (12), bottom inset (16).
    static let chromeHeight: CGFloat = 72
    static let rowSpacing: CGFloat = 16
    static let paginationHeight: CGFloat = 32

    static func rowHeight(limitRowCount: Int, showsMultiple: Bool) -> CGFloat {
        // Ring 100 + ring/details gap 15; account heading 20 + gap 14 when present.
        let base: CGFloat = showsMultiple ? 149 : 115
        return max(180, base + UnifiedLimitRowMetrics.textHeight(rowCount: limitRowCount))
    }

    static func contentHeight(wrapRowCount: Int, limitRowCount: Int, showsMultiple: Bool) -> CGFloat {
        let count = max(1, wrapRowCount)
        return chromeHeight + rowHeight(limitRowCount: limitRowCount, showsMultiple: showsMultiple) * CGFloat(count)
            + rowSpacing * CGFloat(count - 1)
    }

    static func pageLayout(wrapRowCount: Int, limitRowCount: Int, showsMultiple: Bool, availableHeight: CGFloat)
        -> (rowsPerPage: Int, pageCount: Int, height: CGFloat) {
        let count = max(1, wrapRowCount)
        let fullHeight = contentHeight(wrapRowCount: count, limitRowCount: limitRowCount, showsMultiple: showsMultiple)
        if fullHeight <= availableHeight {
            return (count, 1, fullHeight)
        }
        let row = rowHeight(limitRowCount: limitRowCount, showsMultiple: showsMultiple)
        let capacity = max(1, Int((availableHeight - chromeHeight - paginationHeight + rowSpacing) / (row + rowSpacing)))
        let pages = (count + capacity - 1) / capacity
        let height = contentHeight(wrapRowCount: capacity, limitRowCount: limitRowCount, showsMultiple: showsMultiple)
            + (pages > 1 ? paginationHeight : 0)
        return (capacity, pages, height)
    }
}
