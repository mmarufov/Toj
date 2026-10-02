import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import test from 'node:test';
import { report } from './website/budget.mjs';

const docs = new URL('../docs/', import.meta.url);
const html = readFileSync(new URL('index.html', docs), 'utf8');
const plain = html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');

test('all local assets and fragments resolve, with unique IDs', () => {
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, value] of html.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
    if (value.startsWith('#')) { if (value.length > 1) assert.ok(ids.includes(value.slice(1)), value); }
    else if (!/^(https?:|mailto:)/.test(value)) assert.ok(existsSync(new URL(value, docs)), value);
  }
  for (const name of readdirSync(new URL('assets/', docs)).filter(name => name.endsWith('.css'))) {
    for (const [, value] of readFileSync(new URL(`assets/${name}`, docs), 'utf8').matchAll(/url\(["']?([^"')]+)["']?\)/g)) assert.ok(existsSync(new URL(`assets/${value}`, docs)), value);
  }
  assert.ok(existsSync(new URL('assets/toj-social.png', docs)));
});
test('shipping facts and prominent threat model remain explicit', () => {
  assert.match(plain, /A little closer\. Even on a weak signal\./);
  assert.match(plain, /Toj operators can decrypt your messages/);
  assert.match(plain, /not end-to-end encrypted/);
  assert.match(plain, /Secret Chats are planned/);
  assert.match(plain, /isn't accepting public users yet/);
  assert.match(plain, /implemented but disabled/);
  assert.match(plain, /This test did not run the iOS app or use a physical mobile network/);
  assert.match(plain, /September 30, 2026/); assert.match(plain, /47120dc/);
  assert.ok(html.indexOf('id="trust"') < html.indexOf('id="experience"'));
  assert.doesNotMatch(html, /[\u2014\u2018\u2019]/);
  assert.equal((plain.match(/Not the /g) || []).length, 1);
});
test('static document preserves reading, navigation and Pages configuration', () => {
  assert.equal(readFileSync(new URL('CNAME', docs), 'utf8').trim(), 'tojchat.tech');
  assert.ok(existsSync(new URL('.nojekyll', docs)));
  assert.equal((html.match(/<h1\b/g) || []).length, 1);
  for (const anchor of ['experience', 'engineering', 'about', 'trust']) assert.ok(html.includes(`id="${anchor}"`));
  assert.match(html, /data-state="delivered"/); assert.match(html, /data-story-controls hidden/);
  assert.match(html, /<ol class="story-transcript">/); assert.match(html, /<html lang="en">/);
  assert.match(html, /lang="tg">Ҳисор/); assert.match(html, /no messages leave this page/);
});
test('runtime scripts are local and contain no network or tracking clients', () => {
  assert.doesNotMatch(html, /<script[^>]+src="https?:/);
  for (const file of readdirSync(new URL('assets/', docs)).filter(file => file.endsWith('.js'))) {
    assert.doesNotMatch(readFileSync(new URL(`assets/${file}`, docs), 'utf8'), /\bfetch\s*\(|\bXMLHttpRequest\b|\bWebSocket\s*\(|sendBeacon|localStorage/);
  }
});
test('all compressed payload budgets pass', () => {
  for (const check of report.checks) assert.ok(check.bytes <= check.limit, `${check.name}: ${check.bytes} > ${check.limit}`);
});
