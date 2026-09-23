//
//  UsageDetailView.swift
//  Agent Ring
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct UsageDetailView: View {
    /// 多账号 Codex 用量（顺序 = 启用账号配置顺序；每账号一列）
    @Binding var codexAccountUsages: [CodexAccountUsage]
    @Binding var cursorUsageData: CursorUsageData?
    @Binding var antigravityUsageData: AntigravityUsageData?
    @Binding var errorMessage: String?
    @Binding var cursorNeedsRelogin: Bool
    @Binding var antigravityNeedsRelogin: Bool
    @ObservedObject var refreshState: RefreshState
    var cursorAccountUsages: [CursorAccountUsage] = []
    var planQuotaStates: [ProviderType: PlanQuotaState] = [:]
    var availableSize: CGSize = CGSize(width: 1040, height: 800)
    var onMenuAction: ((MenuAction) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var localization = LocalizationManager.shared
    @Binding var hasAvailableUpdate: Bool
    @Binding var shouldShowUpdateBadge: Bool

    enum MenuAction {
        case generalSettings
        case authSettings
        case checkForUpdates
        case about
        case quit
        case refresh
        case codexRelogin
        case cursorRelogin
        case antigravityRelogin
    }

    /// 一列 = 一个展示单元（Codex 账号 / Cursor / Antigravity）
    struct ColumnUnit: Identifiable, Hashable {
        enum Source: Hashable {
            case codexAccount(UUID)
            case codexPlaceholder
            case cursorAccount(UUID)
            case cursor
            case plan(ProviderType)
            case antigravity
            case antigravityThird
        }

        let source: Source
        var id: String { "\(source)" }
    }

    @State var rotationAngle: Double = 0
    @State var animationTimer: Timer?
    @ObservedObject private var settings = UserSettings.shared
    private var showRemainingMode: Bool {
        settings.showRemainingMode
    }
    @State private var orderedProviders: [ProviderType] = []
    @State private var currentPage = 0
    @State private var dropTargetProvider: ProviderType?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var draggedProvider: ProviderType? = nil

    private var activeProviders: [ProviderType] {
        UserSettings.shared.orderedActiveProviders(
            hasCodexData: !codexAccountUsages.isEmpty,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
    }

    private var displayProviders: [ProviderType] {
        orderedProviders.isEmpty ? activeProviders : orderedProviders
    }

    /// 展示单元序列：Codex 账号（配置顺序）→ 其他平台
    private var columnUnits: [ColumnUnit] {
        var units: [ColumnUnit] = []
        for provider in displayProviders {
            switch provider {
            case .kimi, .glm:
                units.append(ColumnUnit(source: .plan(provider)))
            case .codex:
                if codexAccountUsages.isEmpty {
                    units.append(ColumnUnit(source: .codexPlaceholder))
                } else {
                    units.append(contentsOf: codexAccountUsages.map { ColumnUnit(source: .codexAccount($0.accountId)) })
                }
            case .cursor:
                units.append(contentsOf: cursorAccountUsages.isEmpty ? [ColumnUnit(source: .cursor)]
                    : cursorAccountUsages.map { ColumnUnit(source: .cursorAccount($0.accountId)) })
            case .antigravity:
                units.append(ColumnUnit(source: .antigravity))
            case .antigravityThird:
                units.append(ColumnUnit(source: .antigravityThird))
            }
        }
        return units
    }

    /// 按每行至多 4 列折行分组
    private func groupedUnitRows() -> [[ColumnUnit]] {
        guard !columnUnits.isEmpty else { return [] }
        let widths = PopoverLayout.wrapRows(unitCount: columnUnits.count, availableWidth: availableSize.width)
        var rows: [[ColumnUnit]] = []
        var cursorIndex = columnUnits.startIndex
        for width in widths {
            let end = columnUnits.index(cursorIndex, offsetBy: width)
            rows.append(Array(columnUnits[cursorIndex..<end]))
            cursorIndex = end
        }
        return rows
    }

    /// 拖拽排序仅在"每列恰好一个平台、单行"时启用；
    /// 多 Codex 账号展开为多列后，账号顺序以认证设置页拖拽为准。
    private var supportsProviderReordering: Bool {
        columnUnits.count == displayProviders.count && PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1), availableWidth: availableSize.width).count == 1
    }

    private func columnWidth(forRowCount count: Int) -> CGFloat {
        PopoverLayout.columnWidth(columnCount: count)
    }

    private var popoverWidth: CGFloat {
        PopoverLayout.viewWidth(maxRowColumns: PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1), availableWidth: availableSize.width).max() ?? 1)
    }

    private var showsMultipleProviders: Bool {
        columnUnits.count > 1
    }

    private var limitRowCount: Int {
        max(
            PopoverLayout.limitRowCount(
                codexUsages: codexAccountUsages.map { $0.usage },
                cursorUsageData: cursorUsageData,
                antigravityUsageData: antigravityUsageData,
                cursorUsages: cursorAccountUsages.compactMap { $0.usage },
                planQuotas: planQuotaStates.values.compactMap { $0.quota }
            ),
            columnUnits.isEmpty ? 0 : 1
        )
    }

    private var pageLayout: (rowsPerPage: Int, pageCount: Int, height: CGFloat) {
        PopoverLayout.pageLayout(
            wrapRowCount: max(1, groupedUnitRows().count),
            limitRowCount: limitRowCount,
            showsMultiple: showsMultipleProviders,
            availableHeight: availableSize.height
        )
    }

    private var visiblePage: Int { min(currentPage, pageLayout.pageCount - 1) }

    private var providerDividerHeight: CGFloat {
        PopoverLayout.rowHeight(limitRowCount: limitRowCount, showsMultiple: showsMultipleProviders)
    }

    private var dashboardTitleText: String {
        let mode = showRemainingMode ? L.Usage.dashboardModeRemaining : L.Usage.dashboardModeUsed
        return L.Usage.dashboardTitle(appName: L.App.name, mode: mode)
    }

    private var codexAnyNeedsRelogin: Bool {
        codexAccountUsages.contains { $0.needsRelogin }
    }

    private var headerView: some View {
        HStack {
            if showsMultipleProviders {
                Text(dashboardTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if let provider = activeProviders.first {
                switch provider {
                case .antigravity, .antigravityThird:
                    if let icon = ImageHelper.createAntigravityIcon(size: 18, isTemplate: false) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(providerTitle(for: provider))
                        .font(.headline)
                case .kimi, .glm:
                    Text(provider.displayName).font(.headline)
                case .cursor:
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 16, weight: .semibold))
                    Text(L.Usage.cursorTitle)
                        .font(.headline)
                case .codex:
                    if let icon = ImageHelper.createCodexIcon(size: 18) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(codexAccountUsages.first?.displayName ?? L.Usage.codexTitle)
                        .font(.headline)
                }
            } else {
                Text(dashboardTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer()
            refreshAndMenuButtons
        }
        .frame(height: 28, alignment: .center)
        .padding(.horizontal)
        .padding(.top)
    }

    private var refreshAndMenuButtons: some View {
        HStack(spacing: 6) {
            Button(action: { onMenuAction?(.refresh) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(refreshState.isRefreshing && !reduceMotion ? rotationAngle : 0))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!refreshState.canRefresh || refreshState.isRefreshing)
            .help(L.Usage.refresh)
            .accessibilityLabel(L.Usage.refresh)

            ZStack(alignment: .topTrailing) {
                Button(action: { onMenuAction?(.generalSettings) }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                    .help(L.Menu.generalSettings)
                .accessibilityLabel(L.Menu.generalSettings)

                if shouldShowUpdateBadge {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        let rows = Array(groupedUnitRows().dropFirst(visiblePage * pageLayout.rowsPerPage).prefix(pageLayout.rowsPerPage))
        if rows.isEmpty {
            if let errorMessage {
                errorState(
                    message: errorMessage,
                    needsRelogin: codexAnyNeedsRelogin || cursorNeedsRelogin || antigravityNeedsRelogin,
                    reloginAction: codexAnyNeedsRelogin ? .codexRelogin : (cursorNeedsRelogin ? .cursorRelogin : .antigravityRelogin)
                )
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(L.Usage.loading)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 100)
            }
        } else if rows.count == 1, let single = rows[0].first, !showsMultipleProviders {
            columnView(for: single)
        } else {
            VStack(spacing: PopoverLayout.rowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, rowUnits in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(rowUnits.enumerated()), id: \.element) { index, unit in
                            if index > 0 {
                                ProviderDivider(height: providerDividerHeight)
                            }
                            columnContainer(for: unit)
                                .frame(width: columnWidth(forRowCount: rowUnits.count))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// 列容器：支持排序时带拖拽；多账号展开后仅展示（账号顺序在认证页拖拽）
    @ViewBuilder
    private func columnContainer(for unit: ColumnUnit) -> some View {
        if supportsProviderReordering, let provider = provider(for: unit) {
            draggableColumn(for: unit, provider: provider)
        } else {
            columnView(for: unit)
        }
    }

    private func provider(for unit: ColumnUnit) -> ProviderType? {
        switch unit.source {
        case .codexAccount, .codexPlaceholder: return .codex
        case .cursor, .cursorAccount: return .cursor
        case .plan(let provider): return provider
        case .antigravity: return .antigravity
        case .antigravityThird: return .antigravityThird
        }
    }

    @ViewBuilder
    private func columnView(for unit: ColumnUnit) -> some View {
        VStack(spacing: 14) {
            if showsMultipleProviders {
                columnHeader(for: unit)
            }
            columnBody(for: unit)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 拖动时原位卡片整体变为半透明（0.35），保持原始尺寸稳定，不拉伸相邻卡片；放下前目标位不插占位，松开才落位。
    @ViewBuilder
    private func draggableColumn(for unit: ColumnUnit, provider: ProviderType) -> some View {
        let isDragging = draggedProvider == provider
        columnView(for: unit)
            .overlay(alignment: providerDropAlignment(for: provider)) {
                if dropTargetProvider == provider && draggedProvider != provider {
                    Capsule().fill(Color.accentColor).frame(width: 2)
                }
            }
            .opacity(isDragging ? 0.35 : 1.0)
            .contentShape(Rectangle())
            .onDrag {
                draggedProvider = provider
                return NSItemProvider(object: provider.rawValue as NSString)
            } preview: {
                columnView(for: unit)
                    .frame(width: columnWidth(forRowCount: 1))
                    .opacity(0.6)
                    .padding(8)
            }
            .onDrop(
                of: [UTType.text.identifier],
                delegate: ProviderDropDelegate(
                    item: provider,
                    providers: $orderedProviders,
                    draggedItem: $draggedProvider,
                    dropTarget: $dropTargetProvider,
                    reduceMotion: reduceMotion
                )
            )
    }

    private func providerDropAlignment(for provider: ProviderType) -> Alignment {
        guard let draggedProvider,
              let source = displayProviders.firstIndex(of: draggedProvider),
              let target = displayProviders.firstIndex(of: provider) else { return .leading }
        return source < target ? .trailing : .leading
    }

    private func columnHeader(for unit: ColumnUnit) -> some View {
        Text(columnTitle(for: unit))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 20)
            .help(supportsProviderReordering ? L.Usage.dragToReorder : columnTitle(for: unit))
    }

    private func columnTitle(for unit: ColumnUnit) -> String {
        switch unit.source {
        case .codexAccount(let accountId):
            return codexAccountUsages.first { $0.accountId == accountId }?.displayName ?? L.Usage.codexTitle
        case .codexPlaceholder:
            return L.Usage.codexTitle
        case .plan(let provider): return provider.displayName
        case .cursorAccount(let id):
            return "Cursor · " + (cursorAccountUsages.first { $0.accountId == id }?.displayName ?? L.Usage.cursorTitle)
        case .cursor:
            return L.Usage.cursorTitle
        case .antigravity:
            return L.Usage.antigravityTitle
        case .antigravityThird:
            return "Antigravity Third"
        }
    }

    private func providerTitle(for provider: ProviderType) -> String {
        switch provider {
        case .kimi, .glm: return provider.displayName
        case .codex: return L.Usage.codexTitle
        case .cursor: return L.Usage.cursorTitle
        case .antigravity: return L.Usage.antigravityTitle
        case .antigravityThird: return "Antigravity Third"
        }
    }

    @ViewBuilder
    private func columnBody(for unit: ColumnUnit) -> some View {
        switch unit.source {
        case .codexAccount(let accountId):
            let entry = codexAccountUsages.first { $0.accountId == accountId }
            if let usage = entry?.usage {
                CodexColumnView(
                    codexUsageData: usage,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    onRefresh: { onMenuAction?(.refresh) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: entry?.needsRelogin == true
                        ? L.Error.sessionExpired
                        : (entry?.errorMessage ?? errorMessage ?? L.Usage.loading),
                    needsRelogin: entry?.needsRelogin == true,
                    reloginAction: .codexRelogin
                )
                .frame(maxWidth: .infinity)
            }
        case .codexPlaceholder:
            errorState(
                message: errorMessage ?? L.Usage.loading,
                needsRelogin: false,
                reloginAction: .codexRelogin
            )
            .frame(maxWidth: .infinity)
        case .plan(let provider):
            if let quota = planQuotaStates[provider]?.quota {
                PlanQuotaColumnView(quota: quota, showRemaining: showRemainingMode,
                    isRefreshing: refreshState.isRefreshing, onRefresh: { onMenuAction?(.refresh) })
            } else {
                errorState(message: planQuotaStates[provider]?.error ?? L.Usage.loading,
                    needsRelogin: false, reloginAction: .authSettings)
            }
        case .cursor, .cursorAccount:
            let entry: CursorAccountUsage? = {
                if case .cursorAccount(let id) = unit.source { return cursorAccountUsages.first { $0.accountId == id } }
                return nil
            }()
            let usage = entry != nil ? entry?.usage : cursorUsageData
            let needsRelogin = entry?.needsRelogin ?? cursorNeedsRelogin
            if let cursorUsageData = usage {
                CursorColumnView(
                    cursorUsageData: cursorUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    onRefresh: { onMenuAction?(.refresh) },
                    errorMessage: entry?.errorMessage,
                    lastUpdatedAt: entry?.lastUpdatedAt
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: needsRelogin ? L.Error.sessionExpired : (entry?.errorMessage ?? L.Usage.loading),
                    needsRelogin: needsRelogin,
                    reloginAction: .cursorRelogin
                )
                .frame(maxWidth: .infinity)
            }
        case .antigravity, .antigravityThird:
            let provider: ProviderType = unit.source == .antigravity ? .antigravity : .antigravityThird
            if let antigravityUsageData {
                AntigravityColumnView(
                    provider: provider,
                    antigravityUsageData: antigravityUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    onRefresh: { onMenuAction?(.refresh) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: antigravityNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: antigravityNeedsRelogin,
                    reloginAction: .antigravityRelogin
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func errorState(message: String, needsRelogin: Bool, reloginAction: MenuAction = .codexRelogin) -> some View {
        if message == L.Usage.loading && !needsRelogin {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L.Usage.loading).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            VStack(spacing: 12) {
                Image(systemName: needsRelogin ? "lock.open.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.subheadline)
                    .lineLimit(3)
                    .help(message)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                if needsRelogin {
                    Button(action: { onMenuAction?(reloginAction) }) {
                        Label(reloginButtonTitle(for: reloginAction), systemImage: "arrow.counterclockwise.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button(action: { onMenuAction?(.authSettings) }) {
                        Label(L.Usage.goToSettings, systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
            .padding()
        }
    }

    private func reloginButtonTitle(for action: MenuAction) -> String {
        switch action {
        case .cursorRelogin: return L.Usage.cursorRelogin
        case .antigravityRelogin: return L.Usage.antigravityRelogin
        default: return L.Usage.codexRelogin
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            headerView
            mainContent
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(height: PopoverLayout.contentHeight(
                    wrapRowCount: pageLayout.rowsPerPage,
                    limitRowCount: limitRowCount,
                    showsMultiple: showsMultipleProviders
                ) - PopoverLayout.chromeHeight, alignment: .top)
            if pageLayout.pageCount > 1 {
                HStack(spacing: 12) {
                    Button { currentPage = max(0, visiblePage - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(visiblePage == 0)
                    .accessibilityLabel(Text("usage.previous_page"))
                    Text("\(visiblePage + 1) / \(pageLayout.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { currentPage = min(pageLayout.pageCount - 1, visiblePage + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(visiblePage == pageLayout.pageCount - 1)
                    .accessibilityLabel(Text("usage.next_page"))
                }
                .buttonStyle(.borderless)
                .frame(height: 20)
            }
        }
        .padding(.bottom, 16)
        .frame(width: popoverWidth, height: pageLayout.height, alignment: .top)
        .background(reduceTransparency || contrast == .increased ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .id(localization.updateTrigger)
        .onAppear {
            currentPage = 0
            orderedProviders = activeProviders
            if !UserDefaults.standard.bool(forKey: "ringShowsRemaining.defaultMigrated") {
                UserSettings.shared.showRemainingMode = true
                UserDefaults.standard.set(true, forKey: "ringShowsRemaining.defaultMigrated")
            }
            if refreshState.isRefreshing {
                startRotationAnimation()
            }
        }
        .onChange(of: activeProviders) { newProviders in
            if orderedProviders != newProviders && draggedProvider == nil {
                orderedProviders = newProviders
            }
        }
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            if draggedProvider != nil && NSEvent.pressedMouseButtons == 0 {
                draggedProvider = nil
                dropTargetProvider = nil
            }
        }
        .onChange(of: reduceMotion) { reduced in
            if reduced { stopRotationAnimation() }
            else if refreshState.isRefreshing { startRotationAnimation() }
        }
        .onHover { _ in
            if NSEvent.pressedMouseButtons == 0 && draggedProvider != nil {
                draggedProvider = nil
                dropTargetProvider = nil
            }
        }
        .onChange(of: refreshState.isRefreshing) { newValue in
            newValue ? startRotationAnimation() : stopRotationAnimation()
        }
        .onDisappear {
            draggedProvider = nil
            dropTargetProvider = nil
            stopRotationAnimation()
        }
        #if DEBUG
        .background(UserSettings.shared.debugKeepDetailWindowOpen ? Color.white : Color.clear)
        #else
        .background(Color.clear)
        #endif
    }

}

private struct ProviderDropDelegate: DropDelegate {
    let item: ProviderType
    @Binding var providers: [ProviderType]
    @Binding var draggedItem: ProviderType?
    @Binding var dropTarget: ProviderType?
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard draggedItem != nil, draggedItem != item else { return }
        dropTarget = item
    }

    func dropExited(info: DropInfo) {
        if dropTarget == item { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItem = nil; dropTarget = nil }

        if providers.isEmpty {
            providers = UserSettings.shared.orderedActiveProviders()
        }
        guard let currentDragged = draggedItem,
              currentDragged != item,
              let from = providers.firstIndex(of: currentDragged),
              let to = providers.firstIndex(of: item) else {
            return false
        }

        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
            providers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            UserSettings.shared.setProviderOrder(providers)
        }
        return true
    }
}

private extension UsageDetailView {
    func startRotationAnimation() {
        stopRotationAnimation()
        guard !reduceMotion else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            rotationAngle += 3
            if rotationAngle >= 360 {
                rotationAngle = 0
            }
        }
    }

    func stopRotationAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

struct UsageDetailView_Previews: PreviewProvider {
    @State static var sampleCodexUsages: [CodexAccountUsage] = [
        CodexAccountUsage(
            accountId: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            displayName: "工作号",
            usage: CodexUsageData(
                primary: .init(percentage: 42, resetsAt: Date().addingTimeInterval(3600 * 2)),
                secondary: .init(percentage: 58, resetsAt: Date().addingTimeInterval(3600 * 24 * 3)),
                extraUsage: CodexExtraUsageData(
                    hasCredits: true,
                    unlimited: false,
                    overageLimitReached: false,
                    spendControlReached: false,
                    balance: Decimal(12),
                    approxLocalMessages: nil,
                    approxCloudMessages: nil
                )
            )
        ),
        CodexAccountUsage(
            accountId: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!,
            displayName: "个人号",
            usage: CodexUsageData(
                primary: .init(percentage: 12, resetsAt: Date().addingTimeInterval(3600 * 5)),
                secondary: .init(percentage: 88, resetsAt: Date().addingTimeInterval(3600 * 24)),
                extraUsage: nil
            )
        ),
        CodexAccountUsage(
            accountId: UUID(uuidString: "33333333-0000-0000-0000-000000000003")!,
            displayName: "测试号",
            usage: nil,
            needsRelogin: true
        )
    ]
    @State static var error: String?
    @State static var hasUpdate = false
    @State static var showBadge = false

    static var previews: some View {
        UsageDetailView(
            codexAccountUsages: $sampleCodexUsages,
            cursorUsageData: .constant(nil),
            antigravityUsageData: .constant(nil),
            errorMessage: $error,
            cursorNeedsRelogin: .constant(false),
            antigravityNeedsRelogin: .constant(false),
            refreshState: RefreshState(),
            hasAvailableUpdate: $hasUpdate,
            shouldShowUpdateBadge: $showBadge
        )
    }
}
