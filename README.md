# Laile (莱乐)

Camera-verified home physical therapy and calisthenics, with a coach that checks in on you.

**Tencent Cloud AI CAN DO IT Hackathon Singapore 2026 — Healthcare Track (NTU LKC Medicine)**
**Challenge Statement 2: AI Healthier Every Day — Intelligent Support for Long-Term Self-Care**

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
- **The physio stays on top.** Lele drafts programs and the physio signs them; they can ask Lele to
  change one, watch a session live, approve anything the patient wants to add, and see a daily list
  of what Lele noticed. Only the physio ends physio, and discharge hands the person on to a
  follow-on program with their limits still applied.
- **Code decides, the model talks.** Safety, limits and program changes are deterministic rules;
  the model (Tencent Cloud ADP) explains, encourages and remembers.

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
Server/              Vapor API + clinician portal + Hunyuan + ElevenLabs/TRTC voice
```

### Run it

Server + clinician portal (SQLite and demo data, no keys needed):

```bash
cd Server && swift run LaileServer serve --hostname 127.0.0.1 --port 8080
```

Open http://127.0.0.1:8080/portal — the login page shows the demo clinician's credentials.

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
cd Packages/LaileCore && swift test && cd ../../Server && swift test
```

### Lele (the agent) and care notes

**Lele (乐乐)** is Laile's coach:
- **In a session:** Lele is the voice.
- **Between sessions:** Lele is an agent on **Tencent Cloud ADP** (Tencent Hy3 model).
  - Instructions: `agent/prompts/lele.md`
  - Knowledge base: `agent/knowledge/`, in two ADP categories: `physical-therapy/` and `medicines/`.

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

TRTC Conversational AI uses ElevenLabs natively (`TTSType: elevenlabs`) with the user's chosen voice.

### TestFlight

1. Set `DEVELOPMENT_TEAM` and the Release `LAILE_API_BASE_URL` (deployed domain) in `iOS/project.yml`, run `xcodegen generate`.
2. Xcode → Product → Archive → Distribute → App Store Connect.
3. Add internal testers (up to 100, no review wait).

### Deploy (Tencent Cloud Lighthouse)

```bash
docker build -f Server/Dockerfile -t laile-server .
```

Run with `DATABASE_URL` pointing at TencentDB for PostgreSQL and the keys from `Server/.env.example`.

## Submission requirements (from the Hackathon Handbook)

- [ ] Built on CodeBuddy and/or WorkBuddy, with proof of usage (chat screenshots / logs)
- [ ] Project title + short blurb (<10 words)
- [ ] Project description (target scenario, users, value; pain point sourcing; architecture;
      business value)
- [ ] 3+ screenshots/recordings of CodeBuddy/WorkBuddy conversation history
- [ ] 16:9 cover image (380×216px)
- [ ] Demo video (5–8 min, optional but recommended)
- [ ] Live project link (optional, bonus points)
- [ ] Complete source code in this repo
- [ ] Architecture / trust-boundary diagram

Deadline: **16 Oct 2026** (project submission). Finalists announced 23 Oct 2026.
