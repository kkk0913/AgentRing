//
//  CodexColumnView.swift
//  Agent Ring
//

import SwiftUI

/// Codex 用量列视图（双 Provider 模式右列）
struct CodexColumnView: View {
    let codexUsageData: CodexUsageData
    let showRemainingMode: Bool
    let refreshState: RefreshState
    var onRefresh: (() -> Void)?

    private var activeCodexTypes: [LimitType] {
        UserSettings.shared.getActiveDisplayTypes(codexUsageData: codexUsageData)
    }

    private var primaryRingType: LimitType? {
        if activeCodexTypes.contains(.codexPrimary) {
            return .codexPrimary
        }
        if activeCodexTypes.contains(.codexSecondary) {
            return .codexSecondary
        }
        return nil
    }

    private var primaryRingData: CodexUsageData.LimitData? {
        let placeholder = CodexUsageData.LimitData(percentage: 0, resetsAt: nil)
        let showPlaceholder = UserSettings.shared.shouldShowCustomPlaceholderInPopover

        switch primaryRingType {
        case .codexPrimary:
            return codexUsageData.primary ?? (showPlaceholder ? placeholder : nil)
        case .codexSecondary:
            return codexUsageData.secondary ?? (showPlaceholder ? placeholder : nil)
        default:
            return nil
        }
    }

    private var secondaryData: CodexUsageData.LimitData? { codexUsageData.secondary }

    private var showSecondaryRing: Bool {
        primaryRingType == .codexPrimary && activeCodexTypes.contains(.codexSecondary) && secondaryData != nil
    }

    private var isCodexRefreshing: Bool {
        refreshState.isRefreshingProvider(.codex)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                if let ringData = primaryRingData {
                    let outerColor = primaryRingType == .codexSecondary
                        ? UsageColorScheme.codexSecondaryColorSwiftUI(ringData.percentage)
                        : UsageColorScheme.codexPrimaryColorSwiftUI(ringData.percentage)
                    ActivityRingView(
                        outerPercentage: ringData.percentage,
                        innerPercentage: showSecondaryRing ? secondaryData?.percentage : nil,
                        outerColor: outerColor,
                        innerColor: UsageColorScheme.codexPairedInnerColorSwiftUI(secondaryData?.percentage ?? 0),
                        isRefreshing: isCodexRefreshing,
                        showRemainingMode: showRemainingMode
                    )
                }
            }
            .frame(height: 100)
            .accessibilityLabel(L.Usage.refresh)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if refreshState.canRefresh && !refreshState.isRefreshing { onRefresh?() }
            }
            .help(L.Usage.refresh)
            .contentShape(Circle())
            .onTapGesture {
                if refreshState.canRefresh && !refreshState.isRefreshing {
                    onRefresh?()
                }
            }

            limitRows(for: activeCodexTypes) { type in
                UnifiedLimitRow(
                    type: type,
                    codexData: codexUsageData,
                    showRemainingMode: showRemainingMode
                )
            }
            .padding(.horizontal, 10)
        }
    }
}
