// The session engine, ported line for line from LaileCore's SessionConductor, RepCounter,
// HoldTimer and SetupCheck so a browser session counts, pauses and reports exactly like the
// iPhone app. Pure logic: frames and time in, events out. No DOM, no camera.

export const MIN_CONFIDENCE = 0.3;

const NUMBER_WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty'];

const line = (text, priority = 'normal') => ({ text, priority });
export const Cue = {
  count: (n) => line(n < NUMBER_WORDS.length ? NUMBER_WORDS[n][0].toUpperCase() + NUMBER_WORDS[n].slice(1) : String(n), 'low'),
  seconds: (n) => line(`${n} seconds`, 'low'),
  resumed: line('Welcome back. Carry on whenever you\'re ready.'),
  holdIt: line('Hold it there.'),
  relax: line('And relax.'),
  niceWork: line('Nice work.'),
  rest: line('Rest.'),
  sessionDone: line('That\'s the session done. Great work today.'),
  cantSee: line('I can\'t see you clearly, so I\'m not counting that. Check the camera.'),
  paused: line('Paused. Take your time.'),
  further: line('A little further if it\'s comfortable.'),
  intro: (spec, first) => line(`${first ? 'First up' : 'Next'}: ${spec.name}. ${spec.cues.purpose}`),
  setup: (spec, tip) => line(tip ? `${spec.cues.setup} ${cameraTip(spec.posture)}` : spec.cues.setup),
  go: (spec) => line(`Perfect, I can see you. ${spec.cues.go} In your own time.`),
  nextSet: (n, total, hold) => {
    const w = (x) => (x < NUMBER_WORDS.length ? NUMBER_WORDS[x] : String(x));
    return line(`Set ${w(n)} of ${w(total)}. ${hold ? 'Get back into position' : 'Start'} whenever you're ready.`);
  },
  restCheckIn: (s) => line(`Nice. Take ${s} seconds. How did that feel?`),
  restFor: (s) => line(`Nice. Rest for ${s} seconds.`),
  easedReps: (supervised) => line("Of course. I've made it a little easier, so a smaller movement counts now. Go as far as is comfortable."
    + (supervised ? ' Your physio will see that you asked.' : '')),
  easedHold: (s) => line(`Of course. The hold is shorter now, ${s} seconds.`),
  easeAtFloor: line("That's as easy as I can make it today. Go as far as is comfortable, and tell me if anything hurts."),
};

// The phone's camera tips, worded for a laptop or phone browser.
function cameraTip(posture) {
  return {
    standing: 'Stand the screen up at waist height, about two to three metres away.',
    seated: 'Put the screen at chair height, about two metres away.',
    supine: 'Prop the screen on a chair beside your bed, level with the mattress.',
    plank: 'Put the screen on the floor, about two metres to your side.',
    kneeling: 'Put the screen low, about two metres away.',
  }[posture] ?? '';
}

const SPOKEN = { shoulder: 'shoulder', elbow: 'elbow', wrist: 'wrist', hip: 'hip', knee: 'knee', ankle: 'ankle' };

export function setupGuidance(issue) {
  switch (issue.type) {
    case 'noPerson': return line('I can\'t see anyone yet. Step into the frame.');
    case 'partsNotVisible':
      return issue.parts.length === 1
        ? line(`I can't see your ${SPOKEN[issue.parts[0]]}. Move the screen back a little, or shift so it's in view.`)
        : line('I can\'t see all of the joints I need. Move the screen back a little so your whole body is in view.');
    case 'tooClose': return line('You\'re a bit close. Move the screen further away.');
    case 'tooFar': return line('You\'re quite far away. Bring the screen a little closer.');
    case 'offCenter': return line('Shift over so you\'re in the middle of the screen.');
    case 'needSideView': return line('Turn so your side faces the screen.');
    case 'needFrontView': return line('Turn to face the screen.');
    default: return line('Check the camera.');
  }
}

// MARK: Pose geometry. A frame is { t, aspect, lm: { leftKnee: { x, y, c }, ... } } in
// normalised image coordinates; x is scaled by the aspect ratio for angles, like PoseFrame.metricPoint.

export const jointName = (part, side) => side + part[0].toUpperCase() + part.slice(1);

function landmark(frame, name, minC = MIN_CONFIDENCE) {
  const l = frame.lm[name];
  return l && l.c >= minC ? l : null;
}

function metricPoint(frame, name, minC) {
  const l = landmark(frame, name, minC);
  return l ? { x: l.x * frame.aspect, y: l.y } : null;
}

const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export function interiorAngle(a, v, b) {
  const v1 = [a.x - v.x, a.y - v.y], v2 = [b.x - v.x, b.y - v.y];
  const m1 = Math.hypot(...v1), m2 = Math.hypot(...v2);
  if (m1 < 1e-9 || m2 < 1e-9) return 0;
  const cos = Math.max(-1, Math.min(1, (v1[0] * v2[0] + v1[1] * v2[1]) / (m1 * m2)));
  return (Math.acos(cos) * 180) / Math.PI;
}

export function frameAngle(frame, def, side, minC = MIN_CONFIDENCE) {
  const a = metricPoint(frame, jointName(def.from, side), minC);
  const v = metricPoint(frame, jointName(def.vertex, side), minC);
  const b = metricPoint(frame, jointName(def.to, side), minC);
  return a && v && b ? interiorAngle(a, v, b) : null;
}

function meanConfidence(frame, parts, side) {
  if (!parts.length) return 0;
  return parts.reduce((sum, p) => sum + (frame.lm[jointName(p, side)]?.c ?? 0), 0) / parts.length;
}

export function trackedAngle(spec) {
  const kind = spec.kind;
  if (kind.reps) return kind.reps._0.angle;
  if (kind.hold) return kind.hold._0.angle ?? null;
  return null;
}

export const isHold = (spec) => Boolean(spec.kind.hold);

const PART_ORDER = ['shoulder', 'elbow', 'wrist', 'hip', 'knee', 'ankle'];

export function requiredParts(spec) {
  const parts = new Set();
  const tracked = trackedAngle(spec);
  if (tracked) [tracked.from, tracked.vertex, tracked.to].forEach((p) => parts.add(p));
  (spec.formChecks ?? []).forEach((c) => [c.angle.from, c.angle.vertex, c.angle.to].forEach((p) => parts.add(p)));
  if (!parts.size) { parts.add('shoulder'); parts.add('hip'); }
  return PART_ORDER.filter((p) => parts.has(p));
}

export function conditionMet(condition, angle) {
  if (condition.atLeast) return angle >= condition.atLeast._0;
  if (condition.atMost) return angle <= condition.atMost._0;
  if (condition.between) return angle >= condition.between._0 && angle <= condition.between._1;
  return true;
}

function viewOrientation(frame, minC) {
  const ls = metricPoint(frame, 'leftShoulder', minC), rs = metricPoint(frame, 'rightShoulder', minC);
  const lh = metricPoint(frame, 'leftHip', minC), rh = metricPoint(frame, 'rightHip', minC);
  const shoulder = ls ?? rs, hip = lh ?? rh;
  if (!shoulder || !hip) return null;
  const torso = distance(shoulder, hip);
  if (torso <= 0.02) return null;
  if (!ls || !rs) return 'side';
  const ratio = distance(ls, rs) / torso;
  if (ratio < 0.3) return 'side';
  if (ratio > 0.45) return 'front';
  return null;
}

export function setupCheck(frame, spec, preferredSide, minC = MIN_CONFIDENCE) {
  const parts = requiredParts(spec);
  const visible = Object.values(frame.lm).filter((l) => l.c >= minC);
  if (visible.length < 4) return { isReady: false, issues: [{ type: 'noPerson' }], side: preferredSide ?? 'left' };
  const side = preferredSide ?? (meanConfidence(frame, parts, 'left') >= meanConfidence(frame, parts, 'right') ? 'left' : 'right');
  const issues = [];
  const missing = parts.filter((p) => !landmark(frame, jointName(p, side), minC));
  const xs = visible.map((l) => l.x), ys = visible.map((l) => l.y);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const touchesEdge = minX < 0.02 || maxX > 0.98 || minY < 0.02 || maxY > 0.98;
  if (missing.length) issues.push(touchesEdge ? { type: 'tooClose' } : { type: 'partsNotVisible', parts: missing });
  else if (Math.max(maxX - minX, maxY - minY) < 0.3) issues.push({ type: 'tooFar' });
  const centerX = (minX + maxX) / 2;
  if (centerX < 0.22 || centerX > 0.78) issues.push({ type: 'offCenter' });
  const orientation = viewOrientation(frame, minC);
  if (spec.cameraView === 'side' && orientation === 'front') issues.push({ type: 'needSideView' });
  if (spec.cameraView === 'front' && orientation === 'side') issues.push({ type: 'needFrontView' });
  return { isReady: issues.length === 0, issues, side };
}

// MARK: Counting

export class RepCounter {
  static startBand = 0.12;
  static leaveStartBand = 0.2;

  constructor(rule) {
    this.rule = rule;
    this.count = 0;
    this.partials = 0;
    this.currentProgress = 0;
    this.state = { name: 'waitingForStart' };
  }

  progress(angle) {
    const span = this.rule.target - this.rule.start;
    return Math.abs(span) < 1e-6 ? 0 : (angle - this.rule.start) / span;
  }

  get isAtStart() { return this.state.name === 'atStart'; }

  update(angle) {
    const p = this.progress(angle);
    this.currentProgress = p;
    const s = this.state;
    if (s.name === 'waitingForStart') {
      if (p <= RepCounter.startBand) this.state = { name: 'atStart' };
      return null;
    }
    if (s.name === 'atStart') {
      if (p > RepCounter.leaveStartBand) this.state = { name: 'inRep', peakProgress: p, peakAngle: angle, reachedTarget: p >= 1 };
      return null;
    }
    if (p > s.peakProgress) { s.peakProgress = p; s.peakAngle = angle; }
    if (p >= 1) s.reachedTarget = true;
    if (p <= RepCounter.startBand) {
      this.state = { name: 'atStart' };
      if (s.reachedTarget) { this.count += 1; return { type: 'rep', count: this.count, peakAngle: s.peakAngle }; }
      if (s.peakProgress >= this.rule.partialFraction) { this.partials += 1; return { type: 'partial', peakAngle: s.peakAngle }; }
    }
    return null;
  }

  interrupt() { if (this.state.name === 'inRep') this.state = { name: 'waitingForStart' }; }

  /// A new target mid-set ("make it easier"); a rep in progress is judged against it.
  retarget(target) {
    this.rule = { ...this.rule, target };
    if (this.state.name === 'inRep') {
      const peak = this.progress(this.state.peakAngle);
      this.state = { ...this.state, peakProgress: peak, reachedTarget: peak >= 1 };
    }
  }
}

export class HoldTimer {
  static grace = 0.5;
  static maxStep = 0.25;

  constructor(targetSeconds) {
    this.targetSeconds = targetSeconds;
    this.heldSeconds = 0;
    this.isHolding = false;
    this.lastTimestamp = null;
    this.lastSatisfiedAt = null;
  }

  get isComplete() { return this.heldSeconds >= this.targetSeconds; }

  /// A shorter hold mid-set; never at or below the time already held.
  retarget(seconds) { this.targetSeconds = Math.max(seconds, Math.floor(this.heldSeconds) + 1); }
  get wholeSeconds() { return Math.floor(this.heldSeconds); }

  update(satisfied, t) {
    const before = this.heldSeconds, wasHolding = this.isHolding, wasComplete = this.isComplete;
    if (satisfied) this.lastSatisfiedAt = t;
    const withinGrace = this.lastSatisfiedAt != null && t - this.lastSatisfiedAt <= HoldTimer.grace;
    this.isHolding = satisfied || (wasHolding && withinGrace);
    if (this.isHolding && this.lastTimestamp != null && !this.isComplete) {
      const step = Math.min(Math.max(0, t - this.lastTimestamp), HoldTimer.maxStep);
      this.heldSeconds = Math.min(this.targetSeconds, this.heldSeconds + step);
    }
    this.lastTimestamp = t;
    const crossed = [];
    for (let s = Math.floor(before) + 1; s <= Math.floor(this.heldSeconds); s += 1) crossed.push(s);
    return { crossed, completed: !wasComplete && this.isComplete, startedHolding: !wasHolding && this.isHolding, stoppedHolding: wasHolding && !this.isHolding };
  }
}

// MARK: Conductor

const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
  const r = (Math.random() * 16) | 0;
  return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
}));

/// The server reads dates as ISO 8601 without fractions of a second.
const iso = (d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

export const actionName = (action) => (action ? Object.keys(action)[0] : 'continueExercise');

export class Conductor {
  /// `launch` is the server's WebSessionPlan; `t` is seconds on any steady clock.
  constructor(launch, t, startDate = new Date()) {
    this.launch = launch;
    this.plan = launch.plan;
    this.policy = launch.policy;
    this.config = { setupStableSeconds: 1, trackingLostSeconds: 2, formCueCooldown: 5, setupCueCooldown: 5 };
    this.phase = { name: 'setup' };
    this.exerciseIndex = 0;
    this.setIndex = 0;
    this.results = [];
    this.symptoms = [];
    this.escalation = null;
    this.lastAngle = null;
    this.setupIssues = [];
    this.startDate = startDate;
    this.startTime = t;
    this.now = t;
    this.side = null;
    this.current = null;
    this.repCounter = null;
    this.holdTimer = null;
    this.smoothed = null;
    this.setupReadySince = null;
    this.lastSetupCueAt = -Infinity;
    this.lastSeenAt = t;
    this.trackingLostAnnounced = false;
    this.formViolationSince = {};
    this.lastFormCueAt = {};
    this.lastPartialCueAt = -Infinity;
    this.lastCorrectionCueAt = -Infinity;
    this.phaseBeforePause = null;
    this.coachSpeaking = false;
    this.isCheckingIn = false;
    // Targets the person asked to make easier, for the current exercise only.
    this.easedRepTarget = null;
    this.easedHoldSeconds = null;
  }

  get currentExercise() { return this.plan[this.exerciseIndex] ?? null; }
  get isFinished() { return this.phase.name === 'finished'; }
  get isAwaitingPainRating() { return this.phase.name === 'paused' && this.phase.reason === 'awaitingPainRating'; }
  get isClarifying() { return this.phase.name === 'paused' && this.phase.reason === 'clarifying'; }

  get snapshot() {
    const planned = this.currentExercise;
    return {
      phase: this.phase,
      exerciseIndex: this.exerciseIndex,
      exerciseCount: this.plan.length,
      exerciseId: planned?.spec.id ?? null,
      exerciseName: planned?.spec.name ?? '',
      setIndex: this.setIndex,
      totalSets: planned?.dose.sets ?? 0,
      isHold: planned ? isHold(planned.spec) : false,
      reps: this.repCounter?.count ?? 0,
      targetReps: planned?.dose.reps ?? null,
      holdSeconds: this.holdTimer?.heldSeconds ?? 0,
      targetHoldSeconds: planned?.dose.holdSeconds ?? null,
      isHolding: this.holdTimer?.isHolding ?? false,
      angle: this.lastAngle,
      repProgress: this.repCounter?.currentProgress ?? 0,
      setupIssues: this.setupIssues,
      side: this.side,
      restRemaining: this.phase.name === 'rest' ? Math.max(0, Math.ceil(this.phase.until - this.now)) : null,
    };
  }

  repRule(planned) {
    if (!planned.spec.kind.reps) return null;
    const rule = { ...planned.spec.kind.reps._0 };
    if (planned.repTargetOverride != null) rule.target = planned.repTargetOverride;
    return rule;
  }

  start(t) {
    this.now = t;
    if (!this.plan.length) return this.finishSession();
    return this.enterSetup(true);
  }

  process(frame) {
    const events = this.tick(frame.t);
    if (this.phase.name === 'setup') events.push(...this.processSetup(frame));
    else if (this.phase.name === 'active') events.push(...this.processActive(frame));
    return events;
  }

  tick(t) {
    this.now = Math.max(this.now, t);
    const events = [];
    if (this.phase.name === 'rest' && this.now >= this.phase.until && !this.coachSpeaking) {
      this.setIndex += 1;
      this.beginSet();
      this.isCheckingIn = false;
      const planned = this.currentExercise;
      if (planned) events.push({ type: 'say', line: Cue.nextSet(this.setIndex + 1, planned.dose.sets, isHold(planned.spec)) });
      events.push(...this.beginActive());
    }
    return events;
  }

  coachSpeechChanged(speaking, t) {
    this.now = Math.max(this.now, t);
    this.coachSpeaking = speaking;
    return speaking ? [] : this.tick(this.now);
  }

  pause(t, reason = 'user') {
    this.now = Math.max(this.now, t);
    if (this.isFinished) return [];
    if (this.phase.name === 'paused') {
      this.phase = { name: 'paused', reason };
      return [{ type: 'phase' }];
    }
    this.phaseBeforePause = this.phase;
    this.phase = { name: 'paused', reason };
    const events = [{ type: 'phase' }];
    if (reason === 'user') events.push({ type: 'say', line: Cue.paused });
    return events;
  }

  resume(t) {
    this.now = Math.max(this.now, t);
    if (this.phase.name !== 'paused') return [];
    const reason = this.phase.reason;
    const previous = this.phaseBeforePause;
    this.phaseBeforePause = null;
    if (!previous || previous.name === 'setup') return this.enterSetup(false);
    if (previous.name === 'rest') { this.phase = previous; return [{ type: 'phase' }]; }
    this.repCounter?.interrupt();
    return [...(reason === 'user' ? [{ type: 'say', line: Cue.resumed }] : []), ...this.beginActive()];
  }

  skipExercise(t) {
    this.now = Math.max(this.now, t);
    if (this.isFinished) return [];
    this.closeCurrentSet();
    return this.finishExercise('skipped');
  }

  endSession(t) {
    this.now = Math.max(this.now, t);
    if (this.isFinished) return [];
    this.closeCurrentSet();
    if (this.current) {
      this.current.stopReason = 'userEnded';
      this.results.push(this.current);
      this.current = null;
    }
    return this.finishSession();
  }

  /// Something the person said, already classified by Lele on the server (which applied the
  /// program's pain limits). Context is attached here, and an answer to "0 to 10?" completes
  /// the earlier report so the physio sees one event.
  report(incoming, t) {
    this.now = Math.max(this.now, t);
    const report = { ...incoming };
    const planned = this.currentExercise;
    report.timestamp = iso(this.dateFor(this.now));
    report.exerciseId = report.exerciseId ?? planned?.spec.id;
    if (report.setIndex == null && planned) report.setIndex = this.setIndex;
    if (this.repCounter && report.repIndex == null) report.repIndex = this.repCounter.count + (this.repCounter.isAtStart ? 0 : 1);
    if (this.holdTimer && this.holdTimer.heldSeconds > 0 && report.holdSecond == null) report.holdSecond = this.holdTimer.wholeSeconds;
    if (report.angle == null && this.lastAngle != null) report.angle = this.lastAngle;

    if ((this.isAwaitingPainRating || this.isClarifying) && this.symptoms.length) {
      const previous = this.symptoms.pop();
      report.utterance = `${previous.utterance} → ${report.utterance}`;
      for (const key of ['bodyLocation', 'side', 'quality']) report[key] = report[key] ?? previous[key];
      for (const key of ['exerciseId', 'setIndex', 'repIndex', 'holdSecond', 'angle']) report[key] = previous[key] ?? report[key];
      report.timestamp = previous.timestamp;
      if (this.isAwaitingPainRating && report.category === 'normal' && (report.severity ?? 0) > 0) report.category = 'pain';
    }
    for (const key of Object.keys(report)) if (report[key] == null) delete report[key];
    this.symptoms.push(report);

    this.isCheckingIn = false;
    const events = [{ type: 'symptom', report }];
    const action = actionName(report.action);
    switch (action) {
      case 'continueExercise':
        if (this.phase.name === 'paused' && this.phase.reason !== 'user') events.push(...this.resume(this.now));
        break;
      case 'clarify':
        events.push(...this.pause(this.now, 'clarifying'));
        break;
      case 'pauseAndRate':
        events.push(...this.pause(this.now, 'awaitingPainRating'));
        break;
      case 'stopSet': {
        const effective = this.phase.name === 'paused' ? this.phaseBeforePause : this.phase;
        this.phaseBeforePause = null;
        if (effective?.name === 'active') {
          this.phase = { name: 'active' };
          events.push(...this.completeSet());
        } else {
          this.closeCurrentSet();
          events.push(...this.finishExercise('symptom'));
        }
        break;
      }
      case 'stopExercise':
        this.phaseBeforePause = null;
        this.closeCurrentSet();
        events.push(...this.finishExercise('symptom'));
        break;
      case 'endSession':
        this.escalation = report.action.endSession._0;
        this.closeCurrentSet();
        if (this.current) {
          this.current.stopReason = 'redFlag';
          this.results.push(this.current);
          this.current = null;
        }
        events.push(...this.finishSession(false));
        break;
      default: break;
    }
    return events;
  }

  /// The person asked for it to be easier ("I can't bend that far"): SessionConductor.ease. The rep
  /// target moves 10° towards the start, never below half its planned range; a hold gets a quarter
  /// shorter, never below half. Their words go into the summary for the physio.
  ease(utterance, source, t) {
    this.now = Math.max(this.now, t);
    const planned = this.currentExercise;
    if (!planned || this.isFinished) return [];
    let say = Cue.easeAtFloor;
    const rule = this.repRule(planned);
    if (rule) {
      const current = this.easedRepTarget ?? rule.target;
      const floor = rule.start + (rule.target - rule.start) * 0.5;
      const next = rule.target < rule.start ? Math.min(current + 10, floor) : Math.max(current - 10, floor);
      if (Math.abs(next - current) > 0.5) {
        this.easedRepTarget = next;
        this.repCounter?.retarget(next);
        say = Cue.easedReps(this.launch.mode === 'rehab');
      }
    } else if (isHold(planned.spec)) {
      const plan = plannedHold(planned);
      const current = this.easedHoldSeconds ?? plan;
      const next = Math.max(Math.max(2, Math.ceil(plan * 0.5)), Math.round(current * 0.75));
      if (next < current) {
        this.easedHoldSeconds = next;
        this.holdTimer?.retarget(next);
        say = Cue.easedHold(Math.floor(this.holdTimer?.targetSeconds ?? next));
      }
    }
    const report = {
      id: uuid(), timestamp: iso(this.dateFor(this.now)), category: 'effort', utterance,
      quality: say === Cue.easeAtFloor ? 'asked for it easier' : 'asked for it easier, target eased',
      source, exerciseId: planned.spec.id, setIndex: this.setIndex, action: { continueExercise: {} },
    };
    if (this.lastAngle != null) report.angle = this.lastAngle;
    if (this.repCounter) report.repIndex = this.repCounter.count + (this.repCounter.isAtStart ? 0 : 1);
    if (this.holdTimer && this.holdTimer.heldSeconds > 0) report.holdSecond = this.holdTimer.wholeSeconds;
    this.symptoms.push(report);
    const events = [{ type: 'symptom', report }, { type: 'say', line: say }];
    if (this.phase.name === 'paused' && this.phase.reason !== 'user') events.push(...this.resume(this.now));
    return events;
  }

  summary(painBefore, painAfter) {
    const s = {
      id: uuid(), kind: this.launch.kind, title: this.launch.title, mode: this.launch.mode,
      startedAt: iso(this.startDate), endedAt: iso(this.dateFor(this.now)),
      exercises: this.results, symptoms: this.symptoms,
    };
    if (this.launch.programId) s.programId = this.launch.programId;
    if (this.launch.templateId) s.templateId = this.launch.templateId;
    if (this.launch.enrollmentId) s.enrollmentId = this.launch.enrollmentId;
    if (painBefore != null) s.painBefore = painBefore;
    if (painAfter != null) s.painAfter = painAfter;
    if (this.escalation) s.escalation = this.escalation;
    return s;
  }

  // MARK: Phases

  enterSetup(introduce) {
    const planned = this.currentExercise;
    if (!planned) return this.finishSession();
    this.phase = { name: 'setup' };
    this.setupReadySince = null;
    this.lastSetupCueAt = this.now;
    if (!this.current) {
      this.current = newResult(planned);
      this.beginSet();
    }
    const events = [{ type: 'phase' }];
    if (introduce) {
      const previousPosture = this.exerciseIndex > 0 ? this.plan[this.exerciseIndex - 1].spec.posture : null;
      events.push({ type: 'say', line: Cue.intro(planned.spec, this.exerciseIndex === 0) });
      if (planned.careCue) events.push({ type: 'say', line: { text: planned.careCue.text, priority: 'normal' } });
      events.push({ type: 'say', line: Cue.setup(planned.spec, previousPosture !== planned.spec.posture) });
    }
    return events;
  }

  processSetup(frame) {
    const planned = this.currentExercise;
    if (!planned) return [];
    const status = setupCheck(frame, planned.spec, planned.side ?? null);
    this.setupIssues = status.issues;
    const events = [];
    if (status.isReady) {
      if (this.setupReadySince == null) this.setupReadySince = this.now;
      if (this.now - this.setupReadySince >= this.config.setupStableSeconds && !this.coachSpeaking) {
        this.side = status.side;
        this.current.side = status.side;
        this.setupIssues = [];
        events.push({ type: 'say', line: Cue.go(planned.spec) });
        events.push(...this.beginActive());
      }
    } else {
      this.setupReadySince = null;
      const issue = status.issues[0];
      if (issue && !this.coachSpeaking && this.now - this.lastSetupCueAt >= this.config.setupCueCooldown) {
        this.lastSetupCueAt = this.now;
        events.push({ type: 'say', line: setupGuidance(issue) });
      }
    }
    return events;
  }

  beginActive() {
    this.phase = { name: 'active' };
    this.lastSeenAt = this.now;
    return [{ type: 'phase' }];
  }

  beginSet() {
    const planned = this.currentExercise;
    if (!planned) return;
    const rule = this.repRule(planned);
    if (rule && this.easedRepTarget != null) rule.target = this.easedRepTarget;
    this.repCounter = rule ? new RepCounter(rule) : null;
    this.holdTimer = isHold(planned.spec) ? new HoldTimer(this.easedHoldSeconds ?? plannedHold(planned)) : null;
    this.formViolationSince = {};
    this.trackingLostAnnounced = false;
  }

  processActive(frame) {
    const planned = this.currentExercise;
    const side = this.side;
    if (!planned || !side) return [];
    const events = [];
    const definition = trackedAngle(planned.spec);
    let angle = null;
    if (definition) {
      const raw = frameAngle(frame, definition, side);
      if (raw != null) {
        this.smoothed = this.smoothed == null ? raw : this.smoothed + 0.35 * (raw - this.smoothed);
        angle = this.smoothed;
      }
    }
    const present = definition
      ? angle != null
      : setupCheck(frame, planned.spec, side).issues.every((i) => i.type !== 'noPerson');

    if (present) {
      this.lastSeenAt = this.now;
      this.trackingLostAnnounced = false;
    } else if (!this.trackingLostAnnounced && this.now - this.lastSeenAt >= this.config.trackingLostSeconds) {
      this.trackingLostAnnounced = true;
      this.repCounter?.interrupt();
      events.push({ type: 'trackingLost' }, { type: 'say', line: Cue.cantSee });
    }

    if (angle != null) {
      this.lastAngle = angle;
      this.current.minAngle = Math.min(this.current.minAngle ?? angle, angle);
      this.current.maxAngle = Math.max(this.current.maxAngle ?? angle, angle);
    }

    if (this.repCounter && angle != null) {
      const event = this.repCounter.update(angle);
      if (event?.type === 'rep') {
        this.current.repPeakAngles.push(event.peakAngle);
        events.push({ type: 'rep', count: event.count });
        if (event.count >= (planned.dose.reps ?? Infinity)) {
          events.push(...this.completeSet());
          return events;
        }
        events.push({ type: 'say', line: Cue.count(event.count) });
      } else if (event?.type === 'partial') {
        events.push({ type: 'partial' });
        if (this.now - this.lastPartialCueAt >= this.config.formCueCooldown) {
          this.lastPartialCueAt = this.now;
          events.push({ type: 'say', line: Cue.further });
        }
      }
    }

    if (this.holdTimer) {
      const rule = planned.spec.kind.hold?._0;
      const satisfied = rule?.condition ? (angle != null && conditionMet(rule.condition, angle)) : present;
      const update = this.holdTimer.update(satisfied, this.now);
      if (update.startedHolding && this.holdTimer.heldSeconds < 0.5) events.push({ type: 'say', line: Cue.holdIt });
      const target = Math.floor(this.holdTimer.targetSeconds);
      for (const second of update.crossed) {
        events.push({ type: 'hold', seconds: second, target });
        const cue = second < target ? holdCountLine(second, target) : null;
        if (cue) events.push({ type: 'say', line: cue });
      }
      if (update.stoppedHolding && rule?.correction && this.now - this.lastCorrectionCueAt >= this.config.formCueCooldown) {
        this.lastCorrectionCueAt = this.now;
        events.push({ type: 'say', line: { text: rule.correction, priority: 'normal' } });
      }
      if (update.completed) {
        events.push(...this.completeSet());
        return events;
      }
    }

    for (const check of planned.spec.formChecks ?? []) {
      const value = frameAngle(frame, check.angle, side);
      if (value == null) continue;
      if (conditionMet(check.condition, value)) { delete this.formViolationSince[check.id]; continue; }
      const since = this.formViolationSince[check.id] ?? this.now;
      this.formViolationSince[check.id] = since;
      if (this.now - since >= 0.6 && this.now - (this.lastFormCueAt[check.id] ?? -Infinity) >= this.config.formCueCooldown) {
        this.lastFormCueAt[check.id] = this.now;
        this.current.formWarnings += 1;
        events.push({ type: 'form', message: check.cue }, { type: 'say', line: { text: check.cue, priority: 'normal' } });
      }
    }
    return events;
  }

  closeCurrentSet() {
    if (!this.current) return;
    const recorded = Math.max(this.current.repsPerSet.length, this.current.holdSecondsPerSet.length) > this.setIndex;
    if (recorded) return;
    if (this.repCounter) {
      if (this.repCounter.count > 0 || this.repCounter.partials > 0) {
        this.current.repsPerSet.push(this.repCounter.count);
        this.current.partialReps += this.repCounter.partials;
      }
    } else if (this.holdTimer && this.holdTimer.wholeSeconds > 0) {
      this.current.holdSecondsPerSet.push(this.holdTimer.wholeSeconds);
    }
  }

  completeSet() {
    const planned = this.currentExercise;
    if (!planned) return [];
    if (this.repCounter) {
      this.current.repsPerSet.push(this.repCounter.count);
      this.current.partialReps += this.repCounter.partials;
    } else if (this.holdTimer) {
      this.current.holdSecondsPerSet.push(this.holdTimer.wholeSeconds);
    }
    const events = [{ type: 'setDone' }];
    const hold = isHold(planned.spec);
    if (hold) events.push({ type: 'say', line: Cue.relax });
    if (this.setIndex + 1 < planned.dose.sets) {
      const rest = planned.dose.restSeconds;
      this.phase = { name: 'rest', until: this.now + rest };
      events.push({ type: 'phase' });
      if (rest >= 10 && this.setIndex === 0) {
        this.isCheckingIn = true;
        events.push({ type: 'say', line: Cue.restCheckIn(rest) });
      } else if (rest > 10) {
        events.push({ type: 'say', line: Cue.restFor(rest) });
      } else if (!hold) {
        events.push({ type: 'say', line: Cue.rest });
      }
      return events;
    }
    events.push({ type: 'say', line: Cue.niceWork });
    return [...events, ...this.finishExercise(null)];
  }

  finishExercise(stopReason) {
    const events = [];
    if (this.current) {
      if (stopReason) this.current.stopReason = stopReason;
      this.results.push(this.current);
      events.push({ type: 'exerciseDone', result: this.current });
    }
    this.current = null;
    this.exerciseIndex += 1;
    this.setIndex = 0;
    this.repCounter = null;
    this.holdTimer = null;
    this.easedRepTarget = null;
    this.easedHoldSeconds = null;
    this.smoothed = null;
    this.lastAngle = null;
    if (this.exerciseIndex >= this.plan.length) return [...events, ...this.finishSession()];
    const previous = this.plan[this.exerciseIndex - 1].spec, next = this.plan[this.exerciseIndex].spec;
    if (previous.posture !== next.posture || previous.cameraView !== next.cameraView) this.side = null;
    return [...events, ...this.enterSetup(true)];
  }

  finishSession(sayDone = true) {
    this.phase = { name: 'finished' };
    const events = [{ type: 'phase' }];
    if (sayDone) events.push({ type: 'say', line: Cue.sessionDone });
    events.push({ type: 'finished' });
    return events;
  }

  dateFor(t) { return new Date(this.startDate.getTime() + (t - this.startTime) * 1000); }
}

const plannedHold = (planned) => planned.dose.holdSeconds ?? planned.spec.defaultDose.holdSeconds ?? 30;

function newResult(planned) {
  const result = { id: uuid(), exerciseId: planned.spec.id, plannedSets: planned.dose.sets, repsPerSet: [], partialReps: 0,
    holdSecondsPerSet: [], repPeakAngles: [], formWarnings: 0 };
  if (planned.side) result.side = planned.side;
  return result;
}

/// Short holds count every second; long holds every five, then a final three-two-one.
function holdCountLine(second, target) {
  const remaining = target - second;
  if (target <= 10) return Cue.count(second);
  if (remaining <= 3) return Cue.count(remaining);
  if (second % 5 === 0) return second <= 30 ? Cue.count(second) : Cue.seconds(second);
  return null;
}
