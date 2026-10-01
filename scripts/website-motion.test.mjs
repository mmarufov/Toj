import assert from "node:assert/strict";
import test from "node:test";
import { setupMotion } from "../docs/motion.js";

function fixture(reduced = false) {
  const calls = [],
    observers = [],
    frames = new Map(),
    listeners = new Map();
  let id = 0,
    top = 200;
  function element() {
    const styles = new Map();
    return {
      styles,
      style: {
        setProperty: (k, v) => styles.set(k, v),
        removeProperty: (k) => styles.delete(k),
      },
      animate(keyframes, options) {
        const animation = {
          keyframes,
          options,
          cancelled: false,
          finished: new Promise(() => {}),
          cancel() {
            this.cancelled = true;
          },
        };
        calls.push(animation);
        return animation;
      },
    };
  }
  const bubbles = [element(), element(), element(), element()];
  const stage = {
    querySelectorAll: () => bubbles,
    getBoundingClientRect: () => ({ top, height: 620 }),
  };
  const phone = element(),
    note = element(),
    section = element();
  const preference = {
    matches: reduced,
    addEventListener: (_, fn) => (preference.change = fn),
    removeEventListener: () => (preference.change = null),
  };
  const window = {
    innerHeight: 1000,
    matchMedia: () => preference,
    IntersectionObserver: class {
      constructor(callback) {
        this.callback = callback;
        this.targets = new Set();
        observers.push(this);
      }
      observe(e) {
        this.targets.add(e);
      }
      unobserve(e) {
        this.targets.delete(e);
      }
      disconnect() {
        this.targets.clear();
      }
    },
    requestAnimationFrame(fn) {
      frames.set(++id, fn);
      return id;
    },
    cancelAnimationFrame: (id) => frames.delete(id),
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
  };
  const document = {
    querySelector: (selector) =>
      ({ ".product-stage": stage, ".phone": phone, ".floating-note": note })[
        selector
      ],
    querySelectorAll: () => [section],
  };
  const cleanup = setupMotion({ window, document });
  return {
    calls,
    observers,
    frames,
    listeners,
    stage,
    phone,
    note,
    section,
    preference,
    cleanup,
    enter(target, visible = true) {
      observers.at(-1).callback([{ target, isIntersecting: visible }]);
    },
    flush() {
      const pending = [...frames.values()];
      frames.clear();
      pending.forEach((fn) => fn());
    },
    move(value) {
      top = value;
      listeners.get("scroll")?.();
    },
  };
}

test("reduced motion starts without observers, frames, or animations", () => {
  const f = fixture(true);
  assert.equal(f.observers.length, 0);
  assert.equal(f.calls.length, 0);
  assert.equal(f.listeners.size, 0);
  f.cleanup();
});
test("messages stagger once and section entrance does not replay", () => {
  const f = fixture();
  f.enter(f.stage);
  f.enter(f.stage);
  assert.deepEqual(
    f.calls.map((a) => a.options.delay),
    [0, 120, 240, 360],
  );
  f.enter(f.section);
  f.enter(f.section);
  assert.equal(f.calls.length, 5);
  assert.equal(f.observers[0].targets.has(f.section), false);
  f.cleanup();
});
test("scroll updates coalesce into one frame and transforms stay bounded", () => {
  const f = fixture();
  f.enter(f.stage);
  f.move(-10000);
  f.move(-20000);
  assert.equal(f.frames.size, 1);
  f.flush();
  assert.equal(f.phone.styles.get("--scroll-tilt"), "3.5deg");
  assert.equal(f.phone.styles.get("--scroll-lift"), "-18px");
  f.move(20000);
  f.flush();
  assert.equal(f.phone.styles.get("--scroll-tilt"), "-3.5deg");
  assert.equal(f.phone.styles.get("--scroll-lift"), "18px");
  f.cleanup();
});
test("offscreen phone schedules no work", () => {
  const f = fixture();
  f.enter(f.stage);
  f.flush();
  f.enter(f.stage, false);
  f.move(-1000);
  assert.equal(f.frames.size, 0);
  f.cleanup();
});
test("changing preference cancels motion, clears transforms, and can resume", () => {
  const f = fixture();
  f.enter(f.stage);
  f.flush();
  f.move(-100);
  f.preference.matches = true;
  f.preference.change();
  assert.equal(f.frames.size, 0);
  assert.equal(f.listeners.size, 0);
  assert.equal(f.phone.styles.size, 0);
  assert.equal(f.note.styles.size, 0);
  assert.ok(f.calls.every((a) => a.cancelled));
  f.preference.matches = false;
  f.preference.change();
  assert.equal(f.observers.length, 2);
  f.enter(f.stage);
  f.flush();
  assert.equal(f.calls.length, 4);
  f.cleanup();
  assert.equal(f.preference.change, null);
});
test("unsupported browser retains native content without throwing", () => {
  const cleanup = setupMotion({ window: {}, document: {} });
  assert.doesNotThrow(cleanup);
});
