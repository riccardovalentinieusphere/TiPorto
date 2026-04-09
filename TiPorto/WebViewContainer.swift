import SwiftUI
import UIKit

struct WebViewContainer: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController()
    }

    func updateUIViewController(_ uiViewController: WebViewController, context: Context) {
        // nothing
    }
}
