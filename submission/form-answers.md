# Submission form answers

Copy each answer into the Google Form. Files to upload are listed at the end.

## Project Title

Laile (莱乐)

## Short Blurb (under 10 words)

Home physio that counts every rep and checks in.

## Project Description

PROJECT OVERVIEW: TARGET SCENARIOS, USERS AND VALUE PROPOSITION

Most physical therapy happens at home, between visits, where nobody can see it. Laile is an iPhone app, a web app and a clinician portal built around one idea: every exercise is measured by the camera, and a coach called Lele keeps the person going between visits.
- Scenario: home exercise after a knee or hip replacement, a stiff shoulder or back pain, and staying strong afterwards with calisthenics.
- Users: patients such as Mdm Tan, 68, sixteen days after a knee replacement; people without a physio who want to get stronger; and their physiotherapists.
- Value: the camera counts every rep and measures knee bend and arm lift. Lele checks in each morning, adapts a session when something hurts or is too hard, remembers what was sore, plans new programs from the person's goals in chat, and writes the physio a brief. The physio sees sessions live, approves plans and signs every program.

REAL WORLD SCENARIO INSIGHTS: SOURCE OF PAIN POINTS, TARGET AUDIENCE AND CORE PROBLEM SOLVED

- Up to half of people in rehabilitation don't keep up their home exercises (Argent et al., JMIR mHealth 2018).
- A systematic review of 20 studies links poor adherence to low confidence, low mood, worry, pain during exercise, poor support and too many barriers (Jack et al., Manual Therapy 2010). Monitoring with feedback, goal setting and follow-up help (Peek et al., Physiotherapy 2016).
- Singapore is a super-aged society: 21.4% of citizens were 65 or older in 2026 (Population in Brief 2026). Joint replacements, falls prevention and staying independent all depend on exercise done at home.
- Core problem: between visits the physio is blind. A checkbox can't tell a done exercise from a skipped one, or from one stopped because it hurt. Problems surface weeks later. Laile replaces self-report with camera-verified sessions and gives every patient a coach that listens.

COMPREHENSIVE SOLUTION DESIGN: BUSINESS AND TECHNICAL ARCHITECTURE, AND HOW PROMPTS DRIVE THE AI

Technical architecture
- Patient side: a SwiftUI iPhone app (Apple Vision pose on the device) and a web app (MediaPipe pose in the browser). Both run the same session engine: reps count only at the target angle, holds only while in position, and video never leaves the device.
- Server: Swift (Vapor) on Tencent Cloud Lighthouse with the clinician portal. LaileCore, one shared Swift package, holds the safety rules, programs, care notes and session engine, so the phone and the server decide the same way. 168 automated tests.
- Lele: an agent on Tencent Cloud ADP (Hy3 model) with a 12-document knowledge base on rehabilitation, exercise and medicines. ElevenLabs gives Lele its voice, cached per line.
- Safety gate: red flags (chest pain, a hot swollen calf and others), medicine dose questions and the physio's pain limits are decided by tested code before any model sees a message.

How prompts drive the AI
- One ADP agent with a persona prompt and three modes. For chat, every message carries the person's record (program, goals, measurements, last session, care notes), the question, and a reminder of Lele's voice, so replies quote real numbers.
- PLAN REQUEST: the server sends goals, time, experience, areas to protect, the physio's precautions and the only exercise ids allowed. Lele returns a JSON draft, which a schema check and a contraindication checker validate. A physio patient's plan waits for the physio's approval.
- CLINICIAN BRIEF: the server sends adherence, measurements, reports and pending approvals, all computed by code. Lele writes 4 to 6 lines for the physio, adding what the knowledge base says is typical at this stage.
- Memory: when Lele hears something worth remembering, it adds a structured line that code checks before saving it as a care note. Easing an exercise is computed by code, never below half its range.
- The model talks; code decides.

Business architecture
- Clinics pay for visibility: verified adherence, live sessions and a prioritised daily list without extra visits. Proposed: a monthly fee per active patient.
- People stay after discharge: a calisthenics or mobility program with their limits carried over, and a consumer subscription for people without a physio.

BUSINESS VALUE: QUANTIFIABLE METRICS OR CLEARLY DEFINED IMPACT

- Adherence becomes measurable: sessions done against sessions prescribed, per patient, from camera-verified data (the portal shows, for example, "7 of 21 prescribed sessions").
- Every pain report arrives with the person's words, the exercise, set, rep and knee angle, so a physio acts the same day instead of at the next visit.
- Recovery is tracked against baseline and milestones, such as knee bend reaching 90° for chairs.
- Low running cost: pose estimation runs on the device, models are called only for conversation, drafts and briefs, and voice lines are paid for once.
- Pilot metrics: adherence against self-report, days to reach 90° knee bend, same-day response to pain reports, and how many patients keep exercising after discharge.

## Project Web Link

https://43-156-108-79.sslip.io

(Web app at /app, clinician portal at /portal with clinician@laile.demo / laile-demo-2026, iPhone app at https://testflight.apple.com/join/WuymKzUH)

## Demo Video Link

Upload the video to YouTube as Public or Unlisted and paste the link. Public with the hashtags below also counts for the social media bonus.

## Source Code

https://github.com/LimCharles/laile

## Social Media Post Link (bonus)

Post the demo on YouTube (Public) with this description:

> Laile: home physio that counts every rep and checks in. Lele, an agent on Tencent Cloud ADP, coaches sessions, adapts when something hurts, plans new programs in chat and briefs the physio. Try it: https://43-156-108-79.sslip.io
> #WorkBuddy #CodeBuddy #Miora #TencentCloudHackathon
>
> Music: "Wholesome" by Kevin MacLeod (incompetech.com), licensed under Creative Commons: By Attribution 4.0 License, http://creativecommons.org/licenses/by/4.0/

## Files to upload

| Field | File |
|---|---|
| Cover Image (max 1 MB) | `submission/cover/laile-cover-380x216.png` (100 KB) |
| WorkBuddy/CodeBuddy Conversation History (max 10 MB) | `submission/codebuddy/laile-codebuddy-history.pdf` (0.6 MB) |
| Architecture Diagram PPT (max 10 MB) | `submission/architecture/laile-architecture.pptx` (1.1 MB) |
