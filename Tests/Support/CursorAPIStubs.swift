import Foundation
import OSLog
// Test-only dependencies: the real service/model run without reading user credentials.
enum ProviderType { case cursor }
protocol UsageProvider { var providerType: ProviderType { get } }
enum UsageError: Error {
    case noCredentials, invalidURL, networkError, unauthorized, decodingError, rateLimited
    case httpError(statusCode: Int)
}
struct TestAccount { let id: UUID; var credentialToken: String }
final class UserSettings {
    static let shared = UserSettings()
    var cursorAccounts: [TestAccount] = []
    var cursorSessionToken = "must-not-be-used-for-a-specific-account"
}
extension Logger { static let api = Logger(subsystem: "AgentRing.Tests", category: "Cursor") }
