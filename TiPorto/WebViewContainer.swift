import SwiftUI

struct WebViewContainer: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController {
        WebViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController,
                                context: Context) {
        // nothing
    }
}
