// News Lens: pick a filter on the real page.
//
// Runs in the same isolated content world as lift.js, after a lift: every text block
// lift.js found gets a box over it (a dashed outline; amber when in the filter), the rest
// of the page has its images faded and fixed layers hidden, and a transparent shield on top takes
// every tap, so the site's own scripts never see them. Tapping text toggles its whole
// style group: every block in that style lights up (or goes out) together.
//
//   NewsJuice.pickStart({ keep: [groupIds], kinds: { groupId: 'Article text', ... } })
//   NewsJuice.pickStop()
//
// Each toggle is posted to the app (messageHandlers.njPick):
//   { type: 'pickToggle', g, kind, on, spots, keep }
(function () {
  var state = null;

  var CSS = [
    'html.nj-picking img,html.nj-picking video,html.nj-picking iframe,html.nj-picking picture,',
    'html.nj-picking canvas,html.nj-picking svg{opacity:.2!important;transition:opacity .25s}',
    // No blend modes: some pages composite their text in layers a blend can't reach, and
    // the wash then hides the text. A see-through tint works everywhere.
    '#nj-pick{position:absolute;left:0;top:0;width:0;height:0;z-index:2147483646;pointer-events:none}',
    // Under the boxes, text outside the filter is washed out, so the picks stand out.
    '#nj-pick-wash{position:absolute;left:0;top:0;width:0;height:0;z-index:2147483645;pointer-events:none}',
    '.nj-wash{position:absolute;background:rgba(246,243,236,.6);border-radius:3px;transition:opacity .25s}',
    '.nj-wash.on{opacity:0}',
    '#nj-pick-shield{position:fixed;inset:0;z-index:2147483647;background:transparent}',
    '.nj-box{position:absolute;box-sizing:border-box;border-radius:3px;outline:1px dashed rgba(107,100,88,.45);',
    '  outline-offset:2px;transition:outline-color .25s}',
    // Text in the filter gets an amber wash.
    '.nj-box::before{content:"";position:absolute;inset:-2px;border-radius:3px;background:transparent;',
    '  transition:background .25s}',
    '.nj-box.on::before{background:rgba(245,200,60,.35)}',
    '.nj-box::after{content:"";position:absolute;left:-6px;top:-2px;bottom:-2px;width:3px;border-radius:2px;',
    '  background:#d9a400;transform:scaleY(0);transition:transform .25s}',
    '.nj-box.on{outline-color:transparent}.nj-box.on::after{transform:none}',
  ].join('\n');

  function post(msg) {
    try { webkit.messageHandlers.njPick.postMessage(msg); } catch (e) { /* not in the app */ }
  }

  // Sticky headers, cookie banners and other fixed layers would sit over the text and
  // catch taps; they're hidden while picking and put back afterwards.
  // Each element is looked at once (seen), so later sweeps only cost the new ones.
  function hideFixed(hidden, seen) {
    document.querySelectorAll('body *').forEach(function (el) {
      if (seen.has(el)) return;
      seen.add(el);
      if (el.id && el.id.indexOf('nj-pick') === 0) return;
      var pos = getComputedStyle(el).position;
      if (pos !== 'fixed' && pos !== 'sticky') return;
      hidden.push([el, el.style.getPropertyValue('visibility'), el.style.getPropertyPriority('visibility')]);
      el.style.setProperty('visibility', 'hidden', 'important');
    });
    return hidden;
  }

  // Ads in the page itself (full-screen in-article ads, ad slots, third-party frames)
  // push the text out of reach; they're collapsed while picking. Never one that holds
  // any of the page's text.
  var AD = /(^|[\s_-])(ad|ads|adv|advert\w*|ad-?slot|ad-?unit|ad-?container|sponsor\w*|dfp|gpt-ad|taboola|outbrain|promoted)([\s_-]|$)/i;
  // holding: every element that contains some of the page's text (built once).
  function collapseAds(collapsed, holding, seen) {
    var holdsText = function (el) { return holding.has(el); };
    var collapse = function (el) {
      if (collapsed.some(function (c) { return c[0] === el; }) || holdsText(el)) return;
      collapsed.push([el, el.style.getPropertyValue('display'), el.style.getPropertyPriority('display')]);
      el.style.setProperty('display', 'none', 'important');
    };
    document.querySelectorAll('iframe, [id], [class]').forEach(function (el) {
      if (seen.has(el)) return;
      seen.add(el);
      if (el.id && el.id.indexOf('nj-pick') === 0) return;
      var name = (el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : '');
      if (el.tagName === 'IFRAME' || AD.test(name)) collapse(el);
    });
    // Video players (ad players most of all): the largest wrapper around each video
    // that holds none of the page's text.
    document.querySelectorAll('video').forEach(function (v) {
      if (seen.has(v)) return;
      seen.add(v);
      var box = v;
      while (box.parentElement && box.parentElement !== document.body && !holdsText(box.parentElement)) box = box.parentElement;
      collapse(box);
    });
    return collapsed;
  }

  // Pop-ups (paywalls, sign-up and consent boxes) lock the page while they're up:
  // overflow hidden, or the body pinned with position fixed. The pop-up itself is
  // hidden while picking, but the lock would stay and the page couldn't scroll. So the
  // page is unlocked while picking, and the site's own settings come back afterwards.
  var UNLOCK = { overflow: 'visible', 'overflow-y': 'auto', height: 'auto', 'max-height': 'none',
    position: 'static', top: 'auto', 'touch-action': 'auto' };
  function unlockScroll() {
    var saved = [];
    [document.documentElement, document.body].forEach(function (el) {
      if (!el) return;
      Object.keys(UNLOCK).forEach(function (prop) {
        saved.push([el, prop, el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)]);
        el.style.setProperty(prop, el === document.documentElement && prop === 'overflow' ? 'auto' : UNLOCK[prop], 'important');
      });
    });
    return saved;
  }

  // The nearest element under a point that scrolls on its own (an inner scroll area),
  // or null when the page itself scrolls there.
  function scrollerAt(x, y) {
    var under = document.elementsFromPoint(x, y).filter(function (el) {
      return !(el.id && el.id.indexOf('nj-pick') === 0) && !el.closest('#nj-pick');
    })[0];
    for (var el = under; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
      var oy = getComputedStyle(el).overflowY;
      if ((oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 4) return el;
    }
    return null;
  }

  function start(opts) {
    stop();
    var els = (window.NewsJuice && NewsJuice._els) || [];
    var gs = (window.NewsJuice && NewsJuice._gs) || [];
    if (!els.length) return false;
    var kinds = opts.kinds || {};
    var keep = (opts.keep || []).slice();

    var style = document.createElement('style');
    style.id = 'nj-pick-style';
    style.textContent = CSS;
    var wash = document.createElement('div');
    wash.id = 'nj-pick-wash';
    var layer = document.createElement('div');
    layer.id = 'nj-pick';
    var shield = document.createElement('div');
    shield.id = 'nj-pick-shield';
    shield.setAttribute('aria-hidden', 'true');
    var holding = new Set();
    els.forEach(function (el) { for (var n = el; n && !holding.has(n); n = n.parentElement) holding.add(n); });
    var seenFixed = new WeakSet(), seenAds = new WeakSet();
    var hidden = hideFixed([], seenFixed);
    var unlocked = unlockScroll();
    var collapsed = collapseAds([], holding, seenAds);
    document.documentElement.classList.add('nj-picking');
    document.documentElement.append(style, wash, layer, shield);

    // One box per block, in document coordinates, so it scrolls with the page.
    var boxes = [];
    var boxed = new WeakSet();
    var spots = {};
    function addBoxes(els, gs) {
      els.forEach(function (el, i) {
        if (!el || !el.isConnected || boxed.has(el)) return;
        boxed.add(el);
        for (var n = el; n && !holding.has(n); n = n.parentElement) holding.add(n);
        addBox(el, gs[i]);
      });
    }
    function addBox(el, g) {
      spots[g] = (spots[g] || 0) + 1;
      var box = document.createElement('div');
      box.className = 'nj-box';
      box.setAttribute('role', 'button');
      // VoiceOver activates the box itself (the shield is hidden from it).
      box.addEventListener('click', function (e) { e.stopPropagation(); toggle(g); });
      layer.appendChild(box);
      var fade = document.createElement('div');
      fade.className = 'nj-wash';
      wash.appendChild(fade);
      boxes.push({ g: g, el: el, box: box, fade: fade, top: 0, left: 0, w: 0, h: 0,
        text: (el.innerText || '').trim().slice(0, 80) });
    }
    addBoxes(els, gs);

    // Pages keep moving after they load (images and ads arrive, fonts swap), so the
    // boxes follow their text, and ads and banners that turn up later are hidden.
    function place() {
      var sx = scrollX, sy = scrollY;
      boxes.forEach(function (b) {
        var r = b.el.isConnected ? b.el.getBoundingClientRect() : { width: 0, height: 0, left: 0, top: 0 };
        var shown = r.width >= 2 && r.height >= 2;
        b.left = r.left + sx; b.top = r.top + sy; b.w = shown ? r.width : 0; b.h = shown ? r.height : 0;
        var css = shown
          ? 'left:' + b.left + 'px;top:' + b.top + 'px;width:' + b.w + 'px;height:' + b.h + 'px'
          : 'display:none';
        b.box.style.cssText = css;
        b.fade.style.cssText = css;
      });
    }
    place();
    // Boxes are re-measured when the page changes size (images, ads and fonts arriving),
    // at most once a frame; new banners and ads are swept up every second.
    var queued = false;
    var replace = function () {
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () { queued = false; place(); });
    };
    var resized = new ResizeObserver(replace);
    resized.observe(document.documentElement);
    var sweep = setInterval(function () {
      hideFixed(hidden, seenFixed); collapseAds(collapsed, holding, seenAds); replace();
    }, 1000);
    addEventListener('resize', replace);

    // Pages that load more as you scroll: once the page has changed and settled, it's
    // read again and the new text gets boxes too (highlighted if its style is already
    // in the filter). Only new elements get boxes; the read waits until the page and
    // the scrolling have settled.
    var changed = false, rescanTimer = null;
    var rescan = function () {
      clearTimeout(rescanTimer);
      rescanTimer = setTimeout(function () {
        if (!changed) return;
        changed = false;
        var before = boxes.length;
        NewsJuice.lift();
        addBoxes(NewsJuice._els || [], NewsJuice._gs || []);
        if (boxes.length !== before) { paint(); replace(); }
      }, 800);
    };
    var watcher = new MutationObserver(function () { changed = true; rescan(); });
    watcher.observe(document.body, { childList: true, subtree: true });
    // Some pages only draw text as it scrolls into view, without changing the page, so
    // stopping scrolling counts as a change too.
    var onScroll = function () { changed = true; rescan(); };
    addEventListener('scroll', onScroll, { passive: true });

    function paint() {
      boxes.forEach(function (b) {
        var on = keep.indexOf(b.g) >= 0;
        var kind = kinds[b.g] || 'Text';
        b.box.classList.toggle('on', on);
        b.fade.classList.toggle('on', on);
        b.box.setAttribute('aria-pressed', on);
        b.box.setAttribute('aria-label', kind + (on ? ', in your filter. ' : ', not in your filter. ') + b.text);
      });
    }

    function toggle(g) {
      var i = keep.indexOf(g);
      if (i >= 0) keep.splice(i, 1); else keep.push(g);
      paint();
      post({ type: 'pickToggle', g: g, kind: kinds[g] || 'Text', on: i < 0, spots: spots[g] || 0, keep: keep.slice() });
    }

    // A tap anywhere lands on the shield: find the smallest box under it.
    function onTap(e) {
      e.preventDefault();
      e.stopPropagation();
      var x = e.pageX, y = e.pageY;
      var hit = null;
      boxes.forEach(function (b) {
        if (x >= b.left - 4 && x <= b.left + b.w + 4 && y >= b.top - 4 && y <= b.top + b.h + 4 &&
            (!hit || b.w * b.h < hit.w * hit.h)) hit = b;
      });
      if (hit) toggle(hit.g);
    }
    shield.addEventListener('click', onTap);
    // The shield sits over everything, so a drag over an inner scroll area would scroll
    // the page instead; it's passed to that area by hand.
    var drag = null;
    shield.addEventListener('touchstart', function (e) {
      var t = e.touches[0];
      var area = t && scrollerAt(t.clientX, t.clientY);
      drag = area ? { area: area, y: t.clientY } : null;
    }, { passive: true });
    shield.addEventListener('touchmove', function (e) {
      if (!drag) return;
      var t = e.touches[0];
      var dy = drag.y - t.clientY;
      var before = drag.area.scrollTop;
      drag.area.scrollTop += dy;
      drag.y = t.clientY;
      // Hand over to the page at the area's ends.
      if (drag.area.scrollTop !== before) e.preventDefault();
    }, { passive: false });
    // Keep presses and long-presses from reaching the site underneath.
    ['touchstart', 'touchend', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu'].forEach(function (t) {
      shield.addEventListener(t, function (e) { e.stopPropagation(); if (t === 'contextmenu') e.preventDefault(); },
        { passive: t !== 'contextmenu' });
    });

    paint();
    state = { style: style, wash: wash, layer: layer, shield: shield, hidden: hidden, collapsed: collapsed, unlocked: unlocked,
      sweep: sweep, replace: replace, resized: resized, watcher: watcher, onScroll: onScroll,
      rescanTimer: function () { return rescanTimer; } };
    return true;
  }

  function stop() {
    if (!state) return;
    clearInterval(state.sweep);
    state.resized.disconnect();
    state.watcher.disconnect();
    clearTimeout(state.rescanTimer());
    removeEventListener('scroll', state.onScroll);
    removeEventListener('resize', state.replace);
    [state.style, state.wash, state.layer, state.shield].forEach(function (n) { n.remove(); });
    state.hidden.forEach(function (h) {
      if (h[1]) h[0].style.setProperty('visibility', h[1], h[2]);
      else h[0].style.removeProperty('visibility');
    });
    state.unlocked.forEach(function (u) {
      if (u[2]) u[0].style.setProperty(u[1], u[2], u[3]); else u[0].style.removeProperty(u[1]);
    });
    state.collapsed.forEach(function (c) {
      if (c[1]) c[0].style.setProperty('display', c[1], c[2]);
      else c[0].style.removeProperty('display');
    });
    document.documentElement.classList.remove('nj-picking');
    state = null;
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.pickStart = start;
  window.NewsJuice.pickStop = stop;
})();
