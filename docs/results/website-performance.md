# Website redesign: measured release evidence

Measured 2026-10-02T07:06:43.562Z (UTC). Baseline: main revision `71f232b`. Candidate: the exact website files in the SHA-256 manifest below. The measurement and report-generation scripts live in `scripts/website/`.

## Five cold runs per profile

Each table cell is **median / worst**. The old and new sites used the same gzip-enabled local server, machine, browser and settings, measured sequentially without concurrent browser tests. All 30 individual samples and their settings are retained in [before JSON](website-before.json) and [after JSON](website-after.json).

| Measurement | Previous site | Redesign | Release target |
| --- | --- | --- | --- |
| Mobile performance score | 100 / 100 | 100 / 100 | >=95 |
| Mobile accessibility score | 100 / 100 | 100 / 100 | 100 automated |
| Mobile LCP | 1.51 s / 1.51 s | 1.20 s / 1.28 s | <=2.5 s |
| Mobile CLS | 0 / 0 | 0 / 0 | <=0.05 |
| Mobile TBT (ms) | 0 / 0 | 0 / 0 | <=100 ms |
| 400 kbps LCP | 1.35 s / 1.39 s | 1.21 s / 1.25 s | <=4 s median |
| 100 kbps hero/navigation usable | 2.97 s / 3.09 s | 2.83 s / 2.85 s | <=8 s |
| Full-page measured transfer including playback | 92.8 KiB / 92.8 KiB | 33.3 KiB / 33.3 KiB | <=120 KiB |

The redesign meets every planned size and lab performance gate. These results do not establish field Core Web Vitals, INP, performance on a physical iPhone, or performance on an actual cellular network. Localhost measurements omit real DNS, TLS, CDN distance and network variability. Live-domain verification is recorded with the deployment PR after Pages publishes it.

## Profiles and transfer accounting

- Browser: Chromium 151.0.7922.34; Lighthouse 13.5.0; macOS arm64.
- Lighthouse: standard mobile simulated throttling, 412 x 823 CSS px, DPR 1.75, 150 ms RTT, 1638.4 kbps throughput, 4x CPU slowdown. Exact network and simulation settings are in each JSON sample.
- Applied custom throttling: 390 x 844 CSS px, DPR 1, 4x CPU. Profiles: 400 kbps down / 100 kbps up / 400 ms latency, and 100 kbps down / 50 kbps up / 800 ms latency.
- A fresh browser context with cache disabled is used for each custom run; Lighthouse starts a fresh browser profile per run. LCP is observed before any scrolling. Full-page transfer includes deliberately starting playback and scrolling to the footer. The usable timestamp is the first frame with loaded CSS and visible hero text/navigation. All content remains readable without waiting for the optional fonts or Motion module.
- Browser transfer includes reported HTTP overhead. The size gate below counts gzip bodies plus stored WOFF2/WebP, including both fonts and the optional motion chunk. The sharing image is excluded because the page never loads it.

| Payload | Measured | Budget |
| --- | --- | --- |
| Critical HTML, CSS and inline graphics | 12.62 KiB | 20 KiB |
| All executable JavaScript | 7.28 KiB | 10 KiB |
| Initial payload (including optional assets) | 31.29 KiB | 80 KiB |
| Complete page, excluding social image | 31.29 KiB | 120 KiB |

## Verification

- Ten deterministic checks cover state sequencing, stable message identity, pause/resume/replay, cleanup, content truth, local assets, domain preservation and payload limits.
- The three-browser CI suite covers Chromium, Firefox and WebKit. Thirty Chromium/WebKit checks also pass locally. The local Firefox binary cannot start on this Mac; Firefox coverage runs on the Linux CI runner.
- Verified widths: 320, 390, 768, 1440 and 1920 px; 200% content zoom; keyboard focus and native FAQ; axe WCAG AA checks; 44 px controls; JavaScript disabled; blocked fonts/library; Save-Data; changing reduced-motion preference; offscreen/hidden-tab suspension; pagehide cleanup; no external runtime/API requests.
- Every hero state and complete desktop/mobile layouts were visually reviewed. Noto font cmap coverage includes the displayed Tajik example and all six distinctive Tajik letters. Accessible reading order was inspected from browser accessibility snapshots; automatic state changes do not flood a live region.
- Native Safari and spoken VoiceOver checks remain unverified: the native computer-control API times out when selecting Safari on this Mac. WebKit 26.5 rendering/interaction coverage passes. No physical-device result is claimed.

## Candidate asset identity

Generated HTML and runtime assets, SHA-256:

```json
{
  "index.html": "2578563c0a5ecfb17167198586a588a41d6384251e6e90bcec2e41911c2c17a8",
  "assets/motion-EB2EJW3E.js": "507775ef10c33d4d75d78803aa8fd709411ad58b60b975ec74c7e305419f69b3",
  "assets/noto-tajik-4cc01d5e9d.woff2": "4cc01d5e9d3e26a11017fd33ad83321bfff22579166bc194b0656a5ceb2eb498",
  "assets/onest-latin-c715992dec.woff2": "c715992deccd248451e884ab7720a8d5b4a1f0d11d0267922fd5329f78406d32",
  "assets/site-41e6475842.css": "41e6475842f6f1af05daf216e5034eef278aea930bfa8a9f7cce350341953201",
  "assets/site-NQK6ES7L.js": "cb381ed7bb8fcba6729deafb8132a65118db75b0a4a859828e42c67a95e52ee4"
}
```
