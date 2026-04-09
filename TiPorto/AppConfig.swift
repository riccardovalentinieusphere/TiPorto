import Foundation

enum AppConfig {
    static let skipTokenRegistrationInDebug: Bool = {
        #if DEBUG
        return false
        #else
        return false
        #endif
    }()

    static let homeURL = URL(
        string: "https://int.tiporto.io/Transports/Home"
    )!

    static let logoutURL = URL(
        string: "https://int.tiporto.io/logout"
    )!

    static let registerTokenURL = URL(
        string: "https://int.tiporto.io/api/push/register-token"
    )!

    static let unbindTokenURL = URL(
        string: "https://int.tiporto.io/api/push/unbind-token"
    )!

    static let fcmHeaderName = "X-FCM-Token"
}
