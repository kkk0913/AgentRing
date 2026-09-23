//
//  AntigravityColumnView.swift
//  Agent Ring
//

import SwiftUI

struct AntigravityColumnView: View {
    let provider: ProviderType
    let antigravityUsageData: AntigravityUsageData
    let showRemainingMode: Bool
    let refreshState: RefreshState
    var onRefresh: (() -> Void)?

    private var activeTypes: [LimitType] {
        UserSettings.shared.getActiveAntigravityDisplayTypes(
            antigravityUsageData: antigravityUsageData,
            provider: provider
        )
    }

    private var isRefreshing: Bool {
        refreshState.isRefreshingProvider(.antigravity)
    }

    private var outerPercentage: Double {
        if provider == .antigravity {
            return antigravityUsageData.geminiPrimary?.percentage ?? antigravityUsageData.primary?.percentage ?? 0
        } else {
            return antigravityUsageData.thirdPartyPrimary?.percentage ?? 0
        }
    }

    private var innerPercentage: Double? {
        if provider == .antigravity {
            return antigravityUsageData.geminiSecondary?.percentage ?? antigravityUsageData.secondary?.percentage
        } else {
            return antigravityUsageData.thirdPartySecondary?.percentage
        }
    }

    private var outerColor: Color {
        if provider == .antigravity {
            return UsageColorScheme.antigravityPrimaryColorSwiftUI(outerPercentage)
        } else {
            return UsageColorScheme.antigravityThirdPartyPrimaryColorSwiftUI(outerPercentage)
        }
    }

    private var innerColor: Color {
        if provider == .antigravity {
            return UsageColorScheme.antigravityPairedInnerColorSwiftUI(innerPercentage ?? 0)
        } else {
            return UsageColorScheme.antigravityThirdPartyPairedInnerColorSwiftUI(innerPercentage ?? 0)
        }
    }

    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                ActivityRingView(
                    outerPercentage: outerPercentage,
                    innerPercentage: innerPercentage,
                    outerColor: outerColor,
                    innerColor: innerColor,
                    isRefreshing: isRefreshing,
                    showRemainingMode: showRemainingMode
                )
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
                    antigravityData: antigravityUsageData,
                    showRemainingMode: showRemainingMode
                )
            }
            .padding(.horizontal, 10)
        }
    }
}
