import Foundation

/// Read-only quota requests. Credentials can only go to a selected official HTTPS host.
final class PlanQuotaService: NSObject, URLSessionTaskDelegate {
    private var task: URLSessionDataTask?
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func request(provider: ProviderType, configuration: PlanQuotaConfiguration) throws -> URLRequest {
        let secret = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, !secret.contains("\r"), !secret.contains("\n") else { throw PlanQuotaError.credentials }
        let url: URL
        switch provider {
        case .glm:
            guard ["cn", "global"].contains(configuration.region) else { throw PlanQuotaError.configuration }
            let host = configuration.region == "cn" ? "open.bigmodel.cn" : "api.z.ai"
            url = URL(string: "https://\(host)/api/monitor/usage/quota/limit")!
        case .kimi:
            guard configuration.credentialKind == "apiKey" else { throw PlanQuotaError.migration }
            guard ["cn", "global"].contains(configuration.region) else { throw PlanQuotaError.configuration }
            let host = configuration.region == "cn" ? "api.kimi.com" : "api.kimi.ai"
            url = URL(string: "https://\(host)/coding/v1/usages")!
        default: throw PlanQuotaError.configuration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(provider == .kimi ? "Bearer \(secret)" : secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentRing/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"), forHTTPHeaderField: "User-Agent")
        return request
    }

    func fetch(provider: ProviderType, configuration: PlanQuotaConfiguration, completion: @escaping (Result<PlanQuota, Error>) -> Void) {
        cancel()
        do {
            let request = try Self.request(provider: provider, configuration: configuration)
            task = session.dataTask(with: request) { data, response, error in
                let result: Result<PlanQuota, Error>
                do {
                    if let error { throw error }
                    guard let response = response as? HTTPURLResponse else { throw PlanQuotaError.response }
                    if [401, 403].contains(response.statusCode) { throw PlanQuotaError.credentials }
                    guard response.statusCode == 200 else { throw PlanQuotaError.http(response.statusCode) }
                    guard let data else { throw PlanQuotaError.response }
                    result = .success(try PlanQuotaParser.parse(data, provider: provider))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { completion(result) }
            }
            task?.resume()
        } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }
    func cancel() { task?.cancel(); task = nil }
    func close() { cancel(); session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
