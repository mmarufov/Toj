// A local, deterministic illustration. This never calls Toj's API.
const demo = document.querySelector(".sync-demo");
const toggle = document.querySelector("#connection-toggle");
const queue = document.querySelector("#queue-message");
const reset = document.querySelector("#reset-demo");
const message = document.querySelector("#queued-message");
const status = document.querySelector("#demo-status");
let online = true;
let queued = false;
let delivered = false;

function render(description) {
  demo.dataset.state = online ? "online" : "offline";
  toggle.setAttribute("aria-pressed", String(!online));
  document.querySelector("#connection-label").textContent = online
    ? "Go offline"
    : "Reconnect";
  message.hidden = !queued;
  document.querySelector("#demo-empty").hidden = queued;
  message.classList.toggle("queued", !delivered);
  document.querySelector("#message-status").textContent = delivered
    ? "Synced · same message ID ✓✓"
    : "Saved on this device · pending";
  queue.disabled = queued;
  status.textContent = description;
}
toggle.disabled = false;
queue.disabled = false;
reset.disabled = false;
toggle.addEventListener("click", () => {
  online = !online;
  if (online && queued && !delivered) {
    delivered = true;
    render(
      "Connection restored. The queued message is now synced, without creating a duplicate.",
    );
  } else {
    render(
      online
        ? "Back online. Try going offline and queuing a message."
        : "Offline. You can still queue a message. It will wait for the connection.",
    );
  }
});
queue.addEventListener("click", () => {
  queued = true;
  delivered = online;
  render(
    online
      ? "Message synced. Reset, then go offline to see how a pending send recovers."
      : "Saved locally. Reconnect to sync this message with the same ID.",
  );
});
reset.addEventListener("click", () => {
  online = true;
  queued = false;
  delivered = false;
  render("Start by going offline, then queue a sample message.");
});
render("Start by going offline, then queue a sample message.");

// Motion is optional: failed loading never hides content or disables the demo.
import("./motion.js").then(({ setupMotion }) => setupMotion()).catch(() => {});

// Optional typography enhancement. Native layout is the fallback if it fails.
// Keep the demo functional independently of font loading and text measurement.
async function enhanceTypography() {
  const { prepare, layout } = await import("./assets/pretext.js");
  await document.fonts.ready;
  const elements = [...document.querySelectorAll(".engineering-card > p")];
  const prepared = new Map();
  function measure() {
    for (const element of elements) {
      const style = getComputedStyle(element);
      const font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      const key = `${font}:${element.textContent}`;
      if (prepared.get(element)?.key !== key)
        prepared.set(element, {
          key,
          handle: prepare(element.textContent, font),
        });
      const result = layout(
        prepared.get(element).handle,
        element.clientWidth,
        parseFloat(style.lineHeight),
      );
      element.style.minHeight = `${result.height}px`;
    }
  }
  const observer = new ResizeObserver(measure);
  for (const element of elements) observer.observe(element);
  // Editing is restricted to local design previews, never the published page.
  if (
    ["localhost", "127.0.0.1"].includes(location.hostname) &&
    new URLSearchParams(location.search).has("edit")
  ) {
    for (const element of elements) {
      element.contentEditable = "true";
      new MutationObserver(measure).observe(element, {
        childList: true,
        characterData: true,
        subtree: true,
      });
    }
  }
  measure();
}
enhanceTypography().catch(() => {
  /* Native CSS text layout remains available. */
});
