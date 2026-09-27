# Laile (莱乐) — Product Concept

> **Stack update (28 Sep):** built as Swift end to end — SwiftUI iOS app (TestFlight) + Vapor server/clinician
> portal, sharing one `LaileCore` package; Apple Vision replaces MediaPipe; ElevenLabs is the coach's voice
> (natively supported by TRTC Conversational AI). See `docs/architecture.md`. The product sections below still apply.

A voice-first, camera-verified movement coach with two front doors:

- **Rehab mode** — clinician-prescribed home rehab (hackathon focus: knee/hip replacement).
- **Move mode** — self-directed calisthenics for everyday users.

Both share one engine: the camera measures, a deterministic conductor counts, and a
conversational voice agent talks with you — including *while* you hold a pose.

On the other side sits the **clinician portal**: patient records, AI-drafted programs that a
clinician reviews and signs, baselines, and progress/symptom reports.

---

## 1. The story that ties both modes together

> Rehab isn't the finish line — it's the on-ramp.

A patient starts in Rehab mode after surgery. When their clinician marks them as discharged
from rehab, the app "graduates" them into Move mode with a maintenance program built from the
same exercises and the same baselines. The record carries over.

This is why dual-mode *strengthens* the Challenge 2 pitch instead of diluting it: Challenge 2
is about **long-term self-care** and **preventive health**. Rehab is the 12-week clinical
episode; Move mode is the lifelong habit that keeps the knee (and the rest of the body)
strong. It's also the business model: clinics adopt Rehab mode (B2B), the everyday user pays
for Move mode (B2C), and each funnels into the other.

**For the demo, lead with Rehab, then show graduation into Move.** Don't pitch it as "a
fitness app that also does rehab" — judges from a medical school will score the clinical
side.

---

## 2. Three users, three surfaces

| User | Surface | What they do |
|---|---|---|
| **Patient** (Rehab mode) | PWA on phone/tablet | Follows a signed program, reports how it feels, sees progress |
| **Everyday user** (Move mode) | Same PWA | Takes a baseline test, follows a progression path, sets PRs |
| **Clinician** (physio / surgeon / sports doctor) | Clinician portal (desktop web, same Next.js app) | Manages patients, generates + approves programs, reviews records |

Optional fourth: **caregiver** (adult child / helper) — read-only weekly summary, patient
opt-in.

Account linking: clinician creates the patient record → issues an invite code/QR → patient
scans it in the app and **explicitly consents** to share session data with that clinician
(PDPA). Move-mode users have no clinician and their data stays private to them.

---

## 3. The in-session experience (the core)

### 3.1 Flow

```
SETUP ─► DEMO ─► READY ─► ACTIVE (reps or hold, counting) ─► REST ─► next set/exercise ─► WRAP-UP
  ▲                           │   ▲
  │                           ▼   │
  └──── camera lost ◄──── VOICE EVENT (user speaks at any time)
```

1. **Setup** — the camera-setup assistant checks the required landmarks are visible, the
   body fills the frame, the view angle matches the exercise (side-on for knee angle,
   front-on for squats), and the lighting is adequate. It talks you into position:
   *"Move the phone a little further back… turn it so it sees your left side… perfect."*
2. **Demo** — short Miora-generated clip of the exercise + one-sentence purpose
   (*"This stretches the back of your new knee so it can bend enough for stairs."*).
3. **Active** — the conductor counts reps from joint angles, or runs the hold timer. Voice
   cues count *with* you: *"Hold… hold… five more… three, two, one — and relax."* Only
   reps/holds that the camera actually verifies are counted; if it can't see the joint,
   it says so instead of guessing.
4. **Rest** — the agent checks in conversationally between sets.
5. **Wrap-up** — today's headline number (e.g. knee bend 84°, up 3° from last session),
   post-session pain rating, what's next.

### 3.2 Talking during a hold (your key idea)

The mic stays open throughout. At any moment the user can say things like:

| User says | Classified as | What happens |
|---|---|---|
| "Okay" / "this is fine" / counts along | **Normal / effort** | Keep counting. Maybe a short encouragement. |
| "It's pulling behind my knee" / "tight" | **Expected stretch discomfort** | Keep going, reassure, log it lightly. |
| "Ow" / "that hurts" (ambiguous) | **Needs clarification** | Timer pauses. *"Is it a stretching feeling or a sharp pain?"* |
| "Sharp pain on the inside of my knee" | **Pain** | Stop the set, ask 0–10, log location/type/severity against this exercise + rep. If above the clinician's threshold → end exercise, flag to clinician. |
| "Something clicked" / "knee gave way" / "tingling in my foot" | **Wrong sensation** | Stop, log, flag for clinician review. |
| "My calf is swollen and sore" / "chest hurts" / "can't breathe" | **Red flag** | Stop session. Deterministic escalation script: contact care team today / call 995. |

Every symptom report is stored with: verbatim transcript, structured fields (body location,
quality, severity 0–10, side), exercise, set, rep/hold second, joint angle at that moment,
and the action taken. **That last detail is gold for a clinician**: "sharp pain at 95° of
knee flexion on rep 7 of heel slides" is far more useful than "patient reports pain."

Pain rules follow the idea behind the physio *pain-monitoring model*: some discomfort during
rehab is expected and acceptable if it stays within a limit and settles by the next day. The
threshold (e.g. ≤ 4/10) is **set per patient by the clinician**, not by the AI. Move mode
uses a conservative default ("stop, and see a doctor if it persists").

### 3.3 Who decides what (critical design rule)

- **The LLM listens and talks.** It understands free speech, extracts structured symptom
  data, and responds naturally.
- **Deterministic code decides.** Rep counting, hold timing, the stop/continue decision
  from symptom severity, red-flag escalation, and every number shown to the user or
  clinician all come from code, not the model.

The LLM proposes a classification via a tool call (`report_symptom({...})`); the conductor
applies fixed rules to it. If the model is unsure, it must ask, not guess.

---

## 4. Baselines and improvement tracking

**Baseline session** — the first session of any program (and every ~2 weeks after) is a
test session:

- *Rehab:* active knee flexion/extension range of motion (ROM), straight-leg raise hold,
  sit-to-stand count in 30 s, pain at rest.
- *Move:* max push-ups (or the hardest variation achievable), plank hold, bodyweight squat
  depth + reps, glute bridge hold, deep-squat mobility.

**Improvement marking** — each metric has a trend line and the app marks:

- **Personal bests** ("Longest plank yet: 1:12").
- **Milestones** — clinician-defined in Rehab (e.g. knee flexion ≥ 90°), progression unlocks
  in Move (wall push-up → incline → knee → full → diamond → archer).
- **Plateaus / regressions** — no ROM gain over N sessions, or a drop → nudges the patient
  and **flags the clinician** (possible stiffness risk).

Everything is phrased relative to the user's own baseline, never to other people.

---

## 5. Clinician portal

### 5.1 Patient record

- Profile + clinical context: diagnosis, procedure + date, side, precautions (e.g. hip
  precautions, weight-bearing status), relevant comorbidities, medication list, goals.
- Timeline: sessions, baselines, symptom reports, messages, program versions.
- Trends: ROM, holds, reps, pain before/after, adherence (verified sessions vs prescribed).
- Flags inbox: red flags, pain above threshold, plateaus, missed sessions + the patient's
  stated reason.
- Pre-visit report (PDF/print): one page, numbers pulled straight from the database, the
  LLM writes only the summary around them. Includes the patient's own questions for the
  visit.

Data shapes loosely follow FHIR resources (Patient, Condition, MedicationStatement,
Observation, CarePlan) so a real deployment can map to hospital systems later — a feasibility
point, not something to build now.

### 5.2 AI-drafted programs (human-in-the-loop)

1. Clinician enters or pastes the patient's medical data (structured form + free-text notes).
2. The program agent drafts a routine, **choosing only from the vetted exercise library**
   and within each exercise's allowed parameter ranges (sets, reps, hold time, frequency,
   ROM limits).
3. A **deterministic contraindication check** runs on the draft (e.g. posterior hip
   precautions → no hip flexion past 90°; non-weight-bearing → no standing exercises).
   Violations are blocked, not just warned.
4. Each suggested exercise shows *why* it was chosen and which library/protocol entry it
   came from.
5. The clinician edits, then **signs**. Only a signed program reaches the patient. Every
   change is a new version; old versions stay in the record.

The AI never prescribes directly to a patient. In Move mode, programs come from pre-built
progression templates adjusted to baseline results, never from medical data.

### 5.3 Move-mode safety gate

Move-mode onboarding runs a short readiness screen (in the style of the standard PAR-Q+
questionnaire). Answers that suggest risk (recent surgery, chest pain on exertion, etc.) →
"please check with a doctor first," with the option to get linked to a clinician (the
funnel into Rehab mode).

---

## 6. Medication layer (Challenge 2 requirement)

Rehab mode only:

- Discharge medication list entered by the clinician (or photographed and confirmed by the
  clinician).
- Plain-language explanation of each drug: what it's for and how to take it, grounded in the
  knowledge base.
- Reminders + a taken/not-taken log.
- Session scheduling around the prescribed pain-relief timing, as set by the clinician.
- Pain before and after each session, shown alongside medication timing in the report.
- **Hard boundary:** no dose changes, no "should I take X" answers. The fallback is always
  *"That's a question for your doctor or pharmacist — I'll add it to your list for your next
  visit."*

---

## 7. Voice: yes, Tencent has natural, conversational TTS

The handbook's "TTS/ASR from TRTC" points to the right product. For a ChatGPT/Claude-voice
feel, use **TRTC Conversational AI** (Tencent's real-time AI voice conversation service)
rather than separate speech-to-text and text-to-speech calls. It handles the parts that make
voice feel natural:

- streaming speech recognition (ASR) with voice activity detection,
- **interruption (barge-in)** — the user can talk over the agent,
- streaming TTS with low latency,
- a **custom LLM endpoint** — it calls *our* backend for each turn, so our code sees every
  utterance, runs the tool calls (`report_symptom`, `pause_set`), and applies the rules.

Standalone **Tencent Cloud TTS** (which includes more natural large-model voices) is used
separately to pre-generate the fixed counting cues ("hold… three, two, one… relax") as audio
files cached on the device. Counting must be frame-accurate and must never lag behind a
network round-trip, so counts play locally while the conversational agent handles everything
the user says.

> Verify during setup: TRTC Conversational AI's supported languages and voices
> (English + Mandarin at minimum), its custom-LLM request format, and whether it can be told
> to speak server-pushed text (useful for the agent to announce "set complete").

---

## 8. Architecture

```
┌──────────────────────── USER DEVICE (PWA) ───────────────────────┐
│ Camera ─► MediaPipe Pose (Web Worker) ─► joint angles             │
│                                  │                                │
│                                  ▼                                │
│ Session Conductor (TS state machine) ◄── Exercise Specs (JSON)     │
│   reps · holds · form checks · camera-visibility gate             │
│   pre-cached TTS cue audio (counts)                               │
│   applies symptom rules → continue / pause / stop / escalate      │
│                                  ▲                                │
│ TRTC Web SDK (mic + speaker) ────┘ events                         │
│                                                                   │
│ RAW VIDEO NEVER LEAVES THE DEVICE — only angles + events uploaded │
└──────────┬───────────────────────────────┬────────────────────────┘
           │ audio stream                  │ HTTPS (sessions, events)
           ▼                               ▼
┌──────────────────── TENCENT CLOUD ────────────────────────────────┐
│ TRTC Conversational AI (ASR ⇄ TTS, barge-in)                       │
│        │ custom-LLM call per turn                                  │
│        ▼                                                           │
│ Laile API (Next.js route handlers on Lighthouse)                   │
│   ├─ Coach agent  ── Hunyuan via ADP (+ knowledge base: exercise    │
│   │                  library, medication explainers)               │
│   ├─ Program agent ─ ADP workflow → schema check → contraindication │
│   │                  rules → clinician sign-off                    │
│   ├─ Red-flag + pain rules (deterministic)                         │
│   └─ Report builder (numbers from DB, LLM writes narrative only)   │
│ TencentDB for PostgreSQL · COS (reports, assets) · TTS (cue gen)   │
└───────────────────────────────────────────────────────────────────┘
           ▲
           │ Clinician portal (same Next.js app, /clinician, role-gated)
```

### Unifying abstraction: the Exercise Spec

Every exercise (rehab or calisthenics) is **data**, not code:

```jsonc
{
  "id": "heel-slide",
  "modes": ["rehab"],
  "view": "side",                         // camera requirement
  "requiredLandmarks": ["hip", "knee", "ankle"],
  "primaryAngle": { "joint": "knee", "from": "hip", "via": "knee", "to": "ankle" },
  "type": "reps",                          // or "hold"
  "repPhases": { "startAbove": 160, "targetBelow": 100 },   // clinician can override
  "formChecks": ["heel-stays-on-surface", "tempo-not-too-fast"],
  "metric": "max-knee-flexion",
  "cues": { "purpose": "…", "setup": "…", "counting": "rep" }
}
```

The same conductor runs a heel slide or a push-up. Clinicians override parameters per
patient; Move-mode progressions are just ordered lists of specs.

---

## 9. Final tech stack

| Layer | Choice |
|---|---|
| Build tool | **CodeBuddy** (mandatory; screenshot conversations throughout) |
| Frontend | **Next.js (App Router) + React + TypeScript**, installable PWA (Serwist for the service worker), Tailwind + shadcn/ui, Recharts for trends |
| Pose | **MediaPipe Pose Landmarker** (`@mediapipe/tasks-vision`) in a Web Worker, on-device |
| Voice conversation | **TRTC Conversational AI** + TRTC Web SDK |
| Cue audio | **Tencent Cloud TTS**, pre-generated at build time, cached by the service worker |
| LLM + agents | **Tencent Cloud ADP** with **Hunyuan**: coach agent, program-drafting workflow, knowledge base (RAG) |
| Agent sandbox | **Tencent Cloud Agent Runtime**, optional, for the program agent's tool execution |
| Backend | Next.js route handlers (+ a small Node service if TRTC's callback needs one) on **Tencent Cloud Lighthouse** (Docker) |
| Data | **TencentDB for PostgreSQL** + Drizzle ORM; **COS** for PDFs and media |
| Auth | Auth.js with roles: `patient`, `mover`, `clinician`, `caregiver` |
| Visual assets | **Miora**: mascot, exercise demo clips, UI illustrations, 380×216 cover |
| Scheduled summaries | **WorkBuddy** (optional): weekly clinician/caregiver digests |

---

## 10. Build priorities (deadline 16 Oct 2026)

**P0 — the demo can't exist without these**
- Exercise-spec engine + conductor with 3 rehab exercises (heel slide, quad-set hold,
  straight-leg raise) and knee ROM as the headline metric
- Camera-setup assistant
- Pre-cached counting cues + TRTC conversational voice with the talk-during-hold symptom
  capture
- Symptom rules + red-flag escalation
- Baseline session + ROM trend chart with PB/milestone marking
- Clinician portal: patient record, AI-drafted program → contraindication check → sign
- Pre-visit report

**P1 — makes it a strong submission**
- Medication list, explanations, reminders
- Move mode: readiness screen, baseline test, 1 progression path (push-up), plank hold
- Rehab → Move graduation
- Missed-session "what got in the way?" check-in

**P2 — only if time allows**
- Caregiver digest (WorkBuddy), Mandarin UI, more exercises, hip replacement protocol

**Honest scope note:** the full concept is more than 19 days of work for a small team. If time
runs short, cut Move mode down to one screen that shows graduation and a single progression,
and keep all the depth in Rehab and the clinician portal. That's what the judges are scoring.

---

## 11. Demo script (5–8 min)

1. **Clinician** enters a fictional patient (Mdm Tan, 68, right total knee replacement,
   day 10), clicks *Draft program*, the AI proposes 4 exercises with reasons, one is blocked
   by a precaution rule, clinician tweaks a hold time and signs.
2. **Patient** scans the invite, the voice agent walks through camera setup, runs the
   baseline: knee bend 72°.
3. Heel slides with counting; during a hold the patient says *"it's pulling at the back"*
   → reassured, continues. Next set: *"ow, sharp, inside of my knee"* → pause, 6/10, set
   stopped, logged at 95° on rep 7.
4. Skip ahead two weeks (seeded data): ROM trend with a milestone at 90°, one plateau flag.
5. **Clinician** opens the pre-visit report: adherence, ROM trend, the pain event with
   angle context, the patient's questions.
6. Discharge → **graduation into Move mode**: first push-up baseline, progression path.
7. Close on the trust boundary: video never leaves the device, the AI drafts but never
   decides, clinicians sign.
