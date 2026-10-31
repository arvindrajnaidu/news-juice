// A stand-in for the filter gist while testing: serves one filters.json at any path
// that ends in filters.json, with an ETag and 304s like the gist's raw URL.
//   npm run filters:serve [-- path/to/filters.json]   (default ../filters/filters.json)
// Point a Debug build at it with the launch argument
//   -NJFiltersURL http://localhost:8787/raw/filters.json
import http from 'node:http';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = path.resolve(process.argv[2] || path.join(app, '..', 'filters', 'filters.json'));
const port = Number(process.env.PORT) || 8787;

http.createServer(async (req, res) => {
  let status = 404;
  if (req.url.split('?')[0].endsWith('/filters.json')) {
    const body = await fs.readFile(file);
    const etag = '"' + crypto.createHash('sha1').update(body).digest('hex') + '"';
    if (req.headers['if-none-match'] === etag) {
      status = 304;
      res.writeHead(304, { ETag: etag });
      res.end();
    } else {
      status = 200;
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', ETag: etag });
      res.end(body);
    }
  } else {
    res.writeHead(404);
    res.end();
  }
  console.log(new Date().toISOString(), req.method, req.url, status);
}).listen(port, () => console.log(`serving ${file} on http://localhost:${port}/raw/filters.json`));
