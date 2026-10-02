// A deterministic illustration, independent of DOM, animation library, and network.
export const beats = Object.freeze([
  { at: 0, state: "ready" },
  { at: 900, state: "sending" },
  { at: 2000, state: "queued" },
  { at: 4500, state: "retrying" },
  { at: 5500, state: "accepted" },
  { at: 6500, state: "delivered" },
]);
export const duration = 8000;

export function createDeliveryStory({ render, clock = {
  now: () => performance.now(),
  set: (fn, delay) => setTimeout(fn, delay),
  clear: (id) => clearTimeout(id),
} }) {
  let elapsed = duration;
  let start = 0;
  let playback = "idle";
  let timer = null;
  let destroyed = false;
  // This ID represents the one message throughout a run, including every retry.
  const messageId = "illustration-message-1";
  const currentElapsed = () => playback === "playing"
    ? Math.min(duration, elapsed + clock.now() - start) : elapsed;
  const snapshot = () => {
    const time = currentElapsed();
    return { messageId, elapsed: time, playback,
      state: beats.findLast((beat) => beat.at <= time).state };
  };
  function cancel() {
    if (timer !== null) clock.clear(timer);
    timer = null;
  }
  function tick() {
    if (destroyed || playback !== "playing") return;
    const time = currentElapsed();
    if (time >= duration) {
      elapsed = duration;
      playback = "complete";
      cancel();
    }
    render(snapshot());
    if (playback === "playing") {
      const next = beats.find((beat) => beat.at > time)?.at ?? duration;
      timer = clock.set(tick, next - time);
    }
  }
  function play() {
    if (destroyed) return;
    cancel();
    elapsed = 0;
    start = clock.now();
    playback = "playing";
    tick();
  }
  function pause() {
    if (destroyed || playback !== "playing") return;
    elapsed = currentElapsed();
    playback = "paused";
    cancel();
    render(snapshot());
  }
  function resume() {
    if (destroyed || playback !== "paused") return;
    start = clock.now();
    playback = "playing";
    tick();
  }
  function finish() {
    if (destroyed) return;
    cancel();
    elapsed = duration;
    playback = "complete";
    render(snapshot());
  }
  function destroy() {
    cancel();
    destroyed = true;
  }
  return { play, pause, resume, finish, destroy, snapshot };
}
