import Foundation
import WebKit

/// Handles Amazon Kindle authentication via WKWebView
/// Captures cookies and device token during login flow
@MainActor
final class KindleAuthService: ObservableObject {
    static let shared = KindleAuthService()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var authError: String?

    private let keychain = KeychainService.shared
    private let logger = DebugLogger.shared

    private init() {
        // Check if we have valid stored credentials
        isAuthenticated = keychain.hasAuthCookies
        logger.log(.auth, "Auth init: \(isAuthenticated ? "authenticated" : "not authenticated")")
    }

    // MARK: - Public Interface

    /// Get the cookie header string for API requests
    var cookieHeader: String {
        keychain.loadCookies()
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Get the session ID from stored cookies
    var sessionId: String? {
        keychain.loadCookies().first { $0.name == "session-id" }?.value
    }

    /// Get stored device token
    var deviceToken: String? {
        keychain.loadDeviceToken()
    }

    /// Get stored ADP session token
    var adpSessionToken: String? {
        keychain.loadADPSessionToken()
    }

    /// Save authentication data after successful login
    /// Returns true if save was successful and cookies are verified in keychain
    @discardableResult
    func saveAuthData(cookies: [HTTPCookie], deviceToken: String?) -> Bool {
        do {
            let existingDeviceToken = keychain.loadDeviceToken()
            let resolvedDeviceToken = deviceToken ?? existingDeviceToken

            guard resolvedDeviceToken != nil else {
                authError = "Device token missing. Please try again."
                logger.log(.error, "Auth save failed: missing device token")
                return false
            }

            try keychain.saveCookies(cookies)

            if let token = deviceToken {
                try keychain.saveDeviceToken(token)
                logger.log(.auth, "Device token saved", details: "Token: \(token.prefix(20))...")
            }

            let hasAuth = keychain.hasAuthCookies && resolvedDeviceToken != nil
            isAuthenticated = hasAuth
            authError = nil

            logger.log(.auth, "Auth saved: \(cookies.count) cookies, hasAuth=\(hasAuth)", details: "Cookie names: \(cookies.map { $0.name }.joined(separator: ", "))")
            return hasAuth
        } catch {
            authError = "Failed to save credentials: \(error.localizedDescription)"
            logger.log(.error, "Auth save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Save ADP session token (obtained from getDeviceToken API)
    func saveADPSessionToken(_ token: String) {
        do {
            try keychain.saveADPSessionToken(token)
            logger.log(.auth, "ADP session token saved")
        } catch {
            logger.log(.error, "Failed to save ADP token: \(error.localizedDescription)")
        }
    }

    /// Clear all stored credentials and log out
    func logout() {
        logger.log(.auth, "Logging out - clearing all credentials")
        keychain.clearAll()
        isAuthenticated = false

        // Clear WKWebView data
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
            // Also clear HTTPCookieStorage
            if let cookies = HTTPCookieStorage.shared.cookies {
                for cookie in cookies {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
        }
    }

    /// Mark as needing re-authentication (e.g., after 401/403)
    func markSessionExpired() {
        logger.log(.auth, "Session marked expired")
        isAuthenticated = false
        authError = "Session expired. Please log in again."
    }

    /// Check if stored cookies contain required auth cookies
    func validateStoredAuth() -> Bool {
        let hasAuth = keychain.hasAuthCookies
        isAuthenticated = hasAuth
        return hasAuth
    }
}

// MARK: - JavaScript for Device Token Capture

extension KindleAuthService {
    /// JavaScript to inject into WKWebView to capture device token from network requests
    static let deviceTokenCaptureScript = """
        (function() {
            const log = (msg) => window.webkit.messageHandlers.debugLog.postMessage(msg);
            const foundToken = (source, token) => {
                window.webkit.messageHandlers.deviceToken.postMessage(JSON.stringify({source, token}));
            };

            // Helper to extract serialNumber from URL (works with relative URLs)
            const extractSerialNumber = (url) => {
                if (!url || !url.includes('getDeviceToken')) return null;
                const match = url.match(/serialNumber=([^&]+)/);
                return match ? match[1] : null;
            };

            // 1. Intercept fetch
            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0]?.url || args[0];
                if (typeof url === 'string') {
                    log('fetch: ' + url.substring(0, 100));
                    const serial = extractSerialNumber(url);
                    if (serial) {
                        log('🎯 Found device token in fetch!');
                        foundToken('fetch', serial);
                    }
                }
                return originalFetch.apply(this, args);
            };

            // 2. Intercept XHR
            const originalXHR = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url, ...args) {
                if (typeof url === 'string') {
                    log('xhr: ' + url.substring(0, 100));
                    const serial = extractSerialNumber(url);
                    if (serial) {
                        log('🎯 Found device token in XHR!');
                        foundToken('xhr', serial);
                    }
                }
                return originalXHR.apply(this, [method, url, ...args]);
            };

            // 3. Intercept sendBeacon
            if (navigator.sendBeacon) {
                const originalBeacon = navigator.sendBeacon.bind(navigator);
                navigator.sendBeacon = function(url, data) {
                    log('beacon: ' + url.substring(0, 100));
                    const serial = extractSerialNumber(url);
                    if (serial) {
                        log('🎯 Found device token in beacon!');
                        foundToken('beacon', serial);
                    }
                    return originalBeacon(url, data);
                };
            }

            log('Device token capture script initialized');
        })();
        """
}
