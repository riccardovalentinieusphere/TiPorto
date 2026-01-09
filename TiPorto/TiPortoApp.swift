//
//  TiPortoApp 2.swift
//  TiPorto
//
//  Created by Riccardo Valentini on 18.12.2025.
//


import SwiftUI

@main
struct TiPortoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        WindowGroup {
            WebViewContainer()
        }
    }
}
