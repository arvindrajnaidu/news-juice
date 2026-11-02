import UIKit
import WebKit
import Capacitor
import AVFoundation
import MediaPlayer
import NaturalLanguage
import FirebaseAppCheck
import CryptoKit

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
    #if DEBUG
    private static var openedLaunchURL = false
    #endif

    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NewsJuiceBrowserPlugin())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ShareLinks.showPending()
        #if DEBUG
        // `xcrun simctl launch <device> com.buzzie.newslens -NJOpenURL https://...`
        // opens a page straight away, for testing.
        // (Once: a launch argument can't be removed from UserDefaults.)
        if !Self.openedLaunchURL, let url = UserDefaults.standard.string(forKey: "NJOpenURL").flatMap(URL.init(string:)),
           presentedViewController == nil {
            Self.openedLaunchURL = true
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

final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    /// page: the site; select: picking the filter on the site itself (pick.js);
    /// pick: the card list in the reader; read: the filtered article.
    private enum Mode { case page, select, pick, read }

    private let startURL: URL
    private var webView: WKWebView!
    /// The app's own reader page, under the site's web view. No site code runs in it.
    private var readerView: WKWebView!
    private var mode = Mode.page

    private let backButton = UIButton(type: .system)
    private var canGoBackObservation: NSKeyValueObservation?
    private var lastCounts = (lifted: 0, kinds: 0)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let changeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let textButton = UIButton(type: .system)
    /// Back buttons in the bottom bars (the page's, next to Filter, and the reading
    /// toolbar's); the top bar's back is only for picking.
    private let pageBack = UIButton(type: .system)
    private let readBack = UIButton(type: .system)
    /// The reading view's toolbar: back, Listen, share, text size, edit filter.
    private let readerBar = UIView()
    /// Original | Filtered: switches views. The magnifier is only for building the filter.
    private let viewSwitch = UISegmentedControl(items: ["Original", "Filtered"])
    private var titlesAfterBack: NSLayoutConstraint!
    private var titlesAtEdge: NSLayoutConstraint!
    /// Where Cancel (or back) in picking returns to.
    private var pickReturn = Mode.page
    /// Reads the filtered page aloud; its player sits at the bottom while it's on.
    private let narrator = Narrator()
    private let player = PlayerBar()
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
    /// Set while a navigation the app asked for (a link tapped in the reader) is under way.
    /// While the reader is up, the site can't navigate on its own (redirects, auto-refresh,
    /// reloads); only these, and going back or forward, get through.
    private var appNavigation = false
    /// How many articles deep the reader is from links followed inside it; back walks
    /// these, then leaves the filtered view for the original page.
    private var readerTrail = 0
    /// The last lift result (JSON), what the on-page picker works from.
    private var lastLift: String?
    private var lastSuggested: [String]?
    /// On-page picking: the groups in the filter so far, and how many groups the page has.
    private var pickKeep: [String] = []
    private var pickGroups = 0
    private let pickBar = PickBar()
    private var bottomBarHeight: NSLayoutConstraint!
    private var textSizeObserver: NSObjectProtocol?
    /// Drives the slide back to Home while the edge swipe is under way.
    private var homeSwipe: UIPercentDrivenInteractiveTransition?
    /// Where the reader's filter came from: "own", "suggested" or "none".
    private var filterSource = "none"

    private static let bar = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.13, green: 0.125, blue: 0.11, alpha: 1)
        : UIColor(red: 0.953, green: 0.937, blue: 0.902, alpha: 1) }
    /// Deep teal for the main actions (white on it); highlighter yellow only marks picked text.
    private static let accent = UIColor(red: 0.122, green: 0.435, blue: 0.42, alpha: 1)
    /// Warm grey for the small icon controls (back, globe, sliders, house).
    private static let iconTint = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1)
        : UIColor(red: 0.42, green: 0.39, blue: 0.345, alpha: 1) }
    private static let ink = UIColor(red: 0.114, green: 0.106, blue: 0.094, alpha: 1)

    /// filter: filter the first page as soon as it loads (a shared filter was just added).
    init(url: URL, filter: Bool = false) {
        startURL = url
        super.init(nibName: nil, bundle: nil)
        // A site with a filter (the user's or a suggested one) opens straight in the filtered view.
        liftOnLoad = filter || url.host.map(Self.hasFilter) ?? false
        modalPresentationStyle = .fullScreen
        transitioningDelegate = SideSlide.shared
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let textSizeObserver { NotificationCenter.default.removeObserver(textSizeObserver) }
    }

    /// Lets go of the page and reader when the browser closes: their script handlers
    /// (held by WebKit, not by us), audio and any picking on the page.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        stopListening()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        readerView?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.bar

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Sign-in buttons (Sign in with Google and the like) open their window from script.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let file = Bundle.main.url(forResource: "lift", withExtension: "js", subdirectory: "public/lift"),
           let source = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        } else {
            assertionFailure("public/lift/lift.js missing from the bundle: run `npm run sync` in app/")
        }
        if let file = Bundle.main.url(forResource: "pick", withExtension: "js", subdirectory: "public/lift"),
           let source = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        // pick.js (in the same isolated world) reports each tap on the page here.
        let pickHandler = RecipeHandler()
        pickHandler.browser = self
        config.userContentController.add(pickHandler, contentWorld: .defaultClient, name: "njPick")
        // Sites tailor their markup to the user agent; look like Mobile Safari.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let pageEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pageEdgeSwipe(_:)))
        pageEdge.edges = .left
        webView.addGestureRecognizer(pageEdge)
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
        for v in [hairline, pageBack, liftButton, pickBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(v)
        }
        pickBar.isHidden = true
        pickBar.onStart = { [weak self] in self?.finishPicking() }
        pickBar.onCancel = { [weak self] in self?.cancelPicking() }

        // The site sits on top of the reader and slides away to reveal it; the site ends
        // above the bottom bar, the reader runs to the bottom of the screen.
        makeReaderBar()
        // The reader sits above the page and slides in over it from the right.
        for v in [webView!, bottomBar, readerView!, readerBar, player, topBar, progress] as [UIView] {
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

            hairline.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            // Same spots as the reading toolbar: back at the left, the magnifier centred.
            pageBack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            pageBack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),
            pageBack.widthAnchor.constraint(equalToConstant: 44),
            pageBack.heightAnchor.constraint(equalToConstant: 44),
            liftButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            liftButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 4),
            liftButton.widthAnchor.constraint(equalToConstant: 56),
            liftButton.heightAnchor.constraint(equalToConstant: 44),

            pickBar.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            pickBar.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            pickBar.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),

            player.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            readerBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -52),

            // The Listen player sits just above the reading toolbar.
            player.bottomAnchor.constraint(equalTo: readerBar.topAnchor),
            player.heightAnchor.constraint(equalToConstant: 76),
        ])
        player.isHidden = true
        bottomBarHeight = bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -52)
        bottomBarHeight.isActive = true
        player.onPlayPause = { [weak self] in self?.narrator.togglePause() }
        player.onPrevious = { [weak self] in self?.narrator.skip(by: -1) }
        player.onNext = { [weak self] in self?.narrator.skip(by: 1) }
        player.onSpeed = { [weak self] in self?.narrator.nextSpeed() }
        player.onClose = { [weak self] in self?.stopListening() }
        narrator.onPart = { [weak self] i in
            self?.readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.speaking(\(i.map(String.init) ?? "null"))")
        }
        narrator.onChange = { [weak self] in
            guard let self else { return }
            self.player.update(playing: self.narrator.isPlaying, speed: self.narrator.speed, ai: self.narrator.usingAI)
            if !self.narrator.isOn { self.stopListening() }
        }

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            self?.progress.setProgress(Float(wv.estimatedProgress), animated: true)
            self?.progress.isHidden = wv.estimatedProgress >= 1
        }
        canGoBackObservation = webView.observe(\.canGoBack) { [weak self] _, _ in
            guard let self else { return }
            self.updateBar(lifted: self.lastCounts.lifted, kinds: self.lastCounts.kinds)
        }
        updateBar(lifted: 0, kinds: 0)
        textSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyTextStyle()
        }
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
        backButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(backHeld(_:))))
        for b in [pageBack, readBack] {
            b.configuration = back
            b.accessibilityLabel = "Back"
            b.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .primaryActionTriggered)
            b.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(backHeld(_:))))
        }

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.text = startURL.host
        titleLabel.textAlignment = .left
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .left
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .leading

        viewSwitch.selectedSegmentTintColor = Self.accent
        viewSwitch.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .selected)
        viewSwitch.setTitleTextAttributes([.foregroundColor: Self.iconTint, .font: UIFont.systemFont(ofSize: 13, weight: .medium)], for: .normal)
        viewSwitch.selectedSegmentIndex = 0
        viewSwitch.addAction(UIAction { [weak self] _ in self?.switchView() }, for: .valueChanged)

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
        iconButton(changeButton, "magnifyingglass", "Edit filter") { [weak self] in self?.editOnPage() }
        iconButton(shareButton, "square.and.arrow.up", "Share filter") { [weak self] in self?.shareFilter() }
        iconButton(listenButton, "headphones", "Listen") { [weak self] in self?.listen() }
        iconButton(textButton, "textformat.size", "Text size") {}
        textButton.showsMenuAsPrimaryAction = true
        textButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.textMenuItems() ?? [])
        }])
        let right = UIStackView(arrangedSubviews: [viewSwitch])
        right.spacing = 0

        for v in [backButton, titles, right, rule] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        titlesAfterBack = titles.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4)
        titlesAtEdge = titles.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20)
        titlesAtEdge.isActive = true
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            // Site name on the left (after back while picking), the view switch on the right.
            titles.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -10),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return bar
    }

    /// The full-width Filter button in the bar under the page.
    /// The magnifying glass: the app's main action, teal and a little larger than the
    /// other icons, in the middle of the bottom bar (Filter on the page, Edit filter in
    /// the reader), so it's always in the same place.
    private static func styleMagnifier(_ button: UIButton) {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: "magnifyingglass",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))
        c.contentInsets = .zero
        c.baseForegroundColor = Self.accent
        button.configuration = c
    }

    private func makeLiftButton() {
        Self.styleMagnifier(liftButton)
        liftButton.accessibilityLabel = "Build filter"
        liftButton.addAction(UIAction { [weak self] _ in self?.buildOnPage() }, for: .primaryActionTriggered)
    }

    /// Shows what the top bar should for the current mode.
    private func updateBar(lifted: Int, kinds: Int) {
        lastCounts = (lifted, kinds)
        // One stack: Home, the site's pages, the filtered view. Back always has somewhere
        // to go; holding it goes straight Home.
        backButton.accessibilityLabel = mode != .page ? (readerTrail > 0 ? "Previous article" : "Original page")
            : webView.canGoBack ? "Back" : "Your sites"
        // Page and reading view have back in their bottom bars; picking keeps it on top.
        backButton.isHidden = mode == .page || mode == .read
        readerBar.isHidden = mode != .read
        pageBack.isHidden = mode != .page
        changeButton.isHidden = mode != .read
        shareButton.isHidden = mode == .page || mode == .select
        listenButton.isEnabled = !narrator.isOn
        textButton.isHidden = mode != .read
        viewSwitch.isHidden = mode == .select || mode == .pick
        viewSwitch.selectedSegmentIndex = mode == .read ? 1 : 0
        viewSwitch.setEnabled(mode == .read || siteHasRecipe, forSegmentAt: 1)
        titlesAtEdge.isActive = !(mode == .select || mode == .pick)
        titlesAfterBack.isActive = mode == .select || mode == .pick
        switch mode {
        case .page: subtitleLabel.text = "Original page"
        case .pick, .select: subtitleLabel.text = "\(lifted) of \(kinds) styles in filter"
        case .read: subtitleLabel.text = filterSource == "suggested" ? "Suggested filter" : "Saved for this site"
        }
    }

    /// Lifts the page, then shows it filtered: a site with a filter (the user's or a
    /// suggested one) reads straight away; a new one is picked on the page itself.
    private func lift() {
        liftPage { [weak self] json, keep in
            guard let self, let host = self.webView.url?.host else { return }
            if RecipeHandler.recipe(forHost: host) != nil || keep != nil {
                self.showReader(json, suggested: keep)
            } else {
                self.pickReturn = .page
                self.startPicking(keep: nil, coach: true)
            }
        }
    }

    /// Runs lift.js on the page and looks up the site's suggested filter.
    private func liftPage(then next: @escaping (_ json: String, _ suggested: [String]?) -> Void) {
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
            self.lastLift = json
            guard let host = self.webView.url?.host else { next(json, nil); return }
            SuggestedFilters.lookup(host: host, article: obj["article"] as? Bool) { [weak self] keep in
                self?.lastSuggested = keep
                next(json, keep)
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
        lastLift = liftJSON
        lastSuggested = suggested
        let recipe = webView.url?.host.flatMap(RecipeHandler.recipe(forHost:))
        let js = "window.NewsJuice ? (NewsJuice.showReader(\(liftJSON), " +
            "{ recipe: \(json(recipe)), suggested: \(json(suggested)) }), true) : false"
        readerView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            guard value as? Bool == true else {
                // The reader page is still loading (only possible right after opening).
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.showReader(liftJSON, suggested: suggested, attempt: attempt + 1)
                    }
                }
                return
            }
            if let url = self.webView.url?.absoluteString { self.liftedPages.insert(url) }
            self.applyTextStyle()
            self.revealReader()
        }
    }

    /// Slides the site (and the Lift bar) down out of the way and pauses it.
    private func revealReader() {
        readerView.isHidden = false
        webView.pauseAllMediaPlayback()
        webView.setAllMediaPlaybackSuspended(true)
        guard !webView.isHidden else { return }
        // Like a push: the reader slides in from the right over the page, which eases left.
        let width = view.bounds.width
        let still = UIAccessibility.isReduceMotionEnabled
        readerView.transform = still ? .identity : CGAffineTransform(translationX: width, y: 0)
        readerView.alpha = still ? 0 : 1
        readerBar.alpha = 0
        UIView.animate(withDuration: still ? 0.25 : 0.4, delay: 0, options: [.curveEaseOut]) {
            self.readerView.transform = .identity
            self.readerView.alpha = 1
            self.readerBar.alpha = 1
            if !still {
                self.webView.transform = CGAffineTransform(translationX: -width * 0.3, y: 0)
                self.bottomBar.transform = CGAffineTransform(translationX: -width * 0.3, y: 0)
            }
            self.bottomBar.alpha = 0
        } completion: { _ in
            guard self.mode != .page else { return }
            self.webView.isHidden = true
        }
    }

    /// "‹ Page": slides the original site back up over the reader and wakes it.
    private func toPage(animated: Bool = true) {
        stopListening()
        endPicking()
        readerTrail = 0
        mode = .page
        updateBar(lifted: 0, kinds: 0)
        webView.setAllMediaPlaybackSuspended(false)
        webView.isHidden = false
        let width = view.bounds.width
        let still = UIAccessibility.isReduceMotionEnabled
        let show = {
            self.webView.transform = .identity
            self.webView.alpha = 1
            self.bottomBar.transform = .identity
            self.bottomBar.alpha = 1
            // The reader slides back out to the right (or fades, with Reduce Motion).
            if still { self.readerView.alpha = 0 } else { self.readerView.transform = CGAffineTransform(translationX: width, y: 0) }
        }
        let done = { (_: Bool) in
            // Picking may already have started on the page by now; the reader stays hidden
            // unless something brought it back.
            if self.mode != .read { self.readerView.isHidden = true }
            self.readerView.transform = .identity
            self.readerView.alpha = 1
        }
        guard animated else { show(); done(true); return }
        UIView.animate(withDuration: still ? 0.25 : 0.4, delay: 0, options: [.curveEaseOut],
                       animations: show, completion: done)
    }

    // MARK: Picking on the page

    /// Puts the page into picking mode (pick.js): keep is the filter to start from, or
    /// nil for a first guess (the suggested filter, else the main text and headline).
    private func startPicking(keep: [String]?, coach: Bool, startFrom: [String]? = nil) {
        guard let lift = lastLift else { return }
        let from = startFrom ?? lastSuggested
        let json = { (v: Any?) in
            v.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        readerView.evaluateJavaScript("JSON.stringify(NewsJuice.pickPrep(\(lift), \(json(from))))") { [weak self] value, _ in
            guard let self, let text = value as? String, let data = text.data(using: .utf8),
                  let prep = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kinds = prep["kinds"] as? [String: String] else { return }
            self.pickKeep = keep ?? prep["keep"] as? [String] ?? []
            self.pickGroups = kinds.count
            let js = "NewsJuice.pickStart({ keep: \(json(self.pickKeep)), kinds: \(json(kinds)) })"
            self.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
            self.mode = .select
            self.liftButton.isHidden = true
            self.pickBar.isHidden = false
            self.pickBar.update(count: self.pickKeep.count, hint: nil)
            self.bottomBarHeight.constant = -PickBar.height
            UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
            self.updateBar(lifted: self.pickKeep.count, kinds: self.pickGroups)
            if coach { CoachCard.showOnce(in: self.view) }
        }
    }

    /// pick.js: a style was tapped on the page.
    func pickToggled(kind: String, on: Bool, spots: Int, keep: [String]) {
        guard mode == .select else { return }
        pickKeep = keep
        let place = spots == 1 ? "1 spot" : "\(spots) spots"
        pickBar.update(count: keep.count, hint: "\(on ? "Added" : "Removed") \(kind) · \(place) on this page")
        updateBar(lifted: keep.count, kinds: pickGroups)
    }

    /// Leaves picking mode without touching the saved filter.
    private func endPicking() {
        guard mode == .select || !pickBar.isHidden else { return }
        webView.evaluateJavaScript("window.NewsJuice && NewsJuice.pickStop && NewsJuice.pickStop()", in: nil, in: .defaultClient) { _ in }
        pickBar.isHidden = true
        liftButton.isHidden = false
        CoachCard.dismiss(in: view)
        bottomBarHeight.constant = -52
        if mode == .select { mode = .page }
    }

    /// Cancel (or back) while picking: back to where picking started, nothing saved.
    private func cancelPicking() {
        endPicking()
        updateBar(lifted: 0, kinds: 0)
        if pickReturn == .read, let lift = lastLift { showReader(lift, suggested: lastSuggested) }
    }

    /// The site's saved groups for its other kinds of page, which picking here leaves alone.
    private var groupsElsewhere: [String] {
        guard let host = webView.url?.host, let saved = RecipeHandler.recipe(forHost: host),
              let lift = lastLift, let data = lift.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let here = Set(((obj["groups"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        return saved.filter { !here.contains($0) }
    }

    /// Start reading: save the filter and show the filtered page.
    private func finishPicking() {
        guard mode == .select, !pickKeep.isEmpty, let lift = lastLift, let host = webView.url?.host else { return }
        RecipeHandler.save(host: host, keep: groupsElsewhere + pickKeep)
        endPicking()
        showReader(lift, suggested: lastSuggested)
    }

    /// The magnifier in the reader: edit the filter on the page, starting from the picks.
    private func editOnPage() {
        stopListening()
        readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.currentKeep()") { [weak self] value, _ in
            guard let self else { return }
            let keep = value as? [String]
            self.toPage()
            self.pickReturn = .read
            self.startPicking(keep: keep, coach: false)
        }
    }

    /// The magnifier on the page: build (or edit) the filter on the page itself, starting
    /// from the site's filter, or the suggested one, or a first guess.
    private func buildOnPage() {
        liftPage { [weak self] json, suggested in
            guard let self else { return }
            self.pickReturn = .page
            let own = self.webView.url?.host.flatMap(RecipeHandler.recipe(forHost:))
            self.startPicking(keep: nil, coach: own == nil && suggested == nil, startFrom: own ?? suggested)
        }
    }

    /// Original | Filtered.
    private func switchView() {
        if viewSwitch.selectedSegmentIndex == 0 {
            if mode == .read { toPage() }
        } else if mode == .page {
            lift()
        }
    }

    /// reader.js: it switched between Pick and Read (or the lifted count changed).
    func readerMode(_ name: String, lifted: Int, kinds: Int, source: String) {
        guard mode != .select else { return }
        mode = name == "read" ? .read : .pick
        if mode != .read { stopListening() }
        filterSource = source
        updateBar(lifted: lifted, kinds: kinds)
    }

    /// reader.js: a link in the reader was tapped. Open it, and if the site has a
    /// recipe, keep the reader up and lift the new page as soon as it loads.
    func openFromReader(_ url: URL) {
        stopListening()
        readerTrail += 1
        liftOnLoad = url.host.map(Self.hasFilter) ?? false
        appNavigation = true
        webView.load(URLRequest(url: url))
    }

    /// Swiping in from the left edge of the reader. Back to the original page follows
    /// the finger (the reader slides off to the right as you drag); back to a previous
    /// filtered article just goes back once the swipe ends.
    @objc private func readerEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let width = view.bounds.width
        let interactive = mode == .read && readerTrail == 0 && !UIAccessibility.isReduceMotionEnabled
        guard interactive else {
            if gesture.state == .ended { goBack() }
            return
        }
        let dx = max(0, gesture.translation(in: view).x)
        let progress = min(1, dx / width)
        switch gesture.state {
        case .began:
            webView.isHidden = false
            webView.transform = CGAffineTransform(translationX: -width * 0.3, y: 0)
        case .changed:
            readerView.transform = CGAffineTransform(translationX: dx, y: 0)
            readerBar.transform = CGAffineTransform(translationX: dx, y: 0)
            webView.transform = CGAffineTransform(translationX: -width * 0.3 * (1 - progress), y: 0)
            bottomBar.transform = webView.transform
            bottomBar.alpha = progress
        case .ended, .cancelled:
            let finish = gesture.state == .ended && (progress > 1 / 3 || gesture.velocity(in: view).x > 600)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                if finish {
                    self.readerView.transform = CGAffineTransform(translationX: width, y: 0)
                    self.readerBar.transform = self.readerView.transform
                    self.webView.transform = .identity
                    self.bottomBar.transform = .identity
                    self.bottomBar.alpha = 1
                } else {
                    self.readerView.transform = .identity
                    self.readerBar.transform = .identity
                    self.webView.transform = CGAffineTransform(translationX: -width * 0.3, y: 0)
                    self.bottomBar.transform = self.webView.transform
                    self.bottomBar.alpha = 0
                }
            } completion: { _ in
                self.readerBar.transform = .identity
                if finish {
                    self.toPage(animated: false)
                } else {
                    self.webView.isHidden = true
                }
            }
        default:
            break
        }
    }

    /// Back. In the filtered view: the previous filtered article if a link was followed
    /// in the reader (it opens filtered again, behind the reader), else the original page.
    /// On the original page: the browser's previous page, and from the first one, Home.
    private func goBack() {
        if mode == .select { cancelPicking(); return }
        if mode != .page {
            guard readerTrail > 0, webView.canGoBack else { toPage(); return }
            readerTrail -= 1
        }
        guard webView.canGoBack else { goHome(); return }
        stopListening()
        if mode != .page { liftOnLoad = siteHasRecipe }
        appNavigation = true
        webView.goBack()
    }

    /// Back to the list of sites.
    private func goHome() {
        stopListening()
        endPicking()
        dismiss(animated: true)
    }

    @objc private func backHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        goHome()
    }

    /// Swiping in from the left edge of the page with no history left goes Home (the
    /// web view's own swipe handles going back while there's history).
    /// The page slides off to the right, back to Home, following the finger.
    @objc private func pageEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let progress = min(1, max(0, gesture.translation(in: view).x / view.bounds.width))
        switch gesture.state {
        case .began:
            guard mode == .page, !webView.canGoBack else { return }
            homeSwipe = UIPercentDrivenInteractiveTransition()
            SideSlide.shared.interaction = homeSwipe
            stopListening()
            dismiss(animated: true)
        case .changed:
            homeSwipe?.update(progress)
        case .ended, .cancelled:
            guard let swipe = homeSwipe else { return }
            if gesture.state == .ended && (progress > 1 / 3 || gesture.velocity(in: view).x > 600) {
                swipe.finish()
            } else {
                swipe.cancel()
            }
            homeSwipe = nil
            SideSlide.shared.interaction = nil
        default:
            break
        }
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

    /// Shares the filter as it stands (the picks on screen, plus the site's picks for its
    /// other kinds of page) as a link; see ShareLinks.
    private func shareFilter() {
        guard let host = webView.url?.host else { return }
        readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.currentRecipe()") { [weak self] value, _ in
            guard let self, let keep = value as? [String], !keep.isEmpty,
                  let link = ShareLinks.link(host: host, keep: keep) else { return }
            let site = RecipeHandler.normalize(host)
            NSLog("NewsJuice sharing %@", link.absoluteString)
            let sheet = UIActivityViewController(
                activityItems: ["My News Lens filter for \(site): just the text worth reading.", link],
                applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.shareButton
            self.present(sheet, animated: true)
        }
    }

    /// The reading view's toolbar along the bottom: back, then the reading tools.
    private func makeReaderBar() {
        readerBar.backgroundColor = Self.bar
        readerBar.isHidden = true
        let rule = UIView()
        rule.backgroundColor = .separator
        Self.styleMagnifier(changeButton)
        let tools = UIStackView(arrangedSubviews: [readBack, listenButton, changeButton, shareButton, textButton])
        tools.distribution = .equalSpacing
        tools.alignment = .center
        for v in [rule, tools] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            readerBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: readerBar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: readerBar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: readerBar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            tools.topAnchor.constraint(equalTo: readerBar.topAnchor, constant: 4),
            tools.heightAnchor.constraint(equalToConstant: 44),
            tools.leadingAnchor.constraint(equalTo: readerBar.leadingAnchor, constant: 16),
            tools.trailingAnchor.constraint(equalTo: readerBar.trailingAnchor, constant: -16),
            readBack.widthAnchor.constraint(equalToConstant: 44),
            readBack.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: Text size

    /// Steps of the reader's own size control, on top of the iPhone's text size.
    private static let textScales: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5]

    private var textScale: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "NJTextScale") as? Double ?? 1) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "NJTextScale"); applyTextStyle() }
    }

    private var textSans: Bool {
        get { UserDefaults.standard.bool(forKey: "NJTextSans") }
        set { UserDefaults.standard.set(newValue, forKey: "NJTextSans"); applyTextStyle() }
    }

    /// The reader's type scale: the iPhone's text size (Dynamic Type, relative to the
    /// standard 17pt body, capped so pages still fit) times the reader's own setting.
    private func applyTextStyle() {
        let system = min(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17) / 17, 1.8)
        let scale = system * textScale
        readerView?.evaluateJavaScript(
            "window.NewsJuice && NewsJuice.setTextStyle && NewsJuice.setTextStyle({ scale: \(scale), sans: \(textSans) })")
    }

    private func textMenuItems() -> [UIMenuElement] {
        let scales = Self.textScales
        let i = scales.firstIndex(of: textScale) ?? 1
        let larger = UIAction(title: "Larger", image: UIImage(systemName: "textformat.size.larger"),
                              attributes: i + 1 < scales.count ? [] : .disabled) { [weak self] _ in
            self?.textScale = scales[min(i + 1, scales.count - 1)]
        }
        let smaller = UIAction(title: "Smaller", image: UIImage(systemName: "textformat.size.smaller"),
                               attributes: i > 0 ? [] : .disabled) { [weak self] _ in
            self?.textScale = scales[max(i - 1, 0)]
        }
        let reset = UIAction(title: "Default size", attributes: textScale == 1 ? .disabled : []) { [weak self] _ in
            self?.textScale = 1
        }
        let serif = UIAction(title: "Serif", state: textSans ? .off : .on) { [weak self] _ in self?.textSans = false }
        let sans = UIAction(title: "Sans serif", state: textSans ? .on : .off) { [weak self] _ in self?.textSans = true }
        return [UIMenu(options: .displayInline, children: [larger, smaller, reset]),
                UIMenu(options: .displayInline, children: [serif, sans])]
    }

    /// Reads the filtered page aloud, from the top.
    private func listen() {
        readerView.evaluateJavaScript("window.NewsJuice && NewsJuice.speechParts()") { [weak self] value, _ in
            guard let self, let obj = value as? [String: Any],
                  let raw = obj["parts"] as? [[String: Any]], !raw.isEmpty else { return }
            let parts = raw.compactMap { p in (p["text"] as? String).map { Narrator.Part(text: $0, head: p["head"] as? Bool ?? false) } }
            let site = self.webView.url?.host.map(RecipeHandler.normalize) ?? ""
            let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? site
            self.narrator.start(parts, title: title, site: site)
            self.player.isHidden = false
            self.updateBar(lifted: self.lastCounts.lifted, kinds: self.lastCounts.kinds)
        }
    }

    /// reader.js: a paragraph was tapped while listening.
    func listenFrom(_ index: Int) {
        narrator.jump(to: index)
    }

    private func stopListening() {
        guard narrator.isOn || !player.isHidden else { return }
        narrator.stop()
        player.isHidden = true
        readerView?.evaluateJavaScript("window.NewsJuice && NewsJuice.speaking(null)")
        updateBar(lifted: lastCounts.lifted, kinds: lastCounts.kinds)
    }

    private func flash(_ text: String) {
        subtitleLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.updateBar(lifted: self.lastCounts.lifted, kinds: self.lastCounts.kinds)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        titleLabel.text = webView.url?.host
        SuggestedFilters.refreshIfStale()
        appNavigation = false
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
        // The reader is a snapshot of the page; while it's up, don't let the site load
        // something else underneath it on its own.
        if webView === self.webView, mode != .page, action.targetFrame?.isMainFrame == true,
           !appNavigation, action.navigationType != .backForward {
            NSLog("NewsJuice held site navigation to %@ while reading", action.request.url?.absoluteString ?? "")
            decisionHandler(.cancel)
            return
        }
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        // Keep browsing in here; hand tel:, mailto:, app links etc. to the system.
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            if let url = action.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { appNavigation = false }
    }

    // MARK: WKUIDelegate

    /// A new window. A link with target=_blank just opens here; a window opened from
    /// script (a sign-in popup) gets a sheet of its own, built on the configuration
    /// WebKit hands over so the page that opened it can still talk to it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Nor open windows from behind the reader.
        if webView === self.webView, mode != .page { return nil }
        if action.navigationType == .linkActivated {
            webView.load(action.request)
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let sheet = PopupViewController(webView: popup)
        (presentedViewController ?? self).present(sheet, animated: true)
        return popup
    }

    /// The popup closed itself (window.close(), as sign-in windows do when they're done).
    func webViewDidClose(_ webView: WKWebView) {
        guard webView !== self.webView else { return }
        var top: UIViewController? = presentedViewController
        while let vc = top {
            if let popup = vc as? PopupViewController, popup.webView === webView {
                popup.presentingViewController?.dismiss(animated: true)
                return
            }
            top = vc.presentedViewController
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topmost.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topmost.present(alert, animated: true)
    }

    private var topmost: UIViewController {
        var vc: UIViewController = self
        while let next = vc.presentedViewController { vc = next }
        return vc
    }
}

/// A window a page opened from script, such as a sign-in popup, shown as a sheet
/// with a Done button.
final class PopupViewController: UIViewController {
    let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let bar = UINavigationBar()
        let item = UINavigationItem()
        item.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        bar.items = [item]
        titleObservation = webView.observe(\.url, options: [.initial, .new]) { web, _ in
            item.title = web.url?.host
        }
        for v in [bar, webView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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

    static func save(host: String, keep: [String]) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[normalize(host)] = keep
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
        case "pickToggle":
            browser?.pickToggled(kind: body["kind"] as? String ?? "Text", on: body["on"] as? Bool ?? false,
                                 spots: body["spots"] as? Int ?? 0, keep: body["keep"] as? [String] ?? [])
            return
        case "listenFrom":
            if let i = body["index"] as? Int { browser?.listenFrom(i) }
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
        Self.save(host: host, keep: keep)
        NSLog("NewsJuice recipe for %@: %@", host, keep.joined(separator: " | "))
    }
}

/// Links for sharing a filter: <base><host>#<filter>. arvindrajnaidu.github.io serves the
/// apple-app-site-association that opens them in the app, and a page for those without it.
enum ShareLinks {
    static let baseURL = URL(string: "https://arvindrajnaidu.github.io/f/")!
    /// The same link as newslens://f/<host>#<filter>, for the "Open in News Lens" button
    /// on the web page (a universal link tapped on its own site stays in Safari).
    static let scheme = "newslens"

    /// The filter rides after the "#": its style signatures joined by "|", base64url.
    static func link(host: String, keep: [String]) -> URL? {
        let data = Data(keep.joined(separator: "|").utf8)
        let code = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: baseURL.absoluteString + RecipeHandler.normalize(host) + "#" + code)
    }

    /// A shared filter in a link, or nil if the link isn't one (or doesn't hold up).
    static func parse(_ url: URL) -> (host: String, keep: [String])? {
        let path: [String]
        switch url.scheme?.lowercased() {
        case "https" where url.host == baseURL.host: path = url.pathComponents.filter { $0 != "/" }
        case scheme: path = ([url.host ?? ""] + url.pathComponents).filter { $0 != "/" && !$0.isEmpty }
        default: return nil
        }
        guard path.count == 2, path[0] == "f",
              path[1].range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let code = url.fragment, code.count <= 4000 else { return nil }
        var b64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else { return nil }
        // Only things shaped like style signatures ("18px bold georgia links"), and not too many.
        let keep = text.split(separator: "|").map(String.init).filter {
            $0.count <= 80 && $0.range(of: #"^\d{1,3}px[ a-z0-9_.\-]*$"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard !keep.isEmpty, keep.count <= 40 else { return nil }
        return (path[1].lowercased(), keep)
    }

    /// A link that arrived before the app's UI was up (opening the app from it).
    private static var pending: URL?

    /// Handles a share link: asks whether to use the filter, then saves it and opens the
    /// site filtered. Returns false if the URL isn't a share link.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard parse(url) != nil else {
            NSLog("NewsJuice not a share link: %@", url.absoluteString)
            return false
        }
        pending = url
        showPending()
        return true
    }

    static func showPending() {
        guard let url = pending, let shared = parse(url),
              let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).compactMap(\.rootViewController).first(where: { $0 is MainViewController }),
              root.isViewLoaded, root.view.window != nil else {
            NSLog("NewsJuice share link waiting for the UI")
            return
        }
        pending = nil
        let (host, keep) = shared
        var top = root
        while let next = top.presentedViewController { top = next }
        let site = RecipeHandler.normalize(host)
        let replaces = RecipeHandler.recipe(forHost: host) != nil
        let kinds = keep.count == 1 ? "1 style" : "\(keep.count) styles"
        let alert = UIAlertController(
            title: "Use this filter for \(site)?",
            message: "It shows \(kinds) of text."
                + (replaces ? " It replaces your own filter for this site." : ""),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use Filter", style: .default) { _ in
            RecipeHandler.save(host: site, keep: keep)
            NSLog("NewsJuice shared filter for %@: %@", site, keep.joined(separator: " | "))
            guard let page = URL(string: "https://\(host)/") else { return }
            let show = { root.present(BrowserViewController(url: page, filter: true), animated: true) }
            if root.presentedViewController != nil { root.dismiss(animated: true, completion: show) } else { show() }
        })
        top.present(alert, animated: true)
    }
}

/// Suggested filters: one filters.json that Arvind keeps (a public gist; see docs/filters.md),
/// fetched at most once a day with If-None-Match and kept for offline use, with a copy
/// bundled in the app for first launch. The user's own filter (RecipeHandler) always wins.
enum SuggestedFilters {
    /// The gist's raw URL, without a revision hash so it always serves the latest edit.
    static let defaultURL = URL(string:
        "https://gist.githubusercontent.com/arvindrajnaidu/aec29d9de36b300bc4e8192745d65004/raw/filters.json")!
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

/// Reads a list of paragraphs aloud, one at a time, and keeps going with the screen
/// locked (background audio), with lock-screen controls. Each paragraph comes from the
/// AI voice (AIVoice, our speak function) with the next one fetched ahead; if that
/// fails (offline, over the daily allowance), it carries on in the system's voice.
final class Narrator: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    struct Part { let text: String; let head: Bool }

    static let speeds: [Float] = [1, 1.25, 1.5, 2, 0.8]
    private let synth = AVSpeechSynthesizer()
    private var audio: AVAudioPlayer?
    private var parts: [Part] = []
    private var index = 0
    private var voice: AVSpeechSynthesisVoice?
    private var title = "", site = "", language = "en"
    /// Audio fetched for each part, and the fetches under way.
    private var clips: [Int: Data] = [:]
    private var fetches: [Int: Task<Data, Error>] = [:]
    /// Bumped on every jump, so a fetch that lands late doesn't play over a newer one.
    private var generation = 0
    private(set) var speed: Float = 1
    private(set) var isOn = false
    private(set) var isPlaying = false
    private(set) var usingAI = true
    /// The part being read (nil when stopped), and any change worth redrawing for.
    var onPart: ((Int?) -> Void)?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(routeChanged(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func start(_ parts: [Part], title: String, site: String) {
        self.parts = parts
        self.title = title
        self.site = site
        clips = [:]
        usingAI = true
        let sample = parts.prefix(20).map(\.text).joined(separator: " ")
        language = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue ?? "en"
        voice = Self.voice(for: sample)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        isOn = true
        RemoteControls.shared.narrator = self
        speak(0)
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        isPlaying = false
        generation += 1
        silence()
        fetches.values.forEach { $0.cancel() }
        fetches = [:]
        clips = [:]
        onPart?(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if RemoteControls.shared.narrator === self { RemoteControls.shared.narrator = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }

    func togglePause() { isPlaying ? pause() : play() }

    func play() {
        guard isOn else { return }
        if let audio { audio.play() } else if synth.isPaused { synth.continueSpeaking() } else { speak(index) }
        isPlaying = true
        nowPlaying()
        onChange?()
    }

    func pause() {
        guard isOn, isPlaying else { return }
        audio?.pause()
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        isPlaying = false
        nowPlaying()
        onChange?()
    }

    func skip(by step: Int) { jump(to: max(0, min(parts.count - 1, index + step))) }

    func jump(to i: Int) {
        guard isOn, parts.indices.contains(i) else { return }
        speak(i)
    }

    func nextSpeed() {
        let i = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(i + 1) % Self.speeds.count]
        if let audio {
            audio.rate = speed
        } else if isPlaying {
            // The system voice takes a new rate from the next utterance; restart this one.
            speak(index)
            return
        }
        onChange?()
    }

    private func silence() {
        audio?.stop()
        audio = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ i: Int) {
        index = i
        generation += 1
        let gen = generation
        silence()
        isPlaying = true
        onPart?(i)
        nowPlaying()
        onChange?()
        guard usingAI else { speakBuiltIn(i); return }
        Task { @MainActor in
            do {
                let data = try await self.clip(i)
                guard gen == self.generation, self.isOn else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.enableRate = true
                player.rate = self.speed
                self.audio = player
                if self.isPlaying { player.play() }
                if i + 1 < self.parts.count { _ = Task { try? await self.clip(i + 1) } }
            } catch {
                guard gen == self.generation, self.isOn else { return }
                NSLog("NewsJuice AI voice unavailable (%@); using the built-in voice", String(describing: error))
                self.usingAI = false
                self.onChange?()
                self.speakBuiltIn(i)
            }
        }
    }

    /// The AI audio for part i: already fetched, under way, or fetched now.
    @MainActor private func clip(_ i: Int) async throws -> Data {
        if let data = clips[i] { return data }
        let task = fetches[i] ?? Task { try await AIVoice.speak(parts[i].text, head: parts[i].head, story: title, site: site, lang: language) }
        fetches[i] = task
        defer { fetches[i] = nil }
        let data = try await task.value
        clips[i] = data
        return data
    }

    private func speakBuiltIn(_ i: Int) {
        let part = parts[i]
        let u = AVSpeechUtterance(string: part.text)
        u.voice = voice
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * speed)
        // A beat around headlines so they read as headlines.
        u.preUtteranceDelay = part.head && i > 0 ? 0.35 : 0
        u.postUtteranceDelay = part.head ? 0.45 : 0.12
        synth.speak(u)
        if !isPlaying { synth.pauseSpeaking(at: .immediate) }
    }

    private func finishedPart() {
        guard isOn else { return }
        clips[index] = nil
        if index + 1 < parts.count { speak(index + 1) } else { stop() }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard isOn, audio == nil, utterance.speechString == parts[index].text else { return }
        finishedPart()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audio else { return }
        audio = nil
        finishedPart()
    }

    private func nowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: site,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    /// A call or another app's audio paused us; carry on if the system says to.
    @objc private func interrupted(_ note: Notification) {
        guard isOn, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began { self.pause(); return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            if options.contains(.shouldResume) { self.play() }
        }
    }

    /// Headphones unplugged (or Bluetooth gone): pause rather than read out loud.
    @objc private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.pause() }
    }

    /// The best installed voice for the text's language: the user's own variant of it
    /// (en-IN for an Indian English user) and Premium or Enhanced quality first.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let preferred = Locale.preferredLanguages.first { $0.hasPrefix(lang) }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        let best = voices.max { a, b in
            let ra = (a.language == preferred ? 10 : 0) + a.quality.rawValue
            let rb = (b.language == preferred ? 10 : 0) + b.quality.rawValue
            return ra < rb
        }
        return best ?? AVSpeechSynthesisVoice(language: preferred ?? lang)
    }
}

/// The expressive voice: our speak Cloud Function (functions/index.js), which reads a
/// paragraph with OpenAI's speech model. Requests carry an App Check token and this
/// install's random id (for its daily allowance).
enum AIVoice {
    static let endpoint = URL(string: "https://us-central1-news-lens-4ea95.cloudfunctions.net/speak")!

    struct Failure: Error { let status: Int }

    static var installID: String {
        let key = "NJInstallID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func speak(_ text: String, head: Bool, story: String, site: String, lang: String) async throws -> Data {
        let spoken = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let story = String(story.prefix(200))
        // Everything that shapes the audio, so a cached reading matches a fresh one.
        let key = ClipCache.key([ClipCache.version, voice ?? "", lang, head ? "head" : "", story, site, spoken])
        if let data = ClipCache.get(key) { return data }
        let data = try await fetch(spoken, head: head, story: story, site: site, lang: lang)
        ClipCache.put(key, data)
        #if DEBUG
        // -NJSaveClips YES: keep each reading in Documents too, for comparing voices.
        if UserDefaults.standard.bool(forKey: "NJSaveClips") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: docs.appendingPathComponent("clip-\(voice ?? "default")-\(key.prefix(8)).mp3"))
        }
        #endif
        return data
    }

    /// The voice to ask for; nil leaves it to the function. Debug builds can pick one
    /// with -NJVoice <name> to compare voices.
    private static var voice: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "NJVoice")
        #else
        return nil
        #endif
    }

    private static func fetch(_ text: String, head: Bool, story: String, site: String, lang: String) async throws -> Data {
        let token = try await AppCheck.appCheck().token(forcingRefresh: false).token
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue(installID, forHTTPHeaderField: "X-NL-Device")
        var body: [String: Any] = ["text": String(text.prefix(4000)), "head": head, "story": story, "site": site, "lang": lang]
        if let voice { body["voice"] = voice }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw Failure(status: status) }
        return data
    }
}

/// Lock screen, Control Center and headphone buttons, sent to whichever narrator is on.
final class RemoteControls {
    static let shared = RemoteControls()
    weak var narrator: Narrator?

    private init() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.narrator?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.narrator?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.narrator?.togglePause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.narrator?.skip(by: 1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.narrator?.skip(by: -1); return .success }
    }
}

/// The slim player at the bottom while listening: previous, play/pause, next, speed, close.
final class PlayerBar: UIView {
    var onPlayPause: (() -> Void)?, onPrevious: (() -> Void)?, onNext: (() -> Void)?
    var onSpeed: (() -> Void)?, onClose: (() -> Void)?
    private let play = UIButton(type: .system)
    private let speed = UIButton(type: .system)
    private let voiceLabel = UILabel()

    private static let tint = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1)
        : UIColor(red: 0.42, green: 0.39, blue: 0.345, alpha: 1) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.125, blue: 0.11, alpha: 1)
            : UIColor(red: 0.953, green: 0.937, blue: 0.902, alpha: 1) }
        let rule = UIView()
        rule.backgroundColor = .separator
        let button = { (b: UIButton, symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) in
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
            c.baseForegroundColor = Self.tint
            b.configuration = c
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
            b.widthAnchor.constraint(equalToConstant: 52).isActive = true
            b.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        let prev = UIButton(type: .system), next = UIButton(type: .system), close = UIButton(type: .system)
        button(prev, "backward.fill", 20, "Previous paragraph") { [weak self] in self?.onPrevious?() }
        button(play, "pause.fill", 28, "Pause") { [weak self] in self?.onPlayPause?() }
        button(next, "forward.fill", 20, "Next paragraph") { [weak self] in self?.onNext?() }
        button(close, "xmark", 17, "Stop listening") { [weak self] in self?.onClose?() }
        var sc = UIButton.Configuration.plain()
        sc.baseForegroundColor = Self.tint
        sc.contentInsets = .zero
        sc.titleLineBreakMode = .byClipping
        speed.configuration = sc
        speed.accessibilityLabel = "Reading speed"
        speed.addAction(UIAction { [weak self] _ in self?.onSpeed?() }, for: .primaryActionTriggered)
        speed.widthAnchor.constraint(equalToConstant: 56).isActive = true
        voiceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        voiceLabel.textColor = .secondaryLabel
        voiceLabel.textAlignment = .center
        let controls = UIStackView(arrangedSubviews: [speed, prev, play, next, close])
        controls.distribution = .equalSpacing
        controls.alignment = .center
        for v in [rule, controls, voiceLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            voiceLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 2),
            voiceLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        update(playing: true, speed: 1, ai: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(playing: Bool, speed rate: Float, ai: Bool) {
        voiceLabel.text = ai ? "AI voice" : "Built-in voice"
        play.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
        play.accessibilityLabel = playing ? "Pause" : "Play"
        let text = rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
        speed.configuration?.attributedTitle = AttributedString(text, attributes: AttributeContainer(
            [.font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)]))
    }
}

/// Readings kept on the phone (Caches/tts), so playing something again costs nothing.
/// Keyed by a SHA-256 of what shapes the audio; trimmed oldest-first to 100 MB.
enum ClipCache {
    /// Bump when the server's voice or direction changes, so old readings aren't reused.
    static let version = "gemini-2"
    private static let limit = 100 * 1024 * 1024
    private static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func key(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func get(_ key: String) -> Data? {
        let file = folder.appendingPathComponent(key + ".mp3")
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Touch it, so trimming keeps what's been played recently.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// Disk work happens off the main thread, one write at a time.
    private static let io = DispatchQueue(label: "news-lens.clip-cache", qos: .utility)

    static func put(_ key: String, _ data: Data) {
        io.async {
            try? data.write(to: folder.appendingPathComponent(key + ".mp3"))
            trim()
        }
    }

    private static func trim() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard var files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let info = { (url: URL) in try? url.resourceValues(forKeys: Set(keys)) }
        var total = files.reduce(0) { $0 + (info($1)?.fileSize ?? 0) }
        guard total > limit else { return }
        files.sort { (info($0)?.contentModificationDate ?? .distantPast) < (info($1)?.contentModificationDate ?? .distantPast) }
        for file in files where total > limit {
            total -= info(file)?.fileSize ?? 0
            try? fm.removeItem(at: file)
        }
    }
}

/// The bar under the page while picking on it: what the last tap did, Cancel, and
/// Start reading.
final class PickBar: UIView {
    static let height: CGFloat = 104
    var onStart: (() -> Void)?, onCancel: (() -> Void)?
    private let hint = UILabel()
    private let list = UIButton(type: .system)
    private let start = UIButton(type: .system)

    private static let tint = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1)
        : UIColor(red: 0.42, green: 0.39, blue: 0.345, alpha: 1) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabel
        hint.lineBreakMode = .byTruncatingTail
        var lc = UIButton.Configuration.plain()
        lc.contentInsets = .zero
        lc.baseForegroundColor = Self.tint
        lc.attributedTitle = AttributedString("Cancel", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]))
        list.configuration = lc
        list.accessibilityLabel = "Cancel without saving"
        list.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)
        start.addAction(UIAction { [weak self] _ in self?.onStart?() }, for: .primaryActionTriggered)
        for v in [hint, list, start] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: topAnchor),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: list.leadingAnchor, constant: -8),
            hint.heightAnchor.constraint(equalToConstant: 22),
            list.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            start.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            start.leadingAnchor.constraint(equalTo: leadingAnchor),
            start.trailingAnchor.constraint(equalTo: trailingAnchor),
            start.heightAnchor.constraint(equalToConstant: 54),
            start.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(count: 0, hint: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(count: Int, hint text: String?) {
        hint.text = text ?? "Tap text to add or remove it"
        var c = UIButton.Configuration.filled()
        c.background.cornerRadius = 16
        c.imagePadding = 10
        c.titleAlignment = .leading
        if count > 0 {
            c.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
            c.baseBackgroundColor = UIColor(red: 0.122, green: 0.435, blue: 0.42, alpha: 1)
            c.baseForegroundColor = .white
            c.attributedTitle = AttributedString("Start reading", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]))
            c.attributedSubtitle = AttributedString(count == 1 ? "1 style in your filter" : "\(count) styles in your filter",
                                                    attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 12, weight: .medium)]))
        } else {
            c.baseBackgroundColor = UIColor(red: 0.90, green: 0.875, blue: 0.82, alpha: 1)
            c.baseForegroundColor = UIColor(red: 0.48, green: 0.45, blue: 0.41, alpha: 1)
            c.attributedTitle = AttributedString("Tap text to add to your filter",
                                                 attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .semibold)]))
        }
        start.configuration = c
        start.isEnabled = count > 0
    }
}

/// The one-time explanation the first time someone picks a filter on a page.
enum CoachCard {
    private static let seenKey = "NJCoachSeen"
    private static let tagValue = 7_210

    static func showOnce(in view: UIView) {
        guard !UserDefaults.standard.bool(forKey: seenKey), view.viewWithTag(tagValue) == nil else { return }
        // A dimmed backdrop over everything, so the card reads as the app's, not the site's.
        let backdrop = UIView()
        backdrop.tag = tagValue
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let card = UIView()
        card.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.16, blue: 0.14, alpha: 1) : UIColor(red: 0.985, green: 0.975, blue: 0.955, alpha: 1) }
        card.layer.cornerRadius = 18
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        let title = UILabel()
        title.text = "Tap the text you want to read"
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.numberOfLines = 0
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        icon.tintColor = UIColor(red: 0.122, green: 0.435, blue: 0.42, alpha: 1)
        icon.contentMode = .left
        let steps = ["Tap any text on the page.",
                     "Everything in the same style lights up and joins your filter.",
                     "Tap Start reading. We remember it for this site."]
        let list = UIStackView(arrangedSubviews: steps.enumerated().map { i, text in
            let l = UILabel()
            l.numberOfLines = 0
            l.font = .systemFont(ofSize: 15)
            l.text = "\(i + 1).  \(text)"
            return l
        })
        list.axis = .vertical
        list.spacing = 8
        var bc = UIButton.Configuration.filled()
        bc.baseBackgroundColor = UIColor(red: 0.122, green: 0.435, blue: 0.42, alpha: 1)
        bc.baseForegroundColor = .white
        bc.background.cornerRadius = 12
        bc.attributedTitle = AttributedString("Got it", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .semibold)]))
        let ok = UIButton(configuration: bc)
        ok.addAction(UIAction { [weak view] _ in
            UserDefaults.standard.set(true, forKey: seenKey)
            if let view { dismiss(in: view) }
        }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [icon, title, list, ok])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(18, after: list)
        stack.setCustomSpacing(10, after: icon)
        // Tapping outside the card dismisses it too.
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: CoachCard.Dismisser.shared, action: #selector(Dismisser.tapped(_:))))
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            ok.heightAnchor.constraint(equalToConstant: 46),
            card.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -24),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
        backdrop.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.35, delay: 0.2, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: []) {
            backdrop.alpha = 1
            card.transform = .identity
        }
    }

    final class Dismisser: NSObject {
        static let shared = Dismisser()
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let backdrop = gesture.view, let card = backdrop.subviews.first,
                  !card.frame.contains(gesture.location(in: backdrop)), let host = backdrop.superview else { return }
            UserDefaults.standard.set(true, forKey: seenKey)
            dismiss(in: host)
        }
    }

    static func dismiss(in view: UIView) {
        guard let card = view.viewWithTag(tagValue) else { return }
        UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }, completion: { _ in card.removeFromSuperview() })
    }
}

/// Presents the browser like a navigation push: it slides in from the right over Home,
/// which eases left, and slides back out to the right. With Reduce Motion, a crossfade.
final class SideSlide: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    static let shared = SideSlide()
    private var presenting = true
    /// Set while an edge swipe drives the dismissal.
    var interaction: UIPercentDrivenInteractiveTransition?

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning)
        -> UIViewControllerInteractiveTransitioning? {
        interaction
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        presenting = false
        return self
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.25 : 0.38
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from) ?? context.viewController(forKey: .from)?.view,
              let to = context.view(forKey: .to) ?? context.viewController(forKey: .to)?.view else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let width = container.bounds.width
        let still = UIAccessibility.isReduceMotionEnabled
        if presenting {
            to.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
            container.addSubview(to)
            to.transform = still ? .identity : CGAffineTransform(translationX: width, y: 0)
            to.alpha = still ? 0 : 1
        } else {
            container.insertSubview(to, belowSubview: from)
            to.transform = still ? .identity : CGAffineTransform(translationX: -width * 0.3, y: 0)
        }
        let curve: UIView.AnimationOptions = context.isInteractive ? .curveLinear : .curveEaseOut
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [curve]) {
            if self.presenting {
                to.transform = .identity
                to.alpha = 1
                if !still { from.transform = CGAffineTransform(translationX: -width * 0.3, y: 0) }
            } else {
                to.transform = .identity
                if still { from.alpha = 0 } else { from.transform = CGAffineTransform(translationX: width, y: 0) }
            }
        } completion: { _ in
            from.transform = .identity
            from.alpha = 1
            to.transform = .identity
            let cancelled = context.transitionWasCancelled
            if cancelled && !self.presenting { to.removeFromSuperview() }
            context.completeTransition(!cancelled)
        }
    }
}
