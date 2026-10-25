import FirebaseCore
import FirebaseMessaging
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    private var didStartPushServices = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        configureNavigationBarAppearance()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        resetAppBadge()
        startPushServicesAfterInitialRender(application)
    }

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

    private func startPushServicesAfterInitialRender(_ application: UIApplication) {
        guard !didStartPushServices else { return }
        didStartPushServices = true

        Task { @MainActor in
            // Let the first WebView frame start loading before initializing Firebase and push services.
            try? await Task.sleep(for: .milliseconds(500))
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
            requestPushPermission(application)
        }
    }

    private func resetAppBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    private func requestPushPermission(_ application: UIApplication) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }

                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        resetAppBadge()
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        resetAppBadge()

        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        if let url = payload.url {
            NotificationCenter.default.post(name: .openURLFromPush, object: url)
        }

        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, token.count >= 20 else { return }
        PushRegistrar.shared.cacheToken(token)
    }
}
