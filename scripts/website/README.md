# Toj website

Read [the writing guide](../../docs/AGENTS.md) before editing copy. The website remains static GitHub Pages, published from `main:/docs`. It never contacts the messenger backend.

## Local workflow

Use Node 24 and the committed lockfile:

```sh
cd scripts/website
npm ci
npm run build
npm test
npm run check:budget
npx playwright install chromium firefox webkit
npm run test:browser
npm run serve
```

Edit `src/index.html`, `src/styles.css`, and `src/site.mjs`. `src/story.mjs` owns delivery and playback state. Build emits content-versioned assets into `docs/assets/` and updates `docs/index.html`. Commit sources and outputs together. CI rejects output drift and oversized payloads. Existing application checks remain required.

The message illustration plays once when visible, then rests. Its delivery states distinguish local persistence, retries, server acceptance, and recipient delivery. Playback pauses offscreen and when the document is hidden. Reduced motion shows the completed sequence and transcript; Save-Data defaults to stillness with deliberate playback available. No JavaScript is needed for content, links, or disclosures. Motion Mini loads only on playback. Third-party licenses are in `docs/assets/`.

The crown is the existing Toj asset. Product fragments are original HTML illustrations, not app screenshots. With the local server running, `node share.mjs` regenerates the sharing image; `EVIDENCE_DIR` chooses its screenshot directory.

## Performance evidence

`node measure.mjs LABEL URL OUTPUT_DIRECTORY` takes five cold-cache samples per profile: standard Lighthouse mobile, 400/100 kbps with 400 ms latency and 4x CPU, and 100/50 kbps with 800 ms latency and 4x CPU. It saves Lighthouse reports and summary JSON with median and worst values. Run baseline and candidate sequentially on the same machine, with browser tests stopped. Custom measurements use Chromium CDP applied throttling and a 390 x 844 viewport. Lighthouse uses its standard mobile viewport and simulated throttling, recorded in each report.

The custom usable timestamp is the first animation frame with loaded CSS and visible hero text/navigation. LCP is sampled before scrolling. Complete transfer includes deliberate playback and a scroll to the footer. Transfer includes browser-reported HTTP overhead; the deterministic payload gate counts gzip bodies plus stored WOFF2/WebP. These are lab measurements, not field Core Web Vitals or physical-network results.

## Font subsets

`fonts/onest-latin.woff2` is a weight-500 ASCII subset of the former Onest variable font in this repository. `fonts/noto-tajik.woff2` is Noto Sans, weight 500, width 100, subset to `ҲисорХ ҒғӢӣҚқӮӯҲҳҶҷЁёйй`. It covers the displayed search example and every distinctive Tajik letter, including characters missing from Onest. Both use `font-display: optional` so text never waits for fonts.

Generated using FontTools with Brotli support: instantiate variable axes, subset characters, save WOFF2. Source: [Google Fonts Noto Sans](https://github.com/google/fonts/tree/main/ofl/notosans). Both families use the SIL Open Font License. The two reviewed subsets are build inputs; normal builds never download fonts.

`node capture.mjs OUTPUT_DIRECTORY [URL]` captures all six hero states, full desktop/mobile layouts and accessible reading order. `node report.mjs MEASUREMENT_DIRECTORY` publishes the complete before/after sample sets and their asset manifest under `docs/results/`.
