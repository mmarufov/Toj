// Run baseline and candidate sequentially, without concurrent browser tests.
import { chromium } from '@playwright/test';
import lighthouse from 'lighthouse';
import { launch } from 'chrome-launcher';
import { mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const [label, url, directory] = process.argv.slice(2);
if (!label || !url || !directory) throw new Error('Usage: node measure.mjs LABEL URL OUTPUT_DIRECTORY');
await mkdir(directory, { recursive: true });
const report = { label, url, at: new Date().toISOString(), host: `${os.platform()} ${os.arch()}`, viewport: { width: 390, height: 844 }, runs: [] };
const save = () => writeFile(path.join(directory, `${label}.json`), JSON.stringify(report, null, 2));
for (let index = 1; index <= 5; index++) {
  const chrome = await launch({ chromePath: chromium.executablePath(), chromeFlags: ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage'] });
  try {
    const { lhr } = await lighthouse(url, { port: chrome.port, output: 'json', onlyCategories: ['performance', 'accessibility'], logLevel: 'error', formFactor: 'mobile' });
    const row = { profile: 'Lighthouse mobile', index, browser: lhr.environment.networkUserAgent, settings: lhr.configSettings,
      performance: lhr.categories.performance.score * 100, accessibility: lhr.categories.accessibility.score * 100,
      lcp: lhr.audits['largest-contentful-paint'].numericValue, cls: lhr.audits['cumulative-layout-shift'].numericValue,
      tbt: lhr.audits['total-blocking-time'].numericValue, transferred: lhr.audits['total-byte-weight'].numericValue };
    report.runs.push(row); await save(); await writeFile(path.join(directory, `${label}-lighthouse-${index}.json`), JSON.stringify(lhr));
    console.log(JSON.stringify({ label, ...row, settings: undefined, browser: undefined }));
  } finally { await chrome.kill(); }
}
const browser = await chromium.launch(); report.browser = browser.version();
for (const profile of [{ name: '400kbps', down: 400, up: 100, latency: 400 }, { name: '100kbps', down: 100, up: 50, latency: 800 }]) {
  for (let index = 1; index <= 5; index++) {
    const context = await browser.newContext({ viewport: report.viewport, deviceScaleFactor: 1, isMobile: true, hasTouch: true });
    const page = await context.newPage(), cdp = await context.newCDPSession(page);
    await cdp.send('Network.enable'); await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: profile.latency, downloadThroughput: profile.down * 1000 / 8, uploadThroughput: profile.up * 1000 / 8 });
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
    await page.addInitScript(() => {
      window.lab = { lcp: 0, cls: 0, usable: null };
      new PerformanceObserver(list => { for (const entry of list.getEntries()) window.lab.lcp = entry.startTime; }).observe({ type: 'largest-contentful-paint', buffered: true });
      new PerformanceObserver(list => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.lab.cls += entry.value; }).observe({ type: 'layout-shift', buffered: true });
      function ready() {
        const title = document.querySelector('h1'), nav = document.querySelector('nav');
        if (document.styleSheets.length && title?.getBoundingClientRect().height > 0 && nav?.getBoundingClientRect().height > 0 && getComputedStyle(title).visibility === 'visible') window.lab.usable = performance.now();
        else requestAnimationFrame(ready);
      }
      requestAnimationFrame(ready);
    });
    await page.goto(url, { waitUntil: 'load', timeout: 90000 }); await page.waitForTimeout(2000);
    const initial = await page.evaluate(() => ({ ...window.lab, transferred: performance.getEntriesByType('resource').reduce((sum, entry) => sum + entry.transferSize, 0) + performance.getEntriesByType('navigation')[0].transferSize }));
    // Include optional playback even when Save-Data or viewport position prevented autoplay.
    if (await page.locator('[data-replay]').count()) {
      await page.locator('.delivery-story').scrollIntoViewIfNeeded();
      await page.locator('[data-replay]').click();
      await page.waitForTimeout(2000);
    }
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await page.waitForTimeout(1200);
    const completeTransfer = await page.evaluate(() => performance.getEntriesByType('resource').reduce((sum, entry) => sum + entry.transferSize, 0) + performance.getEntriesByType('navigation')[0].transferSize);
    const row = { profile: profile.name, downKbps: profile.down, upKbps: profile.up, latencyMs: profile.latency, cpu: 4, index, ...initial, completeTransfer };
    report.runs.push(row); await save(); console.log(JSON.stringify({ label, ...row })); await context.close();
  }
}
await browser.close();
const median = values => [...values].sort((a,b) => a-b)[Math.floor(values.length/2)];
report.summary = [...new Set(report.runs.map(row => row.profile))].map(profile => {
  const rows = report.runs.filter(row => row.profile === profile), result = { profile };
  for (const key of ['performance', 'accessibility', 'lcp', 'cls', 'tbt', 'usable', 'transferred', 'completeTransfer']) {
    const values = rows.map(row => row[key]).filter(value => typeof value === 'number');
    if (values.length) result[key] = { median: median(values), worst: ['performance','accessibility'].includes(key) ? Math.min(...values) : Math.max(...values) };
  }
  return result;
});
await save(); console.log(JSON.stringify(report.summary, null, 2));
