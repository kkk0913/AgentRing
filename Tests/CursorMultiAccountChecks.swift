final class MockCursorProtocol: URLProtocol {
    static let lock = NSLock()
    static var cookies: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        Self.lock.lock(); Self.cookies.append(cookie); Self.lock.unlock()
        let status = cookie.contains("fake-B") ? 401 : 200
        let payload = Data(#"{"individualUsage":{"plan":{"autoPercentUsed":12,"apiPercentUsed":3}}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}
func waitFor(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(predicate(), "requests complete")
}
let a = UUID(), b = UUID()
UserSettings.shared.cursorAccounts = [.init(id: a, credentialToken: "fake-A"), .init(id: b, credentialToken: "fake-B")]
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [MockCursorProtocol.self]
let serviceA = CursorAPIService(accountId: a, configuration: configuration)
let serviceB = CursorAPIService(accountId: b, configuration: configuration)
var dataA: CursorUsageData?
var errorB: Error?
var completed = 0
serviceA.fetchUsage { result in
    if case .success(let data) = result { dataA = data }
    completed += 1
}
serviceB.fetchUsage { result in
    if case .failure(let error) = result { errorB = error }
    completed += 1
}
waitFor { completed == 2 }
check(dataA?.included?.percentage == 12, "account A succeeds while B is unauthorized")
if case UsageError.unauthorized? = errorB { print("PASS: account B retains its own authentication failure") }
else { fatalError("wrong error for B") }
check(Set(MockCursorProtocol.cookies) == ["WorkosCursorSessionToken=fake-A", "WorkosCursorSessionToken=fake-B"], "requests use their own account cookies")
UserSettings.shared.cursorAccounts[0].credentialToken = "fake-A-renewed"
serviceA.fetchUsage { _ in completed += 1 }
waitFor { completed == 3 }
check(MockCursorProtocol.cookies.last == "WorkosCursorSessionToken=fake-A-renewed", "re-login updates the correct service credential")
UserSettings.shared.cursorAccounts.removeAll { $0.id == a }
var missing = false
serviceA.fetchUsage { result in
    if case .failure(UsageError.noCredentials) = result { missing = true }
}
check(missing, "deleted account cannot fall back to another account")
check(MockCursorProtocol.cookies.count == 3, "deleted account makes no network request")
