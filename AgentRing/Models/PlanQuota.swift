import Foundation
import CoreFoundation

struct PlanQuotaConfiguration: Codable, Equatable {
    var secret: String
    var region: String = "cn"
    var credentialKind: String = "apiKey"

    init(secret: String, region: String = "cn", credentialKind: String = "apiKey") {
        self.secret = secret; self.region = region; self.credentialKind = credentialKind
    }
    private enum CodingKeys: String, CodingKey { case secret, region, credentialKind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        secret = try values.decode(String.self, forKey: .secret)
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? "cn"
        // Old Kimi configurations contain a local server token, never a cloud API key.
        credentialKind = try values.decodeIfPresent(String.self, forKey: .credentialKind) ?? "legacyLocal"
    }
}

struct PlanQuotaWindow: Identifiable {
    let id: String
    let title: String
    let usedPercentage: Double
    let resetsAt: Date?
}

struct PlanQuota {
    let windows: [PlanQuotaWindow]
    let fetchedAt: Date
}

struct PlanQuotaState {
    var quota: PlanQuota?
    var error: String?
}

enum PlanQuotaError: LocalizedError {
    case credentials, configuration, response, empty, service, migration, http(Int)
    var errorDescription: String? {
        switch self {
        case .migration: return L.provider("kimi.migration")
        case .credentials: return L.provider("error.credentials")
        case .configuration: return L.provider("error.configuration")
        case .response: return L.provider("error.response")
        case .empty: return L.provider("error.empty")
        case .service: return L.provider("error.service")
        case .http(let code): return L.provider("error.http") + " (\(code))"
        }
    }
}

/// Parsers reject missing/error payloads rather than presenting them as 0% usage.
enum PlanQuotaParser {
    static func parse(_ data: Data, provider: ProviderType) throws -> PlanQuota {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlanQuotaError.response }
        if let code = root["code"], String(describing: code) != "0", !(provider == .glm && String(describing: code) == "200") {
            throw PlanQuotaError.service
        }
        if let success = root["success"] as? Bool, !success { throw PlanQuotaError.service }
        let body = root["data"] as? [String: Any] ?? root
        var windows: [PlanQuotaWindow] = []
        if provider == .kimi {
            windows = try kimiWindows(body)
        } else if provider == .glm {
            guard let limits = body["limits"] as? [[String: Any]] else { throw PlanQuotaError.response }
            for (index, item) in limits.enumerated() {
                guard let type = item["type"] as? String else { continue }
                guard let pct = number(item["percentage"]), pct >= 0 else { continue }
                let title: String
                switch type {
                case "TOKENS_LIMIT": title = L.provider("quota.tokens")
                case "TIME_LIMIT": title = L.provider("quota.mcp")
                default: title = type
                }
                // Window length/reset time are not guaranteed by the quota endpoint.
                windows.append(.init(id: "\(type)-\(index)", title: title, usedPercentage: min(100, pct), resetsAt: date(item["nextResetTime"])))
            }
        } else { throw PlanQuotaError.configuration }
        guard !windows.isEmpty else { throw PlanQuotaError.empty }
        return PlanQuota(windows: windows, fetchedAt: Date())
    }

    private static func kimiWindows(_ body: [String: Any]) throws -> [PlanQuotaWindow] {
        if body["error"] != nil || body["kind"] as? String == "error" { throw PlanQuotaError.service }
        var legacy: [String: PlanQuotaWindow] = [:]
        if let usage = body["usage"] as? [String: Any], let window = countWindow(usage, id: "limit7d", title: "7d") {
            legacy[window.id] = window
        }
        for item in body["limits"] as? [[String: Any]] ?? [] {
            guard let period = item["window"] as? [String: Any],
                  let duration = number(period["duration"]), duration > 0,
                  let unit = period["timeUnit"] as? String,
                  let detail = item["detail"] as? [String: Any] else { continue }
            let multiplier: Double
            switch unit {
            case "TIME_UNIT_SECOND": multiplier = 1
            case "TIME_UNIT_MINUTE": multiplier = 60
            case "TIME_UNIT_HOUR": multiplier = 3600
            case "TIME_UNIT_DAY": multiplier = 86400
            default: continue
            }
            let seconds = duration * multiplier
            guard seconds.isFinite else { continue }
            let title = seconds.truncatingRemainder(dividingBy: 86400) == 0 ? "\(seconds / 86400)d"
                : seconds.truncatingRemainder(dividingBy: 3600) == 0 ? "\(seconds / 3600)h" : "\(seconds / 60)m"
            let id = seconds == 18000 ? "limit5h" : seconds == 604800 ? "limit7d" : "window-\(seconds)"
            if let window = countWindow(detail, id: id, title: id == "limit5h" ? "5h" : id == "limit7d" ? "7d" : title) { legacy[id] = window }
        }
        var resolved = legacy
        let usages = body["usages"] as? [String: Any] ?? [:]
        for (key, title) in [("limit5h", "5h"), ("limit7d", "7d"), ("monthTotal", L.provider("quota.month")), ("monthCode", L.provider("quota.code_month"))] {
            guard let item = usages[key] as? [String: Any] else { continue }
            guard let ratio = number(item["usedRatio"]), ratio >= 0 else { throw PlanQuotaError.response }
            let reset = date(item["resetAt"])
            // Some transitional payloads carry empty ratios alongside populated counts.
            // Only borrow counts when the reset period matches and no monthly pool is present.
            if ratio == 0, usages["monthTotal"] == nil, let weekly = legacy["limit7d"], weekly.usedPercentage > 0,
               let old = legacy[key], old.usedPercentage > 0, let oldReset = old.resetsAt, let reset,
               abs(oldReset.timeIntervalSince(reset)) <= 2 { continue }
            resolved[key] = .init(id: key, title: title, usedPercentage: min(100, ratio * 100), resetsAt: reset)
        }
        var order = ["limit5h", "limit7d", "monthTotal", "monthCode"]
        // An exhausted monthly pool must remain visible in the menu bar's first ring.
        if (resolved["monthTotal"]?.usedPercentage ?? 0) >= 100 { order = ["monthTotal", "limit5h", "limit7d", "monthCode"] }
        return order.compactMap { resolved[$0] } + resolved.keys.filter { !order.contains($0) }.sorted().compactMap { resolved[$0] }
    }

    private static func countWindow(_ item: [String: Any], id: String, title: String) -> PlanQuotaWindow? {
        guard let limit = number(item["limit"]), limit > 0 else { return nil }
        let used = number(item["used"]) ?? number(item["remaining"]).map { limit - $0 }
        guard let used, used >= 0, (used / limit).isFinite else { return nil }
        return .init(id: id, title: title, usedPercentage: min(100, (used / limit) * 100), resetsAt: date(item["resetTime"]))
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { result = value.doubleValue }
        else if let value = value as? String { result = Double(value) }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        guard let stamp = number(value), stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp > 1e12 ? stamp / 1000 : stamp)
    }
}
