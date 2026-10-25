import SwiftUI
import UIKit
import UserNotifications

@main
struct TiPortoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @Environment(\.scenePhase)
    private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.white
                    .ignoresSafeArea(.all)

                WebViewContainer()
            }
            .ignoresSafeArea(.all)
                .task {
                    UNUserNotificationCenter.current().setBadgeCount(0)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }
}
