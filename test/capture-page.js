// Snapshot a rendered page as an offline lift fixture.
//
// Run in the live page after it has loaded (the iOS app does this in Debug builds,
// see -NJCaptureAfter in NewsJuiceBrowser.swift). For every element in <body> it
// writes the computed styles the lift reads into the inline style attribute and
// the element's rendered size into data-nj-w / data-nj-h, then drops scripts,
// styles, iframes and stylesheets and blanks image sources. Returns the doctype
// plus the serialized <html>.
(function () {
  var PROPS = ['font-size', 'font-weight', 'display', 'float', 'visibility', 'opacity', 'position'];
  var els = document.body ? document.body.getElementsByTagName('*') : [];
  // Read everything first: writing styles while reading would force a relayout per element.
  var snaps = [];
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    var cs = getComputedStyle(el);
    var r = el.getBoundingClientRect();
    snaps.push([el, PROPS.map(function (p) { return p + ':' + cs.getPropertyValue(p); }).join(';'),
      Math.round(r.width), Math.round(r.height)]);
  }
  snaps.forEach(function (s) {
    var el = s[0];
    var prev = el.getAttribute('style');
    el.setAttribute('style', (prev ? prev.replace(/;?\s*$/, ';') : '') + s[1]);
    el.setAttribute('data-nj-w', s[2]);
    el.setAttribute('data-nj-h', s[3]);
  });
  document.querySelectorAll('script, style, iframe, link[rel~="stylesheet"], #news-juice-reader')
    .forEach(function (el) { el.remove(); });
  document.querySelectorAll('img, source').forEach(function (el) {
    if (el.hasAttribute('src')) el.setAttribute('src', '');
    el.removeAttribute('srcset');
    el.removeAttribute('data-src');
    el.removeAttribute('data-srcset');
  });
  var dt = document.doctype;
  var doctype = dt ? '<!DOCTYPE ' + dt.name + (dt.publicId ? ' PUBLIC "' + dt.publicId + '"' : '') +
    (dt.systemId ? ' "' + dt.systemId + '"' : '') + '>' : '';
  return doctype + '\n' + document.documentElement.outerHTML;
})();
