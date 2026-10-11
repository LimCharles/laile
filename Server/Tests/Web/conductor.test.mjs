// The web app's session engine, checked against the same knee-replacement plan the server sends.
// Run: node --test Server/Tests/Web
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Conductor, RepCounter, HoldTimer, setupCheck } from '../../Public/app/conductor.js';

const launch = JSON.parse(readFileSync(new URL('./knee-plan.json', import.meta.url), 'utf8'));
const aspect = 16 / 9;

/// A person lying side-on to the camera, right side nearest, with the given knee and hip angles.
function frame(t, knee = 175, hip = 178) {
  const H = { x: 0.42, y: 0.6 }, S = { x: 0.2, y: 0.6 };
  const a1 = ((180 - hip) * Math.PI) / 180, b = ((180 - knee) * Math.PI) / 180;
  const K = { x: H.x * aspect + 0.3 * Math.cos(a1), y: H.y - 0.3 * Math.sin(a1) };
  const A = { x: K.x + 0.3 * Math.cos(a1 + b), y: K.y + 0.3 * Math.sin(a1 + b) };
  return { t, aspect, lm: {
    rightShoulder: { ...S, c: 0.9 }, rightHip: { ...H, c: 0.9 }, rightKnee: { x: K.x / aspect, y: K.y, c: 0.9 },
    rightAnkle: { x: A.x / aspect, y: A.y, c: 0.9 }, rightElbow: { x: 0.22, y: 0.62, c: 0.8 }, rightWrist: { x: 0.25, y: 0.63, c: 0.8 },
  } };
}

test('a rep counts only after reaching the target and coming back', () => {
  const counter = new RepCounter({ start: 160, target: 110, partialFraction: 0.45 });
  for (const angle of [160, 150, 130, 112, 108, 130, 158]) counter.update(angle);
  assert.equal(counter.count, 1);
  for (const angle of [145, 142, 158]) counter.update(angle); // 36% of the way: not even a partial
  assert.equal(counter.count, 1);
  for (const angle of [125, 158]) counter.update(angle); // 70%: a partial
  assert.equal(counter.partials, 1);
});

test('a hold keeps time through brief dropouts', () => {
  const timer = new HoldTimer(3);
  let t = 0;
  for (; t < 1.5; t += 0.1) timer.update(true, t);
  timer.update(false, t); // one lost frame
  for (t += 0.1; t < 4; t += 0.1) timer.update(true, t);
  assert.ok(timer.isComplete);
});

test('setup asks someone too far away to come closer', () => {
  const tiny = { t: 0, aspect, lm: Object.fromEntries(Object.entries(frame(0).lm).map(([k, v]) => [k, { ...v, x: 0.5 + (v.x - 0.5) * 0.3, y: 0.5 + (v.y - 0.5) * 0.3 }])) };
  const spec = launch.plan.find((p) => p.spec.id === 'heel-slide').spec;
  assert.equal(setupCheck(tiny, spec, 'right').issues[0].type, 'tooFar');
  assert.ok(setupCheck(frame(0), spec, 'right').isReady);
});

test('a whole session counts reps, stops for pain with context, and summarises like the phone', () => {
  const c = new Conductor(launch, 0, new Date('2026-10-12T01:00:00Z'));
  const said = [];
  const run = (events) => events.forEach((e) => e.type === 'say' && said.push(e.line.text));
  run(c.start(0));
  let reported = false;
  for (let t = 0; t < 600 && !c.isFinished; t += 1 / 30) {
    const id = c.currentExercise?.spec.id;
    let knee = 175, hip = 178;
    if (id === 'heel-slide') knee = 166 - 41 * (0.5 - 0.5 * Math.cos((2 * Math.PI * t) / 3));
    if (id === 'straight-leg-raise') {
      hip = 179 - 39 * (0.5 - 0.5 * Math.cos((2 * Math.PI * t) / 3));
      if (!reported && c.snapshot.reps >= 2 && c.phase.name === 'active') {
        reported = true;
        run(c.report({ id: 'r1', category: 'pain', utterance: 'sharp, inside of my knee, about a six', severity: 6, source: 'typed', action: { stopExercise: {} } }, t));
      }
    }
    if (id === 'long-arc-quad') { run(c.endSession(t)); break; }
    run(c.process(frame(t, knee, hip)));
  }
  const summary = c.summary(2, 3);
  const byId = Object.fromEntries(summary.exercises.map((e) => [e.exerciseId, e]));
  assert.deepEqual(byId['ankle-pumps'].holdSecondsPerSet, [30]);
  assert.equal(byId['quad-set'].holdSecondsPerSet.length, 10);
  assert.deepEqual(byId['heel-slide'].repsPerSet, [7, 7], 'two full sets at the eased target');
  assert.equal(byId['straight-leg-raise'].stopReason, 'symptom');
  assert.equal(byId['long-arc-quad'].stopReason, 'userEnded');
  assert.equal(summary.symptoms.length, 1);
  assert.equal(summary.symptoms[0].exerciseId, 'straight-leg-raise');
  assert.equal(summary.symptoms[0].setIndex, 0);
  assert.ok(said.some((line) => line.includes('sore on the inside of your right knee')), "Lele's care note is said before heel slides");
  assert.match(summary.startedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'dates without fractions, as the server reads them');
  assert.equal(summary.painBefore, 2);
  assert.equal(summary.enrollmentId, launch.enrollmentId);
});

test('a red flag ends the session with an emergency', () => {
  const c = new Conductor(launch, 0);
  c.start(0);
  const events = c.report({ id: 'r2', category: 'redFlag', utterance: 'chest pain', source: 'typed', action: { endSession: { _0: 'emergency' } } }, 1);
  assert.ok(events.some((e) => e.type === 'finished'));
  assert.equal(c.summary().escalation, 'emergency');
});
