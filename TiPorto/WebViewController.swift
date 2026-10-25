import UIKit
import WebKit
import Network

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class WebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "tiporto.net.monitor")
    private var isNetworkUp: Bool?
    private var showingOfflineStartup = false
    private var failedPageURL: URL?
    private var isReconnecting = false
    private var reconnectTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.limitsNavigationsToAppBoundDomains = true
        config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "inertiaNav")

        let js = """
        (function () {
          if (window.__iosNavHooked) return;
          window.__iosNavHooked = true;
          const authenticationPaths = new Set(['/login', '/login/database', '/verifySMS']);
          let wasOnAuthenticationPage = authenticationPaths.has(location.pathname);
          function post(reason) {
            try {
              const onAuthenticationPage = authenticationPaths.has(location.pathname);
              const authenticationCompleted = wasOnAuthenticationPage && !onAuthenticationPage
                && (location.pathname === '/Home' || location.pathname.startsWith('/Transports/'));
              wasOnAuthenticationPage = onAuthenticationPage;
              window.webkit.messageHandlers.inertiaNav.postMessage({
                action: authenticationCompleted ? 'authCompleted' : 'navigation',
                path: location.pathname,
                href: location.href,
                offline: navigator.onLine === false || document.documentElement.classList.contains('tp-offline'),
                reason: reason
              });
            } catch (e) {}
          }
          document.addEventListener('click', function (event) {
            if (!document.documentElement.classList.contains('tp-offline')
                || !event.target.closest?.('[role="status"] button')) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            window.webkit.messageHandlers.inertiaNav.postMessage({action: 'retryOffline'});
          }, true);
          document.addEventListener('inertia:navigate', () => post('inertia:navigate'));
          document.addEventListener('inertia:finish', () => post('inertia:finish'));
          window.addEventListener('popstate', () => post('popstate'));
          const pushState = history.pushState;
          history.pushState = function () {
            const result = pushState.apply(this, arguments);
            post('history.pushState');
            return result;
          };
          const replaceState = history.replaceState;
          history.replaceState = function () {
            const result = replaceState.apply(this, arguments);
            post('history.replaceState');
            return result;
          };
          post('init');
        })();
        """
        config.userContentController.addUserScript(WKUserScript(
            source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .none
        webView.scrollView.alwaysBounceVertical = true

        let root = UIView()
        root.backgroundColor = .white
        root.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        additionalSafeAreaInsets = .zero
        PushRegistrar.shared.setWebView(webView)
        startNetworkMonitor()
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.startReconnectTimer()
                    self?.retryOfflinePageIfNeeded()
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stopReconnectTimer() }
            },
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restoreWebViewAfterKeyboardDismissal()
                }
            }
        ]
        webView.load(URLRequest(url: AppConfig.homeURL))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startReconnectTimer()
        retryOfflinePageIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        stopReconnectTimer()
        super.viewDidDisappear(animated)
    }

    deinit {
        reconnectTimer?.invalidate()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "inertiaNav")
        monitor.cancel()
    }

    private func restoreWebViewAfterKeyboardDismissal() {
        // WebKit updates its viewport asynchronously after the keyboard disappears.
        // Wait one run-loop turn, then remove only stale native insets. Keep a valid
        // content offset so dismissing the keyboard does not move the notes field.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()

            let scrollView = self.webView.scrollView
            scrollView.contentInset = .zero
            scrollView.scrollIndicatorInsets = .zero

            let minimumY = -scrollView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let restoredY = min(max(scrollView.contentOffset.y, minimumY), maximumY)
            if restoredY != scrollView.contentOffset.y {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: restoredY),
                    animated: false
                )
            }

            self.webView.setNeedsLayout()
            self.webView.layoutIfNeeded()
        }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = path.status == .satisfied
                let changed = self.isNetworkUp != available
                self.isNetworkUp = available
                if changed {
                    self.notifyNetworkState()
                }
                if available { self.retryOfflinePageIfNeeded() }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func notifyNetworkState() {
        guard !showingOfflineStartup, let isNetworkUp, AppConfig.isTrustedURL(webView.url) else { return }
        let available = isNetworkUp ? "true" : "false"
        webView.evaluateJavaScript("""
        window.__TiPortoNativeNetworkOnline = \(available);
        if (!\(available)) window.dispatchEvent(new Event('offline'));
        """, completionHandler: nil)
    }

    private func startReconnectTimer() {
        stopReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.retryOfflinePageIfNeeded() }
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func retryOfflinePageIfNeeded() {
        guard !isReconnecting, UIApplication.shared.applicationState == .active else { return }
        if showingOfflineStartup {
            retryCurrentPage()
            return
        }
        guard AppConfig.isTrustedURL(webView.url) else { return }
        webView.evaluateJavaScript("document.documentElement.classList.contains('tp-offline')") { [weak self] result, _ in
            guard let self, result as? Bool == true else { return }
            self.retryCurrentPage(evenIfUnreachable: false)
        }
    }

    private func retryCurrentPage(at requestedURL: URL? = nil, evenIfUnreachable: Bool = true) {
        let targetURL = showingOfflineStartup ? failedPageURL : requestedURL ?? webView.url
        guard !isReconnecting, let url = targetURL, AppConfig.isTrustedURL(url) else { return }
        if showingOfflineStartup {
            loadCurrentPage(at: url)
            return
        }
        let probe = """
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 5000);
        try {
          const response = await fetch(url, {
            method: 'HEAD', cache: 'no-store', credentials: 'same-origin', mode: 'same-origin',
            signal: controller.signal
          });
          return response.status >= 200 && response.status < 500
            && new URL(response.url).origin === location.origin;
        } catch (_) {
          return false;
        } finally {
          clearTimeout(timeout);
        }
        """
        let previousURL = webView.url
        isReconnecting = true
        webView.callAsyncJavaScript(probe, arguments: ["url": url.absoluteString], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.isReconnecting = false
            guard UIApplication.shared.applicationState == .active, self.webView.url == previousURL else { return }
            let reachable: Bool
            switch result {
            case .success(let value): reachable = value as? Bool == true
            case .failure: reachable = false
            }
            if reachable { self.isNetworkUp = true }
            if reachable || evenIfUnreachable { self.loadCurrentPage(at: url) }
        }
    }

    private func loadCurrentPage(at url: URL) {
        showingOfflineStartup = false
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        webView.load(request)
    }

    private func showOfflineStartup(for url: URL) {
        guard !showingOfflineStartup, AppConfig.isTrustedURL(url),
              let asset = Bundle.main.url(forResource: "offline-startup", withExtension: "html"),
              let html = try? String(contentsOf: asset, encoding: .utf8) else { return }
        failedPageURL = url
        showingOfflineStartup = true
        webView.loadHTMLString(html, baseURL: AppConfig.homeURL)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "inertiaNav", message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any] else { return }
        if showingOfflineStartup, body["action"] as? String == "retryOffline" {
            retryCurrentPage()
            return
        }
        guard AppConfig.isTrustedURL(message.frameInfo.request.url) else { return }
        if body["action"] as? String == "retryOffline" {
            retryCurrentPage()
            return
        }
        if body["action"] as? String == "authCompleted", let href = body["href"] as? String,
           let url = URL(string: href), AppConfig.isTrustedURL(url) {
            retryCurrentPage(at: url)
            return
        }
        guard isNetworkUp == true,
              body["offline"] as? Bool != true,
              let path = body["path"] as? String, path.lowercased().hasPrefix("/trans") else { return }
        PushRegistrar.shared.tryRegisterOnNavigation(reason: "spa \(path)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !showingOfflineStartup, AppConfig.isTrustedURL(webView.url) else { return }
        failedPageURL = nil
        if let isNetworkUp {
            let available = isNetworkUp ? "true" : "false"
            webView.evaluateJavaScript("window.__TiPortoNativeNetworkOnline = \(available);", completionHandler: nil)
            if !isNetworkUp { notifyNetworkState() }
            if isNetworkUp { PushRegistrar.shared.tryRegisterOnNavigation(reason: "page finished") }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        let url = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? AppConfig.homeURL
        showOfflineStartup(for: url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        if showingOfflineStartup, url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if !AppConfig.isTrustedURL(url) {
            if ["https", "http", "tel", "mailto", "sms"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
            return
        }
        if isNetworkUp == false && !AppConfig.isReadOnlyMethod(navigationAction.request.httpMethod) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
