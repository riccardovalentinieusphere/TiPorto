import Foundation

enum AppConfig {
    static let skipTokenRegistrationInDebug: Bool = {
        #if DEBUG
        return false
        #else
        return false
        #endif
    }()

    // Version 5 is the TestFlight beta and uses the beta web frontend.
    private static let baseURL = URL(string: "https://beta.tiporto.io")!
    static let environmentHost = baseURL.host!

    static let homeURL = baseURL.appending(path: "Home")
    static let logoutURL = baseURL.appending(path: "logout")
    static let registerTokenURL = baseURL.appending(path: "api/push/register-token")
    static let unbindTokenURL = baseURL.appending(path: "api/push/unbind-token")

    static let fcmHeaderName = "X-FCM-Token"

    static func isTrustedURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == homeURL.host
            && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func isReadOnlyMethod(_ method: String?) -> Bool {
        ["GET", "HEAD", "OPTIONS"].contains((method ?? "GET").uppercased())
    }
}
