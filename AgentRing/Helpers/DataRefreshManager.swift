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
    private let cursorApiService = CursorAPIService()
    private let antigravityApiService = AntigravityAPIService()
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
    private var cursorSessionExpiredNotified = false
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

    private var shouldFetchCursorUsage: Bool {
        #if DEBUG
        return settings.debugModeEnabled || settings.hasValidCursorCredentials
        #else
        return settings.hasValidCursorCredentials
        #endif
    }

    private var shouldFetchAntigravityUsage: Bool {
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
        let codexAccountsToFetch = fetchableCodexAccounts
        let fetchCursor = shouldFetchCursorUsage
        let fetchAntigravity = shouldFetchAntigravityUsage

        guard !codexAccountsToFetch.isEmpty || fetchCursor || fetchAntigravity else {
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
        pendingFetches = codexAccountsToFetch.count + (fetchCursor ? 1 : 0) + (fetchAntigravity ? 1 : 0)

        for account in codexAccountsToFetch {
            fetchCodexUsage(account)
        }
        if fetchCursor {
            fetchCursorUsage()
        }
        if fetchAntigravity {
            fetchAntigravityUsage()
        }
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

    private func fetchCodexUsage(_ account: Account) {
        codexApiService(for: account.id).fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
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
                self.noteFetchFinished()
            }
        }
    }

    private func fetchCursorUsage() {
        cursorApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.processCursorSuccess(data)
                case .failure(let error):
                    if case UsageError.unauthorized = error {
                        self.markCursorNeedsRelogin()
                    } else {
                        Logger.menuBar.info("Cursor 请求失败: \(error.localizedDescription)")
                        if self.cursorUsageData == nil && !self.codexHasAnyUsage && self.antigravityUsageData == nil {
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
                self.noteFetchFinished()
            }
        }
    }

    private func fetchAntigravityUsage() {
        antigravityApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
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
                self.noteFetchFinished()
            }
        }
    }

    private func noteFetchFinished() {
        pendingFetches = max(0, pendingFetches - 1)
        if pendingFetches == 0 {
            isLoading = false
            endRefreshAnimationWithMinimumDuration { }
        }
    }

    private func processCursorSuccess(_ data: CursorUsageData) {
        let previous = cursorUsageData
        cursorUsageData = data
        cursorNeedsRelogin = false
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsReloginState {
            errorMessage = nil
        }

        publishSmartMonitoringUtilizations()

        if settings.notificationsEnabled {
            NotificationManager.shared.checkAndNotify(cursorUsageData: data, previousData: previous)
        }

        lastCursorResetsAt = data.included?.resetsAt

        pushBluetoothSync()
    }

    private func processAntigravitySuccess(_ data: AntigravityUsageData) {
        antigravityUsageData = data
        antigravityNeedsRelogin = false
        if errorMessage == UsageError.sessionExpired.localizedDescription && !codexNeedsReloginState {
            errorMessage = nil
        }

        publishSmartMonitoringUtilizations()
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
        var utilizations: [ProviderType: Double] = [:]
        // 多账号取最大用量（告急优先），节奏仍按平台一个键
        let codexValues = codexAccountUsages.compactMap { $0.usage }.compactMap { monitoringUtilization(for: $0) }
        if let value = codexValues.max() {
            utilizations[.codex] = value
        }
        if let value = cursorUsageData?.included?.percentage {
            utilizations[.cursor] = value
        }
        if let antigravity = antigravityUsageData,
           let value = monitoringUtilization(for: antigravity) {
            utilizations[.antigravity] = value
        }
        if !utilizations.isEmpty {
            settings.updateSmartMonitoringMode(providerUtilizations: utilizations)
        }
    }

    private func clearCursorUsageState() {
        cursorUsageData = nil
        lastCursorResetsAt = nil
    }

    private func clearAntigravityUsageState() {
        antigravityUsageData = nil
        lastAntigravityResetsAt = nil
    }

    private func resetCursorReloginState() {
        cursorNeedsRelogin = false
        cursorSessionExpiredNotified = false
    }

    private func resetAntigravityReloginState() {
        antigravityNeedsRelogin = false
        antigravitySessionExpiredNotified = false
    }

    private func markCursorNeedsRelogin() {
        cursorNeedsRelogin = true
        if !cursorSessionExpiredNotified {
            cursorSessionExpiredNotified = true
            if settings.notificationsEnabled {
                NotificationManager.shared.sendCursorSessionExpiredNotification()
            }
        }
        if !codexHasAnyUsage && antigravityUsageData == nil {
            errorMessage = UsageError.sessionExpired.localizedDescription
        }
        clearCursorUsageState()
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
            self?.codexApiServices.values.forEach { $0.proactivelyRefreshIfNeeded() }
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

        publishSmartMonitoringUtilizations()

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
        Task { @MainActor [weak self] in
            guard let self else { return }
            CodexTokenRefreshCoordinator.shared.refresh(accountId: account.id) { [weak self] result in
                guard let self else { return }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            CodexSilentRefreshCoordinator.shared.refresh(accountId: account.id) { [weak self] result in
                guard let self else { return }
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
        isLoading = true
        codexApiService(for: account.id).fetchUsageWithAccessToken(accessToken) { [weak self] usageResult in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
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
        if provider == nil || provider == .codex {
            resetCodexReloginState()
            for service in codexApiServices.values {
                service.clearAccessTokenCache()
            }
            pruneCodexApiServices()
            clearCodexUsageState()
        }
        if provider == nil || provider == .cursor {
            resetCursorReloginState()
            clearCursorUsageState()
        }
        if provider == nil || provider == .antigravity {
            resetAntigravityReloginState()
            AntigravityAPIService.invalidateCredentialsCache()
            clearAntigravityUsageState()
        }
        NotificationManager.shared.resetAllNotificationStates()
        if shouldFetchCodexUsage || shouldFetchCursorUsage || shouldFetchAntigravityUsage {
            fetchUsage()
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.refreshState.isRefreshing = false
                self?.refreshState.refreshingProvider = nil
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
        timerManager.invalidateAll()
        endRefreshActivity()
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
