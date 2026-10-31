# Suggested filters

News Lens can open a site straight in the reader with a filter you've picked for it, a
**suggested filter**. Suggestions come from one file, `filters.json`, that you host as a
public GitHub gist. The app also bundles a copy for first launch and offline use.

## The file

```json
{
  "v": 1,
  "updated": "2026-10-31",
  "sites": {
    "apnews.com": { "keep": ["16px ap", "18px bold ap links"] },
    "example.com": {
      "article": { "keep": ["18px georgia", "32px bold georgia"] },
      "section": { "keep": ["20px bold georgia links"] }
    }
  }
}
```

- **Site keys** are hosts without `www.`, exactly as the address bar shows them
  (`edition.cnn.com`, not `cnn.com`).
- **`keep`** lists the style signatures to keep, the same strings the app saves for a
  user's own filter. A signature is the size, `bold`, `italic`, the font family and
  `links`, for example `18px bold inter links`.
- **Which `keep` applies:**
  - Top-level `keep` applies to every page on the site.
  - `article` and `section` apply only to article pages (`og:type` article) or to the
    other pages.
  - When several apply, they're combined.
- **Size tolerance:** a signature also matches the same style 1px bigger or smaller.
- **Redesigns:** if none of a site's styles are on a page, the app falls back to the
  picker.
- **Getting signatures:** the easiest way is to filter the site yourself in the
  Simulator and copy what the app saved. Debug builds log each save as
  `NewsJuice recipe for <host>: …`.

`filters/filters.json` is the current file. Paste it into the gist, and `npm run sync`
bundles it into the app.

## How the app uses it

When you tap Filter on a site, the app looks for a filter in this order:

1. **Your own filter**, if you've saved one for the site.
2. **The suggested filter** from the downloaded `filters.json`. The app refetches the
   file at most once a day, sending `If-None-Match` so an unchanged gist costs a
   304, and keeps it for offline use. The fetch gives up after 2 seconds.
3. **The suggested filter** from the bundled copy.
4. **The picker**, as for any new site.

A suggestion opens straight in the reader with the subtitle "Suggested filter".

- **Editing it:** once you edit it with the sliders, it becomes your own, and later
  updates to the suggestion don't touch it.
- **Reset to suggested:** in the picker, this drops your own filter and goes back to the
  suggestion.
- **Unchanged suggestions:** reading a suggestion without changing it saves nothing, so
  gist updates keep arriving.

## The gist

- The app fetches the raw URL **without** a revision hash:
  `https://gist.githubusercontent.com/arvindrajnaidu/aec29d9de36b300bc4e8192745d65004/raw/filters.json`
  (gist https://gist.github.com/arvindrajnaidu/aec29d9de36b300bc4e8192745d65004).
  It's set in `SuggestedFilters.defaultURL` in `NewsJuiceBrowser.swift`.
- **Edits can lag:** raw gist content is cached, so an edit can take a few minutes to
  show up there. Each device then picks it up within a day.

## Testing locally

```bash
cd app && npm run filters:serve
```

This serves `filters/filters.json` (or a file you pass after `--`) with ETags at
`http://localhost:8787/raw/filters.json`. Launch a Debug build with
`-NJFiltersURL http://localhost:8787/raw/filters.json` to use it.
