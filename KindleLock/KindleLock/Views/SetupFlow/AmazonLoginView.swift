import SwiftUI
import WebKit

/// View for Amazon Kindle login via WKWebView
/// Captures cookies and device token during login flow
struct AmazonLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authService = KindleAuthService.shared

    let onLoginComplete: (Bool) -> Void

    @State private var webViewRef: WKWebView?
    @State private var statusMessage = "Loading..."
    @State private var deviceToken: String?
    @State private var cookies: [HTTPCookie] = []

    var body: some View {
        NavigationStack {
            AmazonWebViewRepresentable(
                deviceToken: $deviceToken,
                webViewRef: $webViewRef,
                statusMessage: $statusMessage
            )
            .navigationTitle("Sign in to Amazon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onLoginComplete(false)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        extractCookiesAndFinish()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private func extractCookiesAndFinish() {
        guard let webView = webViewRef else {
            onLoginComplete(false)
            dismiss()
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { allCookies in
            let amazonCookies = allCookies.filter { cookie in
                cookie.domain.contains("amazon.com") || cookie.domain.contains("amazon.")
            }

            // Check for required auth cookies
            let requiredCookieNames = ["at-main", "session-id"]
            let hasRequiredCookies = requiredCookieNames.allSatisfy { name in
                amazonCookies.contains { $0.name == name }
            }

            DispatchQueue.main.async {
                if hasRequiredCookies {
                    // Save to keychain via auth service and check if it actually succeeded
                    let saveSuccess = self.authService.saveAuthData(cookies: amazonCookies, deviceToken: self.deviceToken)
                    self.onLoginComplete(saveSuccess)
                } else {
                    self.onLoginComplete(false)
                }
                self.dismiss()
            }
        }
    }
}

// MARK: - WKWebView Representable

private struct AmazonWebViewRepresentable: UIViewRepresentable {
    @Binding var deviceToken: String?
    @Binding var webViewRef: WKWebView?
    @Binding var statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Use non-persistent store for clean login (no stale sessions)
        config.websiteDataStore = .nonPersistent()

        // Inject device token capture script
        let script = WKUserScript(
            source: KindleAuthService.deviceTokenCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )

        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "deviceToken")
        config.userContentController.add(context.coordinator, name: "debugLog")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Store reference
        DispatchQueue.main.async {
            self.webViewRef = webView
        }

        // Load Kindle library (triggers login if not authenticated)
        if let url = URL(string: "https://read.amazon.com/kindle-library") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: AmazonWebViewRepresentable

        init(_ parent: AmazonWebViewRepresentable) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "deviceToken", let jsonString = message.body as? String {
                // Parse JSON to get token
                if let data = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let token = json["token"] {
                    DispatchQueue.main.async {
                        self.parent.deviceToken = token
                        self.parent.statusMessage = "✓ Device registered"
                    }
                }
            }
            // debugLog messages are ignored in production
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }

            DispatchQueue.main.async {
                if url.absoluteString.contains("signin") || url.absoluteString.contains("ap/") {
                    self.parent.statusMessage = "Sign in, then tap Done"
                } else if url.host?.contains("read.amazon.com") == true {
                    self.parent.statusMessage = "Signed in - tap Done"
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.statusMessage = "Loading..."
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    AmazonLoginView { success in
        print("Login completed: \(success)")
    }
}
