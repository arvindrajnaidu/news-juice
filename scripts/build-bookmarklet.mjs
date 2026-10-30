// Packs lift.js + reader.js into a bookmarklet so the lift can be tried on any
// site in a desktop (or mobile) browser. Writes dist/bookmarklet.html with a
// link to drag to the bookmarks bar.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (f) => fs.readFile(path.join(root, f), 'utf8');
const strip = (s) => s.split('\n').filter((l) => !/^\s*\/\//.test(l)).map((l) => l.trim()).join('\n');

const code = strip(await read('lift/lift.js')) + '\n' + strip(await read('lift/reader.js')) + `
var r=window.NewsJuice.lift();
if(r.ok){window.NewsJuice.showReader(r);console.log('News Juice lift',r);}
else{alert('News Juice: nothing to lift ('+r.reason+')');}`;
const href = 'javascript:' + encodeURIComponent('(function(){' + code + '})();void 0');

await fs.mkdir(path.join(root, 'dist'), { recursive: true });
await fs.writeFile(path.join(root, 'dist/bookmarklet.txt'), href);
await fs.writeFile(path.join(root, 'dist/bookmarklet.html'), `<!doctype html><meta charset="utf-8">
<title>News Juice bookmarklet</title>
<style>body{font:16px system-ui,sans-serif;max-width:36rem;margin:40px auto;padding:0 16px;line-height:1.5}
a.bm{display:inline-block;padding:10px 16px;border-radius:8px;background:#e8a317;color:#000;font-weight:600;text-decoration:none}</style>
<h1>News Juice lift</h1>
<p>Drag this button to your bookmarks bar:</p>
<p><a class="bm" href="${href.replace(/"/g, '&quot;')}">Lift</a></p>
<p>Then open a news article (for example on ndtv.com) and click <b>Lift</b> in the bookmarks bar. The article slides up in a clean view. Click the handle at the top or press Escape to drop it back down.</p>
<p>The browser console shows the details (body font size, font-size histogram, chosen container) under "News Juice lift".</p>`);
console.log(`dist/bookmarklet.html written (${href.length} chars)`);
