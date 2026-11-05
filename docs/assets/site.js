// Mercury's website: the opening scene (a planet that becomes the wallpaper of a Mac), the dark
// and light tones as you scroll, the feature mock ups, the right download message for the
// visitor's device and the latest release details.
// Runs entirely in the browser: nothing is sent anywhere, no cookies are set.
(function () {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const root = document.documentElement;
  const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
  const step = (a, b, x) => clamp((x - a) / (b - a), 0, 1);
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const mix = (a, b, t) => a + (b - a) * t;

  // ── Nav: it tightens up once you scroll.
  const shell = document.querySelector(".nav-shell");
  const onScrollNav = () => shell.classList.toggle("scrolled", window.scrollY > 24);
  window.addEventListener("scroll", onScrollNav, { passive: true });
  onScrollNav();
  const menu = document.querySelector(".menu-btn");
  if (menu) menu.addEventListener("click", () => menu.setAttribute("aria-expanded", shell.classList.toggle("open")));
  document.querySelectorAll(".drawer a").forEach((a) => a.addEventListener("click", () => shell.classList.remove("open")));

  // ── Things fade up as they come into view.
  const items = document.querySelectorAll(".reveal");
  if (reduce || !("IntersectionObserver" in window)) items.forEach((el) => el.classList.add("in"));
  else {
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }), { rootMargin: "0px 0px -10% 0px" });
    items.forEach((el) => io.observe(el));
  }

  // ── On the home page the whole page fades between dark and light as sections reach the middle.
  if (document.body.classList.contains("home") && "IntersectionObserver" in window) {
    const toneIO = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) root.dataset.tone = e.target.dataset.tone;
    }), { rootMargin: "-50% 0px -50% 0px" });
    document.querySelectorAll("main > section[data-tone], footer[data-tone]").forEach((s) => toneIO.observe(s));
  }

  // ── Features: the text scrolls past and the mock up beside it changes to match.
  const feats = document.querySelectorAll(".feat");
  const mocks = document.querySelectorAll(".feat-stage .mock");
  if (feats.length && "IntersectionObserver" in window) {
    const fio = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const i = e.target.dataset.i;
      feats.forEach((f) => f.classList.toggle("on", f.dataset.i === i));
      mocks.forEach((m) => m.classList.toggle("on", m.dataset.i === i));
    }), { rootMargin: "-45% 0px -45% 0px" });
    feats.forEach((f) => fio.observe(f));
    feats[0].classList.add("on");
  }

  // ── The film waits for a click, then plays from the start with sound and normal controls.
  const film = document.querySelector(".film");
  if (film) {
    const v = film.querySelector("video");
    film.querySelector(".play").addEventListener("click", () => {
      film.classList.add("playing");
      v.controls = true; v.muted = false; v.currentTime = 0; v.play();
    });
    v.addEventListener("ended", () => { film.classList.remove("playing"); v.controls = false; v.load(); });
  }

  // ── "Meet Mercury": a deep voice line timed to the opening. The voice starts as the orbit around
  // "your Mac" begins to draw, and "Mercury" lands with the boom as the gold moon appears. Browsers only
  // allow sound after a click or key press, so if it's blocked on arrival, the first click or key press
  // near the top redraws the orbit and plays it then. Once per visit.
  const ringEl = document.querySelector(".intro .ring");
  if (ringEl && window.Audio) {
    let played = false;
    try { played = sessionStorage.getItem("meetMercury") === "1"; } catch (e) {}
    const voice = new Audio("assets/meet-mercury.mp3?v=1");
    voice.preload = "auto";
    const LEAD = 500;   // the orbit starts drawing 0.5 s in; "Mercury" is 1.38 s into the clip, the moon shows at 1.9 s
    const done = () => { played = true; try { sessionStorage.setItem("meetMercury", "1"); } catch (e) {} };
    const redraw = () => ringEl.querySelectorAll("path, .moon").forEach((el) => {
      el.style.animation = "none"; void el.getBoundingClientRect(); el.style.animation = "";
    });
    const events = ["pointerdown", "keydown"];
    const onFirst = (e) => {
      if (played || (e.target.closest && e.target.closest("a, button, input, textarea, select"))) return;
      if (window.scrollY > window.innerHeight * 0.4) return;
      events.forEach((t) => window.removeEventListener(t, onFirst, true));
      // Unlock the sound inside the click (Safari needs this), then play it in time with the redrawn orbit.
      voice.muted = true;
      voice.play().then(() => {
        voice.pause(); voice.currentTime = 0; voice.muted = false;
        redraw();
        setTimeout(() => voice.play().then(done, () => {}), LEAD);
      }, () => {});
    };
    if (!played) {
      setTimeout(() => {
        voice.play().then(done, () => events.forEach((t) => window.addEventListener(t, onFirst, true)));
      }, Math.max(0, LEAD - performance.now()));
    }
  }

  // ── The opening scene.
  const scene = document.querySelector(".scene");
  if (scene) openingScene(scene);

  function openingScene(scene) {
    const pin = scene.querySelector(".scene-pin");
    const canvas = scene.querySelector(".space");
    const intro = scene.querySelector(".intro");
    const meet = scene.querySelector(".meet");
    const laptop = scene.querySelector(".laptop");
    const ui = scene.querySelector(".screen-ui");
    const caption = scene.querySelector(".caption");
    const hint = scene.querySelector(".scroll-hint");
    const q = scene.querySelector(".live-panel .q");
    const a = scene.querySelector(".live-panel .a");
    const answer = a.dataset.type;
    let typed = -1, typer = 0;

    const gl = canvas.getContext("webgl", { antialias: false, alpha: false, premultipliedAlpha: false });
    if (!gl) { pin.classList.add("no-gl"); }
    const draw = gl ? planetRenderer(gl, canvas) : null;

    let introBottom = 0;
    const measure = () => { introBottom = intro.offsetTop + intro.offsetHeight; };
    measure();
    window.addEventListener("resize", measure);

    function chat(on) {
      if (on && typed < 0) {
        typed = 0;
        q.style.opacity = 1; q.style.transform = "none";
        if (reduce) { a.textContent = answer; return; }
        const tick = () => {
          typed = Math.min(answer.length, typed + 2);
          a.textContent = answer.slice(0, typed);
          if (typed < answer.length) typer = setTimeout(tick, 22);
        };
        typer = setTimeout(tick, 650);
      } else if (!on && typed >= 0) {
        clearTimeout(typer); typed = -1; a.textContent = "";
        q.style.opacity = 0; q.style.transform = "translateY(8px)";
      }
    }
    q.style.transition = "opacity .5s, transform .6s cubic-bezier(.22,1,.36,1)";
    q.style.opacity = 0;

    let visible = true;
    if ("IntersectionObserver" in window) new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) requestAnimationFrame(frame); }).observe(scene);

    const t0 = performance.now();
    function frame(now) {
      const W = pin.clientWidth, H = pin.clientHeight;
      const total = scene.offsetHeight - H;
      const p = clamp(-scene.getBoundingClientRect().top / total, 0, 1);
      const t = (now - t0) / 1000;

      // where the laptop's screen ends up
      const narrow = W < 700;
      const sw = narrow ? W * 0.9 : Math.min(W * 0.62, H * 0.6 * 1.6, 1120);
      const sh = sw / 1.6;
      const sx = (W - sw) / 2, sy = H * (narrow ? 0.42 : 0.47) - sh / 2;

      const b = ease(step(0.05, 0.42, p));   // the planet rises into full view
      const c = ease(step(0.46, 0.76, p));   // and becomes the screen's wallpaper
      const rect = [mix(0, sx, c), mix(0, sy, c), mix(W, sw, c), mix(H, sh, c)];

      const top0 = Math.max(H * 0.66, Math.min(introBottom + 30, H * 0.86));
      const R0 = Math.max(W * 0.8, H * 1.0);
      const R1 = Math.min(W, H) * 0.31;
      const R2 = sh * 0.36;
      let pr = Math.exp(mix(Math.log(R0), Math.log(R1), b));
      let px = W / 2, py = mix(top0, H * 0.45 - R1, b) + pr;   // the top edge rises smoothly
      pr = mix(pr, R2, c);
      px = mix(px, sx + sw * 0.36, c);
      py = mix(py, sy + sh * (narrow ? 0.42 : 0.52), c);

      // the spin is tied to scroll so the big ray crater faces you once it's on the laptop
      if (draw) draw({ W, H, rect, rad: mix(0, sw * 0.016, c), planet: [px, py, pr], spin: 0.72 + (p - 0.9) * 2.4 + (reduce ? 0 : Math.sin(t * 0.045) * 0.22), glow: c, time: reduce ? 0 : t });

      intro.style.opacity = 1 - step(0.0, 0.13, p);
      intro.style.transform = `translateY(${-step(0, 0.2, p) * 90}px)`;
      intro.style.pointerEvents = p > 0.08 ? "none" : "";
      meet.style.opacity = step(0.24, 0.31, p) * (1 - step(0.41, 0.47, p));
      meet.style.transform = `translateY(${(1 - step(0.24, 0.34, p)) * 20}px)`;
      hint.style.opacity = 1 - step(0, 0.04, p);

      const bz = mix(0, sw * 0.017, c);
      laptop.style.opacity = step(0.47, 0.56, p);
      laptop.style.left = rect[0] + "px"; laptop.style.top = rect[1] + "px";
      laptop.style.width = rect[2] + "px"; laptop.style.height = rect[3] + "px";
      laptop.style.setProperty("--bz", bz + "px");
      laptop.style.setProperty("--rad", mix(0, sw * 0.016, c) + "px");

      const k = rect[2] / 1280;
      ui.style.transform = `translate(${rect[0]}px, ${rect[1]}px) scale(${k})`;
      ui.style.opacity = step(0.74, 0.8, p);
      caption.style.opacity = step(0.8, 0.86, p);
      caption.style.top = Math.min(H - 60, sy + sh + sw * 0.07) + "px";
      caption.style.bottom = "auto";
      chat(p > 0.79);

      if (visible) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  // Draws the stars, the spinning planet and the glow of the screen with one fragment shader.
  // The planet's surface is a map of the same planet as the logo (tools/make_planet.py).
  function planetRenderer(gl, canvas) {
    const vs = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0., 1.); }";
    const fs = `
precision highp float;
uniform vec2 uRes; uniform vec4 uRect; uniform float uRad; uniform vec3 uPl;
uniform float uSpin, uGlow, uTime, uReady; uniform sampler2D uMap;
float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float stars(vec2 uv, float scale, float keep, float size){
  vec2 g = uv * scale; vec2 id = floor(g); vec2 f = fract(g) - 0.5;
  float h = hash(id); if (h < keep) return 0.;
  vec2 o = vec2(hash(id + 3.1), hash(id + 7.7)) - 0.5;
  float d = length(f - o * 0.7);
  float tw = 0.65 + 0.35 * sin(uTime * (0.6 + h * 2.4) + h * 40.);
  return smoothstep(size, 0., d) * tw * (h - keep) / (1. - keep);
}
float box(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r; }
void main(){
  vec2 px = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  float d = box(px - (uRect.xy + uRect.zw * 0.5), uRect.zw * 0.5, uRad);
  vec2 suv = (px - uRect.xy) / uRect.z;
  vec3 col = mix(vec3(0.016, 0.02, 0.045), vec3(0.004, 0.005, 0.012), clamp(suv.y * 0.8, 0., 1.));
  float s = stars(suv, 70., 0.9, 0.13) + stars(suv + 5., 160., 0.96, 0.17) * 0.7 + stars(suv + 9., 300., 0.985, 0.2) * 0.45;
  col += vec3(0.82, 0.88, 1.) * s;
  vec2 pp = (px - uPl.xy) / uPl.z; float r = length(pp);
  col += vec3(0.07, 0.11, 0.28) * exp(-max(r - 1., 0.) * 1.6) * 0.8;
  col += vec3(0.32, 0.5, 1.0) * exp(-max(r - 1., 0.) * 14.) * 0.45 * step(1., r);
  if (r < 1.0) {
    vec3 n = vec3(pp.x, -pp.y, sqrt(1. - r * r));
    float tl = 0.22; vec3 m0 = vec3(n.x, n.y * cos(tl) - n.z * sin(tl), n.y * sin(tl) + n.z * cos(tl));
    float cs = cos(uSpin), sn = sin(uSpin);
    vec3 m = vec3(cs * m0.x + sn * m0.z, m0.y, -sn * m0.x + cs * m0.z);
    float u = atan(m.x, m.z) / 6.2831853 + 0.5;
    float v = 0.5 - asin(clamp(m.y, -1., 1.)) / 3.1415927;
    vec3 a = texture2D(uMap, vec2(u, v)).rgb;
    vec3 b = texture2D(uMap, vec2(fract(u + 0.5) - 0.5, v)).rgb;
    vec3 tex = abs(u - 0.5) < 0.25 ? a : b;
    vec3 L = normalize(vec3(-0.45, 0.35, 0.82));
    float lam = max(dot(n, L), 0.);
    vec3 pc = tex * (0.16 + 1.0 * pow(lam, 0.85));
    pc *= 0.62 + 0.38 * pow(n.z, 0.55);
    pc += vec3(0.38, 0.56, 1.) * exp(-n.z * 8.) * 0.32 * (0.3 + lam);
    float edge = smoothstep(1.0, 1.0 - 1.5 / uPl.z, r);
    col = mix(col, pc, edge * uReady);
  }
  float inside = smoothstep(1., -1., d);
  vec3 room = vec3(0.10, 0.15, 0.36) * exp(-max(d, 0.) / (uRect.z * 0.14)) * 0.42 * uGlow;
  gl_FragColor = vec4(mix(room, col, inside), 1.);
}`;
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, vs));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { canvas.parentNode.classList.add("no-gl"); return null; }
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    const U = {};
    ["uRes", "uRect", "uRad", "uPl", "uSpin", "uGlow", "uTime", "uReady", "uMap"].forEach((n) => (U[n] = gl.getUniformLocation(prog, n)));

    let ready = 0, loadedAt = 0;
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([30, 50, 120]));
    const img = new Image();
    img.onload = () => {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, img);
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      const ext = gl.getExtension("EXT_texture_filter_anisotropic");
      if (ext) gl.texParameterf(gl.TEXTURE_2D, ext.TEXTURE_MAX_ANISOTROPY_EXT, 8);
      loadedAt = performance.now();
    };
    img.src = "assets/mercury-map.jpg?v=1";

    return function draw(s) {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = Math.round(s.W * dpr), h = Math.round(s.H * dpr);
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; gl.viewport(0, 0, w, h); }
      if (loadedAt) ready = reduce ? 1 : Math.min(1, (performance.now() - loadedAt) / 900);
      gl.uniform2f(U.uRes, w, h);
      gl.uniform4f(U.uRect, s.rect[0] * dpr, s.rect[1] * dpr, s.rect[2] * dpr, s.rect[3] * dpr);
      gl.uniform1f(U.uRad, s.rad * dpr);
      gl.uniform3f(U.uPl, s.planet[0] * dpr, s.planet[1] * dpr, s.planet[2] * dpr);
      gl.uniform1f(U.uSpin, s.spin);
      gl.uniform1f(U.uGlow, s.glow);
      gl.uniform1f(U.uTime, s.time);
      gl.uniform1f(U.uReady, ready);
      gl.uniform1i(U.uMap, 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };
  }

  // ── The right download message for this device.
  const ua = navigator.userAgent || "";
  const plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  let os = "other";
  if (/iPhone|iPad|iPod/.test(ua) || (/Mac/.test(plat) && navigator.maxTouchPoints > 1)) os = "ios";
  else if (/Android/.test(ua)) os = "android";
  else if (/Mac/.test(plat) || /Macintosh/.test(ua)) os = "mac";
  else if (/Win/.test(plat) || /Windows/.test(ua)) os = "windows";
  else if (/CrOS/.test(ua)) os = "chromeos";
  else if (/Linux/.test(plat) || /Linux/.test(ua)) os = "linux";
  document.querySelectorAll("[data-os]").forEach((el) => {
    const list = el.getAttribute("data-os").split(" ");
    el.hidden = !(list.includes(os) || (list.includes("not-mac") && os !== "mac"));
  });

  fetch("release.json", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : null))
    .then((rel) => {
      if (!rel) return;
      document.querySelectorAll("[data-release]").forEach((el) => {
        const key = el.getAttribute("data-release");
        if (key === "url") el.setAttribute("href", rel.url);
        else if (key === "size") el.textContent = (rel.size / 1048576).toFixed(1) + " MB";
        else if (rel[key] !== undefined) el.textContent = rel[key];
      });
      // Until a release is public, the download area shows the beta message instead.
      document.querySelectorAll("[data-available]").forEach((el) => {
        el.hidden = String(rel.available !== false) !== el.getAttribute("data-available");
      });
      document.querySelectorAll("[data-notarized]").forEach((el) => {
        el.hidden = String(rel.notarized) !== el.getAttribute("data-notarized");
      });
    })
    .catch(() => {});

  document.querySelectorAll("[data-copy]").forEach((b) => {
    b.addEventListener("click", () => {
      const t = document.querySelector(b.getAttribute("data-copy"));
      if (!t) return;
      navigator.clipboard.writeText(t.textContent.trim()).then(() => {
        const old = b.textContent;
        b.textContent = "Copied";
        setTimeout(() => (b.textContent = old), 1400);
      });
    });
  });
})();
