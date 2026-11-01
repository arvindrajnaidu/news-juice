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
    // The whole layer multiplies with the page, so washes tint the text without hiding it.
    '#nj-pick{position:absolute;left:0;top:0;width:0;height:0;z-index:2147483646;pointer-events:none;',
    '  mix-blend-mode:multiply}',
    '#nj-pick-shield{position:fixed;inset:0;z-index:2147483647;background:transparent}',
    '.nj-box{position:absolute;box-sizing:border-box;border-radius:3px;outline:1px dashed rgba(107,100,88,.45);',
    '  outline-offset:2px;transition:outline-color .25s}',
    // Text in the filter gets an amber wash.
    '.nj-box::before{content:"";position:absolute;inset:-2px;border-radius:3px;background:transparent;',
    '  transition:background .25s}',
    '.nj-box.on::before{background:#fbe0a0}',
    '.nj-box::after{content:"";position:absolute;left:-6px;top:-2px;bottom:-2px;width:3px;border-radius:2px;',
    '  background:#e8a317;transform:scaleY(0);transition:transform .25s}',
    '.nj-box.on{outline-color:transparent}.nj-box.on::after{transform:none}',
  ].join('\n');

  function post(msg) {
    try { webkit.messageHandlers.njPick.postMessage(msg); } catch (e) { /* not in the app */ }
  }

  // Sticky headers, cookie banners and other fixed layers would sit over the text and
  // catch taps; they're hidden while picking and put back afterwards.
  function hideFixed(hidden) {
    document.querySelectorAll('body *').forEach(function (el) {
      if (el.id && el.id.indexOf('nj-pick') === 0) return;
      if (hidden.some(function (h) { return h[0] === el; })) return;
      var pos = getComputedStyle(el).position;
      if (pos !== 'fixed' && pos !== 'sticky') return;
      hidden.push([el, el.style.getPropertyValue('visibility'), el.style.getPropertyPriority('visibility')]);
      el.style.setProperty('visibility', 'hidden', 'important');
    });
    return hidden;
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
    var layer = document.createElement('div');
    layer.id = 'nj-pick';
    var shield = document.createElement('div');
    shield.id = 'nj-pick-shield';
    shield.setAttribute('aria-hidden', 'true');
    // Ads and banners that turn up later are hidden as they arrive.
    var hidden = hideFixed([]);
    var sweep = setInterval(function () { hideFixed(hidden); }, 1000);
    document.documentElement.classList.add('nj-picking');
    document.documentElement.append(style, layer, shield);

    // One box per block, in document coordinates, so it scrolls with the page.
    var boxes = [];
    var sx = scrollX, sy = scrollY;
    els.forEach(function (el, i) {
      if (!el || !el.isConnected) return;
      var r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return;
      var g = gs[i];
      var box = document.createElement('div');
      box.className = 'nj-box';
      box.style.cssText = 'left:' + (r.left + sx) + 'px;top:' + (r.top + sy) + 'px;width:' + r.width + 'px;height:' + r.height + 'px';
      box.setAttribute('role', 'button');
      // VoiceOver activates the box itself (the shield is hidden from it).
      box.addEventListener('click', function (e) { e.stopPropagation(); toggle(g); });
      layer.appendChild(box);
      boxes.push({ g: g, box: box, top: r.top + sy, left: r.left + sx, w: r.width, h: r.height,
        text: (el.innerText || '').trim().slice(0, 80) });
    });

    var spots = {};
    boxes.forEach(function (b) { spots[b.g] = (spots[b.g] || 0) + 1; });

    function paint() {
      boxes.forEach(function (b) {
        var on = keep.indexOf(b.g) >= 0;
        var kind = kinds[b.g] || 'Text';
        b.box.classList.toggle('on', on);
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
    // Keep presses and long-presses from reaching the site underneath.
    ['touchstart', 'touchend', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu'].forEach(function (t) {
      shield.addEventListener(t, function (e) { e.stopPropagation(); if (t === 'contextmenu') e.preventDefault(); },
        { passive: t !== 'contextmenu' });
    });

    paint();
    state = { style: style, layer: layer, shield: shield, hidden: hidden, sweep: sweep };
    return true;
  }

  function stop() {
    if (!state) return;
    clearInterval(state.sweep);
    [state.style, state.layer, state.shield].forEach(function (n) { n.remove(); });
    state.hidden.forEach(function (h) {
      if (h[1]) h[0].style.setProperty('visibility', h[1], h[2]);
      else h[0].style.removeProperty('visibility');
    });
    document.documentElement.classList.remove('nj-picking');
    state = null;
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.pickStart = start;
  window.NewsJuice.pickStop = stop;
})();
