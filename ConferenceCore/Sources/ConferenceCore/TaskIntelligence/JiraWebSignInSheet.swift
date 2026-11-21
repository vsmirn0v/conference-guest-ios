import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

#if canImport(WebKit) && (os(iOS) || os(macOS))
public struct JiraWebSignInSheet: View {
    public let baseURL: URL
    public let onAuthenticated: @MainActor (_ mode: JiraAuthMode, _ secret: String, _ user: JiraUserContact) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var statusText: String = L("Sign in to Jira in the window below. Your session will be verified automatically.")
    @State private var currentURLString: String
    @State private var isChecking = false
    @State private var webViewNonce = UUID()

    public init(
        baseURL: URL,
        onAuthenticated: @escaping @MainActor (_ mode: JiraAuthMode, _ secret: String, _ user: JiraUserContact) -> Void
    ) {
        self.baseURL = baseURL
        self.onAuthenticated = onAuthenticated
        _currentURLString = State(initialValue: baseURL.appendingPathComponent("login.jsp").absoluteString)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if isChecking { ProgressView().controlSize(.small) }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(L("Verify Session")) {
                        Task { await verifyCurrentSession(from: currentWebView) }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))

                Divider()

                JiraWebViewContainer(
                    startURL: baseURL.appendingPathComponent("login.jsp"),
                    nonce: webViewNonce,
                    onWebViewReady: { currentWebView = $0 },
                    onNavigationFinished: { url, webView in
                        currentWebView = webView
                        currentURLString = url?.absoluteString ?? currentURLString
                        if url?.host?.lowercased() == baseURL.host?.lowercased(),
                           !(url?.path.lowercased().contains("login") ?? false) {
                            await verifyCurrentSession(from: webView)
                        }
                    }
                )
            }
            .navigationTitle(baseURL.host ?? "Jira")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #endif
    }

    @State private var currentWebView: WKWebView?

    @MainActor
    private func verifyCurrentSession(from webView: WKWebView?) async {
        guard !isChecking, let webView else { return }
        isChecking = true
        defer { isChecking = false }

        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { list in
                continuation.resume(returning: list)
            }
        }
        let targetHost = baseURL.host?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return targetHost == domain || targetHost.hasSuffix("." + domain)
        }
        guard !matching.isEmpty else {
            statusText = L("Complete login inside the web view first.")
            return
        }
        let cookieHeader = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let hostKey = targetHost
        let settings = JiraConnectionSettings(enabled: true, baseURL: baseURL.absoluteString, authMode: .webSession)
        let connector = JiraTaskConnector(
            settings: settings,
            secretProvider: { key, kind in
                (key == hostKey && kind == .jiraSessionCookies) ? cookieHeader : nil
            },
            session: URLSession(configuration: .ephemeral)
        )

        do {
            statusText = L("Verifying Jira session…")
            let user = try await connector.verifyMyself()
            // Try minting a durable 90-day PAT automatically on Jira Data Center/Server.
            if let pat = await tryCreatePersonalAccessToken(cookieHeader: cookieHeader) {
                onAuthenticated(.personalAccessToken, pat, user)
            } else {
                onAuthenticated(.webSession, cookieHeader, user)
            }
            dismiss()
        } catch {
            statusText = L("Still waiting for authenticated Jira session…")
        }
    }

    private func tryCreatePersonalAccessToken(cookieHeader: String) async -> String? {
        let endpoint = baseURL.appendingPathComponent("rest/pat/latest/tokens")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": "RockNRoll \(Int(Date().timeIntervalSince1970))",
            "expirationDuration": 90
        ])
        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await MeetingAITransfer.send(request, using: session),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawToken = json["rawToken"] as? String, !rawToken.isEmpty else {
            return nil
        }
        return rawToken
    }
}

private final class JiraWebNavigationCoordinator: NSObject, WKNavigationDelegate {
    var lastNonce: UUID?
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void

    init(onNavigationFinished: @escaping @MainActor (URL?, WKWebView) async -> Void) {
        self.onNavigationFinished = onNavigationFinished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        Task { @MainActor [onNavigationFinished] in
            await onNavigationFinished(url, webView)
        }
    }
}

#if os(iOS)
private struct JiraWebViewContainer: UIViewRepresentable {
    let startURL: URL
    let nonce: UUID
    let onWebViewReady: @MainActor (WKWebView) -> Void
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void

    func makeCoordinator() -> JiraWebNavigationCoordinator {
        JiraWebNavigationCoordinator(onNavigationFinished: onNavigationFinished)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastNonce = nonce
        webView.load(URLRequest(url: startURL))
        Task { @MainActor in onWebViewReady(webView) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != nonce {
            context.coordinator.lastNonce = nonce
            webView.load(URLRequest(url: startURL))
        }
    }
}
#else
private struct JiraWebViewContainer: NSViewRepresentable {
    let startURL: URL
    let nonce: UUID
    let onWebViewReady: @MainActor (WKWebView) -> Void
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void

    func makeCoordinator() -> JiraWebNavigationCoordinator {
        JiraWebNavigationCoordinator(onNavigationFinished: onNavigationFinished)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastNonce = nonce
        webView.load(URLRequest(url: startURL))
        Task { @MainActor in onWebViewReady(webView) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != nonce {
            context.coordinator.lastNonce = nonce
            webView.load(URLRequest(url: startURL))
        }
    }
}
#endif
#endif
