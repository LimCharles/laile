# Laile (莱乐)

Camera-verified home physical therapy — so recovery doesn't depend on willpower.

**Tencent Cloud AI CAN DO IT Hackathon Singapore 2026 — Healthcare Track (NTU LKC Medicine)**
**Challenge Statement 2: AI Healthier Every Day — Intelligent Support for Long-Term Self-Care**

## The problem

Home exercise adherence after orthopedic surgery (knee/hip replacement) is notoriously
poor — patients skip sessions or do them with bad form, and self-reported logs can't tell
the difference. Like most health apps, nothing happens the moment you stop using it, so
there's no reason to keep going. That's the core reason retention fails across the category:
Apple Health, mood trackers, etc. are passive logs with no external stakes.

## The approach

Laile uses camera-based pose estimation to verify that a prescribed exercise was actually
performed, and performed correctly — not just checked off. This does two things existing
health apps can't:

1. **Can't be faked.** Rep counting and form scoring come from the camera, not a self-report.
2. **Creates real stakes.** Adherence data is compiled into a report for the patient's
   surgeon/physiotherapist ahead of each follow-up visit — the app becomes part of the
   clinical record that gates recovery clearance, not an optional wellness extra.

Target population: post-surgical orthopedic rehab patients (starting with knee/hip
replacement home exercise programs).

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

Open http://127.0.0.1:8080/portal and sign in as `clinician@laile.demo` (password in
`Server/Sources/LaileServer/Features/Seed/DemoSeedFeature.swift`). The fictional demo patient is
`patient@laile.demo`; the unclaimed invite code is `LAI-DEMO42`.

iOS app — Debug builds talk to the local server at http://127.0.0.1:8080 (start it first); Release builds
use `LAILE_API_BASE_URL` in `iOS/project.yml`. The Simulator uses a simulated skeleton:

```bash
cd iOS && xcodegen generate && open Laile.xcodeproj
```

Tests:

```bash
cd Packages/LaileCore && swift test && cd ../../Server && swift test
```

### Voice

Set `ELEVENLABS_API_KEY` (see `Server/.env.example`), then render every fixed coaching line into the app:

```bash
cd Server && swift run LaileServer generate-cues --output ../iOS/Laile/Resources/Cues
```

TRTC Conversational AI uses ElevenLabs natively (`TTSType: elevenlabs`), so live calls get the same voice.

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
