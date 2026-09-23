//
//  CursorWebLoginCoordinator.swift
//  Agent Ring
//

import Combine
import Foundation
import WebKit
import AppKit
import os

final class CursorWebLoginCoordinator: ObservableObject {
    enum LoginState: Equatable {
        case loading
        case waitingForLogin
        case validating
        case success(accountName: String)
        case failed(message: String)
    }

    @Published var loginState: LoginState = .loading
    @Published var loadProgress: Double = 0

    private(set) var webView: WKWebView!
    private var cookieTimer: Timer?
    private var progressObservation: NSKeyValueObservation?
    private var onAccountCreated: ((Account) -> Void)?
    private var navigationDelegate: NavigationDelegate?
    private var uiDelegate: UIDelegate?
    private let apiService = CursorAPIService()

    private let allowedDomains: Set<String> = [
        "cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
        "workos.com",
        "google.com",
        "accounts.google.com",
        "github.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "challenges.cloudflare.com"
    ]

    private let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    init() {
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true

        let delegate = NavigationDelegate(coordinator: self)
        webView.navigationDelegate = delegate
        navigationDelegate = delegate

        let ui = UIDelegate(coordinator: self)
        webView.uiDelegate = ui
        uiDelegate = ui

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.loadProgress = webView.estimatedProgress
            }
        }

        self.webView = webView
    }

    func loadLoginPage() {
        guard let url = URL(string: "https://authenticator.cursor.sh/") else { return }
        loginState = .loading
        webView.load(URLRequest(url: url))
    }

    func setOnAccountCreated(_ callback: @escaping (Account) -> Void) {
        onAccountCreated = callback
    }

    func cleanup() {
        cookieTimer?.invalidate()
        cookieTimer = nil
        progressObservation = nil
    }

    fileprivate func startCookieMonitoring() {
        cookieTimer?.invalidate()
        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForSessionToken()
        }
    }

    private func checkForSessionToken() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard let token = Self.extractSessionToken(from: cookies) else { return }

            DispatchQueue.main.async {
                self.cookieTimer?.invalidate()
                self.cookieTimer = nil
                self.validateSessionToken(token)
            }
        }
    }

    static func extractSessionToken(from cookies: [HTTPCookie]) -> String? {
        cookies.first { cookie in
            cookie.name == "WorkosCursorSessionToken"
                && (cookie.domain.contains("cursor.com") || cookie.domain.contains("cursor.sh"))
                && !cookie.value.isEmpty
        }?.value
    }

    private func validateSessionToken(_ sessionToken: String) {
        loginState = .validating
        apiService.validateSessionToken(sessionToken) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let info):
                    let account = Account(
                        credentialToken: sessionToken,
                        accountIdentifier: info.identifier,
                        accountName: info.displayName,
                        alias: nil,
                        provider: .cursor
                    )
                    let stored = UserSettings.shared.addCursorAccount(account)
                    UserSettings.shared.setCursorAccountEnabled(stored, enabled: true)
                    self.loginState = .success(accountName: stored.displayName)
                    self.onAccountCreated?(stored)
                case .failure(let error):
                    self.loginState = .failed(message: error.localizedDescription)
                    self.startCookieMonitoring()
                }
            }
        }
    }
}

extension CursorWebLoginCoordinator {
    final class NavigationDelegate: NSObject, WKNavigationDelegate {
        private weak var coordinator: CursorWebLoginCoordinator?

        init(coordinator: CursorWebLoginCoordinator) {
            self.coordinator = coordinator
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let coordinator, coordinator.loginState != .validating else { return }
            coordinator.loginState = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let coordinator else { return }
            if case .validating = coordinator.loginState { return }
            if case .success = coordinator.loginState { return }
            coordinator.loginState = .waitingForLogin

            let host = webView.url?.host?.lowercased() ?? ""
            if host.contains("cursor.com") || host.contains("cursor.sh") {
                coordinator.startCookieMonitoring()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            coordinator?.loginState = .failed(message: error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let coordinator = coordinator,
                  let url = navigationAction.request.url,
                  let host = url.host?.lowercased() else {
                decisionHandler(.allow)
                return
            }

            let isAllowed = coordinator.allowedDomains.contains { domain in
                host == domain || host.hasSuffix(".\(domain)")
            }
            if isAllowed {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }

    final class UIDelegate: NSObject, WKUIDelegate {
        private weak var coordinator: CursorWebLoginCoordinator?

        init(coordinator: CursorWebLoginCoordinator) {
            self.coordinator = coordinator
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }
    }
}
