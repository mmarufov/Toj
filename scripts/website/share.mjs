import { chromium } from '@playwright/test';
import { readFile, copyFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.EVIDENCE_DIR || path.join(root, '.context/website');
await mkdir(evidence, { recursive: true });
const html = (await readFile(path.join(root, 'docs/index.html'), 'utf8')).replace(/<script.*?<\/script>/g, '').replace('<head>', '<head><base href="http://127.0.0.1:4173/">');
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
await page.setContent(html, { waitUntil: 'networkidle' });
await page.addStyleTag({ content: `
body{height:630px;overflow:hidden} .site-header,.trust,.experience,.engineering,.about,.site-footer,.hero-description,.hero-actions,.hero-footnote,.availability,.story-bottom,.delivery-story figcaption,.story-transcript{display:none}
.hero-intro{padding-top:62px}.hero h1{font-size:72px;line-height:1.08}.hero .delivery-story{margin-top:35px;max-width:970px}.scene{grid-template-columns:1fr 174px 1fr}.conversation-body{height:139px}.scene-label{font-size:9px}.hero{width:100%}
.share-brand{position:absolute;left:34px;top:28px;display:flex;align-items:center;gap:8px;font:24px Onest,sans-serif;letter-spacing:-1px}.share-brand img{width:27px;height:27px;border-radius:7px}.share-url{position:absolute;bottom:25px;right:36px;color:#9c9c9f;font:11px ui-monospace,monospace;letter-spacing:1px}
` });
await page.evaluate(async () => { await document.fonts.ready; const logo = document.createElement('div'); logo.className = 'share-brand'; logo.innerHTML = '<img src="assets/toj-symbol.webp" alt="">toj<span style="color:#e0b75d;margin-left:-8px">.</span>'; document.body.append(logo); const url = document.createElement('span'); url.className = 'share-url'; url.textContent = 'tojchat.tech / in development'; document.body.append(url); });
const output = path.join(evidence, 'toj-social.png');
await page.screenshot({ path: output }); await browser.close();
await copyFile(output, path.join(root, 'docs/assets/toj-social.png'));
console.log(output);
