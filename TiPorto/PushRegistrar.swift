import CryptoKit
import Foundation
import WebKit

@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()
    private let preferences = UserDefaults.standard
    private let tokenKey = "last_fcm_token"
    private let successKey = "push.last_successful_registration.v2"
    private weak var webView: WKWebView?
    private var inFlight = false
    private var retryPending = false

    private init() {}

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        tryRegister(reason: "WebView available")
    }

    func cacheToken(_ token: String) {
        guard token.count >= 20 else {
            print("[Push][Firebase] ignored invalid FCM token")
            return
        }
        guard preferences.string(forKey: tokenKey) != token else { return }
        preferences.set(token, forKey: tokenKey)
        print("[Push][Firebase] FCM token available (\(masked(token)))")
        tryRegister(reason: "FCM token available")
    }

    func tryRegisterOnNavigation(reason: String) { tryRegister(reason: reason) }

    private func tryRegister(reason: String) {
        guard let token = preferences.string(forKey: tokenKey), token.count >= 20 else {
            print("[Push][Backend] waiting for FCM token | reason=\(reason)")
            return
        }
        guard let webView else {
            print("[Push][Backend] waiting for WebView/session | token=\(masked(token))")
            return
        }
        guard AppConfig.isTrustedURL(webView.url) else {
            print("[Push][Backend] waiting for trusted page on \(AppConfig.environmentHost)")
            return
        }
        guard !inFlight else {
            retryPending = true
            return
        }
        webView.evaluateJavaScript("navigator.onLine !== false && window.__TiPortoNativeNetworkOnline !== false && !document.documentElement.classList.contains('tp-offline')") { [weak self, weak webView] result, error in
            guard let self, let webView else { return }
            if let error { print("[Push][Backend] page state unavailable: \(error.localizedDescription)") }
            guard result as? Bool == true else { return }
            self.readSession(from: webView, token: token, reason: reason)
        }
    }

    private func readSession(from webView: WKWebView, token: String, reason: String) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
            guard let self, let webView else { return }
            let host = AppConfig.environmentHost.lowercased()
            let hostCookies = cookies.filter {
                let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix(".\(domain)")
            }.sorted { $0.name < $1.name }
            let header = hostCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard !header.isEmpty else {
                print("[Push][Backend] waiting for authenticated WebView cookies | host=\(host)")
                return
            }
            let stableCookies = hostCookies.filter {
                let name = $0.name.lowercased()
                return name.contains("session") || name.contains("auth") || name.contains("remember")
            }
            let sessionIdentity = (stableCookies.isEmpty ? hostCookies : stableCookies)
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            webView.evaluateJavaScript("localStorage.getItem('locale') || ''") { value, _ in
                let locale = String(((value as? String) ?? "").replacingOccurrences(of: "-", with: "_").prefix(5))
                self.register(token: token, cookieHeader: header, sessionIdentity: sessionIdentity, locale: locale, reason: reason)
            }
        }
    }

    private func register(token: String, cookieHeader: String, sessionIdentity: String, locale: String, reason: String) {
        let session = hash(sessionIdentity)
        let key = [AppConfig.environmentHost, token, session].joined(separator: "|")
        guard preferences.string(forKey: successKey) != key else {
            print("[Push][Backend] already confirmed for token/session/environment")
            return
        }
        guard !AppConfig.skipTokenRegistrationInDebug, !inFlight else {
            retryPending = inFlight
            return
        }
        inFlight = true

        var request = URLRequest(url: AppConfig.registerTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if !locale.isEmpty { request.setValue(locale, forHTTPHeaderField: "X-Locale") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "platform": "ios"])
        print("[Push][Backend] POST /api/push/register-token | host=\(AppConfig.environmentHost) token=\(masked(token)) session=\(session.prefix(8)) reason=\(reason)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let registrar = self
            Task { @MainActor [weak registrar] in
                guard let self = registrar else { return }
                self.inFlight = false
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let result = self.validate(data)
                if let error {
                    print("[Push][Backend] transport error: \(error.localizedDescription); will retry")
                } else if (200...299).contains(code), result.ok, let boundTo = result.boundTo {
                    self.preferences.set(key, forKey: self.successKey)
                    print("[Push][Backend] registration CONFIRMED | HTTP \(code) bound_to=\(boundTo)")
                } else {
                    print("[Push][Backend] registration rejected | HTTP \(code) ok=\(result.ok) bound_to_valid=\(result.boundTo != nil); will retry")
                }
                if self.retryPending {
                    self.retryPending = false
                    self.tryRegister(reason: "queued state change")
                }
            }
        }.resume()
    }

    private func validate(_ data: Data?) -> (ok: Bool, boundTo: String?) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true, let raw = json["bound_to"], !(raw is NSNull) else { return (false, nil) }
        let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return (!value.isEmpty, value.isEmpty ? nil : value)
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func masked(_ token: String) -> String {
        token.count > 10 ? "\(token.prefix(6))…\(token.suffix(4))" : "<redacted>"
    }
}
