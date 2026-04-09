//
//  AppDelegate.swift
//  TiPorto
//
//  Created by Riccardo Valentini on 18.12.2025.
//

import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

final class AppDelegate: NSObject,
                         UIApplicationDelegate,
                         MessagingDelegate,
                         UNUserNotificationCenterDelegate {

    // MARK: - App lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        FirebaseApp.configure()

        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(named: "TopColor")
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.white
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white
        ]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().tintColor = .white

        requestPushPermission(application)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        resetAppBadge()
    }

    // MARK: - Badge (iOS 17+)

    private func resetAppBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: - Push permission

    private func requestPushPermission(_ application: UIApplication) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        application.registerForRemoteNotifications()
                    }
                }
            }
    }

    // MARK: - Foreground push

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("🔔 Foreground push received:", notification.request.content.userInfo)

        // IMPORTANTE: NON includere .badge
        resetAppBadge()
        completionHandler([.banner, .sound])
    }

    // MARK: - Tap su push (background / terminated)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        resetAppBadge()

        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        if let url = payload.url {
            NotificationCenter.default.post(
                name: .openURLFromPush,
                object: url
            )
        }

        completionHandler()
    }

    // MARK: - APNs / Firebase

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print(
            "APNs device token received:",
            deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        )
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        guard let token = fcmToken, token.count >= 20 else { return }
        PushRegistrar.shared.cacheToken(token)
    }
}
