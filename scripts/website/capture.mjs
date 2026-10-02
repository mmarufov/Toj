import { chromium } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const [directory, url = 'http://127.0.0.1:4173'] = process.argv.slice(2);
if (!directory) throw new Error('Usage: node capture.mjs OUTPUT_DIRECTORY [URL]');
await mkdir(directory, { recursive: true });
const browser = await chromium.launch();
for (const width of [1440, 390]) {
  const page = await browser.newPage({ viewport: { width, height: width === 390 ? 844 : 1100 }, deviceScaleFactor: 1 });
  await page.goto(url); await page.locator('.delivery-story').scrollIntoViewIfNeeded(); await page.locator('[data-replay]').click();
  for (const state of ['ready', 'sending', 'queued', 'retrying', 'accepted', 'delivered']) {
    await page.waitForFunction(state => document.querySelector('.delivery-story').dataset.state === state, state);
    if (state === 'delivered' || state === 'sending') await page.waitForTimeout(450);
    await page.locator('.delivery-story').screenshot({ path: path.join(directory, `${width}-${state}.png`) });
  }
  await page.waitForFunction(() => document.querySelector('.delivery-story').dataset.playback === 'complete');
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
  await page.screenshot({ path: path.join(directory, `${width}-full.png`), fullPage: true });
  await page.screenshot({ path: path.join(directory, `${width}-hero.png`) });
  await writeFile(path.join(directory, `${width}-reading-order.yml`), await page.locator('body').ariaSnapshot());
  await page.close();
}
await browser.close();
