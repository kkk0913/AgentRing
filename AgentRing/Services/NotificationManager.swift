//
//  NotificationManager.swift
//  Agent Ring
//

import Foundation
import UserNotifications
import OSLog

final class NotificationManager {
    static let shared = NotificationManager()

    private let warningThreshold: Double = 90
    private let secondaryEarlyWarningThreshold: Double = 75
    private let resetDropThreshold: Double = 30
    private var notifiedWarnings: [String: Bool] = [:]

    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Logger.menuBar.error("请求通知权限失败: \(error.localizedDescription)")
            }
            Logger.menuBar.info("通知权限: \(granted ? "已授权" : "未授权")")
        }
    }

    func checkAndNotify(codexUsageData: CodexUsageData, previousData: CodexUsageData?, account: Account) {
        checkLimit(
            type: .codexPrimary,
            current: codexUsageData.primary?.percentage,
            previous: previousData?.primary?.percentage,
            currentResetsAt: codexUsageData.primary?.resetsAt,
            previousResetsAt: previousData?.primary?.resetsAt,
            accountId: account.id,
            accountLabel: account.displayName
        )
        checkLimit(
            type: .codexSecondary,
            current: codexUsageData.secondary?.percentage,
            previous: previousData?.secondary?.percentage,
            currentResetsAt: codexUsageData.secondary?.resetsAt,
            previousResetsAt: previousData?.secondary?.resetsAt,
            accountId: account.id,
            accountLabel: account.displayName
        )
        checkLimit(
            type: .codexExtraUsage,
            current: codexUsageData.extraUsage?.percentage,
            previous: previousData?.extraUsage?.percentage,
            currentResetsAt: nil,
            previousResetsAt: nil,
            accountId: account.id,
            accountLabel: account.displayName
        )
    }

    func checkAndNotify(cursorUsageData: CursorUsageData, previousData: CursorUsageData?) {
        checkLimit(
            type: .cursorIncluded,
            current: cursorUsageData.included?.percentage,
            previous: previousData?.included?.percentage,
            currentResetsAt: cursorUsageData.included?.resetsAt,
            previousResetsAt: previousData?.included?.resetsAt,
            accountId: UserSettings.shared.currentCursorAccountId
        )
        checkLimit(
            type: .cursorOnDemand,
            current: cursorUsageData.apiModels?.percentage ?? cursorUsageData.onDemand?.percentage,
            previous: previousData?.apiModels?.percentage ?? previousData?.onDemand?.percentage,
            currentResetsAt: cursorUsageData.apiModels?.resetsAt ?? cursorUsageData.onDemand?.resetsAt,
            previousResetsAt: previousData?.apiModels?.resetsAt ?? previousData?.onDemand?.resetsAt,
            accountId: UserSettings.shared.currentCursorAccountId
        )
    }

    private func checkLimit(
        type: LimitType,
        current: Double?,
        previous: Double?,
        currentResetsAt: Date?,
        previousResetsAt: Date?,
        accountId: UUID?,
        accountLabel: String? = nil
    ) {
        guard let currentPct = current else { return }

        if let previousPct = previous,
           isReset(currentPct: currentPct, previousPct: previousPct, currentResetsAt: currentResetsAt, previousResetsAt: previousResetsAt) {
            sendResetNotification(limitType: type, accountLabel: accountLabel)
            notifiedWarnings.removeValue(forKey: notificationKey(for: type, accountId: accountId))
            notifiedWarnings.removeValue(forKey: notificationKey(for: type, accountId: accountId, suffix: "75"))
            return
        }

        let previousPct = previous ?? 0

        if type == .codexSecondary {
            let earlyKey = notificationKey(for: type, accountId: accountId, suffix: "75")
            let alreadyNotifiedEarly = notifiedWarnings[earlyKey] ?? false
            if !alreadyNotifiedEarly && previousPct < secondaryEarlyWarningThreshold && currentPct >= secondaryEarlyWarningThreshold {
                sendUsageWarning(limitType: type, percentage: currentPct, accountLabel: accountLabel)
                notifiedWarnings[earlyKey] = true
            }
        }

        let warningKey = notificationKey(for: type, accountId: accountId)
        let alreadyNotified = notifiedWarnings[warningKey] ?? false
        if !alreadyNotified && previousPct < warningThreshold && currentPct >= warningThreshold {
            sendUsageWarning(limitType: type, percentage: currentPct, accountLabel: accountLabel)
            notifiedWarnings[warningKey] = true
        }
    }

    /// 通知正文的账号前缀（多账号同显时区分归属）
    private static func accountPrefix(_ accountLabel: String?) -> String {
        accountLabel.map { "\($0) · " } ?? ""
    }

    private func notificationKey(for type: LimitType, accountId: UUID?, suffix: String? = nil) -> String {
        Self.makeNotificationKey(
            provider: type.provider,
            accountId: accountId,
            limitType: type,
            suffix: suffix
        )
    }

    static func makeNotificationKey(
        provider: ProviderType,
        accountId: UUID?,
        limitType: LimitType,
        suffix: String? = nil
    ) -> String {
        var key = "\(provider.rawValue):\(accountId?.uuidString ?? "none"):\(limitType.rawValue)"
        if let suffix {
            key += ":\(suffix)"
        }
        return key
    }

    static func makeAccountNotificationKeyPrefix(provider: ProviderType, accountId: UUID?) -> String {
        "\(provider.rawValue):\(accountId?.uuidString ?? "none"):"
    }

    private func isReset(
        currentPct: Double,
        previousPct: Double,
        currentResetsAt: Date?,
        previousResetsAt: Date?
    ) -> Bool {
        if previousPct >= warningThreshold && (previousPct - currentPct) > resetDropThreshold {
            return true
        }

        if let currentResetsAt, let previousResetsAt,
           abs(currentResetsAt.timeIntervalSince(previousResetsAt)) > 1,
           currentPct < previousPct {
            return true
        }

        return false
    }

    private func sendUsageWarning(limitType: LimitType, percentage: Double, accountLabel: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = L.UsageNotification.warningTitle
        content.body = Self.accountPrefix(accountLabel) + L.UsageNotification.warningBody(limitType.displayName, Int(percentage))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage_warning_\(limitType.rawValue)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func sendResetNotification(limitType: LimitType, accountLabel: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = L.UsageNotification.resetTitle
        content.body = Self.accountPrefix(accountLabel) + L.UsageNotification.resetBody(limitType.displayName)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage_reset_\(limitType.rawValue)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendCursorSessionExpiredNotification() {
        let content = UNMutableNotificationContent()
        content.title = L.UsageNotification.cursorSessionExpiredTitle
        content.body = L.UsageNotification.cursorSessionExpiredBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "cursor_session_expired",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendCodexSessionExpiredNotification(accountLabel: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = L.UsageNotification.codexSessionExpiredTitle
        content.body = Self.accountPrefix(accountLabel) + L.UsageNotification.codexSessionExpiredBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex_session_expired_\(accountLabel ?? "all")",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func resetAllNotificationStates() {
        notifiedWarnings.removeAll()
    }

    func resetNotificationStates(for provider: ProviderType, accountId: UUID?) {
        let prefix = Self.makeAccountNotificationKeyPrefix(provider: provider, accountId: accountId)
        notifiedWarnings = notifiedWarnings.filter { key, _ in !key.hasPrefix(prefix) }
    }
}
