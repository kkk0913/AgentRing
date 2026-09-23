import Foundation

func check(_ condition: @autoclosure () -> Bool, _ title: String) {
    guard condition() else { fatalError("FAIL: " + title) }
    print("PASS: " + title)
}
func decode(_ json: String, _ provider: ProviderType) throws -> PlanQuota {
    try PlanQuotaParser.parse(Data(json.utf8), provider: provider)
}
func rejects(_ json: String, _ provider: ProviderType, _ title: String) {
    do { _ = try decode(json, provider); fatalError("FAIL: " + title) }
    catch { print("PASS: " + title) }
}
let kimi = try decode(#"{"usages":{"limit5h":{"usedRatio":0.12,"resetAt":"2026-09-23T19:00:00+08:00"},"limit7d":{"usedRatio":0.85},"monthCode":{"usedRatio":0}}}"#, .kimi)
check(kimi.windows.map(\.usedPercentage) == [12,85,0], "Kimi ratios become percentages and preserve zero")
check(kimi.windows[0].resetsAt != nil && kimi.windows[1].resetsAt == nil, "Kimi missing reset time stays unknown")
check(kimi.windows.map(\.id) == ["limit5h","limit7d","monthCode"], "Kimi only displays present windows in stable order")
rejects(#"{"error":{"message":"expired"}}"#, .kimi, "Kimi error payload is not quota")
rejects(#"{"code":40101,"data":{"usages":{}}}"#, .kimi, "Kimi envelope failure is rejected")
rejects(#"{"usages":{}}"#, .kimi, "missing Kimi windows are not zero quota")
rejects(#"{"usages":{"limit5h":{"usedRatio":true}}}"#, .kimi, "boolean ratios are not numbers")
let legacy = try decode(#"{"usage":{"limit":"1000","used":"200","resetTime":"2026-09-25T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"100"}}]}"#, .kimi)
check(legacy.windows.map(\.usedPercentage) == [50,20], "legacy counts yield 5h and weekly percentages")
check(legacy.windows.map(\.id) == ["limit5h","limit7d"], "legacy count windows have stable IDs")
let mixed = try decode(#"{"usage":{"limit":100,"used":80},"usages":{"limit7d":{"usedRatio":0.15},"monthTotal":{"usedRatio":1},"limit5h":{"usedRatio":0}}}"#, .kimi)
check(mixed.windows.first?.id == "monthTotal" && mixed.windows.first?.usedPercentage == 100, "exhausted monthly pool stays visible")
check(mixed.windows.first(where: {$0.id == "limit7d"})?.usedPercentage == 15, "ratio windows take precedence over legacy counts")
rejects(#"{"usage":{"limit":0,"used":0}}"#, .kimi, "zero count limit does not invent an empty quota")
rejects(#"{"usages":{"limit5h":{"usedRatio":"NaN"}}}"#, .kimi, "non-finite ratios are rejected")
let oldConfiguration = try JSONDecoder().decode(PlanQuotaConfiguration.self, from: Data(#"{"secret":"fake-local","region":"cn","port":58627}"#.utf8))
check(oldConfiguration.credentialKind == "legacyLocal", "old configuration is explicitly classified as local")
do { _ = try PlanQuotaService.request(provider: .kimi, configuration: oldConfiguration); fatalError("old local token leaked") }
catch { print("PASS: old local token cannot be sent to the cloud") }
let newConfiguration = PlanQuotaConfiguration(secret: "fake-key")
let restored = try JSONDecoder().decode(PlanQuotaConfiguration.self, from: JSONEncoder().encode(newConfiguration))
check(restored == newConfiguration && restored.credentialKind == "apiKey", "new API-key configuration survives persistence")
_ = try PlanQuotaService.request(provider: .glm, configuration: oldConfiguration)
print("PASS: existing GLM configuration remains compatible")
let glm = try decode(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":23},{"type":"TIME_LIMIT","percentage":"70","nextResetTime":1790208000000}]}}"#, .glm)
check(glm.windows.map(\.usedPercentage) == [23,70], "GLM percentages are not multiplied by 100")
check(glm.windows[0].resetsAt == nil && glm.windows[1].resetsAt != nil, "GLM reset time is optional and accepts milliseconds")
rejects(#"{"code":401,"success":false,"data":{"limits":[]}}"#, .glm, "GLM business failure is rejected")
rejects(#"{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT"}]}}"#, .glm, "GLM missing percentage is not shown as 0")
let cn = try PlanQuotaService.request(provider: .glm, configuration: .init(secret: "fake-key"))
let global = try PlanQuotaService.request(provider: .glm, configuration: .init(secret: "fake-key", region: "global"))
let local = try PlanQuotaService.request(provider: .kimi, configuration: .init(secret: "fake-key"))
let kimiGlobal = try PlanQuotaService.request(provider: .kimi, configuration: .init(secret: "fake-global", region: "global"))
check(cn.url?.host == "open.bigmodel.cn" && global.url?.host == "api.z.ai", "GLM regions only use official hosts")
check(cn.value(forHTTPHeaderField: "Authorization") == "fake-key", "GLM uses official raw-key Authorization")
check(local.url?.absoluteString == "https://api.kimi.com/coding/v1/usages" && kimiGlobal.url?.host == "api.kimi.ai", "Kimi only connects to selected official HTTPS host")
check(local.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key", "Kimi uses API-key bearer authentication")
check(local.httpMethod == "GET" && cn.httpMethod == "GET", "quota integration only uses read requests")
do { _ = try PlanQuotaService.request(provider: .glm, configuration: .init(secret: "fake", region: "https://other.example")); fatalError("unexpected host allowed") }
catch { print("PASS: custom credential destinations are rejected") }
do { _ = try PlanQuotaService.request(provider: .kimi, configuration: .init(secret: "fake", region: "other")); fatalError("bad region allowed") }
catch { print("PASS: invalid Kimi region is rejected") }
final class QuotaProtocol: URLProtocol {
    static var status = 200
    static var payload = #"{"code":0,"data":{"kind":"error","message":"unavailable"}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QuotaProtocol.self]
let service = PlanQuotaService(configuration: config)
func fetchFailure(_ status: Int, _ title: String) {
    QuotaProtocol.status = status
    var result: Result<PlanQuota, Error>?
    service.fetch(provider: .kimi, configuration: .init(secret: "fake")) { result = $0 }
    let end = Date().addingTimeInterval(5)
    while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    if case .failure? = result { print("PASS: " + title) } else { fatalError("FAIL: " + title) }
}
fetchFailure(200, "service surfaces in-band failures")
fetchFailure(401, "service surfaces expired credentials")
fetchFailure(429, "service surfaces rate limiting")
var redirected = true
service.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: local), willPerformHTTPRedirection: HTTPURLResponse(url: local.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: cn) { redirected = $0 != nil }
check(!redirected, "service refuses credential redirects")
service.close()
