// Pipit speaker-attribution probe. Paste into the browser console on a meeting
// tab, then run the call. It records four things on one clock:
//
//   1. Per-participant audio levels from WebRTC contributing sources (CSRC).
//      Meet gives every participant a CSRC that lasts the whole conference, so
//      a CSRC is a stable per-person key with packet-rate timing.
//   2. Audio envelopes for the local microphone and the mixed far end. These
//      are the ground truth. Everything else gets scored against when the
//      waveform actually moved.
//   3. Every DOM attribute that changes, grouped by element signature. The
//      speaking indicator is whichever attribute flips in time with speech, so
//      this finds it instead of guessing a selector.
//   4. Caption and participant-panel text, with the element it came from.
//
// Paste it at any point, including mid-call. The constructor hook only catches
// connections opened afterwards, and Meet takes its own reference to
// RTCPeerConnection when its bundle loads, so that hook alone finds nothing in a
// call already running. The prototype harvest is what covers that case, because
// prototype methods are looked up when they are called.
//
// Nothing has to be typed during the call. A panel appears at the top of the
// page. Join, press Start, then do what the panel says. It marks its own phase
// changes, and the Save button writes the log out.

(() => {
  // A re-paste replaces the old probe rather than returning it. Refusing to
  // reinstall means a newer version pasted over an older one silently does
  // nothing, and the only symptom is data that never arrives.
  const existing = window.__pipitProbe;
  if (existing && existing.installed) {
    console.warn('[pipit] replacing the probe already on this page');
    try { existing.stop(); } catch {}
    try { existing.ui && existing.ui.remove(); } catch {}
    try { (existing.sinks || []).forEach((el) => el.remove()); } catch {}
    window.__pipitProbe = null;
  }

  const P = {
    installed: true,
    startedAt: Date.now(),
    t0: performance.now(),
    pcs: new Set(),
    rtc: [],          // { t, pc, csrc, level, voice, kind }
    attrs: new Map(), // signature -> { count, samples: [{t, attr, from, to}] }
    text: [],         // { t, source, name, body }
    marks: [],        // { t, label }
    seenCsrc: new Map(),
  };
  window.__pipitProbe = P;

  const now = () => Math.round(performance.now() - P.t0);

  P.mark = (label) => {
    P.marks.push({ t: now(), label: String(label) });
    console.log(`[pipit] mark ${label} @ ${now()}ms`);
  };

  // ---------------------------------------------------------------- WebRTC

  let pcSeq = 0;

  // Zoom's client lives in an iframe with its own window object, so the hook has
  // to be installed per window. Patching only the top one would miss every
  // connection Zoom opens.
  function hookWindow(win, label) {
    let NativePC;
    try { NativePC = win.RTCPeerConnection; } catch { return false; }
    if (!NativePC) return false;
    if (NativePC.__pipitPatched) return true;
    const Patched = function (...args) {
      const pc = new NativePC(...args);
      pc.__pipitId = ++pcSeq;
      pc.__pipitWindow = label;
      P.pcs.add(pc);
      console.log(`[pipit] peer connection ${pc.__pipitId} created in ${label}`);
      return pc;
    };
    Patched.prototype = NativePC.prototype;
    Patched.__pipitPatched = true;
    Object.getOwnPropertyNames(NativePC)
      .filter((k) => !['length', 'name', 'prototype'].includes(k))
      .forEach((k) => { try { Patched[k] = NativePC[k]; } catch {} });
    try {
      win.RTCPeerConnection = Patched;
      win.webkitRTCPeerConnection = Patched;
    } catch (err) {
      console.warn(`[pipit] cannot hook ${label}`, err);
      return false;
    }
    console.log(`[pipit] RTCPeerConnection hooked in ${label}`);
    return true;
  }

  if (!hookWindow(window, 'top')) {
    console.warn('[pipit] no RTCPeerConnection on the top window');
  }

  // Hooking the constructor only catches connections opened after the hook. Meet
  // takes its own reference to RTCPeerConnection when its bundle loads, so a hook
  // pasted into a console afterwards sees nothing at all.
  //
  // Prototype methods are looked up at call time, so wrapping them catches
  // connections that already exist. Meet polls getStats for its own telemetry and
  // reads getReceivers constantly, so a live call surfaces itself within seconds.
  function harvest(win, label) {
    const proto = win.RTCPeerConnection && win.RTCPeerConnection.prototype;
    if (!proto) return;
    // Already wrapped by a previous paste. Re-point it at this probe's set
    // instead of wrapping twice.
    if (proto.__pipitHarvested) { win.__pipitHarvestSink = P.pcs; return; }
    proto.__pipitHarvested = true;
    win.__pipitHarvestSink = P.pcs;
    let seq = 0;
    for (const name of ['getStats', 'getReceivers', 'getSenders', 'getTransceivers',
      'addIceCandidate', 'setRemoteDescription', 'createOffer', 'createAnswer']) {
      const original = proto[name];
      if (typeof original !== 'function') continue;
      proto[name] = function (...args) {
        const sink = win.__pipitHarvestSink;
        if (sink && !sink.has(this)) {
          this.__pipitId = this.__pipitId || `p${++seq}`;
          this.__pipitWindow = label;
          sink.add(this);
          console.log(`[pipit] harvested peer connection ${this.__pipitId} via ${name}`);
        }
        return original.apply(this, args);
      };
    }
    console.log(`[pipit] prototype harvest armed in ${label}`);
  }
  harvest(window, 'top');

  // getContributingSources returns everything from the last ten seconds, so
  // entries are keyed by source plus their own timestamp to avoid recounting.
  function pollRTC() {
    for (const pc of P.pcs) {
      let receivers = [];
      try { receivers = pc.getReceivers(); } catch { continue; }
      for (const r of receivers) {
        if (!r.track || r.track.kind !== 'audio') continue;
        const rows = [];
        try { (r.getContributingSources?.() || []).forEach((s) => rows.push(['csrc', s])); } catch {}
        try { (r.getSynchronizationSources?.() || []).forEach((s) => rows.push(['ssrc', s])); } catch {}
        for (const [kind, s] of rows) {
          const key = `${pc.__pipitId}:${kind}:${s.source}:${s.timestamp}`;
          if (P.seenCsrc.has(key)) continue;
          P.seenCsrc.set(key, true);
          P.rtc.push({
            t: now(),
            pc: pc.__pipitId,
            kind,
            csrc: s.source,
            level: s.audioLevel ?? null,
            voice: s.voiceActivityFlag ?? null,
            rtpTs: s.rtpTimestamp ?? null,
            wallTs: s.timestamp ?? null,
          });
        }
      }
    }
    if (P.seenCsrc.size > 200000) P.seenCsrc.clear();
  }
  P.rtcTimer = setInterval(pollRTC, 100);

  // ----------------------------------------------------------- audio truth

  // The recorded waveform is the ground truth, so the probe measures it rather
  // than asking the operator to announce turns. Two envelopes, both on the same
  // clock as everything else: the local microphone, and the mixed far end.
  //
  // This is what makes the lag question answerable. The distance between a rise
  // in the envelope and the moment the UI or the CSRC stream reacts to it is the
  // per-platform constant we have to subtract.

  P.analysers = [];
  P.env = [];

  function tap(stream, label) {
    if (!stream || P.analysers.some((a) => a.label === label)) return;
    try {
      P.ctx = P.ctx || new (window.AudioContext || window.webkitAudioContext)();
      const node = P.ctx.createAnalyser();
      node.fftSize = 512;
      // Deliberately not connected to the destination. Routing a remote track
      // back to the speakers would put the call into a feedback loop.
      P.ctx.createMediaStreamSource(stream).connect(node);
      P.analysers.push({ label, node, buf: new Float32Array(node.fftSize) });
      console.log(`[pipit] tapped ${label}`);
    } catch (err) {
      console.warn(`[pipit] cannot tap ${label}`, err);
    }
  }

  // The page already holds microphone permission for this origin, so a second
  // capture resolves without a prompt.
  P.tapMic = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      P.micStream = stream;
      tap(stream, 'mic');
    } catch (err) {
      console.warn('[pipit] microphone tap refused', err);
    }
  };

  // Remote audio, taken from the media elements the page is already playing.
  //
  // Going through the receivers would be better, because a receiver also exposes
  // getContributingSources and therefore the speaker's identity. It is not
  // reachable from a console. Firefox defines RTCPeerConnection.prototype methods
  // as non-writable and non-configurable, so the prototype cannot be wrapped
  // after the fact, and the constructor hook only catches connections opened
  // later. An extension running at document_start can hook the constructor and
  // does get the receivers.
  //
  // What a media element still gives is the audio itself. Meet plays its three
  // virtual audio slots through three elements, so tapping them yields one
  // envelope per slot. That is enough to see how many slots carry sound at once,
  // which is the question Slack answered with a flat "one".
  function tapRemote() {
    let index = 0;
    const documents = [document];
    // Zoom renders the whole client inside a same-origin iframe, so its media
    // elements are not in the top document.
    for (const frame of document.querySelectorAll('iframe')) {
      try { if (frame.contentDocument) documents.push(frame.contentDocument); } catch {}
    }
    for (const doc of documents) {
      for (const el of doc.querySelectorAll('audio,video')) {
        const stream = el.srcObject;
        if (!stream || typeof stream.getAudioTracks !== 'function') continue;
        for (const track of stream.getAudioTracks()) {
          index += 1;
          if (track.__pipitTapped) continue;
          track.__pipitTapped = true;
          tap(new MediaStream([track]), `slot${index}:${track.id.slice(0, 8)}`);
        }
      }
    }
  }

  // Zoom decodes audio in WebAssembly and plays it through WebAudio rather than
  // through a media element, so there is no track to tap. Wrapping the context's
  // destination catches whatever it renders. This only works when the probe is in
  // place before the page builds its graph, which a console paste usually is not,
  // so treat a silent result here as untested rather than negative.
  function hookAudioContext(win, label) {
    for (const name of ['AudioContext', 'webkitAudioContext']) {
      const Native = win[name];
      if (typeof Native !== 'function' || Native.__pipitPatched) continue;
      const Patched = function (...args) {
        const ctx = new Native(...args);
        try {
          const node = ctx.createAnalyser();
          node.fftSize = 512;
          node.connect(ctx.destination);
          P.analysers.push({
            label: `webaudio@${label}`, node, buf: new Float32Array(node.fftSize),
          });
          ctx.__pipitAnalyser = node;
          console.log(`[pipit] audio context wrapped in ${label}`);
        } catch {}
        return ctx;
      };
      Patched.prototype = Native.prototype;
      Patched.__pipitPatched = true;
      try { win[name] = Patched; } catch {}
    }
  }
  hookAudioContext(window, 'top');

  function sampleEnvelopes() {
    tapRemote();
    if (!P.analysers.length) return;
    const t = now();
    for (const a of P.analysers) {
      a.node.getFloatTimeDomainData(a.buf);
      let sum = 0;
      for (let i = 0; i < a.buf.length; i += 1) sum += a.buf[i] * a.buf[i];
      P.env.push({ t, src: a.label, rms: Math.sqrt(sum / a.buf.length) });
    }
    if (P.env.length > 400000) P.env.splice(0, 100000);
  }
  P.envTimer = setInterval(sampleEnvelopes, 50);
  // Slots appear as the call renegotiates, so keep looking rather than binding
  // once at install time.
  P.slotTimer = setInterval(tapRemote, 1000);

  // ------------------------------------------------------------------- DOM

  // An element signature that survives React re-renders: tag, role, and the
  // class list, which is what a speaking indicator usually toggles.
  function signature(el) {
    if (!el || !el.tagName) return '?';
    const role = el.getAttribute?.('role');
    const jsname = el.getAttribute?.('jsname');
    const testid = el.getAttribute?.('data-testid') || el.getAttribute?.('data-qa');
    return [
      el.tagName.toLowerCase(),
      role ? `role=${role}` : '',
      jsname ? `jsname=${jsname}` : '',
      testid ? `testid=${testid}` : '',
    ].filter(Boolean).join(' ');
  }

  function noteAttr(el, attr, from, to) {
    const sig = `${signature(el)} @${attr}`;
    let entry = P.attrs.get(sig);
    if (!entry) { entry = { count: 0, samples: [], times: [] }; P.attrs.set(sig, entry); }
    entry.count += 1;
    entry.times.push(now());
    if (entry.samples.length < 400) {
      entry.samples.push({
        t: now(),
        from: (from ?? '').slice(0, 90),
        to: (to ?? '').slice(0, 90),
        near: nearestName(el),
      });
    }
  }

  // Climbs to the closest text that looks like a person's label, so an
  // anonymous class flip can still be tied to a participant.
  function nearestName(el) {
    let node = el;
    for (let i = 0; i < 6 && node; i += 1) {
      const label = node.getAttribute?.('aria-label')
        || node.getAttribute?.('data-participant-id')
        || node.getAttribute?.('data-self-name')
        || node.getAttribute?.('title');
      if (label) return String(label).slice(0, 80);
      node = node.parentElement;
    }
    const text = (el.closest?.('[data-participant-id],[role="listitem"]')?.innerText || '').trim();
    return text.slice(0, 80) || null;
  }

  const observer = new MutationObserver((records) => {
    for (const rec of records) {
      if (rec.type === 'attributes') {
        const el = rec.target;
        noteAttr(el, rec.attributeName, rec.oldValue, el.getAttribute?.(rec.attributeName));
      } else if (rec.type === 'characterData') {
        const el = rec.target.parentElement;
        const body = (rec.target.textContent || '').trim();
        if (!body) continue;
        P.text.push({
          t: now(),
          source: signature(el),
          name: nearestName(el),
          prev: (el?.previousElementSibling?.textContent || '').trim().slice(0, 60) || null,
          body: body.slice(0, 300),
        });
        if (P.text.length > 20000) P.text.splice(0, 5000);
      }
    }
  });

  function watch(doc) {
    try {
      observer.observe(doc.documentElement, {
        subtree: true,
        childList: false,
        attributes: true,
        attributeOldValue: true,
        characterData: true,
        characterDataOldValue: true,
      });
      console.log('[pipit] observing', doc.location?.href || 'document');
    } catch (err) {
      console.warn('[pipit] cannot observe', err);
    }
  }
  watch(document);

  // Zoom's web client lives in a same-origin #webclient iframe that appears after
  // the top page loads, so frames are swept on a timer rather than once. The hook
  // has to be in place before that frame opens its connections, which is why the
  // sweep is fast and starts immediately.
  const attached = new WeakSet();
  P.attachFrames = () => {
    for (const frame of document.querySelectorAll('iframe')) {
      if (attached.has(frame)) continue;
      let doc;
      try { doc = frame.contentDocument; } catch { attached.add(frame); continue; }
      if (!doc) continue;
      attached.add(frame);
      const label = `iframe#${frame.id || '?'}`;
      hookWindow(frame.contentWindow, label);
      try { harvest(frame.contentWindow, label); } catch {}
      try { hookAudioContext(frame.contentWindow, label); } catch {}
      watch(doc);
    }
  };
  P.attachFrames();
  P.frameTimer = setInterval(P.attachFrames, 250);

  // ---------------------------------------------------------------- output

  // A one-shot picture of who the page thinks is present.
  P.roster = () => {
    const rows = [];
    const seen = new Set();
    const push = (el, why) => {
      const label = el.getAttribute('aria-label') || (el.innerText || '').trim().slice(0, 60);
      const id = el.getAttribute('data-participant-id') || label;
      if (!id || seen.has(id)) return;
      seen.add(id);
      rows.push({ why, id, label, sig: signature(el) });
    };
    document.querySelectorAll('[data-participant-id]').forEach((el) => push(el, 'data-participant-id'));
    document.querySelectorAll('[role="list"] [role="listitem"]').forEach((el) => push(el, 'listitem'));
    document.querySelectorAll('[aria-label*="icrophone"],[aria-label*="uted"]').forEach((el) => push(el, 'mic-label'));
    return rows;
  };

  P.report = () => {
    const byCsrc = new Map();
    for (const row of P.rtc) {
      const key = `${row.kind}:${row.csrc}`;
      const e = byCsrc.get(key) || { key, pc: row.pc, samples: 0, loud: 0, first: row.t, last: row.t };
      e.samples += 1;
      if ((row.level ?? 0) > 0.02) e.loud += 1;
      e.last = row.t;
      byCsrc.set(key, e);
    }
    console.log(`--- ${P.pcs.size} peer connection(s) seen ---`);
    if (!P.pcs.size) {
      console.warn('[pipit] no peer connections yet. Meet polls getStats every few '
        + 'seconds, so wait, and confirm you are actually in the call.');
    }
    console.log('--- audio sources ---');
    console.table([...byCsrc.values()].sort((a, b) => b.loud - a.loud));
    console.log('--- attributes that changed most ---');
    console.table([...P.attrs.entries()]
      .map(([sig, e]) => ({ sig, count: e.count, example: e.samples[0]?.to, near: e.samples[0]?.near }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 30));
    console.log('--- roster ---');
    console.table(P.roster());
    console.log('--- text sources ---');
    const bySource = new Map();
    for (const row of P.text) bySource.set(row.source, (bySource.get(row.source) || 0) + 1);
    console.table([...bySource.entries()].map(([source, count]) => ({ source, count }))
      .sort((a, b) => b.count - a.count).slice(0, 20));
    console.log('--- audio slots ---');
    const bySlot = new Map();
    for (const e of P.env) {
      const s = bySlot.get(e.src) || { src: e.src, n: 0, max: 0, loud: 0 };
      s.n += 1; s.max = Math.max(s.max, e.rms);
      if (e.rms > 0.004) s.loud += 1;
      bySlot.set(e.src, s);
    }
    console.table([...bySlot.values()]);
    console.log('marks:', P.marks);
    return { sources: byCsrc.size, attrSignatures: P.attrs.size, textEvents: P.text.length };
  };

  // A meeting URL carries a passcode in its query, so the saved log keeps only
  // origin and path. This is the same trim provider.js already does before
  // anything reaches the app.
  const scrubbed = () => {
    try {
      const u = new URL(location.href);
      return `${u.origin}${u.pathname}`;
    } catch { return null; }
  };

  P.dump = () => JSON.stringify({
    href: scrubbed(),
    peerConnections: P.pcs.size,
    startedAt: P.startedAt,
    durationMs: now(),
    marks: P.marks,
    rtc: P.rtc,
    env: P.env,
    attrs: [...P.attrs.entries()].map(([sig, e]) => ({ sig, count: e.count, times: e.times, samples: e.samples })),
    text: P.text,
    roster: P.roster(),
  });

  P.save = () => {
    const blob = new Blob([P.dump()], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `pipit-probe-${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  P.stop = () => {
    clearInterval(P.rtcTimer);
    clearInterval(P.frameTimer);
    clearInterval(P.envTimer);
    clearInterval(P.slotTimer);
    if (P.phaseTimer) clearTimeout(P.phaseTimer);
    for (const track of P.micStream?.getTracks() || []) track.stop();
    observer.disconnect();
    console.log('[pipit] stopped');
  };

  // --------------------------------------------------------------- prompter

  // Nobody can talk and type at the same time, so the screen does the asking and
  // the probe marks its own transitions. Read the panel, do what it says.
  //
  // This runs solo, with a phone joined to the same call as the second
  // participant. That is not a convenience. A call with one person in it has no
  // inbound audio at all, so getContributingSources has nothing to return and
  // the main question about Meet stays unanswered. The phone is what makes a
  // real remote participant exist, with a real CSRC and a real tile.
  //
  // Laptop mic stays muted except where the panel says otherwise, and the phone
  // wants headphones, or the two ends will howl at each other.
  //
  // The phases matter in this order. Silence first, to establish a floor. Long
  // single turns, to measure how fast each signal rises and how long it takes to
  // release. Short alternating turns, to catch a handover. Overlap last, because
  // it is the case every one of these signals is worst at.

  const SCRIPT = [
    ['SILENCE', 6],
    ['TALK into the PHONE', 12],
    ['SILENCE', 12],
    ['TALK into the LAPTOP', 12],
    ['SILENCE', 12],
    ['PHONE', 4],
    ['LAPTOP', 4],
    ['PHONE', 4],
    ['LAPTOP', 4],
    ['TALK into LAPTOP, play a video at the PHONE', 8],
    ['SILENCE', 12],
    ['DONE, hit Save', 0],
  ];

  const ui = document.createElement('div');
  ui.style.cssText = [
    'position:fixed', 'z-index:2147483647', 'top:12px', 'left:50%',
    'transform:translateX(-50%)', 'background:#111', 'color:#fff',
    'font:600 15px/1.35 system-ui,sans-serif', 'padding:14px 18px',
    'border-radius:12px', 'box-shadow:0 6px 28px rgba(0,0,0,.5)',
    'text-align:center', 'min-width:320px', 'user-select:none',
  ].join(';');
  const line = document.createElement('div');
  line.style.cssText = 'font-size:26px;letter-spacing:.3px;margin-bottom:8px';
  line.textContent = 'Pipit probe ready';
  const sub = document.createElement('div');
  sub.style.cssText = 'font-size:12px;opacity:.65;margin-bottom:10px';
  sub.textContent = 'Join the call first, then press Start';
  const row = document.createElement('div');
  row.style.cssText = 'display:flex;gap:8px;justify-content:center';
  ui.append(line, sub, row);

  function button(label, onClick) {
    const b = document.createElement('button');
    b.textContent = label;
    b.style.cssText = [
      'font:600 13px system-ui,sans-serif', 'padding:7px 14px', 'border:0',
      'border-radius:8px', 'background:#333', 'color:#fff', 'cursor:pointer',
    ].join(';');
    b.onclick = (event) => { event.stopPropagation(); onClick(); };
    row.appendChild(b);
    return b;
  }

  let step = -1;
  function advance() {
    step += 1;
    if (step >= SCRIPT.length) return;
    const [label, seconds] = SCRIPT[step];
    P.mark(label);
    line.textContent = label;
    line.style.color = label.startsWith('SILENCE') ? '#8fa'
      : label.startsWith('DONE') ? '#8cf' : '#fd6';
    if (!seconds) { sub.textContent = 'Recording stopped advancing'; return; }
    let left = seconds;
    sub.textContent = `${left}s`;
    clearInterval(P.countTimer);
    P.countTimer = setInterval(() => {
      left -= 1;
      sub.textContent = `${left}s`;
      if (left <= 0) clearInterval(P.countTimer);
    }, 1000);
    P.phaseTimer = setTimeout(advance, seconds * 1000);
  }

  P.start = async () => {
    // A click is what lets the audio context leave its suspended state.
    try { await P.ctx?.resume(); } catch {}
    await P.tapMic();
    advance();
  };

  const startButton = button('Start', () => { startButton.remove(); P.start(); });
  button('Mark', () => P.mark('manual'));
  button('Report', () => P.report());
  button('Save', () => P.save());
  document.body.appendChild(ui);
  P.ui = ui;

  console.log('[pipit] probe installed. Join the call, then press Start on the panel.');
  return P;
})();
