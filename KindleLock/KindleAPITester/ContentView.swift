import SwiftUI
import WebKit

struct ContentView: View {
    @State private var showLogin = false
    @State private var clearCookiesFirst = false
    @State private var cookies: [HTTPCookie] = []
    @State private var isLoggedIn = false
    @State private var output = "Tap 'Login to Amazon' to begin"
    @State private var isLoading = false
    @State private var webView: WKWebView?
    @State private var deviceToken: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isLoggedIn {
                    Text("✅ Logged in")
                        .foregroundStyle(.green)
                    Text("\(cookies.count) cookies captured")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Fetch All") {
                            Task { await fetchAll() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)

                        Button("Clear & Re-login") {
                            // Clear ALL website data from ALL domains
                            let dataStore = WKWebsiteDataStore.default()
                            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                            let sinceDate = Date(timeIntervalSince1970: 0) // Beginning of time
                            dataStore.removeData(ofTypes: dataTypes, modifiedSince: sinceDate) {
                                // Also clear HTTPCookieStorage
                                if let cookies = HTTPCookieStorage.shared.cookies {
                                    for cookie in cookies {
                                        HTTPCookieStorage.shared.deleteCookie(cookie)
                                    }
                                }
                                DispatchQueue.main.async {
                                    self.clearCookiesFirst = true
                                    self.cookies = []
                                    self.isLoggedIn = false
                                    self.deviceToken = nil
                                    self.output = "All browser data cleared. Tap login."
                                    self.showLogin = true
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button("Login to Amazon") {
                        clearCookiesFirst = false
                        showLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isLoading {
                    ProgressView()
                }

                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
            .navigationTitle("Kindle API Tester")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: output) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                AmazonLoginView(
                    cookies: $cookies,
                    isLoggedIn: $isLoggedIn,
                    isPresented: $showLogin,
                    clearCookiesFirst: clearCookiesFirst,
                    deviceToken: $deviceToken
                )
            }
        }
    }

    // MARK: - Fetch All Methods

    private func fetchAll() async {
        isLoading = true
        output = "=== Kindle API Test Suite ===\n"
        output += "Testing all available methods...\n\n"

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let sessionId = cookies.first(where: { $0.name == "session-id" })?.value ?? ""

        // Method 1: Library JSON API
        output += "--- Method 1: Library JSON API ---\n"
        let books = await fetchLibraryJSON(cookieHeader: cookieHeader, sessionId: sessionId)
        output += "Found \(books.count) books\n"
        if let first = books.first {
            output += "Sample: \(first.title.prefix(30))... (percentageRead: \(first.percentageRead))\n"
        }
        output += "Note: percentageRead is always 0 from this endpoint\n"

        // Method 2: Device Token Status
        output += "\n--- Method 2: Device Token ---\n"
        var adpToken: String? = nil
        if let capturedToken = deviceToken {
            output += "✅ Device token captured from login: \(capturedToken.prefix(20))...\n"
            // Now get the device session token using the captured device token
            adpToken = await fetchDeviceSessionToken(deviceToken: capturedToken, cookieHeader: cookieHeader, sessionId: sessionId)
        } else {
            output += "⚠️ No device token captured from login\n"
            output += "Note: Try 'Clear & Re-login' to capture the device token\n"
        }

        // Method 3: startReading API (try first 3 books)
        output += "\n--- Method 3: startReading API ---\n"
        for book in books.prefix(3) {
            let result = await fetchStartReading(asin: book.asin, cookieHeader: cookieHeader, sessionId: sessionId, adpToken: adpToken)
            output += "\(book.title.prefix(25))...: \(result)\n"
        }

        // Method 4: HTML DOM Scrape
        output += "\n--- Method 4: HTML DOM Scrape ---\n"
        output += "Loading library page in WebView...\n"

        await scrapeLibraryHTML()

        isLoading = false
    }

    // MARK: - Method 1: Library JSON API

    struct BookInfo {
        let asin: String
        let title: String
        let percentageRead: Int
    }

    private func fetchLibraryJSON(cookieHeader: String, sessionId: String) async -> [BookInfo] {
        do {
            let url = URL(string: "https://read.amazon.com/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50")!
            var request = URLRequest(url: url)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(sessionId, forHTTPHeaderField: "x-amzn-sessionid")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                output += "API returned non-200 status\n"
                return []
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let itemsList = json["itemsList"] as? [[String: Any]] else {
                output += "Failed to parse JSON response\n"
                return []
            }

            return itemsList.map { book in
                BookInfo(
                    asin: book["asin"] as? String ?? "",
                    title: book["title"] as? String ?? "Unknown",
                    percentageRead: book["percentageRead"] as? Int ?? 0
                )
            }
        } catch {
            output += "Error: \(error.localizedDescription)\n"
            return []
        }
    }

    // MARK: - Method 2: Device Session Token

    private func fetchDeviceSessionToken(deviceToken: String, cookieHeader: String, sessionId: String) async -> String? {
        do {
            let url = URL(string: "https://read.amazon.com/service/web/register/getDeviceToken?serialNumber=\(deviceToken)&deviceType=\(deviceToken)")!
            var request = URLRequest(url: url)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(sessionId, forHTTPHeaderField: "x-amzn-sessionid")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                output += "Device token fetch: No response\n"
                return nil
            }

            output += "Device token HTTP: \(httpResponse.statusCode)\n"

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    output += "Response keys: \(json.keys.joined(separator: ", "))\n"

                    if let deviceSessionToken = json["deviceSessionToken"] as? String {
                        output += "✅ Got ADP session token!\n"
                        return deviceSessionToken
                    } else {
                        let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "?"
                        output += "Response: \(preview)\n"
                    }
                } else {
                    let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "?"
                    output += "Raw: \(preview)\n"
                }
            } else {
                let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "?"
                output += "Error: \(preview)\n"
            }
        } catch {
            output += "Error: \(error.localizedDescription)\n"
        }
        return nil
    }

    // MARK: - Method 3: startReading API

    private func fetchStartReading(asin: String, cookieHeader: String, sessionId: String, adpToken: String?) async -> String {
        do {
            let url = URL(string: "https://read.amazon.com/service/mobile/reader/startReading?asin=\(asin)&clientVersion=20000100")!
            var request = URLRequest(url: url)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(sessionId, forHTTPHeaderField: "x-amzn-sessionid")
            if let adpToken = adpToken {
                request.setValue(adpToken, forHTTPHeaderField: "x-adp-session-token")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return "No response"
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let lastPageRead = json["lastPageReadData"] as? [String: Any],
                       let position = lastPageRead["position"] as? Int {
                        return "✅ Position: \(position)"
                    } else {
                        return "✅ OK but no position data"
                    }
                }
                return "✅ OK but couldn't parse"
            } else {
                return "❌ HTTP \(httpResponse.statusCode)"
            }
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    // MARK: - Method 3: HTML DOM Scrape

    @MainActor
    private func scrapeLibraryHTML() async {
        await withCheckedContinuation { continuation in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()

            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            self.webView = wv

            let coordinator = HTMLScrapeCoordinator { result in
                self.output += result
                self.webView = nil
                continuation.resume()
            }

            wv.navigationDelegate = coordinator

            // Keep coordinator alive
            objc_setAssociatedObject(wv, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

            if let url = URL(string: "https://read.amazon.com/kindle-library") {
                wv.load(URLRequest(url: url))
            }
        }
    }
}

// MARK: - HTML Scrape Coordinator

class HTMLScrapeCoordinator: NSObject, WKNavigationDelegate {
    var completion: (String) -> Void
    var hasExtracted = false

    init(completion: @escaping (String) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }

        if url.absoluteString.contains("kindle-library") && !hasExtracted {
            hasExtracted = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.extractData(from: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion("❌ WebView navigation failed: \(error.localizedDescription)\n")
    }

    private func extractData(from webView: WKWebView) {
        let js = """
        (function() {
            const books = [];
            const debug = {
                url: window.location.href,
                selectors: {}
            };

            // Try multiple selector strategies
            const strategies = [
                { name: 'library-item-option', selector: '[id^="library-item-option-"]' },
                { name: 'book-card', selector: '[data-asin]' },
                { name: 'notebook-book', selector: '.kp-notebook-library-each-book' },
                { name: 'content-item', selector: '[class*="content-item"]' },
                { name: 'library-item', selector: '[class*="library-item"]' }
            ];

            for (const strat of strategies) {
                const found = document.querySelectorAll(strat.selector);
                debug.selectors[strat.name] = found.length;
            }

            // Get page HTML snippet for debugging (first 2000 chars of body)
            debug.bodySnippet = document.body?.innerHTML?.substring(0, 2000) || 'no body';

            // Strategy 1: library-item-option-{asin} elements
            const items = document.querySelectorAll('[id^="library-item-option-"]');
            for (const item of items) {
                const id = item.id;
                if (id.includes('sample')) continue;

                const asin = id.replace('library-item-option-', '');
                if (!asin) continue;

                let title = 'Unknown';
                let percentComplete = 0;

                // Title extraction - use the specific title element by ID
                const titleEl = document.getElementById('title-' + asin);
                if (titleEl) {
                    title = titleEl.textContent?.trim() || 'Unknown';
                }

                // Fallback: Try the hidden div with book title (class contains _1C_Zm4Mhyc833h7XJtCCVx)
                if (title === 'Unknown') {
                    const hiddenTitle = item.querySelector('[aria-hidden="true"]');
                    if (hiddenTitle) {
                        title = hiddenTitle.textContent?.trim() || 'Unknown';
                    }
                }

                // Fallback: aria-label on item
                if (title === 'Unknown') {
                    const ariaLabel = item.getAttribute('aria-label');
                    if (ariaLabel && ariaLabel !== asin) {
                        title = ariaLabel;
                    }
                }

                // Percentage extraction - use the specific percentage element by ID
                const percentReadEl = document.getElementById('percentage-read-' + asin);
                if (percentReadEl) {
                    const text = percentReadEl.textContent || '';
                    const match = text.match(/(\\d+)/);
                    if (match) percentComplete = parseInt(match[1]);
                    // Also capture raw text for debugging
                    debug.samplePercentText = text;
                }

                // Fallback: Search for percentage in item text
                if (percentComplete === 0) {
                    const match = (item.innerText || '').match(/(\\d+)%/);
                    if (match) percentComplete = parseInt(match[1]);
                }

                // Look for progress bar
                if (percentComplete === 0) {
                    const progressBar = item.querySelector('[class*="progress"], [role="progressbar"]');
                    if (progressBar) {
                        const width = progressBar.style?.width;
                        if (width) {
                            const match = width.match(/(\\d+)/);
                            if (match) percentComplete = parseInt(match[1]);
                        }
                        const ariaVal = progressBar.getAttribute('aria-valuenow');
                        if (ariaVal) percentComplete = parseInt(ariaVal);
                    }
                }

                books.push({
                    asin: asin,
                    title: title.substring(0, 50),
                    percent: percentComplete
                });
            }

            // Strategy 2: data-asin elements (fallback)
            if (books.length === 0) {
                const asinItems = document.querySelectorAll('[data-asin]');
                for (const item of asinItems) {
                    const asin = item.getAttribute('data-asin');
                    if (!asin) continue;

                    books.push({
                        asin: asin,
                        title: item.textContent?.substring(0, 50) || 'Unknown',
                        percent: 0
                    });
                }
            }

            // Debug: Check if title and percentage elements exist
            if (items.length > 0) {
                const firstAsin = items[0].id.replace('library-item-option-', '');
                debug.firstAsin = firstAsin;
                debug.titleElExists = !!document.getElementById('title-' + firstAsin);
                debug.percentElExists = !!document.getElementById('percentage-read-' + firstAsin);

                // Get title element HTML if exists
                const titleEl = document.getElementById('title-' + firstAsin);
                if (titleEl) {
                    debug.titleElHTML = titleEl.outerHTML?.substring(0, 300);
                }

                // Get percentage element HTML if exists
                const percentEl = document.getElementById('percentage-read-' + firstAsin);
                if (percentEl) {
                    debug.percentElHTML = percentEl.outerHTML?.substring(0, 300);
                }

                debug.firstItemHTML = items[0].outerHTML?.substring(0, 1500) || 'none';
            }

            return JSON.stringify({
                count: books.length,
                books: books,
                debug: debug
            });
        })();
        """

        webView.evaluateJavaScript(js) { result, error in
            var output = ""

            if let error = error {
                output = "❌ JavaScript error: \(error.localizedDescription)\n"
            } else if let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                let count = parsed["count"] as? Int ?? 0
                let books = parsed["books"] as? [[String: Any]] ?? []
                let debug = parsed["debug"] as? [String: Any] ?? [:]

                output += "Found \(count) books via DOM scraping\n"
                output += "Page URL: \(debug["url"] ?? "?")\n\n"

                // Show selector stats
                if let selectors = debug["selectors"] as? [String: Int] {
                    output += "Selector counts:\n"
                    for (name, cnt) in selectors {
                        output += "  \(name): \(cnt)\n"
                    }
                    output += "\n"
                }

                if books.isEmpty {
                    output += "⚠️ No books found - page may not have loaded fully\n"
                    // Show body snippet for debugging
                    if let snippet = debug["bodySnippet"] as? String {
                        output += "\nPage HTML preview:\n\(snippet.prefix(500))...\n"
                    }
                } else {
                    for (index, book) in books.prefix(10).enumerated() {
                        let title = book["title"] as? String ?? "?"
                        let percent = book["percent"] as? Int ?? 0
                        let rawText = book["rawText"] as? String ?? ""
                        output += "\(index + 1). \(title) [\(percent)%]\n"
                        if !rawText.isEmpty && title == "Unknown" {
                            output += "   raw: \(rawText.prefix(60))...\n"
                        }
                    }
                    if books.count > 10 {
                        output += "... and \(books.count - 10) more\n"
                    }
                }

                // Show element existence debug info
                output += "\n--- Debug Info ---\n"
                if let firstAsin = debug["firstAsin"] as? String {
                    output += "First ASIN: \(firstAsin)\n"
                }
                output += "title element exists: \(debug["titleElExists"] ?? false)\n"
                output += "percent element exists: \(debug["percentElExists"] ?? false)\n"

                if let titleHTML = debug["titleElHTML"] as? String {
                    output += "\nTitle element HTML:\n\(titleHTML)\n"
                }

                if let percentHTML = debug["percentElHTML"] as? String {
                    output += "\nPercent element HTML:\n\(percentHTML)\n"
                }

                if let sampleText = debug["samplePercentText"] as? String {
                    output += "\nSample percent text: '\(sampleText)'\n"
                }

                // Show first item HTML for debugging
                if let firstHTML = debug["firstItemHTML"] as? String {
                    output += "\n--- First item HTML (full) ---\n"
                    output += "\(firstHTML.prefix(1200))...\n"
                }
            } else {
                output = "❌ Failed to parse scrape result\n"
            }

            self.completion(output)
        }
    }
}

// MARK: - Amazon Login WebView Container

struct AmazonLoginView: View {
    @Binding var cookies: [HTTPCookie]
    @Binding var isLoggedIn: Bool
    @Binding var isPresented: Bool
    var clearCookiesFirst: Bool = false
    @Binding var deviceToken: String?

    @State private var webViewRef: WKWebView?
    @State private var statusMessage = "Loading..."

    var body: some View {
        NavigationStack {
            AmazonWebView(
                cookies: $cookies,
                isLoggedIn: $isLoggedIn,
                deviceToken: $deviceToken,
                clearCookiesFirst: clearCookiesFirst,
                webViewRef: $webViewRef,
                statusMessage: $statusMessage
            )
            .navigationTitle("Amazon Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let webView = webViewRef {
                            extractCookiesAndClose(from: webView)
                        }
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

    private func extractCookiesAndClose(from webView: WKWebView) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { allCookies in
            let amazonCookies = allCookies.filter { cookie in
                cookie.domain.contains("amazon.com") || cookie.domain.contains("amazon.")
            }

            print("🍪 Extracted \(amazonCookies.count) Amazon cookies")

            // Check for REQUIRED auth cookies
            let requiredCookieNames = ["at-main", "session-id"]
            let hasRequiredCookies = requiredCookieNames.allSatisfy { name in
                amazonCookies.contains { $0.name == name }
            }
            print("🔐 Has required auth cookies: \(hasRequiredCookies)")

            // Save cookies to default store
            let defaultStore = WKWebsiteDataStore.default().httpCookieStore
            for cookie in amazonCookies {
                defaultStore.setCookie(cookie)
            }

            DispatchQueue.main.async {
                self.cookies = amazonCookies
                self.isLoggedIn = hasRequiredCookies
                self.isPresented = false
            }
        }
    }
}

// MARK: - Amazon WebView (UIViewRepresentable)

struct AmazonWebView: UIViewRepresentable {
    @Binding var cookies: [HTTPCookie]
    @Binding var isLoggedIn: Bool
    @Binding var deviceToken: String?
    var clearCookiesFirst: Bool
    @Binding var webViewRef: WKWebView?
    @Binding var statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Use non-persistent data store if clearing
        if clearCookiesFirst {
            config.websiteDataStore = .nonPersistent()
        } else {
            config.websiteDataStore = .default()
        }

        // Inject script to capture device token from network requests
        let script = WKUserScript(source: """
            (function() {
                const originalFetch = window.fetch;
                window.fetch = function(...args) {
                    const url = args[0]?.url || args[0];
                    if (url && url.includes('getDeviceToken')) {
                        const urlParams = new URLSearchParams(new URL(url).search);
                        const serialNumber = urlParams.get('serialNumber');
                        if (serialNumber) {
                            window.webkit.messageHandlers.deviceToken.postMessage(serialNumber);
                        }
                    }
                    return originalFetch.apply(this, args);
                };

                const originalXHR = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url, ...args) {
                    if (url && url.includes('getDeviceToken')) {
                        const urlParams = new URLSearchParams(new URL(url, window.location.origin).search);
                        const serialNumber = urlParams.get('serialNumber');
                        if (serialNumber) {
                            window.webkit.messageHandlers.deviceToken.postMessage(serialNumber);
                        }
                    }
                    return originalXHR.apply(this, [method, url, ...args]);
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "deviceToken")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Store reference for parent to access
        DispatchQueue.main.async {
            self.webViewRef = webView
        }

        // Load kindle-library to trigger device token request
        if let url = URL(string: "https://read.amazon.com/kindle-library") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: AmazonWebView

        init(_ parent: AmazonWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "deviceToken", let token = message.body as? String {
                print("📱 Captured device token: \(token.prefix(20))...")
                DispatchQueue.main.async {
                    self.parent.deviceToken = token
                    self.parent.statusMessage = "✅ Device token captured"
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            print("📄 Page loaded: \(url.absoluteString.prefix(60))...")

            DispatchQueue.main.async {
                if url.absoluteString.contains("signin") || url.absoluteString.contains("ap/") {
                    self.parent.statusMessage = "Please sign in, then tap Done"
                } else if url.host?.contains("read.amazon.com") == true {
                    self.parent.statusMessage = "Library loaded - tap Done when ready"
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.statusMessage = "Loading..."
            }
        }
    }
}

#Preview {
    ContentView()
}
