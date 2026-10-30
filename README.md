# News Juice

A mobile browser (iOS and Android) for reading text-heavy news sites without the clutter. Swipe, and the article "lifts" off the page into a clean reading view.

## Plan

1. **Build the lift on desktop.** A script that runs on a loaded page and pulls out the article using font sizes. Tune it on NDTV and other text-heavy sites.
2. **Prove the in-app browser on a phone.** A Capacitor app that opens any URL, runs the lift on the page, and gets the text back.
3. **Build the reading experience.** Address bar, the swipe that lifts the article, and a swipe back to the page.
4. **Ship.** Icon, privacy page, store listings, TestFlight and Play internal testing.

## The lift (step 1)

`lift/lift.js` works on the rendered page, so it sees the same font sizes you do:

1. Collect every visible block of text with its computed font size and how much of it is links.
2. Add up the characters set in each font size. The size with the most prose is the **body size**.
3. Starting at `<body>`, step into whichever child holds at least 75% of the body-size text. Where that stops is the **article container**.
4. Read the container top to bottom: body-size blocks become paragraphs, larger short lines become headings, slightly smaller full sentences (quotes, captions) are kept, and link-heavy blocks are dropped.

The thresholds are the `DEFAULTS` at the top of `lift.js`.

`lift/reader.js` draws the clean view that slides up over the page.

## Try it

```bash
npm install
npx playwright install chromium   # first time only

npm run bookmarklet   # writes dist/bookmarklet.html: drag "Lift" to your bookmarks bar
npm run lift:test     # opens every site in harness/sites.txt in a phone-sized browser
                      # and writes a before/after report to harness/out/index.html
```

`npm run lift:test -- https://www.ndtv.com/some-article` runs it on specific pages. Homepages work too: the harness follows the first link that looks like an article.
