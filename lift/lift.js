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
//   { ok, url, host, title, article,
//     groups: [{ id, size, bold, italic, family, link, color, transform, chars, count, sample }],  // most text first
//     blocks: [{ g, text, tag, href?, links? }] }                                // page order
// A block that sits inside a link has its `href`; links within a block's text are
// `links`: [start, end, href] ranges into `text`.
(function () {
  var DEFAULTS = {
    maxLinkDensity: 0.5,   // blocks with more link text than this are link lists, grouped apart from prose
    sampleChars: 120,
  };

  var SKIP_TAGS = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|CANVAS|IFRAME|BUTTON|SELECT|TEXTAREA|INPUT|LABEL|NAV|FORM|HEAD|OPTION)$/;
  var HEADING = /^H[1-6]$/;

  // Tags whose content isn't page text. SVG elements keep their lower-case names
  // (svg, style inside an icon), so compare in upper case.
  function skipped(el) {
    return SKIP_TAGS.test(el.tagName.toUpperCase());
  }

  function isHidden(el, style) {
    if (style.display === 'none' || style.visibility === 'hidden' || +style.opacity === 0) return true;
    if (style.display === 'contents') return false; // no box of its own, but its children render
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return true;
    // Text for screen readers only ("screen-reader-text", "sr-only"): clipped away or
    // squeezed into a pixel.
    if (/inset\(50%|circle\(0/.test(style.clipPath || '')) return true;
    if (style.position === 'absolute' && /rect\(\s*(0|1)px,?\s*(0|1)px/.test(style.clip || '')) return true;
    return (r.width <= 1 || r.height <= 1) && style.overflow === 'hidden';
  }

  function isOverlay(el, style) {
    if (style.position === 'fixed' || style.position === 'sticky') return true;
    if (el.tagName === 'DIALOG') return true;
    return el.getAttribute('role') === 'dialog' || el.getAttribute('aria-modal') === 'true';
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
    if (n.nodeType !== 1 || skipped(n)) return '';
    if (n.tagName === 'BR') return '\n';
    var out = '';
    for (var c = n.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 1 && !flowsInline(c, getComputedStyle(c))) continue;
      out += inlineText(c);
    }
    return out;
  }

  function webLink(a) {
    return a && /^https?:/i.test(a.href) ? a.href : null;
  }

  // Text that belongs to this element directly (its own text nodes plus inline
  // children), not text inside nested block elements. Also returns where the
  // links are: [start, end, href] ranges into the text.
  function ownText(el) {
    var segs = []; // { text, href }
    var linkChars = 0;
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        segs.push({ text: n.nodeValue, href: null });
      } else if (n.nodeType === 1 && !skipped(n) && flowsInline(n, getComputedStyle(n))) {
        var t = inlineText(n);
        var a = n.tagName === 'A' ? n : n.querySelector('a');
        if (a) linkChars += t.length;
        // A link only when it covers the whole inline child (<a>, or <b><a>..</a></b>).
        var href = a && a.textContent.trim() === n.textContent.trim() ? webLink(a) : null;
        segs.push({ text: t, href: href });
      }
    }
    // Collapse whitespace segment by segment so the link ranges stay right.
    var text = '';
    var links = [];
    segs.forEach(function (sg) {
      var t = sg.text.replace(/[ \t\r\f\v\u00a0]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n+/g, '\n');
      if (/[ \n]$/.test(text) || !text) t = t.replace(/^[ \n]+/, '');
      if (!t) return;
      if (sg.href) {
        var lead = t.length - t.replace(/^[ \n]+/, '').length;
        var core = t.trim();
        if (core) links.push([text.length + lead, text.length + lead + core.length, sg.href]);
      }
      text += t;
    });
    var trimmed = text.replace(/[ \n]+$/, '');
    links = links.filter(function (l) { return l[1] <= trimmed.length; });
    // Text inside a link (a headline in a "trending" list) is all link.
    var outer = el.closest('a');
    var linkDensity = outer ? 1 : trimmed.length ? Math.min(1, linkChars / trimmed.length) : 0;
    return { text: trimmed, linkDensity: linkDensity, href: webLink(outer), links: links };
  }

  function familyOf(style) {
    return (style.fontFamily.split(',')[0] || '').replace(/["']/g, '').trim().toLowerCase();
  }

  function collectBlocks(root, opts) {
    var blocks = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (el) {
        if (skipped(el) || el.id === 'news-juice-reader') return NodeFilter.FILTER_REJECT;
        var st = getComputedStyle(el);
        if (isHidden(el, st)) return NodeFilter.FILTER_REJECT;
        // Overlays (cookie banners, sign-in gates, sticky ads, players) aren't page text.
        if (isOverlay(el, st)) return NodeFilter.FILTER_REJECT;
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
        href: own.href,
        links: own.links,
        tag: el.tagName.toLowerCase(),
        size: size, bold: bold, italic: italic, family: family, link: link,
        color: st.color, transform: st.textTransform,
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
          link: b.link, color: b.color, transform: b.transform, chars: 0, count: 0, sample: '', blocks: [] };
        groups.push(g);
      }
      g.chars += b.text.length;
      g.count++;
      g.blocks.push(b.text);
    });
    // The sample is the first block that's typical of the group, not a stray label
    // ("Live") that happens to come first: at least half as long as its longest block.
    groups.forEach(function (g) {
      var longest = Math.max.apply(null, g.blocks.map(function (t) { return t.length; }));
      var text = g.blocks.filter(function (t) { return t.length >= Math.min(40, longest / 2); })[0] || g.blocks[0];
      g.sample = text.replace(/\n/g, ' ').slice(0, opts.sampleChars);
      delete g.blocks;
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

  // Article pages say so in their Open Graph type; section fronts say "website".
  function isArticle() {
    var og = document.querySelector('meta[property="og:type"]');
    return !!og && /article/i.test(og.content || '');
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
      article: isArticle(),
      groups: groups,
      blocks: blocks.map(function (b) {
        var out = { g: b.g, text: b.text, tag: b.tag };
        if (b.href) out.href = b.href;
        else if (b.links.length) out.links = b.links;
        return out;
      }),
    };
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.lift = lift;
})();
