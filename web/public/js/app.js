// SK Note Taker — web review client.
// Hash routing, fetch from /api, and a fully rendered dark UI. No framework, no build step.

import { renderMarkdown } from './markdown.js';

// ---------- Small helpers ----------
const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, attrs = {}, children = []) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (v != null) node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c == null) continue;
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
};
const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

async function api(path, opts) {
  const res = await fetch(`/api${path}`, opts);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

function toast(msg) {
  let t = $('#toast');
  if (!t) {
    t = el('div', { id: 'toast', class: 'toast' });
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('show'), 2200);
}

// ---------- Formatting ----------
function relativeDate(iso) {
  if (!iso) return 'Unknown date';
  const then = new Date(iso);
  if (isNaN(then)) return 'Unknown date';
  const diff = Date.now() - then.getTime();
  const day = 86400000;
  const abs = Math.abs(diff);
  if (abs < 60000) return 'Just now';
  if (abs < 3600000) return `${Math.round(diff / 60000)}m ago`;
  if (abs < day) return `${Math.round(diff / 3600000)}h ago`;
  if (abs < day * 7) return `${Math.round(diff / day)}d ago`;
  return then.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatDuration(sec) {
  if (typeof sec !== 'number' || sec <= 0) return null;
  const m = Math.round(sec / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  const rem = m % 60;
  return rem ? `${h}h ${rem}m` : `${h}h`;
}

function formatTime(sec) {
  if (typeof sec !== 'number') return '';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

// Stable, distinct hue per speaker key.
const SPEAKER_HUES = [255, 172, 330, 42, 200, 96, 288, 14];
function speakerColor(key) {
  let hash = 0;
  const str = String(key || '');
  for (let i = 0; i < str.length; i++) hash = (hash * 31 + str.charCodeAt(i)) >>> 0;
  const hue = SPEAKER_HUES[hash % SPEAKER_HUES.length];
  return `hsl(${hue}, 68%, 60%)`;
}

// ---------- Brand mark ----------
function brandLogoSvg(size = 38) {
  return `
  <svg class="brand-logo" width="${size}" height="${size}" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="SK Note Taker logo">
    <defs>
      <linearGradient id="skg" x1="0" y1="0" x2="40" y2="40" gradientUnits="userSpaceOnUse">
        <stop stop-color="#4F46E5"/><stop offset="1" stop-color="#14B8A6"/>
      </linearGradient>
    </defs>
    <rect width="40" height="40" rx="11" fill="url(#skg)"/>
    <g fill="#fff">
      <rect x="9"  y="16" width="3" height="8"  rx="1.5"/>
      <rect x="14" y="11" width="3" height="18" rx="1.5"/>
      <rect x="19" y="14" width="3" height="12" rx="1.5"/>
      <rect x="24" y="9"  width="3" height="22" rx="1.5"/>
      <rect x="29" y="15" width="3" height="10" rx="1.5"/>
    </g>
  </svg>`;
}

function mountBrand() {
  const brand = $('#brandLink');
  brand.innerHTML = `${brandLogoSvg(38)}<span><span class="brand-title">SK Note Taker</span><span class="brand-sub">Meeting review</span></span>`;
  $('#topbarBrand').innerHTML = `${brandLogoSvg(30)}<span class="brand-title" style="font-size:15px;margin-left:8px">SK Note Taker</span>`;
}

// ---------- State ----------
const state = {
  folders: { tree: [], totalMeetings: 0, unfiled: 0 },
  flatFolders: [], // {id, name}
  activeFolderId: null, // null = all
  query: '',
};

function flatten(tree, acc = []) {
  for (const f of tree) {
    acc.push({ id: f.id, name: f.name });
    if (f.children && f.children.length) flatten(f.children, acc);
  }
  return acc;
}

// ---------- Sidebar / folders ----------
const folderIcon = `<svg class="folder-icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>`;
const allIcon = `<svg class="folder-icon" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg>`;

function folderNode(f) {
  const item = el('button', {
    class: `folder-item${state.activeFolderId === f.id ? ' active' : ''}`,
    onclick: () => selectFolder(f.id),
  }, [
    el('span', { class: 'folder-icon', html: folderIcon }),
    el('span', { class: 'folder-name' }, f.name),
    el('span', { class: 'count' }, String(f.count)),
  ]);

  const wrap = el('div');
  wrap.appendChild(item);
  if (f.children && f.children.length) {
    const kids = el('div', { class: 'folder-children' });
    for (const c of f.children) kids.appendChild(folderNode(c));
    wrap.appendChild(kids);
  }
  return wrap;
}

function renderSidebar() {
  const nav = $('#folderNav');
  nav.innerHTML = '';

  const all = el('button', {
    class: `folder-item${state.activeFolderId === null ? ' active' : ''}`,
    onclick: () => selectFolder(null),
  }, [
    el('span', { class: 'folder-icon', html: allIcon }),
    el('span', { class: 'folder-name' }, 'All meetings'),
    el('span', { class: 'count' }, String(state.folders.totalMeetings)),
  ]);
  nav.appendChild(all);

  if (state.folders.tree.length) {
    nav.appendChild(el('div', { class: 'folder-section-label' }, 'Folders'));
    for (const f of state.folders.tree) nav.appendChild(folderNode(f));
  }
}

function selectFolder(id) {
  state.activeFolderId = id;
  closeSidebar();
  if (location.hash.startsWith('#/meeting/')) location.hash = '#/';
  else renderRoute();
  renderSidebar();
}

// ---------- Views ----------
function summaryBadge() {
  return `<span class="badge badge-summary"><svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M20 6L9 17l-5-5"/></svg>Summary</span>`;
}

async function renderList() {
  const view = $('#view');
  view.innerHTML = '<div class="spinner"></div>';

  const params = new URLSearchParams();
  if (state.activeFolderId) params.set('folderId', state.activeFolderId);
  if (state.query) params.set('q', state.query);

  let meetings = [];
  try {
    const data = await api(`/meetings?${params.toString()}`);
    meetings = data.meetings || [];
  } catch (err) {
    view.innerHTML = '';
    view.appendChild(errorState('Could not load meetings', String(err.message)));
    return;
  }

  const folderName = state.activeFolderId
    ? state.flatFolders.find((f) => f.id === state.activeFolderId)?.name || 'Folder'
    : 'All meetings';

  view.innerHTML = '';
  const head = el('div', { class: 'page-head' }, [
    el('h1', { class: 'page-title' }, folderName),
    el('div', { class: 'page-sub' },
      state.query
        ? `${meetings.length} result${meetings.length === 1 ? '' : 's'} for “${state.query}”`
        : `${meetings.length} meeting${meetings.length === 1 ? '' : 's'}`),
  ]);
  view.appendChild(head);

  if (!meetings.length) {
    view.appendChild(emptyState(state.query));
    return;
  }

  const list = el('div', { class: 'meeting-list' });
  for (const m of meetings) list.appendChild(meetingCard(m));
  view.appendChild(list);
}

function meetingCard(m) {
  const badges = el('div', { style: 'display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end' });
  if (m.hasSummary) badges.innerHTML += summaryBadge();
  if (m.hasRecording) badges.innerHTML += '<span class="badge badge-rec">Audio</span>';
  if (m.state && m.state !== 'complete') badges.innerHTML += `<span class="badge badge-state">${escapeHtml(m.state)}</span>`;

  const meta = [el('span', {}, relativeDate(m.createdAt))];
  const dur = formatDuration(m.durationSec);
  if (dur) {
    meta.push(el('span', { class: 'sep' }, '·'));
    meta.push(el('span', {}, dur));
  }
  if (m.speakerNames && m.speakerNames.length) {
    meta.push(el('span', { class: 'sep' }, '·'));
    meta.push(el('span', {}, `${m.speakerNames.length} speaker${m.speakerNames.length === 1 ? '' : 's'}`));
  }

  const chips = el('div', { class: 'chips' });
  for (const name of (m.speakerNames || []).slice(0, 5)) {
    chips.appendChild(el('span', { class: 'chip' }, [
      el('span', { class: 'chip-dot', style: `background:${speakerColor(name)}` }),
      name,
    ]));
  }

  return el('div', {
    class: 'meeting-card',
    onclick: () => { location.hash = `#/meeting/${m.id}`; },
  }, [
    el('div', { class: 'mc-top' }, [
      el('div', { class: 'mc-title' }, m.title),
      badges,
    ]),
    el('div', { class: 'mc-meta' }, meta),
    m.speakerNames && m.speakerNames.length ? chips : null,
  ]);
}

function emptyState(query) {
  if (query) {
    return el('div', { class: 'empty' }, [
      el('div', { class: 'empty-glyph', html: brandLogoSvg(40) }),
      el('h3', {}, 'No matches'),
      el('p', {}, `Nothing matched “${query}”. Try a different search or clear the filter.`),
    ]);
  }
  return el('div', { class: 'empty' }, [
    el('div', { class: 'empty-glyph', html: brandLogoSvg(40) }),
    el('h3', {}, 'No meetings yet'),
    el('p', {}, 'Record your first meeting in SK Note Taker and it will appear here for review.'),
  ]);
}

function errorState(title, detail) {
  return el('div', { class: 'empty' }, [
    el('div', { class: 'empty-glyph', html: brandLogoSvg(40) }),
    el('h3', {}, title),
    el('p', {}, detail || ''),
  ]);
}

// ---------- Detail ----------
async function renderDetail(id) {
  const view = $('#view');
  view.innerHTML = '<div class="spinner"></div>';

  let meeting, transcript;
  try {
    [meeting, transcript] = await Promise.all([
      api(`/meetings/${encodeURIComponent(id)}`),
      api(`/meetings/${encodeURIComponent(id)}/transcript`).catch(() => ({ speakers: {}, segments: [] })),
    ]);
  } catch (err) {
    view.innerHTML = '';
    view.appendChild(backLink());
    view.appendChild(errorState('Meeting not found', String(err.message)));
    return;
  }

  const ctx = { id, meeting, transcript, tab: 'summary' };
  view.innerHTML = '';
  view.appendChild(backLink());
  view.appendChild(detailHead(ctx));

  if (meeting.hasRecording) view.appendChild(audioBar(id));

  const tabsAvailable = [];
  if (meeting.summary) tabsAvailable.push(['summary', 'Summary']);
  tabsAvailable.push(['transcript', 'Transcript']);
  tabsAvailable.push(['notes', 'Notes']);
  ctx.tab = tabsAvailable[0][0];

  const tabsBar = el('div', { class: 'tabs' });
  const panel = el('div', { id: 'tab-panel' });

  const setTab = (t) => {
    ctx.tab = t;
    [...tabsBar.children].forEach((b) => b.classList.toggle('active', b.dataset.tab === t));
    panel.innerHTML = '';
    if (t === 'summary') panel.appendChild(summaryTab(ctx));
    else if (t === 'transcript') panel.appendChild(transcriptTab(ctx));
    else panel.appendChild(notesTab(ctx));
  };

  for (const [key, label] of tabsAvailable) {
    tabsBar.appendChild(el('button', {
      class: 'tab', 'data-tab': key, onclick: () => setTab(key),
    }, label));
  }
  view.appendChild(tabsBar);
  view.appendChild(panel);
  setTab(ctx.tab);
}

function backLink() {
  return el('a', {
    class: 'back-link',
    onclick: (e) => { e.preventDefault(); location.hash = '#/'; },
    href: '#/',
  }, [
    el('span', { html: '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>' }),
    'All meetings',
  ]);
}

function detailHead(ctx) {
  const { meeting } = ctx;
  const meta = [el('span', {}, relativeDate(meeting.createdAt))];
  const dur = formatDuration(meeting.durationSec);
  if (dur) { meta.push(el('span', { class: 'sep' }, '·')); meta.push(el('span', {}, dur)); }

  // Folder selector.
  const select = el('select', {
    class: 'folder-select',
    onchange: async (e) => {
      const val = e.target.value || null;
      try {
        await api(`/meetings/${encodeURIComponent(ctx.id)}/folder`, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ folderId: val }),
        });
        toast('Moved to folder');
        await loadFolders();
        renderSidebar();
      } catch (err) {
        toast('Could not move meeting');
      }
    },
  });
  select.appendChild(el('option', { value: '' }, 'No folder'));
  for (const f of state.flatFolders) {
    const opt = el('option', { value: f.id }, f.name);
    if (f.id === meeting.folderId) opt.selected = true;
    select.appendChild(opt);
  }

  meta.push(el('span', { class: 'sep' }, '·'));
  meta.push(select);

  return el('div', { class: 'detail-head' }, [
    el('h1', { class: 'detail-title' }, meeting.title || 'Untitled meeting'),
    el('div', { class: 'detail-meta' }, meta),
  ]);
}

function audioBar(id) {
  return el('div', { class: 'audio-bar' }, [
    el('span', { class: 'audio-label' }, 'Recording'),
    el('audio', { controls: '', preload: 'none', src: `/api/meetings/${encodeURIComponent(id)}/audio` }),
  ]);
}

function summaryTab(ctx) {
  const s = ctx.meeting.summary;
  const wrap = el('div');
  if (!s) {
    wrap.appendChild(el('div', { class: 'notes-empty' }, 'No summary generated yet.'));
    return wrap;
  }

  // Action items checklist.
  if (s.actionItems && s.actionItems.length) {
    const ul = el('ul');
    for (const item of s.actionItems) {
      const owner = item.owner ? `<span class="owner">${escapeHtml(item.owner)}</span> · ` : '';
      const text = item.text || (typeof item === 'string' ? item : '');
      const li = el('li', { class: 'action-item' });
      const check = el('span', {
        class: 'check',
        html: '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>',
        onclick: () => { li.classList.toggle('done'); check.classList.toggle('done'); },
      });
      li.appendChild(check);
      li.appendChild(el('span', { class: 'action-text', html: owner + escapeHtml(text) }));
      ul.appendChild(li);
    }
    wrap.appendChild(el('div', { class: 'callout callout-action' }, [
      el('div', { class: 'callout-head' }, [iconSpan('M9 11l3 3L22 4'), 'Action items']),
      ul,
    ]));
  }

  if (s.decisions && s.decisions.length) {
    const ul = el('ul');
    for (const d of s.decisions) ul.appendChild(el('li', {}, typeof d === 'string' ? d : JSON.stringify(d)));
    wrap.appendChild(el('div', { class: 'callout callout-decision' }, [
      el('div', { class: 'callout-head' }, [iconSpan('M12 2l3 7h7l-5.5 4 2 7L12 16l-6.5 4 2-7L2 9h7z'), 'Decisions']),
      ul,
    ]));
  }

  if (s.remember && s.remember.length) {
    const ul = el('ul');
    for (const r of s.remember) ul.appendChild(el('li', {}, typeof r === 'string' ? r : JSON.stringify(r)));
    wrap.appendChild(el('div', { class: 'callout callout-remember' }, [
      el('div', { class: 'callout-head' }, [iconSpan('M12 2a7 7 0 0 0-4 12.7V17h8v-2.3A7 7 0 0 0 12 2z'), 'Things to remember']),
      ul,
    ]));
  }

  if (s.body) {
    wrap.appendChild(el('div', { class: 'markdown', html: renderMarkdown(s.body) }));
  }
  return wrap;
}

function iconSpan(path) {
  return el('span', { html: `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${path}"/></svg>` });
}

function notesTab(ctx) {
  const notes = ctx.meeting.notes;
  if (!notes || !notes.trim()) {
    return el('div', { class: 'notes-empty' }, 'No notes for this meeting.');
  }
  return el('div', { class: 'markdown', html: renderMarkdown(notes) });
}

function transcriptTab(ctx) {
  const { transcript } = ctx;
  const wrap = el('div');

  const segments = transcript.segments || [];
  const speakers = transcript.speakers || {};

  // Sticky speaker-rename bar.
  const speakerKeys = Object.keys(speakers);
  if (speakerKeys.length) {
    const bar = el('div', { class: 'speaker-bar' });
    bar.appendChild(el('span', { class: 'speaker-bar-label' }, 'Speakers'));
    for (const key of speakerKeys) {
      bar.appendChild(speakerChip(ctx, key, speakers[key]));
    }
    wrap.appendChild(bar);
  }

  if (!segments.length) {
    wrap.appendChild(el('div', { class: 'transcript-empty' }, 'No transcript available for this meeting.'));
    return wrap;
  }

  const list = el('div', { class: 'utterances' });
  for (const seg of segments) {
    const color = speakerColor(seg.speaker);
    const initials = (seg.speakerName || '?').trim().charAt(0).toUpperCase() || '?';
    list.appendChild(el('div', { class: 'utterance', 'data-speaker': seg.speaker }, [
      el('div', { class: 'utt-avatar', style: `background:${color}` }, initials),
      el('div', { class: 'utt-body' }, [
        el('div', { class: 'utt-head' }, [
          el('span', { class: 'utt-speaker', style: `color:${color}` }, seg.speakerName || seg.speaker || 'Unknown'),
          el('span', { class: 'utt-time' }, formatTime(seg.start)),
        ]),
        el('div', { class: 'utt-bubble' }, seg.text || ''),
      ]),
    ]));
  }
  wrap.appendChild(list);
  return wrap;
}

function speakerChip(ctx, key, name) {
  const color = speakerColor(key);
  const chip = el('div', { class: 'speaker-chip' });
  chip.appendChild(el('span', { class: 'sc-dot', style: `background:${color}` }));

  const label = el('span', {}, name || key);
  chip.appendChild(label);

  const startEdit = () => {
    const input = el('input', { type: 'text', value: name || '' });
    chip.replaceChild(input, label);
    input.focus();
    input.select();
    const commit = async () => {
      const newName = input.value.trim();
      if (!newName || newName === name) {
        chip.replaceChild(label, input);
        return;
      }
      try {
        await api(`/meetings/${encodeURIComponent(ctx.id)}/speakers`, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ [key]: newName }),
        });
        toast(`Renamed to ${newName}`);
        // Update local state and re-render transcript so utterances reflect the new name.
        ctx.transcript.speakers[key] = newName;
        for (const seg of ctx.transcript.segments) {
          if (seg.speaker === key) seg.speakerName = newName;
        }
        const panel = $('#tab-panel');
        panel.innerHTML = '';
        panel.appendChild(transcriptTab(ctx));
      } catch (err) {
        toast('Could not rename speaker');
        chip.replaceChild(label, input);
      }
    };
    input.addEventListener('blur', commit);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') input.blur();
      if (e.key === 'Escape') chip.replaceChild(label, input);
    });
  };

  chip.addEventListener('click', startEdit);
  return chip;
}

// ---------- Routing ----------
function renderRoute() {
  const hash = location.hash || '#/';
  const m = hash.match(/^#\/meeting\/(.+)$/);
  if (m) renderDetail(decodeURIComponent(m[1]));
  else renderList();
}

// ---------- Sidebar toggle (mobile) ----------
function openSidebar() { $('#sidebar').classList.add('open'); }
function closeSidebar() { $('#sidebar').classList.remove('open'); }

// ---------- Boot ----------
async function loadFolders() {
  try {
    const data = await api('/folders');
    state.folders = data;
    state.flatFolders = flatten(data.tree || []);
  } catch {
    state.folders = { tree: [], totalMeetings: 0, unfiled: 0 };
    state.flatFolders = [];
  }
}

function initSearch() {
  const input = $('#searchInput');
  let timer;
  input.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      state.query = input.value;
      if (location.hash.startsWith('#/meeting/')) location.hash = '#/';
      else renderList();
    }, 220);
  });
}

async function boot() {
  mountBrand();
  initSearch();
  $('#menuToggle').addEventListener('click', openSidebar);
  $('#scrim').addEventListener('click', closeSidebar);
  $('#brandLink').addEventListener('click', (e) => {
    e.preventDefault();
    location.hash = '#/';
  });

  await loadFolders();
  renderSidebar();
  window.addEventListener('hashchange', renderRoute);
  renderRoute();
}

boot();
