//
//  CursorColumnView.swift
//  Agent Ring
//

import SwiftUI

struct CursorColumnView: View {
    let cursorUsageData: CursorUsageData
    let showRemainingMode: Bool
    let refreshState: RefreshState
    var onRefresh: (() -> Void)?
    var errorMessage: String? = nil
    var lastUpdatedAt: Date? = nil

    private var activeTypes: [LimitType] {
        UserSettings.shared.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData)
    }

    private var isRefreshing: Bool {
        refreshState.isRefreshingProvider(.cursor)
    }

    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                if let errorMessage {
                    VStack(spacing: 6) {
                        Label(L.provider("refresh.failed"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(L.provider("refresh.cached")).foregroundStyle(.secondary)
                        if let lastUpdatedAt {
                            Text(lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .help(errorMessage)
                    .accessibilityLabel(L.provider("refresh.failed") + ": " + errorMessage)
                } else if let included = cursorUsageData.included {
                    ActivityRingView(
                        outerPercentage: included.percentage,
                        innerPercentage: activeTypes.contains(.cursorOnDemand)
                            ? (cursorUsageData.apiModels?.percentage ?? cursorUsageData.onDemand?.percentage)
                            : nil,
                        outerColor: UsageColorScheme.cursorIncludedColorSwiftUI(included.percentage),
                        innerColor: UsageColorScheme.cursorPairedInnerColorSwiftUI(
                            cursorUsageData.apiModels?.percentage
                                ?? cursorUsageData.onDemand?.percentage
                                ?? 0
                        ),
                        isRefreshing: isRefreshing,
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

            limitRows(for: activeTypes) { type in
                UnifiedLimitRow(
                    type: type,
                    cursorData: cursorUsageData,
                    showRemainingMode: showRemainingMode
                )
            }
            .padding(.horizontal, 10)
        }
    }
}
