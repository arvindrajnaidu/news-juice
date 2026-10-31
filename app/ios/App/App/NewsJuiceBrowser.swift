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
// The reader is drawn outside the site, in a second, app-owned web view under it that
// loads only our own www/reader.html. The Lift button runs the lift and hands the
// result to that view, and the site slides away (paused, media suspended) to reveal
// it; "‹ Page" slides the site back.

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
        CAPPluginMethod(name: "forgetSite", returnType: CAPPluginReturnPromise),
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

    /// The start screen removed a site: forget its saved lift choices too.
    @objc func forgetSite(_ call: CAPPluginCall) {
        guard let host = call.getString("host") else { call.reject("host is required"); return }
        RecipeHandler.forget(host: host)
        call.resolve()
    }
}

final class BrowserViewController: UIViewController, WKNavigationDelegate {
    private enum Mode { case page, pick, read }

    private let startURL: URL
    private var webView: WKWebView!
    /// The app's own reader page, under the site's web view. No site code runs in it.
    private var readerView: WKWebView!
    private var mode = Mode.page

    private let pageButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let homeButton = UIButton(type: .system)
    private let changeButton = UIButton(type: .system)
    private let liftButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    /// Set when the next page should open straight in the reader (a link tapped in the
    /// reader, or going back to a page that was lifted): lift it once it loads.
    private var liftOnLoad = false
    /// Pages that were showing the reader, so going back to one lifts it again.
    private var liftedPages = Set<String>()
    /// Whether the start screen has been told which site this browser opened.
    private var siteReported = false

    private static let bar = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.13, green: 0.125, blue: 0.11, alpha: 1)
        : UIColor(red: 0.953, green: 0.937, blue: 0.902, alpha: 1) }
    private static let accent = UIColor(red: 0.91, green: 0.64, blue: 0.09, alpha: 1)
    private static let ink = UIColor(red: 0.114, green: 0.106, blue: 0.094, alpha: 1)

    init(url: URL) {
        startURL = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.bar

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

        // reader.js saves a site's recipe (the text groups to lift) and reports its mode
        // and tapped links through this handler.
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
        // Swiping in from the left edge of the reader goes back a page, like the site.
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(readerEdgeSwipe(_:)))
        edge.edges = .left
        readerView.addGestureRecognizer(edge)

        let topBar = makeTopBar()
        makeLiftButton()

        // The site sits on top of the reader and slides away to reveal it.
        for v in [readerView!, webView!, topBar, progress, liftButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            progress.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            readerView.topAnchor.constraint(equalTo: webView.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),

            liftButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            liftButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            liftButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            liftButton.heightAnchor.constraint(equalToConstant: 54),
        ])

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            self?.progress.setProgress(Float(wv.estimatedProgress), animated: true)
            self?.progress.isHidden = wv.estimatedProgress >= 1
        }
        updateBar(lifted: 0, kinds: 0)
        webView.load(URLRequest(url: startURL))
    }

    /// Site name with what you're looking at underneath; "‹ Page" at left while lifted;
    /// Home on the page, Change while reading.
    private func makeTopBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = Self.bar
        let rule = UIView()
        rule.backgroundColor = UIColor.separator

        var page = UIButton.Configuration.plain()
        page.image = UIImage(systemName: "chevron.backward",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        page.title = "Page"
        page.imagePadding = 2
        page.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        pageButton.configuration = page
        pageButton.addAction(UIAction { [weak self] _ in self?.toPage() }, for: .primaryActionTriggered)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.text = startURL.host
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        let left = UIStackView(arrangedSubviews: [pageButton, titles])
        left.alignment = .center
        left.spacing = 4

        homeButton.configuration = .plain()
        homeButton.setTitle("Home", for: .normal)
        homeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        var change = UIButton.Configuration.filled()
        change.title = "Change"
        change.baseBackgroundColor = .systemBackground
        change.baseForegroundColor = .label
        change.cornerStyle = .capsule
        change.background.strokeColor = UIColor(red: 0.79, green: 0.76, blue: 0.71, alpha: 1)
        change.background.strokeWidth = 1
        change.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0; a.font = .systemFont(ofSize: 15, weight: .semibold); return a
        }
        changeButton.configuration = change
        changeButton.addAction(UIAction { [weak self] _ in
            self?.readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.setMode('pick')")
        }, for: .primaryActionTriggered)

        for v in [left, homeButton, changeButton, rule] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -8),
            homeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            homeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            changeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            changeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            changeButton.heightAnchor.constraint(equalToConstant: 38),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return bar
    }

    /// The full-width amber Lift button floating over the page.
    private func makeLiftButton() {
        var c = UIButton.Configuration.filled()
        c.title = "Lift"
        c.image = UIImage(systemName: "magnifyingglass",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        c.imagePadding = 8
        c.baseBackgroundColor = Self.accent
        c.baseForegroundColor = Self.ink
        c.background.cornerRadius = 16
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0; a.font = .systemFont(ofSize: 17, weight: .semibold); return a
        }
        liftButton.configuration = c
        liftButton.layer.shadowColor = Self.ink.cgColor
        liftButton.layer.shadowOpacity = 0.22
        liftButton.layer.shadowRadius = 12
        liftButton.layer.shadowOffset = CGSize(width: 0, height: 10)
        liftButton.addAction(UIAction { [weak self] _ in self?.lift() }, for: .primaryActionTriggered)
    }

    /// Shows what the top bar should for the current mode.
    private func updateBar(lifted: Int, kinds: Int) {
        pageButton.isHidden = mode == .page
        homeButton.isHidden = mode != .page
        changeButton.isHidden = mode != .read
        switch mode {
        case .page: subtitleLabel.text = "Original page"
        case .pick: subtitleLabel.text = "\(lifted) of \(kinds) kinds lifted"
        case .read: subtitleLabel.text = "Lifted · saved for this site"
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

    /// Hands a lift result to the reader view, then slides the site away to reveal it.
    /// reader.js opens in Read for a site with a recipe and in Pick for a new one.
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
            if let url = self.webView.url?.absoluteString { self.liftedPages.insert(url) }
            self.revealReader()
        }
    }

    /// Slides the site (and the Lift button) down out of the way and pauses it.
    private func revealReader() {
        readerView.isHidden = false
        webView.pauseAllMediaPlayback()
        webView.setAllMediaPlaybackSuspended(true)
        guard !webView.isHidden else { return }
        let drop = CGAffineTransform(translationX: 0, y: view.bounds.height)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: []) {
            self.webView.transform = drop
            self.webView.alpha = 0
            self.liftButton.transform = CGAffineTransform(translationX: 0, y: 140)
            self.liftButton.alpha = 0
        } completion: { _ in
            guard self.mode != .page else { return }
            self.webView.isHidden = true
        }
    }

    /// "‹ Page": slides the original site back up over the reader and wakes it.
    private func toPage(animated: Bool = true) {
        mode = .page
        updateBar(lifted: 0, kinds: 0)
        webView.setAllMediaPlaybackSuspended(false)
        webView.isHidden = false
        let show = {
            self.webView.transform = .identity
            self.webView.alpha = 1
            self.liftButton.transform = .identity
            self.liftButton.alpha = 1
        }
        let done = { (_: Bool) in if self.mode == .page { self.readerView.isHidden = true } }
        guard animated else { show(); done(true); return }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [], animations: show, completion: done)
    }

    /// reader.js: it switched between Pick and Read (or the lifted count changed).
    func readerMode(_ name: String, lifted: Int, kinds: Int) {
        mode = name == "read" ? .read : .pick
        updateBar(lifted: lifted, kinds: kinds)
    }

    /// reader.js: a link in the reader was tapped. Open it, and if the site has a
    /// recipe, keep the reader up and lift the new page as soon as it loads.
    func openFromReader(_ url: URL) {
        liftOnLoad = url.host.flatMap(RecipeHandler.recipe(forHost:)) != nil
        webView.load(URLRequest(url: url))
    }

    @objc private func readerEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .recognized, webView.canGoBack else { return }
        liftOnLoad = siteHasRecipe
        webView.goBack()
    }

    /// Tells the start screen which site was opened (its address after any redirect, and
    /// the site's own name), so a new site joins the list there.
    private func reportSiteOnce() {
        guard !siteReported, let url = webView.url else { return }
        siteReported = true
        let js = """
        JSON.stringify({ url: location.href, name: ((document.querySelector('meta[property="og:site_name"]') ||
          document.querySelector('meta[name="application-name"]') || {}).content || '') })
        """
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
            let info = (try? result.get()) as? String
                ?? "{\"url\": \"\(url.absoluteString)\", \"name\": \"\"}"
            let start = (self?.presentingViewController as? CAPBridgeViewController)?.webView
            start?.evaluateJavaScript("window.siteVisited && siteVisited(\(info))")
        }
    }

    private var siteHasRecipe: Bool {
        webView.url?.host.flatMap(RecipeHandler.recipe(forHost:)) != nil
    }

    private func flash(_ text: String) {
        liftButton.configuration?.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.liftButton.configuration?.title = "Lift"
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        titleLabel.text = webView.url?.host
        // A page opened from the reader stays behind the reader until it's lifted;
        // anything else shows the page.
        if !liftOnLoad && mode != .page { toPage(animated: false) }
        #if DEBUG
        debugRunDone = false
        #endif
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reportSiteOnce()
        let backToLifted = webView.url.map { liftedPages.contains($0.absoluteString) } ?? false
        if liftOnLoad || (backToLifted && siteHasRecipe) {
            // A beat for late paragraphs to render before lifting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.lift() }
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
/// Also passes reader.js's mode and tapped links on to the browser.
final class RecipeHandler: NSObject, WKScriptMessageHandler {
    private static let key = "NJRecipes"
    weak var browser: BrowserViewController?

    static func forget(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[normalize(host)] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

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
        case "mode":
            browser?.readerMode(body["mode"] as? String ?? "pick",
                                lifted: body["lifted"] as? Int ?? 0, kinds: body["kinds"] as? Int ?? 0)
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
