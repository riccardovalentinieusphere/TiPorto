import Foundation
import WebKit

final class PushRegistrar {

    static let shared = PushRegistrar()
    private init() {}

    func cacheToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "last_fcm_token")
    }

    func updateCookies(from webView: WKWebView) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { _ in }
    }

    func tryRegisterIfAuthed(token: String) {
#if DEBUG
        print("PushRegistrar DEBUG: skip network")
        return
#endif
        // chiamata reale al backend
    }
}
