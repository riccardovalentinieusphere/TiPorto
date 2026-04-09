import Foundation
import WebKit

final class PushRegistrar {

    static let shared = PushRegistrar()
    private init() {}

    private let queue = DispatchQueue(label: "PushRegistrar.queue")
    private var inFlight = false

    // Dedup
    private let prefs = UserDefaults.standard
    private let keyLastSentToken  = "last_sent_token"
    private let keyLastSentCookie = "last_sent_cookie"

    // Storage
    private let keyLastFcmToken = "last_fcm_token"

    // WebView
    private weak var currentWebView: WKWebView?

    // MARK: - Public

    func setWebView(_ webView: WKWebView) {
        self.currentWebView = webView
    }

    func cacheToken(_ token: String) {
        prefs.set(token, forKey: keyLastFcmToken)
    }

    func getCachedToken() -> String {
        prefs.string(forKey: keyLastFcmToken) ?? ""
    }

    /// Entry-point unico, chiamato dal controller
    func tryRegisterOnNavigation(reason: String) {
        let token = getCachedToken()
        guard token.count >= 20 else {
            print("[PushRegistrar] SKIP token invalid | reason:", reason)
            return
        }
        guard let webView = currentWebView else {
            print("[PushRegistrar] SKIP no webView | reason:", reason)
            return
        }

        print("[PushRegistrar] TRY register | reason:", reason)
        updateCookiesAndTryRegister(from: webView, token: token)
    }

    // MARK: - Register internals

    func updateCookiesAndTryRegister(from webView: WKWebView, token: String) {
        guard token.count >= 20 else { return }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let host = AppConfig.homeURL.host ?? ""

            let cookieHeader = cookies
                .filter { $0.domain.contains(host) }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            guard !cookieHeader.isEmpty else { return }

            // 🔹 QUI leggiamo la locale dalla SPA
            self.fetchLocaleFromWebView(webView) { locale in
                self.queue.async {
                    self.tryRegisterIfAuthedLocked(
                        token: token,
                        cookieHeader: cookieHeader,
                        locale: locale
                    )
                }
            }
        }
    }

    private func tryRegisterIfAuthedLocked(token: String, cookieHeader: String, locale: String) {
        if AppConfig.skipTokenRegistrationInDebug {
            print("[PushRegistrar] DEBUG skip enabled")
            return
        }

        let lastToken  = prefs.string(forKey: keyLastSentToken)
        let lastCookie = prefs.string(forKey: keyLastSentCookie)
        
        if lastToken == token && lastCookie == cookieHeader {
            print("[PushRegistrar] SKIP dedup (token+cookie)")
            return
        }

        guard !inFlight else {
            print("[PushRegistrar] SKIP inFlight")
            return
        }

        inFlight = true
        print("[PushRegistrar] REGISTER start")

        var req = URLRequest(url: AppConfig.registerTokenURL)
        if !locale.isEmpty {
                req.setValue(locale, forHTTPHeaderField: "X-Locale")
                print("[PushRegistrar] X-Locale =", locale)
            }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "platform": "ios"
        ])

        URLSession.shared.dataTask(with: req) { _, resp, err in
            defer { self.queue.async { self.inFlight = false } }

            if let err {
                print("[PushRegistrar] ERROR:", err)
                return
            }

            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[PushRegistrar] HTTP", code)

            if (200...299).contains(code) {
                self.prefs.set(token, forKey: self.keyLastSentToken)
                self.prefs.set(cookieHeader, forKey: self.keyLastSentCookie)
                print("[PushRegistrar] REGISTER OK (dedup persisted)")
            }
        }.resume()
    }
    
    private func fetchLocaleFromWebView(
        _ webView: WKWebView,
        completion: @escaping (String) -> Void
    ) {
        let js = """
        (function () {
          try {
            return localStorage.getItem('locale') || '';
          } catch (e) {
            return '';
          }
        })();
        """

        webView.evaluateJavaScript(js) { res, err in
            if let err {
                print("[PushRegistrar] locale JS error:", err)
            }

            let raw = (res as? String) ?? ""
            let norm = raw
                .replacingOccurrences(of: "-", with: "_") // en-US → en_US
            completion(String(norm.prefix(5)))            // en_US
        }
    }

}
