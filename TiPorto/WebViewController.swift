import UIKit
import WebKit
import Network

final class WebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!

    // tracking path
    private var savedPath: String = ""
    private var nextPath: String = ""

    private var didRegisterAfterLoginTransition = false

    // ===== Reachability =====
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "tiporto.net.monitor")

    private var isNetworkUp: Bool = true
    private var isShowingOfflineAlert = false

    private let offlineMessage = """
    Impossibile collegarsi al servizio.

    Assicurati di avere una connessione Internet attiva
    (Wi-Fi o rete mobile) e riprova.
    """

    // ===== Overlay (MOSTRARE SOLO SE OFFLINE) =====
    private lazy var overlay: UIView = {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        overlay.isHidden = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.layer.cornerRadius = 14
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Nessuna connessione"
        label.textColor = .label
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center

        blur.contentView.addSubview(spinner)
        blur.contentView.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: blur.topAnchor, constant: 24),

            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -24),
        ])

        overlay.addSubview(blur)

        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            blur.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            blur.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])

        return overlay
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let js = """
        (function () {
          if (window.__iosNavHooked) return;
          window.__iosNavHooked = true;

          function post(reason) {
            try {
              window.webkit.messageHandlers.inertiaNav.postMessage({
                href: window.location.href,
                path: window.location.pathname,
                reason: reason || "unknown"
              });
            } catch (e) {}
          }

          document.addEventListener('inertia:navigate', () => post('inertia:navigate'));
          document.addEventListener('inertia:finish', () => post('inertia:finish'));
          window.addEventListener('popstate', () => post('popstate'));

          const _ps = history.pushState;
          history.pushState = function () {
            const r = _ps.apply(this, arguments);
            post('history.pushState');
            return r;
          };

          const _rs = history.replaceState;
          history.replaceState = function () {
            const r = _rs.apply(this, arguments);
            post('history.replaceState');
            return r;
          };

          post('init');
        })();
        """

        let userScript = WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "inertiaNav")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        // Edge-to-edge reale
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.verticalScrollIndicatorInsets = .zero
        webView.scrollView.horizontalScrollIndicatorInsets = .zero
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.alwaysBounceVertical = true

        let root = UIView()
        root.backgroundColor = .clear

        root.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        root.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        additionalSafeAreaInsets = .zero

        PushRegistrar.shared.setWebView(webView)
        startNetworkMonitor()
        webView.load(URLRequest(url: AppConfig.homeURL))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // iOS ogni tanto reinserisce inset automatici
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.verticalScrollIndicatorInsets = .zero
        webView.scrollView.horizontalScrollIndicatorInsets = .zero
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "inertiaNav")
        monitor.cancel()
    }

    // MARK: - Offline UI

    private func setOfflineUI(_ offline: Bool) {
        overlay.isHidden = !offline

        if offline {
            presentOfflineAlert()
        } else {
            dismissOfflineAlertIfNeeded()
        }
    }

    private func presentOfflineAlert() {
        guard !isShowingOfflineAlert else { return }
        isShowingOfflineAlert = true

        let a = UIAlertController(
            title: "TiPorto non raggiungibile",
            message: offlineMessage,
            preferredStyle: .alert
        )

        a.addAction(UIAlertAction(title: "Riprova", style: .default) { _ in
            self.isShowingOfflineAlert = false

            guard self.isNetworkUp else {
                self.setOfflineUI(true)
                return
            }

            self.setOfflineUI(false)
            self.webView.reload()
        })

        a.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in
            self.isShowingOfflineAlert = false
        })

        present(a, animated: true)
    }

    private func dismissOfflineAlertIfNeeded() {
        if isShowingOfflineAlert, presentedViewController is UIAlertController {
            dismiss(animated: true)
            isShowingOfflineAlert = false
        }
    }

    // MARK: - Reachability

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                let up = (path.status == .satisfied)
                self.isNetworkUp = up
                self.setOfflineUI(!up)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "inertiaNav",
              let body = message.body as? [String: Any],
              let path = (body["path"] as? String)?.lowercased(),
              !path.isEmpty else { return }

        savedPath = nextPath
        nextPath = path

        if path.hasPrefix("/trans") {
            PushRegistrar.shared.tryRegisterOnNavigation(reason: "spa \(path)")
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavError(error)
    }

    private func handleNavError(_ error: Error) {
        let ns = error as NSError

        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return
        }

        if !isNetworkUp {
            setOfflineUI(true)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme?.lowercased() == "tel" {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
