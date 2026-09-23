//
//  MenuBarUI.swift
//  Agent Ring
//

import SwiftUI
import AppKit
import Combine

final class MenuBarUI {
    private(set) var statusItem: NSStatusItem!
    private(set) var popover: NSPopover!
    private var popoverCloseObserver: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var iconCache: [String: NSImage] = [:]
    private let maxCacheSize = 50
    private let settings = UserSettings.shared
    private let iconRenderer = MenuBarIconRenderer()

    init() {
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = createSimpleCircleIcon()
    }

    func configureClickHandler(target: AnyObject?, action: Selector) {
        guard let button = statusItem.button else { return }
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = target
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 290, height: 240)
        popover.behavior = .semitransient
    }

    func setPopoverContent<Content: View>(_ contentView: Content) {
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    func setPopoverContentSize(_ size: NSSize) {
        popover.contentSize = size
    }

    func openPopover(relativeTo button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)

        // 毛玻璃仍应遵循应用的外观设置。
        switch settings.appearance {
        case .system:
            popover.appearance = nil
        case .light:
            popover.appearance = NSAppearance(named: .aqua)
        case .dark:
            popover.appearance = NSAppearance(named: .darkAqua)
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindow()
        setupPopoverCloseObserver()
        setupAppResignActiveObserver()
    }

    private func configurePopoverWindow() {
        guard let popoverWindow = popover.contentViewController?.view.window else { return }
        popoverWindow.level = .popUpMenu
        popoverWindow.makeKey()

        adjustPopoverWindowPosition(popoverWindow)
        DispatchQueue.main.async { [weak self, weak popoverWindow] in
            guard let self, let popoverWindow else { return }
            self.adjustPopoverWindowPosition(popoverWindow)
            // Start without highlighting an arbitrary control; Tab can still enter the key-view loop.
            popoverWindow.makeFirstResponder(nil)
        }

        #if DEBUG
        if settings.debugKeepDetailWindowOpen {
            popoverWindow.backgroundColor = .white
            popoverWindow.isOpaque = true
            popover.contentViewController?.view.layer?.backgroundColor = NSColor.white.cgColor
            return
        }
        #endif

        // Release / 正常路径：透明窗口，露出 NSPopover 系统毛玻璃
        popoverWindow.backgroundColor = .clear
        popoverWindow.isOpaque = false
        popover.contentViewController?.view.wantsLayer = true
        popover.contentViewController?.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func adjustPopoverWindowPosition(_ popoverWindow: NSWindow) {
        let edgeMargin: CGFloat = 14
        let screen = popoverWindow.screen ?? statusItem.button?.window?.screen ?? NSScreen.main
        guard let screen else { return }
        var frame = popoverWindow.frame
        let maxAllowedX = screen.visibleFrame.maxX - frame.width - edgeMargin
        frame.origin.x = max(screen.visibleFrame.minX + edgeMargin, min(frame.origin.x, maxAllowedX))
        frame.origin.y = max(screen.visibleFrame.minY + edgeMargin, frame.origin.y)
        popoverWindow.setFrame(frame, display: true)
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        removePopoverCloseObserver()
        removeAppResignActiveObserver()
    }

    private func setupPopoverCloseObserver() {
        removePopoverCloseObserver()
        popoverCloseObserver = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            #if DEBUG
            if UserSettings.shared.debugKeepDetailWindowOpen { return }
            #endif
            self.closePopover()
        }
    }

    private func removePopoverCloseObserver() {
        if let popoverCloseObserver {
            NSEvent.removeMonitor(popoverCloseObserver)
            self.popoverCloseObserver = nil
        }
    }

    private func setupAppResignActiveObserver() {
        removeAppResignActiveObserver()
        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            #if DEBUG
            if UserSettings.shared.debugKeepDetailWindowOpen { return }
            #endif
            self.closePopover()
        }
    }

    private func removeAppResignActiveObserver() {
        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
    }

    func createStandardMenu(hasUpdate: Bool, shouldShowBadge: Bool, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()

        // Codex 多账号同显，无需切换子菜单；账号启停与排序在认证设置页



        if settings.cursorAccounts.count > 1 {
            menu.addItem(.separator())
        }

        let generalItem = NSMenuItem(title: L.Menu.generalSettings, action: #selector(MenuBarManager.openGeneralSettings), keyEquivalent: ",")
        generalItem.target = target
        setMenuItemIcon(generalItem, systemName: "gearshape")
        menu.addItem(generalItem)

        let authItem = NSMenuItem(title: L.Menu.authSettings, action: #selector(MenuBarManager.openAuthSettings), keyEquivalent: "a")
        authItem.target = target
        authItem.keyEquivalentModifierMask = [.command, .shift]
        setMenuItemIcon(authItem, systemName: "key.horizontal")
        menu.addItem(authItem)

        let bluetoothItem = NSMenuItem(title: L.SettingsTab.bluetooth, action: #selector(MenuBarManager.openBluetoothSettings), keyEquivalent: "b")
        bluetoothItem.target = target
        bluetoothItem.keyEquivalentModifierMask = [.command, .shift]
        setMenuItemIcon(bluetoothItem, systemName: "antenna.radiowaves.left.and.right")
        menu.addItem(bluetoothItem)

        let updateItem = NSMenuItem(title: L.Menu.checkUpdates, action: #selector(MenuBarManager.checkForUpdates), keyEquivalent: "u")
        updateItem.target = target
        if hasUpdate && shouldShowBadge {
            updateItem.image = createBadgeIcon()
        } else {
            setMenuItemIcon(updateItem, systemName: "arrow.triangle.2.circlepath")
        }
        menu.addItem(updateItem)

        let aboutItem = NSMenuItem(title: L.Menu.about, action: #selector(MenuBarManager.openAbout), keyEquivalent: "")
        aboutItem.target = target
        setMenuItemIcon(aboutItem, systemName: "info.circle")
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L.Menu.quit, action: #selector(MenuBarManager.quitApp), keyEquivalent: "q")
        quitItem.target = target
        setMenuItemIcon(quitItem, systemName: "power")
        menu.addItem(quitItem)

        return menu
    }

    private func setMenuItemIcon(_ item: NSMenuItem, systemName: String) {
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else { return }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        item.image = image
    }

    private func createAccountSubmenu(accounts: [Account], currentId: UUID?, selector: Selector, target: AnyObject?) -> NSMenu {
        let submenu = NSMenu()
        for account in accounts {
            let item = NSMenuItem(title: account.displayName, action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = account
            if account.id == currentId {
                item.state = .on
            }
            submenu.addItem(item)
        }
        return submenu
    }

    private func createBadgeIcon() -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .draw(in: NSRect(x: 0, y: 2, width: 12, height: 12))
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func updateMenuBarIcon(
        codexAccountUsages: [CodexAccountUsage],
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData? = nil,
        cursorAccountUsages: [CursorAccountUsage] = [],
        planQuotaStates: [ProviderType: PlanQuotaState] = [:],
        hasUpdate: Bool = false,
        shouldShowBadge: Bool = false
    ) {
        guard let button = statusItem.button else { return }
        // 悬停清单：多账号簇无标识，tooltip 说明各簇归属
        button.toolTip = buildTooltip(
            codexAccountUsages: codexAccountUsages,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
        if !cursorAccountUsages.isEmpty {
            var names = codexAccountUsages.map { "Codex · " + $0.displayName }
            names += cursorAccountUsages.map { entry in
                var text = "Cursor · " + entry.displayName
                if let error = entry.errorMessage {
                    text += " — " + L.provider("refresh.failed") + ": " + error
                    if let updated = entry.lastUpdatedAt { text += " (" + L.provider("refresh.cached") + " " + updated.formatted() + ")" }
                } else if entry.usage == nil { text += " — " + L.Usage.loading }
                return text
            }
            if antigravityUsageData != nil { names.append("Antigravity") }
            button.toolTip = names.joined(separator: "\n")
        }
        let planTips = settings.providerOrder.compactMap { provider -> String? in
            guard settings.isProviderEnabled(provider), let state = planQuotaStates[provider] else { return nil }
            if let quota = state.quota {
                return provider.displayName + ": " + quota.windows.map { $0.title + " " + UsageRingDisplay.percentLabel(usedPercentage: $0.usedPercentage, showRemainingMode: settings.showRemainingMode) }.joined(separator: ", ")
            }
            return provider.displayName + ": " + (state.error ?? L.Usage.loading)
        }
        if !planTips.isEmpty { button.toolTip = ([button.toolTip ?? ""] + planTips).joined(separator: "\n") }
        let cacheKey = generateCacheKey(
            codexAccountUsages: codexAccountUsages,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        ) + String(reflecting: codexAccountUsages) + String(reflecting: cursorAccountUsages) + String(reflecting: planQuotaStates)

        if let cachedImage = iconCache[cacheKey] {
            button.image = cachedImage
            return
        }

        let icon = iconRenderer.createIcon(
            codexAccountUsages: codexAccountUsages,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData,
            cursorAccountUsages: cursorAccountUsages,
            planQuotaStates: planQuotaStates,
            button: button
        )
        if iconCache.count >= maxCacheSize {
            iconCache.removeValue(forKey: iconCache.keys.first!)
        }
        iconCache[cacheKey] = icon
        button.image = icon
    }

    private func percentText(usedPercentage: Double) -> String {
        UsageRingDisplay.percentLabel(
            usedPercentage: usedPercentage,
            showRemainingMode: settings.showRemainingMode
        )
    }

    private func buildTooltip(
        codexAccountUsages: [CodexAccountUsage],
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?
    ) -> String {
        var lines: [String] = []
        for entry in codexAccountUsages {
            guard let usage = entry.usage else {
                lines.append(entry.displayName + " — " + (entry.needsRelogin ? L.Error.sessionExpired : entry.errorMessage ?? L.Usage.loading))
                continue
            }
            let pct = [
                usage.primary?.percentage,
                usage.secondary?.percentage,
                usage.extraUsage?.percentage
            ].compactMap { $0 }.max()
            if let pct {
                lines.append("\(entry.displayName)  \(percentText(usedPercentage: pct))")
            } else {
                lines.append(entry.displayName)
            }
        }
        if let cursorUsageData {
            let pct = [
                cursorUsageData.included?.percentage,
                cursorUsageData.apiModels?.percentage,
                cursorUsageData.onDemand?.percentage
            ].compactMap { $0 }.max()
            lines.append(pct.map { "Cursor  \(percentText(usedPercentage: $0))" } ?? "Cursor")
        }
        if let antigravityUsageData {
            let pct = [
                antigravityUsageData.geminiPrimary?.percentage ?? antigravityUsageData.primary?.percentage,
                antigravityUsageData.geminiSecondary?.percentage ?? antigravityUsageData.secondary?.percentage,
                antigravityUsageData.thirdPartyPrimary?.percentage,
                antigravityUsageData.thirdPartySecondary?.percentage
            ].compactMap { $0 }.max()
            lines.append(pct.map { "Antigravity  \(percentText(usedPercentage: $0))" } ?? "Antigravity")
        }
        return lines.joined(separator: "\n")
    }

    func clearIconCache() {
        iconCache.removeAll()
    }

    private func generateCacheKey(
        codexAccountUsages: [CodexAccountUsage],
        cursorUsageData: CursorUsageData?,
        antigravityUsageData: AntigravityUsageData?
    ) -> String {
        var key = "\(settings.iconDisplayMode.rawValue)_\(settings.iconStyleMode.rawValue)_\(settings.displayMode.rawValue)_\(settings.showRemainingMode)"
        if codexAccountUsages.isEmpty {
            key += "_no_codex"
        }
        for entry in codexAccountUsages {
            let activeTypes = settings.getActiveCodexDisplayTypes(codexUsageData: entry.usage, forMenuBar: true)
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            key += "_cx\(entry.accountId.uuidString.prefix(8))_\(activeTypes)"
            if let primary = entry.usage?.primary { key += "_p\(Int(primary.percentage))" }
            if let secondary = entry.usage?.secondary { key += "_s\(Int(secondary.percentage))" }
            if let extra = entry.usage?.extraUsage?.percentage { key += "_e\(Int(extra))" }
        }
        if let cursorUsageData {
            let activeTypes = settings.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData, forMenuBar: true)
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            key += "_cu\(activeTypes)"
            if let included = cursorUsageData.included { key += "_i\(Int(included.percentage))" }
            if let apiModels = cursorUsageData.apiModels { key += "_a\(Int(apiModels.percentage))" }
            if let onDemand = cursorUsageData.onDemand { key += "_o\(Int(onDemand.percentage))" }
        } else {
            key += "_no_cursor"
        }
        if let antigravityUsageData {
            let activeTypes = (settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, forMenuBar: true, provider: .antigravity) + settings.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, forMenuBar: true, provider: .antigravityThird))
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            key += "_ag\(activeTypes)"
            if let primary = antigravityUsageData.geminiPrimary ?? antigravityUsageData.primary { key += "_p\(Int(primary.percentage))" }
            if let secondary = antigravityUsageData.geminiSecondary ?? antigravityUsageData.secondary { key += "_s\(Int(secondary.percentage))" }
            if let tpPrimary = antigravityUsageData.thirdPartyPrimary { key += "_tpp\(Int(tpPrimary.percentage))" }
            if let tpSecondary = antigravityUsageData.thirdPartySecondary { key += "_tps\(Int(tpSecondary.percentage))" }
        } else {
            key += "_no_antigravity"
        }
        return key
    }

    private func createSimpleCircleIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
        NSColor.labelColor.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func cleanup() {
        removePopoverCloseObserver()
        removeAppResignActiveObserver()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    deinit {
        cleanup()
    }
}
