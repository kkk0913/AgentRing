import Foundation
import OSLog
struct Account { let id: UUID; let displayName: String }
struct CursorUsageData { let value: Double }
struct AntigravityUsageData {}
struct CodexUsageData { let value: Double }
enum UsageError: Error { case unauthorized, noCredentials }
class CursorAPIService {
    var callbacks: [(Result<CursorUsageData, Error>) -> Void] = []
    init(accountId: UUID) {}
    func fetchUsage(completion: @escaping (Result<CursorUsageData, Error>) -> Void) { callbacks.append(completion) }
}
class AntigravityAPIService {
    var callbacks: [(Result<AntigravityUsageData, Error>) -> Void] = []
    func fetchUsage(completion: @escaping (Result<AntigravityUsageData, Error>) -> Void) { callbacks.append(completion) }
}
enum ProviderType: Hashable { case kimi, glm }
struct PlanQuotaConfiguration {}
struct PlanQuota {}
struct PlanQuotaState { var quota: PlanQuota? = nil; var error: String? = nil }
enum L { static func provider(_ key: String) -> String { key } }
class PlanQuotaService {
    var callbacks: [(Result<PlanQuota, Error>) -> Void] = []
    func fetch(provider: ProviderType, configuration: PlanQuotaConfiguration, completion: @escaping (Result<PlanQuota, Error>) -> Void) { callbacks.append(completion) }
}
class Settings {
    var notificationsEnabled = true
    var planConfigurations: [ProviderType: PlanQuotaConfiguration] = [:]
    var enabled: Set<ProviderType> = [.kimi, .glm]
    func isProviderEnabled(_ provider: ProviderType) -> Bool { enabled.contains(provider) }
}
class NotificationManager {
    static let shared = NotificationManager()
    var expired: [UUID] = []
    func checkAndNotify(cursorUsageData: CursorUsageData, previousData: CursorUsageData?, account: Account) {}
    func sendCursorSessionExpiredNotification(accountId: UUID, accountLabel: String) { expired.append(accountId) }
}
extension Logger { static let menuBar = Logger(subsystem: "AgentRing.Tests", category: "Refresh") }
class RefreshHarness {
    var fetchableCodexAccounts: [Account] = []
    var codexAccountUsages: [CodexAccountUsage] = []
    var planQuotaStates: [ProviderType: PlanQuotaState] = [:]
    var planServices: [ProviderType: PlanQuotaService] = [:]
    var onMonitoring: (() -> Void)?
    var fetchGeneration = 1
    var pendingFetches = 0
    var cursorApiServices: [UUID: CursorAPIService] = [:]
    var antigravityApiService = AntigravityAPIService()
    var cursorAccountUsages: [CursorAccountUsage] = []
    var cursorSessionExpiredNotifiedAccounts: Set<UUID> = []
    var cursorUsageData: CursorUsageData?
    var antigravityUsageData: AntigravityUsageData?
    var cursorNeedsRelogin = false
    var codexHasAnyUsage = false
    var errorMessage: String?
    var isLoading = true
    let settings = Settings()
    var smartUpdates = 0
    var animationEnds = 0
    var antigravitySuccesses = 0
    func publishSmartMonitoringUtilizations() { smartUpdates += 1; onMonitoring?() }
    func pushBluetoothSync() {}
    func processAntigravitySuccess(_ data: AntigravityUsageData) { antigravitySuccesses += 1; antigravityUsageData = data }
    func markAntigravityNeedsRelogin() {}
    func clearAntigravityUsageState() { antigravityUsageData = nil }
    func endRefreshAnimationWithMinimumDuration(completion: () -> Void) { animationEnds += 1; completion() }
    // PRODUCTION_METHODS
}
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: " + name) }
    print("PASS: " + name)
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
var snapshot = AccountMonitoringSnapshot()
check(snapshot.record(["A": 90, "B": 10]), "first snapshot establishes active monitoring")
check(snapshot.record(["A": 90, "B": 11]), "lower-use account activity is detected")
check(!snapshot.record(["B": 11, "A": 90]), "reordering does not count as activity")
check(snapshot.record(["A": 90, "B": 0]), "account quota reset counts as a change")
let h = RefreshHarness()
let a = Account(id: UUID(), displayName: "A"), b = Account(id: UUID(), displayName: "B")
h.cursorAccountUsages = [CursorAccountUsage(accountId: a.id, displayName: a.displayName), CursorAccountUsage(accountId: b.id, displayName: b.displayName)]
h.pendingFetches = 3
h.fetchCursorUsage(a); h.fetchCursorUsage(b); h.fetchAntigravityUsage()
let oldCursor = h.cursorApiServices[a.id]!.callbacks[0]
let oldAnti = h.antigravityApiService.callbacks[0]
h.fetchGeneration += 1
h.pendingFetches = 3
h.fetchCursorUsage(a); h.fetchCursorUsage(b); h.fetchAntigravityUsage()
oldCursor(.failure(UsageError.unauthorized)); oldAnti(.failure(URLError(.cancelled))); drain()
check(h.pendingFetches == 3 && h.isLoading && h.smartUpdates == 0, "old cancelled callbacks cannot complete the new batch")
check(NotificationManager.shared.expired.isEmpty, "old unauthorized response cannot send a stale alert")
oldAnti(.success(AntigravityUsageData())); drain()
check(h.antigravitySuccesses == 0, "old Antigravity success cannot overwrite state")
h.cursorApiServices[a.id]!.callbacks[1](.failure(UsageError.unauthorized)); drain()
check(h.smartUpdates == 0 && h.pendingFetches == 2, "partial batch does not update smart monitoring")
h.cursorApiServices[b.id]!.callbacks[1](.success(CursorUsageData(value: 11))); drain()
check(h.cursorAccountUsages[1].usage?.value == 11 && h.cursorAccountUsages[0].needsRelogin, "one account failure does not affect another")
h.antigravityApiService.callbacks[1](.success(AntigravityUsageData())); drain()
check(h.smartUpdates == 1 && h.animationEnds == 1 && !h.isLoading, "complete batch updates monitoring and animation once")
h.noteFetchFinished(generation: h.fetchGeneration)
check(h.smartUpdates == 1, "completed batch cannot finish twice")
func respond(_ account: Account, _ result: Result<CursorUsageData, Error>) {
    h.fetchGeneration += 1; h.pendingFetches = 1
    h.fetchCursorUsage(account)
    h.cursorApiServices[account.id]!.callbacks.last!(result)
    drain()
}
respond(a, .failure(UsageError.unauthorized))
check(NotificationManager.shared.expired == [a.id], "repeated authorization failure is deduplicated")
respond(b, .failure(UsageError.unauthorized))
check(NotificationManager.shared.expired == [a.id, b.id], "different accounts each receive an alert")
respond(a, .success(CursorUsageData(value: 20)))
respond(a, .failure(UsageError.unauthorized))
check(NotificationManager.shared.expired == [a.id, b.id, a.id], "successful recovery allows a new expiry alert")

let p = RefreshHarness()
p.pendingFetches = 1
p.fetchPlanQuota(.glm)
check(p.pendingFetches == 0 && p.planQuotaStates[.glm]?.error != nil && p.planServices.isEmpty, "unconfigured platform finishes with an error without a request")
p.settings.planConfigurations[.glm] = PlanQuotaConfiguration()
p.fetchGeneration += 1; p.pendingFetches = 1
p.fetchPlanQuota(.glm)
let old = p.planServices[.glm]!.callbacks[0]
p.fetchGeneration += 1; p.pendingFetches = 1
p.settings.enabled.remove(.glm)
old(.success(PlanQuota()))
check(p.planQuotaStates[.glm]?.quota == nil && p.pendingFetches == 1, "disabled platform cannot be restored by an old response")
p.settings.enabled.insert(.glm)
p.fetchPlanQuota(.glm)
p.planServices[.glm]!.callbacks.last!(.success(PlanQuota()))
check(p.planQuotaStates[.glm]?.quota != nil && p.pendingFetches == 0, "enabled platform publishes quota and completes its batch")
p.fetchGeneration += 1; p.pendingFetches = 1
p.fetchPlanQuota(.glm)
p.planServices[.glm]!.callbacks.last!(.failure(UsageError.unauthorized))
check(p.planQuotaStates[.glm]?.quota == nil && p.planQuotaStates[.glm]?.error != nil, "quota error clears stale success data")
p.onMonitoring = { p.fetchGeneration += 1; p.pendingFetches = 2; p.isLoading = true }
p.fetchGeneration += 1; p.pendingFetches = 1
p.noteFetchFinished(generation: p.fetchGeneration)
check(p.isLoading && p.pendingFetches == 2, "monitoring-triggered new batch keeps its loading state")

// Exercise production reconciliation before any response, with B completing first.
let c = RefreshHarness()
c.fetchableCodexAccounts = [a, b]
c.reconcileCodexUsageState()
check(c.codexAccountUsages.map(\.accountId) == [a.id, b.id], "startup reserves all Codex account positions")
c.upsertCodexUsage(CodexAccountUsage(accountId: b.id, displayName: b.displayName, usage: CodexUsageData(value: 42)), account: b)
check(c.codexAccountUsages.first?.accountId == a.id && c.codexAccountUsages.first?.usage == nil, "fast second account cannot replace first account")
c.upsertCodexUsage(CodexAccountUsage(accountId: a.id, displayName: a.displayName, needsRelogin: true, errorMessage: "expired"), account: a)
c.reconcileCodexUsageState()
check(c.codexAccountUsages.first?.needsRelogin == true && c.codexAccountUsages.first?.errorMessage == "expired", "periodic reconciliation preserves failed account state")
c.fetchableCodexAccounts = [b]
c.reconcileCodexUsageState()
check(c.codexAccountUsages.map(\.accountId) == [b.id], "disabled account is removed without moving surviving data to a different identity")
respond(a, .success(CursorUsageData(value: 23)))
let lastSuccess = h.cursorAccountUsages[0].lastUpdatedAt
check(lastSuccess != nil, "Cursor success records update time")
respond(a, .failure(URLError(.timedOut)))
check(h.cursorAccountUsages[0].usage?.value == 23 && h.cursorAccountUsages[0].errorMessage != nil && h.cursorAccountUsages[0].lastUpdatedAt == lastSuccess, "Cursor failure retains dated cache and explicit error")
respond(a, .success(CursorUsageData(value: 24)))
check(h.cursorAccountUsages[0].usage?.value == 24 && h.cursorAccountUsages[0].errorMessage == nil && h.cursorAccountUsages[0].lastUpdatedAt! > lastSuccess!, "Cursor recovery clears warning and advances update time")
