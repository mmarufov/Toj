// Run with: node --test scripts/website.test.mjs
// These are deterministic UI-controller and static-document checks, not backend tests.
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import test from "node:test";

const docs = new URL("../docs/", import.meta.url);
const html = readFileSync(new URL("index.html", docs), "utf8");
const script = readFileSync(new URL("site.js", docs), "utf8");

function fixture() {
  const elements = new Map();
  for (const selector of [
    ".sync-demo",
    "#connection-toggle",
    "#queue-message",
    "#reset-demo",
    "#queued-message",
    "#demo-status",
    "#connection-label",
    "#demo-empty",
    "#message-status",
  ]) {
    const listeners = new Map();
    elements.set(selector, {
      dataset: {},
      attributes: {},
      classes: new Set(),
      textContent: "",
      disabled: true,
      hidden: false,
      setAttribute(name, value) {
        this.attributes[name] = value;
      },
      addEventListener(type, listener) {
        listeners.set(type, listener);
      },
      click() {
        if (!this.disabled) listeners.get("click")?.();
      },
      classList: { toggle() {} },
    });
  }
  const document = {
    querySelector(selector) {
      assert.ok(elements.has(selector), `Unknown DOM selector ${selector}`);
      return elements.get(selector);
    },
  };
  // The optional text-layout import intentionally has no loader here. Its rejected
  // promise must not break the demo, just as a missing optional asset must not.
  runInNewContext(script, { document });
  return (selector) => elements.get(selector);
}

test("initial state is online, queue enabled, sample message absent", () => {
  const get = fixture();
  assert.equal(get(".sync-demo").dataset.state, "online");
  assert.equal(get("#queued-message").hidden, true);
  assert.equal(get("#queue-message").disabled, false);
  assert.equal(get("#connection-toggle").attributes["aria-pressed"], "false");
});
test("offline send is pending, then reconnect reconciles the same message", () => {
  const get = fixture();
  const original = get("#queued-message");
  get("#connection-toggle").click();
  assert.equal(get("#connection-toggle").attributes["aria-pressed"], "true");
  get("#queue-message").click();
  assert.equal(original.hidden, false);
  assert.match(get("#message-status").textContent, /pending/);
  assert.equal(get("#queue-message").disabled, true);
  get("#connection-toggle").click();
  assert.match(get("#message-status").textContent, /Synced/);
  assert.equal(get("#queued-message"), original);
});
test("online send completes immediately and disabled button prevents another send", () => {
  const get = fixture();
  get("#queue-message").click();
  assert.match(get("#message-status").textContent, /Synced/);
  const before = get("#demo-status").textContent;
  get("#queue-message").click();
  assert.equal(get("#demo-status").textContent, before);
});
test("disconnect after delivery never turns an accepted message back into pending", () => {
  const get = fixture();
  get("#queue-message").click();
  get("#connection-toggle").click();
  assert.match(get("#message-status").textContent, /Synced/);
  get("#connection-toggle").click();
  assert.match(get("#message-status").textContent, /Synced/);
});
test("reset restores the initial state from pending and from delivered", () => {
  const get = fixture();
  for (const reconnect of [false, true]) {
    get("#connection-toggle").click();
    get("#queue-message").click();
    if (reconnect) get("#connection-toggle").click();
    get("#reset-demo").click();
    assert.equal(get(".sync-demo").dataset.state, "online");
    assert.equal(get("#queued-message").hidden, true);
    assert.equal(get("#queue-message").disabled, false);
  }
});
test("all local assets and fragment links exist, with unique IDs", () => {
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, value] of html.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
    if (value.startsWith("#")) {
      if (value.length > 1) assert.ok(ids.includes(value.slice(1)), value);
    } else if (!/^(https?:|mailto:)/.test(value)) {
      assert.ok(existsSync(fileURLToPath(new URL(value, docs))), value);
    }
  }
  assert.ok(existsSync(new URL("assets/pretext.js", docs)));
});
test("page preserves domain, accessibility baseline and truthful availability", () => {
  assert.equal(
    readFileSync(new URL("CNAME", docs), "utf8").trim(),
    "tojchat.tech",
  );
  assert.ok(existsSync(new URL(".nojekyll", docs)));
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1);
  assert.match(html, /aria-live="polite"/);
  assert.match(html, /not a live backend test/);
  assert.ok(html.replace(/\s+/g, ' ').includes('not end-to-end encrypted'));
  assert.match(html, /isn't accepting public users/);
  assert.doesNotMatch(
    script,
    /\bfetch\s*\(|\bXMLHttpRequest\b|\bWebSocket\s*\(/,
  );
});
