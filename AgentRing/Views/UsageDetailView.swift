//
//  UsageDetailView.swift
//  Agent Ring
//

import SwiftUI
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
    var onMenuAction: ((MenuAction) -> Void)? = nil
    @StateObject private var localization = LocalizationManager.shared
    @Binding var hasAvailableUpdate: Bool
    @Binding var shouldShowUpdateBadge: Bool

    enum LoadingAnimationType: Int, CaseIterable {
        case rainbow = 0
        case dashed = 1
        case pulse = 2

        var name: String {
            switch self {
            case .rainbow: return L.LoadingAnimation.rainbow
            case .dashed: return L.LoadingAnimation.dashed
            case .pulse: return L.LoadingAnimation.pulse
            }
        }
    }

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
            case cursor
            case antigravity
            case antigravityThird
        }

        let source: Source
        var id: String { "\(source)" }
    }

    @State var codexAnimationType: LoadingAnimationType = .rainbow
    @State var cursorAnimationType: LoadingAnimationType = .rainbow
    @State var antigravityAnimationType: LoadingAnimationType = .rainbow
    @State var rotationAngle: Double = 0
    @State var animationTimer: Timer?
    @State private var showAnimationTypeHint = false
    @State private var animationTypeHintName = ""
    @State private var animationTypeHintDismissWorkItem: DispatchWorkItem?
    @ObservedObject private var settings = UserSettings.shared
    private var showRemainingMode: Bool {
        settings.showRemainingMode
    }
    @State private var remainingModeAnimationTrigger = 0
    @State private var orderedProviders: [ProviderType] = []
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
            case .codex:
                if codexAccountUsages.isEmpty {
                    units.append(ColumnUnit(source: .codexPlaceholder))
                } else {
                    units.append(contentsOf: codexAccountUsages.map { ColumnUnit(source: .codexAccount($0.accountId)) })
                }
            case .cursor:
                units.append(ColumnUnit(source: .cursor))
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
        let widths = PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1))
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
        columnUnits.count == displayProviders.count && PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1)).count == 1
    }

    private func columnWidth(forRowCount count: Int) -> CGFloat {
        PopoverLayout.columnWidth(columnCount: count)
    }

    private var popoverWidth: CGFloat {
        PopoverLayout.viewWidth(maxRowColumns: PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1)).max() ?? 1)
    }

    private var showsMultipleProviders: Bool {
        columnUnits.count > 1
    }

    private var limitRowCount: Int {
        max(
            PopoverLayout.limitRowCount(
                codexUsages: codexAccountUsages.map { $0.usage },
                cursorUsageData: cursorUsageData,
                antigravityUsageData: antigravityUsageData
            ),
            columnUnits.isEmpty ? 0 : 1
        )
    }

    private var contentSpacing: CGFloat {
        limitRowCount >= 2 ? 10 : 16
    }

    private var contentHeight: CGFloat {
        PopoverLayout.contentHeight(
            wrapRowCount: PopoverLayout.wrapRows(unitCount: max(columnUnits.count, 1)).count,
            limitRowCount: limitRowCount,
            showsMultiple: showsMultipleProviders
        )
    }

    private var providerDividerHeight: CGFloat {
        max(160, contentHeight - (showsMultipleProviders ? 52 : 40))
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
        .frame(height: 20, alignment: .center)
        .padding(.horizontal)
        .padding(.top)
    }

    private var refreshAndMenuButtons: some View {
        HStack(spacing: 6) {
            Button(action: { onMenuAction?(.refresh) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(refreshState.isRefreshing ? rotationAngle : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!refreshState.canRefresh || refreshState.isRefreshing)
            .focusable(false)
            .help(L.Usage.refresh)

            ZStack(alignment: .topTrailing) {
                Button(action: { onMenuAction?(.generalSettings) }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(L.Menu.generalSettings)

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
        let rows = groupedUnitRows()
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
            VStack(spacing: 12) {
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
        case .cursor: return .cursor
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
                    draggedItem: $draggedProvider
                )
            )
    }

    private func columnHeader(for unit: ColumnUnit) -> some View {
        Text(columnTitle(for: unit))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .help(L.Usage.dragToReorder)
    }

    private func columnTitle(for unit: ColumnUnit) -> String {
        switch unit.source {
        case .codexAccount(let accountId):
            return codexAccountUsages.first { $0.accountId == accountId }?.displayName ?? L.Usage.codexTitle
        case .codexPlaceholder:
            return L.Usage.codexTitle
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
                    animationType: $codexAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
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
        case .cursor:
            if let cursorUsageData {
                CursorColumnView(
                    cursorUsageData: cursorUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    animationType: $cursorAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: cursorNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: cursorNeedsRelogin,
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
                    animationType: $antigravityAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
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

    private func errorState(message: String, needsRelogin: Bool, reloginAction: MenuAction = .codexRelogin) -> some View {
        VStack(spacing: 12) {
            Image(systemName: needsRelogin ? "lock.open.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
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

    private func reloginButtonTitle(for action: MenuAction) -> String {
        switch action {
        case .cursorRelogin: return L.Usage.cursorRelogin
        case .antigravityRelogin: return L.Usage.antigravityRelogin
        default: return L.Usage.codexRelogin
        }
    }

    private var animationHintView: some View {
        Group {
            if showAnimationTypeHint {
                AnimationTypeHintView(animationTypeName: animationTypeHintName)
                    .padding(.top, -8)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    var body: some View {
        VStack(spacing: contentSpacing) {
            VStack(spacing: contentSpacing) {
                headerView
                mainContent
            }
            .offset(y: showAnimationTypeHint ? -18 : 0)

            animationHintView
            Spacer()
        }
        .frame(width: popoverWidth, height: contentHeight)
        .animation(.easeInOut(duration: 0.25), value: showAnimationTypeHint)
        .id(localization.updateTrigger)
        .onAppear {
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
        .onChange(of: settings.showRemainingMode) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                remainingModeAnimationTrigger += 1
            }
        }
        .onHover { _ in
            if NSEvent.pressedMouseButtons == 0 && draggedProvider != nil {
                draggedProvider = nil
            }
        }
        .onChange(of: refreshState.isRefreshing) { newValue in
            newValue ? startRotationAnimation() : stopRotationAnimation()
        }
        .onDisappear {
            draggedProvider = nil
            stopRotationAnimation()
            animationTypeHintDismissWorkItem?.cancel()
        }
        #if DEBUG
        .background(UserSettings.shared.debugKeepDetailWindowOpen ? Color.white : Color.clear)
        #else
        .background(Color.clear)
        #endif
    }

    private func showAnimationHint(_ animationTypeName: String) {
        animationTypeHintDismissWorkItem?.cancel()
        animationTypeHintName = animationTypeName
        withAnimation(.easeInOut(duration: 0.25)) {
            showAnimationTypeHint = true
        }

        let dismissWorkItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) {
                showAnimationTypeHint = false
            }
        }
        animationTypeHintDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: dismissWorkItem)
    }
}

private struct ProviderDropDelegate: DropDelegate {
    let item: ProviderType
    @Binding var providers: [ProviderType]
    @Binding var draggedItem: ProviderType?

    func dropEntered(info: DropInfo) {
        // 悬停时不把被拖卡片插进目标位，避免半透明占位；只在松开时落位。
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItem = nil }

        if providers.isEmpty {
            providers = UserSettings.shared.orderedActiveProviders()
        }
        guard let currentDragged = draggedItem,
              currentDragged != item,
              let from = providers.firstIndex(of: currentDragged),
              let to = providers.firstIndex(of: item) else {
            return false
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            providers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            UserSettings.shared.setProviderOrder(providers)
        }
        return true
    }
}

private extension UsageDetailView {
    func startRotationAnimation() {
        stopRotationAnimation()
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
