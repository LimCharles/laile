# Recording run sheet (about 35 minutes)

Four long takes. Don't stop for mistakes: pause, then redo the step. Claude cuts everything,
adds the titles, captions, split screens and music. You don't record any title slides.

## Set up the room (10 minutes)

```
        [ window or lamp: light on you ]

   you, on a firm chair, side-on to the phone
   (right leg nearest the phone)
              |
              |  about 2 m
              |
   iPhone, standing up on a stool or chair seat, at chair height
   Mac on a table just behind the phone, a little higher, camera on
```

1. **iPhone:** TestFlight → update Laile to **build 4**. In Laile: Me → **Restart demo with fresh data**
   (or tap **Physio patient** on the welcome screen).
2. **iPhone:** turn on Do Not Disturb, brightness and volume up. Add Screen Recording to Control
   Center. Long-press it and set **Microphone OFF**: the Mac records your voice, and Laile keeps
   the phone's mic to itself so Lele can hear you.
3. **Mac:** open QuickTime → File → New Movie Recording. Check that the chair and your whole body,
   from head to feet, are in the picture. This is the wide camera.
4. Wear shorts or fitted trousers so the camera can see your knee.

## Take 1: the patient (about 15 minutes)

Start the **Mac recording**, then the **iPhone screen recording**. Stand in front of both, tap the
iPhone screen once and **clap once**.

**At the chair, phone in hand (the Mac films you using it):**
1. Laile → **Today**. Scroll slowly to the bottom and back up.
2. **Lele** tab. On "How's your knee feeling compared with yesterday?" tap **Worse**. Read the reply.
3. Type **How am I doing?** and send. Wait for the reply, even if it takes a minute.
4. Type **Why am I doing heel slides?** and wait.
5. Type **Can I take two more paracetamol before my exercises?**
6. Type **I have chest pain and feel dizzy**. (It's only a test of the safety reply.)

**The session:**
7. **Today** → **Start session**. For pain right now, tap **1**.
8. Tap **Skip** four times, until the top says **Seated knee straightening**.
9. Stand the phone on the stool, sit side-on with your **right leg nearest the phone**, back
   straight, feet on the floor. Wait until Lele says "Perfect, I can see you".
10. **Clap once** (for syncing).
11. Do **2 reps, straightening only three-quarters of the way** (don't lock the knee). They won't count.
12. Say: **"I can't straighten it that far, can you make it easier?"** Wait for Lele.
13. Say: **"Still a bit hard."** Wait for Lele.
14. Do **3 reps, three-quarters of the way** again. These count now.
15. Say: **"It's just pulling at the back."** Do 1 more rep.
16. Touch the inside of your knee, wince, and say: **"Ow, sharp, on the inside of my knee."**
17. When Lele asks zero to ten, say: **"About a six."**
18. Pick up the phone. For pain now, tap **3**. Hold on the results for 5 seconds. Smile at the Mac,
    thumbs up.

**Planning, memory and a call:**
19. **Lele** tab → **Plan a new program**. Answer:
    - type **I want to get stronger so stairs feel easier**
    - tap **15 minutes**
    - tap **I move now and then**
    - type **my right knee, it's the new one**
    - tap **No**, then wait for the plan (up to a minute).
20. **Me** tab: scroll slowly through "What Lele knows about you" and "What Lele remembers".
21. **Lele** tab → **phone icon**. Say: **"My knee was stiff this morning, but the exercises helped."**
    Listen to Lele, then End.

Stop the iPhone recording, then the Mac recording.

## Take 2: the physio (about 5 minutes, Mac screen)

Press Cmd+Shift+5 → Record Entire Screen. In the browser at 125% zoom:

1. Open https://43-156-108-79.sslip.io/portal and log in as `clinician@laile.demo` /
   `laile-demo-2026`.
2. On **Today from Lele**, find your **Mdm Tan (demo guest HH:mm)**. Hover over her pain report
   and the plan waiting for approval.
3. Click her name. Wait for **Lele's summary** to fill in (up to a minute), then scroll slowly:
   needs attention, charts, her pain reports.
4. Back to **Patients**. Next to "Set new goals with Lele…", click **Approve**.
5. Open her patient page → her program. Under **Ask Lele to change this program**, type
   **make it gentler, she had a flare this week** → **Ask Lele**. Wait, then scroll the new draft.

Stop the recording (the stop button in the menu bar).

## Take 3: the good news (about 1 minute, iPhone screen)

Start the iPhone screen recording. On the **Lele** tab, show Dr Nair's "Good news…" message, tap
**Start check-in**, let Lele introduce the first move, then End. Stop the recording.

(Claude has already recorded the web app, the calisthenics demo and the phone-size view.)

## Take 4: talk to the Mac (about 10 minutes)

QuickTime → New Movie Recording. Sit facing the Mac, camera at eye level, light on your face.
Read each line, pause two seconds, then the next. Redo any line you trip on.

1. Hi, I'm Charles. This is Laile, home physio that counts every rep and checks in.
2. Up to half of people in rehab stop doing their home exercises, and between visits their physio can't see any of it.
3. I'm using Mdm Tan's demo account. She's 68, sixteen days after a knee replacement.
4. Every morning, Lele, her coach, checks in. A worse morning makes today's session gentler, and her physio is told.
5. Lele runs on Tencent Cloud ADP with a physio knowledge base, and every reply uses her real numbers.
6. Red flags and medicine dose questions never reach the model. Fixed rules answer first.
7. In a session, the camera counts every rep and measures her knee. The video never leaves the phone.
8. When she can't reach the target, Lele makes it easier on the spot, never below half the range her physio set.
9. When she says it's sharp, her physio's pain limits decide: above four stops the set, six stops the exercise. The exact moment is saved with her knee angle.
10. When her goals change, she plans a new program just by talking to Lele.
11. Lele drafts it from the knowledge base, using only exercises we've vetted, and checks it against her physio's limits. Because she's in a physio's care, nothing starts until her physio says yes.
12. Everything she tells Lele builds one record that Lele reads before every reply.
13. Her physio, Dr Nair, sees what matters first.
14. Lele writes her a short brief from the record and the knowledge base. Every number in it comes from code.
15. She approves the plan, and Mdm Tan gets the news straight away.
16. She can also ask Lele to change a program in plain words. Nothing reaches the patient until she signs it.
17. After physio, people carry on with calisthenics, with their limits carried over. It works on iPhone or in any browser.
18. Lele talks, code decides. Built on Tencent Cloud ADP and Lighthouse, audited with CodeBuddy, branded with Miora, and covered by 166 automated tests.
19. A quick reflection on how I built it. I'm a solo builder, so I kept one language, Swift, and one shared engine for the phone and the server.
20. My rule was simple: the model talks, the code decides. Anything to do with safety is plain code with tests, and Lele handles the conversation.
21. WorkBuddy audited my safety rules and found real bugs. "No pain, but my foot is numb" was answered with "carry on". I reviewed its fixes and merged them.
22. Miora made the whole brand from one brief: the logo, the app icon and Lele herself.
23. My tips: send your ADP agent real numbers with every message, restate its voice, because the knowledge base template can take over, and test with the way people actually talk.
24. Laile. Home physio that counts every rep and checks in.

(Optional, your call: one line on any other coding assistant you used, e.g. "I also used Claude Code for much of the coding.")

Then sit still and silent for **10 seconds** (room tone). Stop.

## Send

AirDrop the iPhone recordings to the Mac. Put all files, as they are, in
`~/Desktop/laile-video-raw/` and tell Claude. No renaming needed.
