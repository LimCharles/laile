# Laile demo video: features and shot list

The script is [demo-script.md](demo-script.md). This page lists every feature, what only you can
record, and what Claude makes.

## Every feature

### Lele, the agent (Tencent Cloud ADP)
- [ ] Starts conversations: morning check-in, medicine reminders, a nudge on quiet days, "what's getting in the way?", plateaus, visit prep. Quiet 9 pm to 7 am, at most three a day.
- [ ] Acts on answers: "Worse this morning" makes today's session gentler and tells the physio.
- [ ] Chat with real numbers: "How am I doing?" (knee bend, gap, what it means for chairs and stairs).
- [ ] Explains exercises from the knowledge base: "Why am I doing heel slides?"
- [ ] Plans a new program in chat: five questions, then ADP drafts it; it replaces Lele's old plan, or goes to the physio to approve.
- [ ] Remembers: sore spots and what was eased (care notes); "What Lele knows about you" on Me.
- [ ] Coaches sessions out loud (ElevenLabs voice), takes turns, asks "How did that feel?" between sets.
- [ ] Makes it easier on request mid-set: "I can't straighten it that far" (never below half the range).
- [ ] Pain rules: pulling carries on; sharp asks 0 to 10; above 4 stops the set, 6 stops the exercise.
- [ ] Red flags end everything: "chest pain" means call 995. Dose questions go to the doctor or pharmacist.
- [ ] Voice call with Lele (phone icon in the Lele tab).
- [ ] Writes the physio's brief (patient page) from the record plus the knowledge base.
- [ ] Revises a program when the physio asks in plain words ("make it gentler, she had a flare").
- [ ] Drafts a program from a referral for a new patient (portal, New patient, Draft program with AI).

### The patient app (iPhone, and the same in any browser)
- [ ] Demo accounts with two weeks of history; sign in, register, link a physio code.
- [ ] Today: signed program, streak and level, medicines with Taken and "What's this for?", quick sessions.
- [ ] Programs: physio program, Lele's plan, Laile catalog (calisthenics, mobility, after physio), Join or Ask physio.
- [ ] Sessions: camera counts reps and times holds, measures knee bend and arm lift; setup guidance ("I can't see your ankle"); form cues; first session is a check-in that sets targets; pain before and after; results with XP and badges.
- [ ] Progress: knee bend, straightening gap, reps, holds and pain against baseline; milestones; plateau flags.
- [ ] Live classes (iPhone): timed follow-along with a leaderboard.

### The physio portal
- [ ] Today from Lele: most pressing first; approve or decline requests and Lele's plans inline.
- [ ] Patient page: Lele's summary, live session view, what needs attention, charts against baseline, pain reports with exact words and knee angle.
- [ ] Care notes: keep an exercise eased, close a note, add notes for Lele.
- [ ] Sign every program version; pre-visit report (prints); discharge to a follow-on program.

### Under the hood (said, not shown)
- [ ] Tencent Cloud ADP (Hy3, 12-document knowledge base), Lighthouse, ElevenLabs, TestFlight, web app.
- [ ] Code decides, the model talks; video stays on the device; physios sign.
- [ ] 166 automated tests; CodeBuddy safety audit and fixes; brand made in Miora.

## What only you can record

### Before you start
- [ ] Update to **build 4** in TestFlight (it has the Plan a new program and Make it easier buttons).
- [ ] Fresh demo: Me → Restart the demo with fresh data. Note the time it shows in the portal.
- [ ] Phone: Do Not Disturb, brightness up, volume up, battery over 50%.
- [ ] Control Center → long-press Screen Recording → **Microphone On**.
- [ ] Mac: light mode, browser zoom 125%, bookmarks bar hidden, other tabs closed.
- [ ] Clothes: shorts or fitted trousers so the camera sees your knee; plain background; light in front of you, not behind.

### Footage (landscape, 1080p or 4K, 30 fps)
1. [ ] **Intro to camera** (10 s): "Hi, I'm Charles. This is Laile, home physio that counts every rep and checks in." Look at the lens.
2. [ ] **Setup B-roll** (10 s): propping the phone on a chair side-on, stepping back, sitting down.
3. [ ] **Session, wide shot** (second phone or the Mac's camera, whole body, side-on, about 2 m away). Start this camera AND the iPhone screen recording, then **clap once** where both can hear it. Then, on Seated knee straightening:
   - [ ] two reps that stop short (they won't count)
   - [ ] say "I can't straighten it that far, can you make it easier?"
   - [ ] three reps that now count
   - [ ] say "it's just pulling at the back"
   - [ ] say "ow, sharp, on the inside of my knee", then "about a six"
   - [ ] tap End, set pain after to 3
4. [ ] **Calisthenics shot** (optional, 15 s): a few squats or knee push-ups on the Calisthenics demo, same two-camera setup and clap.
5. [ ] **Lele voice call** (iPhone screen recording, mic on): tap the phone icon and say "my knee was stiff this morning but the exercises helped".
6. [ ] **Physio B-roll** (optional, 5 s): over the shoulder at the laptop with the portal open.
7. [ ] **Room tone**: 10 seconds of silence in the room where you record the voiceover.

### Voiceover (Voice Memos, quiet room, phone about 20 cm away)
- [ ] One memo per scene, reading the **Say** lines from the script. Take a breath between lines; mistakes are fine, just repeat the line.
- [ ] Say once, near the start: "I'm using Mdm Tan's demo account."

### Screen recordings (from the script)
- [ ] iPhone: scenes 2, 3, 4, 5, and Lele's "Good news" message after the approval in 6.
- [ ] Mac: the portal in scene 6 (and the web app for scene 7 if you don't use the iPhone).

### Sending
- [ ] AirDrop everything into `~/Desktop/laile-video-raw/`, named by scene: `01-intro.mov`, `03-session-cam.mov`, `03-session-phone.mov`, `03-voice.m4a`, and so on.
- [ ] Tell Claude the folder is ready.

## What Claude makes

- [ ] Creatives in **Miora**: title cards, scene cards, Lele mascot poses (thinking, cheering, careful), end card. Log in to Miora in the browser panel first.
- [ ] Editing in HyperFrames: syncing on the clap, split screen (you next to the phone), phone and browser frames, zoom-ins, callouts ("Above 4/10 stops the set"), labels when an ADP wait is cut.
- [ ] Captions from your voiceover, burned in, plus a subtitle file.
- [ ] Architecture and "built with Tencent" slides, quiet music under the voice.
- [ ] 1080p render, 7 to 8 minutes, plus a 3-minute Demo Day cut.
