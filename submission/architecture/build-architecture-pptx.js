// Builds submission/architecture/laile-architecture.pptx for the hackathon form.
const path = require('path');
const pptxgen = require('pptxgenjs');
const { applyTheme } = require('/Users/caplim/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/d96223ff-4f3d-4bea-a1e2-87e2dbab2b4f/e406a18d-0142-4da6-b532-e86e9f7e687f/skills/pptx/scripts/apply_theme.js');

const REPO = '/Users/caplim/Coding/tencent-hackathon/.claude/worktrees/pt-app-ideation-7860ae';
const OUT = path.join(REPO, 'submission/architecture/laile-architecture.pptx');

const THEME = {
  name: 'Laile',
  headFontFace: 'Calibri',
  bodyFontFace: 'Calibri',
  colors: {
    dk1: '17211C', lt1: 'FFFFFF', dk2: '0F8A6A', lt2: 'F6F7F5',
    accent1: '0F8A6A', accent2: 'E8930C', accent3: 'DFF3EC', accent4: '5D6B63', accent5: 'C62828', accent6: '3CC49B',
    hlink: '0F8A6A', folHlink: '0B6B52',
  },
};

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE'; // 13.333" x 7.5"
pres.title = 'Laile architecture';
pres.author = 'Charles Andrew Lim';
pres.company = 'Laile';
pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
const C = pres.SchemeColor;

// ---- Layouts --------------------------------------------------------------
pres.defineSlideMaster({
  title: 'TITLE',
  background: { color: C.accent1 },
  objects: [
    { placeholder: { options: { name: 'title', type: 'title', x: 0.8, y: 2.25, w: 8.4, h: 1.3, fontSize: 48, bold: true, color: C.background1, align: 'left', valign: 'bottom', margin: 0 }, text: '' } },
    { placeholder: { options: { name: 'body', type: 'body', x: 0.8, y: 3.75, w: 8.4, h: 1.2, fontSize: 20, color: C.accent3, valign: 'top', margin: 0 }, text: '' } },
    { placeholder: { options: { name: 'links', type: 'body', x: 0.8, y: 6.25, w: 11.7, h: 0.6, fontSize: 12, color: C.accent3, valign: 'bottom', margin: 0 }, text: '' } },
  ],
});

pres.defineSlideMaster({
  title: 'CONTENT',
  background: { color: C.background1 },
  objects: [
    { placeholder: { options: { name: 'title', type: 'title', x: 0.6, y: 0.35, w: 12.1, h: 0.8, fontSize: 32, bold: true, color: C.text1, align: 'left', valign: 'middle', margin: 0 }, text: '' } },
    { text: { text: 'Laile  ·  Tencent Cloud AI CAN DO IT Hackathon Singapore 2026', options: { x: 0.6, y: 7.0, w: 9, h: 0.3, fontSize: 10, color: C.accent4, margin: 0 } } },
  ],
  slideNumber: { x: 12.2, y: 7.0, w: 0.5, h: 0.3, fontSize: 10, color: C.accent4, align: 'right' },
});

const notes = (slide, text) => slide.addNotes(text);

// ---- 1. Title ---------------------------------------------------------------
pres.addSection({ title: 'Overview' });
{
  const s = pres.addSlide({ masterName: 'TITLE', sectionTitle: 'Overview' });
  s.addText('Laile architecture', { placeholder: 'title' });
  s.addText('Home physio that counts every rep and checks in. How it is built, where the trust boundary sits, and why.', { placeholder: 'body' });
  s.addText('github.com/LimCharles/laile   ·   43-156-108-79.sslip.io   ·   Charles Andrew Lim, Healthcare track, Challenge Statement 2', { placeholder: 'links' });
  s.addImage({ path: path.join(REPO, 'submission/brand/app-icon-1024.png'), x: 9.85, y: 1.85, w: 2.75, h: 2.75, objectName: 'App icon', altText: 'Laile app icon: the 乐 mark' });
  notes(s, 'Laile is a home physiotherapy and calisthenics app with a clinician portal. Lele, its coach, is an agent on Tencent Cloud ADP.');
}

// ---- 2. Architecture diagram ----------------------------------------------------
pres.addSection({ title: 'Architecture' });
{
  const s = pres.addSlide({ masterName: 'CONTENT', sectionTitle: 'Architecture' });
  s.addText('Architecture and trust boundary', { placeholder: 'title' });
  const w = 11.8, h = w * 1124 / 2397;
  s.addImage({ path: path.join(REPO, 'submission/diagram/architecture.png'), x: (13.333 - w) / 2, y: 1.3, w, h, objectName: 'Architecture diagram',
    altText: 'Patient phone or browser, Laile API on Tencent Cloud, models on ADP and ElevenLabs, and the clinician portal' });
  notes(s, 'Video stays on the device. Counts, angles and what the person says go to the Laile API on Lighthouse. The safety gate runs before any model. ADP drafts, chats and summarises; code decides.');
}

// ---- 3. AI and safety -------------------------------------------------------------
{
  const s = pres.addSlide({ masterName: 'CONTENT', sectionTitle: 'Architecture' });
  s.addText('How the AI is used, and kept safe', { placeholder: 'title' });
  const head = (t) => ({ text: t, options: { bold: true, color: C.background1, fill: { color: C.accent1 }, fontSize: 14 } });
  const rows = [
    ['Conversation and explanations', 'Lele on Tencent Cloud ADP (Hy3, 12-document knowledge base)', 'Real numbers sent with every message; red flags and dose questions answered by rules first'],
    ['Program drafts and revisions', 'Lele on ADP, PLAN REQUEST mode', 'Vetted exercise library only; contraindication checker; physio signs or approves'],
    ["The physio's brief", 'Lele on ADP, CLINICIAN BRIEF mode', 'Every number and flag is computed by code and passed in'],
    ['Planning by chat', 'Five questions in code, then an ADP draft', "A supervised patient's plan waits for the physio's yes"],
    ['Remembering what hurt', 'Care notes (CareMemory)', 'Easing computed by code; the physio sees every note'],
    ['Mid-session safety', 'Symptom rules, red flags, "make it easier"', "The physio's pain limits decide; never below half the range"],
    ['Seeing movement', 'Apple Vision (iPhone), MediaPipe (browser)', 'Video stays on the device; no count without a clear view'],
  ];
  const body = rows.map((r, i) => r.map((t, j) => ({ text: t, options: { fontSize: 13, color: C.text1, bold: j === 0, fill: { color: i % 2 ? C.background1 : C.background2 } } })));
  s.addTable([[head('Job'), head('Done by'), head('Kept safe by')], ...body], {
    x: 0.6, y: 1.35, w: 12.1, colW: [2.9, 3.9, 5.3], rowH: 0.62, valign: 'middle', margin: [4, 8, 4, 8],
    border: { type: 'solid', pt: 0.75, color: 'E1E7E3' }, objectName: 'AI and safety table',
  });
  notes(s, 'The model talks; code decides. Every number a physio sees comes from tested code.');
}

// ---- 4. Prompts -------------------------------------------------------------------
{
  const s = pres.addSlide({ masterName: 'CONTENT', sectionTitle: 'Architecture' });
  s.addText('How prompts drive Lele', { placeholder: 'title' });
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y: 1.3, w: 12.1, h: 0.75, rectRadius: 0.12, fill: { color: C.accent3 }, line: { color: C.accent3 }, objectName: 'Rules first banner' });
  s.addText([
    { text: 'Rules first. ', options: { bold: true, color: C.accent1 } },
    { text: 'Red flags, medicine dose questions and pain limits are answered by tested code before any model sees a message.', options: { color: C.text1 } },
  ], { x: 0.85, y: 1.3, w: 11.6, h: 0.75, fontSize: 15, valign: 'middle', margin: 0, isTextBox: true });

  const cards = [
    ['1', 'Chat', 'Sent: the person\'s program, goals, measurements, last session and care notes, then the question and a reminder of Lele\'s voice.',
      'Back: a reply in Lele\'s voice, under 120 words, quoting real numbers. A "remember" line becomes a care note only after code checks it.'],
    ['2', 'PLAN REQUEST', 'Sent: goals, minutes a day, experience, areas to protect, the physio\'s precautions, and the only exercise ids allowed.',
      'Back: a JSON draft, then a schema check and the contraindication checker. A physio patient\'s plan waits for approval.'],
    ['3', 'CLINICIAN BRIEF', 'Sent: adherence, key measures with numbers, recent reports, care notes and pending approvals, all computed by code.',
      'Back: 4 to 6 lines for the physio, with what the knowledge base says is typical at this stage.'],
  ];
  cards.forEach(([n, title, sent, back], i) => {
    const x = 0.6 + i * 4.125;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 2.35, w: 3.85, h: 3.25, rectRadius: 0.15, fill: { color: C.background2 }, line: { color: 'E1E7E3', width: 0.75 }, objectName: `Card ${title}` });
    s.addShape(pres.shapes.OVAL, { x: x + 0.3, y: 2.6, w: 0.55, h: 0.55, fill: { color: C.accent1 }, line: { color: C.accent1 }, objectName: `Step ${n}` });
    s.addText(n, { x: x + 0.3, y: 2.6, w: 0.55, h: 0.55, fontSize: 18, bold: true, color: C.background1, align: 'center', valign: 'middle', margin: 0, isTextBox: true });
    s.addText(title, { x: x + 1.0, y: 2.6, w: 2.65, h: 0.55, fontSize: 19, bold: true, color: C.text1, valign: 'middle', margin: 0, isTextBox: true });
    s.addText([
      { text: sent, options: { breakLine: true, paraSpaceAfter: 10 } },
      { text: back },
    ], { x: x + 0.3, y: 3.35, w: 3.3, h: 2.1, fontSize: 14, color: C.text1, valign: 'top', margin: 0, isTextBox: true });
  });
  s.addText([
    { text: 'One agent, three modes. ', options: { bold: true, color: C.accent1 } },
    { text: "The server starts each message with its mode, and Lele's prompt on ADP has a section for each. The same knowledge base grounds all three.", options: { color: C.text1 } },
  ], { x: 0.6, y: 5.95, w: 12.1, h: 0.6, fontSize: 15, valign: 'middle', margin: 0, isTextBox: true });
  notes(s, 'All three go to the same ADP agent; the server prefixes PLAN REQUEST or CLINICIAN BRIEF and the agent prompt has a section for each mode.');
}

// ---- 5. Built with ------------------------------------------------------------------
pres.addSection({ title: 'Build' });
{
  const s = pres.addSlide({ masterName: 'CONTENT', sectionTitle: 'Build' });
  s.addText('Built with', { placeholder: 'title' });
  const cols = [
    ['Tencent Cloud and tools', C.accent1, [
      ['ADP', 'Lele on the Hy3 model with a 12-document knowledge base: chat, program drafts, the physio\'s summary'],
      ['Lighthouse', 'the server, web app and clinician portal (Docker, Caddy, HTTPS)'],
      ['CodeBuddy / WorkBuddy', 'safety and ADP audits; fixes reviewed and merged'],
      ['Miora', 'logo, cover, app icon and the Lele mascot'],
    ]],
    ['iPhone and web apps', C.text1, [
      ['Swift 6, SwiftUI', 'feature modules in LaileKit'],
      ['Apple Vision, Speech', 'body pose for reps, holds and angles; spoken symptoms'],
      ['Web app', 'plain JavaScript, MediaPipe pose, the same API'],
      ['ElevenLabs', "Lele's voice on phone and web, cached per line"],
    ]],
    ['Server and shared code', C.accent2, [
      ['Vapor (Swift)', 'API, Leaf portal, live session view'],
      ['Fluent', 'SQLite, or TencentDB for PostgreSQL'],
      ['LaileCore', 'safety rules, programs, care notes and the session engine, shared by phone and server'],
      ['166 automated tests', '127 core, 33 server, 6 web'],
    ]],
  ];
  cols.forEach(([title, color, items], i) => {
    const x = 0.6 + i * 4.125;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 1.35, w: 3.85, h: 4.2, rectRadius: 0.15, fill: { color: C.background2 }, line: { color: 'E1E7E3', width: 0.75 }, objectName: `Column ${title}` });
    s.addText(title, { x: x + 0.3, y: 1.55, w: 3.3, h: 0.5, fontSize: 18, bold: true, color, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(items.flatMap(([k, v], j) => [
      { text: `${k}: `, options: { bold: true } },
      { text: v, options: { breakLine: j < items.length - 1, paraSpaceAfter: 12 } },
    ]), { x: x + 0.3, y: 2.2, w: 3.3, h: 3.2, fontSize: 14, color: C.text1, valign: 'top', margin: 0, isTextBox: true });
  });
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y: 5.85, w: 12.1, h: 0.75, rectRadius: 0.12, fill: { color: C.accent3 }, line: { color: C.accent3 }, objectName: 'Links' });
  s.addText([
    { text: 'Try it: ', options: { bold: true, color: C.accent1 } },
    { text: 'web app 43-156-108-79.sslip.io/app   ·   iPhone testflight.apple.com/join/WuymKzUH   ·   source github.com/LimCharles/laile', options: { color: C.text1 } },
  ], { x: 0.85, y: 5.85, w: 11.6, h: 0.75, fontSize: 14, valign: 'middle', margin: 0, isTextBox: true });
  notes(s, 'One language for the domain logic; the phone and the server run the same LaileCore package.');
}

// ---- 6. Trade-offs ---------------------------------------------------------------------
{
  const s = pres.addSlide({ masterName: 'CONTENT', sectionTitle: 'Build' });
  s.addText('Key design trade-offs', { placeholder: 'title' });
  const rows = [
    ['Native iPhone app, web app, Swift server', 'Native camera performance and one language for the shared logic. The web app covers Android and laptops; its session engine is a JavaScript port tested against the same plan.'],
    ['Pose on the device', 'No video upload, and the iPhone works offline. Joints are 2D, so angles are estimates for tracking trends, and reports say so.'],
    ['Rules for safety, a model for talk', 'Predictable, testable safety. Unusual phrasings fall back to a clarifying question instead of a guess.'],
    ['ADP knowledge base', "Curated, reviewable content. Its answer template can override the persona, so each message restates Lele's voice and replies are tidied."],
    ['Server-rendered portal', 'Fast to build and prints cleanly as a pre-visit report, with no second front-end stack.'],
  ];
  rows.forEach(([choice, why], i) => {
    const y = 1.35 + i * 1.07;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y, w: 3.7, h: 0.9, rectRadius: 0.12, fill: { color: C.accent3 }, line: { color: C.accent3 }, objectName: `Choice ${i + 1}` });
    s.addText(choice, { x: 0.8, y, w: 3.3, h: 0.9, fontSize: 15, bold: true, color: C.accent1, valign: 'middle', margin: 0, isTextBox: true });
    s.addText(why, { x: 4.6, y, w: 8.1, h: 0.9, fontSize: 14, color: C.text1, valign: 'middle', margin: 0, isTextBox: true });
  });
  notes(s, 'Each choice trades something; these are the ones that shaped Laile.');
}

(async () => {
  await pres.writeFile({ fileName: OUT });
  await applyTheme(OUT, THEME);
  console.log('wrote', OUT);
})();
