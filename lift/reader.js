// "Tap to lift" reader for a lift() result.
//
// Two modes on one sheet:
//  - Pick ("Edit lifts"): one card per style group, in page order, each showing a
//    real sample in the page's own style plus a plain name (Headline, Article
//    text, Link list...). Tap a card to lift it, tap again to drop it.
//  - Read: tapping "Read N lifted" turns the lifted cards into the article in
//    place (unlifted ones fold away, the type settles into the reader style), then
//    shows every block of the lifted groups in page order.
// The lifted set is the site's "recipe": saved per host when you tap Read, and
// applied straight away (straight to Read) the next time you lift on that site.
// A site with no recipe opens in Pick with the biggest prose group lifted.
//
// Exposes window.NewsJuice.showReader(result, { recipe }), NewsJuice.setMode('pick'|
// 'read') and NewsJuice.renderHTML(result). In the iOS app this runs in the app's
// own reader view (www/reader.html): recipes are saved, and the mode and tapped
// links reported, through its `newsJuice` message handler. Elsewhere (bookmarklet)
// recipes go to localStorage and Escape closes the sheet.
(function () {
  var SPRING = 'cubic-bezier(0.2, 0.9, 0.2, 1.1)';
  var INK = '#1d1b18';
  var CSS = [
    ':host{all:initial}',
    '.nj-sheet{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;overflow-x:hidden;color:' + INK + ';',
    '  font:15px/1.4 -apple-system,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased;',
    '  -webkit-text-size-adjust:100%;transition:background-color .5s ease;background:#ece8e0}',
    '.nj-sheet.read{background:#fbf8f2}',
    '.nj-intro{margin:0;padding:14px 16px 8px;font-size:13px;color:#4a453d;overflow:hidden;max-height:60px;',
    '  transition:max-height .4s ease,opacity .3s ease,padding .4s ease}',
    '.read .nj-intro{max-height:0;opacity:0;padding:0 16px}',
    '.nj-reset{display:block;margin:0 16px 4px;padding:6px 0;border:0;background:none;',
    'font:600 14px -apple-system,system-ui,sans-serif;color:#6b6458}',
    '.nj-reset[hidden],.read .nj-reset{display:none}',
    '.nj-list{display:flex;flex-direction:column;padding:6px 14px 0;transition:padding .45s ease}',
    '.read .nj-list{padding:22px 24px 0}',
    '.nj-card{display:flex;flex-direction:column;align-items:flex-start;gap:6px;width:100%;box-sizing:border-box;',
    '  overflow:hidden;border:0;text-align:left;font:inherit;color:' + INK + ';cursor:pointer;-webkit-tap-highlight-color:transparent;',
    '  -webkit-user-select:none;user-select:none;-webkit-touch-callout:none;',
    '  max-height:400px;padding:12px 14px;margin:0 0 10px;border-radius:10px;',
    '  background:rgba(255,255,255,.35);opacity:.62;transform:none;box-shadow:none;',
    '  transition:transform .45s ' + SPRING + ' var(--d,0ms),box-shadow .45s ease var(--d,0ms),background-color .45s ease,',
    '    opacity .35s ease,max-height .5s ease,padding .45s ease var(--d,0ms),margin .45s ease,border-radius .45s ease}',
    '.nj-card.on{background:#fff;opacity:1;transform:translateY(-4px) scale(1.02);',
    '  box-shadow:0 14px 28px rgba(29,27,24,.20),0 2px 6px rgba(29,27,24,.10)}',
    '.read .nj-card{pointer-events:none;background:rgba(255,255,255,0);box-shadow:none;border-radius:0;margin:0}',
    '.read .nj-card.on{transform:none;opacity:1;padding:0 0 14px}',
    '.read .nj-card:not(.on){transform:translateY(-12px);opacity:0;max-height:0;padding:0}',
    '.nj-sample{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden;',
    '  font-size:var(--ps);font-weight:var(--pw);font-style:var(--pi);color:var(--pc);text-decoration:var(--pd);',
    '  text-transform:var(--pt);font-family:var(--pf);line-height:1.3;',
    '  transition:font-size .45s ease var(--d,0ms),line-height .45s ease,color .45s ease}',
    '.read .nj-sample{-webkit-line-clamp:6;color:' + INK + ';text-decoration:none;text-transform:none}',
    '.read .role-head .nj-sample{font:700 28px/1.2 Georgia,"Iowan Old Style",serif}',
    '.read .role-sub .nj-sample{font:700 21px/1.3 Georgia,"Iowan Old Style",serif}',
    '.read .role-body .nj-sample{font:400 19px/1.6 Georgia,"Iowan Old Style",serif}',
    '.read .role-small .nj-sample{font:400 14px/1.45 -apple-system,system-ui,sans-serif;color:#7a7368}',
    '.nj-badge{font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px;overflow:hidden;max-height:24px;',
    '  background:#d9d2c5;color:#3d3830;transition:opacity .25s ease,max-height .3s ease}',
    '.on .nj-badge{background:#e8a317;color:' + INK + '}',
    '.read .nj-badge{opacity:0;max-height:0;padding:0}',
    '.nj-pad{height:120px}',
    '.nj-readbtn{position:fixed;left:16px;right:16px;bottom:calc(env(safe-area-inset-bottom) + 12px);height:54px;border:0;',
    '  border-radius:16px;background:#e8a317;color:' + INK + ';font:600 17px -apple-system,system-ui,sans-serif;display:flex;',
    '  align-items:center;justify-content:center;gap:8px;box-shadow:0 10px 24px rgba(29,27,24,.22);z-index:3;',
    '  transition:transform .4s cubic-bezier(.2,.9,.2,1),opacity .3s ease}',
    '.nj-readbtn:disabled{background:#e6dfd2;color:#7a7368;box-shadow:none}',
    '.nj-readbtn .nj-label{display:flex;flex-direction:column;align-items:flex-start;line-height:1.15}',
    '.nj-readbtn small{font-size:12px;font-weight:500;opacity:.75}',
    '.read .nj-readbtn{transform:translateY(140px);opacity:0;pointer-events:none}',
    '@keyframes nj-in{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}',
    '.nj-enter .nj-card{animation:nj-in .45s ' + SPRING + ' backwards;animation-delay:var(--e,0ms)}',
    // The article, in page order.
    '.nj-article{max-width:38rem;margin:0 auto;padding:22px 24px 80px;font:19px/1.6 Georgia,"Iowan Old Style",serif;',
    '  overflow-wrap:break-word;transition:opacity .25s ease}',
    '.nj-article.hidden{display:none}',
    '.nj-article.fade{opacity:0}',
    '.nj-article h1{font-size:28px;line-height:1.2;margin:0 0 .7em}',
    '.nj-article h2{font-size:21px;line-height:1.3;margin:1.3em 0 .4em}',
    '.nj-article p,.nj-article li{margin:0 0 1em}',
    '.nj-article .small{font:14px/1.45 -apple-system,system-ui,sans-serif;color:#7a7368}',
    '.nj-article a{color:inherit;text-decoration:underline;text-decoration-color:#c9c2b6;text-underline-offset:.18em}',
    '.nj-article .nj-speaking{background:rgba(232,163,23,.16);box-shadow:0 0 0 8px rgba(232,163,23,.16);border-radius:3px}',
    '.listening .nj-article{padding-bottom:170px}',
    '.nj-article .src{font:13px -apple-system,system-ui,sans-serif;color:#7a7368;word-break:break-all;margin-top:2em}',
    '@media (prefers-color-scheme:dark){.nj-sheet{background:#22201c;color:#e8e3da}.nj-sheet.read{background:#1a1916}',
    '  .nj-card{color:#e8e3da;background:rgba(255,255,255,.06)}.nj-card.on{background:#2e2b26}',
    '  .read .nj-sample{color:#e8e3da}.nj-intro{color:#b3ab9f}.nj-reset{color:#b3ab9f}.nj-badge{background:#3a372f;color:#cfc8bb}}',
  ].join('\n');

  var STORE_PREFIX = 'newsjuice:recipe:';
  var current = null; // the reader on screen, if any

  function inApp() {
    return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.newsJuice);
  }

  // Tells the iOS app (when running in it) about the reader, so its top bar can follow.
  function notifyApp(message) {
    if (inApp()) window.webkit.messageHandlers.newsJuice.postMessage(message);
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  function proseGroup(r) {
    return r.groups.filter(function (x) { return !x.link; })[0];
  }

  // With nothing saved, keep the group with the most prose (not a link list). On a
  // section front whose headline list clearly outweighs any prose, keep the headlines.
  function defaultKeep(r) {
    var prose = proseGroup(r);
    var headlines = r.groups.filter(function (x) { return x.link && x.chars / x.count >= 30; })[0];
    if (!r.article && headlines && (!prose || headlines.chars > 2 * prose.chars)) return [headlines.id];
    var g = prose || r.groups[0];
    return g ? [g.id] : [];
  }

  function storedRecipe(r, given) {
    if (given) return given;
    try { return JSON.parse(localStorage.getItem(STORE_PREFIX + r.host) || 'null'); } catch (e) { return null; }
  }

  function onPage(r) {
    var present = {};
    r.groups.forEach(function (g) { present[g.id] = true; });
    return present;
  }

  // A saved group's id on this page: the same signature, or the same one a pixel
  // bigger or smaller (sites nudge their type sizes now and then).
  function matchId(id, present) {
    if (present[id]) return id;
    var m = /^(\d+)px(.*)$/.exec(id);
    if (!m) return null;
    var up = (+m[1] + 1) + 'px' + m[2], down = (+m[1] - 1) + 'px' + m[2];
    return present[up] ? up : present[down] ? down : null;
  }

  // The groups of a recipe that are on this page, or null if none are.
  function matchRecipe(r, recipe) {
    if (!recipe) return null;
    var present = onPage(r), keep = [];
    recipe.forEach(function (id) {
      var m = matchId(id, present);
      if (m && keep.indexOf(m) < 0) keep.push(m);
    });
    return keep.length ? keep : null;
  }

  function loadRecipe(r, given) {
    return matchRecipe(r, storedRecipe(r, given));
  }

  // keep null forgets the site's recipe.
  function saveRecipe(host, keep) {
    if (inApp()) {
      notifyApp({ type: 'saveRecipe', host: host, keep: keep });
      return;
    }
    try {
      if (keep) localStorage.setItem(STORE_PREFIX + host, JSON.stringify(keep));
      else localStorage.removeItem(STORE_PREFIX + host);
    } catch (e) { /* storage blocked */ }
  }

  function sameSet(a, b) {
    return a.length === b.length && a.every(function (id) { return b.indexOf(id) >= 0; });
  }

  function byId(r) {
    var m = {};
    r.groups.forEach(function (g) { m[g.id] = g; });
    return m;
  }

  // Groups in the order their first block appears on the page.
  function pageOrder(r) {
    var seen = {};
    var out = [];
    var groups = byId(r);
    r.blocks.forEach(function (b) {
      if (!seen[b.g]) { seen[b.g] = true; out.push(groups[b.g]); }
    });
    return out;
  }

  // A plain name for a group, guessed from its size, weight, links and length.
  function kindOf(g, r) {
    var body = proseGroup(r);
    var base = body ? body.size : 16;
    var avg = g.chars / g.count;
    var biggest = 0;
    r.groups.forEach(function (x) { if (!x.link && x.size > biggest) biggest = x.size; });
    if (g.link) {
      if (/video/i.test(g.sample)) return 'Video titles';
      return avg < 25 ? 'Menu links' : 'Link list';
    }
    if (body && g.id === body.id) return 'Article text';
    if (g.size === biggest && g.size > base + 2 && g.count <= 2) return 'Headline';
    if (g.size > base + 1) return avg < 120 ? 'Subheads' : 'Summary';
    if (/^(by |edited by|updated|published|written by)/i.test(g.sample) || /\b(IST|EDT|EST|GMT|BST|ago)\b/.test(g.sample)) return 'Byline';
    if (avg <= 20 || g.transform === 'uppercase') return 'Labels';
    if (g.size >= base - 1 && avg >= 80 && g.count <= 3) return 'Summary';
    if (g.size >= base - 1 && (g.bold || (body && g.family !== body.family)) && avg < 150) return 'Subheads';
    if (g.size < base) return avg >= 40 ? 'Captions' : 'Labels';
    return 'Other text';
  }

  // How a group reads once lifted, relative to the biggest kept prose group.
  function roleOf(g, base, headSize) {
    if (g.size >= headSize && g.size > base + 4) return 'head';
    if (g.size > base + 1) return 'sub';
    if (g.size < base - 1) return 'small';
    return 'body';
  }

  function readBase(r, keep) {
    var groups = byId(r);
    var kept = keep.map(function (id) { return groups[id]; }).filter(Boolean)
      .sort(function (a, b) { return b.chars - a.chars; });
    var prose = kept.filter(function (g) { return !g.link; })[0] || kept[0];
    var base = prose ? prose.size : 16;
    var headSize = 0;
    kept.forEach(function (g) { if (g.size > headSize) headSize = g.size; });
    return { base: base, headSize: headSize };
  }

  // A block's text as HTML, with its links (the whole block, or ranges in it) as <a>.
  function textHTML(b) {
    var br = function (s) { return esc(s).replace(/\n/g, '<br>'); };
    var link = function (href, s) { return '<a href="' + esc(href) + '">' + br(s) + '</a>'; };
    if (b.href) return link(b.href, b.text);
    var html = '';
    var at = 0;
    (b.links || []).forEach(function (l) {
      if (l[0] < at) return;
      html += br(b.text.slice(at, l[0])) + link(l[2], b.text.slice(l[0], l[1]));
      at = l[1];
    });
    return html + br(b.text.slice(at));
  }

  // The lifted groups' blocks in page order, as the article.
  function articleHTML(r, keep) {
    var kept = {};
    keep.forEach(function (id) { kept[id] = true; });
    var groups = byId(r);
    var sizes = readBase(r, keep);
    var html = '';
    var inList = false;
    var headDone = false;
    r.blocks.forEach(function (b) {
      if (!kept[b.g]) return;
      var role = roleOf(groups[b.g], sizes.base, sizes.headSize);
      var isLi = b.tag === 'li' && role !== 'head';
      if (isLi && !inList) { html += '<ul>'; inList = true; }
      if (!isLi && inList) { html += '</ul>'; inList = false; }
      var t = textHTML(b);
      if (role === 'head' && !headDone && b.text.length <= 200) { html += '<h1>' + t + '</h1>'; headDone = true; }
      else if ((role === 'head' || role === 'sub') && b.text.length <= 200) html += '<h2>' + t + '</h2>';
      else if (isLi) html += '<li>' + t + '</li>';
      else if (role === 'small') html += '<p class="small">' + t + '</p>';
      else html += '<p>' + t + '</p>';
    });
    if (inList) html += '</ul>';
    return html + '<p class="src">' + esc(r.url || '') + '</p>';
  }

  // The page's own text colour for a sample, unless it's too pale to read on a card
  // (white text from a dark site header).
  function sampleColor(c) {
    var m = /rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/.exec(c || '');
    if (!m) return INK;
    var lum = (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255;
    return lum > 0.75 || (m[4] !== undefined && +m[4] < 0.5) ? INK : c;
  }

  function cardHTML(r, keep) {
    var sizes = readBase(r, keep);
    return pageOrder(r).map(function (g, i) {
      var on = keep.indexOf(g.id) >= 0;
      var kind = kindOf(g, r);
      var vars = '--ps:' + Math.min(g.size, 30) + 'px;--pw:' + (g.bold ? 700 : 400) + ';--pi:' + (g.italic ? 'italic' : 'normal') +
        ';--pc:' + sampleColor(g.color) + ';--pd:' + (g.link ? 'underline' : 'none') + ';--pt:' + (g.transform || 'none') +
        ';--pf:"' + (g.family || '').replace(/"/g, '') + '",-apple-system,system-ui,sans-serif;--e:' + Math.min(i, 12) * 35 + 'ms';
      return '<button class="nj-card role-' + roleOf(g, sizes.base, sizes.headSize) + (on ? ' on' : '') + '" data-g="' + esc(g.id) +
        '" data-kind="' + esc(kind) + '" aria-pressed="' + on + '" style="' + esc(vars) + '">' +
        '<span class="nj-sample">' + esc(g.sample) + '</span>' +
        '<span class="nj-badge">' + esc(kind) + ' · ' + g.count + '</span></button>';
    }).join('');
  }

  // Standalone page with the default (or saved) selection, used by the test harness.
  function renderHTML(r) {
    var keep = loadRecipe(r) || defaultKeep(r);
    return '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>' + esc(r.title || 'Filtered') + '</title><style>' + CSS.replace(/\.nj-sheet\{position:fixed;inset:0;/, '.nj-sheet{') +
      '</style><div class="nj-sheet read"><div class="nj-article">' + articleHTML(r, keep) + '</div></div>';
  }

  function showReader(r, opts) {
    opts = opts || {};
    var old = document.getElementById('news-juice-reader');
    if (old) old.remove();
    // The user's own recipe wins; otherwise a suggested one (from the filter server
    // or bundled with the app), passed in by the app as opts.suggested.
    var saved = loadRecipe(r, opts.recipe);
    var groups = byId(r);
    var body = proseGroup(r);
    // On an article, a recipe that only matches link lists here (the nav on an article
    // can look just like the headlines on a section front) still needs the body text.
    var repair = function (ids) {
      if (!ids) return null;
      var linkOnly = ids.every(function (id) { return groups[id] && groups[id].link; });
      return r.article && linkOnly && body ? ids.concat(body.id) : ids;
    };
    saved = repair(saved);
    var suggested = repair(matchRecipe(r, opts.suggested));
    var source = saved ? 'own' : suggested ? 'suggested' : 'none';
    // A site's recipe covers all its page types (section fronts and articles style
    // their text differently), so saving keeps the groups that aren't on this page.
    var present = onPage(r);
    var elsewhere = (storedRecipe(r, opts.recipe) || []).filter(function (id) { return !matchId(id, present); });
    var keep = (saved || suggested || defaultKeep(r)).slice();
    // A site with a recipe reads straight away; a new site (or a new kind of page on
    // it) starts by picking.
    var mode = opts.mode || (saved || suggested ? 'read' : 'pick');

    var host = document.createElement('div');
    host.id = 'news-juice-reader';
    var root = host.attachShadow({ mode: 'open' });
    root.innerHTML = '<style>' + CSS + '</style><div class="nj-sheet ' + mode + '">' +
      '<p class="nj-intro">One sample of every kind of text on this page. Tap what you want to read; tap again to drop it.</p>' +
      '<button class="nj-reset" hidden>Reset to suggested</button>' +
      '<div class="nj-list"></div><div class="nj-article hidden"></div><div class="nj-pad"></div>' +
      '<button class="nj-readbtn"></button></div>';
    document.documentElement.appendChild(host);

    var sheet = root.querySelector('.nj-sheet');
    var list = root.querySelector('.nj-list');
    var article = root.querySelector('.nj-article');
    var readBtn = root.querySelector('.nj-readbtn');
    var resetBtn = root.querySelector('.nj-reset');
    var busy = false;

    var report = function () {
      notifyApp({ type: 'mode', mode: mode, lifted: keep.length, kinds: r.groups.length, source: source });
    };
    var updateButton = function () {
      readBtn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" ' +
        'stroke-linecap="round" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"></circle><path d="M15.5 15.5L21 21"></path></svg>' +
        '<span class="nj-label">' + (keep.length
          ? 'Start reading<small>' + keep.length + (keep.length === 1 ? ' style' : ' styles') + ' in your filter</small>'
          : 'Tap text to add to your filter') + '</span>';
      readBtn.disabled = !keep.length;
      resetBtn.hidden = !suggested || sameSet(keep, suggested);
    };
    var showArticle = function () {
      article.innerHTML = articleHTML(r, keep);
      article.classList.remove('hidden');
      list.style.display = 'none';
    };

    // Pick -> Read: lifted cards settle into the page (staggered), the rest fold away,
    // then the full article in page order fades in where they landed.
    var toRead = function () {
      if (busy || !keep.length) return;
      busy = true;
      sheet.scrollTop = 0;
      var sizes = readBase(r, keep);
      var n = 0;
      list.querySelectorAll('.nj-card').forEach(function (c) {
        var g = groups[c.getAttribute('data-g')];
        c.className = c.className.replace(/role-\w+/, 'role-' + roleOf(g, sizes.base, sizes.headSize));
        c.style.setProperty('--d', c.classList.contains('on') ? (n++ * 70) + 'ms' : '0ms');
      });
      sheet.classList.remove('pick', 'nj-enter');
      sheet.classList.add('read');
      mode = 'read';
      // Reading a suggestion as it is leaves nothing of the user's to save, so later
      // updates to it still arrive; any change makes it their own.
      if (source !== 'suggested' || !sameSet(keep, suggested)) {
        saveRecipe(r.host, elsewhere.concat(keep));
        source = 'own';
      }
      report();
      setTimeout(function () {
        article.classList.add('fade');
        showArticle();
        requestAnimationFrame(function () { article.classList.remove('fade'); busy = false; });
      }, 450 + Math.max(0, n - 1) * 70 + 60);
    };

    // Read -> Pick: the article gives way to the cards in their read state, which
    // then lift back into cards.
    var toPick = function () {
      if (busy) return;
      busy = true;
      list.innerHTML = cardHTML(r, keep);
      list.style.display = '';
      article.classList.add('hidden');
      sheet.scrollTop = 0;
      void sheet.offsetHeight;
      sheet.classList.remove('read');
      sheet.classList.add('pick');
      mode = 'pick';
      updateButton();
      report();
      setTimeout(function () { busy = false; }, 500);
    };

    list.innerHTML = cardHTML(r, keep);
    updateButton();
    if (mode === 'read') {
      article.classList.add('fade');
      showArticle();
      requestAnimationFrame(function () { article.classList.remove('fade'); });
    } else {
      sheet.classList.add('nj-enter');
    }
    report();

    // Only real taps count: page scripts sometimes fire synthetic clicks.
    list.addEventListener('click', function (e) {
      if (!e.isTrusted || mode !== 'pick') return;
      var card = e.target.closest('.nj-card');
      if (!card) return;
      var id = card.getAttribute('data-g');
      var i = keep.indexOf(id);
      if (i >= 0) keep.splice(i, 1); else keep.push(id);
      var on = i < 0;
      card.classList.toggle('on', on);
      card.setAttribute('aria-pressed', on);
      card.querySelector('.nj-badge').textContent = card.getAttribute('data-kind') + ' · ' + groups[id].count;
      updateButton();
      report();
    });
    readBtn.addEventListener('click', function (e) { if (e.isTrusted) toRead(); });
    // Drops the user's own recipe for the site and goes back to the suggested one.
    resetBtn.addEventListener('click', function (e) {
      if (!e.isTrusted || mode !== 'pick' || !suggested) return;
      keep = suggested.slice();
      elsewhere = [];
      source = 'suggested';
      saveRecipe(r.host, null);
      list.innerHTML = cardHTML(r, keep);
      updateButton();
      report();
    });

    // Links go through the app, which opens the page and lifts it again when the
    // site has a recipe; in a plain browser they just navigate. While listening, a tap
    // on a paragraph (not a link) starts reading there.
    article.addEventListener('click', function (e) {
      var a = e.target.closest('a');
      if (!a) {
        var part = e.target.closest('[data-nj-say]');
        if (part && e.isTrusted && sheet.classList.contains('listening')) {
          notifyApp({ type: 'listenFrom', index: +part.getAttribute('data-nj-say') });
        }
        return;
      }
      e.preventDefault();
      if (!e.isTrusted) return;
      if (inApp()) notifyApp({ type: 'navigate', url: a.href });
      else location.href = a.href;
    });

    var close = function () {
      current = null;
      document.removeEventListener('keydown', onKey);
      host.remove();
    };
    var onKey = function (e) { if (e.key === 'Escape') close(); };
    if (!inApp()) document.addEventListener('keydown', onKey);
    // What sharing sends: the site's whole recipe, with the current picks for this page.
    var recipe = function () { return elsewhere.concat(keep); };
    // Listening: the article's headings and paragraphs, in order, for the app to speak.
    var speech = function () {
      if (mode !== 'read') return null;
      var parts = [];
      article.querySelectorAll('h1,h2,p:not(.src),li').forEach(function (el) {
        var text = el.innerText.trim();
        if (!text) return;
        el.setAttribute('data-nj-say', parts.length);
        parts.push({ text: text, head: /^H/.test(el.tagName) });
      });
      return { title: r.title || '', parts: parts };
    };
    var speaking = function (i) {
      var old = article.querySelector('.nj-speaking');
      if (old) old.classList.remove('nj-speaking');
      sheet.classList.toggle('listening', i !== null);
      var el = i === null ? null : article.querySelector('[data-nj-say="' + i + '"]');
      if (!el) return;
      el.classList.add('nj-speaking');
      var box = el.getBoundingClientRect();
      if (box.top < 70 || box.bottom > innerHeight - 180) {
        sheet.scrollTo({ top: sheet.scrollTop + box.top - innerHeight / 3, behavior: 'smooth' });
      }
    };
    current = { toRead: toRead, toPick: toPick, close: close, recipe: recipe, speech: speech, speaking: speaking,
      keep: function () { return keep.slice(); } };
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.showReader = showReader;
  // For the on-page picker: a name for each style group, and a first guess at a filter
  // for a site with none (the suggested one if it matches, else the main text and the
  // page's headline).
  window.NewsJuice.pickPrep = function (r, suggested) {
    var kinds = {};
    r.groups.forEach(function (g) { kinds[g.id] = kindOf(g, r); });
    return { kinds: kinds, keep: matchRecipe(r, suggested) || firstGuess(r, kinds) };
  };

  // A starting point for a site with no filter. An article: its headline and body text.
  // A front page: its headline lists (the biggest, plus a bigger-type lead list).
  // Never captions, credits, bylines, labels or menus.
  function firstGuess(r, kinds) {
    var of = function (kind) { return r.groups.filter(function (g) { return kinds[g.id] === kind; }); };
    var ids = function (gs) { return gs.map(function (g) { return g.id; }); };
    var body = of('Article text')[0];
    // Some home pages call themselves articles; an article also has a path and real
    // paragraphs of text.
    var path = '/';
    try { path = new URL(r.url).pathname; } catch (e) { /* no url */ }
    if (r.article && path.length > 1 && body && body.chars >= 600 && body.chars / body.count >= 60) {
      return ids([of('Headline')[0], body].filter(Boolean));
    } else {
      var lists = r.groups.filter(function (g) {
        return g.link && kinds[g.id] !== 'Menu links' && kinds[g.id] !== 'Video titles' && g.chars / g.count >= 30;
      });
      if (lists.length) {
        var main = lists[0]; // groups come biggest-first
        var lead = lists.filter(function (g) { return g !== main && g.size > main.size; })[0];
        return ids([lead, main].filter(Boolean));
      }
    }
    return defaultKeep(r);
  };
  // The picks for this page (for editing them on the page).
  window.NewsJuice.currentKeep = function () { return current ? current.keep() : null; };
  window.NewsJuice.renderHTML = renderHTML;
  window.NewsJuice.currentRecipe = function () { return current ? current.recipe() : null; };
  window.NewsJuice.speechParts = function () { return current ? current.speech() : null; };
  // i: the part being read (from speechParts), or null when listening stops.
  window.NewsJuice.speaking = function (i) { if (current) current.speaking(i); };
  window.NewsJuice.setMode = function (m) {
    if (!current) return;
    if (m === 'read') current.toRead(); else current.toPick();
  };
})();
