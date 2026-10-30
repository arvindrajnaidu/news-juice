// Clean reading view for a lift() result. Slides up over the page as an
// overlay; tap the handle or press Escape to drop it back down.
//
// The lift sorts the page's text into style groups. The sheet has a panel
// listing them (sample line, size, Keep/Cull) and shows only the kept groups,
// in page order, updating as you toggle. The kept set is the site's "recipe":
// it is saved per host and applied straight away the next time you lift a page
// on that site. With no recipe the biggest prose group is kept and the panel
// starts open.
//
// Exposes window.NewsJuice.showReader(result, { recipe }) and
// window.NewsJuice.renderHTML(result). Recipes are saved through the iOS app's
// `newsJuice` message handler when it's there, otherwise in localStorage.
(function () {
  var CSS = [
    ':host{all:initial}',
    '.nj-sheet{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;overflow-x:hidden;background:#fbf8f2;color:#1d1b18;',
    '  transform:translateY(100%);transition:transform .35s cubic-bezier(.2,.8,.2,1);',
    '  font:19px/1.6 Georgia,"Iowan Old Style",serif;-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}',
    '.nj-sheet.up{transform:none}',
    '.nj-top{position:sticky;top:0;z-index:1;background:inherit;border-bottom:1px solid transparent}',
    '.nj-handle{display:flex;justify-content:center;padding:10px;cursor:pointer}',
    '.nj-handle span{width:44px;height:5px;border-radius:3px;background:#c9c2b6}',
    '.nj-toggle{display:block;width:100%;box-sizing:border-box;margin:0;padding:0 20px 10px;border:0;background:none;color:#7a7368;',
    '  font:600 13px system-ui,sans-serif;text-align:left;cursor:pointer}',
    '.nj-panel{display:none;max-height:45vh;overflow-y:auto;padding:0 12px 10px;font:14px/1.35 system-ui,sans-serif}',
    '.nj-panel.open{display:block}',
    '.nj-row{display:flex;align-items:center;gap:10px;width:100%;box-sizing:border-box;margin:0;padding:8px;border:0;',
    '  border-radius:8px;background:none;color:inherit;font:inherit;text-align:left;cursor:pointer}',
    '.nj-row+.nj-row{border-top:1px solid #e6dfd3}',
    '.nj-row .nj-txt{flex:1;min-width:0}',
    '.nj-sample{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '.nj-meta{display:block;font-size:12px;color:#7a7368}',
    '.nj-pill{flex:none;width:52px;padding:4px 0;border-radius:999px;text-align:center;font-size:12px;font-weight:600;',
    '  background:#e6dfd3;color:#7a7368}',
    '.nj-row.kept .nj-pill{background:#e8a317;color:#000}',
    '.nj-row:not(.kept) .nj-sample{color:#9a9387}',
    '.nj-body{max-width:38rem;margin:0 auto;padding:0 20px 80px;overflow-wrap:break-word}',
    'h1{font-size:1.6em;line-height:1.25;margin:.4em 0 .8em}',
    'h2{font-size:1.15em;line-height:1.3;margin:1.6em 0 .4em}',
    'p,li{margin:0 0 1em}',
    '.nj-small{font:14px/1.45 system-ui,sans-serif;color:#7a7368}',
    '.nj-empty{font:15px system-ui,sans-serif;color:#7a7368}',
    '.nj-src{font:13px system-ui,sans-serif;color:#7a7368;word-break:break-all}',
    '@media (prefers-color-scheme:dark){.nj-sheet{background:#1a1916;color:#e8e3da}.nj-handle span{background:#4a463f}',
    '  .nj-row+.nj-row{border-top-color:#3a372f}.nj-pill{background:#3a372f;color:#9a9387}.nj-row:not(.kept) .nj-sample{color:#6f695f}}',
  ].join('\n');

  var STORE_PREFIX = 'newsjuice:recipe:';

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  // With nothing saved, keep the group with the most prose (not a link list).
  function defaultKeep(r) {
    var g = r.groups.filter(function (x) { return !x.link; })[0] || r.groups[0];
    return g ? [g.id] : [];
  }

  function loadRecipe(r, given) {
    var recipe = given;
    if (!recipe) {
      try { recipe = JSON.parse(localStorage.getItem(STORE_PREFIX + r.host) || 'null'); } catch (e) { recipe = null; }
    }
    if (!recipe) return null;
    var present = {};
    r.groups.forEach(function (g) { present[g.id] = true; });
    var keep = recipe.filter(function (id) { return present[id]; });
    return keep.length ? keep : null; // none of the saved groups are on this page
  }

  function saveRecipe(host, keep) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.newsJuice;
    if (handler) {
      handler.postMessage({ type: 'saveRecipe', host: host, keep: keep });
      return;
    }
    try { localStorage.setItem(STORE_PREFIX + host, JSON.stringify(keep)); } catch (e) { /* storage blocked */ }
  }

  function bodyHTML(r, keep) {
    var kept = {};
    keep.forEach(function (id) { kept[id] = true; });
    var groups = {};
    r.groups.forEach(function (g) { groups[g.id] = g; });
    // The kept group with the most text sets the body size; bigger kept text reads as
    // headings, smaller (captions, datelines) as small print.
    var base = null;
    r.groups.forEach(function (g) { if (kept[g.id] && base === null) base = g.size; });

    var html = '<h1>' + esc(r.title || '') + '</h1>';
    var inList = false;
    var shown = 0;
    var titleSkipped = false;
    r.blocks.forEach(function (b) {
      if (!kept[b.g]) return;
      if (!titleSkipped && b.text === r.title) { titleSkipped = true; return; }
      var g = groups[b.g];
      var isLi = b.tag === 'li';
      if (isLi && !inList) { html += '<ul>'; inList = true; }
      if (!isLi && inList) { html += '</ul>'; inList = false; }
      var t = esc(b.text).replace(/\n/g, '<br>');
      html += g.size > base + 1 && b.text.length <= 200 ? '<h2>' + t + '</h2>'
            : isLi ? '<li>' + t + '</li>'
            : g.size < base - 1 ? '<p class="nj-small">' + t + '</p>'
            : '<p>' + t + '</p>';
      shown++;
    });
    if (inList) html += '</ul>';
    if (!shown) html += '<p class="nj-empty">Nothing kept. Open “Text on this page” and keep a group.</p>';
    return html + '<p class="nj-src">' + esc(r.url || '') + '</p>';
  }

  function panelHTML(r, keep) {
    return r.groups.map(function (g) {
      var meta = g.size + 'px' + (g.bold ? ' bold' : '') + (g.italic ? ' italic' : '') + (g.link ? ' · links' : '') +
        ' · ' + g.chars.toLocaleString() + ' chars · ' + g.count + (g.count === 1 ? ' block' : ' blocks');
      var kept = keep.indexOf(g.id) >= 0;
      return '<button class="nj-row' + (kept ? ' kept' : '') + '" data-g="' + esc(g.id) + '" role="switch" aria-checked="' + kept + '">' +
        '<span class="nj-txt"><span class="nj-sample">' + esc(g.sample) + '</span><span class="nj-meta">' + esc(meta) +
        '</span></span><span class="nj-pill">' + (kept ? 'Keep' : 'Cull') + '</span></button>';
    }).join('');
  }

  // Standalone page with the default (or saved) selection, used by the test harness.
  function renderHTML(r) {
    var keep = loadRecipe(r) || defaultKeep(r);
    return '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>' + esc(r.title || 'Lifted') + '</title><style>' + CSS.replace(/\.nj-sheet\{position:fixed;inset:0;/, '.nj-sheet{') +
      '</style><div class="nj-sheet up"><div class="nj-body">' + bodyHTML(r, keep) + '</div></div>';
  }

  function showReader(r, opts) {
    opts = opts || {};
    var old = document.getElementById('news-juice-reader');
    if (old) old.remove();
    var saved = loadRecipe(r, opts.recipe);
    var keep = saved || defaultKeep(r);

    var host = document.createElement('div');
    host.id = 'news-juice-reader';
    var root = host.attachShadow({ mode: 'open' });
    root.innerHTML = '<style>' + CSS + '</style><div class="nj-sheet"><div class="nj-top">' +
      '<div class="nj-handle"><span></span></div><button class="nj-toggle"></button>' +
      '<div class="nj-panel' + (saved ? '' : ' open') + '"></div></div><div class="nj-body"></div></div>';
    document.documentElement.appendChild(host);

    var sheet = root.querySelector('.nj-sheet');
    var panel = root.querySelector('.nj-panel');
    var toggle = root.querySelector('.nj-toggle');
    var body = root.querySelector('.nj-body');
    var render = function () {
      var open = panel.classList.contains('open');
      toggle.textContent = (open ? '▾ ' : '▸ ') + 'Text on this page · keeping ' + keep.length + ' of ' + r.groups.length;
      panel.innerHTML = panelHTML(r, keep);
      body.innerHTML = bodyHTML(r, keep);
    };
    render();

    // Only real taps count: page scripts sometimes fire synthetic clicks.
    toggle.addEventListener('click', function (e) {
      if (!e.isTrusted) return;
      panel.classList.toggle('open');
      render();
    });
    panel.addEventListener('click', function (e) {
      if (!e.isTrusted) return;
      var row = e.target.closest('.nj-row');
      if (!row) return;
      var id = row.getAttribute('data-g');
      var i = keep.indexOf(id);
      if (i >= 0) keep.splice(i, 1); else keep.push(id);
      saveRecipe(r.host, keep.slice());
      var scroll = panel.scrollTop;
      render();
      panel.scrollTop = scroll;
    });

    var close = function () {
      sheet.classList.remove('up');
      document.removeEventListener('keydown', onKey);
      setTimeout(function () { host.remove(); }, 400);
    };
    var onKey = function (e) { if (e.key === 'Escape') close(); };
    root.querySelector('.nj-handle').addEventListener('click', close);
    document.addEventListener('keydown', onKey);
    requestAnimationFrame(function () { requestAnimationFrame(function () { sheet.classList.add('up'); }); });
  }

  window.NewsJuice = window.NewsJuice || {};
  window.NewsJuice.showReader = showReader;
  window.NewsJuice.renderHTML = renderHTML;
})();
