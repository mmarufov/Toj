import assert from 'node:assert/strict';
import test from 'node:test';
import { createDeliveryStory } from './website/src/story.mjs';

function fixture() {
  let time = 0, id = 0;
  const pending = new Map(), frames = [];
  const clock = { now: () => time, set: (fn, delay) => { pending.set(++id, { at: time + delay, fn }); return id; }, clear: id => pending.delete(id) };
  const story = createDeliveryStory({ clock, render: frame => frames.push(frame) });
  const advance = amount => {
    const end = time + amount;
    while (true) {
      const next = [...pending.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      time = next[1].at; pending.delete(next[0]); next[1].fn();
    }
    time = end;
  };
  return { story, frames, pending, advance };
}
test('one message survives all delivery states and settles without looping', () => {
  const f = fixture(); f.story.play(); f.advance(20000);
  assert.deepEqual(f.frames.map(frame => frame.state), ['ready', 'sending', 'queued', 'retrying', 'accepted', 'delivered', 'delivered']);
  assert.equal(new Set(f.frames.map(frame => frame.messageId)).size, 1);
  assert.equal(f.story.snapshot().playback, 'complete'); assert.equal(f.pending.size, 0);
});
test('pause freezes time and resume preserves the exact remaining delay', () => {
  const f = fixture(); f.story.play(); f.advance(2500); f.story.pause();
  assert.equal(f.pending.size, 0); f.advance(10000); assert.equal(f.story.snapshot().elapsed, 2500);
  f.story.resume(); f.advance(1999); assert.equal(f.story.snapshot().state, 'queued');
  f.advance(1); assert.equal(f.story.snapshot().state, 'retrying');
});
test('replay cancels the previous timer without duplicate transitions', () => {
  const f = fixture(); f.story.play(); f.advance(3000); f.story.play();
  assert.equal(f.pending.size, 1); assert.equal(f.story.snapshot().state, 'ready');
  const count = f.frames.length; f.advance(899); assert.equal(f.frames.length, count);
  f.advance(1); assert.equal(f.frames.at(-1).state, 'sending');
});
test('reduced motion completion cancels all work', () => {
  const f = fixture(); f.story.play(); f.advance(3000); f.story.finish();
  assert.equal(f.story.snapshot().state, 'delivered'); assert.equal(f.story.snapshot().playback, 'complete');
  const count = f.frames.length; f.advance(20000); assert.equal(f.frames.length, count); assert.equal(f.pending.size, 0);
});
test('destroy clears timers and ignores stale requests', () => {
  const f = fixture(); f.story.play(); f.advance(1200); f.story.destroy(); const count = f.frames.length;
  f.story.play(); f.story.pause(); f.story.resume(); f.story.finish(); f.advance(20000);
  assert.equal(f.frames.length, count); assert.equal(f.pending.size, 0);
});
