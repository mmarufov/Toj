// Progressive enhancement only. Content is visible before, during, and without JS.
export function setupMotion({ window, document } = globalThis) {
  if (!window.matchMedia || !window.IntersectionObserver) return () => {};
  const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
  const stage = document.querySelector(".product-stage");
  const phone = document.querySelector(".phone");
  const note = document.querySelector(".floating-note");
  if (!stage || !phone) return () => {};
  const sections = [
    ...document.querySelectorAll(
      ".section-heading, .demo-story, .sync-demo, .engineering-intro, .engineering-card, .about-copy, .project-notes, .closing",
    ),
  ];
  const seen = new Set();
  const animations = new Set();
  let observer;
  let frame = null;
  let stageVisible = false;

  function animate(element, keyframes, delay = 0) {
    if (!element?.animate) return;
    const animation = element.animate(keyframes, {
      duration: 720,
      delay,
      easing: "cubic-bezier(.2,.75,.25,1)",
      // Only hold the first frame during the stagger, never override final styling.
      fill: "backwards",
    });
    animations.add(animation);
    animation.finished.then(
      () => animations.delete(animation),
      () => animations.delete(animation),
    );
  }

  function updatePhone() {
    frame = null;
    if (preference.matches || !stageVisible) return;
    const rect = stage.getBoundingClientRect();
    const progress = Math.max(
      0,
      Math.min(
        1,
        (window.innerHeight - rect.top) / (window.innerHeight + rect.height),
      ),
    );
    phone.style.setProperty("--scroll-tilt", `${(progress - 0.5) * 7}deg`);
    phone.style.setProperty("--scroll-lift", `${(progress - 0.5) * -36}px`);
    note?.style.setProperty("--note-lift", `${(progress - 0.5) * -18}px`);
  }

  function schedule() {
    if (preference.matches || !stageVisible || frame !== null) return;
    frame = window.requestAnimationFrame(updatePhone);
  }

  function stop() {
    observer?.disconnect();
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    stageVisible = false;
    window.removeEventListener("scroll", schedule);
    window.removeEventListener("resize", schedule);
    for (const animation of animations) animation.cancel();
    animations.clear();
    phone.style.removeProperty("--scroll-tilt");
    phone.style.removeProperty("--scroll-lift");
    note?.style.removeProperty("--note-lift");
  }

  function start() {
    stop();
    if (preference.matches) return;
    observer = new window.IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.target === stage) {
            stageVisible = entry.isIntersecting;
            schedule();
          }
          if (!entry.isIntersecting || seen.has(entry.target)) continue;
          seen.add(entry.target);
          if (entry.target === stage) {
            [...stage.querySelectorAll(".bubble")].forEach((bubble, index) => {
              animate(
                bubble,
                [
                  { opacity: 0.2, transform: "translateY(14px) scale(.97)" },
                  { opacity: 1, transform: "translateY(0) scale(1)" },
                ],
                index * 120,
              );
            });
          } else {
            animate(entry.target, [
              { opacity: 0.25, transform: "translateY(24px)" },
              { opacity: 1, transform: "translateY(0)" },
            ]);
            observer.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.12 },
    );
    observer.observe(stage);
    sections.forEach((element) => observer.observe(element));
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule, { passive: true });
  }

  start();
  preference.addEventListener("change", start);
  return () => {
    stop();
    preference.removeEventListener("change", start);
  };
}
