// News Juice "lift": sort a rendered page's text by how it is styled.
//
// Idea: on a news page every kind of text has its own look. The article body is
// one font size, weight and family; headings, captions, "also read" links,
// trending lists and footers each have theirs. So instead of guessing which part
// is the article, group every visible block of text by its style signature and
// let the reader pick which groups to keep (and remember that per site).
//
// Runs in any browser context (desktop page, bookmarklet, mobile webview).
// Exposes window.NewsJuice.lift(options) -> result object:
//   { ok, url, host, title,
//     groups: [{ id, size, bold, italic, family, link, chars, count, sample }],  // most text first
//     blocks: [{ g, text, tag }] }                                               // page order
(function () {
  var DEFAULTS = {
    maxLinkDensity: 0.5,   // blocks with more link text than this are link lists, grouped apart from prose
    sampleChars: 120,
  };

  var SKIP_TAGS = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|CANVAS|IFRAME|BUTTON|SELECT|TEXTAREA|INPUT|LABEL|NAV|FORM|HEAD|OPTION)$/;
  var HEADING = /^H[1-6]$/;

  function isHidden(el, style) {
    if (style.display === 'none' || style.visibility === 'hidden' || +style.opacity === 0) return true;
    if (style.display === 'contents') return false; // no box of its own, but its children render
    var r = el.getBoundingClientRect();
    return r.width === 0 && r.height === 0;
  }

  // A child element that reads as part of its parent's line of text: inline
  // elements, line breaks, and short floated letters (drop caps).
  function flowsInline(n, style) {
    if (n.tagName === 'BR') return true;
    if (style.display.indexOf('inline') === 0) return true;
    return style.float !== 'none' && style.display !== 'none' && n.textContent.trim().length <= 2;
  }

  // Visible text of an inline subtree. Stops at block elements inside it (a link
  // wrapping a whole card): the walker reads those as blocks of their own. Also
  // leaves out the code in nested scripts, which textContent would include.
  function inlineText(n) {
    if (n.nodeType === 3) return n.nodeValue;
    if (n.nodeType !== 1 || SKIP_TAGS.test(n.tagName)) return '';
    if (n.tagName === 'BR') return '\n';
    var out = '';
    for (var c = n.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 1 && !flowsInline(c, getComputedStyle(c))) continue;
      out += inlineText(c);
    }
    return out;
  }

  // Text that belongs to this element directly (its own text nodes plus inline
  // children), not text inside nested block elements.
  function ownText(el) {
    var out = '';
    var linkChars = 0;
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        out += n.nodeValue;
      } else if (n.nodeType === 1 && !SKIP_TAGS.test(n.tagName) && flowsInline(n, getComputedStyle(n))) {
        var t = inlineText(n);
        out += t;
        if (n.tagName === 'A' || n.querySelector('a')) linkChars += t.length;
      }
    }
    var text = out.replace(/[ \t\r\f\v ]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
    // Text inside a link (a headline in a "trending" list) is all link.
    var linkDensity = el.closest('a') ? 1 : text.length ? Math.min(1, linkChars / text.length) : 0;
    return { text: text, linkDensity: linkDensity };
  }

  function familyOf(style) {
    return (style.fontFamily.split(',')[0] || '').replace(/["']/g, '').trim().toLowerCase();
  }

  function collectBlocks(root, opts) {
    var blocks = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (el) {
        if (SKIP_TAGS.test(el.tagName) || el.id === 'news-juice-reader') return NodeFilter.FILTER_REJECT;
        if (isHidden(el, getComputedStyle(el))) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    for (var el = walker.currentNode; el; el = walker.nextNode()) {
      var st = getComputedStyle(el);
      // Inline elements are read as part of their parent block (headings excepted).
      if (el !== root && flowsInline(el, st) && !HEADING.test(el.tagName)) continue;
      var own = ownText(el);
      if (own.text.length < 2) continue;
      var size = Math.round(parseFloat(st.fontSize));
      var bold = (parseInt(st.fontWeight, 10) || 400) >= 600;
      var italic = st.fontStyle === 'italic';
      var family = familyOf(st);
      var link = own.linkDensity > opts.maxLinkDensity;
      blocks.push({
        g: size + 'px' + (bold ? ' bold' : '') + (italic ? ' italic' : '') + ' ' + family + (link ? ' links' : ''),
        text: own.text,
        tag: el.tagName.toLowerCase(),
        size: size, bold: bold, italic: italic, family: family, link: link,
      });
    }
    return blocks;
  }

  function groupBlocks(blocks, opts) {
    var byId = {};
    var groups = [];
    blocks.forEach(function (b) {
      var g = byId[b.g];
      if (!g) {
        g = byId[b.g] = { id: b.g, size: b.size, bold: b.bold, italic: b.italic, family: b.family,
          link: b.link, chars: 0, count: 0, sample: b.text.replace(/\n/g, ' ').slice(0, opts.sampleChars) };
        groups.push(g);
      }
      g.chars += b.text.length;
      g.count++;
    });
    return groups.sort(function (a, b) { return b.chars - a.chars; });
  }

  function pickTitle() {
    var h1s = document.querySelectorAll('h1');
    for (var i = 0; i < h1s.length; i++) {
      var t = h1s[i].innerText && h1s[i].innerText.trim();
      if (t && !isHidden(h1s[i], getComputedStyle(h1s[i]))) return t;
    }
    var og = document.querySelector('meta[property="og:title"]');
    return og ? og.content : document.title;
  }

  function lift(options) {
    var opts = Object.assign({}, DEFAULTS, options || {});
    var blocks = collectBlocks(document.body, opts);
    var groups = groupBlocks(blocks, opts);
    return {
      ok: groups.length > 0,
      reason: groups.length ? undefined : 'no text found',
      url: location.href,
      host: location.hostname.replace(/^www\./, ''),
      title: pickTitle(),
      groups: groups,
      blocks: blocks.map(function (b) { return { g: b.g, text: b.text, tag: b.tag }; }),
    };
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.lift = lift;
})();
