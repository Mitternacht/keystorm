// Keystorm website: small progressive enhancements. The page works without this file.
(() => {
  const root = document.documentElement;
  root.classList.add("js");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Mode tabs (WAI-ARIA tabs pattern) with a sliding glass thumb.
  // Without JavaScript every example stays visible; here we show one at a time.
  const tablist = document.querySelector('[role="tablist"]');
  if (tablist) {
    const tabs = [...tablist.querySelectorAll('[role="tab"]')];
    const thumb = tablist.querySelector(".seg-thumb");
    const panelFor = (tab) => document.getElementById(tab.getAttribute("aria-controls"));
    const place = (tab) => {
      if (!thumb || !tab) return;
      thumb.style.setProperty("--tw", `${tab.offsetWidth}px`);
      thumb.style.setProperty("--tx", `${tab.offsetLeft - 4}px`);
    };
    const select = (tab, focus, animate) => {
      tabs.forEach((t) => {
        const on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        const panel = panelFor(t);
        if (!panel) return;
        panel.hidden = !on;
        if (on && animate && !reduceMotion) { panel.classList.remove("enter"); void panel.offsetWidth; panel.classList.add("enter"); }
      });
      place(tab);
      if (focus) tab.focus();
    };
    tabs.forEach((tab, i) => {
      tab.addEventListener("click", () => select(tab, false, true));
      tab.addEventListener("keydown", (e) => {
        const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
        if (next === undefined) return;
        e.preventDefault();
        select(tabs[(next + tabs.length) % tabs.length], true, true);
      });
    });
    const current = () => tabs.find((t) => t.getAttribute("aria-selected") === "true") || tabs[0];
    select(current(), false, false);
    requestAnimationFrame(() => place(current()));
    window.addEventListener("resize", () => place(current()));
  }

  // Hero: type the dictated sentence once (about four seconds), then stop.
  const stage = document.querySelector(".stage");
  const typed = document.querySelector(".typed");
  const time = document.querySelector(".hud-time");
  if (stage && typed && !reduceMotion) {
    const full = typed.dataset.typed || typed.textContent;
    let i = 0;
    let seconds = 3;
    // Reserve the finished sentence's height so nothing below jumps while it types.
    const line = typed.parentElement;
    const reserve = () => {
      const now = typed.textContent;
      line.style.minHeight = "";
      typed.textContent = full;
      line.style.minHeight = `${line.offsetHeight}px`;
      typed.textContent = now;
    };
    reserve();
    window.addEventListener("resize", reserve);
    typed.textContent = "";
    stage.classList.add("typing");
    const clock = time ? setInterval(() => { seconds += 1; time.textContent = `0:00:${String(seconds).padStart(2, "0")}`; }, 1000) : 0;
    const tick = () => {
      i += 1;
      typed.textContent = full.slice(0, i);
      if (i < full.length) { setTimeout(tick, 30 + Math.random() * 28); return; }
      stage.classList.remove("typing");
      stage.classList.add("done");
      clearInterval(clock);
    };
    setTimeout(tick, 700);
  }

  // Specular rim light that follows the pointer across glass surfaces.
  // Reads all rectangles first, then writes, so the browser lays out once per frame.
  if (!reduceMotion && window.matchMedia("(pointer: fine)").matches) {
    const surfaces = [...document.querySelectorAll(".glass, .glass-dark")];
    let frame = 0;
    let x = 0;
    let y = 0;
    window.addEventListener("pointermove", (e) => {
      x = e.clientX;
      y = e.clientY;
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        const rects = surfaces.map((el) => el.getBoundingClientRect());
        surfaces.forEach((el, n) => {
          const r = rects[n];
          if (r.bottom < -200 || r.top > innerHeight + 200) return;
          el.style.setProperty("--mx", `${x - r.left}px`);
          el.style.setProperty("--my", `${y - r.top}px`);
        });
      });
    }, { passive: true });
  }

  // Gentle reveal on scroll.
  const reveal = [...document.querySelectorAll(".section-head, .step, .chips, .modes, .privacy, .card, .details, .cta > *")];
  if ("IntersectionObserver" in window && !reduceMotion) {
    reveal.forEach((el) => el.classList.add("reveal"));
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => { if (entry.isIntersecting) { entry.target.classList.add("in"); io.unobserve(entry.target); } });
    }, { rootMargin: "0px 0px 6% 0px", threshold: 0.01 });
    reveal.forEach((el) => io.observe(el));
  }
})();
