// A camera session in the browser: MediaPipe finds the joints, conductor.js counts and times
// exactly like the iPhone app, Lele answers what the person says, and the result goes to the
// same /v1/sessions endpoint, so the physio's portal and Lele see it like any phone session.

import { Conductor, Cue, actionName, frameAngle, isHold, jointName, setupGuidance, trackedAngle } from '/app/conductor.js';

const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const MP_VERSION = '0.10.14';
const MP_BASE = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${MP_VERSION}`;
const MODEL = 'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task';
const LANDMARKS = {
  leftShoulder: 11, rightShoulder: 12, leftElbow: 13, rightElbow: 14, leftWrist: 15, rightWrist: 16,
  leftHip: 23, rightHip: 24, leftKnee: 25, rightKnee: 26, leftAnkle: 27, rightAnkle: 28,
};
const BONES = [['leftShoulder', 'rightShoulder'], ['leftShoulder', 'leftElbow'], ['leftElbow', 'leftWrist'], ['rightShoulder', 'rightElbow'],
  ['rightElbow', 'rightWrist'], ['leftShoulder', 'leftHip'], ['rightShoulder', 'rightHip'], ['leftHip', 'rightHip'], ['leftHip', 'leftKnee'],
  ['leftKnee', 'leftAnkle'], ['rightHip', 'rightKnee'], ['rightKnee', 'rightAnkle']];

let landmarkerPromise = null;

function loadLandmarker() {
  landmarkerPromise ??= (async () => {
    const vision = await import(/* @vite-ignore */ `${MP_BASE}/vision_bundle.mjs`);
    const fileset = await vision.FilesetResolver.forVisionTasks(`${MP_BASE}/wasm`);
    const options = (delegate) => ({ baseOptions: { modelAssetPath: MODEL, delegate }, runningMode: 'VIDEO', numPoses: 1 });
    try {
      return await vision.PoseLandmarker.createFromOptions(fileset, options('GPU'));
    } catch {
      return vision.PoseLandmarker.createFromOptions(fileset, options('CPU'));
    }
  })();
  landmarkerPromise.catch(() => { landmarkerPromise = null; });
  return landmarkerPromise;
}

// MARK: The coach's voice

/// Lele's ElevenLabs voice, the same one the iPhone app uses. Lines come from the server's
/// /v1/voice/speak, which renders each line once and caches it for everyone. Audio plays through
/// Web Audio, unlocked by the tap that starts the session. If a line can't be fetched the caption
/// still shows, and the session waits a moment so it can be read.
class Voice {
  constructor(fetchAudio, onSpeakingChanged) {
    this.fetchAudio = fetchAudio;
    this.onSpeakingChanged = onSpeakingChanged;
    this.onCaption = () => {};
    this.ctx = null;
    this.cache = new Map();
    this.queue = [];
    this.busy = false;
    this.stopped = false;
    this.current = null;
    this.currentCount = null;
  }

  /// Call from a tap: browsers only allow sound after the person has interacted.
  unlock() {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return;
    this.ctx ??= new Context();
    this.ctx.resume?.().catch(() => {});
    const silence = this.ctx.createBufferSource();
    silence.buffer = this.ctx.createBuffer(1, 1, 22050);
    silence.connect(this.ctx.destination);
    silence.start(0);
  }

  load(text) {
    if (!this.cache.has(text)) {
      const pending = this.ctx
        ? this.fetchAudio(text).then((data) => this.ctx.decodeAudioData(data)).catch(() => null)
        : Promise.resolve(null);
      this.cache.set(text, pending);
      pending.then((buffer) => { if (!buffer) this.cache.delete(text); });
    }
    return this.cache.get(text);
  }

  /// Fetches the session's lines a few at a time, in the order they'll be needed.
  async prefetch(texts, parallel = 4) {
    const list = [...new Set(texts)];
    let next = 0;
    const worker = async () => {
      while (next < list.length && !this.stopped) await this.load(list[next++]);
    };
    await Promise.all(Array.from({ length: parallel }, worker));
  }

  /// Counts never talk over the coach and are skipped if not ready; everything else queues, and
  /// the session waits for it to finish before handing the turn back, like the phone.
  say(line) {
    if (this.stopped) return;
    if (line.priority === 'low') {
      if (this.busy) return;
      const ready = this.cache.get(line.text);
      if (!ready) { this.load(line.text); return; }
      ready.then((buffer) => {
        if (!buffer || this.busy || this.stopped) return;
        try { this.currentCount?.stop(); } catch { /* already ended */ }
        this.currentCount = this.play(buffer).source;
      });
      return;
    }
    if (line.priority === 'high') this.queue.unshift(line); else this.queue.push(line);
    this.load(line.text);
    if (!this.busy) {
      this.busy = true;
      this.onSpeakingChanged(true);
      this.next();
    }
  }

  async next() {
    const line = this.queue.shift();
    if (!line || this.stopped) {
      this.busy = false;
      if (!this.stopped) this.onSpeakingChanged(false);
      return;
    }
    const buffer = await Promise.race([this.load(line.text), new Promise((resolve) => setTimeout(() => resolve(null), 8000))]);
    if (this.stopped) return;
    this.onCaption(line.text);
    if (buffer && this.ctx) {
      try { this.currentCount?.stop(); } catch { /* already ended */ }
      await this.play(buffer).ended;
    } else {
      await new Promise((resolve) => setTimeout(resolve, Math.min(4000, 800 + line.text.length * 35)));
    }
    this.next();
  }

  play(buffer) {
    const source = this.ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(this.ctx.destination);
    const ended = new Promise((resolve) => { source.onended = resolve; });
    source.start(0);
    this.current = source;
    return { source, ended };
  }

  /// Drops lines that haven't started yet (after a skip they're about the wrong exercise).
  clearQueue() { this.queue = []; }

  stop() {
    this.stopped = true;
    this.queue = [];
    for (const s of [this.current, this.currentCount]) { try { s?.stop(); } catch { /* already ended */ } }
    this.ctx?.close?.().catch(() => {});
    this.busy = false;
  }
}

/// Every line this session can say, first exercise first, so the voice is ready before it's
/// needed (LaileCore's CueCatalog.lines(for:)).
function linesFor(launch) {
  const plan = launch.plan;
  const first = [];
  const rest = [];
  if (launch.isCheckIn) first.push(CHECK_IN_INTRO.text);
  plan.forEach((p, i) => {
    const target = i === 0 ? first : rest;
    const tip = i === 0 || plan[i - 1].spec.posture !== p.spec.posture;
    target.push(Cue.intro(p.spec, i === 0).text);
    if (p.careCue) target.push(p.careCue.text);
    target.push(Cue.setup(p.spec, tip).text, Cue.go(p.spec).text);
    (p.spec.formChecks ?? []).forEach((c) => rest.push(c.cue));
    const correction = p.spec.kind.hold?._0?.correction;
    if (correction) rest.push(correction);
    const d = p.dose;
    if (d.sets > 1) {
      if (d.restSeconds >= 10) rest.push(Cue.restCheckIn(d.restSeconds).text);
      if (d.restSeconds > 10) rest.push(Cue.restFor(d.restSeconds).text);
      for (let n = 2; n <= d.sets; n += 1) rest.push(Cue.nextSet(n, d.sets, isHold(p.spec)).text);
    }
    if (d.holdSeconds > 30) for (let s = 35; s <= d.holdSeconds; s += 5) rest.push(Cue.seconds(s).text);
  });
  const maxCount = Math.min(30, Math.max(10, ...plan.map((p) => p.dose.reps ?? 0)));
  const counts = Array.from({ length: maxCount }, (_, i) => Cue.count(i + 1).text);
  const core = [Cue.holdIt, Cue.relax, Cue.niceWork, Cue.rest, Cue.further, Cue.cantSee, Cue.paused, Cue.resumed, Cue.sessionDone,
    Cue.easedReps(launch.mode === 'rehab'), Cue.easeAtFloor].map((l) => l.text);
  const setup = ['noPerson', 'tooFar', 'tooClose', 'offCenter', 'needSideView', 'needFrontView'].map((type) => setupGuidance({ type }).text);
  return [...first, ...counts.slice(0, 10), ...core, ...setup, ...rest, ...counts.slice(10)];
}

const CHECK_IN_INTRO = { text: "A quick check-in first. Go at a comfortable effort and tap That's enough when it feels right.", priority: 'normal' };

// MARK: Session

export async function runSession({ api, speech, query, onFinished }) {
  const params = new URLSearchParams(query).toString();
  const launch = await api('GET', `v1/sessions/plan?${params}`);
  if (!launch.plan.length) throw new Error('Nothing in this session fits your current limits. Ask Lele or your physio about it.');
  const askPain = launch.isSupervised || (!launch.enrollmentId && launch.mode === 'rehab');

  const root = document.createElement('div');
  root.className = 'session';
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-label', launch.title);
  root.innerHTML = `
    <div class="stage">
      <video playsinline muted></video>
      <canvas></canvas>
      <div class="hud">
        <div><h3 data-slot="exercise">${esc(launch.title)}</h3><div class="small" data-slot="sets"></div></div>
        <div class="small" data-slot="live">${launch.isSupervised ? '<span class="live-dot"></span>Your physio can follow live' : ''}</div>
      </div>
      <div class="say" data-slot="caption" hidden></div>
      <div class="count"><div class="n" data-slot="count"></div><div class="small" data-slot="count-label"></div></div>
      <div class="overlay" data-slot="overlay"></div>
    </div>
    <form class="bar" data-slot="bar" hidden>
      <input class="field" name="said" placeholder="Tell Lele how it feels" aria-label="Tell Lele how it feels" autocomplete="off" style="flex:2;min-width:180px">
      <button class="btn secondary" type="button" data-do="mic" hidden>Speak</button>
      <button class="btn secondary" type="submit">Tell Lele</button>
      <button class="btn secondary" type="button" data-do="easier">Make it easier</button>
      <button class="btn secondary" type="button" data-do="pause">Pause</button>
      <button class="btn secondary" type="button" data-do="skip">${launch.isCheckIn ? "That's enough" : 'Skip'}</button>
      <button class="btn danger" type="button" data-do="end">End</button>
    </form>`;
  document.body.appendChild(root);
  document.body.style.overflow = 'hidden';

  const $ = (slot) => root.querySelector(`[data-slot="${slot}"]`);
  const video = root.querySelector('video');
  const canvas = root.querySelector('canvas');
  const ctx = canvas.getContext('2d');
  const overlay = $('overlay');
  const bar = $('bar');

  let stream = null;
  let conductor = null;
  const voice = new Voice(speech, () => {});
  let painBefore = null;
  let stopped = false;
  let finished = false;
  let lastHeard = '';
  let lastLive = 0;
  let lastVideoTime = -1;
  let ticker = null;
  let recognition = null;
  let telling = false;
  const clock = () => performance.now() / 1000;

  const cleanup = () => {
    stopped = true;
    clearInterval(ticker);
    voice.stop();
    try { recognition?.abort(); } catch { /* not running */ }
    stream?.getTracks().forEach((t) => t.stop());
    root.remove();
    document.body.style.overflow = '';
    document.removeEventListener('keydown', onKey);
  };

  const onKey = (e) => { if (e.key === 'Escape' && !conductor) { cleanup(); onFinished?.(null); } };
  document.addEventListener('keydown', onKey);

  const showOverlay = (html) => { overlay.innerHTML = `<div class="panel">${html}</div>`; overlay.hidden = false; };
  const hideOverlay = () => { overlay.hidden = true; overlay.innerHTML = ''; };

  const painPicker = (title, note, button) => `
    <h3>${title}</h3><p class="muted small">${note}</p>
    <input class="range" type="range" min="0" max="10" step="1" value="0" data-slot="pain" aria-label="Pain from 0 to 10">
    <div class="scale"><span>0 none</span><span data-slot="pain-value">0</span><span>10 worst</span></div>
    <div class="row" style="margin-top:14px"><button class="btn" data-do="${button}">Continue</button><button class="btn ghost" data-do="${button}-skip">Skip</button></div>`;

  // Step 1: what's in this session, then pain before (supervised), then the camera.
  const items = launch.plan.map((p) => {
    const d = p.dose;
    const what = d.reps ? `${d.sets} × ${d.reps}` : `${d.sets > 1 ? `${d.sets} × ` : ''}${d.holdSeconds}s`;
    return `<li><span>${esc(p.spec.name)}${p.careCue ? ' <span class="pill warm">eased</span>' : ''}</span><span class="muted small">${what}</span></li>`;
  }).join('');
  showOverlay(`
    <p class="eyebrow">${launch.isCheckIn ? 'Check-in' : 'Session'}</p>
    <h3 style="font-size:20px">${esc(launch.title)}</h3>
    ${launch.isCheckIn ? '<p class="small">A quick check-in first. Go at a comfortable effort and tap "That\'s enough" when it feels right. Laile sets your targets from it.</p>' : ''}
    <ul class="list">${items}</ul>
    <p class="muted small" style="margin-top:12px">Laile uses your camera to count reps and measure joint angles. The video stays on this device; only the numbers are saved. Set the screen two to three metres away so your whole body fits.</p>
    <div class="row" style="margin-top:14px"><button class="btn" data-do="begin">${askPain ? 'Next' : 'Turn on camera'}</button><button class="btn ghost" data-do="cancel">Not now</button></div>
    <p class="error" data-slot="error"></p>`);
  loadLandmarker().catch(() => {}); // start downloading the model while they read

  const startCamera = async () => {
    showOverlay('<h3>Starting the camera…</h3><p class="muted small">Allow camera access when your browser asks. The first time takes a few seconds to load the pose model.</p>');
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
    } catch (e) {
      showOverlay(`<h3>Laile needs the camera</h3><p class="small">${esc(e.name === 'NotAllowedError' ? 'Camera access was blocked. Allow it in your browser\'s site settings, then try again.' : 'No camera was found on this device.')}</p>
        <div class="row" style="margin-top:12px"><button class="btn" data-do="retry-camera">Try again</button><button class="btn ghost" data-do="cancel">Close</button></div>`);
      return;
    }
    video.srcObject = stream;
    // Never hang on a camera that is slow to deliver its first frame.
    await Promise.race([video.play().catch(() => {}), new Promise((resolve) => setTimeout(resolve, 1500))]);
    let landmarker;
    try {
      landmarker = await loadLandmarker();
    } catch {
      showOverlay('<h3>Couldn\'t load the pose model</h3><p class="small">Check your connection and try again.</p><div class="row"><button class="btn" data-do="retry-camera">Try again</button><button class="btn ghost" data-do="cancel">Close</button></div>');
      return;
    }
    hideOverlay();
    begin(landmarker);
  };

  const begin = (landmarker) => {
    bar.hidden = false;
    conductor = new Conductor(launch, clock());
    voice.onSpeakingChanged = (speaking) => handle(conductor.coachSpeechChanged(speaking, clock()));
    voice.onCaption = (text) => { const c = $('caption'); c.textContent = text; c.hidden = false; };
    if (launch.isCheckIn) voice.say(CHECK_IN_INTRO);
    handle(conductor.start(clock()));
    setupMic();
    ticker = setInterval(() => {
      if (stopped || !conductor) return;
      handle(conductor.tick(clock()));
      postLive(false);
      paint();
    }, 100);
    const loop = () => {
      if (stopped || finished) return;
      if (video.readyState >= 2 && video.currentTime !== lastVideoTime) {
        lastVideoTime = video.currentTime;
        let result = null;
        try { result = landmarker.detectForVideo(video, performance.now()); } catch { /* skip a frame */ }
        const frame = toFrame(result, clock());
        handle(conductor.process(frame));
        draw(result);
      }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  };

  const toFrame = (result, t) => {
    const aspect = (video.videoWidth || 16) / (video.videoHeight || 9);
    const lm = {};
    const points = result?.landmarks?.[0];
    if (points) {
      for (const [name, i] of Object.entries(LANDMARKS)) {
        const p = points[i];
        if (p) lm[name] = { x: p.x, y: p.y, c: p.visibility ?? 0 };
      }
    }
    return { t, aspect, lm };
  };

  const draw = (result) => {
    const w = video.videoWidth, h = video.videoHeight;
    if (!w || !h) return;
    if (canvas.width !== w) { canvas.width = w; canvas.height = h; }
    ctx.clearRect(0, 0, w, h);
    const points = result?.landmarks?.[0];
    if (!points) return;
    const planned = conductor?.currentExercise;
    const def = planned ? trackedAngle(planned.spec) : null;
    const side = conductor?.side;
    const tracked = new Set(def && side ? [def.from, def.vertex, def.to].map((p) => jointName(p, side)) : []);
    const at = (name) => { const p = points[LANDMARKS[name]]; return p && (p.visibility ?? 0) >= 0.3 ? [p.x * w, p.y * h] : null; };
    ctx.lineCap = 'round';
    for (const [a, b] of BONES) {
      const pa = at(a), pb = at(b);
      if (!pa || !pb) continue;
      const strong = tracked.has(a) && tracked.has(b);
      ctx.strokeStyle = strong ? '#3CC49B' : 'rgba(255,255,255,0.55)';
      ctx.lineWidth = strong ? 8 : 4;
      ctx.beginPath(); ctx.moveTo(...pa); ctx.lineTo(...pb); ctx.stroke();
    }
    for (const name of Object.keys(LANDMARKS)) {
      const p = at(name);
      if (!p) continue;
      ctx.fillStyle = tracked.has(name) ? '#3CC49B' : '#ffffff';
      ctx.beginPath(); ctx.arc(p[0], p[1], tracked.has(name) ? 9 : 5, 0, Math.PI * 2); ctx.fill();
    }
  };

  const angleLabel = (s) => {
    const planned = conductor?.currentExercise;
    if (s.angle == null || !planned) return null;
    const def = trackedAngle(planned.spec);
    if (!def) return null;
    const rule = planned.spec.kind.reps?._0;
    if (def.vertex === 'knee' && rule && rule.target < rule.start) return `Knee bent to ${Math.round(180 - s.angle)}°`;
    if (def.from === 'hip' && def.vertex === 'shoulder' && def.to === 'wrist') return `Arm lifted to ${Math.round(s.angle)}°`;
    return `${def.vertex[0].toUpperCase()}${def.vertex.slice(1)} at ${Math.round(s.angle)}°`;
  };

  const phaseLabel = (p) => ({ setup: 'setting up', active: 'exercising', rest: 'resting', paused: 'paused', finished: 'finished' }[p.name] ?? p.name);

  const postLive = (ended) => {
    if (!launch.isSupervised || !conductor) return;
    const now = clock();
    if (!ended && now - lastLive < 2) return;
    lastLive = now;
    const s = conductor.snapshot;
    api('POST', 'v1/sessions/live', {
      sessionTitle: launch.title, exerciseName: s.exerciseName, exerciseIndex: s.exerciseIndex, exerciseCount: s.exerciseCount,
      setIndex: s.setIndex, totalSets: s.totalSets, phase: phaseLabel(s.phase), reps: s.reps, targetReps: s.targetReps,
      holdSeconds: Math.floor(s.holdSeconds), targetHoldSeconds: s.isHold ? s.targetHoldSeconds : null, angleLabel: angleLabel(s),
      lastHeard: lastHeard || null, symptomsLogged: conductor.symptoms.length, ended,
    }).catch(() => {});
  };

  const paint = () => {
    if (!conductor || finished) return;
    const s = conductor.snapshot;
    $('exercise').textContent = s.exerciseName || launch.title;
    $('sets').textContent = s.totalSets ? `Exercise ${Math.min(s.exerciseIndex + 1, s.exerciseCount)} of ${s.exerciseCount} · set ${s.setIndex + 1} of ${s.totalSets}` : '';
    const label = angleLabel(s);
    if (s.phase.name === 'rest') {
      $('count').textContent = `${s.restRemaining}`;
      $('count-label').textContent = 'seconds rest';
    } else if (s.phase.name === 'setup') {
      $('count').textContent = '';
      $('count-label').textContent = s.setupIssues.length ? 'Getting you in frame' : 'Hold still';
    } else if (s.isHold) {
      $('count').textContent = `${Math.floor(s.holdSeconds)}s`;
      $('count-label').textContent = `of ${s.targetHoldSeconds ?? ''}s${s.isHolding ? ' · holding' : ''}`;
    } else {
      $('count').textContent = `${s.reps}`;
      $('count-label').textContent = `of ${s.targetReps ?? '∞'} reps${label ? ` · ${label}` : ''}`;
    }
    const pauseButton = bar.querySelector('[data-do="pause"]');
    pauseButton.textContent = s.phase.name === 'paused' && s.phase.reason === 'user' ? 'Resume' : 'Pause';
    if (telling) return;
    if (conductor.isAwaitingPainRating && overlay.hidden) {
      showOverlay(`<h3>From 0 to 10, how bad is it?</h3><div class="chips">${Array.from({ length: 11 }, (_, n) => `<button class="chip" data-do="rate" data-n="${n}">${n}</button>`).join('')}</div>`);
    } else if (conductor.isClarifying && overlay.hidden) {
      showOverlay(`<h3>Is it a stretch, or sharp pain?</h3><div class="chips">
        <button class="chip" data-do="clarify" data-text="It's just a stretch">Just a stretch</button>
        <button class="chip" data-do="clarify" data-text="It's sharp pain">Sharp pain</button>
        <button class="chip" data-do="clarify" data-text="It feels fine now">Fine now</button></div>`);
    } else if (!conductor.isAwaitingPainRating && !conductor.isClarifying && overlay.dataset.kind !== 'keep' && !overlay.hidden && conductor.phase.name !== 'finished') {
      hideOverlay();
    }
  };

  const handle = (events) => {
    if (!events?.length || stopped) return;
    for (const e of events) {
      if (e.type === 'say') voice.say(e.line);
      if (e.type === 'finished') { finished = true; setTimeout(() => finish(), 400); }
    }
    paint();
  };

  // MARK: Talking to Lele mid-session

  const tell = async (text, source = 'typed') => {
    const utterance = String(text || '').trim();
    if (!utterance || telling || !conductor || finished) return;
    telling = true;
    lastHeard = utterance;
    const s = conductor.snapshot;
    const planned = conductor.currentExercise;
    const context = {
      exerciseName: s.exerciseName || null, exerciseId: planned?.spec.id ?? null, setIndex: s.setIndex, totalSets: s.totalSets,
      reps: s.reps, holdSeconds: Math.floor(s.holdSeconds), angle: s.angle, phase: phaseLabel(s.phase), awaitingPainRating: conductor.isAwaitingPainRating,
    };
    try {
      const turn = await api('POST', 'v1/voice/turn', { utterance, context });
      // "Make it easier": the session eases the exercise and says how; their words are kept.
      if (turn.ease) {
        hideOverlay();
        handle(conductor.ease(utterance, source, clock()));
        telling = false;
        paint();
        return;
      }
      // Lele's answer first, then whatever the session does next (the next exercise's intro).
      if (turn.reply) voice.say({ text: turn.reply, priority: 'high' });
      if (turn.report) {
        const report = { ...turn.report, source };
        if (planned && !report.side && planned.side) report.side = planned.side;
        hideOverlay();
        handle(conductor.report(report, clock()));
      }
    } catch {
      voice.say({ text: 'I didn\'t catch that. If something hurts, stop and tap End.', priority: 'high' });
    }
    telling = false;
    paint();
  };

  const setupMic = () => {
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    const mic = bar.querySelector('[data-do="mic"]');
    if (!Recognition) return;
    mic.hidden = false;
    mic.addEventListener('click', () => {
      try {
        recognition = new Recognition();
        recognition.lang = 'en-SG';
        recognition.interimResults = false;
        recognition.maxAlternatives = 1;
        recognition.onresult = (e) => { const said = e.results?.[0]?.[0]?.transcript; if (said) tell(said, 'voiceOnDevice'); };
        recognition.onend = () => { mic.textContent = 'Speak'; };
        mic.textContent = 'Listening…';
        recognition.start();
      } catch { mic.textContent = 'Speak'; }
    });
  };

  // MARK: Finishing

  // The coach keeps talking (an emergency line must be heard in full); only the camera stops.
  const finish = () => {
    clearInterval(ticker);
    stream?.getTracks().forEach((t) => t.stop());
    bar.hidden = true;
    $('caption').hidden = true;
    postLive(true);
    const escalation = conductor.escalation;
    if (escalation === 'emergency') {
      overlay.dataset.kind = 'keep';
      showOverlay(`<div class="card alert"><h3>Stop now and get help</h3><p>${esc(launch.policy.emergencyNumber ? `Call ${launch.policy.emergencyNumber} for an ambulance, or ask someone nearby to help you.` : 'Call emergency services now.')}</p>
        <a class="btn danger block" href="tel:${esc(launch.policy.emergencyNumber || '995')}">Call ${esc(launch.policy.emergencyNumber || '995')}</a></div>
        <button class="btn ghost block" data-do="save">Save what happened</button>`);
      return;
    }
    if (askPain) {
      overlay.dataset.kind = 'keep';
      showOverlay(painPicker('How much pain do you have now?', 'Your physio sees this next to how you felt before.', 'pain-after'));
      return;
    }
    submit(null);
  };

  const submit = async (painAfter) => {
    overlay.dataset.kind = 'keep';
    showOverlay('<h3>Saving your session…</h3>');
    const summary = conductor.summary(painBefore, painAfter);
    try {
      const result = await api('POST', 'v1/sessions', summary);
      showResult(summary, result);
    } catch (e) {
      showOverlay(`<h3>Couldn't save the session</h3><p class="small">${esc(e.message)}</p>
        <div class="row"><button class="btn" data-do="save-retry">Try again</button><button class="btn ghost" data-do="close">Close without saving</button></div>`);
      root.dataset.pendingPain = painAfter ?? '';
    }
  };

  const showResult = (summary, result) => {
    const names = Object.fromEntries(launch.plan.map((p) => [p.spec.id, p.spec.name]));
    const rows = summary.exercises.map((x) => {
      const reps = x.repsPerSet.reduce((a, b) => a + b, 0);
      const held = x.holdSecondsPerSet.reduce((a, b) => a + b, 0);
      const what = reps ? `${x.repsPerSet.join(' + ')} reps` : held ? `${x.holdSecondsPerSet.length} × ${Math.round(held / Math.max(1, x.holdSecondsPerSet.length))}s held` : 'skipped';
      const stop = x.stopReason === 'symptom' ? ' · stopped for how it felt' : '';
      return `<li><span>${esc(names[x.exerciseId] ?? x.exerciseId)}</span><span class="muted small">${what}${stop}</span></li>`;
    }).join('');
    const badges = (result.movement?.newBadges ?? []).map((b) => `<span class="pill warm">${esc(b.title)}</span>`).join(' ');
    const notes = (result.careNotes ?? []).map((n) => `<li>${esc(n.text)}</li>`).join('');
    const careTeam = summary.escalation === 'contactCareTeamToday'
      ? '<div class="card alert"><p class="small"><strong>Contact your care team or a doctor today</strong> about what you reported.</p></div>' : '';
    overlay.dataset.kind = 'keep';
    showOverlay(`
      <p class="eyebrow">Saved</p><h3 style="font-size:20px">${esc(launch.title)}</h3>
      ${careTeam}
      <ul class="list">${rows}</ul>
      <p class="small" style="margin-top:10px">+${result.movement?.xpAwarded ?? 0} XP · ${result.movement?.moveStreak?.current ?? 0}-day move streak ${badges}</p>
      ${notes ? `<p class="small"><strong>Lele noted</strong></p><ul class="small">${notes}</ul>` : ''}
      ${launch.isSupervised ? '<p class="muted small">Your physio sees this in the Laile portal, with anything you told Lele.</p>' : ''}
      <button class="btn block" data-do="done" style="margin-top:8px">Done</button>`);
    root.dataset.result = '1';
    root._result = result;
  };

  // MARK: Controls

  root.addEventListener('input', (e) => {
    if (e.target.matches('[data-slot="pain"]')) $('pain-value').textContent = e.target.value;
  });

  root.addEventListener('submit', (e) => {
    e.preventDefault();
    const input = bar.querySelector('input[name="said"]');
    const text = input.value;
    input.value = '';
    tell(text);
  });

  root.addEventListener('click', (e) => {
    const el = e.target.closest('[data-do]');
    if (!el) return;
    e.preventDefault();
    const now = clock();
    const pain = () => Number(root.querySelector('[data-slot="pain"]')?.value ?? 0);
    switch (el.dataset.do) {
      case 'cancel':
      case 'close':
        cleanup();
        onFinished?.(null);
        break;
      case 'begin':
        voice.unlock();
        voice.prefetch(linesFor(launch));
        if (askPain) showOverlay(painPicker('Before you start: any pain right now?', '0 is none, 10 is the worst you can imagine. Your physio sees how this changes.', 'pain-before'));
        else startCamera();
        break;
      case 'pain-before': painBefore = pain(); startCamera(); break;
      case 'pain-before-skip': startCamera(); break;
      case 'retry-camera': startCamera(); break;
      case 'pause':
        if (!conductor) break;
        handle(conductor.phase.name === 'paused' ? conductor.resume(now) : conductor.pause(now, 'user'));
        break;
      case 'skip':
        if (conductor) { voice.clearQueue(); handle(conductor.skipExercise(now)); }
        break;
      case 'end':
        if (conductor && confirm('End the session now? What you did so far is saved.')) handle(conductor.endSession(now));
        break;
      case 'easier': if (conductor && !finished) handle(conductor.ease('Make it easier (tapped)', 'tapped', now)); break;
      case 'rate': hideOverlay(); tell(`${el.dataset.n} out of 10`); break;
      case 'clarify': hideOverlay(); tell(el.dataset.text); break;
      case 'mic': break;
      case 'pain-after': submit(pain()); break;
      case 'pain-after-skip': submit(null); break;
      case 'save': submit(null); break;
      case 'save-retry': submit(root.dataset.pendingPain === '' ? null : Number(root.dataset.pendingPain)); break;
      case 'done': {
        const result = root._result;
        cleanup();
        onFinished?.(result);
        break;
      }
      default: break;
    }
  });

  // Exposed for testing in a browser without a camera: feed synthetic frames.
  window.__laileSession = {
    get conductor() { return conductor; },
    feed: (frame) => conductor && handle(conductor.process({ ...frame, t: clock() })),
    angle: (frame, def, side) => frameAngle(frame, def, side),
    actionName,
  };
}
