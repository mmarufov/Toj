import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { report as budget } from './budget.mjs';
const directory = process.argv[2];
if (!directory) throw new Error('Usage: node report.mjs MEASUREMENT_DIRECTORY');
const root = fileURLToPath(new URL('../../', import.meta.url));
const before = JSON.parse(await readFile(path.join(directory, 'baseline.json'), 'utf8'));
const after = JSON.parse(await readFile(path.join(directory, 'candidate.json'), 'utf8'));
if (!before.summary || !after.summary || before.runs.length !== 15 || after.runs.length !== 15) throw new Error('Both complete five-run, three-profile measurements are required');
const out = path.join(root, 'docs/results'); await mkdir(out, { recursive: true });
const html = await readFile(path.join(root, 'docs/index.html'), 'utf8');
const manifest = {};
for (const name of ['index.html', ...budget.files.map(file => `assets/${file.name}`)]) {
  manifest[name] = createHash('sha256').update(await readFile(path.join(root, 'docs', name))).digest('hex');
}
const metric = (data, profile, field) => {
  const item = data.summary.find(row => row.profile === profile)[field];
  const format = value => ['transferred','completeTransfer'].includes(field) ? `${(value / 1024).toFixed(1)} KiB` : ['performance','accessibility','cls','tbt'].includes(field) ? String(value) : `${(value / 1000).toFixed(2)} s`;
  return `${format(item.median)} / ${format(item.worst)}`;
};
const measured = [
  ['Mobile performance score', 'Lighthouse mobile', 'performance', '>=95'],
  ['Mobile accessibility score', 'Lighthouse mobile', 'accessibility', '100 automated'],
  ['Mobile LCP', 'Lighthouse mobile', 'lcp', '<=2.5 s'],
  ['Mobile CLS', 'Lighthouse mobile', 'cls', '<=0.05'],
  ['Mobile TBT (ms)', 'Lighthouse mobile', 'tbt', '<=100 ms'],
  ['400 kbps LCP', '400kbps', 'lcp', '<=4 s median'],
  ['100 kbps hero/navigation usable', '100kbps', 'usable', '<=8 s'],
  ['Full-page measured transfer including playback', '400kbps', 'completeTransfer', '<=120 KiB'],
];
const rows = measured.map(([label, profile, key, gate]) => `| ${label} | ${metric(before, profile, key)} | ${metric(after, profile, key)} | ${gate} |`).join('\n');
const report = `# Website redesign: measured release evidence

Measured ${after.at} (UTC). Baseline: main revision \`71f232b\`. Candidate: the exact website files in the SHA-256 manifest below. The measurement and report-generation scripts live in \`scripts/website/\`.

## Five cold runs per profile

Each table cell is **median / worst**. The old and new sites used the same gzip-enabled local server, machine, browser and settings, measured sequentially without concurrent browser tests. All 30 individual samples and their settings are retained in [before JSON](website-before.json) and [after JSON](website-after.json).

| Measurement | Previous site | Redesign | Release target |
| --- | --- | --- | --- |
${rows}

The redesign meets every planned size and lab performance gate. These results do not establish field Core Web Vitals, INP, performance on a physical iPhone, or performance on an actual cellular network. Localhost measurements omit real DNS, TLS, CDN distance and network variability. Live-domain verification is recorded with the deployment PR after Pages publishes it.

## Profiles and transfer accounting

- Browser: Chromium ${after.browser}; Lighthouse 13.5.0; macOS arm64.
- Lighthouse: standard mobile simulated throttling, 412 x 823 CSS px, DPR 1.75, 150 ms RTT, 1638.4 kbps throughput, 4x CPU slowdown. Exact network and simulation settings are in each JSON sample.
- Applied custom throttling: 390 x 844 CSS px, DPR 1, 4x CPU. Profiles: 400 kbps down / 100 kbps up / 400 ms latency, and 100 kbps down / 50 kbps up / 800 ms latency.
- A fresh browser context with cache disabled is used for each custom run; Lighthouse starts a fresh browser profile per run. LCP is observed before any scrolling. Full-page transfer includes deliberately starting playback and scrolling to the footer. The usable timestamp is the first frame with loaded CSS and visible hero text/navigation. All content remains readable without waiting for the optional fonts or Motion module.
- Browser transfer includes reported HTTP overhead. The size gate below counts gzip bodies plus stored WOFF2/WebP, including both fonts and the optional motion chunk. The sharing image is excluded because the page never loads it.

| Payload | Measured | Budget |
| --- | --- | --- |
${budget.checks.map(row => `| ${row.name} | ${(row.bytes / 1024).toFixed(2)} KiB | ${row.limit / 1024} KiB |`).join('\n')}

## Verification

- Ten deterministic checks cover state sequencing, stable message identity, pause/resume/replay, cleanup, content truth, local assets, domain preservation and payload limits.
- The three-browser CI suite covers Chromium, Firefox and WebKit. Thirty Chromium/WebKit checks also pass locally. The local Firefox binary cannot start on this Mac; Firefox coverage runs on the Linux CI runner.
- Verified widths: 320, 390, 768, 1440 and 1920 px; 200% content zoom; keyboard focus and native FAQ; axe WCAG AA checks; 44 px controls; JavaScript disabled; blocked fonts/library; Save-Data; changing reduced-motion preference; offscreen/hidden-tab suspension; pagehide cleanup; no external runtime/API requests.
- Every hero state and complete desktop/mobile layouts were visually reviewed. Noto font cmap coverage includes the displayed Tajik example and all six distinctive Tajik letters. Accessible reading order was inspected from browser accessibility snapshots; automatic state changes do not flood a live region.
- Native Safari and spoken VoiceOver checks remain unverified: the native computer-control API times out when selecting Safari on this Mac. WebKit 26.5 rendering/interaction coverage passes. No physical-device result is claimed.

## Candidate asset identity

Generated HTML and runtime assets, SHA-256:

\`\`\`json
${JSON.stringify(manifest, null, 2)}
\`\`\`
`;
await copyFile(path.join(directory, 'baseline.json'), path.join(out, 'website-before.json'));
await copyFile(path.join(directory, 'candidate.json'), path.join(out, 'website-after.json'));
await writeFile(path.join(out, 'website-performance.md'), report);
console.log('Wrote docs/results/website-performance.md and both raw sample sets.');
