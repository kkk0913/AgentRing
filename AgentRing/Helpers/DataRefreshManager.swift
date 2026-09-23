//
//  DataRefreshManager.swift
//  Agent Ring
//

import Foundation
import Combine
import OSLog
import AppKit

final class DataRefreshManager: ObservableObject {
    /// 按账号的 API 服务实例池（token 缓存 / OAuth 单飞 / 轮换写回均按实例隔离）
    private var codexApiServices: [UUID: CodexAPIService] = [:]
    private var cursorApiServices: [UUID: CursorAPIService] = [:]
    private let antigravityApiService = AntigravityAPIService()
    @Published var planQuotaStates: [ProviderType: PlanQuotaState] = [:]
    private var planServices: [ProviderType: PlanQuotaService] = [:]
    private var fetchGeneration = 0
    @Published var cursorAccountUsages: [CursorAccountUsage] = []
    private let timerManager = TimerManager()
    private let settings = UserSettings.shared

    /// 多账号用量（顺序 = 启用账号配置顺序）
    @Published var codexAccountUsages: [CodexAccountUsage] = []
    @Published var cursorUsageData: CursorUsageData?
    @Published var antigravityUsageData: AntigravityUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var cursorNeedsRelogin = false
    @Published private(set) var antigravityNeedsRelogin = false
    let refreshState = RefreshState()

    /// 每账号上次 primary resetsAt（重置验证定时器按账号挂）
    private var lastCodexResetsAtByAccount: [UUID: Date] = [:]
    private var codexSessionExpiredNotifiedAccounts: Set<UUID> = []
    private var lastCursorResetsAt: Date?
    private var lastAntigravityResetsAt: Date?
    private var lastManualRefreshTime: Date?
    private var lastAPIFetchTime: Date?
    private var refreshAnimationStartTime: Date?
    private let minimumAnimationDuration: TimeInterval = 1.0
    private var refreshActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var cursorSessionExpiredNotifiedAccounts: Set<UUID> = []
    private var antigravitySessionExpiredNotified = false
    private var pendingFetches = 0

    #if DEBUG
    /// DEBUG mock：合成多个假账号，方便预览多列布局
    private lazy var debugMockAccounts: [Account] = (0..<3).map { i in
        Account(
            id: UUID(uuidString: String(format: "DEB0000%d-0000-0000-0000-00000000000%d", i + 1, i + 1))!,
            credentialToken: "mock-token-\(i + 1)",
            accountIdentifier: "mock\(i + 1)",
            accountName: "Mock \(i + 1)",
            alias: nil,
            createdAt: Date(),
            provider: .codex
        )
    }
    #endif

    /// 本轮应拉取的 Codex 账号（启用 + 有凭据，顺序 = 配置顺序）
    private var fetchableCodexAccounts: [Account] {
        guard settings.isProviderEnabled(.codex) else { return [] }
        #if DEBUG
        if shouldSuppressDebugCodexUsageForDisplayOptions {
            return []
        }
        if settings.debugModeEnabled {
            return debugMockAccounts
        }
        #endif
        return settings.enabledCodexAccounts.filter { !$0.credentialToken.isEmpty }
    }

    private var shouldFetchCodexUsage: Bool {
        !fetchableCodexAccounts.isEmpty
    }

    private var fetchableCursorAccounts: [Account] {
        guard settings.isProviderEnabled(.cursor) else { return [] }
        #if DEBUG
        if settings.debugModeEnabled {
            return debugMockAccounts.prefix(2).map { account in
                Account(id: account.id, credentialToken: account.credentialToken,
                    accountIdentifier: "cursor-" + account.accountIdentifier,
                    accountName: "Cursor " + account.accountName, alias: nil,
                    createdAt: account.createdAt, provider: .cursor)
            }
        }
        #endif
        return settings.enabledCursorAccounts.filter { !$0.credentialToken.isEmpty }
    }

    private var shouldFetchCursorUsage: Bool {
        guard settings.isProviderEnabled(.cursor) else { return false }
        #if DEBUG
        return settings.debugModeEnabled || settings.hasValidCursorCredentials
        #else
        return settings.hasValidCursorCredentials
        #endif
    }

    private var shouldFetchAntigravityUsage: Bool {
        guard settings.isProviderEnabled(.antigravity) else { return false }
        #if DEBUG
        return settings.debugModeEnabled || settings.hasValidAntigravityCredentials
        #else
        return settings.hasValidAntigravityCredentials
        #endif
    }

    private var shouldSuppressDebugCodexUsageForDisplayOptions: Bool {
        #if DEBUG
        return settings.debugModeEnabled
            && settings.displayMode == .custom
            && !settings.customDisplayMenuBarOnly
            && settings.customDisplayTypes.isEmpty
        #else
        return false
        #endif
    }

    /// 所有 Codex 账号均无可用数据（用于决定是否展示全局错误）
    private var codexHasAnyUsage: Bool {
        codexAccountUsages.contains { $0.usage != nil }
    }

    /// 副屏同步账号（勾选中的第一个）的用量
    private var bluetoothCodexUsage: CodexUsageData? {
        if let id = settings.bluetoothCodexAccount?.id {
            return codexAccountUsages.first { $0.accountId == id }?.usage
        }
        return codexAccountUsages.first?.usage
    }

    /// 蓝牙副屏读取入口（设置开关即时推送用）
    var bluetoothCodexDataForSync: CodexUsageData? { bluetoothCodexUsage }

    private enum TimerID {
        static let mainRefresh = "mainRefresh"
        static let popoverRefresh = "popoverRefresh"
        static let codexTokenRefresh = "codexTokenRefresh"

        /// 每账号一套重置验证定时器
        static func codexResetVerify(_ accountId: UUID) -> [String] {
            ["codexResetVerify1", "codexResetVerify2", "codexResetVerify3"].map { "\($0)_\(accountId.uuidString)" }
        }
    }

    init() {
        setupWakeObserver()
    }

    func fetchUsage() {
        fetchGeneration += 1
        let plans = [ProviderType.kimi, .glm].filter { settings.isProviderEnabled($0) }
        for provider in [ProviderType.kimi, .glm] where !plans.contains(provider) {
            planServices.removeValue(forKey: provider)?.close()
            planQuotaStates.removeValue(forKey: provider)
        }
        if !settings.isProviderEnabled(.codex) {
            clearCodexUsageState()
            codexApiServices.values.forEach { $0.cancelAllRequests() }
            codexApiServices.removeAll()
        }
        let codexAccountsToFetch = fetchableCodexAccounts
        reconcileCodexUsageState()
        let cursorAccountsToFetch = fetchableCursorAccounts
        let fetchCursor = !cursorAccountsToFetch.isEmpty
        let fetchAntigravity = shouldFetchAntigravityUsage
        reconcileCursorUsageState()
        pendingFetches = 0

        guard !codexAccountsToFetch.isEmpty || fetchCursor || fetchAntigravity || !plans.isEmpty else {
            isLoading = false
            clearCodexUsageState()
            clearCursorUsageState()
            clearAntigravityUsageState()
            errorMessage = UsageError.noCredentials.localizedDescription
            endRefreshAnimationWithMinimumDuration { }
            return
        }

        isLoading = true
        errorMessage = nil
        lastAPIFetchTime = Date()
        pendingFetches = codexAccountsToFetch.count + cursorAccountsToFetch.count + (fetchAntigravity ? 1 : 0) + plans.count

        for account in codexAccountsToFetch {
            fetchCodexUsage(account, countsTowardBatch: true)
        }
        for account in cursorAccountsToFetch { fetchCursorUsage(account) }
        if fetchAntigravity { fetchAntigravityUsage() }
        for provider in plans { fetchPlanQuota(provider) }
    }

    private func codexApiService(for accountId: UUID) -> CodexAPIService {
        if let service = codexApiServices[accountId] { return service }
        let service = CodexAPIService(accountId: accountId)
        codexApiServices[accountId] = service
        return service
    }

    /// 停用/删除账号后清掉残留的实例、定时器与状态
    private func pruneCodexApiServices() {
        let validIds = Set(settings.codexAccounts.map(\.id))
        for accountId in codexApiServices.keys where !validIds.contains(accountId) {
            codexApiServices.removeValue(forKey: accountId)
            lastCodexResetsAtByAccount.removeValue(forKey: accountId)
            codexSessionExpiredNotifiedAccounts.remove(accountId)
            cancelCodexResetVerification(accountId: accountId)
        }
    }

    private func fetchCodexUsage(_ account: Account, countsTowardBatch: Bool = false) {
        guard settings.isProviderEnabled(.codex), settings.isCodexAccountEnabled(account.id) else { return }
        let generation = fetchGeneration
        codexApiService(for: account.id).fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration else { return }
                switch result {
                case .success(let data):
                    self.processCodexSuccess(data, account: account)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.attemptTokenRefreshAndRetry(account)
                    } else {
                        self.setCodexAccountError(account, error.localizedDescription)
                        Logger.menuBar.info("Codex 请求失败(\(account.displayName, privacy: .public)): \(error.localizedDescription)")
                    }
                }
                if countsTowardBatch { self.noteFetchFinished(generation: generation) }
            }
        }
    }

    private func reconcileCursorUsageState() {
        let cursorAccounts = fetchableCursorAccounts
        cursorSessionExpiredNotifiedAccounts.formIntersection(Set(settings.cursorAccounts.map(\.id)))
        let cursorMap = Dictionary(uniqueKeysWithValues: cursorAccountUsages.map { ($0.accountId, $0) })
        cursorAccountUsages = cursorAccounts.map { account in
            var entry = cursorMap[account.id] ?? CursorAccountUsage(accountId: account.id, displayName: account.displayName)
            entry.displayName = account.displayName
            return entry
        }
        for id in Array(cursorApiServices.keys) where !cursorAccounts.contains(where: { $0.id == id }) {
            cursorApiServices.removeValue(forKey: id)?.cancelAllRequests()
        }
        syncPrimaryCursorUsage()
    }

    private func syncPrimaryCursorUsage() {
        // Legacy consumers (companion displays) always use the first enabled account, never the first successful response.
        cursorUsageData = cursorAccountUsages.first?.usage
        cursorNeedsRelogin = cursorAccountUsages.contains { $0.needsRelogin }
    }

    private func fetchCursorUsage(_ account: Account) {
        let generation = fetchGeneration
        let service = cursorApiServices[account.id] ?? CursorAPIService(accountId: account.id)
        cursorApiServices[account.id] = service
        service.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration,
                      let index = self.cursorAccountUsages.firstIndex(where: { $0.accountId == account.id }) else { return }
                switch result {
                case .success(let data):
                    self.cursorSessionExpiredNotifiedAccounts.remove(account.id)
                    let previous = self.cursorAccountUsages[index].usage
                    self.cursorAccountUsages[index] = CursorAccountUsage(accountId: account.id, displayName: account.displayName, usage: data, lastUpdatedAt: Date())
                    if self.settings.notificationsEnabled {
                        NotificationManager.shared.checkAndNotify(cursorUsageData: data, previousData: previous, account: account)
                    }
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        if self.settings.notificationsEnabled,
                           self.cursorSessionExpiredNotifiedAccounts.insert(account.id).inserted {
                            NotificationManager.shared.sendCursorSessionExpiredNotification(accountId: account.id, accountLabel: account.displayName)
                        }
                        self.cursorAccountUsages[index].needsRelogin = true
                        self.cursorAccountUsages[index].usage = nil
                    }
                    self.cursorAccountUsages[index].errorMessage = error.localizedDescription
                }
                self.syncPrimaryCursorUsage()
                self.pushBluetoothSync()
                self.noteFetchFinished(generation: generation)
            }
        }
    }

    private func fetchAntigravityUsage() {
        let generation = fetchGeneration
        antigravityApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration else { return }
                switch result {
                case .success(let data):
                    self.processAntigravitySuccess(data)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.markAntigravityNeedsRelogin()
                    } else if case UsageError.noCredentials = error {
                        self.clearAntigravityUsageState()
                        Logger.menuBar.info("Antigravity 无可用凭证")
                    } else {
                        Logger.menuBar.info("Antigravity 请求失败: \(error.localizedDescription)")
                        if self.antigravityUsageData == nil && !self.codexHasAnyUsage && self.cursorUsageData == nil {
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
                self.noteFetchFinished(generation: generation)
            }
        }
    }

    private func fetchPlanQuota(_ provider: ProviderType) {
        let generation = fetchGeneration
        guard let configuration = settings.planConfigurations[provider] else {
            planQuotaStates[provider] = PlanQuotaState(error: L.provider("configure_first"))
            noteFetchFinished(generation: generation)
            return
        }
        let service = planServices[provider] ?? PlanQuotaService()
        planServices[provider] = service
        service.fetch(provider: provider, configuration: configuration) { [weak self] result in
            guard let self, generation == self.fetchGeneration, self.settings.isProviderEnabled(provider) else { return }
            switch result {
            case .success(let quota): self.planQuotaStates[provider] = PlanQuotaState(quota: quota)
            case .failure(let error):
                // Never show cached values as a live successful quota after an error.
                self.planQuotaStates[provider] = PlanQuotaState(error: error.localizedDescription)
            }
            self.noteFetchFinished(generation: generation)
        }
    }

    private func noteFetchFinished(generation: Int) {
        guard generation == fetchGeneration, pendingFetches > 0 else { return }
        pendingFetches -= 1
        if pendingFetches == 0 {
            isLoading = false
            endRefreshAnimationWithMinimumDuration { }
            // Monitoring may synchronously start a new batch via refreshIntervalChanged.
            publishSmartMonitoringUtilizations()
        }
    }

    private func processAntigravitySuccess(_ data: AntigravityUsageData) {
        antigravityUsageData = data
        antigravityNeedsRelogin = false
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsReloginState {
            errorMessage = nil
        }

        lastAntigravityResetsAt = data.primary?.resetsAt

        pushBluetoothSync()
    }

    /// 蓝牙副屏：任一供应商数据更新后推送最新报文
    /// processXxxSuccess 都在主线程回调，这里同步捕获数据后 hop 到 MainActor 构造
    private func pushBluetoothSync() {
        guard settings.bluetoothSyncEnabled else { return }
        let codex = bluetoothCodexUsage
        let cursor = cursorUsageData
        let antigravity = antigravityUsageData
        Task { @MainActor in
            BluetoothSyncService.shared.pushPayload(
                codexUsageData: codex,
                cursorUsageData: cursor,
                antigravityUsageData: antigravity
            )
            BLESyncService.shared.pushPayload(
                codexUsageData: codex,
                cursorUsageData: cursor,
                antigravityUsageData: antigravity
            )
        }
    }

    private func publishSmartMonitoringUtilizations() {
        var utilizations: [String: Double] = [:]
        for entry in codexAccountUsages {
            if let usage = entry.usage, let value = monitoringUtilization(for: usage) {
                utilizations["codex:\(entry.accountId)"] = value
            }
        }
        for entry in cursorAccountUsages {
            if let value = entry.usage?.included?.percentage {
                utilizations["cursor:\(entry.accountId)"] = value
            }
        }
        if let usage = antigravityUsageData, let value = monitoringUtilization(for: usage) {
            utilizations["antigravity"] = value
        }
        for (provider, state) in planQuotaStates {
            for window in state.quota?.windows ?? [] { utilizations[provider.rawValue + ":" + window.id] = window.usedPercentage }
        }
        settings.updateSmartMonitoringMode(accountUtilizations: utilizations)
    }

    private func clearCursorUsageState() {
        cursorAccountUsages = []
        cursorUsageData = nil
        lastCursorResetsAt = nil
    }

    private func clearAntigravityUsageState() {
        antigravityUsageData = nil
        lastAntigravityResetsAt = nil
    }

    private func resetCursorReloginState() {
        cursorNeedsRelogin = false
    }

    private func resetAntigravityReloginState() {
        antigravityNeedsRelogin = false
        antigravitySessionExpiredNotified = false
    }

    private func markAntigravityNeedsRelogin() {
        antigravityNeedsRelogin = true
        AntigravityAPIService.invalidateCredentialsCache()
        if !antigravitySessionExpiredNotified {
            antigravitySessionExpiredNotified = true
            Logger.menuBar.notice("Antigravity 会话失效，需要重新登录 Antigravity 客户端")
        }
        if !codexHasAnyUsage && cursorUsageData == nil {
            errorMessage = UsageError.sessionExpired.localizedDescription
        }
        clearAntigravityUsageState()
    }

    // MARK: - Codex 多账号状态

    /// 是否有任一 Codex 账号处于需重登录状态
    private var codexNeedsReloginState: Bool {
        codexAccountUsages.contains { $0.needsRelogin }
    }

    private func upsertCodexUsage(_ entry: CodexAccountUsage, account: Account) {
        var map = Dictionary(uniqueKeysWithValues: codexAccountUsages.map { ($0.accountId, $0) })
        map[account.id] = entry
        // 顺序 = 启用账号（可拉取）顺序；已不在列表的残留项丢弃
        let order = fetchableCodexAccounts.map(\.id)
        codexAccountUsages = order.compactMap { map[$0] }
    }

    private func setCodexAccountError(_ account: Account, _ message: String) {
        var entry = codexAccountUsages.first { $0.accountId == account.id }
            ?? CodexAccountUsage(accountId: account.id, displayName: account.displayName)
        entry.errorMessage = message
        upsertCodexUsage(entry, account: account)
        // 单账号网络瞬断不打扰；全部账号都无数据才写全局错误
        if !codexHasAnyUsage && cursorUsageData == nil && antigravityUsageData == nil {
            errorMessage = message
        }
    }

    /// 账号启停或排序后保留仍启用账号的最后一次数据，避免菜单栏在重新拉取时跳动。
    private func reconcileCodexUsageState() {
        let previous = Dictionary(uniqueKeysWithValues: codexAccountUsages.map { ($0.accountId, $0) })
        codexAccountUsages = fetchableCodexAccounts.map { account in
            var entry = previous[account.id]
                ?? CodexAccountUsage(accountId: account.id, displayName: account.displayName)
            entry.displayName = account.displayName
            return entry
        }
    }

    private func clearCodexUsageState(clearError: Bool = true) {
        codexAccountUsages = []
        if clearError {
            errorMessage = nil
        }
        lastCodexResetsAtByAccount.removeAll()
        for accountId in Set(codexApiServices.keys).union(codexSessionExpiredNotifiedAccounts) {
            cancelCodexResetVerification(accountId: accountId)
        }
        codexSessionExpiredNotifiedAccounts.removeAll()
    }

    private func monitoringUtilization(for codex: CodexUsageData) -> Double? {
        [
            codex.primary?.percentage,
            codex.secondary?.percentage,
            codex.extraUsage?.percentage
        ]
        .compactMap { $0 }
        .max()
    }

    private func monitoringUtilization(for antigravity: AntigravityUsageData) -> Double? {
        [
            antigravity.primary?.percentage,
            antigravity.secondary?.percentage
        ]
        .compactMap { $0 }
        .max()
    }

    func startRefreshing() {
        beginRefreshActivity()
        fetchUsage()
        restartTimer()
        startCodexTokenRefreshTimer()

        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.objectWillChange.send()
        }
        #endif
    }

    func stopRefreshing() {
        timerManager.invalidate(TimerID.mainRefresh)
        timerManager.invalidate(TimerID.codexTokenRefresh)
        endRefreshActivity()
    }

    func startPopoverRefreshTimer(updateHandler: @escaping () -> Void) {
        timerManager.schedule(TimerID.popoverRefresh, interval: 1.0, repeats: true) {
            updateHandler()
        }
    }

    func stopPopoverRefreshTimer() {
        timerManager.invalidate(TimerID.popoverRefresh)
    }

    private func restartTimer() {
        timerManager.invalidate(TimerID.mainRefresh)
        timerManager.schedule(TimerID.mainRefresh, interval: TimeInterval(settings.effectiveRefreshInterval), repeats: true) { [weak self] in
            self?.fetchUsage()
        }
    }

    private func startCodexTokenRefreshTimer() {
        timerManager.schedule(TimerID.codexTokenRefresh, interval: 10 * 60, repeats: true) { [weak self] in
            // 逐账号主动续期
            guard let self, self.settings.isProviderEnabled(.codex) else { return }
            for account in self.fetchableCodexAccounts { self.codexApiServices[account.id]?.proactivelyRefreshIfNeeded() }
        }
    }

    private func beginRefreshActivity() {
        guard refreshActivity == nil else { return }
        refreshActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic Codex usage data refresh"
        )
    }

    private func endRefreshActivity() {
        if let activity = refreshActivity {
            ProcessInfo.processInfo.endActivity(activity)
            refreshActivity = nil
        }
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.menuBar.debug("系统从睡眠唤醒，刷新用量")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.fetchUsage()
            }
        }
    }

    func refreshOnPopoverOpen() {
        let now = Date()

        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            if wasIdle {
                restartTimer()
            }
        }

        if let lastFetch = lastAPIFetchTime,
           now.timeIntervalSince(lastFetch) < 30 {
            return
        }

        fetchUsage()
    }

    func handleManualRefresh() {
        let now = Date()
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 {
            return
        }

        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            if wasIdle {
                restartTimer()
            }
        }

        lastManualRefreshTime = now
        refreshAnimationStartTime = now
        // 多账号/多平台一起刷时全部图标同转（refreshingProvider = nil）；单一目标时只转该平台
        let fetchCount = fetchableCodexAccounts.count
            + (shouldFetchCursorUsage ? 1 : 0)
            + (shouldFetchAntigravityUsage ? 1 : 0)
        if fetchCount >= 2 {
            refreshState.refreshingProvider = nil
        } else if shouldFetchAntigravityUsage {
            refreshState.refreshingProvider = .antigravity
        } else if shouldFetchCursorUsage {
            refreshState.refreshingProvider = .cursor
        } else {
            refreshState.refreshingProvider = .codex
        }
        refreshState.isRefreshing = true
        refreshState.canRefresh = false
        resetCodexReloginState()
        resetCursorReloginState()
        resetAntigravityReloginState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }

        fetchUsage()
    }

    private func processCodexSuccess(_ data: CodexUsageData, account: Account) {
        let previousData = codexAccountUsages.first { $0.accountId == account.id }?.usage
        upsertCodexUsage(
            CodexAccountUsage(
                accountId: account.id,
                displayName: account.displayName,
                usage: data,
                needsRelogin: false,
                errorMessage: nil
            ),
            account: account
        )
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsReloginState {
            errorMessage = nil
        }


        if settings.notificationsEnabled {
            NotificationManager.shared.checkAndNotify(codexUsageData: data, previousData: previousData, account: account)
        }

        let newCodexResetsAt = data.primary?.resetsAt
        if hasResetTimeChanged(from: lastCodexResetsAtByAccount[account.id], to: newCodexResetsAt) {
            cancelCodexResetVerification(accountId: account.id)
        } else if let resetsAt = newCodexResetsAt {
            scheduleCodexResetVerification(resetsAt: resetsAt, accountId: account.id)
        }
        lastCodexResetsAtByAccount[account.id] = newCodexResetsAt

        pushBluetoothSync()
    }

    private func attemptTokenRefreshAndRetry(_ account: Account) {
        let alreadyMarked = codexAccountUsages.first { $0.accountId == account.id }?.needsRelogin ?? false
        guard !alreadyMarked else {
            markCodexNeedsRelogin(account)
            return
        }

        if CodexAPIService.isOAuthRefreshToken(settings.codexAccountToken(account.id)) {
            markCodexNeedsRelogin(account)
            return
        }

        Logger.menuBar.info("Codex accessToken 已过期，启动刷新链(\(account.displayName, privacy: .public))")
        attemptLevel1SSRRefresh(account)
    }

    private func attemptLevel1SSRRefresh(_ account: Account) {
        guard settings.isProviderEnabled(.codex), settings.isCodexAccountEnabled(account.id) else { return }
        let generation = fetchGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.fetchGeneration else { return }
            CodexTokenRefreshCoordinator.shared.refresh(accountId: account.id) { [weak self] result in
                guard let self, generation == self.fetchGeneration else { return }
                switch result {
                case .success(let freshAccessToken):
                    self.retryCodexWithAccessToken(freshAccessToken, account: account)
                case .failure:
                    self.attemptLevel2WebViewRefresh(account)
                }
            }
        }
    }

    private func attemptLevel2WebViewRefresh(_ account: Account) {
        guard settings.isProviderEnabled(.codex), settings.isCodexAccountEnabled(account.id) else { return }
        let generation = fetchGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.fetchGeneration else { return }
            CodexSilentRefreshCoordinator.shared.refresh(accountId: account.id) { [weak self] result in
                guard let self, generation == self.fetchGeneration else { return }
                switch result {
                case .success:
                    self.fetchCodexUsage(account)
                case .failure:
                    self.markCodexNeedsRelogin(account)
                }
            }
        }
    }

    private func retryCodexWithAccessToken(_ accessToken: String, account: Account) {
        guard settings.isProviderEnabled(.codex), settings.isCodexAccountEnabled(account.id) else { return }
        let generation = fetchGeneration
        codexApiService(for: account.id).fetchUsageWithAccessToken(accessToken) { [weak self] usageResult in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration else { return }
                switch usageResult {
                case .success(let data):
                    self.processCodexSuccess(data, account: account)
                case .failure:
                    self.attemptLevel2WebViewRefresh(account)
                }
            }
        }
    }

    private func resetCodexReloginState() {
        codexAccountUsages = codexAccountUsages.map { entry in
            var entry = entry
            entry.needsRelogin = false
            return entry
        }
        codexSessionExpiredNotifiedAccounts.removeAll()
    }

    /// 单账号过期：只标记该账号，其他账号照常刷新
    private func markCodexNeedsRelogin(_ account: Account) {
        var entry = codexAccountUsages.first { $0.accountId == account.id }
            ?? CodexAccountUsage(accountId: account.id, displayName: account.displayName)
        entry.needsRelogin = true
        entry.usage = nil
        upsertCodexUsage(entry, account: account)
        if !codexSessionExpiredNotifiedAccounts.contains(account.id) {
            codexSessionExpiredNotifiedAccounts.insert(account.id)
            if settings.notificationsEnabled {
                NotificationManager.shared.sendCodexSessionExpiredNotification(accountLabel: account.displayName)
            }
        }
        if !codexHasAnyUsage && cursorUsageData == nil && antigravityUsageData == nil {
            errorMessage = UsageError.sessionExpired.localizedDescription
        }
        cancelCodexResetVerification(accountId: account.id)
        lastCodexResetsAtByAccount.removeValue(forKey: account.id)
    }

    func handleAccountChanged(provider: ProviderType?) {
        if let provider, provider == .kimi || provider == .glm { planQuotaStates.removeValue(forKey: provider) }
        if provider == nil || provider == .codex {
            resetCodexReloginState()
            for service in codexApiServices.values {
                service.clearAccessTokenCache()
            }
            pruneCodexApiServices()
            reconcileCodexUsageState()
        }
        if provider == nil || provider == .cursor {
            resetCursorReloginState()
            reconcileCursorUsageState()
        }
        if provider == nil || provider == .antigravity {
            resetAntigravityReloginState()
            AntigravityAPIService.invalidateCredentialsCache()
            clearAntigravityUsageState()
        }
        // Also start timers when the first configured provider was added from the welcome screen.
        startRefreshing()
    }

    private func endRefreshAnimationWithMinimumDuration(completion: @escaping () -> Void) {
        guard let startTime = refreshAnimationStartTime else {
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = minimumAnimationDuration - elapsed

        if remaining > 0 {
            let generation = fetchGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, generation == self.fetchGeneration else { return }
                self.refreshState.isRefreshing = false
                self.refreshState.refreshingProvider = nil
                completion()
            }
        } else {
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
        }

        refreshAnimationStartTime = nil
    }

    private func hasResetTimeChanged(from oldTime: Date?, to newTime: Date?) -> Bool {
        if oldTime == nil && newTime == nil { return false }
        if (oldTime == nil) != (newTime == nil) { return true }
        if let oldTime, let newTime {
            return abs(oldTime.timeIntervalSince(newTime)) > 1.0
        }
        return false
    }

    private func cancelCodexResetVerification(accountId: UUID) {
        for timerId in TimerID.codexResetVerify(accountId) {
            timerManager.invalidate(timerId)
        }
    }

    private func scheduleCodexResetVerification(resetsAt: Date, accountId: UUID) {
        cancelCodexResetVerification(accountId: accountId)
        let timeUntilReset = resetsAt.timeIntervalSinceNow
        guard timeUntilReset > 0 else { return }

        let timerIds = TimerID.codexResetVerify(accountId)
        for (index, timerId) in timerIds.enumerated() {
            let offsets: [TimeInterval] = [1, 10, 30]
            timerManager.schedule(timerId, interval: timeUntilReset + offsets[index], repeats: false) { [weak self] in
                // 重置验证只刷新该账号
                guard let self else { return }
                if let account = self.fetchableCodexAccounts.first(where: { $0.id == accountId }) {
                    self.fetchCodexUsage(account)
                }
            }
        }
    }

    func cleanup() {
        planServices.values.forEach { $0.close() }
        timerManager.invalidateAll()
        endRefreshActivity()
        cursorApiServices.values.forEach { $0.cancelAllRequests() }
        antigravityApiService.cancelAllRequests()
        for service in codexApiServices.values {
            service.cancelAllRequests()
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    deinit {
        cleanup()
    }
}
