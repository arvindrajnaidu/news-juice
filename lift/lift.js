// News Juice "lift": pull the article out of a rendered page using font sizes.
//
// Idea: on a text-heavy page, the article body is the font size that carries
// the most text. Find that size, keep the blocks set in it, find the container
// that holds most of them, and read that container top to bottom. Text in a
// bigger size inside the container becomes headings.
//
// Runs in any browser context (desktop page, bookmarklet, mobile webview).
// Exposes window.NewsJuice.lift(options) -> result object.
(function () {
  var DEFAULTS = {
    minBlockChars: 40,      // body blocks shorter than this don't vote on the body size
    maxLinkDensity: 0.5,    // blocks that are mostly links are navigation, not prose
    sizeTolerance: 1,       // px either side of the body size still counts as body
    smallerProse: 3,        // inside the article, sentences up to this many px smaller are kept too (quotes, captions)
    containerShare: 0.75,   // descend into a child while it holds this share of body text
    minHeadingChars: 3,
  };

  var BLOCK_TAGS = /^(P|LI|BLOCKQUOTE|PRE|H[1-6]|DD|DT|FIGCAPTION|TD|DIV|SECTION|ARTICLE|SPAN)$/;
  var SKIP_TAGS = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|CANVAS|IFRAME|BUTTON|SELECT|TEXTAREA|INPUT|LABEL|NAV|FORM)$/;
  var HEADING = /^H[1-6]$/;

  function isHidden(el, style) {
    if (style.display === 'none' || style.visibility === 'hidden' || +style.opacity === 0) return true;
    var r = el.getBoundingClientRect();
    return r.width === 0 && r.height === 0;
  }

  // Text that belongs to this element directly (its own text nodes plus inline
  // children), not text inside nested block elements.
  function ownText(el) {
    var out = '';
    var linkChars = 0;
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        out += n.nodeValue;
      } else if (n.nodeType === 1 && !SKIP_TAGS.test(n.tagName)) {
        var d = getComputedStyle(n).display;
        if (d.indexOf('inline') === 0 || n.tagName === 'BR') {
          var t = n.tagName === 'BR' ? '\n' : n.textContent;
          out += t;
          if (n.tagName === 'A' || n.querySelector('a')) linkChars += t.length;
        }
      }
    }
    var text = out.replace(/[ \t\r\f\v]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
    return { text: text, linkDensity: text.length ? Math.min(1, linkChars / text.length) : 0 };
  }

  function collectBlocks(root) {
    var blocks = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (el) {
        if (SKIP_TAGS.test(el.tagName)) return NodeFilter.FILTER_REJECT;
        var st = getComputedStyle(el);
        if (isHidden(el, st)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    var order = 0;
    for (var el = walker.currentNode; el; el = walker.nextNode()) {
      if (!BLOCK_TAGS.test(el.tagName)) continue;
      var st = getComputedStyle(el);
      if (st.display.indexOf('inline') === 0 && !HEADING.test(el.tagName)) continue;
      var own = ownText(el);
      if (!own.text) continue;
      blocks.push({
        el: el,
        order: order++,
        tag: el.tagName,
        text: own.text,
        chars: own.text.length,
        linkDensity: own.linkDensity,
        size: Math.round(parseFloat(st.fontSize)),
        weight: parseInt(st.fontWeight, 10) || 400,
      });
    }
    return blocks;
  }

  // Font size -> characters of prose set in that size.
  function sizeHistogram(blocks, opts) {
    var hist = {};
    blocks.forEach(function (b) {
      if (b.chars < opts.minBlockChars || b.linkDensity > opts.maxLinkDensity) return;
      hist[b.size] = (hist[b.size] || 0) + b.chars;
    });
    return hist;
  }

  function pickBodySize(hist) {
    var best = null;
    Object.keys(hist).forEach(function (s) {
      if (best === null || hist[s] > hist[best]) best = s;
    });
    return best === null ? null : +best;
  }

  // Start at <body>; step into whichever child holds most of the body text,
  // as long as it holds at least containerShare of it.
  function findContainer(bodyBlocks, opts) {
    var weight = new Map();
    bodyBlocks.forEach(function (b) {
      for (var a = b.el; a && a !== document.documentElement; a = a.parentElement) {
        weight.set(a, (weight.get(a) || 0) + b.chars);
      }
    });
    var node = document.body;
    for (;;) {
      var total = weight.get(node) || 0;
      var next = null;
      for (var c = node.firstElementChild; c; c = c.nextElementSibling) {
        if ((weight.get(c) || 0) >= total * opts.containerShare) { next = c; break; }
      }
      if (!next) return node;
      node = next;
    }
  }

  function pickTitle(blocks, container) {
    var og = document.querySelector('meta[property="og:title"]');
    var h1s = blocks.filter(function (b) { return b.tag === 'H1'; });
    // Prefer an h1 just before or inside the article container.
    for (var i = 0; i < h1s.length; i++) {
      if (container.contains(h1s[i].el) ||
          (h1s[i].el.compareDocumentPosition(container) & Node.DOCUMENT_POSITION_FOLLOWING)) {
        return h1s[i].text;
      }
    }
    if (h1s.length) return h1s[0].text;
    return og ? og.content : document.title;
  }

  function lift(options) {
    var opts = Object.assign({}, DEFAULTS, options || {});
    var blocks = collectBlocks(document.body);
    var hist = sizeHistogram(blocks, opts);
    var bodySize = pickBodySize(hist);
    if (bodySize === null) {
      return { ok: false, reason: 'no prose found', histogram: hist, blocks: [] };
    }
    var isBody = function (b) {
      return Math.abs(b.size - bodySize) <= opts.sizeTolerance &&
             b.linkDensity <= opts.maxLinkDensity;
    };
    var bodyBlocks = blocks.filter(function (b) { return isBody(b) && b.chars >= opts.minBlockChars; });
    var container = findContainer(bodyBlocks, opts);

    var title = pickTitle(blocks, container);
    var out = [];
    blocks.forEach(function (b) {
      if (!container.contains(b.el)) return;
      if (b.text === title) return;
      if (isBody(b)) {
        // Short body-size lines (bylines, "Also read" stubs) are kept only if
        // they look like sentences.
        if (b.chars < opts.minBlockChars && !/[.!?"”]$/.test(b.text)) return;
        out.push({ kind: kindOf(b), text: b.text });
      } else if (b.size < bodySize && b.size >= bodySize - opts.smallerProse &&
                 b.chars >= opts.minBlockChars && b.linkDensity <= opts.maxLinkDensity &&
                 /[.!?"”]$/.test(b.text)) {
        out.push({ kind: kindOf(b), text: b.text });
      } else if (b.size > bodySize + opts.sizeTolerance &&
                 b.chars >= opts.minHeadingChars && b.chars <= 200 &&
                 b.linkDensity <= opts.maxLinkDensity) {
        out.push({ kind: 'h', text: b.text });
      }
    });

    var bodyChars = out.reduce(function (n, b) { return n + (b.kind === 'h' ? 0 : b.text.length); }, 0);
    return {
      ok: bodyChars > 0,
      url: location.href,
      title: title,
      bodySize: bodySize,
      histogram: hist,
      container: describe(container),
      bodyChars: bodyChars,
      pageChars: blocks.reduce(function (n, b) { return n + b.chars; }, 0),
      blocks: out,
    };
  }

  function kindOf(b) {
    if (b.tag === 'LI') return 'li';
    if (b.tag === 'BLOCKQUOTE' || b.el.closest('blockquote')) return 'quote';
    return 'p';
  }

  function describe(el) {
    var s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    if (el.classList.length) s += '.' + Array.prototype.slice.call(el.classList, 0, 3).join('.');
    return s;
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.lift = lift;
})();
