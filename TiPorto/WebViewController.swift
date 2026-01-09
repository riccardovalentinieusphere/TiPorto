import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate {

    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        webView.load(URLRequest(url: AppConfig.homeURL))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openFromPush(_:)),
            name: .openURLFromPush,
            object: nil
        )
    }

    @objc private func openFromPush(_ n: Notification) {
        guard let url = n.object as? URL else { return }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PushRegistrar.shared.updateCookies(from: webView)

        if let token = UserDefaults.standard.string(forKey: "last_fcm_token") {
            PushRegistrar.shared.tryRegisterIfAuthed(token: token)
        }
    }
}

extension Notification.Name {
    static let openURLFromPush = Notification.Name("openURLFromPush")
}
