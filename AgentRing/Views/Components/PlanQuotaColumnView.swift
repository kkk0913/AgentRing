import SwiftUI

struct PlanQuotaColumnView: View {
    let quota: PlanQuota
    let showRemaining: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            if let first = quota.windows.first {
                ActivityRingView(outerPercentage: first.usedPercentage,
                    innerPercentage: quota.windows.dropFirst().first?.usedPercentage,
                    outerColor: .accentColor, innerColor: .accentColor.opacity(0.6),
                    isRefreshing: isRefreshing, showRemainingMode: showRemaining)
                    .frame(height: 100)
                    .contentShape(Circle())
                    .onTapGesture { if !isRefreshing { onRefresh() } }
                    .accessibilityLabel(L.Usage.refresh)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { if !isRefreshing { onRefresh() } }
            }
            VStack(spacing: 6) {
                ForEach(quota.windows) { window in
                    HStack(spacing: 8) {
                        Text(window.title).foregroundStyle(.secondary).lineLimit(1).help(window.title)
                        Spacer(minLength: 4)
                        Text(UsageRingDisplay.percentLabel(usedPercentage: window.usedPercentage, showRemainingMode: showRemaining))
                            .fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle(window.usedPercentage >= 95 ? Color.red : Color.primary)
                        if let reset = window.resetsAt {
                            Text(reset, style: .relative).foregroundStyle(.secondary).lineLimit(1)
                                .help(L.provider("quota.resets") + " " + reset.formatted())
                        } else {
                            Text("—").foregroundStyle(.tertiary).help(L.provider("quota.no_reset"))
                        }
                    }
                    .font(.system(size: 12)).frame(height: 17)
                }
            }.padding(.horizontal, 10)
        }
        .help(L.provider("updated") + " " + quota.fetchedAt.formatted())
    }
}
