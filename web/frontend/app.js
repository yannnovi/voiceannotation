/* voiceannotate on the web -- the whole of the interface.
 *
 * The desktop application keeps its state in one Tcl array and redraws from
 * it; this does the same with one object. The server is the authority on
 * everything that matters -- the transcript, the queue, who may start a run --
 * and this file only ever renders what the server last said.
 *
 * Two rules are worth pointing at, since they are why the page exists in this
 * shape:
 *
 *   - The backend transcribes four files at once, no more. A fifth waits, and
 *     a waiting job is shown its place in the queue rather than a button that
 *     appears to have done nothing.
 *   - One user transcribes one file at a time. The Transcribe button is
 *     disabled while a run of theirs is going, and says why. The server
 *     refuses anyway -- a browser is not a place to enforce a rule -- but the
 *     button should not invite a refusal.
 */

'use strict';

const SPEAKER_COLOURS = 10;

const state = {
  settings: null,
  models: [],
  queue: { running: 0, capacity: 4, queued: 0, per_user: 1 },
  limits: { formats: ['txt'], allow_model_download: true, max_upload_bytes: 0 },
  job: null,          // the job on screen
  segments: [],
  speakers: [],
  selectedSegment: -1,
  selectedSpeaker: -1,
  file: null,
  stream: null,       // the EventSource for the running job
  catalogue: null,
  downloadPoll: null,
  // The download this page has seen in progress, if any. The server keeps the
  // last one it ran whoever started it, and a model someone else fetched an
  // hour ago must not be announced here -- still less selected -- just
  // because this page opened the dialog.
  watchedDownload: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function timecode(seconds) {
  if (!(seconds > 0)) seconds = 0;
  const millis = Math.round(seconds * 1000);
  const ms = millis % 1000;
  const total = Math.floor(millis / 1000);
  const s = total % 60;
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  const pad = (v, n) => String(v).padStart(n, '0');
  return `${pad(h, 2)}:${pad(m, 2)}:${pad(s, 2)}.${pad(ms, 3)}`;
}

// "3 min 12 s" rather than "192.4", as humanDuration does in the Tk interface.
function humanDuration(seconds) {
  seconds = Math.round(seconds || 0);
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  if (minutes < 60) return `${minutes} min ${rest} s`;
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

function humanBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  let value = bytes / 1024;
  for (const unit of ['KiB', 'MiB', 'GiB']) {
    if (value < 1024 || unit === 'GiB') return `${value.toFixed(1)} ${unit}`;
    value /= 1024;
  }
  return `${value.toFixed(1)} GiB`;
}

function speakerColour(id) {
  if (id < 0) return 'var(--text-faint)';
  return `var(--speaker-${(id % SPEAKER_COLOURS) + 1})`;
}

function say(message) {
  $('status').textContent = message;
}

let toastTimer = null;
function toast(message, isError) {
  const node = $('toast');
  node.textContent = message;
  node.classList.toggle('error', Boolean(isError));
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, isError ? 7000 : 3500);
}

async function api(path, options = {}) {
  const response = await fetch(path, { credentials: 'same-origin', ...options });
  const type = response.headers.get('content-type') || '';
  const body = type.includes('application/json') ? await response.json() : null;
  if (!response.ok) {
    const detail = (body && (body.detail || body.message)) || response.statusText;
    throw new Error(typeof detail === 'string' ? detail : 'the request failed');
  }
  return body;
}

function postJson(path, payload) {
  return api(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload || {}),
  });
}

// ---------------------------------------------------------------------------
// Settings: the sidebar, and what is remembered between visits
// ---------------------------------------------------------------------------

function readSettings() {
  return {
    model: $('model').value,
    spkmodel: $('spkmodel').value,
    threshold: parseFloat($('threshold').value),
    minframes: parseInt($('minframes').value, 10) || 40,
    maxspeakers: parseInt($('maxspeakers').value, 10) || 0,
    speaker_prefix: $('speaker-prefix').value.trim() || 'Speaker',
  };
}

function applySettings(settings) {
  state.settings = settings;
  $('threshold').value = settings.threshold;
  $('threshold-value').textContent = Number(settings.threshold).toFixed(2);
  $('minframes').value = settings.minframes;
  $('maxspeakers').value = settings.maxspeakers;
  $('speaker-prefix').value = settings.speaker_prefix;
  fillModelSelects(settings);
}

let saveTimer = null;
function saveSettings() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    try {
      state.settings = await api('/api/settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(readSettings()),
      });
    } catch (error) {
      // Losing a preference is not worth interrupting anyone over.
    }
  }, 400);
}

function fillModelSelects(settings) {
  const fill = (select, kind, value, emptyLabel) => {
    const models = state.models.filter((m) => m.kind === kind);
    select.innerHTML = '';
    if (kind === 'speaker') {
      select.append(new Option('(none — one speaker only)', ''));
    } else if (models.length === 0) {
      select.append(new Option(emptyLabel, ''));
    }
    for (const model of models) select.append(new Option(model.name, model.name));
    select.value = models.some((m) => m.name === value) ? value : (kind === 'speaker' ? '' : '');
  };
  fill($('model'), 'recognition', settings.model, 'no model — download one');
  fill($('spkmodel'), 'speaker', settings.spkmodel, '');
}

// ---------------------------------------------------------------------------
// Rendering the results
// ---------------------------------------------------------------------------

function renderSegments() {
  const body = $('segments-body');
  const empty = $('segments-empty');
  body.textContent = '';

  if (state.segments.length === 0) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  const fragment = document.createDocumentFragment();
  for (const segment of state.segments) {
    const row = document.createElement('tr');
    row.dataset.index = segment.index;
    if (segment.index === state.selectedSegment) row.classList.add('selected');

    const cell = (text, className) => {
      const td = document.createElement('td');
      td.className = className;
      td.textContent = text;
      return td;
    };
    row.append(cell(timecode(segment.start), 'c-start'));
    row.append(cell(timecode(segment.end), 'c-end'));
    row.append(cell(`${(segment.duration || 0).toFixed(1)} s`, 'c-len'));

    const who = cell('', 'c-speaker');
    who.style.color = speakerColour(segment.speaker);
    who.textContent = segment.name;
    row.append(who);

    row.append(cell(segment.text, 'c-text'));
    fragment.append(row);
  }
  body.append(fragment);
}

// Appends one row while a run is going, rather than redrawing the table for
// every passage that arrives: on a long file that is the difference between a
// usable page and a page that stutters.
function appendSegmentRow(segment) {
  state.segments.push(segment);
  $('segments-empty').hidden = true;

  const body = $('segments-body');
  const row = document.createElement('tr');
  row.dataset.index = segment.index;
  const cell = (text, className, colour) => {
    const td = document.createElement('td');
    td.className = className;
    td.textContent = text;
    if (colour) td.style.color = colour;
    return td;
  };
  row.append(cell(timecode(segment.start), 'c-start'));
  row.append(cell(timecode(segment.end), 'c-end'));
  row.append(cell(`${(segment.duration || 0).toFixed(1)} s`, 'c-len'));
  row.append(cell(segment.name, 'c-speaker', speakerColour(segment.speaker)));
  row.append(cell(segment.text, 'c-text'));
  body.append(row);

  // Follow the end of the list only while the reader has not scrolled away,
  // otherwise re-reading an earlier passage mid-run becomes impossible.
  const wrap = row.closest('.table-wrap');
  if (wrap && wrap.scrollTop + wrap.clientHeight >= wrap.scrollHeight - row.offsetHeight - 40) {
    wrap.scrollTop = wrap.scrollHeight;
  }
}

function renderRunningText() {
  const view = $('running-text');
  view.textContent = '';
  if (state.segments.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'Nothing yet.';
    view.append(empty);
    return;
  }

  let previous = -2;
  let turn = null;
  for (const segment of state.segments) {
    // A new block only when the speaker changes, so a long turn reads as a
    // paragraph instead of a list of fragments.
    if (segment.speaker !== previous) {
      turn = document.createElement('div');
      turn.className = 'turn';
      const head = document.createElement('div');
      head.className = 'turn-head';
      const tc = document.createElement('span');
      tc.className = 'tc';
      tc.textContent = timecode(segment.start);
      const who = document.createElement('span');
      who.className = 'who';
      who.style.color = speakerColour(segment.speaker);
      who.textContent = segment.name;
      head.append(tc, who);
      turn.append(head);
      view.append(turn);
      previous = segment.speaker;
    }
    const line = document.createElement('p');
    line.textContent = segment.text;
    turn.append(line);
  }
}

function renderSpeakers() {
  const body = $('speakers-body');
  const empty = $('speakers-empty');
  body.textContent = '';
  if (state.speakers.length === 0) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  for (const speaker of state.speakers) {
    const row = document.createElement('tr');
    row.dataset.id = speaker.id;
    if (speaker.id === state.selectedSpeaker) row.classList.add('selected');

    const name = document.createElement('td');
    const swatch = document.createElement('span');
    swatch.className = 'swatch';
    swatch.style.background = speakerColour(speaker.id);
    name.append(swatch, document.createTextNode(speaker.name));
    row.append(name);

    const time = document.createElement('td');
    time.className = 'num';
    time.textContent = humanDuration(speaker.time);
    row.append(time);

    const count = document.createElement('td');
    count.className = 'num';
    count.textContent = speaker.segments;
    row.append(count);

    body.append(row);
  }
}

function renderStats(job) {
  if (!job) {
    $('stats').textContent = '';
    return;
  }
  if (job.state === 'running') {
    $('stats').textContent =
      `${timecode(job.position)}    ${job.speed.toFixed(1)}x realtime    ` +
      `${job.segment_count} segments`;
  } else if (job.state === 'queued') {
    // The position counts from one, so the jobs ahead are one fewer.
    const ahead = Math.max(0, (job.queue_position || 1) - 1);
    $('stats').textContent = ahead === 0
      ? `next in line · ${state.queue.running}/${state.queue.capacity} slots busy`
      : `${ahead} ahead in the queue · ${state.queue.running}/${state.queue.capacity} slots busy`;
  } else {
    $('stats').textContent = job.segment_count
      ? `${job.segment_count} segments · ${job.speaker_count} speaker(s)`
      : '';
  }
}

function renderCapacity() {
  const q = state.queue;
  const node = $('capacity');
  const full = q.running >= q.capacity;
  node.innerHTML = '';
  const span = document.createElement('span');
  span.className = full ? 'full' : '';
  span.textContent =
    `server: ${q.running}/${q.capacity} transcribing` +
    (q.queued ? ` · ${q.queued} waiting` : '');
  node.append(span);
}

function renderJob(job, { withSegments } = {}) {
  state.job = job;
  if (withSegments && job.segments) {
    state.segments = job.segments;
    renderSegments();
    if (currentTab() === 'running') renderRunningText();
  }
  state.speakers = job.speakers || [];
  renderSpeakers();
  $('progress').value = Math.round((job.fraction || 0) * 100);
  say(job.status);
  renderStats(job);
  setBusy(job.state === 'running' || job.state === 'queued');
}

function setBusy(busy) {
  $('start').disabled = busy;
  $('browse').disabled = busy;
  $('cancel').disabled = !busy;
  $('recluster').disabled = busy;
  $('rename').disabled = busy;
  if (busy) {
    $('start').title = 'One transcription at a time per user.';
  } else {
    $('start').title = '';
  }
}

function currentTab() {
  const active = document.querySelector('.tab.active');
  return active ? active.dataset.tab : 'segments';
}

// ---------------------------------------------------------------------------
// Running a transcription
// ---------------------------------------------------------------------------

function chooseFile(file) {
  if (!file) return;
  const name = file.name.toLowerCase();
  if (!/\.(mp3|wav|wave)$/.test(name)) {
    toast('MP3 and WAV only. Convert first: ffmpeg -i source.m4a -ar 16000 -ac 1 out.wav', true);
    return;
  }
  const limit = state.limits.max_upload_bytes;
  if (limit && file.size > limit) {
    toast(`That file is ${humanBytes(file.size)}; the limit here is ${humanBytes(limit)}.`, true);
    return;
  }
  state.file = file;
  const label = $('filename');
  label.textContent = `${file.name} — ${humanBytes(file.size)}`;
  label.classList.remove('placeholder');
  say(`Selected: ${file.name}`);
}

async function start() {
  if (!state.file) {
    toast('Choose an audio file first.', true);
    return;
  }
  const settings = readSettings();
  if (!settings.model) {
    toast('Choose a Vosk recognition model in the panel on the right.', true);
    return;
  }
  if (!settings.spkmodel) {
    const go = window.confirm(
      'Without a speaker model the audio is still transcribed, but every passage ' +
      'is attributed to a single voice.\n\nContinue anyway?');
    if (!go) return;
  }

  clearResults();
  setBusy(true);
  say('Uploading...');
  $('progress').value = 0;

  const form = new FormData();
  form.append('file', state.file, state.file.name);
  form.append('settings', JSON.stringify(settings));

  let result;
  try {
    result = await api('/api/jobs', { method: 'POST', body: form });
  } catch (error) {
    setBusy(false);
    say('Ready.');
    toast(error.message, true);
    return;
  }

  state.queue = result.queue;
  renderCapacity();
  renderJob(result.job, { withSegments: true });
  watch(result.job.id);
}

function clearResults() {
  state.segments = [];
  state.speakers = [];
  state.selectedSegment = -1;
  state.selectedSpeaker = -1;
  renderSegments();
  renderSpeakers();
  renderRunningText();
  $('stats').textContent = '';
}

function isActive(job) {
  return Boolean(job) && ['queued', 'running'].includes(job.state);
}

function watch(jobId) {
  if (state.stream) state.stream.close();
  state.stream = null;
  // A hidden tab holds no stream; it catches up when it is shown again. See
  // wireVisibility for why that matters.
  if (document.hidden) return;
  const stream = new EventSource(`/api/jobs/${jobId}/events`);
  state.stream = stream;

  stream.onmessage = (message) => {
    let payload;
    try {
      payload = JSON.parse(message.data);
    } catch (error) {
      return;
    }
    if (payload.queue) {
      state.queue = payload.queue;
      renderCapacity();
    }
    switch (payload.type) {
      case 'snapshot':
        renderJob(payload.job, { withSegments: true });
        break;
      case 'segment':
        appendSegmentRow(payload.segment);
        state.job = payload.job;
        break;
      case 'progress':
      case 'status':
      case 'queue':
        renderJob(payload.job);
        break;
      case 'state':
      case 'final':
        stream.close();
        state.stream = null;
        renderJob(payload.job, { withSegments: true });
        if (payload.job.state === 'failed') {
          toast(payload.job.message || 'the transcription failed', true);
        } else if (payload.job.state === 'done') {
          toast('Done. The transcript is ready to export.');
        }
        break;
      default:
        break;
    }
  };

  stream.onerror = () => {
    // EventSource retries on its own; the state is re-sent as a snapshot when
    // it reconnects, so there is nothing to do but let it.
    if (stream.readyState === EventSource.CLOSED) {
      state.stream = null;
      refreshJob(jobId);
    }
  };
}

async function refreshJob(jobId) {
  try {
    const result = await api(`/api/jobs/${jobId}`);
    state.queue = result.queue;
    renderCapacity();
    renderJob(result.job, { withSegments: true });
  } catch (error) {
    /* the job is gone; the page is already showing the last state it knew */
  }
}

async function cancel() {
  if (!isActive(state.job)) return;
  try {
    await postJson(`/api/jobs/${state.job.id}/cancel`, {});
    say('Cancelling...');
  } catch (error) {
    toast(error.message, true);
  }
}

// ---------------------------------------------------------------------------
// After the run: regrouping, renaming, reassigning
// ---------------------------------------------------------------------------

function requireTranscript() {
  if (!state.job || !state.segments.length || state.job.state === 'running') {
    toast('Transcribe a file first.', true);
    return false;
  }
  return true;
}

async function recluster() {
  if (!requireTranscript()) return;
  const settings = readSettings();
  say('Regrouping...');
  try {
    const result = await postJson(`/api/jobs/${state.job.id}/recluster`, {
      threshold: settings.threshold,
      minframes: settings.minframes,
      maxspeakers: settings.maxspeakers,
    });
    renderJob(result.job, { withSegments: true });
    say(result.note);
    toast(result.note);
  } catch (error) {
    toast(error.message, true);
  }
}

async function renameSpeaker() {
  if (state.selectedSpeaker < 0) {
    toast('Select a speaker in the list first.', true);
    return;
  }
  const name = $('rename-entry').value.trim();
  try {
    const result = await postJson(
      `/api/jobs/${state.job.id}/speakers/${state.selectedSpeaker}/name`, { name });
    renderJob(result.job, { withSegments: true });
    say('Speaker renamed.');
  } catch (error) {
    toast(error.message, true);
  }
}

async function assignSegment(index, speaker) {
  try {
    const result = await postJson(
      `/api/jobs/${state.job.id}/segments/${index}/speaker`, { speaker });
    renderJob(result.job, { withSegments: true });
    say('Segment reassigned.');
  } catch (error) {
    toast(error.message, true);
  }
}

// The context menu a right click gives on a segment in the native interface.
function openSegmentMenu(event, index) {
  if (!state.job || state.job.state === 'running') return;
  event.preventDefault();
  state.selectedSegment = index;
  renderSegments();

  const menu = $('segment-menu');
  menu.textContent = '';
  for (const speaker of state.speakers) {
    const item = document.createElement('button');
    item.type = 'button';
    item.textContent = `Assign to ${speaker.name}`;
    item.onclick = () => { closeSegmentMenu(); assignSegment(index, speaker.id); };
    menu.append(item);
  }
  if (state.speakers.length) menu.append(document.createElement('hr'));
  const fresh = document.createElement('button');
  fresh.type = 'button';
  fresh.textContent = 'New speaker';
  fresh.onclick = () => { closeSegmentMenu(); assignSegment(index, state.speakers.length); };
  menu.append(fresh);

  menu.hidden = false;
  // Placed after it is measurable, and never off the bottom or right edge.
  const { width, height } = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(event.clientX, window.innerWidth - width - 8)}px`;
  menu.style.top = `${Math.min(event.clientY, window.innerHeight - height - 8)}px`;
}

function closeSegmentMenu() {
  $('segment-menu').hidden = true;
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

function exportAs(format) {
  if (!requireTranscript()) return;
  // A plain navigation: the response carries Content-Disposition, so the
  // browser saves it under the right name without any help.
  const link = document.createElement('a');
  link.href = `/api/jobs/${state.job.id}/export?format=${encodeURIComponent(format)}`;
  link.download = '';
  document.body.append(link);
  link.click();
  link.remove();
  say(`Exported as ${format}.`);
}

// ---------------------------------------------------------------------------
// The model catalogue
// ---------------------------------------------------------------------------

async function openCatalogue() {
  const dialog = $('catalogue');
  dialog.showModal();
  if (!state.limits.allow_model_download) {
    $('catalogue-status').textContent = 'Downloading models is switched off on this server.';
    $('catalogue-download').disabled = true;
  }
  if (!state.catalogue) await loadCatalogue(false);
  else renderCatalogue();
  pollDownload();
}

async function loadCatalogue(refresh) {
  $('catalogue-empty').hidden = false;
  $('catalogue-empty').textContent = 'Fetching the list of models...';
  try {
    state.catalogue = await api(`/api/catalogue${refresh ? '?refresh=true' : ''}`);
  } catch (error) {
    $('catalogue-empty').textContent = error.message;
    return;
  }
  const select = $('catalogue-lang');
  const chosen = select.value || 'All languages';
  select.innerHTML = '';
  select.append(new Option('All languages', 'All languages'));
  for (const language of state.catalogue.languages) select.append(new Option(language, language));
  select.value = state.catalogue.languages.includes(chosen) ? chosen : 'All languages';
  renderCatalogue();
}

function renderCatalogue() {
  if (!state.catalogue) return;
  const language = $('catalogue-lang').value || 'All languages';
  const body = $('catalogue-body');
  body.textContent = '';

  const rows = state.catalogue.models.filter(
    (m) => language === 'All languages' || m.universal || m.language === language);

  $('catalogue-empty').hidden = rows.length > 0;
  $('catalogue-empty').textContent = 'No model for that language.';

  for (const model of rows) {
    const row = document.createElement('tr');
    row.dataset.name = model.name;
    const cell = (text, className) => {
      const td = document.createElement('td');
      if (className) td.className = className;
      td.textContent = text;
      return td;
    };
    row.append(cell(model.name));
    row.append(cell(model.size_text, 'num'));
    row.append(cell(model.kind));
    row.append(cell(model.installed ? 'installed' : '', model.installed ? 'installed' : ''));
    row.onclick = () => {
      body.querySelectorAll('tr').forEach((r) => r.classList.remove('selected'));
      row.classList.add('selected');
    };
    row.ondblclick = () => { row.click(); downloadSelected(); };
    body.append(row);
  }
  if (!$('catalogue-status').textContent) {
    $('catalogue-status').textContent = `${rows.length} models available.`;
  }
}

async function downloadSelected() {
  const selected = $('catalogue-body').querySelector('tr.selected');
  if (!selected) {
    $('catalogue-status').textContent = 'Select a model in the list first.';
    return;
  }
  $('catalogue-download').disabled = true;
  $('catalogue-status').textContent = 'Starting the download...';
  try {
    const started = await postJson('/api/catalogue/download', { name: selected.dataset.name });
    state.watchedDownload = started.name;
    if (started.state === 'done') {
      // Already on disk: put it to use rather than fetch it a second time.
      applyDownloadedModel(started);
      $('catalogue-download').disabled = false;
      $('catalogue-status').textContent = `Already downloaded. ${started.name} is now selected.`;
      state.watchedDownload = null;
      return;
    }
  } catch (error) {
    $('catalogue-download').disabled = false;
    $('catalogue-status').textContent = error.message;
    return;
  }
  pollDownload();
}

function pollDownload() {
  clearInterval(state.downloadPoll);
  const tick = async () => {
    let result;
    try {
      result = await api('/api/catalogue/download');
    } catch (error) {
      return;
    }
    // The list of installed models changes under us as one arrives, and the
    // panel's two menus have to follow, or a model just fetched cannot be
    // chosen without a reload.
    const before = state.models.map((m) => m.name).join('|');
    state.models = result.models;
    if (before !== state.models.map((m) => m.name).join('|')) {
      fillModelSelects(state.settings || readSettings());
      if (state.catalogue) {
        const installed = new Set(state.models.map((m) => m.name));
        for (const model of state.catalogue.models) model.installed = installed.has(model.name);
        renderCatalogue();
      }
    }

    const download = result.download;
    const inProgress = download && ['downloading', 'unpacking'].includes(download.state);
    if (inProgress) state.watchedDownload = download.name;
    if (!download || (!inProgress && download.name !== state.watchedDownload)) {
      // Nothing running, or only the remains of a transfer this page never
      // saw: nothing to report.
      $('catalogue-progress').value = 0;
      $('catalogue-download').disabled = !state.limits.allow_model_download;
      clearInterval(state.downloadPoll);
      return;
    }
    if (download.state === 'downloading') {
      $('catalogue-progress').value = Math.round(download.fraction * 100);
      $('catalogue-status').textContent =
        `Downloading ${download.name}: ${humanBytes(download.received)}` +
        (download.size ? ` of ${humanBytes(download.size)}` : '');
      $('catalogue-download').disabled = true;
    } else if (download.state === 'unpacking') {
      $('catalogue-progress').value = 100;
      $('catalogue-status').textContent = `Unpacking ${download.name}...`;
      $('catalogue-download').disabled = true;
    } else {
      clearInterval(state.downloadPoll);
      state.watchedDownload = null;
      $('catalogue-progress').value = 0;
      $('catalogue-download').disabled = !state.limits.allow_model_download;
      if (download.state === 'done') {
        // A model that has just arrived is put to use straight away: pointing
        // the panel at it by hand would be a pointless second step.
        applyDownloadedModel(download);
        $('catalogue-status').textContent =
          `${download.name} is ready, and is now the selected model.`;
        say(`Model ready: ${download.name}`);
      } else {
        $('catalogue-status').textContent = `${download.name}: ${download.message}`;
      }
    }
  };
  tick();
  state.downloadPoll = setInterval(tick, 1000);
}

function applyDownloadedModel(download) {
  const select = download.kind === 'speaker' ? $('spkmodel') : $('model');
  if ([...select.options].some((option) => option.value === download.name)) {
    select.value = download.name;
    saveSettings();
  }
}

// ---------------------------------------------------------------------------
// Earlier transcriptions
// ---------------------------------------------------------------------------

async function openHistory() {
  const dialog = $('history');
  dialog.showModal();
  const body = $('history-body');
  body.textContent = '';
  let result;
  try {
    result = await api('/api/jobs');
  } catch (error) {
    $('history-empty').hidden = false;
    $('history-empty').textContent = error.message;
    return;
  }
  $('history-empty').hidden = result.jobs.length > 0;

  for (const job of result.jobs) {
    const row = document.createElement('tr');
    const cell = (text, className) => {
      const td = document.createElement('td');
      if (className) td.className = className;
      td.textContent = text;
      return td;
    };
    row.append(cell(job.filename, 'file'));
    row.append(cell(new Date(job.created * 1000).toLocaleString()));
    row.append(cell(job.state));
    row.append(cell(job.segment_count, 'num'));

    const actions = document.createElement('td');
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'link';
    open.textContent = 'Open';
    open.onclick = async () => {
      dialog.close();
      await refreshJob(job.id);
      if (isActive(job)) watch(job.id);
    };
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'link';
    remove.textContent = 'Delete';
    remove.onclick = async () => {
      if (!window.confirm(`Delete ${job.filename} and its transcript?`)) return;
      try {
        await api(`/api/jobs/${job.id}`, { method: 'DELETE' });
        row.remove();
        if (state.job && state.job.id === job.id) { state.job = null; clearResults(); }
      } catch (error) {
        toast(error.message, true);
      }
    };
    actions.append(open, remove);
    row.append(actions);
    body.append(row);
  }
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function wireMenus() {
  const menus = [...document.querySelectorAll('.menu')];
  const closeAll = () => menus.forEach((menu) => {
    menu.classList.remove('open');
    menu.querySelector('.menu-title').setAttribute('aria-expanded', 'false');
  });

  for (const menu of menus) {
    const title = menu.querySelector('.menu-title');
    title.onclick = (event) => {
      event.stopPropagation();
      const open = menu.classList.contains('open');
      closeAll();
      if (!open) {
        menu.classList.add('open');
        title.setAttribute('aria-expanded', 'true');
      }
    };
  }
  document.addEventListener('click', () => { closeAll(); closeSegmentMenu(); });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { closeAll(); closeSegmentMenu(); }
  });

  document.querySelectorAll('[data-export]').forEach((item) => {
    item.onclick = () => exportAs(item.dataset.export);
  });
  document.querySelectorAll('[data-action]').forEach((item) => {
    item.onclick = () => {
      switch (item.dataset.action) {
        case 'open': $('audio-input').click(); break;
        case 'save-txt': exportAs('txt'); break;
        case 'start': start(); break;
        case 'cancel': cancel(); break;
        case 'recluster': recluster(); break;
        case 'history': openHistory(); break;
        case 'about': $('about').showModal(); break;
        default: break;
      }
    };
  });
}

function wireToolbar() {
  const input = $('audio-input');
  const field = $('filefield');

  $('browse').onclick = () => input.click();
  field.onclick = () => input.click();
  field.onkeydown = (event) => {
    if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); input.click(); }
  };
  input.onchange = () => chooseFile(input.files[0]);

  for (const type of ['dragenter', 'dragover']) {
    field.addEventListener(type, (event) => {
      event.preventDefault();
      field.classList.add('dragover');
    });
  }
  for (const type of ['dragleave', 'drop']) {
    field.addEventListener(type, () => field.classList.remove('dragover'));
  }
  field.addEventListener('drop', (event) => {
    event.preventDefault();
    chooseFile(event.dataTransfer.files[0]);
  });
  // A file dropped anywhere else should not be opened by the browser instead.
  document.addEventListener('dragover', (event) => event.preventDefault());
  document.addEventListener('drop', (event) => event.preventDefault());

  $('start').onclick = start;
  $('cancel').onclick = cancel;
}

function wireTabs() {
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.onclick = () => {
      document.querySelectorAll('.tab').forEach((other) => {
        const active = other === tab;
        other.classList.toggle('active', active);
        other.setAttribute('aria-selected', String(active));
      });
      $('tab-segments').classList.toggle('hidden', tab.dataset.tab !== 'segments');
      $('tab-running').classList.toggle('hidden', tab.dataset.tab !== 'running');
      // The running text is rebuilt when shown rather than on every passage:
      // during a long transcription that avoids redrawing it in a loop.
      if (tab.dataset.tab === 'running') renderRunningText();
    };
  });
}

function wireSidebar() {
  $('threshold').oninput = () => {
    $('threshold-value').textContent = Number($('threshold').value).toFixed(2);
  };
  $('threshold').onchange = saveSettings;
  $('minframes').onchange = saveSettings;
  $('maxspeakers').onchange = saveSettings;
  $('speaker-prefix').onchange = saveSettings;
  $('model').onchange = saveSettings;
  $('spkmodel').onchange = saveSettings;
  $('recluster').onclick = recluster;
  $('rename').onclick = renameSpeaker;
  $('rename-entry').onkeydown = (event) => {
    if (event.key === 'Enter') { event.preventDefault(); renameSpeaker(); }
  };

  $('speakers-body').onclick = (event) => {
    const row = event.target.closest('tr');
    if (!row) return;
    state.selectedSpeaker = Number(row.dataset.id);
    const speaker = state.speakers.find((s) => s.id === state.selectedSpeaker);
    if (speaker) $('rename-entry').value = speaker.name;
    renderSpeakers();
  };

  $('open-catalogue').onclick = openCatalogue;
}

function wireTables() {
  const body = $('segments-body');
  body.onclick = (event) => {
    const row = event.target.closest('tr');
    if (!row) return;
    state.selectedSegment = Number(row.dataset.index);
    renderSegments();
  };
  body.oncontextmenu = (event) => {
    const row = event.target.closest('tr');
    if (!row) return;
    openSegmentMenu(event, Number(row.dataset.index));
  };
}

function wireDialogs() {
  $('catalogue-lang').onchange = () => {
    $('catalogue-status').textContent = '';
    renderCatalogue();
  };
  $('catalogue-refresh').onclick = () => loadCatalogue(true);
  $('catalogue-download').onclick = downloadSelected;
  $('catalogue-close').onclick = () => $('catalogue').close();
  $('catalogue').addEventListener('close', () => clearInterval(state.downloadPoll));
  $('history-close').onclick = () => $('history').close();
  $('about-close').onclick = () => $('about').close();
}

// Only the tab being looked at keeps a live stream.
//
// A stream is a connection held open for as long as a run lasts, and a
// browser allows six HTTP/1.1 connections to one server, all tabs together.
// Measured: with six streams open, every other request from that browser --
// the page's own included -- waits until one closes. Someone who keeps the
// application open in six tabs during a run would see all of them freeze.
// A hidden tab therefore lets its stream go, and on being shown again asks
// for the job afresh; the snapshot the server sends first on every stream is
// what makes that catching up complete rather than approximate.
function wireVisibility() {
  document.addEventListener('visibilitychange', async () => {
    if (document.hidden) {
      if (state.stream) {
        state.stream.close();
        state.stream = null;
      }
      return;
    }
    if (!state.job) return;
    const wasActive = isActive(state.job);
    if (!wasActive) return;
    await refreshJob(state.job.id);
    if (isActive(state.job)) watch(state.job.id);
  });
}

function wireKeys() {
  document.addEventListener('keydown', (event) => {
    const meta = event.ctrlKey || event.metaKey;
    if (!meta) return;
    const key = event.key.toLowerCase();
    if (key === 'o') { event.preventDefault(); $('audio-input').click(); }
    else if (key === 'r') { event.preventDefault(); start(); }
    else if (key === 's') { event.preventDefault(); exportAs('txt'); }
  });
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

async function main() {
  wireMenus();
  wireToolbar();
  wireTabs();
  wireSidebar();
  wireTables();
  wireDialogs();
  wireKeys();
  wireVisibility();

  let initial;
  try {
    initial = await api('/api/state');
  } catch (error) {
    say('The server is not reachable.');
    toast(error.message, true);
    return;
  }

  state.models = initial.models;
  state.queue = initial.queue;
  state.limits = initial.limits;
  applySettings(initial.settings);
  renderCapacity();
  renderSegments();
  renderSpeakers();

  $('about-limits').textContent =
    `This server transcribes ${initial.queue.capacity} files at a time, and ` +
    `${initial.queue.per_user} per user. Beyond that, a job waits in a queue and ` +
    `is told where it stands.`;

  if (!initial.settings.model) {
    say('Choose a Vosk model in the panel on the right to begin.');
  } else {
    say(`Ready. Model: ${initial.settings.model}`);
  }

  // A run left going by a reload -- or by another tab -- is picked back up
  // rather than lost.
  const active = initial.jobs.find(isActive);
  const latest = active || initial.jobs[0];
  if (latest) {
    await refreshJob(latest.id);
    if (active) watch(active.id);
  }

  setInterval(async () => {
    // The stream already carries the queue, and a hidden tab has no one to
    // show it to.
    if (state.stream || document.hidden) return;
    try {
      state.queue = await api('/api/queue');
      renderCapacity();
    } catch (error) { /* transient */ }
  }, 10000);
}

main();
