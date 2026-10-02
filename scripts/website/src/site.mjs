import { createDeliveryStory } from "./story.mjs";

const scene = document.querySelector(".delivery-story");
if (scene) enhanceStory(scene);

function enhanceStory(scene) {
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const mobile = matchMedia("(max-width: 639px)");
  const connection = navigator.connection;
  const controls = scene.querySelector("[data-story-controls]");
  const pause = scene.querySelector("[data-pause]");
  const pauseLabel = scene.querySelector("[data-pause-label]");
  const replay = scene.querySelector("[data-replay]");
  const signal = scene.querySelector("[data-signal-state]");
  const routeNote = scene.querySelector("[data-route-note]");
  const messageStatus = scene.querySelector("[data-message-state]");
  const description = scene.querySelector("[data-story-description]");
  const announcement = scene.querySelector("[data-story-announcement]");
  const sender = scene.querySelector("[data-sender-message]");
  const recipient = scene.querySelector("[data-recipient-message]");
  const packet = scene.querySelector("[data-packet]");
  const track = scene.querySelector(".route-track");
  const copy = {
    ready: ["Connected", "a little distance", "Ready to send", "An ordinary message. An imperfect connection."],
    sending: ["Sending", "on its way", "Saved on this phone", "Saved on your phone. Sending to Maya."],
    queued: ["Signal lost", "waiting for a signal", "Saved here. Waiting for a signal.", "The signal dropped. Your message is still here."],
    retrying: ["Reconnecting", "the same message", "Retrying the same message", "Back online. Retrying the same message."],
    accepted: ["Saved in the cloud", "catching up", "Server confirmed", "The server has it. Maya's phone is catching up."],
    delivered: ["Back in sync", "the same message", "Delivered", "Connection restored. One message, delivered."],
  };
  let animate;
  let animationLoad;
  let animations = [];
  let lastState = "delivered";
  let visible = false;
  let started = false;
  let userPaused = false;
  let suspended = false;
  let userInitiated = false;
  let destroyed = false;
  let requestGeneration = 0;
  const lowData = () => connection?.saveData || ["slow-2g", "2g"].includes(connection?.effectiveType);
  const canRun = () => visible && !document.hidden && !reducedMotion.matches;

  function cancelAnimations() {
    for (const control of animations) control.cancel();
    animations = [];
  }
  function enter(element) {
    if (!animate || reducedMotion.matches) return;
    animations.push(animate(element, {
      opacity: [0, 1], transform: ["translateY(7px)", "translateY(0px)"],
    }, { duration: .4, ease: [.22, 1, .36, 1] }));
  }
  function transmit() {
    if (!animate || reducedMotion.matches) return;
    const axis = mobile.matches ? "Y" : "X";
    const distance = (mobile.matches ? track.clientHeight : track.clientWidth) - 6;
    animations.push(animate(packet, {
      transform: [`translate${axis}(0px)`, `translate${axis}(${distance}px)`],
      opacity: [0, 1, 1, 0],
    }, { duration: .9, ease: "easeInOut" }));
  }
  const story = createDeliveryStory({ render(frame) {
    scene.dataset.state = frame.state;
    scene.dataset.playback = frame.playback;
    scene.dataset.messageId = frame.messageId;
    const words = copy[frame.state];
    signal.textContent = words[0];
    routeNote.textContent = words[1];
    messageStatus.textContent = words[2];
    description.textContent = words[3];
    const paused = frame.playback === "paused";
    pauseLabel.textContent = paused ? "Resume" : "Pause";
    pause.setAttribute("aria-label", `${paused ? "Resume" : "Pause"} delivery animation`);
    pause.disabled = !["playing", "paused"].includes(frame.playback);
    if (frame.state !== lastState) {
      cancelAnimations();
      if (frame.state === "sending") { enter(sender); transmit(); }
      if (frame.state === "retrying") transmit();
      if (frame.state === "delivered") enter(recipient);
      lastState = frame.state;
    }
    for (const control of animations) {
      if (paused) control.pause();
      else if (frame.playback === "playing") control.play();
    }
    if (frame.playback === "complete") {
      cancelAnimations();
      if (userInitiated) announcement.textContent = "Illustration complete. The message was saved locally, retried, and delivered once.";
    }
  } });

  async function play(manual = false) {
    if (destroyed || reducedMotion.matches) return;
    started = true;
    userPaused = false;
    userInitiated = manual;
    announcement.textContent = manual ? "Playing the delivery illustration." : "";
    const generation = ++requestGeneration;
    if (!animationLoad) animationLoad = import("motion/mini").then((module) => { animate = module.animate; }).catch(() => {});
    await animationLoad;
    if (destroyed || generation !== requestGeneration || reducedMotion.matches) return;
    cancelAnimations();
    story.play();
    if (!canRun()) { suspended = true; story.pause(); }
  }
  function updateVisibility() {
    if (destroyed) return;
    if (!canRun() && story.snapshot().playback === "playing") {
      suspended = true;
      story.pause();
    } else if (canRun() && suspended && !userPaused) {
      suspended = false;
      story.resume();
    } else if (canRun() && !started && !lowData()) {
      void play();
    }
  }
  function applyPreferences() {
    scene.dataset.reduced = String(reducedMotion.matches);
    controls.hidden = reducedMotion.matches;
    if (reducedMotion.matches || lowData()) {
      ++requestGeneration;
      cancelAnimations();
      story.finish();
      suspended = false;
    }
    // Changing preferences never triggers an unexpected new autoplay.
    if (reducedMotion.matches) started = true;
  }
  function togglePause() {
    if (story.snapshot().playback === "playing") {
      userPaused = true;
      story.pause();
      announcement.textContent = "Illustration paused.";
    } else if (story.snapshot().playback === "paused") {
      userPaused = false;
      if (canRun()) { suspended = false; story.resume(); }
      announcement.textContent = "Illustration resumed.";
    }
  }
  function replayStory() { void play(true); }
  function onResize() { cancelAnimations(); }
  function onPageHide(event) {
    if (event.persisted) { suspended = true; story.pause(); cancelAnimations(); return; }
    destroyed = true;
    ++requestGeneration;
    story.destroy();
    cancelAnimations();
    observer?.disconnect();
    document.removeEventListener("visibilitychange", updateVisibility);
    reducedMotion.removeEventListener("change", applyPreferences);
    connection?.removeEventListener("change", applyPreferences);
    mobile.removeEventListener("change", onResize);
    window.removeEventListener("pageshow", updateVisibility);
  }
  const observer = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting && entries[0].intersectionRatio >= .55;
    updateVisibility();
  }, { threshold: [0, .55] }) : null;

  scene.dataset.enhanced = "true";
  controls.hidden = false;
  pause.disabled = true;
  applyPreferences();
  pause.addEventListener("click", togglePause);
  replay.addEventListener("click", replayStory);
  reducedMotion.addEventListener("change", applyPreferences);
  connection?.addEventListener("change", applyPreferences);
  mobile.addEventListener("change", onResize);
  document.addEventListener("visibilitychange", updateVisibility);
  window.addEventListener("pagehide", onPageHide, { once: false });
  window.addEventListener("pageshow", updateVisibility);
  if (observer) observer.observe(scene);
  else { visible = true; updateVisibility(); }
}
