import { readFileSync, readdirSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const docs = new URL('../../docs/', import.meta.url);
const html = readFileSync(new URL('index.html', docs));
const generated = readdirSync(new URL('assets/', docs)).filter(name => /^(site|motion|onest-latin|noto-tajik)-.*\.(css|js|woff2)$/.test(name));
const files = generated.map(name => {
  const data = readFileSync(new URL(`assets/${name}`, docs));
  return { name, bytes: name.endsWith('.woff2') ? data.length : gzipSync(data).length };
});
const sum = extension => files.filter(file => file.name.endsWith(extension)).reduce((sum, file) => sum + file.bytes, 0);
const critical = gzipSync(html).length + sum('.css');
const total = critical + sum('.js') + sum('.woff2') + readFileSync(new URL('assets/toj-symbol.webp', docs)).length;
// Conservative: count both fonts and the lazy motion chunk in the initial budget.
const checks = [
  { name: 'Critical HTML, CSS and inline graphics', bytes: critical, limit: 20 * 1024 },
  { name: 'All executable JavaScript', bytes: sum('.js'), limit: 10 * 1024 },
  { name: 'Initial payload (including optional assets)', bytes: total, limit: 80 * 1024 },
  { name: 'Complete page, excluding social image', bytes: total, limit: 120 * 1024 },
];
export const report = { method: 'gzip level 6; WOFF2 and WebP as stored; excludes HTTP headers', files, checks };
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(report, null, 2));
  if (checks.some(check => check.bytes > check.limit)) process.exitCode = 1;
}
