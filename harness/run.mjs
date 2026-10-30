// Test harness for the lift: opens each site in a phone-sized Chromium,
// runs lift.js, and writes a before/after report to harness/out/index.html.
//
//   node harness/run.mjs                 # every line in harness/sites.txt
//   node harness/run.mjs https://...     # just these URLs
//
// A homepage URL is fine: the harness follows its first link that looks like
// an article (a path segment with several hyphens), so the list doesn't go stale.
import { chromium, devices } from 'playwright';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, 'out');
const liftSrc = await fs.readFile(path.join(here, '../lift/lift.js'), 'utf8');
const readerSrc = await fs.readFile(path.join(here, '../lift/reader.js'), 'utf8');

const args = process.argv.slice(2);
const urls = args.length ? args : (await fs.readFile(path.join(here, 'sites.txt'), 'utf8'))
  .split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));

const looksLikeArticle = (u) => {
  try { return new URL(u).pathname.split('/').some((seg) => (seg.match(/-/g) || []).length >= 4); }
  catch { return false; }
};

const slug = (u) => u.replace(/^\w+:\/\//, '').replace(/[^a-z0-9]+/gi, '-').slice(0, 60);

await fs.mkdir(outDir, { recursive: true });
const browser = await chromium.launch();
const context = await browser.newContext({ ...devices['iPhone 13'] });
const rows = [];

for (const start of urls) {
  const page = await context.newPage();
  const row = { start };
  try {
    await page.goto(start, { waitUntil: 'domcontentloaded', timeout: 45000 });
    let url = start;
    if (!looksLikeArticle(start)) {
      const links = await page.$$eval('a[href]', (as) => as.map((a) => a.href));
      const host = new URL(page.url()).hostname.replace(/^www\./, '');
      url = links.find((h) => h.includes(host) && looksLikeArticle(h));
      if (!url) throw new Error('no article link found on homepage');
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    }
    await page.waitForTimeout(3000); // let late layout and ad slots settle
    row.url = page.url();
    const id = slug(row.url);
    const dir = path.join(outDir, id);
    await fs.mkdir(dir, { recursive: true });
    await page.screenshot({ path: path.join(dir, 'before.png') });

    await page.addScriptTag({ content: liftSrc });
    await page.addScriptTag({ content: readerSrc });
    const t0 = Date.now();
    const result = await page.evaluate(() => window.NewsJuice.lift());
    row.ms = Date.now() - t0;
    row.result = result;
    const html = await page.evaluate((r) => window.NewsJuice.renderHTML(r), result);
    await fs.writeFile(path.join(dir, 'lifted.html'), html);
    await fs.writeFile(path.join(dir, 'result.json'), JSON.stringify(result, null, 2));

    const view = await context.newPage();
    await view.setContent(html);
    await view.screenshot({ path: path.join(dir, 'lifted.png') });
    await view.close();
    row.id = id;
    console.log(`ok   ${row.url}  ${result.groups.length} groups, biggest: ${result.groups[0] && result.groups[0].id}`);
  } catch (e) {
    row.error = String(e.message || e).split('\n')[0];
    console.log(`fail ${start}  ${row.error}`);
  }
  rows.push(row);
  await page.close();
}
await browser.close();

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const top = (groups) => (groups || []).slice(0, 6).map((g) => `${g.id}: ${g.chars}`).join(' · ');

const report = `<!doctype html><meta charset="utf-8"><title>Lift report</title>
<style>
body{font:14px system-ui,sans-serif;margin:24px;background:#f4f2ee;color:#222}
.row{background:#fff;border-radius:10px;padding:16px;margin:0 0 20px}
.row h2{font-size:15px;margin:0 0 4px;word-break:break-all}
.meta{color:#666;margin:0 0 12px}
.shots{display:flex;gap:12px;flex-wrap:wrap}
.shots figure{margin:0}.shots img{width:280px;border:1px solid #ddd;border-radius:6px}
.err{color:#b00020}
</style>
<h1>Lift report</h1><p>${rows.filter((r) => r.result?.ok).length} of ${rows.length} pages lifted. Generated ${new Date().toISOString()}</p>
${rows.map((r) => `<div class="row"><h2>${esc(r.url || r.start)}</h2>${r.error ? `<p class="err">${esc(r.error)}</p>` : `
<p class="meta">Title: <b>${esc(r.result.title)}</b><br>${r.result.groups.length} style groups · ${r.result.blocks.length} blocks · ${r.ms} ms<br>Biggest groups (chars): ${esc(top(r.result.groups))}</p>
<div class="shots"><figure><img src="${r.id}/before.png"><figcaption>Before</figcaption></figure>
<figure><img src="${r.id}/lifted.png"><figcaption>Lifted · <a href="${r.id}/lifted.html">full text</a></figcaption></figure></div>`}</div>`).join('\n')}`;
await fs.writeFile(path.join(outDir, 'index.html'), report);
console.log(`\nReport: ${path.join(outDir, 'index.html')}`);
