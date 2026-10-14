# Laile (莱乐)

Camera-verified home physical therapy and calisthenics, with a coach that checks in on you.

**Tencent Cloud AI CAN DO IT Hackathon Singapore 2026 — Healthcare Track (NTU LKC Medicine)**
**Challenge Statement 2: AI Healthier Every Day — Intelligent Support for Long-Term Self-Care**

## Try it

| | |
|---|---|
| Web app, no install | https://43-156-108-79.sslip.io/app (tap a demo account) |
| iPhone app | https://testflight.apple.com/join/WuymKzUH (tap a demo account) |
| Clinician portal | https://43-156-108-79.sslip.io/portal (`clinician@laile.demo` / `laile-demo-2026`) |
| Lele on Tencent Cloud ADP | https://adp.tencentcloud.com/webim_exp/#/chat/nZbZZz |
| Overview | https://43-156-108-79.sslip.io |

Write-up, deck and diagrams: [`submission/`](submission/).

## The problem

Home exercise is where physical therapy succeeds or fails, and adherence is notoriously poor:
people skip sessions or do them with bad form, and self-reported logs can't tell the difference.
Physios only see the patient at the next visit. And like most health apps, nothing happens the
moment you stop opening it, so there's no reason to keep going.

## The approach

- **Programs are the unit.** A physio's program (joined with their code), a plan Lele builds from
  your goals, or a calisthenics/mobility program from Laile's catalog. Every program starts with a
  camera check-in that sets personal targets.
- **The camera verifies.** Pose estimation counts reps, times holds and measures knee bend and arm
  lift. It can't be faked, so it can go in the clinical record.
- **Lele takes initiative.** A morning check-in while you're in physio, medicine reminders, a nudge on
  quiet days, a question about what's getting in the way when you miss a few, and it remembers what
  was sore and makes that exercise easier next time. You can chat or talk to it.
- **Plan with Lele in chat.** Tap "Plan a new program" or say "my goals have changed": five questions,
  buttons or your own words, then Lele on ADP drafts a program from the knowledge base using only the
  vetted exercise library. It replaces Lele's old plan, or, for a physio patient, goes to the physio to
  approve first.
- **Lele learns each person.** Goals, time, sore spots in their own words, what was eased, measurements
  and requests build one record that Lele reads before every reply, that the person sees on Me, and that
  Lele summarises for the physio (ADP with the knowledge base; every number comes from code).
- **The physio stays on top.** Lele drafts programs and the physio signs them; they can ask Lele to
  change one, watch a session live, approve anything the patient wants to add, and see a daily list
  of what Lele noticed. Only the physio ends physio, and discharge hands the person on to a
  follow-on program with their limits still applied.
- **Code decides, the model talks.** Safety, limits and program changes are deterministic rules;
  the model (Tencent Cloud ADP) explains, encourages, drafts and summarises.
- **iPhone or any browser.** The web app has the same account, programs, Lele and progress, with webcam
  sessions (MediaPipe pose and a port of the session conductor, tested against the same plan).

Conditions covered first: knee and hip replacement, knee pain, stiff or painful shoulder.

## What it should solve (per challenge brief)

- **Medication/exercise understanding** — explain what each exercise is for, in plain language.
- **Adherence support** — verify completion and correct form via camera, not self-report.
- **Health tracking** — rep counts, range-of-motion, form-quality trend over the recovery timeline.
- **Preventive health** — flag movements that risk re-injury; surface follow-up scheduling.
- **Healthcare preparation** — auto-generate an adherence/progress summary for the clinician
  ahead of each visit.
- **Strictly bounded** — coaches form on prescribed exercises only; never diagnoses or gives
  medication advice; escalates pain/red-flag signals to "contact your care team."

## Status

Built as a Swift monorepo — see [docs/milestones.md](docs/milestones.md) for what's done and what's next,
[docs/architecture.md](docs/architecture.md) for the design and trust boundary, and
[docs/concept.md](docs/concept.md) for the product concept.

```
Packages/LaileCore   shared domain logic (iOS + server): exercises, conductor, safety rules, rewards, streams
Packages/LaileKit    iOS feature modules (SwiftUI)
iOS/                 app target (XcodeGen) → TestFlight
Server/              Vapor API + clinician portal + Lele on ADP + ElevenLabs/TRTC voice
Server/Public/app/   web app: plain JS modules, no build step (conductor.js mirrors SessionConductor)
agent/               Lele's ADP prompt and knowledge base
submission/          write-up, deck, diagrams, screenshots, CodeBuddy proof
```

### Run it

Server + clinician portal (SQLite and demo data, no keys needed):

```bash
cd Server && swift run LaileServer serve --hostname 127.0.0.1 --port 8080
```

Open http://127.0.0.1:8080/app for the web app and http://127.0.0.1:8080/portal for the portal (the login
page shows the demo clinician's credentials). With `ADP_APP_KEY` in `Server/.env`, Lele's chat, program
drafts and the physio's summary go through the ADP agent; without it, Lele uses offline rules and the
rule-based drafter.

### Demo accounts (`SEED_DEMO_DATA=true`; keep it on for the hackathon deployment)

- **App → "Try a demo account"** (Physio patient / Calisthenics): a brand-new account with two weeks of
  history on every tap, so each demo starts identically and simultaneous testers don't clash.
  Me → "Restart demo with fresh data" swaps in a new one. Guests are deleted after 12 hours.
- **Fixed logins** `patient@laile.demo` / `mover@laile.demo` / `shoulder@laile.demo` reset to the seeded story on every sign-in.
- **`clinician@laile.demo`** (portal) sees Mdm Tan (knee), Mr Ong (shoulder, with a program request
  waiting for approval) and every "Mdm Tan (demo guest HH:mm)".
- **Invite code `LAI-DEMO42`** works for anyone, any number of times (each gets their own record).

iOS app — Debug builds talk to the local server at http://127.0.0.1:8080 (start it first); Release builds
use `LAILE_API_BASE_URL` in `iOS/project.yml`. The Simulator uses a simulated skeleton:

```bash
cd iOS && xcodegen generate && open Laile.xcodeproj
```

Tests:

```bash
cd Packages/LaileCore && swift test && cd ../../Server && swift test && cd .. && node --test Server/Tests/Web/conductor.test.mjs
```

166 tests: 127 in LaileCore, 33 for the server, 6 for the web session engine.

### Lele (the agent) and care notes

**Lele (乐乐)** is Laile's coach:
- **In a session:** Lele is the voice.
- **Between sessions:** Lele is an agent on **Tencent Cloud ADP** (Tencent Hy3 model).
  - Instructions: `agent/prompts/lele.md`
  - Knowledge base: `agent/knowledge/`, in two ADP categories: `physical-therapy/` and `medicines/`.

**ADP modes.** Besides chat, the server sends Lele two kinds of message (`ADPPlannerProvider`):
`PLAN REQUEST` for program drafts (the portal's drafts and revisions, and Lele's plans from chat) and
`CLINICIAN BRIEF` for the physio's summary on each patient page (`LeleBriefWriter`, cached 30 minutes).
Drafts are checked by `ContraindicationChecker`; the brief only summarises numbers code computed.

**Planning by chat** is `PlanChat` (LaileCore) and `LelePlanService` (server): five questions with
suggested answers that also accept free text, then a plan that replaces Lele's old one or, while a
physio supervises, becomes a request with the draft attached for them to approve.

**Lele's initiative** is rules in `LaileCore` (`LeleRound`, `LeleReminders`, `ClinicianBrief`): quiet
hours 7 am–9 pm, at most three conversations started a day, no repeats. The model words replies;
code decides when Lele speaks up and what can change.

**Care notes** are Lele's memory, kept in our database:
- A sore spot during an exercise eases that exercise next time, and Lele says so.
- After 2 comfortable sessions in a row, the exercise eases back to normal.
- Patient and clinician see the same notes and history (app → Progress; portal → patient page and pre-visit report).
- The clinician can keep an exercise eased, close a note, or add notes for Lele to follow.

### Voice

Set `ELEVENLABS_API_KEY` in `Server/.env`. Users pick Lele's voice (Sarah, Jessica, Matilda, Chris —
ElevenLabs built-in voices, usable on every plan) in Me → Coach voice. The app downloads a voice's everyday
lines when it's chosen and each session's lines while the user gets ready; the server caches every render
(`VOICE_CACHE_DIR`), so each line costs credits once per voice. Optionally bundle a voice into the app:

```bash
cd Server && swift run LaileServer generate-cues --voice sarah
```

TRTC Conversational AI uses ElevenLabs natively (`TTSType: elevenlabs`) with the user's chosen voice. The
web app plays the same server-cached lines through Web Audio and prefetches each session's lines.

### TestFlight

1. Set `DEVELOPMENT_TEAM` and the Release `LAILE_API_BASE_URL` (deployed domain) in `iOS/project.yml`, run `xcodegen generate`.
2. Xcode → Product → Archive → Distribute → App Store Connect.
3. Add internal testers (up to 100, no review wait).

### Deploy (Tencent Cloud Lighthouse)

```bash
deploy/deploy.sh <server-ip>
```

Syncs the repo, builds the image on the server and restarts it behind Caddy (HTTPS). Set
`DATABASE_URL` for TencentDB for PostgreSQL, and the keys from `Server/.env.example`.

## Submission requirements (from the Hackathon Handbook)

- [x] Built on CodeBuddy and/or WorkBuddy, with proof of usage (`submission/codebuddy/`)
- [x] Project title + short blurb: "Home physio that counts every rep and checks in."
- [x] Project description (`submission/writeup/laile-description.pdf`)
- [x] 3+ screenshots of CodeBuddy/WorkBuddy conversation history
- [x] 16:9 cover image (`submission/cover/laile-cover-380x216.png`)
- [ ] Demo video (5–8 min, optional but recommended)
- [x] Live project link (web app, portal, TestFlight, ADP chat)
- [x] Complete source code in this repo
- [x] Architecture / trust-boundary diagram (`submission/diagram/`)

Deadline: **16 Oct 2026** (project submission). Finalists announced 23 Oct 2026.
