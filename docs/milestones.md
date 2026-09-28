# Milestones

Deadline: **16 Oct 2026** (submission). Finalists 23 Oct. Demo Day 3 Nov (TBC).

Status key: ✅ done · 🟡 partly done · ⬜ not started

---

## M0 — Foundations ✅ (27–28 Sep)

- ✅ Swift monorepo: `LaileCore` (shared domain logic), `Server` (Vapor), `Packages/LaileKit` + `iOS` (SwiftUI app)
- ✅ Exercise library as data (16 exercises: 7 rehab, 9+ Move), session templates / "snacks"
- ✅ Session conductor: rep counting with hysteresis, hold timers with dropout grace, camera-setup checks,
  form checks, rest/countdown phases, verified session summary
- ✅ 57 core tests + 11 server tests passing

## M1 — Session engine on iOS ✅

- ✅ Apple Vision body-pose on-device (video never leaves the phone); simulated pose provider for the Simulator
- ✅ Full-screen session UI: skeleton overlay with measured joint + live angle, big rep counter, depth meter,
  hold ring, setup guidance, pause/skip/end
- ✅ Voice cues with never-late counting; pre-generated-audio pipeline (see M3)
- ✅ Talk-during-exercise: on-device speech recognition → symptom classification → deterministic rules
  (continue / clarify / rate 0–10 / stop set / stop exercise / escalate); quick-reply chips as backup
- ✅ Pain before/after, results screen with verified reps and "noted for your records"
- ⬜ **Test on a real iPhone** with real bodies — tune angle thresholds per exercise (biggest remaining risk)

## M2 — Rewards & habit loop ✅

- ✅ Daily check-in calendar (7-day cycle, 10→75 XP), check-in streak bonuses
- ✅ Move streak with "never miss twice" shields, XP + levels, first-move-of-day bonus, 11 badges
- ✅ Personal bests & milestones from verified metrics
- ⬜ Local notifications: check-in reminder, "streak at risk", medication reminders

## M3 — Voice that doesn't suck 🟡

- ✅ `CueCatalog`: every fixed line (~400: counts, exercise intros, setup guidance, safety lines, stream lines)
- ✅ `swift run LaileServer generate-cues` renders them with **ElevenLabs** (Tencent TTS as fallback)
  into the app bundle → instant, offline, natural voice
- ✅ `/v1/voice/speak` — server-side TTS for free-form LLM replies (keys never ship in the app)
- ✅ TRTC Conversational AI session start with **ElevenLabs as the native TRTC TTS provider**
- ✅ ElevenLabs key working; users choose between 4 built-in voices (Me → Coach voice) with previews
- ✅ Voices download on demand (everyday lines on selection, each session's lines while getting ready);
  server disk cache so each line is paid for once per voice
- ⬜ Optional: `generate-cues --voice sarah` to bundle the default voice (needs ~14k credits)
- ⬜ Add TRTC iOS SDK (`TXLiteAVSDK_TRTC`) → enable `TRTCVoiceLink` for full-duplex barge-in voice

## M4 — Clinician side ✅

- ✅ Vapor clinician portal (Leaf, server-rendered, prints cleanly): patient list, patient record with
  trend charts, baselines, PB dots, milestone lines, flags (plateau / regression / red flag / missed sessions)
- ✅ Pain & symptom reports with verbatim quote + exercise / set / rep / knee angle; "mark reviewed"
- ✅ AI program drafting (Hunyuan) → contraindication check (blocked, not warned) →
  clinician edits → **sign**; versioning + archive; rule-based template fallback when no LLM
- ✅ Pre-visit report page
- ✅ Invite codes + patient consent linking; medications (explain + remind, never dose advice)
- ⬜ Hunyuan key + real draft test; tune prompt on 3–4 fictional patients

## M5 — Streams ✅ (v1)

- ✅ Timed follow-along streams on a shared clock (late joiners land in the right segment), lobby, live, ended
- ✅ Each phone counts its own reps with the camera; live leaderboard via WebSocket
- ✅ Rehab precautions lock out unsuitable streams; practice stream that starts immediately
- ✅ Clinicians/coaches schedule streams in the portal
- ⬜ Host video: TRTC live broadcast (or pre-recorded premiere video) in the host panel

## M5.5 — Demo accounts ✅

- ✅ "Try a demo account" (Knee rehab / Daily mover): fresh seeded guest per tap, auto-cleanup after 12h
- ✅ Fixed demo logins reset on sign-in; reusable demo invite code; demo creds on the portal login page

## M6 — Ship it ⬜ (target 8 Oct)

- ⬜ Deploy server to **Tencent Cloud Lighthouse** (Dockerfile included) + TencentDB for PostgreSQL; HTTPS domain
- ⬜ TestFlight: set `DEVELOPMENT_TEAM`, archive, upload, internal testers (no review needed)
- ⬜ Set the Release `LAILE_API_BASE_URL` in `iOS/project.yml` to the deployed domain
- ⬜ Portal "discharge → Move mode" action (rehab graduation)
- ⬜ Miora: app icon, cover image (380×216), exercise demo clips

## M7 — Submission package ⬜ (target 14 Oct)

- ⬜ **CodeBuddy/WorkBuddy usage proof** — mandatory, project isn't scored without it (3+ screenshots)
- ⬜ Architecture + trust-boundary diagram (see `docs/architecture.md`)
- ⬜ Physio interviews (2–3) for pain-point sourcing
- ⬜ 5–8 min demo video following the script in `docs/concept.md`
- ⬜ Project title, blurb, description, cover image, live link

---

## Later / stretch

- Mandarin UI + Mandarin voice (ElevenLabs multilingual / Tencent voices)
- WorkBuddy weekly digest to clinician + caregiver
- Caregiver read-only view
- Hip-replacement protocol, more exercises, more progression families (squat, lunge)
- Patient-facing web app (only if judges need a non-iPhone path)
