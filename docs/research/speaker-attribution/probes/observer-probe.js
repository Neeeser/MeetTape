// Compact probe for the observing side of a two-endpoint test.
//
// The full browser-probe.js carries a prompter and a microphone tap because a
// person is running it during their own call. This one is driven by an agent
// with JavaScript access, so it drops both and keeps only what the observer
// needs: the CSRC stream, the DOM changes, and the far-end envelope.
//
// Inject after the prejoin screen loads and before pressing join.

(() => {
  if (window.__p) return 'already installed';
  const P = { t0: performance.now(), pcs: new Set(), rtc: [], attrs: new Map(), env: [], seen: new Set() };
  window.__p = P;
  const now = () => Math.round(performance.now() - P.t0);

  const Native = window.RTCPeerConnection;
  let seq = 0;
  const Patched = function (...a) {
    const pc = new Native(...a);
    pc.__id = ++seq;
    P.pcs.add(pc);
    return pc;
  };
  Patched.prototype = Native.prototype;
  Object.getOwnPropertyNames(Native)
    .filter((k) => !['length', 'name', 'prototype'].includes(k))
    .forEach((k) => { try { Patched[k] = Native[k]; } catch {} });
  window.RTCPeerConnection = Patched;

  P.rtcTimer = setInterval(() => {
    for (const pc of P.pcs) {
      let receivers = [];
      try { receivers = pc.getReceivers(); } catch { continue; }
      for (const r of receivers) {
        if (r.track?.kind !== 'audio') continue;
        const rows = [];
        try { (r.getContributingSources?.() || []).forEach((s) => rows.push(['csrc', s])); } catch {}
        try { (r.getSynchronizationSources?.() || []).forEach((s) => rows.push(['ssrc', s])); } catch {}
        for (const [kind, s] of rows) {
          const key = `${pc.__id}:${kind}:${s.source}:${s.timestamp}`;
          if (P.seen.has(key)) continue;
          P.seen.add(key);
          P.rtc.push({ t: now(), pc: pc.__id, kind, csrc: s.source, level: s.audioLevel ?? null, voice: s.voiceActivityFlag ?? null });
        }
      }
      // The far-end envelope, so a CSRC level can be checked against the audio
      // that actually arrived rather than against a claim about it.
      if (!pc.__tapped) {
        const track = receivers.find((r) => r.track?.kind === 'audio')?.track;
        if (track) {
          try {
            P.ctx = P.ctx || new AudioContext();
            const node = P.ctx.createAnalyser();
            node.fftSize = 512;
            P.ctx.createMediaStreamSource(new MediaStream([track])).connect(node);
            P.tap = { node, buf: new Float32Array(node.fftSize) };
            pc.__tapped = true;
          } catch {}
        }
      }
    }
    if (P.tap) {
      P.tap.node.getFloatTimeDomainData(P.tap.buf);
      let sum = 0;
      for (let i = 0; i < P.tap.buf.length; i += 1) sum += P.tap.buf[i] * P.tap.buf[i];
      P.env.push({ t: now(), rms: Math.sqrt(sum / P.tap.buf.length) });
    }
    if (P.seen.size > 200000) P.seen.clear();
  }, 100);

  function sig(el) {
    if (!el?.tagName) return '?';
    const parts = [el.tagName.toLowerCase()];
    for (const a of ['role', 'jsname', 'data-participant-id']) {
      const v = el.getAttribute?.(a);
      if (v) parts.push(`${a}=${v}`);
    }
    return parts.join(' ');
  }
  function near(el) {
    let n = el;
    for (let i = 0; i < 6 && n; i += 1) {
      const l = n.getAttribute?.('aria-label') || n.getAttribute?.('data-participant-id');
      if (l) return String(l).slice(0, 70);
      n = n.parentElement;
    }
    return null;
  }
  // Methods are attached before the observer is wired up. Running at
  // document_start means there may be no documentElement yet, and an exception
  // there would leave the probe installed but half-built.
  P.mark = (label) => P.rtc.push({ t: now(), mark: label });
  P.sources = () => {
    const m = new Map();
    for (const r of P.rtc) {
      if (!r.csrc) continue;
      const k = `${r.kind}:${r.csrc}`;
      const e = m.get(k) || { k, n: 0, loud: 0, max: 0, first: r.t, last: r.t };
      e.n += 1;
      if ((r.level ?? 0) > 0.02) e.loud += 1;
      e.max = Math.max(e.max, r.level ?? 0);
      e.last = r.t;
      m.set(k, e);
    }
    return [...m.values()];
  };
  P.top = (n = 25) => [...P.attrs.entries()]
    .map(([k, e]) => ({ k, count: e.count, to: e.samples[0]?.to, near: e.samples[0]?.near }))
    .sort((a, b) => b.count - a.count).slice(0, n);

  P.obs = new MutationObserver((records) => {
    for (const rec of records) {
      if (rec.type !== 'attributes') continue;
      const key = `${sig(rec.target)} @${rec.attributeName}`;
      let e = P.attrs.get(key);
      if (!e) { e = { count: 0, samples: [] }; P.attrs.set(key, e); }
      e.count += 1;
      if (e.samples.length < 60) {
        e.samples.push({
          t: now(),
          from: (rec.oldValue || '').slice(0, 70),
          to: (rec.target.getAttribute?.(rec.attributeName) || '').slice(0, 70),
          near: near(rec.target),
        });
      }
    }
  });
  const startObserving = () => {
    if (!document.documentElement) return false;
    P.obs.observe(document.documentElement,
      { subtree: true, attributes: true, attributeOldValue: true });
    return true;
  };
  if (!startObserving()) {
    document.addEventListener('DOMContentLoaded', startObserving, { once: true });
  }

  return 'installed';
})();
