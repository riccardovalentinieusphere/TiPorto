import Foundation

enum AppConfig {
    static let homeURL = URL(string: "https://example.com")!
    static let registerTokenURL = URL(string: "https://example.com/api/push/register-token")!
    static let unbindTokenURL   = URL(string: "https://example.com/api/push/unbind-token")!
    static let fcmHeaderName = "X-FCM-Token"
}
