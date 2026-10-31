import UIKit
import WebKit
import Capacitor

// News Lens's in-app browser.
//
// Capacitor's own web view only hosts the app's local UI (www/index.html). News
// sites open in a separate WKWebView, with lift/lift.js (bundled by `npm run sync`
// into public/lift) injected into every page in an isolated content world: it reads
// the page's DOM, but the site's own scripts can't see or interfere with it.
//
// The reader is drawn outside the site, in a second, app-owned web view layered over
// it that loads only our own www/reader.html. Swiping the bar at the bottom up runs
// the lift and hands the result to that view; the site underneath is paused (media
// suspended, touches off) until the reader is swiped down again.

/// Root view controller (created in SceneDelegate) so the local plugin gets registered.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NewsJuiceBrowserPlugin())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        // `xcrun simctl launch <device> com.buzzie.newslens -NJOpenURL https://...`
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
    /// The app's own reader page, over the site's web view. No site code runs in it.
    private var readerView: WKWebView!
    private let titleLabel = UILabel()
    private let listButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private var canGoBackObservation: NSKeyValueObservation?
    /// Set when a link in the reader opened the current page: lift it once it loads.
    private var liftOnLoad = false
    /// Pages that were showing the reader, so going back to one lifts it again.
    private var liftedPages = Set<String>()
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
        if let file = Bundle.main.url(forResource: "lift", withExtension: "js", subdirectory: "public/lift"),
           let source = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        } else {
            assertionFailure("public/lift/lift.js missing from the bundle: run `npm run sync` in app/")
        }
        // Sites tailor their markup to the user agent; look like Mobile Safari.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        // reader.js saves a site's recipe (the text groups to keep) and reports the
        // reader's state and tapped links through this handler.
        let readerConfig = WKWebViewConfiguration()
        let handler = RecipeHandler()
        handler.browser = self
        readerConfig.userContentController.add(handler, name: "newsJuice")
        readerView = WKWebView(frame: .zero, configuration: readerConfig)
        readerView.isOpaque = false
        readerView.backgroundColor = .clear
        readerView.scrollView.backgroundColor = .clear
        readerView.isHidden = true
        #if DEBUG
        if #available(iOS 16.4, *) { readerView.isInspectable = true }
        #endif
        if let page = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "public") {
            readerView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        let topBar = makeTopBar()
        makeLiftBar()

        for v in [topBar, progress, webView!, readerView!, liftBar] as [UIView] {
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

            readerView.topAnchor.constraint(equalTo: webView.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),

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
        canGoBackObservation = webView.observe(\.canGoBack, options: [.initial]) { [weak self] wv, _ in
            self?.backButton.isHidden = !wv.canGoBack
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
        // Folds the reader's list of text groups away (Hide) and back (Edit). Shown only
        // while the reader is up; reader.js tells us whether its list is open.
        listButton.addAction(UIAction { [weak self] _ in
            self?.readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.togglePanel()")
        }, for: .primaryActionTriggered)
        listButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        listButton.isHidden = true
        backButton.setImage(UIImage(systemName: "chevron.backward",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        backButton.accessibilityLabel = "Back"
        backButton.isHidden = true
        backButton.addAction(UIAction { [weak self] _ in self?.webView.goBack() }, for: .primaryActionTriggered)
        for v in [close, backButton, titleLabel, listButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 14),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            listButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            listButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: bar.widthAnchor, constant: -200),
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
        // lift.js lives in the isolated client world, so that's where it's called.
        let js = "JSON.stringify(window.NewsJuice ? NewsJuice.lift() : { ok: false, reason: 'lift.js not loaded' })"
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let json = value as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                NSLog("NewsJuice lift failed: %@", String(describing: result))
                self.flash("Nothing to lift on this page")
                return
            }
            let groups = obj["groups"] as? [[String: Any]] ?? []
            NSLog("NewsJuice lift %@: %d groups, top %@", self.webView.url?.absoluteString ?? "",
                  groups.count, groups.prefix(4).compactMap { $0["id"] as? String }.joined(separator: " | "))
            self.showReader(json)
        }
    }

    /// Hands a lift result to the app's reader view and pauses the site underneath.
    private func showReader(_ liftJSON: String, attempt: Int = 0) {
        let recipe = webView.url?.host.flatMap(RecipeHandler.recipe(forHost:))
        let recipeJSON = recipe.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let js = "window.NewsJuice ? (NewsJuice.showReader(\(liftJSON), { recipe: \(recipeJSON) }), true) : false"
        readerView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            guard value as? Bool == true else {
                // The reader page is still loading (only possible right after opening).
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showReader(liftJSON, attempt: attempt + 1) }
                }
                return
            }
            self.readerView.isHidden = false
            self.webView.isUserInteractionEnabled = false
            self.webView.pauseAllMediaPlayback()
            self.webView.setAllMediaPlaybackSuspended(true)
            self.readerUp = true
            self.listButton.isHidden = false
            if let url = self.webView.url?.absoluteString { self.liftedPages.insert(url) }
            self.updateLiftLabel()
        }
    }

    private func dropReader() {
        // reader.js closes on Escape.
        readerView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
        readerClosed()
    }

    /// reader.js: a link in the reader was tapped. Open it, and if the site has a
    /// recipe, lift it as soon as it loads so reading carries on in the reader.
    func openFromReader(_ url: URL) {
        liftOnLoad = url.host.flatMap(RecipeHandler.recipe(forHost:)) != nil
        webView.load(URLRequest(url: url))
    }

    private var siteHasRecipe: Bool {
        webView.url?.host.flatMap(RecipeHandler.recipe(forHost:)) != nil
    }

    /// reader.js: the list of text groups was opened or folded.
    func panelChanged(open: Bool) {
        listButton.setTitle(open ? "Hide" : "Edit", for: .normal)
        listButton.isHidden = !readerUp
    }

    /// reader.js: the reader went away (its handle was tapped, or we dropped it).
    /// Wakes the site underneath and hides the reader view once its sheet has slid away.
    func readerClosed() {
        readerUp = false
        listButton.isHidden = true
        webView.isUserInteractionEnabled = true
        webView.setAllMediaPlaybackSuspended(false)
        updateLiftLabel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.readerUp else { return }
            self.readerView.isHidden = true
        }
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
        readerClosed() // a new page starts without the reader
        #if DEBUG
        debugRunDone = false
        #endif
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let backToLifted = webView.url.map { liftedPages.contains($0.absoluteString) } ?? false
        if liftOnLoad || (backToLifted && siteHasRecipe) {
            // A beat for late paragraphs to render before lifting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.readerUp else { return }
                self.lift()
            }
        }
        liftOnLoad = false
        #if DEBUG
        debugFinish()
        #endif
    }

    #if DEBUG
    // Testing hooks, set as launch arguments:
    //   -NJAutoLift <seconds>   lift that long after the page finishes loading and write
    //                           the full result to Documents/lift-<page>.json
    //   -NJCapture YES          then also save a fixture snapshot (test/capture-page.js)
    //                           to Documents/capture-<page>.html
    private var debugRunDone = false

    private func debugFinish() {
        let delay = UserDefaults.standard.double(forKey: "NJAutoLift")
        guard delay > 0, !debugRunDone else { return }
        debugRunDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.debugRun() }
    }

    private func debugRun() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let page = (webView.url.map { ($0.host ?? "") + $0.path } ?? "page")
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .prefix(80)
        let js = "(function () { var t0 = Date.now(); var r = NewsJuice.lift(); r.ms = Date.now() - t0; return JSON.stringify(r, null, 2); })()"
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let json: String
            switch result {
            case .success(let value): json = value as? String ?? "null"
            case .failure(let error): json = "{\"error\": \"\(error.localizedDescription)\"}"
            }
            try? json.write(to: docs.appendingPathComponent("lift-\(page).json"), atomically: true, encoding: .utf8)
            NSLog("NewsJuice debug lift saved lift-%@.json", String(page))
            guard UserDefaults.standard.bool(forKey: "NJCapture"),
                  let file = Bundle.main.url(forResource: "capture-page", withExtension: "js", subdirectory: "public/debug"),
                  let capture = try? String(contentsOf: file, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript(capture) { value, error in
                guard let html = value as? String else {
                    NSLog("NewsJuice capture failed: %@", error?.localizedDescription ?? "unknown")
                    return
                }
                try? html.write(to: docs.appendingPathComponent("capture-\(page).html"), atomically: true, encoding: .utf8)
                NSLog("NewsJuice debug capture saved capture-%@.html", String(page))
            }
        }
    }
    #endif

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

/// Stores each site's recipe (the style groups to keep in the reader) in UserDefaults,
/// keyed by host without "www.", so it applies to every page on that site.
/// Also passes reader.js's panel and reader state on to the browser's top bar.
final class RecipeHandler: NSObject, WKScriptMessageHandler {
    private static let key = "NJRecipes"
    weak var browser: BrowserViewController?

    static func recipe(forHost host: String) -> [String]? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]
        return all?[normalize(host)]
    }

    private static func normalize(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "panel":
            browser?.panelChanged(open: body["open"] as? Bool ?? false)
            return
        case "readerClosed":
            browser?.readerClosed()
            return
        case "navigate":
            if let url = (body["url"] as? String).flatMap(URL.init(string:)) { browser?.openFromReader(url) }
            return
        default:
            break
        }
        guard body["type"] as? String == "saveRecipe",
              let host = body["host"] as? String, let keep = body["keep"] as? [String] else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        all[Self.normalize(host)] = keep
        UserDefaults.standard.set(all, forKey: Self.key)
        NSLog("NewsJuice recipe for %@: %@", host, keep.joined(separator: " | "))
    }
}
