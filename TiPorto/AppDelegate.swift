import FirebaseCore
import FirebaseMessaging
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureNavigationBarAppearance()
        UNUserNotificationCenter.current().delegate = self
        FirebaseApp.configure()
        print("[Push][Firebase] configured | project=\(FirebaseApp.app()?.options.projectID ?? "unknown") bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
        Messaging.messaging().delegate = self
        requestPushPermission(application)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        resetAppBadge()
        UNUserNotificationCenter.current().getNotificationSettings {
            print("[Push][Permission] status on active=\($0.authorizationStatus.rawValue)")
        }
        PushRegistrar.shared.tryRegisterOnNavigation(reason: "app became active")
    }

    private func requestPushPermission(_ application: UIApplication) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("[Push][Permission] current status=\(settings.authorizationStatus.rawValue)")
            let register = {
                DispatchQueue.main.async {
                    print("[Push][APNs] requesting registration")
                    application.registerForRemoteNotifications()
                }
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error { print("[Push][Permission] request failed: \(error.localizedDescription)") }
                    print("[Push][Permission] request completed | granted=\(granted)")
                    if granted { register() }
                }
            case .authorized, .provisional, .ephemeral:
                register()
            case .denied:
                print("[Push][Permission] denied; enable notifications in iOS Settings")
            @unknown default:
                print("[Push][Permission] unknown state")
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Push][APNs] device token received (\(hex.prefix(6))…\(hex.suffix(4)))")
        Messaging.messaging().apnsToken = deviceToken
        Messaging.messaging().token { token, error in
            if let error {
                print("[Push][Firebase] explicit token request failed: \(error.localizedDescription)")
            } else if let token {
                Task { @MainActor in PushRegistrar.shared.cacheToken(token) }
            } else {
                print("[Push][Firebase] explicit token request returned no token")
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push][APNs] registration FAILED: \(error.localizedDescription)")
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else {
            print("[Push][Firebase] delegate returned no FCM token")
            return
        }
        PushRegistrar.shared.cacheToken(fcmToken)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("[Push][Delivery] notification received in foreground")
        resetAppBadge()
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        resetAppBadge()
        if let url = PushPayload(userInfo: response.notification.request.content.userInfo).url {
            NotificationCenter.default.post(name: .openURLFromPush, object: url)
        }
        completionHandler()
    }

    private func resetAppBadge() { UNUserNotificationCenter.current().setBadgeCount(0) }

    private func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(named: "TopColor")
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().tintColor = .white
    }
}
