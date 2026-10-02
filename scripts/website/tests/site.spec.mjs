import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
const scene = page => page.locator('.delivery-story');
async function open(page) { await page.goto('/'); await expect(scene(page)).toHaveAttribute('data-enhanced', 'true'); }
async function replay(page) { await page.locator('[data-replay]').click(); await expect(scene(page)).toHaveAttribute('data-state', 'ready'); }

test('message survives signal loss, preserves identity, and separates acceptance from delivery', async ({ page, baseURL }) => {
  const errors = [], remote = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (new URL(request.url()).origin !== new URL(baseURL).origin) remote.push(request.url()); });
  await open(page); await replay(page);
  await page.evaluate(() => { window.savedMessage = document.querySelector('[data-sender-message]'); });
  await expect(scene(page)).toHaveAttribute('data-state', 'queued');
  await expect(page.locator('[data-sender-message]')).toHaveCSS('opacity', '1');
  await expect(page.locator('[data-recipient-message]')).toHaveCSS('opacity', '0');
  await expect(page.locator('.conversation-recipient .prior-message .message-check')).toHaveCSS('visibility', 'visible');
  const id = await scene(page).getAttribute('data-message-id');
  await expect(scene(page)).toHaveAttribute('data-state', 'accepted');
  await expect(page.locator('[data-message-state]')).toHaveText('Server confirmed');
  await expect(page.locator('[data-recipient-message]')).toHaveCSS('opacity', '0');
  await expect(scene(page)).toHaveAttribute('data-playback', 'complete');
  await expect(page.locator('[data-recipient-message]')).toHaveCSS('opacity', '1');
  expect(await page.evaluate(() => window.savedMessage === document.querySelector('[data-sender-message]'))).toBe(true);
  expect(await scene(page).getAttribute('data-message-id')).toBe(id);
  expect(errors).toEqual([]); expect(remote).toEqual([]);
});
test('pause and replay cooperate with offscreen suspension', async ({ page }) => {
  await open(page); await replay(page); await expect(scene(page)).toHaveAttribute('data-state', 'queued');
  await page.locator('[data-pause]').click(); await expect(scene(page)).toHaveAttribute('data-playback', 'paused');
  await page.locator('#about').scrollIntoViewIfNeeded(); await scene(page).scrollIntoViewIfNeeded();
  await expect(scene(page)).toHaveAttribute('data-playback', 'paused');
  await page.locator('[data-pause]').click(); await expect(scene(page)).toHaveAttribute('data-playback', 'playing');
  await replay(page); await page.locator('#about').scrollIntoViewIfNeeded();
  await expect(scene(page)).toHaveAttribute('data-playback', 'paused');
  await scene(page).scrollIntoViewIfNeeded(); await expect(scene(page)).toHaveAttribute('data-playback', 'playing');
});
test('hidden tabs suspend; pagehide cleanup prevents stale requests', async ({ page }) => {
  await open(page); await replay(page);
  for (const hidden of [true, false]) {
    await page.evaluate(hidden => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => hidden }); document.dispatchEvent(new Event('visibilitychange')); }, hidden);
    await expect(scene(page)).toHaveAttribute('data-playback', hidden ? 'paused' : 'playing');
  }
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false })));
  const previous = await scene(page).getAttribute('data-state'); await page.locator('[data-replay]').click();
  await page.waitForTimeout(1000); await expect(scene(page)).toHaveAttribute('data-state', previous);
});
test('reduced motion is static without loading Motion and settles an active run', async ({ page }) => {
  const requests = []; page.on('request', request => { if (/\/motion-/.test(request.url())) requests.push(request.url()); });
  await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page);
  await expect(scene(page)).toHaveAttribute('data-state', 'delivered');
  await expect(page.locator('.story-transcript')).toBeVisible(); await expect(page.locator('[data-story-controls]')).toBeHidden();
  expect(requests).toEqual([]);
  await page.emulateMedia({ reducedMotion: 'no-preference' }); await replay(page);
  await expect(scene(page)).toHaveAttribute('data-playback', 'playing');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(scene(page)).toHaveAttribute('data-state', 'delivered'); await expect(scene(page)).toHaveAttribute('data-playback', 'complete');
});
test('Save-Data defaults to stillness but allows deliberate playback', async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(navigator, 'connection', { value: Object.assign(new EventTarget(), { saveData: true, effectiveType: '4g' }) }));
  await open(page); await expect(scene(page)).toHaveAttribute('data-state', 'delivered');
  expect(await page.evaluate(() => performance.getEntriesByType('resource').some(entry => /\/motion-/.test(entry.name)))).toBe(false);
  await replay(page); await expect(scene(page)).toHaveAttribute('data-playback', 'playing');
});
test('phone autoplay waits until both conversations can be seen', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page);
  await expect(scene(page)).toHaveAttribute('data-playback', 'static');
  expect(await page.evaluate(() => performance.getEntriesByType('resource').some(entry => /\/motion-/.test(entry.name)))).toBe(false);
  await scene(page).scrollIntoViewIfNeeded();
  await expect(scene(page)).toHaveAttribute('data-playback', 'playing');
});
test('blocked motion and fonts preserve content and delivery controls', async ({ page }) => {
  await page.route(/\/(motion-.*\.js|.*\.woff2)$/, route => route.abort());
  await open(page); await replay(page); await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(scene(page)).toHaveAttribute('data-state', 'queued'); await page.locator('[data-pause]').click();
  await expect(scene(page)).toHaveAttribute('data-playback', 'paused'); await page.locator('#trust').scrollIntoViewIfNeeded();
  await expect(page.getByText('The server holds the keys, so Toj operators can decrypt your messages.')).toBeVisible();
});
test('without JavaScript, navigation, story, security and FAQ stay available', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ javaScriptEnabled: false }); const page = await context.newPage(); await page.goto(baseURL);
  await expect(scene(page)).toHaveAttribute('data-state', 'delivered'); await expect(page.locator('.story-transcript')).toBeVisible();
  await expect(page.locator('[data-story-controls]')).toBeHidden(); await page.locator("summary").filter({ hasText: "What's built so far?" }).click();
  await expect(page.getByText(/Voice and video calls are implemented but disabled/)).toBeVisible(); await context.close();
});
test('keyboard, native disclosures, 44px controls, and WCAG AA audit', async ({ page, browserName }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page);
  await page.keyboard.press(browserName === 'webkit' && process.platform === 'darwin' ? 'Alt+Tab' : 'Tab'); await expect(page.getByText('Skip to content', { exact: true })).toBeFocused();
  await page.keyboard.press('Enter'); await expect(page.locator('#main')).toBeFocused();
  await page.locator("summary").filter({ hasText: "What's built so far?" }).focus(); await page.keyboard.press('Enter');
  await expect(page.getByText(/Voice and video calls are implemented but disabled/)).toBeVisible();
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze(); expect(results.violations).toEqual([]);
  for (const control of await page.locator('button:visible, summary:visible, .button:visible, nav a:visible').all()) expect((await control.boundingBox()).height).toBeGreaterThanOrEqual(44);
});
for (const width of [320, 390, 768, 1440, 1920]) {
  test(`layout fits ${width}px without clipping the message`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 }); await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const message = await page.locator('[data-message-state]').boundingBox(), card = await page.locator('.conversation-sender').boundingBox();
    expect(message.y + message.height).toBeLessThanOrEqual(card.y + card.height - 2);
    for (const section of ['#trust', '#experience', '#engineering', '#about']) { await page.locator(section).scrollIntoViewIfNeeded(); await expect(page.locator(section)).toBeVisible(); }
  });
}
test('200 percent content zoom keeps content and controls reachable', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 1000 }); await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page);
  await page.addStyleTag({ content: 'html { zoom: 2; }' });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.locator('#about').scrollIntoViewIfNeeded(); await page.locator("summary").filter({ hasText: "What's built so far?" }).click();
  await expect(page.getByText(/Voice and video calls are implemented but disabled/)).toBeVisible();
});
