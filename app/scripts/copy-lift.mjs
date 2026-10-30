// Copies the lift scripts from ../lift into www/lift so `cap sync` bundles them
// into the native app (ios/App/App/public/lift). The Swift browser injects them
// into every page it opens. lift/ at the repo root stays the only source.
// Also copies ../test/capture-page.js to www/debug for the Debug-only fixture capture.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(app, '..', 'lift');
const dest = path.join(app, 'www', 'lift');

await fs.mkdir(dest, { recursive: true });
for (const f of ['lift.js', 'reader.js']) {
  await fs.copyFile(path.join(src, f), path.join(dest, f));
}
await fs.mkdir(path.join(app, 'www', 'debug'), { recursive: true });
await fs.copyFile(path.join(app, '..', 'test', 'capture-page.js'), path.join(app, 'www', 'debug', 'capture-page.js'));
console.log(`copied lift.js, reader.js -> ${path.relative(app, dest)}, capture-page.js -> www/debug`);
