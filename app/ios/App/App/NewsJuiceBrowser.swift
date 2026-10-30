import UIKit
import WebKit
import Capacitor

// News Juice's in-app browser.
//
// Capacitor's own web view only hosts the app's local UI (www/index.html). News
// sites open in a separate WKWebView that injects lift/lift.js and lift/reader.js
// (bundled by `npm run sync` into public/lift) into every page. Swiping the bar at
// the bottom up runs the lift and slides the clean reader over the page; swiping
// it down drops the reader again.

/// Root view controller (created in SceneDelegate) so the local plugin gets registered.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NewsJuiceBrowserPlugin())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        // `xcrun simctl launch <device> com.nerdylotus.glance -NJOpenURL https://...`
        // opens a page straight away, for testing.
        if let url = UserDefaults.standard.string(forKey: "NJOpenURL").flatMap(URL.init(string:)),
           presentedViewController == nil {
            UserDefaults.standard.removeObject(forKey: "NJOpenURL")
            present(BrowserViewController(url: url), animated: false)
        }
        #endif
    }
}

@objc(NewsJuiceBrowserPlugin)
public class NewsJuiceBrowserPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NewsJuiceBrowserPlugin"
    public let jsName = "NewsJuiceBrowser"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
    ]

    @objc func open(_ call: CAPPluginCall) {
        guard let raw = call.getString("url"), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            call.reject("A http(s) url is required")
            return
        }
        DispatchQueue.main.async {
            self.bridge?.viewController?.present(BrowserViewController(url: url), animated: true)
            call.resolve()
        }
    }
}

final class BrowserViewController: UIViewController, WKNavigationDelegate {
    private let startURL: URL
    private var webView: WKWebView!
    private let titleLabel = UILabel()
    private let liftBar = UIView()
    private let liftLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    private var readerUp = false

    private static let paper = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.10, green: 0.098, blue: 0.086, alpha: 1)
        : UIColor(red: 0.984, green: 0.973, blue: 0.949, alpha: 1) }
    private static let accent = UIColor(red: 0.91, green: 0.64, blue: 0.09, alpha: 1)

    init(url: URL) {
        startURL = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.paper

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        for name in ["lift", "reader"] {
            guard let file = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "public/lift"),
                  let source = try? String(contentsOf: file, encoding: .utf8) else {
                assertionFailure("public/lift/\(name).js missing from the bundle: run `npm run sync` in app/")
                continue
            }
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        // Sites tailor their markup to the user agent; look like Mobile Safari.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        let topBar = makeTopBar()
        makeLiftBar()

        for v in [topBar, progress, webView!, liftBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            progress.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: liftBar.topAnchor),

            liftBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liftBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liftBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            liftBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -52),
        ])
        view.bringSubviewToFront(progress)

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            self?.progress.setProgress(Float(wv.estimatedProgress), animated: true)
            self?.progress.isHidden = wv.estimatedProgress >= 1
        }
        webView.load(URLRequest(url: startURL))
    }

    private func makeTopBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = Self.paper
        let close = UIButton(type: .system, primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.text = startURL.host
        for v in [close, titleLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: bar.widthAnchor, constant: -160),
        ])
        return bar
    }

    /// The bar at the bottom: a grab handle and a label. Swipe it up (or tap it)
    /// to lift; with the reader up, swipe it down (or tap it) to see the page.
    private func makeLiftBar() {
        liftBar.backgroundColor = Self.paper
        liftBar.layer.shadowColor = UIColor.black.cgColor
        liftBar.layer.shadowOpacity = 0.12
        liftBar.layer.shadowRadius = 6
        liftBar.layer.shadowOffset = CGSize(width: 0, height: -2)
        liftBar.accessibilityTraits = .button

        let handle = UIView()
        handle.backgroundColor = Self.accent
        handle.layer.cornerRadius = 2.5
        liftLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        liftLabel.textAlignment = .center
        for v in [handle, liftLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            liftBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: liftBar.topAnchor, constant: 8),
            handle.centerXAnchor.constraint(equalTo: liftBar.centerXAnchor),
            handle.widthAnchor.constraint(equalToConstant: 44),
            handle.heightAnchor.constraint(equalToConstant: 5),
            liftLabel.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 8),
            liftLabel.centerXAnchor.constraint(equalTo: liftBar.centerXAnchor),
        ])
        updateLiftLabel()

        liftBar.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panLiftBar(_:))))
        liftBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapLiftBar)))
    }

    private func updateLiftLabel() {
        liftLabel.text = readerUp ? "Swipe down for the page" : "Swipe up to lift"
        liftBar.accessibilityLabel = readerUp ? "Back to page" : "Lift article"
    }

    @objc private func tapLiftBar() {
        readerUp ? dropReader() : lift()
    }

    @objc private func panLiftBar(_ pan: UIPanGestureRecognizer) {
        let dy = pan.translation(in: view).y
        switch pan.state {
        case .changed:
            // Let the bar follow the finger a little so the gesture feels physical.
            let travel = readerUp ? max(0, min(dy, 30)) : min(0, max(dy, -30))
            liftBar.transform = CGAffineTransform(translationX: 0, y: travel)
        case .ended, .cancelled:
            let vy = pan.velocity(in: view).y
            UIView.animate(withDuration: 0.2) { self.liftBar.transform = .identity }
            guard pan.state == .ended else { return }
            if !readerUp && (dy < -24 || vy < -400) { lift() }
            if readerUp && (dy > 24 || vy > 400) { dropReader() }
        default:
            break
        }
    }

    private func lift() {
        let js = """
        (function () {
          if (!window.NewsJuice || !NewsJuice.lift) return JSON.stringify({ ok: false, reason: 'lift.js not loaded' });
          var t0 = Date.now();
          var r = NewsJuice.lift();
          if (r.ok) NewsJuice.showReader(r);
          return JSON.stringify({ ok: r.ok, reason: r.reason, ms: Date.now() - t0, title: r.title,
            bodySize: r.bodySize, bodyChars: r.bodyChars, pageChars: r.pageChars,
            blocks: r.blocks.length, container: r.container, url: location.href });
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] value, error in
            guard let self else { return }
            let summary = (value as? String) ?? "error: \(error?.localizedDescription ?? "unknown")"
            NSLog("NewsJuice lift %@", summary)
            if let data = summary.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["ok"] as? Bool == true {
                self.readerUp = true
                self.updateLiftLabel()
            } else {
                self.flash("Nothing to lift on this page")
            }
        }
    }

    private func dropReader() {
        // reader.js closes on Escape.
        webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
        readerUp = false
        updateLiftLabel()
    }

    private func flash(_ text: String) {
        let old = liftLabel.text
        liftLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.liftLabel.text == text { self?.liftLabel.text = old }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        titleLabel.text = webView.url?.host
        readerUp = false // a new page starts without the reader
        updateLiftLabel()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        // Keep browsing in here; hand tel:, mailto:, app links etc. to the system.
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            if let url = action.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}
