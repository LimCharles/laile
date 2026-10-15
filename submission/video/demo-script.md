# Laile demo script (about 7 minutes)

One story, told from both sides: **Mdm Tan**, 68, 16 days after a right knee replacement, and her
physio **Dr Nair**. Then a short look at the calisthenics side and how it's built.

Every line below in quotes under **Type or say** was tried on the live server on 12 Oct and gave
the reply shown. ADP replies take 10 to 30 seconds, so cut the waits when you edit.

## Before you record

- **Two screens.** Patient: the iPhone app from TestFlight (best: the mic listens all session) or the
  web app at https://43-156-108-79.sslip.io/app in Chrome. Physio: the portal on a laptop at
  https://43-156-108-79.sslip.io/portal (`clinician@laile.demo` / `laile-demo-2026`).
- **A fresh patient.** In the app tap **Physio patient**. Note the time: in the portal she appears as
  "Mdm Tan (demo guest HH:mm)". Me → Restart the demo gives a fresh one if a take goes wrong.
- **Check the server:** https://43-156-108-79.sslip.io/health should show the ADP planner.
- **Camera.** Seated knee straightening is the easiest move to film: a firm chair, side-on to the
  camera, about 2 metres away, whole body in frame. Use **Skip** to reach it.
- **Sound.** Phone volume up, quiet room. On the web, allow the camera and use **Speak** (or type in
  "Tell Lele").
- **Don't open her portal page early.** Lele's summary is cached for 30 minutes, and you want it to
  include what happens in the demo. Open it in scene 6 and cut the wait.

## 1. The problem (0:00 to 0:25)

**Screen:** title slide or you on camera.

**Say:** "Up to half of people in rehab don't keep up their home exercises, and between visits the
physio can't see any of it. A checkbox can't tell a done exercise from one that was stopped because
it hurt. This is Laile, and Lele, the coach that keeps people going at home."

## 2. Mdm Tan's morning (0:25 to 1:05)

**Screen:** patient, Today, then the Lele tab.

**Do:** show Today: her program signed by Dr Nair, her move streak, "Plan something new with Lele".
Open the Lele tab. On "How's your knee feeling compared with yesterday?" tap **Worse**.

**Lele replies:** "Sorry to hear that. I've made today's session gentler (smaller range, shorter
holds) and noted it for Dr. Priya Nair. If it keeps getting worse, or you notice a hot, swollen calf
or a fever, contact your care team today."

**Say:** "Lele starts the conversation. A worse morning changes today's session in code, and her
physio is told. The model doesn't decide that."

## 3. A session: the camera counts, Lele listens (1:05 to 2:40)

**Screen:** patient. Today → **Start session**.

**Do:** pause on the session list: heel slides are marked **eased** because last week they hurt.
Continue (pain before: 1). Let Lele introduce the first move, then **Skip** to Seated knee
straightening. Do 2 reps that stop short of straight, so they don't count.

**Say, mid-set:** "I can't straighten it that far, can you make it easier?" (or tap **Make it easier**)
**Lele:** "Of course. I've made it a little easier, so a smaller movement counts now. Go as far as is
comfortable. Your physio will see that you asked." Your next reps count.

**Type or say:** "it's just pulling at the back"
**Lele:** "That pulling feeling is normal. Keep breathing." (carries on counting)

**Type or say:** "ow, sharp, on the inside of my knee"
**Lele:** "Let's pause. From zero to ten, how bad is the pain?"

**Type or say:** "about a six"
**Lele:** "Let's stop this exercise. I've noted exactly what happened for your records."

**Do:** tap **End**, set pain after to 3, show the results card: reps, XP, and "Lele noted: Sharp pain,
inside of right knee, 6/10; ... rep ..., knee bent to ...°".

**Say:** "A rep only counts when the knee reaches the target angle. When she can't reach it, Lele
eases the target on the spot, never below half the range her physio set, and keeps her words for
Dr Nair. When she says it's sharp, fixed rules apply her physio's pain limits: above 4 stops the
set, 6 stops the exercise. The exact moment is logged with the knee angle, and next time that
exercise is eased. The video never leaves the phone."

## 4. Ask Lele (2:40 to 3:20)

**Screen:** patient, Lele tab.

**Type:** "How am I doing?"
**Lele (ADP, about 25 s, cut it):** her knee bend (86°, up from 62°), the straightening gap, what
that means for chairs and stairs, the sore spot it eased, and one next step.

**Type:** "I have chest pain and feel dizzy"
**Lele (instant):** "Please stop and call 995 now, or ask someone nearby to help you."

**Say:** "Lele is an agent on Tencent Cloud ADP with a physio knowledge base. The server sends her
real numbers with every message. Red flags and medicine dose questions never reach the model: fixed
rules answer first."

Optional, 10 seconds: "Can I take two more paracetamol before my exercises?" → "That's one for your
doctor or pharmacist. I'll add it to your questions for your next visit."

Optional, 20 seconds: tap the **phone** icon to call Lele and say "my knee was stiff this morning
but the exercises helped". Lele answers out loud in the same voice, and the call is saved in the
chat like any message.

## 5. New goals, planned in chat (3:20 to 4:30)

**Screen:** patient, Lele tab.

**Do:** tap **Plan a new program** (iPhone build 4 or the web app; on an older build, type "my goals
have changed"), then answer:

| Lele asks | You answer |
|---|---|
| What would you like to work on now? | type "I want to get stronger so stairs feel easier" |
| How many minutes on most days? | tap **15 minutes** |
| How much do you exercise? | tap **I move now and then** |
| Anywhere that hurts? | type "my right knee, it's the new one" |
| Has a doctor told you to be careful? | tap **No** |

**Lele (ADP, about 20 s, cut it):** "From your new goals I've drafted 'Gentle Strength for ...'",
one reason per exercise, then "It stays inside Dr. Priya Nair's limits, and I've sent it to them to
approve."

**Do:** open **Me**: "What Lele knows about you" now shows her goals, 15 minutes, knees, her words.

**Say:** "She changed her goals in her own words. Lele drafted a program from the knowledge base,
using only exercises we've vetted, and code checked it against her physio's limits. Because she's
in a physio's care, nothing starts until Dr Nair says yes. Everything she tells Lele builds one
record that Lele reads before every reply."

## 6. Dr Nair's side (4:30 to 5:55)

**Screen:** portal on the laptop.

**Do:** **Today from Lele**: her new pain report and "Set new goals with Lele, who drafted ... for you
to approve". Open her patient page.

**Show Lele's summary** (ADP, about 15 s on first open, cut it): adherence, knee bend with real
numbers, "within the typical week 2 to 6 aim to pass 90°", the sharp pain she just reported, the
plan waiting for approval, and one thing to discuss at the next visit.

**Do:** scroll: the pain report with her exact words, set, rep and knee angle; the knee bend chart
against baseline. Back on Today from Lele, tap **Approve**.

**Screen:** patient. Lele's new message: "Good news: Dr. Priya Nair approved the plan I drafted from
your new goals, ... The first session is a quick check-in." with **Start check-in**.

**Say:** "Dr Nair gets a brief Lele wrote from the record and the knowledge base. Every number in it
comes from code, so the model only summarises. She approves, and Mdm Tan's new plan starts with a
check-in that sets her targets."

Optional, 30 seconds: open her program, and under **Ask Lele to change this program** type "make it gentler, she had a flare this week" and tap **Ask Lele**. Lele drafts a
gentler version on ADP (about 20 s, cut it); nothing reaches her until Dr Nair signs it.

Optional: with a second phone mid-session, her page shows the session live (reps and knee angle
every 2 seconds).

## 7. Beyond physio: calisthenics (5:55 to 6:25)

**Screen:** web app on the laptop, **Calisthenics** demo (or the iPhone).

**Do:** Programs: First push-up, Squat strong, Core foundations. Today: Lele's plan with **Start
check-in**.

**Say:** "When physio ends, people move on to calisthenics with their limits carried over. People
without a physio start here and plan with Lele too. It's the same app on iPhone or in any browser,
with nothing to install."

## 8. How it's built, and why it's safe (6:25 to 7:10)

**Screen:** the architecture slide from the deck.

**Say:** "Lele talks, code decides. Lele runs on Tencent Cloud ADP for conversation, program drafts
and the physio's brief. Counting, pain limits, red flags and every number a physio sees are tested
rules, 168 automated tests. Video stays on the device. Physios sign every program and approve every
plan. It runs on Tencent Cloud Lighthouse, the brand was made in Miora, and CodeBuddy audited the
safety rules and fixed what it found. Laile: home physio that counts every rep and checks in."

## A 3-minute version (Demo Day)

Scenes 3 (sharp pain only), 5 (start it, then cut to the result) and 6 (summary and Approve), with
one sentence each from 1 and 8. Before you go on stage: open her patient page once in a second tab
right after you send the plan, so the summary is ready when you get there.

## If something goes wrong

- **Lele is slow:** say "Lele is checking her record" and carry on; ADP takes 10 to 30 seconds.
- **The camera won't start counting:** step back until your whole body is in frame and turn side-on;
  Lele says what it needs ("I can't see your ankle").
- **A take is spoiled:** Me → Restart the demo with fresh data, then pick up in the portal under the
  new "demo guest" time.
