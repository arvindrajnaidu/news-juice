# News Juice

A mobile browser (iOS and Android) for reading text-heavy news sites without the clutter. Swipe, and the article "lifts" off the page into a clean reading view.

## Plan

1. **Build the lift on desktop.** A script that runs on a loaded page and pulls out the article using font sizes. Tune it on NDTV and other text-heavy sites.
2. **Prove the in-app browser on a phone.** A Capacitor app that opens any URL, runs the lift on the page, and gets the text back.
3. **Build the reading experience.** Address bar, the swipe that lifts the article, and a swipe back to the page.
4. **Ship.** Icon, privacy page, store listings, TestFlight and Play internal testing.

## The lift

`lift/lift.js` works on the rendered page, so it sees the same styles you do. Instead of guessing which part of the page is the article, it sorts all the text by how it looks:

1. Collect every visible block of text, with inline children (links, emphasis, drop caps) kept in their paragraph.
2. Give each block a style signature: font size, bold or not, italic or not, font family, and whether it is mostly link text.
3. Group blocks by signature and sort the groups by how much text they hold. On a news page the article body is almost always one group of its own.

`lift/reader.js` draws the clean view that slides up over the page. Its panel lists the groups (a sample line, size and character count) with a Keep/Cull switch each, and the article updates as you switch. Kept groups bigger than the body read as headings, smaller ones as small print. The kept set is the site's **recipe**: it is saved per site, so the next article on that site lifts straight into your layout with the panel folded away. On a site with no recipe the biggest prose group is kept and the panel starts open.

`test/fixtures/real/` holds snapshots of real pages (computed styles inlined, scripts and images stripped; see `test/capture-page.js`) with a `.json` note of the expected body group, first and last paragraph, and what a reader would leave out.

## Try it

```bash
npm install
npx playwright install chromium   # first time only

npm run bookmarklet   # writes dist/bookmarklet.html: drag "Lift" to your bookmarks bar
npm run lift:test     # opens every site in harness/sites.txt in a phone-sized browser
                      # and writes a before/after report to harness/out/index.html
```

`npm run lift:test -- https://www.ndtv.com/some-article` runs it on specific pages. Homepages work too: the harness follows the first link that looks like an article.

## iOS app (step 2)

`app/` is a Capacitor 8 iOS app (bundle id `com.buzzie.newslens`). Capacitor's web view only hosts the start screen (`app/www/index.html`: a URL field and a few sites to try). Pages open in a separate native `WKWebView` (`app/ios/App/App/NewsJuiceBrowser.swift`) that injects `lift/lift.js` and `lift/reader.js` into every page at document end. Swipe the bar at the bottom up (or tap it) to lift; swipe it down to get the page back.

```bash
cd app
npm install
npm run sync    # copies ../lift/*.js into www/lift, then `cap sync ios`
npm run ios     # same, then opens Xcode
```

`lift/` stays the only copy of the lift code: `npm run sync` bundles it, so re-run it after editing `lift/*.js`.

In Debug builds, `xcrun simctl launch booted com.buzzie.newslens -NJOpenURL https://...` opens a page straight away. Each lift logs its stats (`NewsJuice lift {...}`) to the console.

The app icon is drawn in `app/resources/icon.svg`; `swift app/scripts/render-icon.swift` renders it into the asset catalog.
