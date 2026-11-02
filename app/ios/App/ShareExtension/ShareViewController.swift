import UIKit
import UniformTypeIdentifiers

// News Lens in the share sheet: "Share → News Lens" on a web page (or on text with a
// link in it) opens that page in the app. No sheet of its own: it finds the URL, hands
// it to the app as newslens://open?url=..., and closes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            if let url = await sharedURL(), let link = Self.appLink(for: url) {
                openInApp(link)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The first web URL among the shared items: a URL itself, or one inside shared text.
    private func sharedURL() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, Self.isWeb(url) {
                return url
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = Self.firstLink(in: text) {
                return url
            }
        }
        return nil
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url).first(where: isWeb)
    }

    static func appLink(for url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "newslens"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return c.url
    }

    /// Extensions can't open URLs directly; the application object in the responder
    /// chain can.
    private func openInApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }
}
