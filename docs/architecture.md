# Architecture

Swift for the domain, four deliverables (iPhone app, server, clinician portal, web app), one shared brain.

```
Packages/LaileCore      Pure Swift domain logic, builds for iOS, macOS and Linux.
                        Exercise specs · session conductor · rep/hold counting · setup checks ·
                        symptom rules + red flags · contraindication checker · program drafting schema ·
                        rewards/streaks/badges · progress analysis · streams clock · API contracts · cue catalog
Server/                 Vapor: REST API + WebSockets + clinician portal (Leaf) + AI + TTS + TRTC
Packages/LaileKit       iOS feature modules (SwiftUI)
iOS/                    Thin app target (XcodeGen `project.yml`) → TestFlight
Server/Public/app/      Web app: plain JS modules served by the server; conductor.js mirrors SessionConductor
```

The server and the phone run **the same** `LaileCore` code: the phone counts reps and applies
safety rules (also offline); the server re-derives PBs, streaks and XP with the same engines.

## Modularity

- **Server:** each feature is a `LaileFeature` (migrations + routes) in `Server/Sources/LaileServer/Features/<Name>`,
  registered in one list in `configure.swift`.
- **iOS:** each tab is a `FeatureModule` in its own Swift package target (`TodayFeature`, `StreamsFeature`, …),
  registered in `FeatureRegistry`. Shared pieces: `AppCore` (state + backends), `DesignSystem`, `PoseKit`, `VoiceKit`.
- **Backend:** one hosted Laile API. The app's address is fixed per build (`LAILE_API_BASE_URL`);
  `LaileBackend` is a protocol only so previews/tests can stub it. Users never choose or run a server.
- **Exercises are data:** adding an exercise = one `ExerciseSpec` entry; the conductor, safety checks,
  program drafter and cue catalog pick it up automatically.

## Trust boundary

```
┌─────────────────── PHONE OR BROWSER (trusted, private) ───────────────────┐
│ Camera → Apple Vision (iPhone) or MediaPipe (browser) → joint angles      │
│                                     ▼                                     │
│  SessionConductor (deterministic): reps · holds · form · setup            │
│  SymptomRules (deterministic): continue / stop set / stop / escalate      │
│  Red-flag keywords: on the iPhone, and again on the server                │
│  Voice: ElevenLabs lines cached on the server, fetched ahead              │
│  RAW VIDEO NEVER LEAVES THE DEVICE                                        │
└──────────┬────────────────────────────────────────────┬───────────────────┘
           │ counts, angles, symptom reports             │ utterance text
           ▼                                             ▼
┌──────────────────────────── TENCENT CLOUD ────────────────────────────────┐
│ Vapor API on Lighthouse · TencentDB for PostgreSQL                        │
│ CoachAgent: red flags + dose questions handled by fixed rules FIRST;      │
│   a model (if configured) only classifies and chats; rules decide         │
│ Drafts: Lele on ADP (PLAN REQUEST) → schema check → contraindication      │
│   checker removes violations → DRAFT → clinician edits → clinician SIGNS  │
│ TRTC Conversational AI (ASR ⇄ ElevenLabs TTS) calls our /v1/voice/llm     │
│ CareMemory (deterministic): sore spot → ease that exercise next time;     │
│   comfortable sessions → ease back; clinician can keep/close/add notes    │
│ Lele on Tencent Cloud ADP (Hy3 + knowledge base): explains, reviews,      │
│   remembers; its suggestions and notes are checked by code before saving  │
│ Lele's brief: ADP (CLINICIAN BRIEF) summarises numbers code computed      │
│ Clinician portal: numbers straight from the DB, never model-generated     │
└───────────────────────────────────────────────────────────────────────────┘
```

Design rules:

1. **The model talks; code decides.** Counting, timing, pain thresholds, escalation and every number a
   clinician sees come from deterministic code.
2. **The AI never prescribes.** Only clinician-signed programs reach a patient. Drafts can only use the
   vetted library, within dose limits, and anything that breaks a precaution is removed before a human sees it.
3. **Honest about uncertainty.** No camera visibility → no count ("I can't see you clearly, so I'm not counting
   that"). Ambiguous remarks → the app asks "stretch or sharp pain?" instead of guessing.
4. **Never medication advice.** Dose questions get a fixed referral to the doctor/pharmacist.
5. **Memory is a record, not a model state.** Lele's notes live in our database, not in the model provider:
   the patient and clinician see the same notes, every change has a history line, and code (`CareMemory`)
   decides how much an exercise is eased: never below half its range, never outside the clinician's limits.

## Voice pipeline

| What | How | Why |
|---|---|---|
| Counts, cues, safety lines, exercise intros (286 lines) | In the user's chosen voice: fetched via `/v1/voice/speak` ahead of time (voice selection, session start) and cached on device; optionally bundled with `generate-cues` | Instant once cached; counts never wait on the network (on-device fallback the first time) |
| Free-form coach replies | `/v1/voice/speak` → ElevenLabs Flash, cached on the server's disk per voice | Natural voice; API key stays on server; each line paid for once |
| Full-duplex conversation (M3) | TRTC Conversational AI with `TTSType: elevenlabs` | Barge-in, streaming ASR; Tencent stack + ElevenLabs voice |
| Fallback | Best on-device iOS voice (Premium if installed) | Works with no network |

## Key trade-offs

- **SwiftUI + Vapor, plus a web app:** a real TestFlight app with native camera/Vision performance; the web
  app covers Android and laptops with no install. Its session engine is a JavaScript port of the Swift one,
  so it is kept honest by tests that run it against the same plan the server sends.
- **Apple Vision on iPhone, MediaPipe in the browser:** both on the device, video never uploaded; 2D joints
  only, so angles are camera estimates for trends, not clinical goniometry (stated in the report).
- **Server-rendered portal (Leaf) instead of an SPA:** fast to build, prints cleanly as a pre-visit report,
  no second front-end stack.
