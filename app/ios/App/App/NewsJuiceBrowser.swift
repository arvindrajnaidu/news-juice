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

    private let backButton = UIButton(type: .system)
    private let pageButton = UIButton(type: .system)
    private var canGoBackObservation: NSKeyValueObservation?
    private var lastCounts = (lifted: 0, kinds: 0)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let homeButton = UIButton(type: .system)
    private let changeButton = UIButton(type: .system)
    private let liftButton = UIButton(type: .system)
    /// The app bar under the page that holds the Lift button, so it never covers the site.
    private let bottomBar = UIView()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    /// Set when the next page should open straight in the reader (a link tapped in the
    /// reader, or going back to a page that was lifted): lift it once it loads.
    private var liftOnLoad = false
    /// Pages that were showing the reader, so going back to one lifts it again.
    private var liftedPages = Set<String>()
    /// Whether the start screen has been told which site this browser opened.
    private var siteReported = false
    /// Where the reader's filter came from: "own", "suggested" or "none".
    private var filterSource = "none"

    private static let bar = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.13, green: 0.125, blue: 0.11, alpha: 1)
        : UIColor(red: 0.953, green: 0.937, blue: 0.902, alpha: 1) }
    private static let accent = UIColor(red: 0.91, green: 0.64, blue: 0.09, alpha: 1)
    /// Warm grey for the small icon controls (back, globe, sliders, house).
    private static let iconTint = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1)
        : UIColor(red: 0.42, green: 0.39, blue: 0.345, alpha: 1) }
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
        readerView.scrollView.panGestureRecognizer.require(toFail: edge)

        let topBar = makeTopBar()
        makeLiftButton()
        bottomBar.backgroundColor = Self.bar
        let hairline = UIView()
        hairline.backgroundColor = .separator
        for v in [hairline, liftButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(v)
        }

        // The site sits on top of the reader and slides away to reveal it; the site ends
        // above the bottom bar, the reader runs to the bottom of the screen.
        for v in [readerView!, webView!, topBar, progress, bottomBar] as [UIView] {
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
            webView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            readerView.topAnchor.constraint(equalTo: webView.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -62),

            hairline.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            liftButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            liftButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            liftButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
            liftButton.heightAnchor.constraint(equalToConstant: 46),
        ])

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            self?.progress.setProgress(Float(wv.estimatedProgress), animated: true)
            self?.progress.isHidden = wv.estimatedProgress >= 1
        }
        canGoBackObservation = webView.observe(\.canGoBack) { [weak self] _, _ in
            guard let self else { return }
            self.updateBar(lifted: self.lastCounts.lifted, kinds: self.lastCounts.kinds)
        }
        updateBar(lifted: 0, kinds: 0)
        webView.load(URLRequest(url: startURL))
    }

    /// Back chevron at left (whenever there's a previous page), the site name and what
    /// you're looking at in the middle, and icons on the right: Home on the page, the
    /// original-page globe while picking, the globe and the Change-lift sliders while reading.
    private func makeTopBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = Self.bar
        let rule = UIView()
        rule.backgroundColor = UIColor.separator

        var back = UIButton.Configuration.plain()
        back.image = UIImage(systemName: "chevron.backward",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        back.contentInsets = .zero
        back.baseForegroundColor = Self.iconTint
        backButton.configuration = back
        backButton.accessibilityLabel = "Back"
        backButton.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .primaryActionTriggered)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.text = startURL.host
        titleLabel.textAlignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center

        let iconButton = { (button: UIButton, symbol: String, label: String, action: @escaping () -> Void) in
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol,
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
            c.contentInsets = .zero
            c.baseForegroundColor = Self.iconTint
            button.configuration = c
            button.accessibilityLabel = label
            button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        iconButton(pageButton, "globe", "Show original page") { [weak self] in self?.toPage() }
        iconButton(changeButton, "slider.horizontal.3", "Change filter") { [weak self] in
            self?.readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.setMode('pick')")
        }
        iconButton(homeButton, "house", "Home") { [weak self] in self?.dismiss(animated: true) }
        let right = UIStackView(arrangedSubviews: [pageButton, changeButton, homeButton])
        right.spacing = 0

        for v in [backButton, titles, right, rule] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titles.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titles.widthAnchor.constraint(lessThanOrEqualTo: bar.widthAnchor, constant: -200),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return bar
    }

    /// The full-width amber Filter button in the bar under the page.
    private func makeLiftButton() {
        var c = UIButton.Configuration.filled()
        c.title = "Filter"
        c.image = UIImage(systemName: "line.3.horizontal.decrease",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        c.imagePadding = 8
        c.baseBackgroundColor = Self.accent
        c.baseForegroundColor = Self.ink
        c.background.cornerRadius = 14
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0; a.font = .systemFont(ofSize: 17, weight: .semibold); return a
        }
        liftButton.configuration = c
        liftButton.addAction(UIAction { [weak self] _ in self?.lift() }, for: .primaryActionTriggered)
    }

    /// Shows what the top bar should for the current mode.
    private func updateBar(lifted: Int, kinds: Int) {
        lastCounts = (lifted, kinds)
        backButton.isHidden = !webView.canGoBack
        pageButton.isHidden = mode == .page
        homeButton.isHidden = mode != .page
        changeButton.isHidden = mode != .read
        switch mode {
        case .page: subtitleLabel.text = "Original page"
        case .pick: subtitleLabel.text = "\(lifted) of \(kinds) kinds kept"
        case .read: subtitleLabel.text = filterSource == "suggested" ? "Suggested filter" : "Filtered · saved for this site"
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
                self.flash("Nothing to filter on this page")
                return
            }
            let groups = obj["groups"] as? [[String: Any]] ?? []
            NSLog("NewsJuice lift %@: %d groups, top %@", self.webView.url?.absoluteString ?? "",
                  groups.count, groups.prefix(4).compactMap { $0["id"] as? String }.joined(separator: " | "))
            guard let host = self.webView.url?.host else { self.showReader(json, suggested: nil); return }
            SuggestedFilters.lookup(host: host, article: obj["article"] as? Bool) { [weak self] keep in
                self?.showReader(json, suggested: keep)
            }
        }
    }

    /// Hands a lift result to the reader view, then slides the site away to reveal it.
    /// reader.js opens in Read for a site with a recipe (the user's own, or else a
    /// suggested one) and in Pick for a new one.
    private func showReader(_ liftJSON: String, suggested: [String]?, attempt: Int = 0) {
        let json = { (list: [String]?) in
            list.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        let recipe = webView.url?.host.flatMap(RecipeHandler.recipe(forHost:))
        let js = "window.NewsJuice ? (NewsJuice.showReader(\(liftJSON), " +
            "{ recipe: \(json(recipe)), suggested: \(json(suggested)) }), true) : false"
        readerView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            guard value as? Bool == true else {
                // The reader page is still loading (only possible right after opening).
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showReader(liftJSON, suggested: suggested, attempt: attempt + 1) }
                }
                return
            }
            if let url = self.webView.url?.absoluteString { self.liftedPages.insert(url) }
            self.revealReader()
        }
    }

    /// Slides the site (and the Lift bar) down out of the way and pauses it.
    private func revealReader() {
        readerView.isHidden = false
        webView.pauseAllMediaPlayback()
        webView.setAllMediaPlaybackSuspended(true)
        guard !webView.isHidden else { return }
        let drop = CGAffineTransform(translationX: 0, y: view.bounds.height)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: []) {
            self.webView.transform = drop
            self.webView.alpha = 0
            self.bottomBar.transform = CGAffineTransform(translationX: 0, y: self.bottomBar.bounds.height)
            self.bottomBar.alpha = 0
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
            self.bottomBar.transform = .identity
            self.bottomBar.alpha = 1
        }
        let done = { (_: Bool) in if self.mode == .page { self.readerView.isHidden = true } }
        guard animated else { show(); done(true); return }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [], animations: show, completion: done)
    }

    /// reader.js: it switched between Pick and Read (or the lifted count changed).
    func readerMode(_ name: String, lifted: Int, kinds: Int, source: String) {
        mode = name == "read" ? .read : .pick
        filterSource = source
        updateBar(lifted: lifted, kinds: kinds)
    }

    /// reader.js: a link in the reader was tapped. Open it, and if the site has a
    /// recipe, keep the reader up and lift the new page as soon as it loads.
    func openFromReader(_ url: URL) {
        liftOnLoad = url.host.map(Self.hasFilter) ?? false
        webView.load(URLRequest(url: url))
    }

    @objc private func readerEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        goBack()
    }

    /// The previous page; from the reader it opens lifted again, behind the reader.
    private func goBack() {
        guard webView.canGoBack else { return }
        if mode != .page { liftOnLoad = siteHasRecipe }
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
        webView.url?.host.map(Self.hasFilter) ?? false
    }

    /// Whether a site has a filter of the user's own or a suggested one on hand.
    private static func hasFilter(_ host: String) -> Bool {
        RecipeHandler.recipe(forHost: host) != nil || SuggestedFilters.hasAny(host: host)
    }

    private func flash(_ text: String) {
        liftButton.configuration?.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.liftButton.configuration?.title = "Filter"
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        titleLabel.text = webView.url?.host
        SuggestedFilters.refreshIfStale()
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

    static func normalize(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "mode":
            browser?.readerMode(body["mode"] as? String ?? "pick",
                                lifted: body["lifted"] as? Int ?? 0, kinds: body["kinds"] as? Int ?? 0,
                                source: body["source"] as? String ?? "none")
            return
        case "navigate":
            if let url = (body["url"] as? String).flatMap(URL.init(string:)) { browser?.openFromReader(url) }
            return
        default:
            break
        }
        guard body["type"] as? String == "saveRecipe", let host = body["host"] as? String else { return }
        // No list: the user reset the site to its suggested filter.
        guard let keep = body["keep"] as? [String] else {
            Self.forget(host: host)
            NSLog("NewsJuice recipe for %@ reset", host)
            return
        }
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        all[Self.normalize(host)] = keep
        UserDefaults.standard.set(all, forKey: Self.key)
        NSLog("NewsJuice recipe for %@: %@", host, keep.joined(separator: " | "))
    }
}

/// Suggested filters: one filters.json that Arvind keeps (a public gist; see docs/filters.md),
/// fetched at most once a day with If-None-Match and kept for offline use, with a copy
/// bundled in the app for first launch. The user's own filter (RecipeHandler) always wins.
enum SuggestedFilters {
    /// The gist's raw URL, without a revision hash so it always serves the latest edit.
    static let defaultURL = URL(string: "https://gist.githubusercontent.com/USER/GIST_ID/raw/filters.json")!
    private static let cacheKey = "NJSuggestedFilters"
    private static let maxAge: TimeInterval = 24 * 60 * 60

    static var url: URL {
        #if DEBUG
        // Testing: -NJFiltersURL http://localhost:8787/raw/filters.json (npm run filters:serve).
        if let s = UserDefaults.standard.string(forKey: "NJFiltersURL"), let u = URL(string: s) { return u }
        #endif
        return defaultURL
    }

    /// The parsed downloaded file, else the bundled one.
    private static var sites: [String: Any] = load()
    private static var fetching = false

    private static func load() -> [String: Any] {
        let cached = UserDefaults.standard.dictionary(forKey: cacheKey)?["body"] as? Data
        if let sites = cached.flatMap(parse) { return sites }
        let bundled = Bundle.main.url(forResource: "filters", withExtension: "json", subdirectory: "public/filters")
        return bundled.flatMap { try? Data(contentsOf: $0) }.flatMap(parse) ?? [:]
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["v"] as? Int == 1 else { return nil }
        return obj["sites"] as? [String: Any]
    }

    static func hasAny(host: String) -> Bool {
        sites[RecipeHandler.normalize(host)] != nil
    }

    /// The suggested styles for this site and kind of page: "keep" applies to every page,
    /// "article" / "section" ({ "keep": [...] }) only to that kind.
    private static func keep(host: String, article: Bool?) -> [String]? {
        guard let site = sites[RecipeHandler.normalize(host)] as? [String: Any] else { return nil }
        var keep = site["keep"] as? [String] ?? []
        let kinds = article.map { [$0 ? "article" : "section"] } ?? ["article", "section"]
        for kind in kinds {
            keep += ((site[kind] as? [String: Any])?["keep"] as? [String] ?? []).filter { !keep.contains($0) }
        }
        return keep.isEmpty ? nil : keep
    }

    /// Calls back on the main queue, after a refresh if the copy is a day old (the fetch
    /// gives up after 2 seconds and the copy on hand is used).
    static func lookup(host: String, article: Bool?, completion: @escaping ([String]?) -> Void) {
        refreshIfStale { completion(keep(host: host, article: article)) }
    }

    static func refreshIfStale(then done: (() -> Void)? = nil) {
        let cache = UserDefaults.standard.dictionary(forKey: cacheKey) ?? [:]
        if let checked = cache["checked"] as? Date, Date().timeIntervalSince(checked) < maxAge {
            done?(); return
        }
        guard !fetching else { done?(); return }
        fetching = true
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        if let etag = cache["etag"] as? String { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                fetching = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var cache = cache
                if status == 200, let data, parse(data) != nil {
                    cache["body"] = data
                    cache["etag"] = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
                    cache["checked"] = Date()
                    sites = load()
                } else if status == 304 {
                    cache["checked"] = Date()
                }
                // Anything else (offline, a bad file) keeps what's on hand and tries again next time.
                if status == 200 || status == 304 { UserDefaults.standard.set(cache, forKey: cacheKey) }
                NSLog("NewsJuice suggested filters: %@ -> %d %@", url.absoluteString, status,
                      error?.localizedDescription ?? "")
                done?()
            }
        }.resume()
    }
}
