/* DeskCat for the web.
   A port of the Mac app's cat (CatSim.swift, CatDrawing.swift, Toy.swift, BoxView.swift), so the
   cat on the site behaves like the real one. World coordinates are CSS pixels with y up and the
   floor at 0. Everything stays inside the stage: the cat, the toy and the box.

   DeskCat.mount(stage, { name, coat, toy, muted, volume, sounds, onChange })
     -> { setName, setCoat, setToy, setMuted, setVolume, letOut, callHome, isHome, drawToyIcon } */
window.DeskCat = { mount(stage, opts = {}) {
  // =====================================================================
  //  Math
  // =====================================================================
  const lerp = (a, b, t) => a + (b - a) * t;
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
  const clamp01 = (v) => clamp(v, 0, 1);
  const rnd = (a, b) => a + Math.random() * (b - a);
  const chance = (p) => Math.random() < p;
  const smoothstep = (t) => t * t * (3 - 2 * t);
  const sgn = (v) => (v > 0 ? 1 : v < 0 ? -1 : 0);
  const sgn1 = (v) => sgn(v) || 1;
  const hypot = Math.hypot, sin = Math.sin, cos = Math.cos, PI = Math.PI;
  const fmod = (a, b) => a % b;

  /** Damped spring: `f` is how fast (Hz), `z` how bouncy (1 = no overshoot, 0.3 = wobbly). */
  class Spring {
    constructor(x, f, z) { this.x = x; this.v = 0; this.target = x; this.f = f; this.z = z; }
    step(dt) {
      const w = 2 * PI * this.f, k = w * w, c = 2 * this.z * w;
      const n = Math.max(1, Math.ceil(dt * 240)), h = dt / n;
      for (let i = 0; i < n; i++) { this.v += (k * (this.target - this.x) - c * this.v) * h; this.x += this.v * h; }
    }
    snap(x) { this.x = x; this.target = x; this.v = 0; }
  }

  // =====================================================================
  //  Rig
  // =====================================================================
  const POSES = {
    stand:  { hx: -20, hy: 27, hr: 14, cx: 16, cy: 29, cr: 15, kx: 33, ky: 50, ffx: 18, ffy: 0, fbx: -21, fby: 0 },
    sit:    { hx: -11, hy: 15, hr: 17, cx: 5,  cy: 36, cr: 14, kx: 10, ky: 63, ffx: 10, ffy: 0, fbx: 3,   fby: 0 },
    crouch: { hx: -21, hy: 23, hr: 14, cx: 15, cy: 15, cr: 14, kx: 33, ky: 22, ffx: 24, ffy: 0, fbx: -17, fby: 0 },
    lie:    { hx: -16, hy: 13, hr: 14, cx: 13, cy: 13, cr: 14, kx: 31, ky: 27, ffx: 30, ffy: 1, fbx: -6,  fby: 1 },
    bow:    { hx: -20, hy: 31, hr: 14, cx: 17, cy: 12, cr: 13, kx: 37, ky: 16, ffx: 44, ffy: 0, fbx: -22, fby: 0 },
    leap:   { hx: -22, hy: 30, hr: 14, cx: 18, cy: 33, cr: 15, kx: 35, ky: 51, ffx: 40, ffy: 13, fbx: -44, fby: 15 },
    held:   { hx: -1,  hy: -50, hr: 13, cx: 2, cy: -22, cr: 14, kx: 3,  ky: 5,  ffx: 6,  ffy: -46, fbx: 0, fby: -74 },
  };
  const KEYS = Object.keys(POSES.stand);
  const LEGS = ["nf", "ff", "nb", "fb"];
  const GAIT = { nb: 0, nf: 0.25, fb: 0.5, ff: 0.75 };

  function solveIK(a, b, l1, l2) {
    const dx = b.x - a.x, dy = b.y - a.y, d = Math.max(hypot(dx, dy), 0.001);
    if (d >= l1 + l2 - 0.01) return { x: a.x + dx * l1 / (l1 + l2), y: a.y + dy * l1 / (l1 + l2) };
    const ux = dx / d, uy = dy / d, along = (l1 * l1 - l2 * l2 + d * d) / (2 * d);
    const h = Math.sqrt(Math.max(0, l1 * l1 - along * along));
    const nx = -uy, ny = ux, s = nx > 0 ? -1 : 1;
    return { x: a.x + ux * along + nx * h * s, y: a.y + uy * along + ny * h * s };
  }

  const LABELS = {
    inBox: "In the box", leaving: "Jumping out", air: "In the air", land: "Landing", pin: "Got it!", sit: "Sitting",
    look: "Looking around", groom: "Grooming", yawn: "Yawning", stretch: "Stretching", loaf: "Loafing", sleep: "Asleep",
    wander: "Exploring", watch: "Watching your pointer", approach: "Creeping closer", stalk: "Stalking", swat: "Batting at it",
    petted: "Being petted", startle: "Startled!", goHome: "Heading home", held: "Picked up", dizzy: "Dizzy!",
    visit: "Coming to say hi", zoomies: "Zoomies!", chase: "Chasing the toy", climb: "Climbing after it", trophy: "Got the toy!",
  };

  // Toys: radius in base units, and whether they roll (round) or slide (flat).
  const TOYS = {
    shark: { radius: 21, rolls: false }, miniShark: { radius: 14, rolls: false }, mouse: { radius: 12, rolls: false },
    bird: { radius: 12, rolls: true }, plushCat: { radius: 16, rolls: true },
  };

  // On the Mac the cat waits minutes between outings. Here it gets going sooner, so you see it move.
  const WEB = { firstOut: 4, roamDelay: [12, 25], bored: [35, 75], visit: [60, 120] };

  // =====================================================================
  //  State
  // =====================================================================
  const GRAVITY = 2400, TAIL_N = 10, CLIMB_STROKE = 22;
  let scale = 1;
  const boxW = () => 120 * scale, boxRim = () => 90 * scale, tailSeg = () => 6.2 * scale;
  const playfulBase = 0.7;

  let floorY = 0, minX = 0, maxX = 1000, maxY = 1000, W = 800, H = 500, dpr = 1;
  const box = { x: 0, y: 0 };
  let boxMoved = false;
  const boxShow = new Spring(1, 4.2, 0.42);
  const roams = true;
  let catName = opts.name || "Mochi";

  // pointer
  let ptrX = 0, ptrY = 0, ptrVX = 0, ptrVY = 0, ptrSpeed = 0, ptrLastMove = -10, spin = 0, ptrHeading = null;
  let raw = { x: 0, y: 0 };

  // body
  const pos = { x: 0, y: 0 };
  let velX = 0, velY = 0, air = false, held = false;
  let gait = 0, speed = 0, breath = 0, time = 0;
  const S = (x, f, z) => new Spring(x, f, z);
  const sit = S(1, 3, 0.8), crouch = S(0, 3.2, 0.75), lie = S(0, 1.6, 0.9), bow = S(0, 2.2, 0.7), leap = S(0, 5, 0.7), hold = S(0, 4, 0.6);
  const squash = S(1, 4.5, 0.32), lean = S(0, 4, 0.6);
  const facing = S(1, 5, 0.85), headFacing = S(1, 7, 0.8), swing = S(0, 1.4, 0.12);
  const tilt = S(0, 3, 0.45), pitch = S(0, 4, 0.7), gx = S(0, 9, 0.85), gy = S(0, 9, 0.85);
  const open = S(1, 14, 1), dil = S(0.3, 4, 0.9), happy = S(0, 5, 0.9), yawn = S(0, 3, 0.8);
  const earL = S(0, 6, 0.35), earR = S(0, 6, 0.35);
  const paw = S(0, 8, 0.55), pawX = S(30, 11, 0.45), pawY = S(30, 11, 0.45), rim = S(0, 5, 0.7);
  const groom = S(0, 3, 0.8), wiggle = S(0, 4, 0.8), purr = S(0, 3, 1);
  const tailBase = S(-1.0, 2.2, 0.6), tailCurl = S(0.36, 2, 0.6), tailAmp = S(0.1, 2, 0.8), tailPuff = S(1, 5, 0.5);
  let tailFreq = 1.6;
  const dizzy = S(0, 2.5, 0.9);
  const dangle = S(0, 1.5, 0.16), stretch = S(0, 2.2, 0.25);
  const heldFX = S(0, 3.5, 0.55), heldFY = S(0, 3.5, 0.55), heldBX = S(0, 3, 0.6), heldBY = S(0, 3, 0.6);
  const curl = S(0, 2, 0.6), paddle = S(0, 3, 0.8);
  let paddlePhase = 0, paddleRate = 6;
  const climbView = S(0, 7, 0.9);
  let climbPhase = 0, climbLead = 1;
  const climbReach = S(0, 6, 0.6);
  let climbReachSide = 1;
  let heldGesture = "limp", heldNext = 0;
  let tailPhase = 0, tail = [], blinkAt = 0, blinkT = -1, sleeping = false;
  let boxClip = null;
  const SPRINGS = [sit, crouch, lie, bow, leap, hold, squash, lean, facing, headFacing, swing, tilt, pitch, gx, gy,
    open, dil, happy, yawn, earL, earR, paw, pawX, pawY, rim, groom, wiggle, purr, tailBase, tailCurl, tailAmp, tailPuff,
    dizzy, dangle, stretch, climbView, climbReach, heldFX, heldFY, heldBX, heldBY, curl, paddle];

  // brain
  const newD = (o = {}) => ({ dur: 0, next: 0, lookX: 0, lookY: 0, x: 0, tiltSign: 1, wiggle: 0, ready: false, wait: 0,
    left: 0, bored: 90, fromBox: false, landY: 0, then: "land", peek: new Spring(1, 3, 0.55), peekValue: 1, stir: 0, prep: 0, ...o });
  let act = "inBox", t = 0, d = newD();
  let interest = 0, playful = 0.7, outSince = 0, petTime = 0, lastPet = -9, noticed = false;
  let duckUntil = 0, happyUntil = 0, swat = null, hearts = [], zzz = 0, dizzyUntil = -10;

  // toy
  let toyKind = null;
  const toy = { pos: { x: 0, y: 0 }, vx: 0, vy: 0, angle: 0, spin: 0, place: "box", grab: { dx: 0, dy: 0 }, facing: 1 };
  let playEnergy = 1, lastToyPlay = -10, lastToyHit = -10, nextLeap = 0, boxLingerUntil = -10, homePending = false;
  let visitAt = 0, visitPending = false;
  const toyRadius = () => (toyKind ? TOYS[toyKind].radius : 12) * scale;
  const toyInBox = () => toyKind != null && toy.place === "box";
  const boxNeeded = () => toyInBox() || (toyKind != null && toy.place === "held") || time < boxLingerUntil;
  const toySpeed = () => hypot(toy.vx, toy.vy);
  const toyResting = () => toy.place === "free" && toySpeed() < 15 && toy.pos.y - toyRadius() - floorY < 2;
  const toyExciting = () => toyKind != null && ((toy.place === "held" && ptrSpeed > 40) || (toy.place === "free" && toySpeed() > 60));
  const isHome = () => act === "inBox" || act === "leaving";
  const committed = () => swat != null || ["leaving", "air", "held", "startle", "land", "pin", "dizzy", "climb"].includes(act);

  // =====================================================================
  //  Sound: the Mac app's recordings (CatSounds.swift, CatAudio.swift) through Web Audio.
  //  Browsers only allow sound after you click or tap the page, so it starts then.
  // =====================================================================
  const SOUNDS = {   // file prefix, number of takes, mix offset (dB), pitch drift, vocal
    meow: ["meow", 3, 0, 0.035, true], chirp: ["chirp", 1, 0, 0.035, true], wake: ["wake", 1, -1, 0.035, true],
    boxIn: ["box-in", 4, -3, 0.07], boxOut: ["box-out", 3, -3, 0.07], land: ["land", 1, -3, 0.07], claw: ["claw", 5, -5, 0.07],
    squeak: ["squeak", 1, -2, 0.07], plush: ["plush", 4, -2, 0.07], bell: ["bell", 1, -3, 0.02], toyLand: ["land", 1, -6, 0.07],
  };
  const TOY_SOUND = { mouse: "squeak", miniShark: "squeak", shark: "plush", plushCat: "plush", bird: "bell" };
  const soundBase = opts.sounds || "sounds/";
  const audio = { ctx: null, master: null, buffers: {}, purr: null, purrGain: null, purrMuffle: null, purrLevel: 0,
                  lastTake: {}, duckUntil: 0, muted: !!opts.muted, volume: opts.volume ?? 0.4, loading: null };
  const applyVolume = () => { if (audio.master) audio.master.gain.value = audio.muted ? 0 : audio.volume; };
  let lastVocal = -10, lastSfx = {}, delayed = [];
  function audioStart() {
    if (audio.muted) return;
    if (!audio.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      audio.ctx = new AC();
      audio.master = audio.ctx.createGain(); audio.master.connect(audio.ctx.destination); applyVolume();
    }
    if (audio.ctx.state === "suspended") audio.ctx.resume();
    if (!audio.loading) {
      const load = (name) => fetch(soundBase + name + ".wav").then((r) => r.arrayBuffer())
        .then((b) => new Promise((ok, no) => audio.ctx.decodeAudioData(b, ok, no))).catch(() => null);
      const files = new Set(Object.values(SOUNDS).flatMap(([pre, n]) => Array.from({ length: n }, (_, i) => `${pre}-${i + 1}`)));
      audio.loading = Promise.all([...files, "purr-1"].map((f) => load(f).then((b) => { if (b) audio.buffers[f] = b; })));
    }
  }
  for (const ev of ["pointerdown", "keydown", "touchend"]) window.addEventListener(ev, audioStart, { passive: true });
  function soundPan() { return clamp((pos.x - W / 2) / (W / 2), -1, 1) * 0.85; }
  function chain(muffled, pan, gain) {   // gain → (low-pass if muffled) → pan → master
    const c = audio.ctx, g = c.createGain(); g.gain.value = gain;
    let node = g;
    if (muffled) { const f = c.createBiquadFilter(); f.type = "lowpass"; f.frequency.value = 1800; node.connect(f); node = f; }
    if (c.createStereoPanner) { const p = c.createStereoPanner(); p.pan.value = pan; node.connect(p); node = p; }
    node.connect(audio.master);
    return g;
  }
  function playSound(ev) {
    if (audio.muted || !audio.ctx || audio.ctx.state !== "running") return;
    const [pre, n, gainDB, drift, vocal] = SOUNDS[ev.sound];
    let i = Math.floor(Math.random() * n);
    if (n > 1 && i === audio.lastTake[ev.sound]) i = (i + 1) % n;
    audio.lastTake[ev.sound] = i;
    const buf = audio.buffers[`${pre}-${i + 1}`];
    if (!buf) return;
    // mix offset, ±1 dB of randomness, softer for gentler impacts, quieter through the box
    let db = gainDB + rnd(-1, 1) + 20 * Math.log10(0.35 + 0.65 * clamp01(ev.level ?? 1));
    if (ev.muffled) db -= 4;
    const src = audio.ctx.createBufferSource();
    src.buffer = buf; src.playbackRate.value = 1 + rnd(-drift, drift);
    src.connect(chain(ev.muffled, soundPan(), Math.pow(10, db / 20)));   // the volume is applied on the master gain
    src.start();
    if (vocal) audio.duckUntil = audio.ctx.currentTime + buf.duration;
  }
  /** Down in the box, below the rim: the voice comes through the cardboard. */
  const muffledNow = () => isHome() && boxClip != null && d.peek.x < 0.8;
  /** The cat's voice, with probability `p`, kept a few seconds apart so it isn't chatty. */
  function say(sound, p = 1) {
    if (!chance(p) || time - lastVocal <= 3) return;
    lastVocal = time;
    playSound({ sound, muffled: muffledNow() });
  }
  /** Box, floor and toy sounds: not rationed like the voice, just not doubled up. */
  function sfx(sound, level = 1, delay = 0) {
    if (delay > 0) { delayed.push([time + delay, sound, level]); return; }
    if (time - (lastSfx[sound] ?? -1) <= 0.12) return;
    lastSfx[sound] = time;
    playSound({ sound, level: clamp01(level) });
  }
  function toySound() { if (toyKind) sfx(TOY_SOUND[toyKind]); }
  /** Every frame: the purr follows how hard the cat is purring, and dips under its voice. */
  function updateAudio() {
    for (const [at, sound, level] of delayed) if (at <= time) sfx(sound, level);
    delayed = delayed.filter(([at]) => at > time);
    if (!audio.ctx || audio.ctx.state !== "running") return;
    const muffled = isHome() && boxClip != null;
    let want = audio.muted ? 0 : clamp01(purr.x) * (purr.target > 0.8 ? 0.8 : 0.5);
    if (audio.ctx.currentTime < audio.duckUntil) want *= 0.5;
    if (muffled) want *= 0.65;
    audio.purrLevel += (want - audio.purrLevel) * 0.08;
    if (want > 0.01 && !audio.purr && audio.buffers["purr-1"]) {
      const c = audio.ctx;
      audio.purr = c.createBufferSource(); audio.purr.buffer = audio.buffers["purr-1"]; audio.purr.loop = true;
      audio.purrGain = c.createGain(); audio.purrGain.gain.value = 0;
      audio.purrMuffle = c.createBiquadFilter(); audio.purrMuffle.type = "lowpass";
      audio.purr.connect(audio.purrGain).connect(audio.purrMuffle).connect(audio.master);
      audio.purr.start();
    }
    if (audio.purr) {
      audio.purrGain.gain.value = audio.purrLevel;
      audio.purrMuffle.frequency.value = muffled ? 1800 : 20000;
      if (audio.purrLevel < 0.002 && want < 0.001) { audio.purr.stop(); audio.purr = null; }
    }
  }

  // =====================================================================
  //  Skeleton
  // =====================================================================
  function skeleton() {
    const ws = [["sit", sit], ["crouch", crouch], ["lie", lie], ["bow", bow], ["leap", leap], ["held", hold]];
    const p = { ...POSES.stand };
    for (const [name, s] of ws) { const w = clamp01(s.x); for (const k of KEYS) p[k] = lerp(p[k], POSES[name][k], w); }
    // held by the scruff: the lower body swings and stretches behind it
    const hw = clamp01(hold.x);
    if (hw > 0.001) {
      const fs = facing.x >= 0 ? 1 : -1, sway = dangle.x / scale * fs * hw, drop = stretch.x * hw;
      p.cx += sway * 0.3; p.cy -= drop * 0.3; p.hx += sway; p.hy -= drop;
      p.ffx += sway * 0.55; p.ffy -= drop * 0.4;
      p.fbx += sway * 1.35 + sin(time * 2.1) * 1.5 * hw; p.fby -= drop * 1.3;
      const c = curl.x * hw;
      p.hx += c * 10; p.hy += c * 12; p.cx += c * 3; p.ky -= c * 3;
    }
    // breathing, butt wiggle
    const br = sin(breath);
    p.cr *= 1 + 0.03 * br; p.cy += 0.6 * br; p.ky += 0.5 * br;
    p.hx += sin(time * 15) * 2.4 * wiggle.x;
    // walk: body bob + planted feet
    const moving = clamp01(speed / 90) * (1 - clamp01(sit.x)) * (1 - clamp01(lie.x)) * (1 - clamp01(leap.x)) * (1 - clamp01(hold.x));
    const stride = 14 + 10 * clamp01(speed / 260);
    const bob = moving * 1.6 * cos(gait * PI * 4);
    p.hy += bob; p.cy += bob; p.ky += bob * 0.6;
    const feet = {};
    for (const leg of LEGS) {
      const front = leg[1] === "f", near = leg[0] === "n";
      let x = (front ? p.ffx : p.fbx) + (near ? 3 : -3), y = front ? p.ffy : p.fby;
      if (moving > 0) {
        const ph = fmod(gait + GAIT[leg], 1);
        let dx, lift = 0;
        if (ph < 0.6) dx = lerp(stride / 2, -stride / 2, ph / 0.6);
        else { const u = (ph - 0.6) / 0.4; dx = lerp(-stride / 2, stride / 2, smoothstep(u)); lift = sin(PI * u) * 6; }
        x += dx * moving; y += lift * moving;
      }
      feet[leg] = { x, y };
    }
    if (hw > 0.001) {   // living paws while held; near and far legs paddle out of step
      for (const leg of LEGS) {
        const front = leg[1] === "f", near = leg[0] === "n", f = feet[leg];
        const ph = paddlePhase + (near ? 0 : PI) + (front ? 0 : PI / 2);
        const amp = paddle.x * (front ? 7 : 5), spread = near ? 1 : -1;
        if (front) {
          f.x += (heldFX.x + spread * 2 + amp * sin(ph)) * hw;
          f.y += (heldFY.x + spread * 3 * clamp01(heldFY.x / 20) + amp * cos(ph)) * hw;
        } else {
          f.x += (heldBX.x + amp * sin(ph)) * hw;
          f.y += (heldBY.x + amp * cos(ph)) * hw;
        }
      }
    }
    const shoulder = { x: p.cx + 2, y: p.cy - p.cr * 0.45 }, hipJoint = { x: p.hx + 2, y: p.hy - p.hr * 0.35 };
    // paws hooked over the box rim
    const rimY = boxClip != null ? (boxClip - pos.y) / scale : 0, r = clamp01(rim.x);
    if (r > 0) {
      feet.nf = { x: lerp(feet.nf.x, p.cx + 14, r), y: lerp(feet.nf.y, rimY + 2, r) };
      feet.ff = { x: lerp(feet.ff.x, p.cx - 8, r), y: lerp(feet.ff.y, rimY + 2, r) };
    }
    // grooming / swatting paw
    const g = clamp01(groom.x), pw = clamp01(paw.x);
    if (g > 0) feet.nf = { x: lerp(feet.nf.x, p.kx + 4, g), y: lerp(feet.nf.y, p.ky - 14, g) };
    if (pw > 0) feet.nf = { x: lerp(feet.nf.x, pawX.x, pw), y: lerp(feet.nf.y, pawY.x, pw) };
    const legs = {};
    for (const leg of LEGS) {
      const front = leg[1] === "f", a = front ? shoulder : hipJoint;
      const l1 = front ? 13 : 14, l2 = front ? 14 : 15;
      let f = feet[leg];
      const dist = hypot(f.x - a.x, f.y - a.y), mx = l1 + l2;
      if (dist > mx) f = { x: a.x + (f.x - a.x) * mx / dist, y: a.y + (f.y - a.y) * mx / dist };
      legs[leg] = { a, k: solveIK(a, f, l1, l2), f };
    }
    return { p, legs, shoulder };
  }

  /** Facing spring -> x scale. Passes quickly through a narrow minimum instead of going paper-thin. */
  const turnScale = (f, m) => (f >= 0 ? 1 : -1) * (m + (1 - m) * Math.min(1, Math.abs(f)));
  /** Cat-local point -> world (applies facing, squash and lean around the root). */
  function toWorld(lx, ly) {
    const sy = squash.x, sx = 1 + (1 - sy) * 0.7, f = turnScale(facing.x, 0.35);
    const x = lx * f * sx * scale, y = ly * sy * scale;
    const a = lean.x + swing.x, c = cos(a), s = sin(a);
    const shake = purr.x * sin(time * 90) * 0.35;
    return { x: pos.x + x * c - y * s + shake, y: pos.y + x * s + y * c };
  }
  const toLocal = (wx, wy) => ({ x: (wx - pos.x) / (turnScale(facing.x, 0.35) * scale), y: (wy - pos.y) / scale });
  function headWorld() { const s = skeleton(); return toWorld(s.p.kx, s.p.ky); }

  // =====================================================================
  //  Tail: a chain that chases a mood-driven shape, so it lags and settles on its own
  // =====================================================================
  const climbSqueeze = () => smoothstep(clamp01(climbPhase / 0.35)) - smoothstep(clamp01((climbPhase - 0.35) / 0.25));
  const climbHipY = () => -48 + 6 * climbSqueeze();
  function tailRoot(sk) {
    // Starts well inside the hips, so the body covers the root and only the slim tail shows where
    // it leaves. Sitting, it comes out low at the back, near the floor, like a real cat's.
    const deep = clamp01(hold.x), seated = clamp01(sit.x) * (1 - deep);
    const side = toWorld(sk.p.hx - sk.p.hr * lerp(0.45, 0.35, deep),
                         sk.p.hy + sk.p.hr * (lerp(0.1, -0.15, deep) - 0.5 * seated));
    const front = { x: pos.x, y: pos.y + (climbHipY() - 8) * scale };
    const k = smoothstep(clamp01(climbView.x));
    return { x: lerp(side.x, front.x, k), y: lerp(side.y, front.y, k) };
  }
  function initTail() {
    const r = tailRoot(skeleton()), f = sgn1(facing.x);
    tail = Array.from({ length: TAIL_N }, (_, i) => ({ x: r.x - i * tailSeg() * f, y: r.y + i * 2 }));
  }
  function stepTail(dt, sk) {
    if (tail.length !== TAIL_N) initTail();
    const root = tailRoot(sk);
    tailPhase += dt * tailFreq * PI * 2;
    const f = sgn1(facing.x), seg = tailSeg();
    let ang = tailBase.x, x = root.x, y = root.y;
    tail[0] = root;
    for (let i = 1; i < TAIL_N; i++) {
      const u = i / TAIL_N;
      ang += tailCurl.x * u + tailAmp.x * u * sin(tailPhase - i * 0.55) * 1.4;
      const tx = x - cos(ang) * f * seg, ty = y + sin(ang) * seg;
      const p = tail[i], k = 1 - Math.exp(-dt * lerp(26, 9, u));
      p.x += (tx - p.x) * k; p.y += (ty - p.y) * k;
      const prev = tail[i - 1], ddx = p.x - prev.x, ddy = p.y - prev.y, dd = Math.max(hypot(ddx, ddy), 1);
      p.x = prev.x + ddx / dd * seg; p.y = prev.y + ddy / dd * seg;
      if (boxClip == null && !held) p.y = Math.max(p.y, floorY + 3.5 * scale);   // rests on the floor
      x = p.x; y = p.y;
    }
  }

  // =====================================================================
  //  Frame
  // =====================================================================
  function step(dt) {
    time += dt;
    trackPointer(dt);
    think(dt);
    speed = air ? 0 : Math.abs(velX);
    gait += speed * dt * 0.6 / (14 + 10 * clamp01(speed / 260));
    breath += dt * (sleeping ? 1.6 : 2.6);
    if (blinkT >= 0) { blinkT += dt; if (blinkT > 0.16) blinkT = -1; }
    for (const s of SPRINGS) s.step(dt);
    boxShow.step(dt);
    if (!isHome() && !held) pos.x = clamp(pos.x, minX, maxX);
    stepTail(dt, skeleton());
    stepToy(dt);
    for (const h of hearts) { h.age += dt; h.y += 22 * dt; h.x += sin(h.age * 6 + h.y) * 0.25; }
    hearts = hearts.filter((h) => h.age < 1.4);
  }

  function trackPointer(dt) {
    const dx = raw.x - ptrX, dy = raw.y - ptrY;
    if (Math.abs(dx) + Math.abs(dy) > 0.5) ptrLastMove = time;
    if (dt > 0) { const k = Math.min(1, dt * 14); ptrVX += (dx / dt - ptrVX) * k; ptrVY += (dy / dt - ptrVY) * k; }
    ptrX = raw.x; ptrY = raw.y; ptrSpeed = hypot(ptrVX, ptrVY);
    // Add up how far the pointer turns while it moves fast: several quick circles make it dizzy.
    if (ptrSpeed > 600) {
      const h = Math.atan2(ptrVY, ptrVX);
      if (ptrHeading != null) { let dh = h - ptrHeading; if (dh > PI) dh -= 2 * PI; else if (dh < -PI) dh += 2 * PI; spin += dh; }
      ptrHeading = h;
    } else ptrHeading = null;
    spin -= spin * Math.min(1, dt * 0.35);
  }

  // ---- helpers ----
  function go(a, data = newD()) { act = a; t = 0; d = data; if (a !== "inBox") sleeping = a === "sleep"; }
  function pose(name) {
    sit.target = name === "sit" ? 1 : 0; crouch.target = name === "crouch" ? 1 : 0; lie.target = name === "lie" ? 1 : 0;
    bow.target = name === "bow" ? 1 : 0; leap.target = name === "leap" ? 1 : 0; hold.target = 0;
  }
  function faceTo(x, m = 6) { const dx = x - pos.x; if (Math.abs(dx) > m) facing.target = sgn(dx); }
  function lookAt(wx, wy) {
    const h = headWorld(), dx = wx - h.x, dy = wy - h.y, dist = Math.max(hypot(dx, dy), 1), r = Math.min(1, dist / 110);
    gx.target = dx / dist * r; gy.target = dy / dist * r;
    pitch.target = clamp(Math.atan2(dy, Math.abs(dx)) * 0.35, -0.3, 0.45);
    if (Math.abs(dx) > 12) headFacing.target = sgn(dx);
  }
  function lookForward() { gx.target = 0.25 * sgn(facing.target); gy.target = -0.05; pitch.target = 0; headFacing.target = sgn(facing.target); }
  // Tail shape per mood: [base angle, curl, sway, sway speed, puff].
  const MOODS = {
    relaxed: [-1.0, 0.36, 0.1, 1.2, 1], walk: [0.15, 0.3, 0.12, 2.2, 1], happy: [1.2, 0.14, 0.08, 1.6, 1],
    hunt: [-0.3, 0.05, 0.07, 7, 1], alert: [-0.15, 0.3, 0.05, 3, 1], scared: [1.0, 0.25, 0.04, 2, 1.9],
    sleep: [-1.35, -0.42, 0, 1, 1], box: [-0.6, 0.35, 0.1, 1.4, 1],
  };
  function mood(m) { const v = MOODS[m]; tailBase.target = v[0]; tailCurl.target = v[1]; tailAmp.target = v[2]; tailFreq = v[3]; tailPuff.target = v[4]; }
  function moveToward(x, maxSpeed, dt, stopAt = 4) {
    const dx = x - pos.x, want = clamp(dx * 3, -maxSpeed, maxSpeed) * (Math.abs(dx) < stopAt ? 0 : 1);
    const accel = 700 * dt;
    velX += clamp(want - velX, -accel, accel);
    pos.x += velX * dt;
    if (Math.abs(velX) > 8) facing.target = sgn(velX);
    return Math.abs(dx) < stopAt + 1 && Math.abs(velX) < 15;
  }
  function brake(dt) { const a = 900 * dt; velX -= clamp(velX, -a, a); pos.x += velX * dt; }
  /** Ballistic jump to (tx, ty) peaking `apex` above the higher end. */
  function launch(tx, ty, apex, then) {
    const top = Math.max(pos.y, ty) + apex;
    const up = Math.sqrt(2 * GRAVITY * (top - pos.y)), tUp = up / GRAVITY, tDown = Math.sqrt(2 * (top - ty) / GRAVITY);
    velX = (tx - pos.x) / (tUp + tDown); velY = up; air = true;
    squash.v += 6; squash.x = 1.18;
    if (Math.abs(tx - pos.x) > 4) facing.target = sgn(tx - pos.x);
    go("air", newD({ landY: ty, then }));
  }
  function emitHeart() {
    const h = headWorld();
    hearts.push({ x: h.x + rnd(-12, 12) * scale, y: h.y + 26 * scale, age: 0 });
    if (hearts.length > 8) hearts.shift();
  }
  function blinkMaybe() { if (time > blinkAt) { blinkT = 0; blinkAt = time + rnd(2.2, 6) * (chance(0.2) ? 0.15 : 1); } }
  function earTwitch() { if (chance(0.5)) earL.v += rnd(10, 16); else earR.v += rnd(10, 16); }
  function startSwat(target, jumps = 1) { swat = { t: 0, target: { x: target.x, y: target.y }, jumps }; }
  function updateSwat(dt) {
    if (!swat) return;
    swat.t += dt;
    const sh = skeleton().shoulder;
    if (swat.t < 0.14) { paw.target = 1; pawX.target = sh.x + 8; pawY.target = sh.y + 24; earL.target = earR.target = -0.15; }
    else if (swat.t < 0.32) {
      const l = toLocal(swat.target.x, swat.target.y);
      const ang = clamp(Math.atan2(l.y - sh.y, Math.max(4, l.x - sh.x)), -0.6, air ? 1.2 : 0.9);
      pawX.target = sh.x + cos(ang) * 30; pawY.target = sh.y + sin(ang) * 30;
    } else { paw.target = 0; earL.target = earR.target = 0; }
    if (swat.t > 0.55) swat = null;
  }

  // ---- perception and decisions ----
  function perceive(dt) {
    const h = headWorld(), dH = hypot(ptrX - h.x, ptrY - h.y);
    const idle = time - ptrLastMove, moving = idle < 0.25, near = dH < 260;
    if (near && moving && ptrSpeed > 25 && ptrSpeed < 2400) interest = Math.min(1, interest + dt * (1.4 - dH / 260));
    else interest = Math.max(0, interest - dt * 0.3);
    const petting = dH < 30 * scale && ptrSpeed > 12 && ptrSpeed < 650 && !air && !held && toy.place !== "held";
    petTime = petting ? petTime + dt : Math.max(0, petTime - dt * 2);
    if (petting) lastPet = time;
    if (!moving || !near) noticed = false;
    const startle = dH < 150 && ptrSpeed > 2600 && !(toyKind != null && toy.place === "held");   // waving a toy isn't scary
    return { head: h, dH, idle, moving, near, startle };
  }
  function pick(opts) {
    const total = opts.reduce((s, o) => s + Math.max(0, o[1]), 0);
    let r = Math.random() * Math.max(total, 0.0001);
    for (const [a, w] of opts) { r -= Math.max(0, w); if (r <= 0) return a; }
    return opts[0][0];
  }
  function decideOut(per) {
    if (time < dizzyUntil) return "dizzy";
    if (homePending) { homePending = false; return "goHome"; }
    if (visitPending) return "visit";
    if (toyKind != null && toy.place === "carried") return playEnergy < 0.35 ? "goHome" : "trophy";
    if (toyKind != null && (toy.place === "free" || toy.place === "held")) {
      const playing = time - lastToyPlay < 3 && playEnergy > 0.15;
      if (toyExciting() || toy.place === "held" || playing) return "chase";
      if (toyResting() && playEnergy > 0.4 && chance(0.2)) return "chase";
    }
    const lowPtr = ptrY - floorY < 110;
    if (interest > 0.35 && per.near) {
      if (per.dH < 78 * scale) return pick([["swat", 45], ["watch", 35], ["groom", 8 * (1 - playful)], ["sit", 10]]);
      if (lowPtr && Math.abs(ptrX - pos.x) < 420) return pick([["stalk", 40 * playful], ["watch", 35], ["approach", 15], ["sit", 10]]);
      return pick([["watch", 55], ["approach", Math.abs(ptrX - pos.x) > 140 ? 25 : 0], ["look", 12]]);
    }
    if (time - outSince > d.bored || (per.idle > 40 && chance(0.4))) return per.idle > 40 && chance(0.4) ? "loaf" : "goHome";
    return pick([["sit", 22], ["look", 18], ["wander", 26], ["groom", 12], ["yawn", 7], ["stretch", 7],
                 ["loaf", per.idle > 15 ? 18 : 10], ["zoomies", 4 * playful]]);
  }
  function enter(a) {
    const n = newD({ bored: d.bored });
    switch (a) {
      case "sit": n.dur = rnd(2, 5); break;
      case "look": n.dur = rnd(2.5, 5); n.next = 0; break;
      case "groom": n.dur = rnd(2.5, 4.5); break;
      case "yawn": n.dur = 1.9; break;
      case "stretch": n.dur = 1.8; break;
      case "loaf": n.dur = rnd(6, 12); n.ready = chance(0.3); break;   // ready: drifts off into a nap
      case "wander": n.x = clamp(pos.x + rnd(150, 420) * (chance(0.5) ? 1 : -1), minX, maxX); break;
      case "watch": n.dur = rnd(1.4, 3.2); n.tiltSign = chance(0.5) ? 1 : -1; break;
      case "approach": n.dur = 4; break;
      case "stalk": n.dur = 7; break;
      case "visit": n.dur = rnd(4, 8); n.tiltSign = chance(0.5) ? 1 : -1; visitPending = false; visitAt = time + rnd(...WEB.visit); break;
      case "chase": n.dur = rnd(20, 35); break;
      case "climb": n.dur = rnd(10, 14); n.x = 0; n.landY = 0; climbPhase = 0; sfx("claw"); break;   // grabs on
      case "trophy": { const side = chance(0.5) ? 1 : -1; n.x = clamp(pos.x + side * rnd(150, 350) * scale, minX, maxX); n.dur = rnd(1.2, 2.2); break; }
      case "zoomies": {
        let side = chance(0.5) ? 1 : -1;
        if ((side > 0 ? maxX - pos.x : pos.x - minX) < 250) side = -side;
        n.x = clamp(pos.x + side * rnd(300, 600), minX, maxX); n.left = chance(0.5) ? 1 : 0; break;
      }
      case "swat": { faceTo(ptrX); const jumps = chance(0.35) ? 2 : 1; startSwat({ x: ptrX, y: ptrY }, jumps); n.left = jumps - 1; break; }
    }
    go(a, n);
  }
  /** Expressions relax back to neutral every frame unless the current activity holds them. */
  function relax(per) {
    yawn.target = 0; groom.target = 0; wiggle.target = 0; purr.target = 0;
    happy.target = time < happyUntil ? 1 : 0;
    tilt.target = 0; earL.target = 0; earR.target = 0; rim.target = 0;
    dizzy.target = time < dizzyUntil ? 1 : 0;
    dangle.target = 0; stretch.target = 0; climbView.target = 0; climbReach.target = 0;
    heldFX.target = heldFY.target = heldBX.target = heldBY.target = 0; curl.target = 0; paddle.target = 0;
    if (!swat) paw.target = 0;
    open.target = sleeping ? 0 : 1;
    dil.target = 0.25 + 0.4 * clamp01((220 - per.dH) / 200) * (per.near ? 1 : 0);
  }

  // ---- the per-frame brain ----
  const IDLE_ACTS = ["sit", "look", "wander", "groom", "loaf", "yawn", "stretch"];
  function think(dt) {
    const per = perceive(dt), a = act;
    t += dt;
    relax(per);
    if (opts.debugPose) {   // frozen in one pose, for checking the drawing
      const P = { sit: ["sit", "relaxed"], stand: ["stand", "relaxed"], loaf: ["lie", "relaxed"], sleep: ["lie", "sleep"], walk: ["stand", "walk"] }[opts.debugPose];
      pose(P[0]); mood(P[1]); sleeping = opts.debugPose === "sleep"; open.target = sleeping ? 0 : 1; brake(dt);
      return;
    }
    playful += (playfulBase - playful) * Math.min(1, dt * 0.03);
    blinkMaybe();
    if (!sleeping && fmod(time, 7) < dt && chance(0.5)) earTwitch();

    // spun round in fast circles: dizzy, wherever it is
    if (Math.abs(spin) > 25 && per.dH < 520 * scale && !sleeping && time > dizzyUntil + 2) {
      spin = 0; dizzyUntil = time + rnd(3.5, 5);
      say("chirp", 0.6);   // "mrr?"
      if (!isHome() && !committed()) { swat = null; paw.target = 0; wiggle.target = 0; enter("dizzy"); return; }
    }
    // interrupts
    if (!isHome() && !committed() && a !== "sleep") {
      if (per.startle) { startle(); return; }
      if (petTime > 0.25 && a !== "petted") { say("chirp", 0.6); go("petted", newD({ bored: d.bored })); }
      else if (per.near && per.moving && !noticed && IDLE_ACTS.includes(a)) {
        noticed = true;
        if (chance(0.35 + 0.55 * playful)) { earL.v += 8; earR.v += 8; enter("watch"); }
      }
    }
    playEnergy = Math.min(1, playEnergy + dt / 240);
    // a toy being waved about or thrown: out of the box, awake, after it
    if (toyExciting() && !held && act !== "chase" && !committed()) {
      if (act === "inBox") { if (time >= dizzyUntil && chance(dt * 3)) letOut(); }
      else if (act === "sleep") { if (hypot(toy.pos.x - pos.x, toy.pos.y - pos.y) < 500 * scale && chance(dt * 1.5)) { sleeping = false; enter("chase"); } }
      else if (!isHome()) enter("chase");
    }
    if (["sit", "look", "wander"].includes(act) && chance(dt / 60)) say("meow");   // (every ~2.5 min on the Mac)
    if (!isHome() && !committed() && time > visitAt && IDLE_ACTS.includes(act)) enter("visit");

    switch (act) {
      case "inBox": inBox(dt, per); break;
      case "leaving": leaving(dt); break;
      case "air": inAir(dt); break;
      case "land": pose("stand"); brake(dt); lean.target = 0; if (t > 0.35) enter(decideOut(per)); break;
      case "pin": {
        pose("crouch"); brake(dt); paw.target = 1; pawX.target = 34; pawY.target = 2; mood("hunt");
        const fs = facing.target >= 0 ? 1 : -1;
        const caught = toyKind != null && toy.place === "free" && Math.abs(toy.pos.x - (pos.x + fs * 30 * scale)) < 45 * scale
          && toy.pos.y - toyRadius() - floorY < 20 * scale;
        if (caught) { if (t <= dt * 1.5) toySound(); toy.vx = 0; toy.spin = 0; toy.pos.x += (pos.x + fs * 32 * scale - toy.pos.x) * 0.3; lookAt(toy.pos.x, toy.pos.y); }
        else lookAt(ptrX, ptrY);
        if (t > 0.6) {
          paw.target = 0; playful = Math.max(0.2, playful - 0.1);
          if (caught) { playEnergy = Math.max(0, playEnergy - 0.035); if (playEnergy < 0.3) { snatchToy(); go("goHome"); } else enter("chase"); }
          else enter(chance(0.5) ? "sit" : "watch");
        }
        break;
      }
      case "sit": pose("sit"); brake(dt); mood("relaxed"); idleLook(per); if (t > d.dur) enter(decideOut(per)); break;
      case "look":
        pose("sit"); brake(dt); mood("relaxed");
        if (t > d.next) { d.next = t + rnd(0.7, 1.8); d.lookX = pos.x + rnd(-300, 300); d.lookY = floorY + rnd(0, 260); }
        lookAt(d.lookX, d.lookY);
        if (t > d.dur) enter(decideOut(per));
        break;
      case "groom":
        pose("sit"); brake(dt); mood("relaxed");
        groom.target = t > 0.3 && t < d.dur - 0.3 ? 1 : 0;
        pitch.target = -0.35 + sin(t * 9) * 0.06; gx.target = 0.2; gy.target = -0.4;
        open.target = 0.35; headFacing.target = sgn(facing.target);
        if (t > d.dur) enter(decideOut(per));
        break;
      case "yawn":
        pose("sit"); brake(dt); mood("relaxed");
        yawn.target = t > 0.2 && t < 1.3 ? 1 : 0; open.target = yawn.target > 0 ? 0.08 : 1;
        pitch.target = yawn.target * 0.35; earL.target = earR.target = yawn.target * 0.35;
        if (t > d.dur) enter(chance(0.4) ? "stretch" : decideOut(per));
        break;
      case "stretch":
        pose(t < 1.3 ? "bow" : "stand"); brake(dt); mood("happy"); open.target = t < 1.3 ? 0.3 : 1;
        if (t > d.dur) enter(decideOut(per));
        break;
      case "loaf":
        pose("lie"); brake(dt); mood("relaxed"); open.target = t > 2 ? 0.45 : 1; idleLook(per, 0.4);
        if ((per.idle > 25 || d.ready) && t > 4) go("sleep", newD({ dur: rnd(20, 50), bored: d.bored }));
        else if (t > d.dur) enter(decideOut(per));
        break;
      case "sleep": sleepTick(dt, per); break;
      case "wander": pose("stand"); mood("walk"); lookForward(); if (moveToward(d.x, 75, dt)) enter(chance(0.6) ? "sit" : "look"); break;
      case "watch": watch(dt, per); break;
      case "approach":
        pose("stand"); mood("alert"); lookAt(ptrX, ptrY);
        if (moveToward(ptrX - sgn(ptrX - pos.x) * 100, 80, dt, 10) || t > d.dur) enter("watch");
        break;
      case "stalk": stalk(dt, per); break;
      case "swat":
        pose("sit"); brake(dt); mood("hunt"); lookAt(ptrX, ptrY); faceTo(ptrX); dil.target = 1;
        if (!swat) { if (d.left > 0) { d.left--; startSwat({ x: ptrX, y: ptrY }); } else enter(per.dH < 90 && chance(0.5) ? "watch" : "sit"); }
        break;
      case "petted":
        pose("sit"); brake(dt); mood("happy");
        happy.target = 1; purr.target = 1; earL.target = earR.target = 0.25; lookAt(ptrX, ptrY);
        if (fmod(t, 0.7) < dt) emitHeart();
        if (petTime < 0.05 && time - lastPet > 0.7) enter(chance(0.5) ? "sit" : "groom");
        else if (t > 5 && chance(dt * 0.25)) enter("swat");
        break;
      case "startle":
        earL.target = earR.target = 0.9; mood("scared"); dil.target = 1;
        if (!air) { brake(dt); pose("crouch"); if (t > 1.1) enter(chance(0.4) ? "goHome" : "watch"); }
        else stepAir(dt);
        break;
      case "goHome": goHome(dt); break;
      case "held": heldTick(dt); break;
      case "dizzy": dizzyTick(dt); break;
      case "chase": chase(dt); break;
      case "climb": climb(dt); break;
      case "trophy": trophy(dt); break;
      case "visit": visit(dt, per); break;
      case "zoomies":
        pose("stand"); mood("happy"); lookForward(); earL.target = earR.target = -0.2;
        if (moveToward(d.x, 340, dt, 12)) {
          if (d.left > 0) { d.left--; d.x = clamp(pos.x - sgn(facing.target) * rnd(250, 450), minX, maxX); }
          else enter("sit");
        }
        break;
    }
    updateSwat(dt);
    if (!isHome() && !held && act !== "goHome" && act !== "air" && boxShow.target > 0 && !boxNeeded()) boxShow.target = 0;
  }

  function leaving(dt) {
    pose("sit"); rim.target = 0;
    if (t < 0.24) { squash.target = 0.8; d.peekValue = lerp(1, 0.7, t / 0.24); placeInBox(d.peekValue); }
    else {
      squash.target = 1;
      const side = box.x + boxW() + 70 * scale < maxX ? 1 : -1;
      outSince = time;
      sfx("boxOut");   // pushes off the cardboard
      if (toyKind != null && !toyInBox()) boxLingerUntil = time + 6;   // jumped out after the toy
      const bored = rnd(...WEB.bored);
      launch(box.x + boxW() / 2 + side * (boxW() / 2 + 55 * scale), floorY, box.y + boxRim() + 40 * scale - Math.max(pos.y, floorY), "land");
      d.bored = bored; d.fromBox = true;
    }
  }
  function inAir(dt) {
    pose("leap");
    velY -= GRAVITY * dt;
    pos.x += velX * dt; pos.y += velY * dt;
    squash.target = 1 + clamp(Math.abs(velY) / 2600, 0, 0.22);
    lean.target = clamp(velY / 1800, -0.35, 0.35) * sgn1(facing.target);
    // stay hidden by the box front while climbing out of it or dropping into it
    const rimY = box.y + boxRim(), overBox = Math.abs(pos.x - (box.x + boxW() / 2)) < boxW() / 2 + 10;
    const hidden = overBox && ((d.fromBox && pos.y < rimY) || (d.then === "box" && velY < 0 && pos.y < rimY + 40 * scale));
    boxClip = hidden ? rimY : null;
    if (d.fromBox && velY < 0 && !boxNeeded()) boxShow.target = 0;
    if (toyKind != null && toy.place === "free" && time - lastToyHit > 0.4) {
      const h = headWorld();
      if (hypot(toy.pos.x - h.x, toy.pos.y - h.y) < 30 * scale + toyRadius()) {
        const fs = facing.target >= 0 ? 1 : -1;
        toy.vx = velX * 0.7 + fs * rnd(120, 260) * scale; toy.vy = Math.max(toy.vy, 0) + rnd(220, 420);
        toy.spin = rnd(-12, 12); lastToyHit = time;
      }
    }
    if (d.then === "box" && velY < 0 && pos.y <= d.landY) { landInBox(); return; }
    if (pos.y <= floorY && velY < 0) {
      if (velY < -520) sfx("land", (-velY - 400) / 900);   // a soft thump on bigger drops
      pos.y = floorY; air = false; velY = 0;
      squash.x = 0.7; squash.v = 0; squash.target = 1; lean.target = 0; leap.target = 0;
      if (d.then === "pin") { pose("crouch"); go("pin", newD({ bored: d.bored })); }
      else go("land", newD({ bored: d.bored }));
    }
  }
  function stepAir(dt) {
    velY -= GRAVITY * dt; pos.x += velX * dt; pos.y += velY * dt;
    if (pos.y <= floorY) { pos.y = floorY; velY = 0; air = false; squash.x = 0.75; leap.target = 0; }
  }
  function startle() {
    swat = null; paw.target = 0;
    const away = sgn1(pos.x - ptrX);
    velX = away * 220; velY = 520; air = true; squash.x = 1.25; leap.target = 0.6;
    facing.target = -away; tailPuff.target = 1.9;
    go("startle", newD({ bored: d.bored }));
  }
  function idleLook(per, amount = 1) {
    if (per.near && per.moving && interest > 0.2) lookAt(ptrX, ptrY);
    else if (fmod(t, 2.2) < 0.02) { gx.target = rnd(-0.6, 0.6) * amount; gy.target = rnd(-0.3, 0.4) * amount; pitch.target = rnd(-0.1, 0.2); }
  }
  function watch(dt, per) {
    const low = ptrY - floorY < 60;
    pose(low && playful > 0.5 ? "crouch" : "sit"); crouch.target *= 0.6;
    brake(dt); mood("hunt"); lookAt(ptrX, ptrY); faceTo(ptrX, 30); dil.target = 0.85;
    // head tilt when the pointer pauses: the classic curious cat
    tilt.target = per.idle > 0.35 && per.idle < 3 && per.dH < 260 ? 0.32 * d.tiltSign : 0;
    if (t > d.dur) { if (!per.near || interest < 0.1) enter(chance(0.5) ? "sit" : "groom"); else enter(decideOut(per)); }
  }
  function stalk(dt, per) {
    const dx = ptrX - pos.x;
    pose("crouch"); mood("hunt"); lookAt(ptrX, ptrY); dil.target = 1; earL.target = earR.target = -0.1;
    if (Math.abs(dx) > 130 && !d.ready) { moveToward(ptrX - sgn(dx) * 120, 38, dt, 6); d.wiggle = 0; }
    else {
      brake(dt); faceTo(ptrX); d.ready = true;
      d.wiggle += dt; wiggle.target = d.wiggle > 0.3 ? 1 : 0;
      if (d.wait === 0) d.wait = rnd(0.9, 1.4);
      if (d.wiggle > d.wait) {
        wiggle.target = 0; squash.x = 0.82; earL.target = earR.target = 0;
        const tx = clamp(ptrX, minX, maxX), ty = Math.max(floorY, ptrY - 22);
        launch(tx - sgn(dx) * 10, floorY, Math.max(25, ty - floorY + 10), "pin");
        playful = Math.max(0.25, playful - 0.08);
        return;
      }
    }
    if (ptrSpeed > 900 || t > d.dur || !per.near) { wiggle.target = 0; enter("watch"); }
  }
  function sleepTick(dt, per) {
    pose("lie"); brake(dt); mood("sleep"); sleeping = true;
    open.target = 0; gx.target = 0; gy.target = 0; pitch.target = -0.12;
    zzz += dt;
    if (per.near && per.moving) {
      d.stir += dt;
      if (d.stir > 0.05 && d.stir - dt <= 0.05) earTwitch();
      if (d.stir > 1.2) { sleeping = false; open.target = 1; say("wake", 0.5); enter("yawn"); return; }
    } else d.stir = Math.max(0, d.stir - dt * 0.5);
    // a nap, not hibernation: wakes up by itself and stretches
    if (d.dur > 0 && t > d.dur) { sleeping = false; open.target = 1; lastVocal = -10; say("wake", 0.55); enter(chance(0.6) ? "stretch" : "yawn"); }
  }
  function goHome(dt) {
    boxShow.target = 1;
    // tidies up: fetches its toy and carries it home in its mouth
    if (toyKind != null && toyResting() && toy.pos.x > minX - 20 && toy.pos.x < maxX + 20) {
      pose("stand"); mood("walk"); lookAt(toy.pos.x, toy.pos.y);
      const side = sgn1(toy.pos.x - pos.x);
      if (moveToward(clamp(toy.pos.x - side * 20 * scale, minX, maxX), 130, dt, 6)) { faceTo(toy.pos.x, 1); toy.place = "carried"; t = 0; }
      return;
    }
    const cx = box.x + boxW() / 2, onFloor = box.y - floorY < 10, side = sgn1(pos.x - cx);
    const spot = onFloor ? cx + side * (boxW() / 2 + 34 * scale) : cx + side * 30 * scale;
    pose("stand"); mood("walk"); lookForward();
    if (t < 0.5) { brake(dt); lookAt(cx, box.y + boxRim()); return; }
    if (moveToward(clamp(spot, minX, maxX), 120, dt, 5)) {
      faceTo(cx, 1);
      d.prep += dt; squash.target = 0.8; pose("crouch"); crouch.target = 0.5;
      if (d.prep > 0.22) { squash.target = 1; launch(cx, box.y + boxRim() - 30 * scale, 34, "box"); }
    }
  }
  function landInBox() {
    air = false; velX = 0; velY = 0; leap.target = 0; lean.target = 0;
    facing.target = sgn1(facing.target); squash.x = 0.8; squash.target = 1;
    pose("sit"); sit.snap(1); crouch.snap(0); leap.snap(0);
    if (toy.place === "carried") placeToyInBox();   // drops it in the box
    sfx("boxIn");   // a soft cardboard thump as it lands inside
    const n = newD({ next: time + rnd(...WEB.roamDelay) });
    n.peek = new Spring(0, 3, 0.55); n.peek.target = 1;
    go("inBox", n);
  }
  function placeInBox(peek) {
    const rimY = box.y + boxRim();
    pos.x = box.x + boxW() / 2;
    pos.y = rimY + (lerp(-98, -40, clamp01(peek)) + Math.max(0, peek - 1) * 60) * scale;
    boxClip = rimY;
  }
  function inBox(dt, per) {
    pose("sit"); mood("box"); boxShow.target = 1;
    const sleepy = per.idle > 40;
    sleeping = sleepy && !per.near;
    let peek = sleepy ? 0.62 : 0.95;
    if (per.near && per.moving && per.dH < 230) peek = 1.12;
    if (per.startle || (ptrSpeed > 2400 && per.dH < 170 && toy.place !== "held")) duckUntil = time + 1.3;
    if (swat) peek = 1.25;                       // rise up to bat over the rim
    if (time < duckUntil) peek = 0;
    const dizzyNow = time < dizzyUntil;
    if (dizzyNow) peek = 0.88 + sin(time * 2.2) * 0.07;   // sways woozily at the rim
    d.peek.target = peek; d.peek.step(dt);
    placeInBox(d.peek.x);
    rim.target = d.peek.x > 0.85 && !sleepy ? 1 : 0;
    open.target = sleeping ? 0 : 1;
    if (dizzyNow) { /* swirly eyes do the looking */ }
    else if ((per.near && interest > 0.15) || per.dH < 160) { lookAt(ptrX, ptrY); faceTo(ptrX, 30 * scale); }
    else if (fmod(t, 2.6) < dt) { gx.target = rnd(-0.7, 0.7); gy.target = rnd(-0.2, 0.4); headFacing.target = chance(0.5) ? 1 : -1; }
    tilt.target = per.idle > 0.4 && per.idle < 3 && per.dH < 200 ? 0.28 : 0;
    if (dizzyNow) {
      lean.target = sin(time * 2.6) * 0.09; tilt.target = sin(time * 3.3) * 0.3; pitch.target = cos(time * 3.3) * 0.12;
      earL.target = 0.45; earR.target = 0.2;
    } else lean.target = 0;
    if (petTime > 0.25) {
      if (petTime - dt <= 0.25) say("chirp", 0.5);
      happy.target = 1; purr.target = 1; if (fmod(t, 0.7) < dt) emitHeart();
    }
    const facingPtr = Math.abs(ptrX - pos.x) < 12 * scale || (sgn(ptrX - pos.x) === sgn(facing.x) && Math.abs(facing.x) > 0.8);
    if (!swat && !dizzyNow && facingPtr && per.dH < 75 * scale && per.dH > 30 * scale && per.moving && ptrSpeed < 1500 && d.peek.x > 0.9 && chance(dt * 1.6)) {
      startSwat({ x: ptrX, y: ptrY });
    }
    if (swat) rim.target = 0;
    // (on the web it doesn't stay asleep in the box: it still goes out on its own)
    if (roams && (time > d.next || time > visitAt) && petTime === 0 && !dizzyNow) {
      if (time > visitAt) visitPending = true;
      letOut();
    }
  }
  function dizzyTick(dt) {
    mood("relaxed"); tailAmp.target = 0.02;
    if (time < dizzyUntil) {   // stagger a few wobbly steps, then plop down and sway
      const fs = facing.target >= 0 ? 1 : -1;
      if (t < 1.6) { pose("stand"); velX = fs * 32 * scale * (0.5 + 0.5 * sin(t * 3)); pos.x += velX * dt; }
      else { pose("sit"); brake(dt); }
      lean.target = sin(t * 2.4) * 0.13; tilt.target = sin(t * 3.3) * 0.3; pitch.target = cos(t * 3.3) * 0.12;
      earL.target = 0.45; earR.target = 0.2; headFacing.target = fs;
    } else {                   // shake it off
      if (d.wait === 0) d.wait = t;
      const k = t - d.wait, fade = Math.max(0, 1 - k / 0.6);
      pose("sit"); brake(dt); lean.target = 0;
      tilt.target = sin(k * 34) * 0.32 * fade;
      earL.target = sin(k * 34) * 0.4 * fade; earR.target = -sin(k * 34) * 0.4 * fade;
      if (k > 0.75) enter(chance(0.5) ? "groom" : "sit");
    }
  }
  /** Trots over to the pointer with its tail up, sits by it and looks up. */
  function visit(dt, per) {
    const tx = clamp(ptrX, minX, maxX), side = sgn1(tx - pos.x);
    mood("happy"); lookAt(ptrX, ptrY);
    if (!d.ready) {
      pose("stand");
      if (moveToward(clamp(tx - side * 55 * scale, minX, maxX), 120, dt, 8)) { d.ready = true; d.wait = 0; faceTo(ptrX, 1); emitHeart(); say(chance(0.5) ? "meow" : "chirp"); }
      if (t > 25) enter("sit");
    } else {
      pose("sit"); brake(dt); faceTo(ptrX, 10);
      happy.target = 0; tilt.target = 0.22 * d.tiltSign; purr.target = 0.45;
      d.wait += dt;
      if (chance(dt * 0.4)) emitHeart();
      if (Math.abs(tx - pos.x) > 160 * scale && d.left < 2) { d.ready = false; d.left++; }
      else if (d.wait > d.dur) enter(decideOut(per));
    }
  }

  // ---- the toy ----
  function placeToyInBox() {
    toy.place = "box"; toy.vx = 0; toy.vy = 0; toy.spin = 0; toy.angle = -0.3; toy.facing = 1;
    toy.pos = { x: box.x + 32 * scale, y: box.y + boxRim() + toyRadius() * 0.15 };
  }
  function stepToy(dt) {
    if (!toyKind) return;
    const r = toyRadius();
    switch (toy.place) {
      case "box": placeToyInBox(); break;
      case "held":
        toy.pos = { x: ptrX - toy.grab.dx, y: ptrY - toy.grab.dy };
        toy.vx = ptrVX; toy.vy = ptrVY; toy.spin = 0;
        toy.angle += (clamp(-ptrVX * 0.0005, -0.6, 0.6) - toy.angle) * Math.min(1, dt * 8);   // swings as you wave it
        if (Math.abs(ptrVX) > 60) toy.facing = sgn(ptrVX);
        break;
      case "carried": {
        const sk = skeleton();
        toy.pos = toWorld(sk.p.kx + 16, sk.p.ky - 13);
        toy.vx = 0; toy.vy = 0; toy.angle = 0.15; toy.facing = facing.x >= 0 ? 1 : -1;
        break;
      }
      case "free": {
        toy.vy -= 1900 * dt;
        toy.pos.x += toy.vx * dt; toy.pos.y += toy.vy * dt;
        toy.angle += toy.spin * dt;
        const rimY = box.y + boxRim();
        if (boxShow.x > 0.5 && toy.vy < 0 && toy.pos.x > box.x + 12 * scale && toy.pos.x < box.x + boxW() - 12 * scale
            && toy.pos.y < rimY + r && toy.pos.y > rimY - 25 * scale) { toyBackInBox(); return; }   // dropped into the box
        if (toy.pos.y - r <= floorY) {
          toy.pos.y = floorY + r;
          if (toy.vy < -350) sfx(toyKind === "bird" ? "bell" : "toyLand", (-toy.vy - 250) / 1200);   // hits the floor
          if (toy.vy < -120) { toy.vy = -toy.vy * 0.42; toy.spin *= 0.7; } else toy.vy = 0;
          toy.vx *= Math.exp(-dt * (TOYS[toyKind].rolls ? 1.6 : 4.5));
          if (Math.abs(toy.vx) < 4) toy.vx = 0;
          if (TOYS[toyKind].rolls) toy.spin = -toy.vx / r;
          else { toy.spin *= Math.exp(-dt * 8); const a = Math.atan2(sin(toy.angle), cos(toy.angle)); toy.angle = a - a * Math.min(1, dt * 6); }
        }
        // the edges of the stage are walls
        if (toy.pos.x < r) { toy.pos.x = r; toy.vx = Math.abs(toy.vx) * 0.5; }
        if (toy.pos.x > W - r) { toy.pos.x = W - r; toy.vx = -Math.abs(toy.vx) * 0.5; }
        if (toy.pos.y + r > maxY) { toy.pos.y = maxY - r; toy.vy = -Math.abs(toy.vy) * 0.4; }
        if (Math.abs(toy.vx) > 30) toy.facing = sgn(toy.vx);
        break;
      }
    }
  }
  /** You put the toy back in the box: the cat follows it home. */
  function toyBackInBox() {
    placeToyInBox();
    if (isHome() || act === "goHome" || held) return;
    if (committed()) homePending = true; else { sleeping = false; go("goHome"); }
  }
  function grabToy() {
    if (!toyKind) return false;
    if (toy.place === "box" && boxShow.x < 0.5) return false;
    toy.grab = { dx: ptrX - toy.pos.x, dy: ptrY - toy.pos.y };
    toy.place = "held";   // also takes it out of the cat's mouth
    toySound();
    return true;
  }
  /** Let go of the toy: it flies off with the pointer's speed, or drops into the box if it's over it. */
  function throwToy() {
    if (toy.place !== "held") return;
    const rimY = box.y + boxRim();
    const overBox = toy.pos.x > box.x && toy.pos.x < box.x + boxW() && toy.pos.y > rimY - 20 * scale && toy.pos.y < rimY + 70 * scale;
    if (overBox && hypot(ptrVX, ptrVY) < 300 && boxShow.x > 0.5) { toyBackInBox(); return; }
    toy.place = "free";
    boxLingerUntil = Math.max(boxLingerUntil, time + 4);
    toy.vx = clamp(ptrVX, -2600, 2600) * 0.9;
    toy.vy = clamp(ptrVY, -1500, 2600) * 0.9;
    toy.spin = -toy.vx / Math.max(toyRadius(), 1) * 0.4 + rnd(-3, 3);
  }
  function snatchToy() { toy.place = "carried"; toy.vx = 0; toy.vy = 0; happyUntil = time + 0.8; lastToyPlay = time; toySound(); say("chirp", 0.4); }
  /** Trots off with the toy in its mouth, sits with it, then drops it to play again or takes it home. */
  function trophy(dt) {
    if (toy.place !== "carried") { enter(decideOut(perceiveQuiet())); return; }
    mood("happy"); lastToyPlay = time;
    if (!d.ready) { pose("stand"); lookForward(); if (moveToward(d.x, 150, dt, 8) || t > 6) { d.ready = true; d.wait = 0; } }
    else {
      pose("sit"); brake(dt); idleLookForward();
      d.wait += dt;
      if (d.wait > d.dur) { if (playEnergy < 0.35) go("goHome"); else { toy.place = "free"; toy.vx = 0; toy.vy = 0; enter("chase"); } }
    }
  }
  function perceiveQuiet() {
    const h = headWorld();
    return { head: h, dH: hypot(ptrX - h.x, ptrY - h.y), idle: time - ptrLastMove, moving: time - ptrLastMove < 0.25, near: false, startle: false };
  }
  function idleLookForward() { gx.target = 0.3 * sgn(facing.target); gy.target = 0; pitch.target = 0.05; headFacing.target = sgn(facing.target); }
  function batToy() {
    const fs = facing.target >= 0 ? 1 : -1, dir = sgn(toy.pos.x - pos.x) || fs;
    startSwat(toy.pos);
    toy.place = "free";
    toy.vx = dir * rnd(260, 520) * scale; toy.vy = rnd(140, 380); toy.spin = rnd(-14, 14);
    lastToyHit = time; playEnergy = Math.max(0, playEnergy - 0.025);
    toySound();
  }
  /** Runs after the toy, leads it while it flies, leaps at it, bats it about, pounces on it. */
  function chase(dt) {
    if (!toyKind || !(toy.place === "free" || toy.place === "held")) { enter("sit"); return; }
    const r = toyRadius(), fs = facing.target >= 0 ? 1 : -1;
    mood("hunt"); lookAt(toy.pos.x, toy.pos.y); dil.target = 1;
    lastToyPlay = time; playEnergy = Math.max(0, playEnergy - dt / 50);
    const height = toy.pos.y - r - floorY;
    let tx = toy.pos.x;
    if (toy.place === "free" && height > 4) {   // where it'll come down
      const g = 1900, tFall = (toy.vy + Math.sqrt(Math.max(0, toy.vy * toy.vy + 2 * g * height))) / g;
      tx = toy.pos.x + toy.vx * Math.min(tFall, 1.2);
    }
    tx = clamp(tx, minX, maxX);
    const dx = tx - pos.x, side = sgn(dx) || fs;
    if (d.wait > 0) { d.wait -= dt; pose("crouch"); crouch.target = 0.5; brake(dt); faceTo(toy.pos.x, 10); return; }   // just batted it: watch it go
    const reach = 240 * scale, near = Math.abs(toy.pos.x - pos.x);
    if (height > 25 * scale && height < reach && near < 150 * scale && time > nextLeap) {
      nextLeap = time + rnd(0.7, 1.3);
      startSwat(toy.pos);
      launch(clamp(toy.pos.x - side * 14 * scale, minX, maxX), floorY, height + 20 * scale, "land");
      return;
    }
    if (height >= reach && toy.place === "held" && near < 110 * scale) { enter("climb"); return; }
    if (height <= 25 * scale && near < 30 * scale + r) {
      if (toy.place === "free") {
        if (chance(0.4) && toySpeed() < 200 && time > nextLeap) { nextLeap = time + 0.8; launch(clamp(toy.pos.x, minX, maxX), floorY, 26 * scale, "pin"); }   // pounce
        else { batToy(); d.wait = rnd(0.5, 1.1); }
        return;
      } else {   // dangled in front of its nose
        if (!swat && chance(dt * 2)) startSwat(toy.pos);
        const h = headWorld();
        if (hypot(toy.pos.x - h.x, toy.pos.y - h.y) < 34 * scale + r) {
          d.wiggle += dt;
          if (d.wiggle > 0.5 && chance(dt * 2.5)) { snatchToy(); enter("trophy"); return; }
        }
      }
    }
    const fast = near > 200 * scale;
    pose(fast ? "stand" : "crouch");
    if (!fast) crouch.target = 0.35;
    const arrived = moveToward(tx - side * (14 * scale + r), fast ? 320 : 170, dt, 6);
    if (arrived && toyResting() && (playEnergy < 0.25 || t > d.dur)) { snatchToy(); go("goHome"); }   // tired of it: takes it home
    else if (t > d.dur + 10) enter("sit");
  }
  /** The toy is held out of reach: claws its way up after it, in strokes, then lets go and drops. */
  function climb(dt) {
    pose("stand"); hold.target = 1; climbView.target = 1;
    mood("hunt"); tailBase.target = -1.45; tailCurl.target = 0.1; tailAmp.target = 0.06;
    earL.target = earR.target = 0.1; dil.target = 1;
    gx.target = clamp((toy.pos.x - pos.x) / (160 * scale), -0.6, 0.6); gy.target = 0.8;   // looking up at it
    lastToyPlay = time;
    // climbs until its paws are at the toy, up to 60% of the stage, and never past the top
    const maxH = Math.max(0, Math.min((maxY - floorY) * 0.6, maxY - floorY - 140 * scale));
    const want = clamp(toy.pos.y - floorY - 74 * scale - 25 * scale, 0, maxH);
    const stroke = CLIMB_STROKE * scale;
    const moreToGo = toy.place === "held" && t < d.dur && want > d.landY + 4 * scale;
    if (moreToGo || climbPhase > 0) {
      const was = climbPhase;
      climbPhase += dt / 0.5;
      if (was < 0.35 && climbPhase >= 0.35) sfx("claw", rnd(0.7, 1));   // claws dig in as it pushes
      if (climbPhase >= 1) { climbPhase = 0; d.landY += stroke; climbLead = -climbLead; }
    }
    if (!moreToGo && climbPhase === 0 && want < d.landY - stroke * 1.5) d.landY = Math.max(0, d.landY - 60 * scale * dt);   // toy lowered: slides down a bit
    d.x = d.landY + smoothstep(clamp01((climbPhase - 0.35) / 0.25)) * stroke;
    pos.x = clamp(pos.x + clamp(toy.pos.x - pos.x, -45 * dt, 45 * dt), minX, maxX);
    pos.y = floorY + d.x + 74 * scale * clamp01(hold.x);
    const paws = { x: pos.x, y: pos.y + 22 * scale }, gap = hypot(toy.pos.x - paws.x, toy.pos.y - paws.y);
    climbReachSide = toy.pos.x >= pos.x ? 1 : -1;
    climbReach.target = gap < 80 * scale ? 1 : 0;
    if (toy.place === "held" && gap < 32 * scale + toyRadius()) {
      d.wiggle += dt;
      if (d.wiggle > 0.45 && chance(dt * 3)) {
        snatchToy(); climbView.target = 0; hold.target = 0;
        pos.y = floorY + d.x; air = true; velY = 80; velX = 0;
        go("air", newD({ then: "land" }));
        return;
      }
    }
    if (toy.place !== "held" || t > d.dur || Math.abs(toy.pos.x - pos.x) > 220 * scale) {
      hold.target = 0; paddle.target = 0; climbView.target = 0;
      pos.y = floorY + d.x; air = true; velY = 60;
      velX = toy.place === "free" ? clamp((toy.pos.x - pos.x) * 1.2, -350, 350) : 0;
      go("air", newD({ then: "land" }));
    }
  }
  function heldTick(dt) {
    pose("stand"); hold.target = 1; sit.target = 0;
    earL.target = earR.target = 0.5; mood("scared"); tailPuff.target = 1;
    tailBase.target = -1.45; tailCurl.target = 0.08;   // hangs down
    open.target = 1; dil.target = 1;
    // every second or two it does something else; being whisked about or lowered to the floor comes first
    const nearFloor = ptrY - floorY < 130 * scale;
    if (ptrSpeed > 1100) { if (heldGesture !== "scramble") { heldGesture = "scramble"; heldNext = time + 0.8; } }
    else if (nearFloor && heldGesture !== "reachDown" && heldGesture !== "scramble") { heldGesture = "reachDown"; heldNext = time + rnd(1.5, 3); }
    else if (time > heldNext) { heldGesture = nearFloor ? "reachDown" : pickHeld(); heldNext = time + rnd(1.0, 2.6); }
    const fs = facing.x >= 0 ? 1 : -1;
    switch (heldGesture) {
      case "limp": paddleRate = 2; lookAt(ptrX + fs * 40, ptrY - 80); break;
      case "reach":       // paws up and forward, as if reaching for your arm
        heldFX.target = 16; heldFY.target = 24; heldBX.target = 6; heldBY.target = 4;
        curl.target = 0.2; paddle.target = 0.15; paddleRate = 4; earL.target = earR.target = 0.1;
        lookAt(ptrX + fs * 60, ptrY + 10); break;
      case "paddle":      // air-walking
        heldFX.target = 8; heldFY.target = 6; heldBX.target = 4; heldBY.target = 6;
        curl.target = 0.1; paddle.target = 1; paddleRate = 7; lookAt(ptrX + fs * 50, ptrY - 120); break;
      case "tuck":        // curls up, paws tucked to the chest
        heldFX.target = 10; heldFY.target = 14; heldBX.target = 14; heldBY.target = 18;
        curl.target = 1; paddle.target = 0; paddleRate = 2; tailCurl.target = 0.32; earL.target = earR.target = 0.25;
        lookAt(ptrX + fs * 30, ptrY - 40); break;
      case "reachDown":   // close to the floor: stretches all four legs down to land
        heldFX.target = 6; heldFY.target = -10; heldBX.target = 2; heldBY.target = -12;
        curl.target = -0.2; paddle.target = 0.35; paddleRate = 5; earL.target = earR.target = 0;
        lookAt(ptrX + fs * 20, floorY); break;
      case "scramble":    // whisked about: paddling hard, ears back
        heldFX.target = 10; heldFY.target = 8; heldBX.target = 4; heldBY.target = 8;
        curl.target = 0.3; paddle.target = 1.3; paddleRate = 11; earL.target = earR.target = 0.8;
        lookAt(ptrX + fs * 40, ptrY - 80); break;
    }
    paddlePhase += dt * paddleRate;
    swing.target = clamp(-ptrVX / 2200, -0.5, 0.5);
    dangle.target = clamp(-ptrVX * 0.018, -26, 26) * scale;
    stretch.target = clamp(ptrVY * 0.01, -6, 12);
    pos.x = ptrX; pos.y = ptrY - 8 * scale;
    boxShow.target = 1;
  }
  function pickHeld() { return pick([["limp", 25], ["reach", 22], ["paddle", 18], ["tuck", 15]].filter((o) => o[0] !== heldGesture)); }

  // ---- commands ----
  function letOut() {
    if (act !== "inBox") return;
    rim.target = 0; swat = null; paw.target = 0; happy.target = 0; purr.target = 0;
    go("leaving", newD({ peekValue: d.peek.x }));
  }
  function callHome() { if (isHome() || act === "goHome" || act === "air" || act === "held") return; sleeping = false; go("goHome"); }
  function clickCat() {
    if (act === "inBox") { letOut(); return; }
    if (committed()) return;
    if (act === "sleep") { sleeping = false; enter("yawn"); return; }
    emitHeart(); happyUntil = time + 0.6;
  }
  function pickUp() {
    if (act === "leaving") return;
    boxClip = null; rim.snap(0); air = false; held = true; sleeping = false;
    if (toy.place === "carried") { toy.place = "free"; toy.vy = 0; }
    swat = null; paw.target = 0; happy.target = 0; purr.target = 0;
    facing.target = sgn1(facing.x);
    heldGesture = chance(0.5) ? "reach" : "paddle"; heldNext = time + rnd(0.8, 1.6);   // first reaction to being lifted
    if (chance(0.5)) { lastVocal = -10; say("meow"); }
    go("held");
  }
  function release() {
    held = false; hold.target = 0; swing.target = 0; earL.target = earR.target = 0;
    const overBox = ptrX > box.x - 10 && ptrX < box.x + boxW() + 10 && ptrY > box.y && ptrY < box.y + boxRim() + 120;
    air = true;
    if (overBox) { velX = 0; velY = 0; go("air", newD({ landY: box.y + boxRim() - 30 * scale, then: "box" })); }
    else {
      velX = clamp(ptrVX * 0.5, -500, 500); velY = clamp(ptrVY * 0.3, -200, 400);
      boxShow.target = boxNeeded() ? 1 : 0;
      outSince = time;
      go("air", newD({ bored: rnd(...WEB.bored), then: "land" }));
      d.landY = floorY;
    }
  }
  function statusLabel() {
    if (act === "inBox" && time < dizzyUntil) return "Dizzy in the box";
    if (act === "inBox" && sleeping) return "Dozing in the box";
    if (act === "inBox" && happy.target > 0) return "Being petted";
    return LABELS[act];
  }

  // =====================================================================
  //  Drawing (the context has y pointing up, in CSS pixels)
  // =====================================================================
  const canvas = document.createElement("canvas");
  canvas.setAttribute("aria-label", "A black cat in a cardboard box. Move your pointer near it, drag it, or throw its toy.");
  stage.appendChild(canvas);
  const mainCtx = canvas.getContext("2d");
  let ctx = mainCtx;

  // Black coat and white eyes, the Mac app's defaults (Look.swift → Palette).
  const PAL = { sclera: "#ffffff", pupil: "#121214", mouth: "#ff8fa3", heart: "#ff6b8b", star: "#ffd140", ink: "#1d1d1f" };
  /** Coat colour → the cat's drawing colours, the way Palette in Look.swift derives them (eyes stay white). */
  function setCoat(hex) {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    const lum = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2], light = lum > 0.55;
    const mix = (o, k) => `rgb(${c.map((v, i) => Math.round(lerp(v, o, k) * 255)).join(",")})`;
    PAL.coat = hex;
    PAL.coatFar = light ? mix(0, 0.1) : mix(1, 0.07);    // far-side legs, a touch off the coat for depth
    PAL.pawRim = light ? mix(0, 0.3) : mix(1, 0.22);     // rim around a paw held in front of the face
    PAL.detail = light ? "rgba(29,29,31,0.85)" : "#ffffff";   // toe lines, closed and happy eyes
    PAL.eyeRing = Math.abs(1 - lum) < 0.35 ? "rgba(29,29,31,0.8)" : null;   // so white eyes still read on a pale coat
  }
  setCoat(opts.coat || "#1d1d1f");
  // The "Kraft" box colour, shaded the way Palette does it.
  const BOX = {};
  {
    const mix = (c, o, k) => c.map((v, i) => lerp(v, o[i], k));
    const css = (c, a = 1) => `rgba(${c.map((v) => Math.round(clamp01(v) * 255)).join(",")},${a})`;
    const b = [0.79, 0.60, 0.38], K = [0, 0, 0], Wt = [1, 1, 1];
    Object.assign(BOX, { top: css(mix(b, Wt, 0.1)), bottom: css(mix(b, K, 0.06)), flap: css(mix(b, K, 0.08)),
      flapDark: css(mix(b, K, 0.15)), scratch: css(mix(b, K, 0.5), 0.32), crease: css(mix(b, K, 0.7), 0.28),
      shade: (a) => css(mix(b, K, 0.7), a), text: PAL.ink });
  }

  function line(a, b, w, color) { ctx.strokeStyle = color; ctx.lineWidth = w; ctx.lineCap = "round"; ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke(); }
  function circle(x, y, r, color) { ctx.fillStyle = color; ctx.beginPath(); ctx.arc(x, y, r, 0, PI * 2); ctx.fill(); }
  function ellipse(x, y, rx, ry, color) { ctx.fillStyle = color; ctx.beginPath(); ctx.ellipse(x, y, rx, ry, 0, 0, PI * 2); ctx.fill(); }
  /** Soft contact shadow: a few stacked translucent ellipses, a cheap blur. */
  function groundShadow(x, y, rx, ry, alpha) {
    if (alpha <= 0.005) return;
    ctx.save(); ctx.fillStyle = "#000"; ctx.globalAlpha *= alpha * 0.32;
    for (let i = 0; i < 4; i++) { const k = 1 + i * 0.22; ctx.beginPath(); ctx.ellipse(x, y, rx * k, ry * k, 0, 0, PI * 2); ctx.fill(); }
    ctx.restore();
  }
  /** Smooth bean between the hip and chest circles. */
  function bean(a, ra, b, rb, back, belly) {
    const dx = b.x - a.x, dy = b.y - a.y, dd = Math.max(hypot(dx, dy), 1), nx = -dy / dd, ny = dx / dd;
    const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, mr = (ra + rb) / 2;
    ctx.fillStyle = PAL.coat; ctx.beginPath();
    ctx.moveTo(a.x + nx * ra, a.y + ny * ra);
    ctx.quadraticCurveTo(mx + nx * (mr + back), my + ny * (mr + back), b.x + nx * rb, b.y + ny * rb);
    ctx.lineTo(b.x - nx * rb, b.y - ny * rb);
    ctx.quadraticCurveTo(mx - nx * (mr + belly), my - ny * (mr + belly), a.x - nx * ra, a.y - ny * ra);
    ctx.closePath(); ctx.fill();
    circle(a.x, a.y, ra, PAL.coat); circle(b.x, b.y, rb, PAL.coat);
  }
  function drawLeg(L, color, outline) {
    const a = toWorld(L.a.x, L.a.y), k = toWorld(L.k.x, L.k.y), f = toWorld(L.f.x, L.f.y);
    const dir = facing.x >= 0 ? 1 : -1, s = scale, fx = f.x + 1.5 * dir * s, fy = f.y + s;
    if (outline) { line(k, f, 10 * s, outline); ellipse(fx, fy, 6.6 * s, 5.6 * s, outline); }
    line(a, k, 9.5 * s, color); line(k, f, 7.5 * s, color);
    ellipse(fx, fy, 5.2 * s, 4.2 * s, color);
  }
  /** One smooth, tapered shape along a curve through the tail's points, rather than a chain of
      separate round-capped strokes (those show a bump at every joint once the tail curls). */
  function drawTail() {
    const n = tail.length;
    if (n < 2) return;
    const puff = tailPuff.x;
    const tw = (i) => lerp(7.5, 4.6, i / (n - 1)) * puff * scale / 2;   // the tail's own half-width
    const chain = tail.map((p, i) => ({ x: p.x, y: p.y, w: tw(i) * (i === 0 ? 1.15 : 1) }));
    // Catmull-Rom through the chain, a few samples per segment
    const m0 = chain.length, pts = [];
    for (let i = 0; i < m0 - 1; i++) {
      const p0 = chain[Math.max(0, i - 1)], p1 = chain[i], p2 = chain[i + 1], p3 = chain[Math.min(m0 - 1, i + 2)];
      for (let k = 0; k < 5; k++) {
        const u = k / 5, u2 = u * u, u3 = u2 * u;
        const f = (a, b, c, d) => 0.5 * (2 * b + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (-a + 3 * b - 3 * c + d) * u3);
        pts.push({ x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y), w: lerp(p1.w, p2.w, smoothstep(u)) });
      }
    }
    pts.push(chain[m0 - 1]);
    const m = pts.length, left = [], right = [];
    for (let i = 0; i < m; i++) {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(m - 1, i + 1)];
      const dx = b.x - a.x, dy = b.y - a.y, dl = Math.max(hypot(dx, dy), 0.001), nx = -dy / dl, ny = dx / dl, w = pts[i].w;
      left.push({ x: pts[i].x + nx * w, y: pts[i].y + ny * w });
      right.push({ x: pts[i].x - nx * w, y: pts[i].y - ny * w });
    }
    ctx.fillStyle = PAL.coat;
    ctx.beginPath();
    ctx.moveTo(left[0].x, left[0].y);
    for (let i = 1; i < m; i++) ctx.lineTo(left[i].x, left[i].y);
    const end = pts[m - 1], pre = pts[m - 2], ta = Math.atan2(end.y - pre.y, end.x - pre.x);
    ctx.arc(end.x, end.y, end.w, ta + PI / 2, ta - PI / 2, true);   // rounded tip
    for (let i = m - 1; i >= 0; i--) ctx.lineTo(right[i].x, right[i].y);
    ctx.closePath();
    ctx.fill();
    circle(pts[0].x, pts[0].y, pts[0].w, PAL.coat);
  }
  /** Rounded head: a superellipse, slightly wider and flatter at the cheeks. */
  function headPath(a, b) {
    ctx.beginPath();
    for (let i = 0; i <= 40; i++) {
      const th = i / 40 * PI * 2, c = cos(th), s = sin(th);
      const x = a * sgn(c) * Math.pow(Math.abs(c), 2 / 2.5) * (s < 0 ? 1.04 : 1);
      const y = b * sgn(s) * Math.pow(Math.abs(s), 2 / 2.5) * (s < 0 ? 0.92 : 1);
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    }
    ctx.closePath();
  }
  function ear(b1, b2, tip, rot) {
    const mx = (b1.x + b2.x) / 2, my = (b1.y + b2.y) / 2;
    ctx.save(); ctx.translate(mx, my); ctx.rotate(rot); ctx.translate(-mx, -my);
    ctx.fillStyle = PAL.coat; ctx.beginPath(); ctx.moveTo(b1.x, b1.y);
    ctx.quadraticCurveTo(lerp(b1.x, tip.x, 0.5) - 2.5, lerp(b1.y, tip.y, 0.5) + 1, tip.x, tip.y);
    ctx.quadraticCurveTo(lerp(b2.x, tip.x, 0.5) + 1.5, lerp(b2.y, tip.y, 0.5) + 2, b2.x, b2.y);
    ctx.closePath(); ctx.fill(); ctx.restore();
  }
  const blinkAmount = () => (blinkT < 0 ? 1 : 1 - sin(PI * clamp01(blinkT / 0.16)));
  function eye(x, y, r, gzx, gzy) {
    const openness = clamp01(open.x * blinkAmount());
    ctx.strokeStyle = PAL.detail; ctx.lineCap = "round"; ctx.lineWidth = 2.2;
    if (dizzy.x > 0.4) {              // @ @
      circle(x, y, r, PAL.sclera);
      if (PAL.eyeRing) { ctx.strokeStyle = PAL.eyeRing; ctx.lineWidth = 1.4; ctx.stroke(); }
      ctx.strokeStyle = PAL.pupil; ctx.lineWidth = 1.6; ctx.beginPath();
      for (let i = 0; i <= 36; i++) {
        const u = i / 36, th = u * PI * 5 + time * 7, rr = r * 0.85 * u;
        i ? ctx.lineTo(x + cos(th) * rr, y + sin(th) * rr) : ctx.moveTo(x, y);
      }
      ctx.stroke(); return;
    }
    if (clamp01(happy.x) > 0.5) {     // ^ ^
      ctx.beginPath(); ctx.moveTo(x - r * 0.8, y - r * 0.15); ctx.quadraticCurveTo(x, y + r * 0.8, x + r * 0.8, y - r * 0.15); ctx.stroke(); return;
    }
    if (openness < 0.1) {             // closed, relaxed
      ctx.beginPath(); ctx.moveTo(x - r * 0.8, y); ctx.quadraticCurveTo(x, y - r * 0.55, x + r * 0.8, y); ctx.stroke(); return;
    }
    ctx.save();
    ctx.beginPath(); ctx.ellipse(x, y - r * (1 - openness) * 0.35, r, r * openness, 0, 0, PI * 2);
    if (PAL.eyeRing) { ctx.strokeStyle = PAL.eyeRing; ctx.lineWidth = 1.4; ctx.stroke(); }
    ctx.fillStyle = PAL.sclera; ctx.fill(); ctx.clip();
    const px = x + gzx * r * 0.42, py = y + gzy * r * 0.34;
    const w = r * (0.34 + 0.62 * clamp01(dil.x)), h = r * 1.5;
    ctx.fillStyle = PAL.pupil; ctx.beginPath();
    ctx.moveTo(px, py + h / 2); ctx.quadraticCurveTo(px + w * 1.05, py, px, py - h / 2); ctx.quadraticCurveTo(px - w * 1.05, py, px, py + h / 2); ctx.fill();
    circle(px + w * 0.28, py + r * 0.3, r * 0.17, "#fff");
    ctx.restore();
  }
  function drawHead(sk) {
    const p = sk.p, c = toWorld(p.kx, p.ky), hf = headFacing.x, sy = 1 + (squash.x - 1) * 0.35, a = tilt.x * 0.9 + pitch.x;
    ctx.save();
    ctx.translate(c.x, c.y); ctx.rotate(lean.x + swing.x * 0.5);
    ctx.scale(turnScale(hf, 0.6) * scale, sy * scale); ctx.rotate(a);
    ear({ x: -22, y: 8 }, { x: -7, y: 18 }, { x: -18, y: 34 }, earL.x * 0.9);
    ear({ x: 6, y: 18 }, { x: 21, y: 9 }, { x: 19, y: 34 }, -earR.x * 0.9);
    ctx.fillStyle = PAL.coat; headPath(25, 21); ctx.fill();
    // gaze in head space (undo the head's own flip and tilt)
    const flip = hf >= 0 ? 1 : -1, gzx = gx.x * flip, gzy = gy.x;
    const rx = gzx * cos(a) + gzy * sin(a), ry = -gzx * sin(a) + gzy * cos(a);
    eye(-6.5, 2, 8, rx, ry); eye(12.5, 2, 8, rx, ry);
    if (yawn.x > 0.05) { const yv = clamp01(yawn.x); ellipse(4, -10, 4 * yv, 6.5 * yv, PAL.mouth); }
    ctx.restore();
  }
  function drawZzz(sk) {
    const h = toWorld(sk.p.kx, sk.p.ky), dir = facing.x >= 0 ? 1 : -1;
    for (let i = 0; i < 3; i++) {
      const u = fmod(zzz * 0.45 + i / 3, 1);
      ctx.save(); ctx.translate(h.x + (18 + u * 22) * dir * scale, h.y + (22 + u * 34) * scale); ctx.scale(1, -1);
      ctx.globalAlpha = sin(PI * u) * 0.85; ctx.font = `700 ${(10 + u * 8) * scale}px system-ui, sans-serif`; ctx.fillStyle = PAL.ink;
      ctx.fillText("z", 0, 0); ctx.restore();
    }
  }
  /** Little stars orbiting above the head; the ones on the far side of the loop are smaller and dimmer. */
  function drawStars(sk) {
    const h = toWorld(sk.p.kx, sk.p.ky), s = scale, k = clamp01(dizzy.x), cx = h.x, cy = h.y + 30 * s;
    for (let i = 0; i < 3; i++) {
      const a = time * 4 + i * PI * 2 / 3, depth = (sin(a) + 1) / 2;
      const c = { x: cx + cos(a) * 26 * s, y: cy - sin(a) * 6 * s }, r = (3.2 + 2 * depth) * s * k;
      ctx.save(); ctx.globalAlpha = k * (0.55 + 0.45 * depth); ctx.fillStyle = PAL.star; ctx.beginPath();
      for (let j = 0; j < 10; j++) {
        const th = j * PI / 5 + PI / 2 + time * 3, rr = j % 2 === 0 ? r : r * 0.45;
        j ? ctx.lineTo(c.x + cos(th) * rr, c.y + sin(th) * rr) : ctx.moveTo(c.x + cos(th) * rr, c.y + sin(th) * rr);
      }
      ctx.closePath(); ctx.fill(); ctx.restore();
    }
  }
  function drawHeart(h) {
    const a = 7 + h.age * 4, dd = a / Math.SQRT2, r = a / 2;
    ctx.save(); ctx.globalAlpha = Math.max(0, 1 - h.age / 1.4); ctx.fillStyle = PAL.heart; ctx.beginPath();
    ctx.moveTo(h.x, h.y + dd); ctx.lineTo(h.x + dd, h.y); ctx.lineTo(h.x, h.y - dd); ctx.lineTo(h.x - dd, h.y); ctx.closePath(); ctx.fill();
    circle(h.x - dd / 2, h.y + dd / 2, r, PAL.heart); circle(h.x + dd / 2, h.y + dd / 2, r, PAL.heart);
    ctx.restore();
  }
  function drawCat() {
    if (climbView.x > 0.5) { drawClimbing(); return; }
    const sk = skeleton(), p = sk.p, s = scale;
    if (boxClip == null && !held) {   // shadow shrinks and fades as it leaves the ground
      const k = clamp01(1 - Math.max(0, pos.y - floorY) / 220);
      groundShadow(pos.x, floorY + 1, 36 * s * (0.6 + 0.4 * k), 4 * s, 0.2 * k);
    }
    ctx.save();
    if (boxClip != null) { ctx.beginPath(); ctx.rect(-10000, boxClip, 30000, 20000); ctx.clip(); }
    drawTail();
    drawLeg(sk.legs.fb, PAL.coatFar); drawLeg(sk.legs.ff, PAL.coatFar);
    const hip = toWorld(p.hx, p.hy), chest = toWorld(p.cx, p.cy);
    const sy = squash.x, sx = 1 + (1 - sy) * 0.7, vol = Math.sqrt(sx * sy) * s;
    const back = lerp(-1.5, 2.5, clamp01(crouch.x)), belly = lerp(-2, -4, clamp01(lie.x));
    bean(hip, p.hr * vol, chest, p.cr * vol, back, belly);
    line(chest, toWorld(p.kx, p.ky), 17 * s, PAL.coat);   // neck
    const heldRim = hold.x > 0.5 ? PAL.pawRim : null;     // dangling legs cross the body: a thin rim keeps them readable
    drawLeg(sk.legs.nb, PAL.coat, heldRim);
    const pawUp = Math.max(paw.x, groom.x) > 0.3;
    if (!pawUp && (boxClip == null || rim.x < 0.5)) drawLeg(sk.legs.nf, PAL.coat, heldRim);
    drawHead(sk);
    if (pawUp) drawLeg(sk.legs.nf, PAL.coat, PAL.pawRim);
    ctx.restore();
    // paws hooked over the rim sit in front of the box, so they're drawn unclipped
    if (boxClip != null && rim.x >= 0.5) {
      for (const id of ["ff", "nf"]) {
        const f = toWorld(sk.legs[id].f.x, sk.legs[id].f.y);
        ellipse(f.x, f.y, 6.5 * s, 5 * s, PAL.coat);
        ctx.strokeStyle = PAL.detail; ctx.lineWidth = 1.3 * s; ctx.lineCap = "round"; ctx.beginPath();
        for (const dx of [-2.2, 2.2]) { ctx.moveTo(f.x + dx * s, f.y - 4.5 * s); ctx.lineTo(f.x + dx * s, f.y - 1.8 * s); }
        ctx.stroke();
      }
    }
    if (sleeping) drawZzz(sk);
    if (dizzy.x > 0.03) drawStars(sk);
    for (const h of hearts) drawHeart(h);
  }
  /** Climbing after the toy, seen from the front: paws reach up in turn while the back feet push. */
  function drawClimbing() {
    const s = scale, u = climbPhase, L = CLIMB_STROKE;
    const g = smoothstep(clamp01(u / 0.35)), r = smoothstep(clamp01((u - 0.35) / 0.25)), squeeze = g - r;
    const k = clamp01(1 - Math.max(0, pos.y - 74 * s - floorY) / 220);
    groundShadow(pos.x, floorY + 1, 26 * s * (0.6 + 0.4 * k), 3.5 * s, 0.18 * k);
    drawTail();
    ctx.save();
    ctx.translate(pos.x, pos.y);
    ctx.rotate(sin(time * 1.3) * 0.03 + squeeze * 0.02 * climbLead + lean.x);
    ctx.scale(s, s);
    const limb = (a, b, out, upper, lower) => {   // the joint bows outwards, like elbows and knees seen from the front
      const m = { x: (a.x + b.x) / 2 + out, y: (a.y + b.y) / 2 };
      line(a, m, upper, PAL.coat); line(m, b, lower, PAL.coat);
      ellipse(b.x, b.y, 5.4, 4.6, PAL.coat);
    };
    const hips = { x: 0, y: climbHipY() }, chest = { x: 0, y: -22 + 2 * squeeze };
    for (const side of [-1, 1]) {
      const foot = { x: side * (16 + 2 * squeeze), y: -70 + 14 * squeeze * (side === climbLead ? 1 : 0.9) };
      limb({ x: side * 8, y: hips.y - 2 }, foot, side * (6 + 5 * squeeze), 11, 8);
    }
    bean(hips, 14, chest, 15, 0, 0);
    const reach = clamp01(climbReach.x);
    for (const side of [-1, 1]) {
      const order = side === climbLead ? 0 : 1;
      const hook = smoothstep(clamp01((u - 0.62 - 0.1 * order) / 0.2)), low = r - hook;
      let pw = { x: side * (27 - 2 * low), y: 30 + L * (hook - r) };
      if (side === climbReachSide && reach > 0) {
        const up = { x: side * 25, y: 42 + sin(time * 14) * 3 };
        pw = { x: lerp(pw.x, up.x, reach), y: lerp(pw.y, up.y, reach) };
      }
      limb({ x: side * 11, y: chest.y + 2 }, pw, side * (6 + 3 * low), 10, 8);
    }
    ctx.translate(0, 6 - 1.5 * squeeze);
    ctx.rotate(tilt.x * 0.5);
    ear({ x: -23, y: 8 }, { x: -8, y: 18 }, { x: -19, y: 34 }, earL.x * 0.9);
    ear({ x: 8, y: 18 }, { x: 23, y: 8 }, { x: 19, y: 34 }, -earR.x * 0.9);
    ctx.fillStyle = PAL.coat; headPath(25, 21); ctx.fill();
    eye(-9, 3, 8, gx.x, gy.x); eye(9, 3, 8, gx.x, gy.x);
    ctx.restore();
    for (const h of hearts) drawHeart(h);
  }

  // ---- the box ----
  function drawBox() {
    const sh = boxShow.x;
    if (sh < 0.02) return;
    const a = clamp01(sh * 3);
    const poly = (pts, fill) => { ctx.fillStyle = fill; ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath(); ctx.fill(); };
    const stroke = (pts, color, w) => { ctx.strokeStyle = color; ctx.lineWidth = w; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.stroke(); };
    ctx.save();
    ctx.translate(box.x + boxW() / 2, box.y);
    ctx.scale(scale, scale);   // everything below is in base units
    groundShadow(0, 1, 74 * clamp(sh, 0, 1.2), 5.5, 0.2 * a);
    ctx.scale(clamp(sh, 0, 1.3), clamp(sh * (1 + (1 - sh) * 0.35), 0, 1.4));   // pops from the bottom centre
    ctx.globalAlpha = a;
    ctx.translate(-60, 0);
    for (const dir of [-1, 1]) {   // flaps, darker towards their tips
      const x0 = dir < 0 ? 0 : 120, tip = x0 + dir * 16, gr = ctx.createLinearGradient(x0, 0, tip, 0);
      gr.addColorStop(0, BOX.flap); gr.addColorStop(1, BOX.flapDark);
      poly([[x0, 90], [tip, 62], [x0, 62]], gr);
    }
    const face = ctx.createLinearGradient(0, 90, 0, 0);
    face.addColorStop(0, BOX.top); face.addColorStop(1, BOX.bottom);
    poly([[0, 0], [120, 0], [120, 90], [0, 90]], face);
    const lip = ctx.createLinearGradient(0, 90, 0, 82);
    lip.addColorStop(0, BOX.shade(0.22)); lip.addColorStop(1, BOX.shade(0));
    poly([[0, 82], [120, 82], [120, 90], [0, 90]], lip);
    const base = ctx.createLinearGradient(0, 0, 0, 7);
    base.addColorStop(0, BOX.shade(0.16)); base.addColorStop(1, BOX.shade(0));
    poly([[0, 0], [120, 0], [120, 7], [0, 7]], base);
    stroke([[0.6, 62], [0.6, 90]], BOX.crease, 1);
    stroke([[119.4, 62], [119.4, 90]], BOX.crease, 1);
    poly([[53, 90], [67, 90], [67, 76], [65, 74.5], [63, 76.5], [60.5, 74], [58, 76], [55.5, 74.2], [53, 75.5]], "rgba(255,255,255,0.3)");
    stroke([[53, 90], [53, 75.5]], "rgba(89,77,51,0.18)", 0.8);
    for (const [pts, w] of [[[[14, 70], [21, 66.5], [27, 65.5]], 0.9], [[[18, 73], [24, 70.5]], 0.7], [[[84, 44], [96, 48], [104, 47]], 0.9],
                            [[[98, 22], [108, 17]], 0.8], [[[101, 25], [106, 22.5]], 0.6], [[[8, 46], [11, 38]], 0.7]]) stroke(pts, BOX.scratch, w);
    ctx.save(); ctx.translate(96, 66); ctx.rotate(-0.3); ellipse(0, 0, 9, 4, "rgba(255,255,255,0.16)"); ctx.restore();
    poly([[0, 0], [9, 0], [0, 7]], "rgba(51,38,13,0.12)");   // worn corner
    // the name, stamped on the front in chunky rounded capitals, shrunk to fit
    const label = catName.toUpperCase();
    if (label) {
      let size = 28, font = "", w = 0;
      const measure = () => {
        font = `900 ${size}px ui-rounded, "Nunito", system-ui, sans-serif`;
        ctx.font = font;
        if ("letterSpacing" in ctx) ctx.letterSpacing = `${size * 0.06}px`;
        return ctx.measureText(label).width;
      };
      w = measure();
      while (w > 102 && size > 10) { size -= 1; w = measure(); }
      ctx.save(); ctx.translate(60, 38); ctx.rotate(-0.035); ctx.scale(1, -1);
      ctx.globalAlpha = a * 0.88; ctx.fillStyle = BOX.text; ctx.textBaseline = "middle";
      ctx.fillText(label, -w / 2 + size * 0.03, size * 0.04);
      if ("letterSpacing" in ctx) ctx.letterSpacing = "0px";
      ctx.restore();
    }
    ctx.restore();
  }

  // ---- toy art (centred on 0,0, facing right, in base units) ----
  function shape(fill, edge, build) {
    ctx.beginPath(); build(); ctx.fillStyle = fill; ctx.fill();
    if (edge) { ctx.strokeStyle = edge; ctx.lineWidth = 1.2; ctx.lineJoin = "round"; ctx.stroke(); }
  }
  function strokePts(pts, c, w) {
    ctx.strokeStyle = c; ctx.lineWidth = w; ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.stroke();
  }
  /** A soft plush shark: chubby body, white belly, stubby fins, a little smile. */
  function sharkArt(top, fin, k) {
    ctx.save(); ctx.scale(k, k);
    const edge = "rgba(47,62,76,0.55)";
    shape(fin, edge, () => { ctx.moveTo(-18, 0); ctx.quadraticCurveTo(-24, 3, -31, 12); ctx.quadraticCurveTo(-26, 6, -27, 0); ctx.quadraticCurveTo(-26, -5, -30, -10); ctx.quadraticCurveTo(-23, -3, -18, -2); ctx.closePath(); });
    shape(fin, edge, () => { ctx.moveTo(-4, 9); ctx.quadraticCurveTo(-3, 16, 1, 19); ctx.quadraticCurveTo(6, 13, 8, 9); ctx.closePath(); });
    shape(top, edge, () => { ctx.moveTo(24, 1); ctx.bezierCurveTo(20, 14, -8, 13, -20, 2); ctx.bezierCurveTo(-8, -12, 20, -12, 24, 1); ctx.closePath(); });
    shape("#F4F1EA", null, () => { ctx.moveTo(22, -2); ctx.bezierCurveTo(14, -11, -6, -10, -14, -3); ctx.bezierCurveTo(-2, -3, 14, -1, 22, -2); ctx.closePath(); });
    shape(fin, edge, () => { ctx.moveTo(4, -3); ctx.quadraticCurveTo(0, -10, -3, -12); ctx.quadraticCurveTo(6, -7, 9, -4); ctx.closePath(); });
    circle(14, 3, 1.9, "#1E2328"); circle(14.6, 3.7, 0.6, "#fff");
    strokePts([[17, -3], [19.5, -4.2], [22, -3]], "rgba(30,35,40,0.8)", 1);
    for (const x of [7, 9.5]) strokePts([[x, 4], [x - 1, 0]], edge, 0.9);
    circle(17, -1, 1.8, "rgba(245,154,168,0.6)");   // blush
    ctx.restore();
  }
  /** A felt mouse: teardrop body, big pink ears, string tail. */
  function mouseArt() {
    const body = "#9C9AA3", pink = "#F4A3B4";
    strokePts([[-11, -2], [-17, 2], [-22, -3], [-26, 1]], "#D98C9C", 1.6);
    shape(body, "rgba(74,72,80,0.55)", () => { ctx.moveTo(14, -3); ctx.bezierCurveTo(8, 12, -14, 10, -12, -5); ctx.quadraticCurveTo(0, -8, 14, -3); ctx.closePath(); });
    circle(3, 8, 5, body); circle(3, 8, 3.2, pink); circle(14.5, -2.5, 1.8, pink); circle(8.5, 1.5, 1.4, "#1E2328");
    for (const dy of [-1, 1]) strokePts([[13, -2], [19, -2 + dy * 2.5]], "rgba(74,72,80,0.5)", 0.6);
  }
  /** A round feather-toy bird: yellow body, orange beak, bright tail feathers. */
  function birdArt() {
    const edge = "rgba(107,78,18,0.5)";
    ["#E5484D", "#3E8EDE", "#46B36B"].forEach((c, i) => {
      ctx.save(); ctx.translate(-8, 1); ctx.rotate(PI + (i - 1) * 0.35);
      shape(c, null, () => ctx.ellipse(7.5, 0, 7.5, 2.6, 0, 0, PI * 2)); ctx.restore();
    });
    shape("#F6C945", edge, () => ctx.ellipse(0, 0, 11, 10, 0, 0, PI * 2));
    shape("#FFE9A6", null, () => ctx.ellipse(1, -4.5, 7, 4.5, 0, 0, PI * 2));
    shape("#E9A92F", edge, () => { ctx.moveTo(-6, 2); ctx.quadraticCurveTo(0, 7, 5, 0); ctx.quadraticCurveTo(-1, -2, -6, 2); ctx.closePath(); });
    shape("#F08A24", edge, () => { ctx.moveTo(10, 3); ctx.lineTo(16, 1); ctx.lineTo(10, -1); ctx.closePath(); });
    circle(5.5, 4, 1.6, "#1E2328"); circle(6, 4.6, 0.5, "#fff");
  }
  /** A small orange plush cat with stitched eyes and stripes. */
  function plushCatArt() {
    const fur = "#F2A04E", edge = "rgba(122,74,24,0.55)", stripe = "#D97E2B";
    strokePts([[-10, -6], [-17, -2], [-18, 6]], fur, 4.5);
    shape(fur, edge, () => ctx.ellipse(-2, -4, 11, 8, 0, 0, PI * 2));
    for (const x of [-7, -2]) strokePts([[x, 3], [x + 1, -2]], stripe, 1.6);
    circle(-8, -12, 3, fur); circle(4, -12, 3, fur);
    shape(fur, edge, () => { ctx.moveTo(0, 8); ctx.lineTo(1, 19); ctx.lineTo(7, 12); ctx.lineTo(12, 12); ctx.lineTo(17, 19); ctx.lineTo(19, 8); ctx.bezierCurveTo(20, -4, -1, -4, 0, 8); ctx.closePath(); });
    circle(3, 15, 1.5, "#F6B8C2"); circle(16, 15, 1.5, "#F6B8C2");
    for (const ex of [5.5, 13]) strokePts([[ex - 2, 7], [ex, 5.6], [ex + 2, 7]], "#3A2410", 1.1);
    circle(9.3, 3.5, 1.1, "#E07A8C");
    strokePts([[6, 13], [7, 10]], stripe, 1.3); strokePts([[12.5, 13], [11.5, 10]], stripe, 1.3);
  }
  function toyArt(kind) {
    if (kind === "shark") sharkArt("#6F8FA9", "#5A7790", 1);
    else if (kind === "miniShark") sharkArt("#8CC6EA", "#6FADD6", 0.66);
    else if (kind === "mouse") mouseArt();
    else if (kind === "bird") birdArt();
    else if (kind === "plushCat") plushCatArt();
  }
  function drawToy() {
    if (!toyKind) return;
    ctx.save();
    if (toy.place === "free") {   // contact shadow, fading with height
      const k = clamp01(1 - Math.max(0, toy.pos.y - toyRadius() - floorY) / 160);
      groundShadow(toy.pos.x, floorY + 1, toyRadius() * 1.1 * (0.6 + 0.4 * k), 3 * scale, 0.22 * k);
    }
    if (toy.place === "box") {    // sits in the box, clipped at the rim like the cat
      ctx.globalAlpha = clamp01((boxShow.x - 0.5) * 3);
      ctx.beginPath(); ctx.rect(-10000, box.y + boxRim(), 30000, 20000); ctx.clip();
    }
    ctx.translate(toy.pos.x, toy.pos.y); ctx.rotate(toy.angle); ctx.scale(toy.facing * scale, scale);
    toyArt(toyKind);
    ctx.restore();
  }
  /** Draws a toy into its own little canvas, for the toy picker. */
  function drawToyIcon(c, kind) {
    const k = window.devicePixelRatio || 1, size = c.clientWidth || 28;
    c.width = c.height = Math.round(size * k);
    ctx = c.getContext("2d");
    const fit = size / (kind === "shark" ? 60 : kind === "miniShark" ? 42 : 40);
    ctx.setTransform(k * fit, 0, 0, -k * fit, c.width / 2 + (kind.includes("hark") ? 3 * k * fit : 0), c.height / 2 + (kind === "plushCat" ? -3 * k * fit : 0));
    toyArt(kind);
    ctx = mainCtx;
  }

  function render() {
    ctx.setTransform(dpr, 0, 0, -dpr, 0, H * dpr);
    ctx.clearRect(0, 0, W, H);
    // In the box the toy sits behind the cat, like the box; once it's out (held, flying or in the
    // cat's mouth) it's drawn in front. (Same fix as the Mac app's toy window level.)
    const toyBehind = toy.place === "box";
    drawBox();
    if (toyBehind) drawToy();
    drawCat();
    if (!toyBehind) drawToy();
  }

  // =====================================================================
  //  World size and input
  // =====================================================================
  function resize() {
    const r = stage.getBoundingClientRect();
    dpr = window.devicePixelRatio || 1;
    const oldW = W;
    W = Math.max(260, r.width); H = Math.max(240, r.height);
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    scale = W >= 900 ? 1.3 : W >= 600 ? 1.15 : 1;
    floorY = 0; maxY = H;
    minX = 45 * scale; maxX = W - 45 * scale;
    box.x = boxMoved ? clamp(box.x + (W - oldW) / 2, 8, W - boxW() - 8) : (W - boxW()) / 2;
    box.y = 0;
    if (!isHome() && !held) pos.x = clamp(pos.x, minX, maxX);
  }

  const toDesk = (e) => { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: H - (e.clientY - r.top) }; };
  let drag = null;
  // While you hold the cat or the toy, it can't leave the stage.
  function clampDrag(p) {
    if (drag?.what === "cat" && drag.moved) return { x: clamp(p.x, 40 * scale, W - 40 * scale), y: clamp(p.y, 95 * scale, H - 50 * scale) };
    if (drag?.what === "toy") { const r = toyRadius(); return { x: clamp(p.x, r, W - r), y: clamp(p.y, r, H - r) }; }
    return { x: clamp(p.x, 0, W), y: clamp(p.y, 0, H) };
  }
  function hitToy(p) {
    if (!toyKind || (toy.place === "box" && boxShow.x < 0.5)) return false;
    return hypot(p.x - toy.pos.x, p.y - toy.pos.y) < toyRadius() * 1.5 + 8;
  }
  function hitCat(p) {
    const h = headWorld();
    if (hypot(p.x - h.x, p.y - h.y) < 30 * scale) return true;
    if (isHome()) return false;
    if (held || climbView.x > 0.5) return hypot(p.x - pos.x, p.y - (pos.y - 30 * scale)) < 55 * scale;
    const l = toLocal(p.x, p.y);
    return l.x > -40 && l.x < 42 && l.y > -4 && l.y < 52;
  }
  const hitBox = (p) => boxShow.x > 0.5 && p.x > box.x - 16 * scale && p.x < box.x + boxW() + 16 * scale && p.y > box.y && p.y < box.y + boxRim();

  canvas.addEventListener("pointerdown", (e) => {
    const p = clampDrag(toDesk(e));
    raw = p; ptrX = p.x; ptrY = p.y;   // a tap jumps the "pointer" here: don't read it as a fast swipe
    if (hitToy(p) && grabToy()) drag = { what: "toy" };
    else if (hitCat(p)) drag = { what: "cat", start: { ...p }, moved: false };
    else if (isHome() && hitBox(p)) drag = { what: "box", start: { ...p }, origin: { ...box } };
    if (drag) { try { canvas.setPointerCapture(e.pointerId); } catch {} canvas.style.cursor = "grabbing"; e.preventDefault(); }
  });
  canvas.addEventListener("pointermove", (e) => {
    raw = clampDrag(toDesk(e));
    if (drag?.what === "cat" && !drag.moved && hypot(raw.x - drag.start.x, raw.y - drag.start.y) > 4) {
      drag.moved = true; pickUp(); raw = clampDrag(raw);
    }
    if (drag?.what === "box") { boxMoved = true; box.x = clamp(drag.origin.x + raw.x - drag.start.x, 8, W - boxW() - 8); }
    if (!drag) canvas.style.cursor = hitToy(raw) || hitCat(raw) || (isHome() && hitBox(raw)) ? "grab" : "default";
  });
  const endDrag = () => {
    if (!drag) return;
    if (drag.what === "toy") throwToy();
    else if (drag.what === "cat") { if (drag.moved) release(); else clickCat(); }
    drag = null; canvas.style.cursor = "default";
  };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  // =====================================================================
  //  Loop
  // =====================================================================
  let last = performance.now() / 1000, lastLabel = "", lastHome = null;
  function frame() {
    const now = performance.now() / 1000, dt = Math.min(now - last, 1 / 12);
    last = now;
    step(dt);
    updateAudio();
    render();
    const label = statusLabel(), home = isHome();
    if (label !== lastLabel || home !== lastHome) { lastLabel = label; lastHome = home; opts.onChange?.(label, home); }
    requestAnimationFrame(frame);
  }

  function setToy(kind) {
    const k = kind && TOYS[kind] ? kind : null;
    if (k === toyKind) return;
    if (drag?.what === "toy") drag = null;
    toyKind = k;
    toy.angle = 0;
    placeToyInBox();
    if (["chase", "climb", "trophy"].includes(act)) { climbView.snap(0); hold.target = 0; air = true; velX = 0; velY = 0; go("air", newD({ then: "land" })); }
  }

  // boot
  resize();
  raw = { x: W * 0.3, y: H * 0.5 }; ptrX = raw.x; ptrY = raw.y;
  go("inBox", newD({ next: WEB.firstOut }));
  visitAt = rnd(...WEB.visit);
  d.peek = new Spring(0.95, 3, 0.55);
  placeInBox(0.95);
  initTail();
  setToy(opts.toy === undefined ? "miniShark" : opts.toy);
  if (opts.debugPose) { act = "sit"; boxClip = null; boxShow.snap(0); pos.x = W / 2; pos.y = 0; initTail(); }
  new ResizeObserver(resize).observe(stage);
  requestAnimationFrame(frame);

  // for poking at it from the console
  window.__deskcat = { get act() { return act; }, pos, toy, box, audio, get W() { return W; }, get H() { return H; } };
  return {
    isHome, letOut, callHome, setToy, setCoat, drawToyIcon,
    setMuted(m) { audio.muted = m; applyVolume(); if (!m) audioStart(); },
    setVolume(v) { audio.volume = clamp01(v); applyVolume(); },
    setName(n) { catName = String(n).trim().slice(0, 14); },
  };
} };
