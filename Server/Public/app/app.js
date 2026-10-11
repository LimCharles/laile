// Laile in a browser: the same account, programs, sessions and Lele as the iPhone app.
// Plain modules, no build step. The server is the single source of truth; this file only
// fetches, renders and sends what the person does.

const $app = document.getElementById('app');
const TOKEN_KEY = 'laile.token';
let memoryToken = null;

// MARK: Storage and API

function getToken() {
  try { return localStorage.getItem(TOKEN_KEY) ?? memoryToken; } catch { return memoryToken; }
}

function setToken(token) {
  memoryToken = token;
  try { token ? localStorage.setItem(TOKEN_KEY, token) : localStorage.removeItem(TOKEN_KEY); } catch { /* private mode */ }
}

export async function api(method, path, body) {
  const headers = { accept: 'application/json' };
  const token = getToken();
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(`/${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (res.status === 401 && token) {
    signOut();
    throw new Error('Please sign in again.');
  }
  if (!res.ok) {
    let reason = '';
    try { reason = (await res.json()).reason; } catch { /* not JSON */ }
    throw new Error(reason || `Something went wrong (${res.status}). Try again in a moment.`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

/// The server reads dates as ISO 8601 without fractions of a second.
export const isoDate = (d = new Date()) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

export const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// LaileCore's CallName: "Mdm Tan (demo)" → "Mdm Tan", "Priya Nair" → "Priya".
const plainName = (name) => String(name || '').replace(/\s*\([^)]*\)\s*$/, '');
const firstName = (name) => {
  const parts = plainName(name).split(/\s+/).filter(Boolean);
  const titles = ['mdm', 'mr', 'mrs', 'ms', 'dr', 'madam', 'auntie', 'uncle'];
  if (parts.length > 1 && titles.includes(parts[0].toLowerCase().replace(/[^a-z]/g, ''))) return `${parts[0]} ${parts[1]}`;
  return parts[0] || 'there';
};
const words = (raw) => String(raw || '').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[-_]/g, ' ').toLowerCase();
const capital = (s) => s ? s[0].toUpperCase() + s.slice(1) : s;

function when(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const days = Math.round((startOfDay(new Date()) - startOfDay(d)) / 86400000);
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (days === 0) return `Today, ${time}`;
  if (days === 1) return `Yesterday, ${time}`;
  if (days < 7) return `${d.toLocaleDateString([], { weekday: 'long' })}, ${time}`;
  return d.toLocaleDateString([], { day: 'numeric', month: 'short' });
}

function startOfDay(d) { const c = new Date(d); c.setHours(0, 0, 0, 0); return c; }

// MARK: State

const S = {
  user: null,
  today: null,
  rewards: null,
  progress: null,
  catalog: null,
  lele: [],
  sending: false,
  busy: false,
  flash: null,
  authMode: 'signin',
};

const isSupervised = () => (S.today?.enrollments ?? []).some((e) => e.kind === 'clinical' && e.status === 'active');
const physioName = () => {
  const e = (S.today?.enrollments ?? []).find((x) => x.kind === 'clinical' && x.status === 'active');
  return e?.supervisorName ? plainName(e.supervisorName) : (S.user?.clinicianName ? plainName(S.user.clinicianName) : 'your physio');
};
const activeEnrollments = () => (S.today?.enrollments ?? []).filter((e) => e.status === 'active');

function sortLele() { S.lele.sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt)); }

function mergeLele(messages) {
  for (const m of messages ?? []) {
    const i = S.lele.findIndex((x) => x.id === m.id);
    if (i >= 0) S.lele[i] = m; else S.lele.push(m);
  }
  sortLele();
}

/// Lele's question still waiting for an answer, if it's the latest thing in the conversation.
function openQuestion() {
  const last = [...S.lele].reverse().find((m) => m.author !== 'person');
  if (!last || last.answeredAt || !last.actions.some((a) => a.kind === 'reply')) return null;
  const answeredLater = S.lele.some((m) => m.author === 'person' && new Date(m.createdAt) > new Date(last.createdAt));
  return answeredLater ? null : last;
}

async function refreshAll() {
  const [user, today, rewards, lele] = await Promise.all([
    api('GET', 'v1/me'),
    api('GET', 'v1/today'),
    api('GET', 'v1/rewards/summary').catch(() => null),
    api('GET', 'v1/lele/messages').catch(() => []),
  ]);
  Object.assign(S, { user, today, rewards });
  S.lele = lele;
  sortLele();
}

async function refreshToday() {
  try { S.today = await api('GET', 'v1/today'); } catch { /* keep what we have */ }
}

function signOut() {
  setToken(null);
  Object.assign(S, { user: null, today: null, rewards: null, progress: null, lele: [], flash: null });
  if (location.hash !== '#/welcome') location.hash = '#/welcome'; else render();
}

// MARK: Icons

const icon = {
  today: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
  programs: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="4" y="3" width="16" height="18" rx="3"/><path d="M8 8h8M8 12h8M8 16h5"/></svg>',
  lele: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M4 5h16v11H9l-5 4z"/></svg>',
  progress: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 17l6-6 4 4 8-8"/><path d="M15 7h6v6"/></svg>',
  me: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6" stroke-linecap="round"/></svg>',
  play: '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M7 4l13 8-13 8z"/></svg>',
  spark: '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 2l2.2 6.6L21 11l-6.8 2.4L12 20l-2.2-6.6L3 11l6.8-2.4z"/></svg>',
};

const avatar = (big = false) => `<span class="avatar${big ? ' big' : ''}"><img src="/app/mark.png" alt=""></span>`;

// MARK: Routing

const tabs = [
  ['today', 'Today'],
  ['programs', 'Programs'],
  ['lele', 'Lele'],
  ['progress', 'Progress'],
  ['me', 'Me'],
];

function route() {
  const name = (location.hash.replace(/^#\/?/, '') || 'today').split('?')[0];
  return tabs.some(([id]) => id === name) || name === 'welcome' ? name : 'today';
}

window.addEventListener('hashchange', () => { render(); window.scrollTo(0, 0); });

async function render() {
  if (!getToken()) {
    $app.innerHTML = viewWelcome();
    return;
  }
  if (!S.user) {
    $app.innerHTML = '<p class="boot">Loading your day…</p>';
    try { await refreshAll(); } catch (e) {
      if (!getToken()) return;
      $app.innerHTML = `<div class="main"><div class="card alert"><h3>Couldn't reach Laile</h3><p>${esc(e.message)}</p><button class="btn" data-act="retry">Try again</button></div></div>`;
      return;
    }
  }
  let current = route();
  if (current === 'welcome') { current = 'today'; history.replaceState(null, '', '#/today'); }
  const nav = `<nav class="nav" aria-label="Laile">
    <div class="brand-row"><img src="/app/mark.png" alt="" width="30" height="30"> Laile</div>
    ${tabs.map(([id, label]) => `<a href="#/${id}" class="${id === current ? 'on' : ''}" ${id === current ? 'aria-current="page"' : ''}><span class="ico">${icon[id]}</span>${label}</a>`).join('')}
  </nav>`;
  const views = { today: viewToday, programs: viewPrograms, lele: viewLele, progress: viewProgress, me: viewMe };
  let body;
  try { body = await views[current](); } catch (e) { body = `<div class="card alert">${esc(e.message)}</div>`; }
  const flash = S.flash ? `<div class="card ${S.flash.kind === 'error' ? 'alert' : 'soft'}" role="status">${esc(S.flash.text)}</div>` : '';
  $app.innerHTML = `<div class="frame">${nav}<main class="main">${flash}${body}</main></div>`;
  S.flash = null;
  if (current === 'lele') {
    requestAnimationFrame(() => window.scrollTo(0, document.body.scrollHeight));
  }
}

function flash(text, kind = 'info') { S.flash = { text, kind }; }

// MARK: Welcome

function viewWelcome() {
  const register = S.authMode === 'register';
  return `<div class="welcome">
    <div class="welcome-hero">
      <img src="/app/mark.png" alt="" width="72" height="72">
      <p class="eyebrow">Laile · 莱乐</p>
      <h1>Home physio that counts every rep and checks in.</h1>
      <p class="muted">Your physio's program, your camera counting every rep and measuring how far your knee bends, and Lele, a coach who remembers how you're doing and keeps your physio in the loop.</p>
    </div>
    <div class="card">
      <h3>Try it now</h3>
      <p class="muted small">A demo account with two weeks of history. Nothing to sign up for.</p>
      <div class="stack">
        <button class="btn block" data-act="demo" data-persona="patient">Physio patient: knee replacement, day 16</button>
        <button class="btn secondary block" data-act="demo" data-persona="mover">Calisthenics: get stronger at home</button>
      </div>
    </div>
    <form class="card" data-form="${register ? 'register' : 'signin'}">
      <h3>${register ? 'Create your account' : 'Sign in'}</h3>
      ${register ? '<label class="lbl" for="f-name">Your name</label><input class="field" id="f-name" name="name" autocomplete="name" required>' : ''}
      <label class="lbl" for="f-email">Email</label>
      <input class="field" id="f-email" name="email" type="email" autocomplete="email" required>
      <label class="lbl" for="f-password">Password</label>
      <input class="field" id="f-password" name="password" type="password" autocomplete="${register ? 'new-password' : 'current-password'}" minlength="${register ? 8 : 1}" required>
      <p class="error" data-slot="auth-error"></p>
      <button class="btn block" type="submit">${register ? 'Create account' : 'Sign in'}</button>
      <button class="btn ghost block" type="button" data-act="auth-mode">${register ? 'I already have an account' : 'New here? Create an account'}</button>
    </form>
    <p class="muted small center">Physio? <a href="/portal">Open the clinician portal</a> · On iPhone? <a href="https://testflight.apple.com/join/WuymKzUH">Get the app on TestFlight</a> · <a href="/privacy.html">Privacy</a></p>
  </div>`;
}

// MARK: Today

function leleQuestionCard() {
  const q = openQuestion();
  if (!q) return '';
  return `<div class="card soft">
    <div class="row top">${avatar()}<div class="grow"><p class="who small muted">Lele</p><div>${esc(q.text)}</div>
    <div class="chips">${q.actions.map((a) => actionButton(q, a)).join('')}</div></div></div>
  </div>`;
}

const sameText = (a, b) => String(a || '').replace(/[.\s]+$/, '') === String(b || '').replace(/[.\s]+$/, '');
const showSummary = (e) => e.program?.summary && e.kind !== 'catalog' && !sameText(e.program.summary, e.subtitle);

function enrollmentCard(e) {
  const checkIn = !e.calibration;
  const items = e.program?.items?.length ?? 0;
  const tags = [
    e.kind === 'clinical' ? `<span class="pill accent">With ${esc(plainName(e.supervisorName) || 'your physio')}</span>` : '',
    e.kind === 'personal' ? '<span class="pill warm">Built by Lele</span>' : '',
    e.kind === 'catalog' ? '<span class="pill">Laile program</span>' : '',
    checkIn ? '<span class="pill warm">Check-in first</span>' : '',
  ].join(' ');
  return `<div class="card">
    <div class="row spread top"><div class="grow"><h3>${esc(e.title)}</h3><p class="muted small">${esc(e.subtitle)}${items ? ` · ${items} exercises` : ''}</p></div></div>
    <div class="chips">${tags}</div>
    ${showSummary(e) ? `<p class="small muted">${esc(e.program.summary)}</p>` : ''}
    <div class="row" style="margin-top:12px"><button class="btn" data-act="start" data-enrollment="${esc(e.id)}">${icon.play} ${checkIn ? 'Start check-in' : 'Start session'}</button></div>
  </div>`;
}

function planCard() {
  const sup = isSupervised();
  return `<div class="card soft">
    <div class="row top">${avatar()}<div class="grow">
      <h3>Plan something new with Lele</h3>
      <p class="small">Tell Lele your goals, how much time you have and anything that hurts. Lele drafts a program${sup ? ` and sends it to ${esc(physioName())} to approve` : ' and swaps it in for you'}.</p>
      <button class="btn small" data-act="plan">${icon.spark} Plan with Lele</button>
    </div></div>
  </div>`;
}

async function viewToday() {
  const t = S.today;
  const hour = new Date().getHours();
  const greeting = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const streak = S.rewards?.moveStreak?.current ?? 0;
  const level = S.rewards?.level?.level;
  const programs = activeEnrollments();
  const doses = t.medicationDoses ?? [];
  const snacks = (t.templates ?? []).filter((x) => x.isSnack);

  return `
    <p class="eyebrow">${esc(new Date().toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' }))}</p>
    <h1>${greeting}, ${esc(firstName(S.user.displayName))}</h1>
    <div class="chips" style="margin-top:0">
      ${streak ? `<span class="pill warm">${streak}-day move streak</span>` : ''}
      ${level ? `<span class="pill accent">Level ${level}</span>` : ''}
      ${S.rewards?.movedToday ? '<span class="pill accent">Moved today</span>' : ''}
    </div>
    <div style="margin-top:16px">${leleQuestionCard()}</div>
    <h2>Your programs</h2>
    ${programs.length ? programs.map(enrollmentCard).join('') : `<div class="card"><h3>No program yet</h3><p class="muted small">Ask Lele to plan one, or pick one in Programs.</p></div>`}
    ${planCard()}
    ${doses.length ? `<h2>Medicines today</h2><div class="card"><ul class="list">${doses.map((d) => `
      <li><div><strong>${esc(d.medication.name)}</strong> <span class="muted small">${esc(d.medication.doseText)} · ${timeLabel(d.scheduled)}</span><div class="muted small">${esc(d.medication.purpose)}</div></div>
      ${d.taken ? '<span class="pill accent">Taken</span>' : `<button class="btn small secondary" data-act="taken" data-med="${esc(d.medication.id)}" data-hour="${d.scheduled.hour}" data-minute="${d.scheduled.minute}">Taken</button>`}</li>`).join('')}</ul>
      <p class="muted small">Timing and doses come from your prescriber. Lele explains what each one is for.</p></div>` : ''}
    ${snacks.length ? `<h2>Quick sessions</h2><div class="grid2">${snacks.map((s) => `
      <div class="card"><h3>${esc(s.title)}</h3><p class="muted small">${esc(s.subtitle)} · ${s.minutes} min</p>
      <button class="btn small secondary" data-act="start" data-template="${esc(s.id)}">${icon.play} Start</button></div>`).join('')}</div>` : ''}
  `;
}

function timeLabel({ hour, minute }) {
  const d = new Date(); d.setHours(hour, minute, 0, 0);
  return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

// MARK: Programs

async function viewPrograms() {
  if (!S.catalog) S.catalog = await api('GET', 'v1/catalog');
  const sup = isSupervised();
  const active = activeEnrollments();
  const done = (S.today?.enrollments ?? []).filter((e) => e.status !== 'active');
  const joined = new Set(active.map((e) => e.catalogId).filter(Boolean));
  const requests = S.today?.requests ?? [];
  const latestRequest = (id) => requests.filter((r) => r.catalogId === id).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  const categories = [['calisthenics', 'Calisthenics'], ['mobility', 'Mobility'], ['recovery', 'After physio'], ['desk', 'Desk breaks']];

  const catalogCard = (p) => {
    const req = latestRequest(p.id);
    let button;
    if (joined.has(p.id)) button = '<span class="pill accent">Joined</span>';
    else if (sup && req?.status === 'pending') button = '<span class="pill warm">Asked</span>';
    else if (sup) button = `<button class="btn small secondary" data-act="ask" data-id="${esc(p.id)}">Ask ${esc(physioName())}</button>`;
    else button = `<button class="btn small" data-act="join" data-id="${esc(p.id)}">Join</button>`;
    return `<div class="card"><div class="row spread top"><div class="grow"><h3>${esc(p.title)}</h3>
      <p class="muted small">${esc(p.subtitle)} · ${p.minutes} min · level ${p.level}</p></div></div>
      <p class="small">${esc(p.about)}</p>
      ${req && req.status !== 'pending' ? `<p class="small muted">${esc(physioName())} ${req.status === 'approved' ? 'approved' : 'said not yet to'} this${req.note ? `: “${esc(req.note)}”` : '.'}</p>` : ''}
      <div class="row">${button}</div></div>`;
  };

  return `
    <h1>Programs</h1>
    ${sup ? `<div class="card soft"><p class="small">${esc(physioName())} supervises your programs. To add one, tap Ask and Lele sends them the request, then tells you the answer.</p></div>` : ''}
    <h2>Yours</h2>
    ${active.length ? active.map((e) => `${enrollmentCard(e)}${e.kind !== 'clinical' ? `<div class="row" style="margin:-4px 0 12px 4px"><button class="btn ghost small" data-act="leave" data-id="${esc(e.id)}">Finish ${esc(e.title)}</button></div>` : ''}`).join('') : '<div class="card"><p class="muted">Nothing yet.</p></div>'}
    ${requests.filter((r) => r.status === 'pending').map((r) => `<div class="card warm"><h3>${esc(r.title)}</h3><p class="small">Waiting for ${esc(physioName())} to approve.</p></div>`).join('')}
    ${planCard()}
    ${categories.map(([id, label]) => {
      const list = S.catalog.filter((p) => p.category === id);
      return list.length ? `<h2>${label}</h2><div class="grid2">${list.map(catalogCard).join('')}</div>` : '';
    }).join('')}
    ${done.length ? `<h2>Finished</h2><div class="card"><ul class="list">${done.map((e) => `<li><span>${esc(e.title)}</span><span class="muted small">${e.completedAt ? when(e.completedAt) : ''}</span></li>`).join('')}</ul></div>` : ''}
    ${S.user.clinicianName ? '' : `<h2>Have a code from your physio?</h2>
    <form class="card" data-form="link"><label class="lbl" for="f-code">Invite code</label>
      <div class="row"><input class="field" id="f-code" name="code" placeholder="e.g. LAI-7K2Q" autocomplete="off" required><button class="btn" type="submit">Link</button></div>
      <p class="error" data-slot="link-error"></p></form>`}
  `;
}

// MARK: Lele

/// Answer buttons stay on a question until it's answered or the conversation has moved on
/// (medicine reminders keep theirs, since a dose can be ticked off later).
function isAnswerable(message) {
  if (message.answeredAt) return false;
  if (message.kind === 'reminder') return true;
  return !S.lele.some((m) => m.author === 'person' && new Date(m.createdAt) > new Date(message.createdAt));
}

function actionButton(message, action) {
  if (action.kind === 'call') return '';
  if (action.kind === 'reply' && !isAnswerable(message)) return '';
  const cls = action.kind === 'reply' ? 'chip' : 'btn small';
  const lead = action.kind === 'startSession' ? icon.play + ' ' : '';
  return `<button class="${cls}" data-act="lele-action" data-msg="${esc(message.id)}" data-aid="${esc(action.id)}">${lead}${esc(action.label)}</button>`;
}

function bubble(m) {
  const who = m.author === 'clinician' ? esc(physioName()) : m.author === 'person' ? '' : 'Lele';
  const actions = m.author === 'person' ? '' : m.actions.map((a) => actionButton(m, a)).join('');
  return `<div class="msg ${m.author}">
    ${m.author === 'person' ? '' : avatar()}
    <div>${who ? `<p class="who">${who} · ${esc(when(m.createdAt))}</p>` : ''}<div class="bubble">${esc(m.text)}</div>
    ${actions ? `<div class="actions">${actions}</div>` : ''}</div>
  </div>`;
}

const suggestions = () => {
  const list = ['How am I doing?', 'Why am I doing this exercise?', "I've been sore after sessions"];
  if ((S.today?.medicationDoses ?? []).length) list.push('What are my medicines for?');
  return list;
};

async function viewLele() {
  const q = openQuestion();
  const typed = S.lele.filter((m) => m.author === 'person').length;
  return `
    <div class="row" style="margin-bottom:14px">${avatar(true)}<div><h1 style="margin:0">Lele</h1>
      <p class="muted small" style="margin:0">Checks in on you, remembers what felt sore, explains your exercises and medicines, and keeps ${isSupervised() ? esc(physioName()) : 'your physio'} in the loop.</p></div></div>
    <div class="thread">${S.lele.map(bubble).join('')}${S.sending ? '<p class="typing">Lele is writing…</p>' : ''}</div>
    <div class="composer-wrap">
      <div class="suggest">
        <button class="chip" data-act="plan">${icon.spark} Plan a new program</button>
        ${typed < 4 ? suggestions().map((s) => `<button class="chip" data-act="say" data-text="${esc(s)}">${esc(s)}</button>`).join('') : ''}
      </div>
      <form class="composer" data-form="chat">
        <textarea class="field" name="text" rows="1" placeholder="${q ? 'Reply to Lele, or tap an answer' : 'Message Lele'}" aria-label="Message Lele" ${S.sending ? 'disabled' : ''}></textarea>
        <button class="btn" type="submit" ${S.sending ? 'disabled' : ''}>Send</button>
      </form>
    </div>
  `;
}

async function sendToLele(raw) {
  const text = String(raw || '').trim();
  if (!text || S.sending) return;
  const question = openQuestion();
  const pendingId = `pending-${Date.now()}`;
  S.lele.push({ id: pendingId, createdAt: isoDate(), kind: 'chat', author: 'person', text, actions: [] });
  S.sending = true;
  if (route() !== 'lele') location.hash = '#/lele'; else render();
  try {
    const turn = question
      ? await api('POST', `v1/lele/messages/${question.id}/reply`, { text })
      : await api('POST', 'v1/lele/chat', { text });
    S.lele = S.lele.filter((m) => m.id !== pendingId);
    mergeLele(turn.messages);
  } catch (e) {
    S.lele = S.lele.filter((m) => m.id !== pendingId);
    S.lele.push({ id: `local-${Date.now()}`, createdAt: isoDate(), kind: 'chat', author: 'lele', text: "I couldn't reply just now. Check your connection and try again in a moment.", actions: [] });
  }
  S.sending = false;
  // A finished plan changes the person's programs, so Today and Programs need the new list.
  await refreshToday();
  render();
}

async function performLeleAction(messageId, actionId) {
  const message = S.lele.find((m) => m.id === messageId);
  const action = message?.actions.find((a) => a.id === actionId);
  if (!message || !action) return;
  switch (action.kind) {
    case 'reply': {
      if (S.sending) return;
      // Show their answer straight away; the server's copy replaces it.
      const pendingId = `pending-${Date.now()}`;
      S.lele.push({ id: pendingId, createdAt: isoDate(), kind: 'chat', author: 'person', text: action.label, actions: [] });
      S.sending = true;
      render();
      try {
        const turn = await api('POST', `v1/lele/messages/${message.id}/reply`, { actionId: action.id });
        S.lele = S.lele.filter((m) => m.id !== pendingId);
        mergeLele(turn.messages);
      } catch (e) {
        S.lele = S.lele.filter((m) => m.id !== pendingId);
        flash(e.message, 'error');
      }
      S.sending = false;
      await refreshToday();
      render();
      break;
    }
    case 'startSession': {
      const value = action.value || '';
      if (value.startsWith('snack:')) startSession({ template: value.slice(6) });
      else startSession({ enrollment: value });
      break;
    }
    case 'joinProgram': {
      try {
        const enrollment = await api('POST', 'v1/enrollments', { catalogId: action.value });
        mergeLele([{ id: `local-${Date.now()}`, createdAt: isoDate(), kind: 'chat', author: 'lele',
          text: `You're in! Your first ${enrollment.title} session is a quick check-in to set your targets.`,
          actions: [{ id: 'start', label: 'Start check-in', kind: 'startSession', value: enrollment.id }] }]);
        await refreshToday();
      } catch (e) { flash(e.message, 'error'); }
      render();
      break;
    }
    case 'openChat': {
      location.hash = '#/lele';
      await render();
      const box = document.querySelector('[data-form="chat"] textarea');
      if (box) { box.value = action.value || ''; box.focus(); }
      break;
    }
    default: break;
  }
}

// MARK: Progress

function sparkline(samples) {
  const values = samples.map((s) => s.value);
  if (values.length < 2) return '';
  const w = 300, h = 56, pad = 4;
  const min = Math.min(...values), max = Math.max(...values);
  const span = max - min || 1;
  const pts = values.map((v, i) => {
    const x = pad + (i / (values.length - 1)) * (w - pad * 2);
    const y = h - pad - ((v - min) / span) * (h - pad * 2);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const [lx, ly] = pts[pts.length - 1].split(',');
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">
    <polyline points="${pts.join(' ')}" fill="none" stroke="var(--accent)" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>
    <circle cx="${lx}" cy="${ly}" r="4" fill="var(--accent)"/></svg>`;
}

const metrics = {
  kneeFlexion: ['Knee bend', '°', true], kneeExtensionDeficit: ['Knee straightening gap', '°', false],
  straightLegRaiseReps: ['Straight-leg raises', ' reps', true], sitToStandReps: ['Sit-to-stands', ' reps', true],
  squatReps: ['Squats', ' reps', true], pushUpReps: ['Push-ups', ' reps', true], gluteBridgeReps: ['Glute bridges', ' reps', true],
  jumpingJackReps: ['Jumping jacks', ' reps', true], plankHoldSeconds: ['Plank hold', 's', true], wallSitSeconds: ['Wall sit', 's', true],
  shoulderElevation: ['Arm lift', '°', true], painAtRest: ['Pain at rest', '/10', false],
};

async function viewProgress() {
  S.progress = await api('GET', 'v1/progress');
  const r = S.rewards;
  const trends = S.progress.trends.filter((t) => t.samples.length);
  const fmt = (v, unit) => `${Math.round(v * 10) / 10}${unit}`;
  return `
    <h1>Progress</h1>
    <p class="muted">Every number here was measured by the camera during your sessions.</p>
    ${r ? `<div class="grid2">
      <div class="card stat"><p class="muted small">Move streak</p><p class="big-num">${r.moveStreak.current} days</p><p class="muted small">Best ${r.moveStreak.best}</p></div>
      <div class="card stat"><p class="muted small">Level</p><p class="big-num">${r.level.level}</p><p class="muted small">${r.level.xpIntoLevel} of ${r.level.xpForNextLevel} XP to the next</p></div>
    </div>` : ''}
    ${trends.map((t) => {
      const [name, unit, higher] = metrics[t.kind] ?? [capital(words(t.kind)), '', true];
      const latest = t.latest?.value, base = t.baseline?.value;
      const change = latest != null && base != null ? latest - base : null;
      const better = change == null ? null : (higher ? change > 0 : change < 0);
      const plateau = t.flags.find((f) => f.plateau);
      return `<div class="card">
        <div class="row spread"><h3>${esc(name)}</h3>${latest != null ? `<span class="big-num" style="font-size:24px">${fmt(latest, unit)}</span>` : ''}</div>
        ${change != null && Math.abs(change) > 0 ? `<p class="small ${better ? 'good' : 'muted'}">${change > 0 ? 'Up' : 'Down'} ${fmt(Math.abs(change), unit)} since your first session${better ? ', better' : ''}</p>` : ''}
        ${sparkline(t.samples)}
        ${t.nextMilestone ? `<p class="small muted">Next: ${esc(t.nextMilestone.title)}</p>` : ''}
        ${plateau ? `<p class="small muted">About the same for ${plateau.plateau.sessions} sessions. Lele and your physio can see this too.</p>` : ''}
      </div>`;
    }).join('') || '<div class="card"><p class="muted">Finish a session and your measurements show up here.</p></div>'}
    <h2>Recent sessions</h2>
    <div class="card"><ul class="list">${S.progress.recentSessions.map((s) => {
      const reps = s.exercises.reduce((n, x) => n + x.repsPerSet.reduce((a, b) => a + b, 0), 0);
      const holds = s.exercises.reduce((n, x) => n + x.holdSecondsPerSet.reduce((a, b) => a + b, 0), 0);
      return `<li><div><strong>${esc(s.title)}</strong><div class="muted small">${esc(when(s.startedAt))}${s.symptoms.length ? ` · ${s.symptoms.length} thing${s.symptoms.length > 1 ? 's' : ''} you reported` : ''}</div></div>
        <span class="muted small">${reps ? `${reps} reps` : ''}${reps && holds ? ' · ' : ''}${holds ? `${holds}s held` : ''}</span></li>`;
    }).join('') || '<li class="muted">No sessions yet.</li>'}</ul></div>
  `;
}

// MARK: Me

async function viewMe() {
  const u = S.user;
  const h = S.today?.health;
  const notes = (S.today?.careNotes ?? []).filter((n) => n.status === 'active');
  const goals = { getStronger: 'Get stronger', easeAches: 'Ease aches and stiffness', moveMore: 'Move more on busy days', flexibility: 'Loosen up', recoverInjury: 'Recover from an injury or surgery' };
  const experience = { new: 'New to exercise', some: 'Moves now and then', regular: 'Trains regularly' };
  const eased = (a) => [a?.rangeEase ? `${a.rangeEase}° less range` : '', a?.holdScale && a.holdScale < 1 ? `holds ${Math.round((1 - a.holdScale) * 100)}% shorter` : '', a?.skip ? 'left out for now' : ''].filter(Boolean).join(', ');
  return `
    <div class="row" style="margin-bottom:8px"><div class="grow"><h1 style="margin:0">${esc(plainName(u.displayName))}</h1>
      <p class="muted small" style="margin:0">${esc(u.email)}${u.isDemo ? ' · demo account' : ''}</p></div></div>
    <div class="chips" style="margin-top:4px">
      <span class="pill accent">${u.mode === 'rehab' ? 'Physio rehab' : 'Calisthenics and mobility'}</span>
      ${u.clinicianName ? `<span class="pill">Physio: ${esc(plainName(u.clinicianName))}</span>` : ''}
    </div>

    <h2>What Lele knows about you</h2>
    <div class="card">
      ${h ? `<ul class="list">
        <li><span class="muted">Goals</span><span>${esc((h.goals ?? []).map((g) => goals[g] ?? capital(words(g))).join(', ') || 'Not set')}</span></li>
        <li><span class="muted">Time per day</span><span>${h.minutesPerDay ? `${h.minutesPerDay} minutes` : 'Not set'}</span></li>
        <li><span class="muted">Experience</span><span>${esc(experience[h.experience] ?? capital(words(h.experience)))}</span></li>
        <li><span class="muted">Go easy on</span><span>${esc((h.sensitiveAreas ?? []).map(words).join(', ') || 'Nothing')}</span></li>
        ${h.notes ? `<li><span class="muted">Notes</span><span>${esc(h.notes)}</span></li>` : ''}
      </ul>` : '<p class="muted">Lele hasn\'t asked about your goals yet.</p>'}
      <button class="btn small secondary" style="margin-top:10px" data-act="plan">${icon.spark} Change my goals with Lele</button>
    </div>

    <h2>What Lele remembers</h2>
    <p class="muted small">From your sessions and chats. Lele eases the exercise next time${u.clinicianName ? `, and ${esc(plainName(u.clinicianName))} sees these in the portal` : ''}.</p>
    ${notes.length ? notes.map((n) => `<div class="card">
      <div class="row spread"><span class="pill ${n.kind === 'clinicianNote' ? 'accent' : 'warm'}">${esc({ soreSpot: 'Sore spot', feelsWrong: 'Felt wrong', clinicianNote: 'From your physio', flare: 'Flare-up', barrier: 'What gets in the way' }[n.kind] ?? capital(words(n.kind)))}</span>
        <span class="muted small">${esc(when(n.updatedAt))}</span></div>
      <p style="margin:8px 0 4px">${esc(n.text)}</p>
      ${n.quote ? `<p class="muted small">You said: “${esc(n.quote)}”</p>` : ''}
      ${eased(n.adjustment) ? `<p class="small">Next time: ${esc(eased(n.adjustment))}.</p>` : ''}
      ${['soreSpot', 'feelsWrong', 'flare'].includes(n.kind) ? `<button class="btn ghost small" data-act="better" data-id="${esc(n.id)}">It feels better now</button>` : ''}
    </div>`).join('') : '<div class="card"><p class="muted">Nothing yet. Tell Lele during a session if something feels sore.</p></div>'}

    <h2>Account</h2>
    <div class="card stack">
      ${u.isDemo ? '<button class="btn secondary block" data-act="restart">Restart the demo with fresh data</button>' : ''}
      <button class="btn ghost block" data-act="signout">Sign out</button>
    </div>
    <p class="muted small">Laile is a coach, not a diagnosis. In an emergency in Singapore, call 995. <a href="/privacy.html">Privacy</a> · <a href="/portal">Clinician portal</a> · <a href="https://testflight.apple.com/join/WuymKzUH">iPhone app</a></p>
  `;
}

// MARK: Sessions

/// Lele's ElevenLabs voice, rendered and cached by the server.
async function speechAudio(text) {
  const res = await fetch('/v1/voice/speak', {
    method: 'POST',
    headers: { authorization: `Bearer ${getToken()}`, 'content-type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) throw new Error(`No voice (${res.status})`);
  return res.arrayBuffer();
}

async function startSession(query) {
  try {
    const { runSession } = await import('/app/session.js');
    await runSession({
      api,
      speech: speechAudio,
      query,
      onFinished: async (result) => {
        await refreshAll().catch(() => {});
        if (result?.movement) flash(`Session saved. +${result.movement.xpAwarded} XP.`);
        render();
      },
    });
  } catch (e) {
    flash(e.message, 'error');
    render();
  }
}

// MARK: Events

async function signInWith(promise, form) {
  const slot = form?.querySelector('[data-slot="auth-error"]');
  try {
    S.busy = true;
    const auth = await promise;
    setToken(auth.token);
    S.user = null;
    location.hash = '#/today';
    await render();
  } catch (e) {
    if (slot) slot.textContent = e.message; else alert(e.message);
  } finally {
    S.busy = false;
  }
}

const timeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Singapore';

const handlers = {
  retry: () => { S.user = null; render(); },
  'auth-mode': () => { S.authMode = S.authMode === 'register' ? 'signin' : 'register'; render(); },
  demo: (el) => {
    el.disabled = true;
    el.textContent = 'Setting up your demo…';
    return signInWith(api('POST', 'v1/demo/sessions', { persona: el.dataset.persona, timeZone: timeZone() }));
  },
  start: (el) => startSession(el.dataset.enrollment ? { enrollment: el.dataset.enrollment } : { template: el.dataset.template }),
  plan: () => sendToLele("I'd like a new program with new goals."),
  say: (el) => sendToLele(el.dataset.text),
  'lele-action': (el) => performLeleAction(el.dataset.msg, el.dataset.aid),
  taken: async (el) => {
    el.disabled = true;
    try {
      await api('POST', 'v1/medications/taken', { medicationId: el.dataset.med, scheduled: { hour: Number(el.dataset.hour), minute: Number(el.dataset.minute) } });
      await refreshToday();
    } catch (e) { flash(e.message, 'error'); }
    render();
  },
  join: async (el) => {
    el.disabled = true;
    try {
      const enrollment = await api('POST', 'v1/enrollments', { catalogId: el.dataset.id });
      await refreshToday();
      flash(`You're in ${enrollment.title}. Your first session is a quick check-in to set your targets.`);
    } catch (e) { flash(e.message, 'error'); }
    render();
  },
  ask: async (el) => {
    el.disabled = true;
    try {
      const turn = await api('POST', 'v1/requests', { catalogId: el.dataset.id });
      mergeLele(turn.messages);
      await refreshToday();
      flash(`Sent to ${physioName()}. Lele will tell you the answer.`);
    } catch (e) { flash(e.message, 'error'); }
    render();
  },
  leave: async (el) => {
    if (!confirm('Finish this program? Your history stays in Progress.')) return;
    try { await api('POST', `v1/enrollments/${el.dataset.id}/leave`); await refreshToday(); } catch (e) { flash(e.message, 'error'); }
    render();
  },
  better: async (el) => {
    el.disabled = true;
    try { await api('POST', `v1/care-notes/${el.dataset.id}/better`); await refreshToday(); flash('Noted. Lele will build that exercise back up.'); } catch (e) { flash(e.message, 'error'); }
    render();
  },
  restart: async (el) => {
    el.disabled = true;
    const persona = S.user?.mode === 'rehab' ? 'patient' : 'mover';
    await signInWith(api('POST', 'v1/demo/sessions', { persona, timeZone: timeZone() }));
  },
  signout: () => signOut(),
};

$app.addEventListener('click', (event) => {
  const el = event.target.closest('[data-act]');
  if (!el || el.disabled) return;
  const handler = handlers[el.dataset.act];
  if (handler) { event.preventDefault(); handler(el); }
});

$app.addEventListener('submit', async (event) => {
  const form = event.target.closest('form[data-form]');
  if (!form) return;
  event.preventDefault();
  const data = Object.fromEntries(new FormData(form));
  switch (form.dataset.form) {
    case 'chat':
      await sendToLele(data.text);
      break;
    case 'signin':
      await signInWith(api('POST', 'v1/auth/login', { email: data.email.trim(), password: data.password }), form);
      break;
    case 'register':
      await signInWith(api('POST', 'v1/auth/register', { email: data.email.trim(), password: data.password, displayName: data.name.trim(), timeZone: timeZone() }), form);
      break;
    case 'link': {
      const slot = form.querySelector('[data-slot="link-error"]');
      try {
        S.user = await api('POST', 'v1/patients/link', { inviteCode: data.code });
        await refreshAll();
        flash(`Linked to ${plainName(S.user.clinicianName) || 'your physio'}.`);
        render();
      } catch (e) { slot.textContent = e.message; }
      break;
    }
    default: break;
  }
});

// Enter sends; Shift+Enter adds a line.
$app.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && event.target.matches('[data-form="chat"] textarea')) {
    event.preventDefault();
    event.target.form.requestSubmit();
  }
});

render();
