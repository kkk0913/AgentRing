//
//  MenuBarManager.swift
//  Agent Ring
//

import SwiftUI
import AppKit
import Combine
import OSLog

final class RefreshState: ObservableObject {
    @Published var isRefreshing = false
    @Published var refreshingProvider: ProviderType?
    @Published var canRefresh = true
    @Published var notificationMessage: String?
    @Published var notificationType: NotificationType = .loading

    enum NotificationType {
        case loading
        case updateAvailable
    }

    func isRefreshingProvider(_ provider: ProviderType) -> Bool {
        if provider == .antigravityThird {
            return isRefreshing && (refreshingProvider == nil || refreshingProvider == .antigravity || refreshingProvider == .antigravityThird)
        }
        return isRefreshing && (refreshingProvider == nil || refreshingProvider == provider)
    }
}

final class MenuBarManager: ObservableObject {
    private let ui = MenuBarUI()
    private let dataManager = DataRefreshManager()
    private var settingsWindow: NSWindow?
    @ObservedObject private var settings = UserSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var windowCloseObserver: NSObjectProtocol?
    private var languageChangeObserver: NSObjectProtocol?

    /// 多账号用量（顺序 = 启用账号配置顺序）
    @Published var codexAccountUsages: [CodexAccountUsage] = []
    @Published var planQuotaStates: [ProviderType: PlanQuotaState] = [:]
    @Published var cursorAccountUsages: [CursorAccountUsage] = []
    @Published var cursorUsageData: CursorUsageData?
    @Published var antigravityUsageData: AntigravityUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var cursorNeedsRelogin = false
    @Published var antigravityNeedsRelogin = false
    @Published var hasAvailableUpdate = false
    @Published var latestVersion: String?
    private var acknowledgedVersion: String?

    var refreshState: RefreshState {
        dataManager.refreshState
    }

    /// 蓝牙副屏：读取当前各 provider 数据（开关开启时立即推送用）
    /// codex 只推勾选中的第一个账号（协议不变）
    var dataManagerForBluetooth: (bluetoothCodexData: CodexUsageData?, cursorData: CursorUsageData?, antigravityData: AntigravityUsageData?) {
        (dataManager.bluetoothCodexDataForSync, cursorUsageData, antigravityUsageData)
    }

    var shouldShowUpdateBadge: Bool {
        let releaseVersion = AppUpdateManager.shared.availableVersion ?? latestVersion
        guard hasAvailableUpdate || AppUpdateManager.shared.availableVersion != nil,
              let version = releaseVersion else { return false }
        return acknowledgedVersion != version
    }

    init() {
        ui.configureClickHandler(target: self, action: #selector(handleClick))
        setupDataBindings()
        setupSettingsObservers()
    }

    private func setupDataBindings() {
        dataManager.$planQuotaStates.sink { [weak self] states in
            self?.planQuotaStates = states
            self?.ui.clearIconCache()
            self?.updateMenuBarIcon()
            self?.updatePopoverContent()
        }.store(in: &cancellables)

        dataManager.$cursorAccountUsages.sink { [weak self] entries in
            self?.cursorAccountUsages = entries
            self?.ui.clearIconCache()
            self?.updateMenuBarIcon()
        }.store(in: &cancellables)


        dataManager.$codexAccountUsages
            .sink { [weak self] usages in
                self?.codexAccountUsages = usages
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$cursorUsageData
            .sink { [weak self] data in
                self?.cursorUsageData = data
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$antigravityUsageData
            .sink { [weak self] data in
                self?.antigravityUsageData = data
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        dataManager.$isLoading.assign(to: &$isLoading)
        dataManager.$errorMessage.assign(to: &$errorMessage)
        dataManager.$cursorNeedsRelogin.assign(to: &$cursorNeedsRelogin)
        dataManager.$antigravityNeedsRelogin.assign(to: &$antigravityNeedsRelogin)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = ui.createStandardMenu(hasUpdate: hasAvailableUpdate, shouldShowBadge: shouldShowUpdateBadge, target: self)
        ui.statusItem.menu = menu
        ui.statusItem.button?.performClick(nil)
        ui.statusItem.menu = nil
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    fileprivate func handleMenuAction(_ action: UsageDetailView.MenuAction) {
        switch action {
        case .refresh:
            dataManager.handleManualRefresh()
        case .generalSettings:
            closePopover()
            openSettingsWindow(tab: 0)
        case .authSettings:
            closePopover()
            openSettingsWindow(tab: 1)
        case .checkForUpdates:
            closePopover()
            checkForUpdates()
        case .about:
            closePopover()
            openSettingsWindow(tab: 3)
        case .codexRelogin:
            closePopover()
            WebLoginWindowManager.shared.showCodexLoginWindow()
        case .cursorRelogin:
            closePopover()
            WebLoginWindowManager.shared.showCursorLoginWindow()
        case .antigravityRelogin:
            closePopover()
            openAuthSettings()
        case .quit:
            quitApp()
        }
    }

    private func setupSettingsObservers() {
        NotificationCenter.default.publisher(for: .settingsChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.ui.clearIconCache()
                self.updateMenuBarIcon()

                #if DEBUG
                self.dataManager.fetchUsage()
                if self.settings.simulateUpdateAvailable {
                    self.hasAvailableUpdate = true
                    self.latestVersion = "2.0.0"
                } else {
                    self.hasAvailableUpdate = false
                    self.latestVersion = nil
                }
                self.updateMenuBarIcon()
                #endif
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .refreshIntervalChanged)
            .sink { [weak self] _ in
                self?.dataManager.stopRefreshing()
                self?.dataManager.startRefreshing()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openSettings)
            .sink { [weak self] notification in
                let tab = notification.userInfo?["tab"] as? Int ?? 0
                self?.openSettingsWindow(tab: tab)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .accountChanged)
            .sink { [weak self] notification in
                guard let self else { return }
                let providerRaw = notification.userInfo?[Notification.UserInfoKey.provider] as? String
                let provider = providerRaw.flatMap { ProviderType(rawValue: $0) }
                self.ui.clearIconCache()
                self.dataManager.handleAccountChanged(provider: provider)
                self.updateMenuBarIcon()
            }
            .store(in: &cancellables)
    }

    @objc func togglePopover() {
        guard let button = ui.statusItem.button else { return }
        ui.popover.isShown ? closePopover() : openPopover(relativeTo: button)
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        // Activating the app for the popover must not also bring an existing settings window forward.
        // Keep its contents alive, but show it again only through an explicit settings action.
        settingsWindow?.orderOut(nil)
        dataManager.refreshOnPopoverOpen()
        ui.setPopoverContentSize(usageDetailContentSize())

        ui.setPopoverContent(UsageDetailHost(manager: self))

        ui.openPopover(relativeTo: button)
        startPopoverRefreshTimer()
    }

    var popoverAvailableSize: NSSize {
        let frame = (ui.statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame
        return NSSize(width: max(320, (frame?.width ?? 1440) - 40), height: max(240, (frame?.height ?? 900) - 40))
    }

    private func usageDetailContentSize() -> NSSize {
        let activeProviders = settings.orderedActiveProviders(
            hasCodexData: !codexAccountUsages.isEmpty,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
        let unitCount = PopoverLayout.unitCount(
            providers: activeProviders,
            codexAccountCount: codexAccountUsages.count,
            cursorAccountCount: cursorAccountUsages.count
        )
        let wrapRows = PopoverLayout.wrapRows(unitCount: max(unitCount, 1), availableWidth: popoverAvailableSize.width)
        let maxRowColumns = wrapRows.max() ?? 1

        let limitRowCount = PopoverLayout.limitRowCount(
            codexUsages: codexAccountUsages.map { $0.usage },
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData,
            cursorUsages: cursorAccountUsages.compactMap { $0.usage },
            planQuotas: planQuotaStates.values.compactMap { $0.quota }
        )
        let rowCount = max(limitRowCount, unitCount > 0 ? 1 : 0)
        let layout = PopoverLayout.pageLayout(
            wrapRowCount: wrapRows.count,
            limitRowCount: rowCount,
            showsMultiple: unitCount > 1,
            availableHeight: popoverAvailableSize.height
        )
        return NSSize(width: PopoverLayout.windowWidth(maxRowColumns: maxRowColumns), height: layout.height)
    }

    private func closePopover() {
        ui.closePopover()
        dataManager.stopPopoverRefreshTimer()
    }

    private func updatePopoverContent() {
        if ui.popover.isShown { ui.setPopoverContentSize(usageDetailContentSize()) }
        objectWillChange.send()
    }

    private func startPopoverRefreshTimer() {
        dataManager.startPopoverRefreshTimer { [weak self] in
            self?.updatePopoverContent()
        }
    }

    func startRefreshing() {
        dataManager.startRefreshing()
    }

    @objc func openSettings() { openSettingsWindow(tab: 0) }
    @objc func openGeneralSettings() { openSettingsWindow(tab: 0) }
    @objc func openAuthSettings() { openSettingsWindow(tab: 1) }
    @objc func openBluetoothSettings() { openSettingsWindow(tab: 2) }
    @objc func openAbout() { openSettingsWindow(tab: 3) }

    @objc func checkForUpdates() {
        let versionToAcknowledge = AppUpdateManager.shared.availableVersion ?? latestVersion
        if let versionToAcknowledge {
            acknowledgedVersion = versionToAcknowledge
            objectWillChange.send()
            updateMenuBarIcon()
        }

        AppUpdateManager.shared.checkForUpdates(isUserInitiated: true)
    }

    func applyUpdateAvailable(version: String?) {
        hasAvailableUpdate = true
        latestVersion = version
        updateMenuBarIcon()
    }

    func applyUpdateNotFound() {
        hasAvailableUpdate = false
        latestVersion = nil
        updateMenuBarIcon()
    }

    private func openSettingsWindow(tab: Int) {
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.regular)
            let hostingController = NSHostingController(rootView: SettingsView(initialTab: tab))
            hostingController.sizingOptions = []

            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = L.Window.settingsTitle
            settingsWindow?.collectionBehavior = [.fullScreenNone]
            settingsWindow?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow?.minSize = NSSize(width: 700, height: 560)
            settingsWindow?.maxSize = NSSize(width: 1200, height: 1200)
            settingsWindow?.setContentSize(NSSize(width: 760, height: 640))
            settingsWindow?.center()
            settingsWindow?.setFrameAutosaveName("AgentRing.SettingsWindow.v5")

            if let windowCloseObserver {
                NotificationCenter.default.removeObserver(windowCloseObserver)
            }

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: settingsWindow,
                queue: .main
            ) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.settingsWindow = nil
                if self?.settings.hasAnyValidCredentials == true && self?.codexAccountUsages.isEmpty != false && self?.cursorUsageData == nil {
                    self?.startRefreshing()
                }
            }

            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: settingsWindow,
                queue: .main
            ) { [weak self] _ in
                #if DEBUG
                if UserSettings.shared.debugKeepDetailWindowOpen { return }
                #endif
                if self?.ui.popover.isShown == true {
                    self?.closePopover()
                }
            }

            if let languageChangeObserver {
                NotificationCenter.default.removeObserver(languageChangeObserver)
            }
            languageChangeObserver = NotificationCenter.default.addObserver(
                forName: .languageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsWindow?.title = L.Window.settingsTitle
            }
        }

        // Perform the transition in one event turn. A delayed makeKeyAndOrderFront could otherwise
        // run after a later status-item click and reopen settings on top of the popover.
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Clear only the initial focus, preserving keyboard navigation once the user presses Tab.
        settingsWindow?.makeFirstResponder(nil)
    }

    private func updateMenuBarIcon() {
        ui.updateMenuBarIcon(
            codexAccountUsages: codexAccountUsages,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData,
            cursorAccountUsages: cursorAccountUsages,
            planQuotaStates: planQuotaStates,
            hasUpdate: hasAvailableUpdate,
            shouldShowBadge: shouldShowUpdateBadge
        )
    }

    func cleanup() {
        dataManager.stopPopoverRefreshTimer()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
            self.languageChangeObserver = nil
        }
        cancellables.removeAll()
        ui.cleanup()
        dataManager.cleanup()
        settingsWindow?.close()
        settingsWindow = nil
    }

    deinit {
        cleanup()
    }
}

/// Hosts the popover so SwiftUI actually observes MenuBarManager publishes.
/// Manual `Binding(get: { self.x })` does not subscribe, so rings stayed at the first paint.
private struct UsageDetailHost: View {
    @ObservedObject var manager: MenuBarManager

    var body: some View {
        UsageDetailView(
            codexAccountUsages: $manager.codexAccountUsages,
            cursorUsageData: $manager.cursorUsageData,
            antigravityUsageData: $manager.antigravityUsageData,
            errorMessage: $manager.errorMessage,
            cursorNeedsRelogin: Binding(get: { manager.cursorNeedsRelogin }, set: { _ in }),
            antigravityNeedsRelogin: Binding(get: { manager.antigravityNeedsRelogin }, set: { _ in }),
            refreshState: manager.refreshState,
            cursorAccountUsages: manager.cursorAccountUsages,
            planQuotaStates: manager.planQuotaStates,
            availableSize: manager.popoverAvailableSize,
            onMenuAction: { action in manager.handleMenuAction(action) },
            hasAvailableUpdate: $manager.hasAvailableUpdate,
            shouldShowUpdateBadge: Binding(get: { manager.shouldShowUpdateBadge }, set: { _ in })
        )
    }
}
