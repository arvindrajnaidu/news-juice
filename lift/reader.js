// Clean reading view for a lift() result. Slides up over the page as an
// overlay; tap the handle or press Escape to drop it back down.
// Exposes window.NewsJuice.showReader(result) and window.NewsJuice.renderHTML(result).
(function () {
  var CSS = [
    ':host{all:initial}',
    '.nj-sheet{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;background:#fbf8f2;color:#1d1b18;',
    '  transform:translateY(100%);transition:transform .35s cubic-bezier(.2,.8,.2,1);',
    '  font:19px/1.6 Georgia,"Iowan Old Style",serif;-webkit-font-smoothing:antialiased}',
    '.nj-sheet.up{transform:none}',
    '.nj-handle{position:sticky;top:0;display:flex;justify-content:center;padding:10px;background:inherit;cursor:pointer}',
    '.nj-handle span{width:44px;height:5px;border-radius:3px;background:#c9c2b6}',
    '.nj-body{max-width:38rem;margin:0 auto;padding:0 20px 80px}',
    'h1{font-size:1.6em;line-height:1.25;margin:.4em 0 .8em}',
    'h2{font-size:1.15em;margin:1.6em 0 .4em}',
    'p,li{margin:0 0 1em}',
    'blockquote{margin:0 0 1em;padding-left:1em;border-left:3px solid #c9c2b6;font-style:italic}',
    '.nj-src{font:13px system-ui,sans-serif;color:#7a7368;word-break:break-all}',
    '@media (prefers-color-scheme:dark){.nj-sheet{background:#1a1916;color:#e8e3da}.nj-handle span{background:#4a463f}}',
  ].join('\n');

  function esc(s) {
    return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  function bodyHTML(r) {
    var html = '<h1>' + esc(r.title || '') + '</h1>';
    var inList = false;
    r.blocks.forEach(function (b) {
      if (b.kind === 'li' && !inList) { html += '<ul>'; inList = true; }
      if (b.kind !== 'li' && inList) { html += '</ul>'; inList = false; }
      var t = esc(b.text).replace(/\n/g, '<br>');
      html += b.kind === 'h' ? '<h2>' + t + '</h2>'
            : b.kind === 'li' ? '<li>' + t + '</li>'
            : b.kind === 'quote' ? '<blockquote>' + t + '</blockquote>'
            : '<p>' + t + '</p>';
    });
    if (inList) html += '</ul>';
    return html + '<p class="nj-src">' + esc(r.url || '') + '</p>';
  }

  // Standalone page, used by the test harness.
  function renderHTML(r) {
    return '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>' + esc(r.title || 'Lifted') + '</title><style>' + CSS.replace(/\.nj-sheet\{position:fixed;inset:0;/, '.nj-sheet{') +
      '</style><div class="nj-sheet up"><div class="nj-body">' + bodyHTML(r) + '</div></div>';
  }

  function showReader(r) {
    var old = document.getElementById('news-juice-reader');
    if (old) old.remove();
    var host = document.createElement('div');
    host.id = 'news-juice-reader';
    var root = host.attachShadow({ mode: 'open' });
    root.innerHTML = '<style>' + CSS + '</style><div class="nj-sheet"><div class="nj-handle"><span></span></div>' +
      '<div class="nj-body">' + bodyHTML(r) + '</div></div>';
    document.documentElement.appendChild(host);
    var sheet = root.querySelector('.nj-sheet');
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
