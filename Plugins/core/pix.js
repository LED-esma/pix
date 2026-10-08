/* Pix canvas helpers: one call per idea, so Pix writes a few lines instead of a whole program.
   Every helper takes a container (element or CSS selector; created if missing) and returns it. */
(function () {
  const Pix = (window.Pix = {});
  const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const h = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  function host(el, boxed = true) {
    let e = typeof el === "string" ? document.querySelector(el) : el;
    if (!e) { e = h("div"); document.body.appendChild(e); }
    if (boxed && !e.classList.contains("pix-box")) e.classList.add("pix-box");
    return e;
  }
  function button(parent, label, onClick, primary) {
    const b = h("button", "pix-btn" + (primary ? " primary" : ""), label);
    b.onclick = onClick; parent.appendChild(b); return b;
  }
  function fail(e, err) { const o = h("div", "pix-out err", "Couldn't draw this: " + (err && err.message || err)); e.appendChild(o); }
  Pix.$ = (s) => document.querySelector(s);

  // ---------- Things Pix can point at while it explains ----------
  // Helpers register named parts (a graph point, "step 2", a slider, a body). Pix's app calls
  // PixFocus(name) for each step: the part reacts (reveals, pulses, animates) and its box comes back.
  const targets = [];
  Pix.target = (name, rect, focus) => { if (name) targets.push({ name: String(name).toLowerCase().trim(), rect, focus }); };
  window.PixFocus = function (query) {
    const q = String(query || "").toLowerCase().trim();
    if (!q) return null;
    const t = targets.find((t) => t.name === q) || targets.find((t) => t.name.length >= 3 && (t.name.includes(q) || q.includes(t.name)));
    let rect = null;
    if (t) {
      try { t.focus && t.focus(); } catch (_) {}
      rect = t.rect();
    } else {
      let el = null;
      try { el = document.querySelector(query); } catch (_) {}
      if (!el) {
        const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let n = walk.nextNode(); n; n = walk.nextNode()) {
          if (n.textContent.toLowerCase().includes(q) && n.parentElement && n.parentElement.closest("body") && !n.parentElement.closest("script")) { el = n.parentElement; break; }
        }
      }
      if (!el) return null;
      el.scrollIntoView({ block: "nearest", behavior: "auto" });
      rect = el.getBoundingClientRect();
    }
    return rect && rect.width + rect.height > 0 ? { x: rect.x, y: rect.y, w: rect.width, h: rect.height } : null;
  };
  const inCanvas = (cv, x, y, w = 18, h = 18) => { const r = cv.getBoundingClientRect(); return new DOMRect(r.x + x - w / 2, r.y + y - h / 2, w, h); };
  Pix.color = (i) => [css("--accent"), css("--accent-2"), css("--good"), css("--blue"), css("--pink")][i % 5];

  // ---------- Math: typeset and animated steps ----------
  Pix.math = function (el, tex, { display = true } = {}) {
    const e = host(el, false);
    try { katex.render(tex, e, { displayMode: display, throwOnError: false }); } catch (err) { e.textContent = tex; }
    return e;
  };

  /** Equation steps that appear one at a time. lines: TeX strings; notes: what changed, per line. */
  Pix.steps = function (el, lines, { notes = [], interval = 1500, autoplay = true } = {}) {
    const e = host(el);
    const rows = lines.map((tex, i) => {
      const r = h("div", "pix-step");
      r.appendChild(h("div", "n", String(i + 1)));
      const m = h("div"); r.appendChild(m);
      try { katex.render(tex, m, { displayMode: false, throwOnError: false }); } catch (_) { m.textContent = tex; }
      if (notes[i]) r.appendChild(h("div", "note", notes[i]));
      e.appendChild(r); return r;
    });
    const bar = h("div", "pix-row"); bar.style.marginTop = "8px"; e.appendChild(bar);
    let at = -1, timer = null;
    const show = (k) => {
      at = Math.max(0, Math.min(rows.length - 1, k));
      rows.forEach((r, i) => { r.classList.toggle("on", i <= at); r.classList.toggle("now", i === at); });
    };
    const play = () => { clearInterval(timer); show(0); timer = setInterval(() => { if (at >= rows.length - 1) clearInterval(timer); else show(at + 1); }, interval); };
    rows.forEach((r, i) => Pix.target("step " + (i + 1), () => r.getBoundingClientRect(), () => { clearInterval(timer); show(i); }));
    button(bar, "Back", () => { clearInterval(timer); show(at - 1); });
    button(bar, "Next", () => { clearInterval(timer); show(at + 1); }, true);
    button(bar, "Replay", play);
    autoplay ? play() : show(0);
    return e;
  };

  // ---------- Flowcharts and mind maps ----------
  let flowN = 0;
  Pix.flow = function (el, source) {
    const e = host(el);
    try {
      const dark = matchMedia("(prefers-color-scheme: dark)").matches;
      mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "neutral", securityLevel: "strict" });
      mermaid.render("pixflow" + flowN++, source).then(({ svg }) => { e.innerHTML = svg; }).catch((err) => fail(e, err));
    } catch (err) { fail(e, err); }
    return e;
  };

  // ---------- Function plots with sliders and an animated draw ----------
  // Curve labels sit at staggered x positions so crossing curves don't collide.
  function compile(expr, names) {
    let s = String(expr).replace(/^\s*[a-z]\s*(\([^)]*\))?\s*=/i, "")
      .replace(/−/g, "-").replace(/×|·/g, "*").replace(/÷/g, "/").replace(/²/g, "^2").replace(/³/g, "^3").replace(/π/g, "pi")
      .replace(/\blog\(/g, "log10(").replace(/\bln\(/g, "log(").replace(/\bpi\b/g, "PI").replace(/\be\b/g, "E")
      .replace(/(\d)\s*([a-zA-Z(])/g, "$1*$2").replace(/\)\s*([a-zA-Z0-9(])/g, ")*$1").replace(/\^/g, "**");
    return new Function(...names, "with (Math) { return (" + s + "); }");
  }
  const nice = (span, px) => { const raw = span / Math.max(px / 70, 1), m = Math.pow(10, Math.floor(Math.log10(raw))); for (const k of [1, 2, 5, 10]) if (k * m >= raw) return k * m; return 10 * m; };
  // Animations fall back to their final frame when motion is reduced or frames stall (hidden windows).
  const still = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fmt = (v) => Math.abs(v - Math.round(v)) < 1e-9 ? String(Math.round(v)) : (+v.toPrecision(3)).toString();

  /** fns: ["2x^2 - 8x + 6", "a*sin(x)"]; points: [[1, 0, "root"]]; x: [min, max]; sliders: {a: [min, max, start]} */
  Pix.plot = function (el, { fns = [], points = [], x = [-10, 10], y = null, sliders = {}, height = 340, animate = true, labels = [] } = {}) {
    const e = host(el);
    const cv = h("canvas", "pix-canvas"); cv.style.height = height + "px"; e.appendChild(cv);
    const names = Object.keys(sliders), vals = names.map((n) => sliders[n][2] ?? sliders[n][0]);
    let fs = [];
    // Later formulas can call the first two as f(…) and g(…), e.g. a secant: (f(1+h)-f(1))/h*(x-1)+f(1)
    try { fs = fns.map((f) => compile(f, ["x", ...names, "f", "g"])); } catch (err) { fail(e, err); return e; }
    let xr = [...x], yr = y ? [...y] : null, prog = animate ? 0 : 1, hover = null, drag = null, pulse = null;
    const PX = (v) => (v - xr[0]) / (xr[1] - xr[0]) * cv.clientWidth, PY = (v) => cv.clientHeight - (v - yr[0]) / (yr[1] - yr[0]) * cv.clientHeight;
    const nan = () => NaN;
    const call = (k, xv, depth) => { const f = fs[k]; if (!f || depth > 2) return NaN; try { return f(xv, ...vals, k > 0 ? (t) => call(0, t, depth + 1) : nan, k > 1 ? (t) => call(1, t, depth + 1) : nan); } catch (_) { return NaN; } };
    const ev = (f, xv) => { const v = call(fs.indexOf(f), xv, 0); return Number.isFinite(v) ? v : NaN; };
    function fitY() {
      if (y) return;
      const ys = points.map((p) => p[1]);
      fs.forEach((f) => { for (let i = 0; i <= 200; i++) { const v = ev(f, xr[0] + (xr[1] - xr[0]) * i / 200); if (!isNaN(v)) ys.push(v); } });
      if (!ys.length) { yr = [-10, 10]; return; }
      ys.sort((a, b) => a - b);
      const lo = ys[Math.floor((ys.length - 1) * .04)], hi = ys[Math.floor((ys.length - 1) * .96)], pad = Math.max((hi - lo) * .15, 1);
      yr = [Math.min(lo - pad, -pad * .3), Math.max(hi + pad, pad * .3)];
    }
    function draw() {
      const dpr = devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
      if (cv.width !== W * dpr) { cv.width = W * dpr; cv.height = H * dpr; }
      const g = cv.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
      const px = (v) => (v - xr[0]) / (xr[1] - xr[0]) * W, py = (v) => H - (v - yr[0]) / (yr[1] - yr[0]) * H;
      const sx = nice(xr[1] - xr[0], W), sy = nice(yr[1] - yr[0], H);
      g.lineWidth = 1; g.strokeStyle = css("--line"); g.beginPath();
      for (let v = Math.ceil(xr[0] / sx) * sx; v <= xr[1]; v += sx) { g.moveTo(px(v), 0); g.lineTo(px(v), H); }
      for (let v = Math.ceil(yr[0] / sy) * sy; v <= yr[1]; v += sy) { g.moveTo(0, py(v)); g.lineTo(W, py(v)); }
      g.stroke();
      const ax = Math.min(Math.max(px(0), 0), W), ay = Math.min(Math.max(py(0), 0), H);
      g.strokeStyle = css("--muted"); g.lineWidth = 1.2; g.beginPath(); g.moveTo(ax, 0); g.lineTo(ax, H); g.moveTo(0, ay); g.lineTo(W, ay); g.stroke();
      g.fillStyle = css("--muted"); g.font = "11px -apple-system, sans-serif";
      for (let v = Math.ceil(xr[0] / sx) * sx; v <= xr[1]; v += sx) if (Math.abs(v) > sx / 1e3) { const t = fmt(v), w = g.measureText(t).width; g.fillText(t, Math.min(Math.max(px(v) - w / 2, 2), W - w - 2), Math.min(Math.max(ay + 14, 12), H - 3)); }
      for (let v = Math.ceil(yr[0] / sy) * sy; v <= yr[1]; v += sy) if (Math.abs(v) > sy / 1e3) { const t = fmt(v), w = g.measureText(t).width; g.fillText(t, Math.min(Math.max(ax - w - 5, 2), W - w - 2), py(v) + 4); }
      g.lineWidth = 2.4; g.lineJoin = g.lineCap = "round";
      fs.forEach((f, k) => {
        g.strokeStyle = Pix.color(k); g.beginPath(); let on = false, last = null;
        for (let s = 0; s <= W * prog; s += 1) {
          const v = ev(f, xr[0] + s / W * (xr[1] - xr[0])), p = py(v);
          if (!isNaN(v) && on && last !== null && Math.abs(p - last) < H * 1.5) g.lineTo(s, p); else if (!isNaN(v)) { g.moveTo(s, p); on = true; } else on = false;
          last = isNaN(v) ? null : p;
        }
        g.stroke();
        if (labels[k] && prog >= 1) { g.fillStyle = Pix.color(k); g.font = "600 12px -apple-system, sans-serif"; const xs = xr[0] + (xr[1] - xr[0]) * (.86 - .22 * (k % 3)); g.fillText(labels[k], px(xs) + 6, py(ev(f, xs)) - 8); }
      });
      if (pulse) {
        const age = (performance.now() - pulse.t0) / 1000;
        if (age < 2.4) {
          g.strokeStyle = css("--pink"); g.lineWidth = 2.5; g.globalAlpha = 1 - age / 2.4;
          g.beginPath(); g.arc(px(pulse.x), py(pulse.y), 8 + 14 * (age % 0.8) / 0.8, 0, 7); g.stroke(); g.globalAlpha = 1;
          requestAnimationFrame(draw);
        } else pulse = null;
      }
      if (prog >= 1) points.forEach(([pxv, pyv, label]) => {
        g.fillStyle = css("--pink"); g.beginPath(); g.arc(px(pxv), py(pyv), 5, 0, 7); g.fill();
        g.fillStyle = css("--fg"); g.font = "500 12px -apple-system, sans-serif";
        g.fillText((label ? label + " " : "") + "(" + fmt(pxv) + ", " + fmt(pyv) + ")", px(pxv) + 8, py(pyv) - 8);
      });
      if (hover && !drag) {
        const hx = xr[0] + hover / W * (xr[1] - xr[0]);
        g.setLineDash([3, 3]); g.strokeStyle = css("--muted"); g.beginPath(); g.moveTo(hover, 0); g.lineTo(hover, H); g.stroke(); g.setLineDash([]);
        fs.forEach((f, k) => { const v = ev(f, hx); if (isNaN(v)) return; g.fillStyle = Pix.color(k); g.beginPath(); g.arc(hover, py(v), 4, 0, 7); g.fill(); const t = "(" + fmt(hx) + ", " + fmt(v) + ")"; const w = g.measureText(t).width; g.fillText(t, hover + 8 + w > W ? hover - w - 8 : hover + 8, py(v) - 6); });
      }
    }
    fitY();
    points.forEach(([a, b, label]) => {
      const focus = () => { prog = 1; pulse = { x: a, y: b, t0: performance.now() }; draw(); };
      const rect = () => inCanvas(cv, PX(a), PY(b), 26, 26);
      Pix.target(label, rect, focus); Pix.target("(" + fmt(a) + ", " + fmt(b) + ")", rect, focus);
    });
    labels.forEach((l, k) => Pix.target(l, () => { const xs = xr[0] + (xr[1] - xr[0]) * (.86 - .22 * (k % 3)); return inCanvas(cv, PX(xs) + 40, PY(ev(fs[k], xs)) - 8, 110, 22); }, () => { prog = 1; draw(); }));
    if (animate && !still()) {
      const t0 = performance.now(); const step = (t) => { prog = Math.min(1, (t - t0) / 1100); draw(); if (prog < 1) requestAnimationFrame(step); }; requestAnimationFrame(step);
      setTimeout(() => { if (prog < 1) { prog = 1; draw(); } }, 1600);
    } else { prog = 1; draw(); }
    cv.addEventListener("pointermove", (ev2) => { const r = cv.getBoundingClientRect(); if (drag) { const dx = (ev2.clientX - drag[0]) / r.width * (drag[2][1] - drag[2][0]), dy = (ev2.clientY - drag[1]) / r.height * (drag[3][1] - drag[3][0]); xr = [drag[2][0] - dx, drag[2][1] - dx]; yr = [drag[3][0] + dy, drag[3][1] + dy]; } hover = ev2.clientX - r.left; draw(); });
    cv.addEventListener("pointerleave", () => { hover = null; draw(); });
    cv.addEventListener("pointerdown", (ev2) => { drag = [ev2.clientX, ev2.clientY, [...xr], [...yr]]; cv.setPointerCapture(ev2.pointerId); });
    cv.addEventListener("pointerup", () => { drag = null; });
    cv.addEventListener("dblclick", () => { xr = [...x]; fitY(); draw(); });
    cv.addEventListener("wheel", (ev2) => { ev2.preventDefault(); const r = cv.getBoundingClientRect(), k = ev2.deltaY > 0 ? 1.12 : 1 / 1.12; const cx = xr[0] + (ev2.clientX - r.left) / r.width * (xr[1] - xr[0]), cy = yr[0] + (1 - (ev2.clientY - r.top) / r.height) * (yr[1] - yr[0]); xr = [cx - (cx - xr[0]) * k, cx + (xr[1] - cx) * k]; yr = [cy - (cy - yr[0]) * k, cy + (yr[1] - cy) * k]; draw(); }, { passive: false });
    names.forEach((n, i) => {
      const [lo, hi] = sliders[n], row = h("label", "pix-slider"), out = h("span", null, n + " = " + fmt(vals[i]));
      const input = h("input"); Object.assign(input, { type: "range", min: lo, max: hi, step: (hi - lo) / 200, value: vals[i] });
      input.oninput = () => { vals[i] = +input.value; out.textContent = n + " = " + fmt(vals[i]); draw(); };
      row.append(out, input); e.appendChild(row);
      // Focusing a slider plays it: sweeps from high to low so you watch the change happen.
      const sweep = () => { const t0 = performance.now(); prog = 1; (function go(t) { const k = Math.min(1, (t - t0) / 2600), v = hi - (hi - lo) * (1 - Math.pow(1 - k, 2)); vals[i] = v; input.value = v; out.textContent = n + " = " + fmt(v); draw(); if (k < 1) requestAnimationFrame(go); })(t0); setTimeout(() => { vals[i] = lo; input.value = lo; out.textContent = n + " = " + fmt(lo); draw(); }, 2800); };
      Pix.target("slider " + n, () => row.getBoundingClientRect(), sweep); Pix.target(n, () => row.getBoundingClientRect(), sweep);
    });
    const bar = h("div", "pix-row"); bar.style.marginTop = "6px"; e.appendChild(bar);
    if (animate) button(bar, "Replay", () => { const t0 = performance.now(); const step = (t) => { prog = Math.min(1, (t - t0) / 1100); draw(); if (prog < 1) requestAnimationFrame(step); }; requestAnimationFrame(step); });
    new ResizeObserver(draw).observe(cv);
    return e;
  };

  // ---------- Physics (Matter.js), in meters and seconds ----------
  /** bodies: [{shape: "circle"|"box", x, y, r | w, h, vx, vy, color, label, fixed, bounce}]; y is up, meters. */
  Pix.physics = function (el, { bodies = [], gravity = 9.8, width = 20, height = 10, ground = true, walls = false, trace = true, vectors = true, springs = [], seconds = 0 } = {}) {
    const e = host(el);
    const cv = h("canvas", "pix-canvas"); cv.style.aspectRatio = width + " / " + height; e.appendChild(cv);
    const info = h("div", "pix-muted"); e.appendChild(info);
    const bar = h("div", "pix-row"); bar.style.marginTop = "6px"; e.appendChild(bar);
    const M = Matter; let engine, list, trails, t, running = true, raf;
    const k = () => cv.clientWidth / width;  // px per meter
    function build() {
      engine = M.Engine.create(); engine.gravity.y = 1; engine.gravity.scale = gravity * k() / 1e6;
      const W = width * k(), H = height * k();
      const statics = [];
      if (ground) statics.push(M.Bodies.rectangle(W / 2, H + 25, W * 4, 50, { isStatic: true }));
      if (walls) statics.push(M.Bodies.rectangle(-25, H / 2, 50, H * 4, { isStatic: true }), M.Bodies.rectangle(W + 25, H / 2, 50, H * 4, { isStatic: true }));
      list = bodies.map((b, i) => {
        const o = { isStatic: !!b.fixed, restitution: b.bounce ?? 0.3, friction: 0.05, frictionAir: 0 };
        const px = b.x * k(), py = H - b.y * k();
        const body = b.shape === "box" ? M.Bodies.rectangle(px, py, (b.w || 1) * k(), (b.h || 1) * k(), o) : M.Bodies.circle(px, py, (b.r || 0.3) * k(), o);
        M.Body.setVelocity(body, { x: (b.vx || 0) * k() / 60, y: -(b.vy || 0) * k() / 60 });
        body.pix = { color: b.color || Pix.color(i), label: b.label || "" };
        return body;
      });
      const cons = springs.map((s) => M.Constraint.create({ bodyA: list[s.a], bodyB: s.b == null ? undefined : list[s.b], pointB: s.b == null ? { x: s.x * k(), y: H - s.y * k() } : undefined, length: (s.length ?? 2) * k(), stiffness: s.stiffness ?? 0.02 }));
      M.Composite.add(engine.world, [...statics, ...list, ...cons]);
      trails = list.map(() => []); t = 0;
      list.forEach((b) => b.pix.label && Pix.target(b.pix.label, () => { const bb = b.bounds; return inCanvas(cv, (bb.min.x + bb.max.x) / 2, (bb.min.y + bb.max.y) / 2, bb.max.x - bb.min.x + 16, bb.max.y - bb.min.y + 16); }));
    }
    function draw() {
      const dpr = devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
      if (cv.width !== W * dpr) { cv.width = W * dpr; cv.height = H * dpr; }
      const g = cv.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
      g.strokeStyle = css("--line"); g.lineWidth = 1; g.beginPath();
      for (let m = 0; m <= width; m++) { g.moveTo(m * k(), 0); g.lineTo(m * k(), H); }
      for (let m = 0; m <= height; m++) { g.moveTo(0, H - m * k()); g.lineTo(W, H - m * k()); }
      g.stroke();
      if (ground) { g.fillStyle = css("--muted"); g.fillRect(0, H - 2, W, 2); }
      engine.world.constraints.forEach((c) => { const a = c.bodyA ? c.bodyA.position : c.pointA, b = c.bodyB ? c.bodyB.position : c.pointB; g.strokeStyle = css("--muted"); g.setLineDash([4, 4]); g.beginPath(); g.moveTo(a.x, a.y); g.lineTo(b.x, b.y); g.stroke(); g.setLineDash([]); });
      list.forEach((b, i) => {
        if (trace) { g.fillStyle = b.pix.color; trails[i].forEach(([x, y], j) => { if (j % 3 === 0) { g.globalAlpha = .35; g.fillRect(x - 1.5, y - 1.5, 3, 3); } }); g.globalAlpha = 1; }
        g.fillStyle = b.pix.color; g.beginPath(); b.vertices.forEach((v, j) => j ? g.lineTo(v.x, v.y) : g.moveTo(v.x, v.y)); g.closePath(); g.fill();
        if (vectors && !b.isStatic) { const vx = b.velocity.x * 6, vy = b.velocity.y * 6; g.strokeStyle = css("--fg"); g.lineWidth = 1.5; g.beginPath(); g.moveTo(b.position.x, b.position.y); g.lineTo(b.position.x + vx, b.position.y + vy); g.stroke(); }
        if (b.pix.label) { g.fillStyle = css("--fg"); g.font = "500 12px -apple-system, sans-serif"; g.fillText(b.pix.label, b.position.x + 10, b.position.y - 10); }
      });
      info.textContent = "t = " + t.toFixed(2) + " s   " + list.filter((b) => !b.isStatic).map((b) => (b.pix.label || "body") + ": " + (b.speed * 60 / k()).toFixed(1) + " m/s, height " + ((cv.clientHeight - b.position.y) / k()).toFixed(1) + " m").join("   ");
    }
    function loop() {
      if (running && !(seconds && t >= seconds)) { M.Engine.update(engine, 1000 / 60); t += 1 / 60; list.forEach((b, i) => { trails[i].push([b.position.x, b.position.y]); if (trails[i].length > 600) trails[i].shift(); }); }
      draw(); raf = requestAnimationFrame(loop);
    }
    const playBtn = button(bar, "Pause", () => { running = !running; playBtn.textContent = running ? "Pause" : "Play"; });
    button(bar, "Replay", () => { cancelAnimationFrame(raf); build(); running = true; playBtn.textContent = "Pause"; loop(); }, true);
    const start = () => { build(); draw(); raf = requestAnimationFrame(loop); };
    cv.clientWidth ? start() : requestAnimationFrame(start);
    return e;
  };

  // ---------- 3D scenes (Three.js) ----------
  /** objects: [{type: "box"|"sphere"|"cylinder"|"cone"|"torus", size: [..], pos: [x,y,z], rot: [deg..], color, label}] */
  Pix.scene3d = function (el, { objects = [], spin = true, grid = true, height = 360 } = {}) {
    const e = host(el);
    const wrap = h("div"); wrap.style.position = "relative"; wrap.style.height = height + "px"; e.appendChild(wrap);
    Promise.all([import("three"), import("pix://local/plugins/3d/OrbitControls.js")]).then(([THREE, { OrbitControls }]) => {
      const W = wrap.clientWidth, H = height;
      const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true }); renderer.setPixelRatio(devicePixelRatio); renderer.setSize(W, H); wrap.appendChild(renderer.domElement);
      const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(45, W / H, 0.1, 1000); camera.position.set(6, 5, 8);
      scene.add(new THREE.HemisphereLight(0xffffff, 0x444466, 2.2)); const sun = new THREE.DirectionalLight(0xffffff, 1.6); sun.position.set(5, 10, 7); scene.add(sun);
      if (grid) { const gh = new THREE.GridHelper(20, 20, 0x8888aa, 0x8888aa); gh.material.opacity = .25; gh.material.transparent = true; scene.add(gh); }
      const group = new THREE.Group(); scene.add(group);
      objects.forEach((o, i) => {
        const s = o.size || [1, 1, 1];
        const geo = o.type === "sphere" ? new THREE.SphereGeometry(s[0] ?? 1, 48, 32) : o.type === "cylinder" ? new THREE.CylinderGeometry(s[0] ?? .5, s[0] ?? .5, s[1] ?? 1, 48)
          : o.type === "cone" ? new THREE.ConeGeometry(s[0] ?? .5, s[1] ?? 1, 48) : o.type === "torus" ? new THREE.TorusGeometry(s[0] ?? 1, s[1] ?? .3, 24, 64) : new THREE.BoxGeometry(s[0] ?? 1, s[1] ?? 1, s[2] ?? 1);
        const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: o.color || Pix.color(i), roughness: .45, metalness: .1 }));
        mesh.position.set(...(o.pos || [0, 0, 0])); if (o.rot) mesh.rotation.set(...o.rot.map((d) => d * Math.PI / 180));
        group.add(mesh);
        if (o.label) { const tag = h("div", "pix-muted", o.label); Object.assign(tag.style, { position: "absolute", pointerEvents: "none", fontWeight: 600, color: css("--fg") }); wrap.appendChild(tag); mesh.userData.tag = tag; }
      });
      const controls = new OrbitControls(camera, renderer.domElement); controls.enableDamping = true; controls.autoRotate = spin; controls.autoRotateSpeed = 1.2;
      (function tick() {
        controls.update(); renderer.render(scene, camera);
        group.children.forEach((m) => { const tag = m.userData.tag; if (!tag) return; const p = m.position.clone().project(camera); tag.style.left = ((p.x + 1) / 2 * W + 8) + "px"; tag.style.top = ((1 - p.y) / 2 * H - 8) + "px"; });
        requestAnimationFrame(tick);
      })();
    }).catch((err) => fail(e, err));
    return e;
  };

  // ---------- 3D graphs (Three.js), z up like in math class ----------
  /** fn: "sin(x)*cos(y)" (or fns: […]) over x, y ranges; curves: [{x:"cos(t)", y:"sin(t)", z:"t/5", t:[0, 20]}];
      points: [[x, y, z, "label"]]; sliders: {a: [min, max, start]} usable in any formula. Drag to rotate, scroll to zoom. */
  Pix.plot3d = function (el, { fn = null, fns = [], x = [-3, 3], y = [-3, 3], z = null, curves = [], points = [], sliders = {},
                                height = 420, animate = true, resolution = 72, spin = false } = {}) {
    const e = host(el);
    const wrap = h("div"); Object.assign(wrap.style, { position: "relative", height: height + "px" }); e.appendChild(wrap);
    const tip = h("div", "pix-muted"); Object.assign(tip.style, { position: "absolute", left: "10px", top: "8px", pointerEvents: "none", fontVariantNumeric: "tabular-nums" }); wrap.appendChild(tip);
    const names = Object.keys(sliders), vals = names.map((n) => sliders[n][2] ?? sliders[n][0]);
    let surf = [], crv = [];
    try {
      surf = (fn ? [fn] : []).concat(fns).map((f) => compile(f, ["x", "y", ...names]));
      crv = curves.map((c) => ({ ...c, fx: compile(c.x, ["t", ...names]), fy: compile(c.y, ["t", ...names]), fz: compile(c.z, ["t", ...names]) }));
    } catch (err) { fail(e, err); return e; }
    const at = (f, ...a) => { try { const v = f(...a, ...vals); return Number.isFinite(v) ? v : NaN; } catch (_) { return NaN; } };
    Promise.all([import("three"), import("pix://local/plugins/3d/OrbitControls.js")]).then(([THREE, { OrbitControls }]) => {
      const W = () => wrap.clientWidth;
      const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true }); renderer.setPixelRatio(devicePixelRatio); renderer.setSize(W(), height); wrap.appendChild(renderer.domElement);
      const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(40, W() / height, 0.1, 200);
      camera.up.set(0, 0, 1); camera.position.set(9, -9, 7);
      scene.add(new THREE.HemisphereLight(0xffffff, 0x555577, 2)); const sun = new THREE.DirectionalLight(0xffffff, 1.4); sun.position.set(4, -6, 10); scene.add(sun);
      const controls = new OrbitControls(camera, renderer.domElement); controls.enableDamping = true; controls.autoRotate = spin; controls.autoRotateSpeed = 0.8;
      const S = 6, ZS = 4, cx = (x[0] + x[1]) / 2, cy = (y[0] + y[1]) / 2;
      const sx = S / (x[1] - x[0]), sy = S / (y[1] - y[0]);
      let zr = z, sz = 1, cz = 0;
      function fitZ() {
        if (z) { zr = z; } else {
          const zs = [];
          surf.forEach((f) => { for (let i = 0; i <= 30; i++) for (let j = 0; j <= 30; j++) { const v = at(f, x[0] + (x[1] - x[0]) * i / 30, y[0] + (y[1] - y[0]) * j / 30); if (!isNaN(v)) zs.push(v); } });
          crv.forEach((c) => { for (let i = 0; i <= 200; i++) { const t = c.t[0] + (c.t[1] - c.t[0]) * i / 200, v = at(c.fz, t); if (!isNaN(v)) zs.push(v); } });
          points.forEach((p) => zs.push(p[2]));
          if (!zs.length) zs.push(-1, 1);
          zs.sort((a, b) => a - b);
          let lo = zs[Math.floor((zs.length - 1) * .02)], hi = zs[Math.floor((zs.length - 1) * .98)];
          if (hi - lo < 1e-6) { lo -= 1; hi += 1; }
          zr = [lo, hi];
        }
        sz = ZS / (zr[1] - zr[0]); cz = (zr[0] + zr[1]) / 2;
      }
      fitZ();
      const P = (a, b, c) => new THREE.Vector3((a - cx) * sx, (b - cy) * sy, (Math.min(Math.max(c, zr[0] - (zr[1] - zr[0])), zr[1] + (zr[1] - zr[0])) - cz) * sz);
      const world = new THREE.Group(); scene.add(world);
      // Box, floor grid, axis labels with the ranges.
      const box = new THREE.Box3Helper(new THREE.Box3(new THREE.Vector3(-S / 2, -S / 2, -ZS / 2), new THREE.Vector3(S / 2, S / 2, ZS / 2)), new THREE.Color(css("--muted")));
      box.material.transparent = true; box.material.opacity = .35; world.add(box);
      const grid = new THREE.GridHelper(S, 12, css("--muted"), css("--muted")); grid.rotation.x = Math.PI / 2; grid.position.z = -ZS / 2; grid.material.transparent = true; grid.material.opacity = .25; world.add(grid);
      const tags = [];
      const tag = (text, pos, strong) => { const d = h("div", "pix-muted", text); Object.assign(d.style, { position: "absolute", pointerEvents: "none", fontWeight: strong ? 700 : 500, color: strong ? css("--fg") : css("--muted"), whiteSpace: "nowrap" }); wrap.appendChild(d); tags.push([d, pos]); };
      tag("x", new THREE.Vector3(S / 2 + .5, -S / 2, -ZS / 2), true); tag("y", new THREE.Vector3(S / 2, S / 2 + .5, -ZS / 2), true); tag("z", new THREE.Vector3(-S / 2, -S / 2, ZS / 2 + .4), true);
      tag(fmt(x[0]), new THREE.Vector3(-S / 2, -S / 2 - .4, -ZS / 2)); tag(fmt(x[1]), new THREE.Vector3(S / 2, -S / 2 - .4, -ZS / 2));
      tag(fmt(y[1]), new THREE.Vector3(S / 2 + .3, S / 2, -ZS / 2));
      // Surfaces, colored by height.
      const lowC = new THREE.Color(css("--blue")), midC = new THREE.Color(css("--accent")), highC = new THREE.Color(css("--accent-2"));
      const meshes = surf.map(() => {
        const g = new THREE.PlaneGeometry(S, S, resolution, resolution);
        g.setAttribute("color", new THREE.BufferAttribute(new Float32Array(g.attributes.position.count * 3), 3));
        const m = new THREE.Mesh(g, new THREE.MeshStandardMaterial({ vertexColors: true, side: THREE.DoubleSide, roughness: .55, metalness: .05, transparent: true, opacity: .95 }));
        const wire = new THREE.Mesh(g, new THREE.MeshBasicMaterial({ wireframe: true, color: css("--fg"), transparent: true, opacity: .07 }));
        world.add(m, wire); return m;
      });
      function shape() {
        surf.forEach((f, k) => {
          const g = meshes[k].geometry, pos = g.attributes.position, col = g.attributes.color, c = new THREE.Color();
          for (let i = 0; i < pos.count; i++) {
            const gx = (i % (resolution + 1)) / resolution, gy = 1 - Math.floor(i / (resolution + 1)) / resolution;
            const xv = x[0] + (x[1] - x[0]) * gx, yv = y[0] + (y[1] - y[0]) * gy, v = at(f, xv, yv), p = P(xv, yv, isNaN(v) ? cz : v);
            pos.setXYZ(i, p.x, p.y, p.z);
            const tt = isNaN(v) ? .5 : Math.min(Math.max((v - zr[0]) / (zr[1] - zr[0]), 0), 1);
            tt < .5 ? c.lerpColors(lowC, midC, tt * 2) : c.lerpColors(midC, highC, (tt - .5) * 2);
            col.setXYZ(i, c.r, c.g, c.b);
          }
          pos.needsUpdate = col.needsUpdate = true; g.computeVertexNormals();
        });
        world.children.filter((o) => o.userData.curve).forEach((o) => world.remove(o));
        crv.forEach((c, k) => {
          const pts = []; for (let i = 0; i <= 400; i++) { const t = c.t[0] + (c.t[1] - c.t[0]) * i / 400, a = at(c.fx, t), b = at(c.fy, t), d = at(c.fz, t); if (![a, b, d].some(isNaN)) pts.push(P(a, b, d)); }
          if (pts.length < 2) return;
          const tube = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 400, .05, 8, false), new THREE.MeshStandardMaterial({ color: c.color || Pix.color(k + 1) }));
          tube.userData.curve = true; world.add(tube); tube.userData.full = tube.geometry.index.count;
        });
      }
      shape();
      points.forEach(([a, b, c, label], k) => {
        const s = new THREE.Mesh(new THREE.SphereGeometry(.09, 24, 16), new THREE.MeshStandardMaterial({ color: css("--pink") })); s.position.copy(P(a, b, c)); world.add(s);
        tag((label ? label + " " : "") + "(" + fmt(a) + ", " + fmt(b) + ", " + fmt(c) + ")", s.position.clone().add(new THREE.Vector3(.15, 0, .15)), true);
      });
      // Draw-in: surfaces rise from flat, curves trace along.
      let t0 = performance.now();
      const grow = () => Math.min(1, animate && !still() ? (performance.now() - t0) / 1400 : 1);
      // Hover: read (x, y, z) off the surface.
      const ray = new THREE.Raycaster(), mouse = new THREE.Vector2();
      renderer.domElement.addEventListener("pointermove", (ev) => {
        const r = renderer.domElement.getBoundingClientRect(); mouse.set((ev.clientX - r.left) / r.width * 2 - 1, -(ev.clientY - r.top) / r.height * 2 + 1);
        ray.setFromCamera(mouse, camera); const hit = ray.intersectObjects(meshes)[0];
        tip.textContent = hit ? "x " + fmt(hit.point.x / sx + cx) + "   y " + fmt(hit.point.y / sy + cy) + "   z " + fmt(hit.point.z / grow() / sz + cz) : "";
      });
      renderer.domElement.addEventListener("dblclick", () => { camera.position.set(9, -9, 7); controls.target.set(0, 0, 0); });
      names.forEach((n, i) => {
        const [lo, hi] = sliders[n], row = h("label", "pix-slider"), out = h("span", null, n + " = " + fmt(vals[i]));
        const input = h("input"); Object.assign(input, { type: "range", min: lo, max: hi, step: (hi - lo) / 200, value: vals[i] });
        input.oninput = () => { vals[i] = +input.value; out.textContent = n + " = " + fmt(vals[i]); shape(); };
        row.append(out, input); e.appendChild(row);
      });
      const bar = h("div", "pix-row"); bar.style.marginTop = "6px"; e.appendChild(bar);
      button(bar, "Replay", () => { t0 = performance.now(); });
      button(bar, controls.autoRotate ? "Stop spin" : "Spin", function () { controls.autoRotate = !controls.autoRotate; this.textContent = controls.autoRotate ? "Stop spin" : "Spin"; });
      setTimeout(() => { if (grow() >= 1) frame(); }, 1600);  // final frame even if animation frames stall
      function frame() {
        const g = grow(), ease = 1 - Math.pow(1 - g, 3);
        meshes.forEach((m) => { m.scale.z = ease; world.children.forEach((o) => { if (o.geometry === m.geometry && o !== m) o.scale.z = ease; }); });
        world.children.forEach((o) => { if (o.userData.curve) o.geometry.setDrawRange(0, Math.floor(o.userData.full * ease / 3) * 3); });
        controls.update(); renderer.render(scene, camera);
        tags.forEach(([d, p]) => { const v = p.clone().project(camera); d.style.left = ((v.x + 1) / 2 * W() + 4) + "px"; d.style.top = ((1 - v.y) / 2 * height - 8) + "px"; d.style.display = v.z < 1 ? "" : "none"; });
      }
      (function tick() { frame(); requestAnimationFrame(tick); })();
      new ResizeObserver(() => { renderer.setSize(W(), height); camera.aspect = W() / height; camera.updateProjectionMatrix(); }).observe(wrap);
    }).catch((err) => fail(e, err));
    return e;
  };

  // ---------- 3D physics simulations (cannon-es + Three.js), z up, meters and seconds ----------
  /** bodies: [{shape: "sphere"|"box"|"cylinder", size: [r] | [w,d,h] | [r,h], pos: [x,y,z], vel: [vx,vy,vz], mass, bounce, color, label, fixed}]
      springs: [{a, b | anchor: [x,y,z], length, stiffness, rod}] (rod = rigid, e.g. a pendulum). Point at bodies by label. */
  Pix.sim3d = function (el, { bodies = [], springs = [], gravity = 9.8, ground = true, size = 20, seconds = 0, trace = true,
                               vectors = true, height = 420, spin = false } = {}) {
    const e = host(el);
    const wrap = h("div"); Object.assign(wrap.style, { position: "relative", height: height + "px" }); e.appendChild(wrap);
    const info = h("div", "pix-muted"); info.style.fontVariantNumeric = "tabular-nums"; e.appendChild(info);
    const bar = h("div", "pix-row"); bar.style.marginTop = "6px"; e.appendChild(bar);
    Promise.all([import("three"), import("pix://local/plugins/3d/OrbitControls.js"), import("pix://local/plugins/sim3d/cannon-es.js")])
      .then(([THREE, { OrbitControls }, CANNON]) => {
        const W = () => wrap.clientWidth;
        const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true }); renderer.setPixelRatio(devicePixelRatio); renderer.setSize(W(), height); wrap.appendChild(renderer.domElement);
        const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(45, W() / height, 0.1, 500);
        camera.up.set(0, 0, 1);
        const reach = Math.max(6, ...bodies.map((b) => Math.hypot(...(b.pos || [0, 0, 0])) + 4));
        camera.position.set(reach * 1.1, -reach * 1.3, reach * 0.8);
        scene.add(new THREE.HemisphereLight(0xffffff, 0x555577, 2)); const sun = new THREE.DirectionalLight(0xffffff, 1.5); sun.position.set(5, -8, 12); scene.add(sun);
        if (ground) {
          const grid = new THREE.GridHelper(size, size, css("--muted"), css("--muted")); grid.rotation.x = Math.PI / 2; grid.material.transparent = true; grid.material.opacity = .3; scene.add(grid);
          const floor = new THREE.Mesh(new THREE.PlaneGeometry(size, size), new THREE.MeshStandardMaterial({ color: css("--muted"), transparent: true, opacity: .1 })); scene.add(floor);
        }
        const controls = new OrbitControls(camera, renderer.domElement); controls.enableDamping = true; controls.autoRotate = spin; controls.autoRotateSpeed = .8;
        controls.target.set(0, 0, 1);
        const tags = [];
        let world, items, links, t = 0, running = true, flash = null;
        function geometry(b) {
          const s = b.size || [];
          if (b.shape === "box") { const [w = 1, d = 1, hh = 1] = s; return [new CANNON.Box(new CANNON.Vec3(w / 2, d / 2, hh / 2)), new THREE.BoxGeometry(w, d, hh)]; }
          if (b.shape === "cylinder") { const [r = .4, hh = 1] = s; return [new CANNON.Cylinder(r, r, hh, 24), new THREE.CylinderGeometry(r, r, hh, 32)]; }
          const r = s[0] ?? .3; return [new CANNON.Sphere(r), new THREE.SphereGeometry(r, 32, 20)];
        }
        function build() {
          if (items) items.forEach((it) => { scene.remove(it.mesh); it.arrow && scene.remove(it.arrow); it.trail && scene.remove(it.trail); });
          if (links) links.forEach((l) => scene.remove(l.line));
          tags.forEach((tg) => tg.el.remove()); tags.length = 0;
          world = new CANNON.World({ gravity: new CANNON.Vec3(0, 0, -gravity) });
          if (ground) { const g = new CANNON.Body({ mass: 0, shape: new CANNON.Plane(), material: new CANNON.Material({ friction: .4, restitution: 1 }) }); world.addBody(g); }
          items = bodies.map((b, i) => {
            const [shape, geo] = geometry(b);
            const body = new CANNON.Body({ mass: b.fixed ? 0 : (b.mass ?? 1), shape, material: new CANNON.Material({ friction: .3, restitution: b.bounce ?? .35 }) });
            body.position.set(...(b.pos || [0, 0, 1])); body.velocity.set(...(b.vel || [0, 0, 0])); world.addBody(body);
            const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: b.color || Pix.color(i), roughness: .45, metalness: .05 })); scene.add(mesh);
            const it = { b, body, mesh, path: [] };
            if (vectors && !b.fixed) { it.arrow = new THREE.ArrowHelper(new THREE.Vector3(1, 0, 0), new THREE.Vector3(), 1, new THREE.Color(css("--fg")).getHex(), .25, .15); scene.add(it.arrow); }
            if (trace && !b.fixed) { it.trail = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: b.color || Pix.color(i), transparent: true, opacity: .55 })); scene.add(it.trail); }
            if (b.label) {
              const d = h("div", "pix-muted", b.label); Object.assign(d.style, { position: "absolute", pointerEvents: "none", fontWeight: 600, color: css("--fg") }); wrap.appendChild(d);
              tags.push({ el: d, mesh });
              Pix.target(b.label, () => { const r = d.getBoundingClientRect(); const c = renderer.domElement.getBoundingClientRect(); const p = mesh.position.clone().project(camera); const x = c.x + (p.x + 1) / 2 * c.width, y = c.y + (1 - p.y) / 2 * c.height; return new DOMRect(x - 30, y - 30, 60, 60); },
                () => { flash = { mesh, t0: performance.now() }; });
            }
            return it;
          });
          links = springs.map((sp) => {
            const A = items[sp.a]?.body; if (!A) return null;
            let B = sp.b != null ? items[sp.b]?.body : null;
            if (!B) { B = new CANNON.Body({ mass: 0 }); B.position.set(...(sp.anchor || [0, 0, 5])); world.addBody(B); }
            const len = sp.length ?? A.position.distanceTo(B.position);
            if (sp.rod) world.addConstraint(new CANNON.DistanceConstraint(A, B, len));
            else { const spring = new CANNON.Spring(A, B, { restLength: len, stiffness: sp.stiffness ?? 40, damping: .4 }); world.addEventListener("postStep", () => spring.applyForce()); }
            const line = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineDashedMaterial({ color: css("--muted"), dashSize: .2, gapSize: .12 })); scene.add(line);
            return { A, B, line };
          }).filter(Boolean);
          t = 0;
        }
        function frame(stepIt) {
          if (stepIt && running && !(seconds && t >= seconds)) { world.step(1 / 60); t += 1 / 60; }
          items.forEach((it) => {
            it.mesh.position.copy(it.body.position); it.mesh.quaternion.copy(it.body.quaternion);
            if (it.trail && stepIt && running) { it.path.push(it.mesh.position.clone()); if (it.path.length > 600) it.path.shift(); it.trail.geometry.setFromPoints(it.path); }
            if (it.arrow) { const v = new THREE.Vector3().copy(it.body.velocity), sp = v.length(); it.arrow.position.copy(it.mesh.position); if (sp > .05) { it.arrow.setDirection(v.normalize()); it.arrow.setLength(Math.min(.3 + sp * .25, 5), .25, .15); it.arrow.visible = true; } else it.arrow.visible = false; }
          });
          links.forEach((l) => { l.line.geometry.setFromPoints([new THREE.Vector3().copy(l.A.position), new THREE.Vector3().copy(l.B.position)]); l.line.computeLineDistances(); });
          if (flash) { const age = (performance.now() - flash.t0) / 1000; flash.mesh.material.emissive = new THREE.Color(css("--pink")); flash.mesh.material.emissiveIntensity = age < 2 ? .8 * (1 - age / 2) * (Math.sin(age * 12) * .5 + .5) : 0; if (age >= 2) flash = null; }
          controls.update(); renderer.render(scene, camera);
          tags.forEach(({ el: d, mesh }) => { const p = mesh.position.clone().project(camera); d.style.left = ((p.x + 1) / 2 * W() + 10) + "px"; d.style.top = ((1 - p.y) / 2 * height - 22) + "px"; d.style.display = p.z < 1 ? "" : "none"; });
          info.textContent = "t = " + t.toFixed(2) + " s   " + items.filter((it) => !it.b.fixed).map((it) => (it.b.label || "body") + ": " + it.body.velocity.length().toFixed(1) + " m/s, height " + it.body.position.z.toFixed(2) + " m").join("   ");
        }
        build(); frame(false);
        (function tick() { frame(true); requestAnimationFrame(tick); })();
        const playBtn = button(bar, "Pause", () => { running = !running; playBtn.textContent = running ? "Pause" : "Play"; });
        button(bar, "Replay", () => { build(); running = true; playBtn.textContent = "Pause"; }, true);
        button(bar, spin ? "Stop spin" : "Spin", function () { controls.autoRotate = !controls.autoRotate; this.textContent = controls.autoRotate ? "Stop spin" : "Spin"; });
        new ResizeObserver(() => { renderer.setSize(W(), height); camera.aspect = W() / height; camera.updateProjectionMatrix(); }).observe(wrap);
      }).catch((err) => fail(e, err));
    return e;
  };

  // ---------- Charts (Chart.js) ----------
  /** type: "bar"|"line"|"scatter"|"pie"|"doughnut"; series: [{name, data}]; for scatter, data is [[x, y]…] */
  Pix.chart = function (el, { type = "bar", labels = [], series = [], title = "", x = "", y = "", height = 320 } = {}) {
    const e = host(el);
    const wrap = h("div"); wrap.style.height = height + "px"; e.appendChild(wrap); const cv = h("canvas"); wrap.appendChild(cv);
    try {
      Chart.defaults.color = css("--muted"); Chart.defaults.borderColor = css("--line"); Chart.defaults.font.family = "-apple-system, sans-serif";
      const round = type === "pie" || type === "doughnut";
      new Chart(cv, {
        type, data: {
          labels, datasets: series.map((s, i) => ({
            label: s.name, data: type === "scatter" ? s.data.map(([a, b]) => ({ x: a, y: b })) : s.data,
            backgroundColor: round ? s.data.map((_, j) => Pix.color(j)) : Pix.color(i) + (type === "line" ? "33" : "cc"),
            borderColor: round ? css("--bg") : Pix.color(i), borderWidth: 2, tension: .3, fill: type === "line", pointRadius: type === "scatter" ? 4 : 2,
          })),
        },
        options: {
          maintainAspectRatio: false, animation: { duration: 900 },
          plugins: { title: { display: !!title, text: title, color: css("--fg") }, legend: { display: series.length > 1 || round } },
          scales: round ? {} : { x: { title: { display: !!x, text: x } }, y: { title: { display: !!y, text: y } } },
        },
      });
    } catch (err) { fail(e, err); }
    return e;
  };

  // ---------- Code you can run ----------
  function runner(el, code, lang, run) {
    const e = host(el);
    const ta = h("textarea", "pix-code"); ta.value = code.trim(); ta.spellcheck = false; e.appendChild(ta);
    const bar = h("div", "pix-row"); bar.style.marginTop = "8px"; e.appendChild(bar);
    const out = h("pre", "pix-out"); e.appendChild(out);
    const go = async () => { out.className = "pix-out"; out.textContent = lang === "python" && !window.__pyodide ? "Starting Python…" : ""; try { out.textContent = await run(ta.value); } catch (err) { out.className = "pix-out err"; out.textContent = String(err && err.message || err); } };
    button(bar, "Run", go, true); bar.appendChild(h("span", "pix-muted", lang === "python" ? "Python" : "JavaScript"));
    go();
    return e;
  }
  Pix.python = (el, code) => runner(el, code, "python", async (src) => {
    if (!window.__pyodide) window.__pyodide = loadPyodide({ indexURL: "pix://local/plugins/python/" });
    const py = await window.__pyodide; let buf = "";
    py.setStdout({ batched: (s) => { buf += s + "\n"; } }); py.setStderr({ batched: (s) => { buf += s + "\n"; } });
    const r = await py.runPythonAsync(src);
    return buf + (r !== undefined && r !== null ? String(r) : "");
  });
  Pix.js = (el, code) => runner(el, code, "js", async (src) => {
    let buf = ""; const log = (...a) => { buf += a.map((v) => typeof v === "object" ? JSON.stringify(v) : String(v)).join(" ") + "\n"; };
    const r = await new Function("console", "return (async () => {" + src + "\n})()")({ log, error: log, warn: log });
    return buf + (r !== undefined ? String(r) : "");
  });

  // ---------- Circuits ----------
  /** parts around one loop: [{type: "battery"|"resistor"|"led"|"lamp"|"switch"|"capacitor"|"motor", label}], current: animate flow */
  Pix.circuit = function (el, { parts = [], current = true, height = 260 } = {}) {
    const e = host(el);
    const ns = "http://www.w3.org/2000/svg", W = 560, H = height, pad = 50;
    const svg = document.createElementNS(ns, "svg"); svg.setAttribute("viewBox", `0 0 ${W} ${H}`); svg.style.width = "100%"; e.appendChild(svg);
    const el2 = (tag, attrs) => { const n = document.createElementNS(ns, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); svg.appendChild(n); return n; };
    const loop = `M${pad},${pad} H${W - pad} V${H - pad} H${pad} Z`;
    el2("path", { d: loop, fill: "none", stroke: css("--muted"), "stroke-width": 2.5 });
    const path = el2("path", { d: loop, fill: "none", stroke: "none" }), L = path.getTotalLength();
    parts.forEach((p, i) => {
      const at = path.getPointAtLength(L * (i + .5) / Math.max(parts.length, 1));
      const g = document.createElementNS(ns, "g"); g.setAttribute("transform", `translate(${at.x},${at.y})`); svg.appendChild(g);
      const add = (tag, a) => { const n = document.createElementNS(ns, tag); for (const k in a) n.setAttribute(k, a[k]); g.appendChild(n); };
      const ink = css("--fg"), acc = css("--accent");
      add("rect", { x: -28, y: -16, width: 56, height: 32, rx: 8, fill: css("--bg"), stroke: "none" });
      if (p.type === "battery") { add("line", { x1: -6, y1: -14, x2: -6, y2: 14, stroke: ink, "stroke-width": 3 }); add("line", { x1: 6, y1: -8, x2: 6, y2: 8, stroke: ink, "stroke-width": 3 }); }
      else if (p.type === "resistor") add("path", { d: "M-24,0 l6,-8 l8,16 l8,-16 l8,16 l8,-16 l6,8", fill: "none", stroke: acc, "stroke-width": 2.5 });
      else if (p.type === "led" || p.type === "lamp") { add("circle", { r: 12, fill: css("--accent-2"), opacity: .9 }); if (p.type === "lamp") add("path", { d: "M-8,-8 L8,8 M8,-8 L-8,8", stroke: ink, "stroke-width": 2 }); }
      else if (p.type === "switch") { add("circle", { cx: -14, r: 3, fill: ink }); add("circle", { cx: 14, r: 3, fill: ink }); add("line", { x1: -14, y1: 0, x2: 12, y2: -12, stroke: ink, "stroke-width": 2.5 }); }
      else if (p.type === "capacitor") { add("line", { x1: -5, y1: -12, x2: -5, y2: 12, stroke: acc, "stroke-width": 3 }); add("line", { x1: 5, y1: -12, x2: 5, y2: 12, stroke: acc, "stroke-width": 3 }); }
      else { add("circle", { r: 13, fill: "none", stroke: acc, "stroke-width": 2.5 }); add("text", { "text-anchor": "middle", y: 5, fill: acc, "font-size": 13, "font-weight": 700 }).textContent = "M"; }
      if (p.label) { const t = document.createElementNS(ns, "text"); Object.entries({ "text-anchor": "middle", y: at.y < H / 2 ? -24 : 32, fill: ink, "font-size": 13, "font-family": "-apple-system, sans-serif" }).forEach(([k, v]) => t.setAttribute(k, v)); t.textContent = p.label; g.appendChild(t); }
    });
    if (current) {
      const dots = Array.from({ length: 14 }, () => el2("circle", { r: 3.5, fill: css("--blue") }));
      let t0 = performance.now();
      (function tick(now) { dots.forEach((d, i) => { const pt = path.getPointAtLength(((now - t0) / 40 + i * L / dots.length) % L); d.setAttribute("cx", pt.x); d.setAttribute("cy", pt.y); }); requestAnimationFrame(tick); })(t0);
    }
    return e;
  };

  /** Adds a Replay button that clears the container and runs draw(container) again. */
  Pix.replay = function (el, draw) {
    const e = host(el);
    const stage = h("div"); e.appendChild(stage);
    const bar = h("div", "pix-row"); bar.style.marginTop = "8px"; e.appendChild(bar);
    const go = () => { stage.innerHTML = ""; draw(stage); };
    button(bar, "Replay", go); go();
    return e;
  };
})();
