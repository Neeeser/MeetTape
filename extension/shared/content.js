// Pipit browser sensor: observes meeting lifecycle and reports it.
//
// It records nothing, calls no service, and owns no meeting state. If it stops
// working the app falls back to native detection and keeps recording.

// provider.js is loaded as a separate content script and shares this scope, so
// its functions are already defined here. Content scripts cannot be ES modules:
// an `import` statement makes the whole script fail to load, silently.

const api = globalThis.browser ?? globalThis.chrome;
const POLL_MS = 500;

function readControls() {
  const nodes = document.querySelectorAll('button,[role="button"]');
  const controls = [];
  for (const node of nodes) {
    controls.push({
      ariaLabel: node.getAttribute('aria-label'),
      tooltip: node.getAttribute('data-tooltip'),
      text: (node.textContent || '').slice(0, 80),
      ariaPressed: node.getAttribute('aria-pressed'),
    });
    if (controls.length >= 200) break;
  }
  return controls;
}

// The documents a provider's UI lives in. Zoom renders its whole client inside
// a same-origin iframe, so the top document alone shows nothing but chrome.
function readDocuments() {
  const documents = [document];
  for (const frame of document.querySelectorAll('iframe')) {
    try {
      // Reading through a frame that is being torn down throws, and an
      // exception here would abort the whole tick, so the tab would report no
      // lifecycle state at all rather than a slightly stale roster.
      const doc = frame.contentDocument;
      if (doc && typeof doc.querySelectorAll === 'function') documents.push(doc);
    } catch {
      // Cross-origin. Nothing to read and nothing to report.
    }
  }
  return documents;
}

// One raw tile per participant element the page renders.
//
// Meet names participants in its own resource format and animates a level meter
// inside each tile while that person is audible. The meter's class names are
// obfuscated and rotate, so what gets reported is the class string itself and
// the tracker decides who is talking from whether it keeps changing.
// Names settle once and rarely change, and reading them is the expensive part:
// innerText forces a layout flush, so reading it per tile per 500 ms tick is a
// stream of reflows on the page being recorded. Read once per participant and
// keep it.
const meetNames = new Map();

function readMeetTiles() {
  // Meet marks the local user's own tile, and finding it matters more than it
  // looks. The far-end track is a mixdown of everyone else, so a turn saying the
  // local user held the floor cannot explain a voice heard there. Without this
  // flag their turns compete for remote clusters and put their own name on
  // whoever they talked over.
  // The top document alone, unlike Zoom: Meet renders its client in the page
  // rather than in an iframe, so walking frames here would cost a scan per tick
  // and find nothing.
  const tiles = [];
  for (const node of document.querySelectorAll('[data-participant-id]')) {
    const id = node.getAttribute('data-participant-id');
    if (!id) continue;
    // Only a name that survived the chrome cut is cached, so a row read while
    // the panel was open cannot pin a control's text as somebody's name for
    // the rest of the call.
    let name = meetNames.get(id);
    if (!name) {
      name = meetTileName(node.innerText);
      if (name) meetNames.set(id, name);
    }
    // The meter element, by the name Meet currently gives it. When that
    // rotates, the fallback is every class below the tile in one string: the
    // meter's own churn is in there, and the tracker only asks whether the
    // string keeps changing. A menu opening inside the tile also changes it,
    // which costs at most a false blip bounded by the tracker's hold.
    const meter = node.querySelector('[jsname="QgSmzd"]');
    let meterString;
    if (meter) {
      // getAttribute, not className: on an SVG element className is an
      // SVGAnimatedString whose toString is a constant, which would make the
      // meter look permanently still and kill speaking detection silently.
      meterString = meter.getAttribute('class') || '';
    } else {
      const parts = [];
      for (const el of node.querySelectorAll('[class]')) {
        parts.push(el.getAttribute('class'));
      }
      meterString = parts.join('|');
    }
    tiles.push({
      id,
      name: name || undefined,
      // Whether this string is a level meter or the subtree's own churn. A
      // people-panel row has no meter, and the tracker uses this to keep
      // layout from reading as audio while a real meter is available.
      hasMeter: !!meter,
      // Meet writes "You" as the local user's own tile name in English, and a
      // probed live call showed the self tile can render no name at all. A
      // hint, never the only mechanism: the app marks the local user by
      // configured name as well, and nothing structural marks the self tile
      // (the one candidate attribute measured `true` on every tile).
      isSelf: /^you$/i.test(name || ''),
      meter: meterString,
    });
  }
  return tiles;
}

function readZoomTiles() {
  // Zoom gives less than the other two, and the reason is architectural. It
  // decodes in WebAssembly and paints video into a canvas, so there is no
  // per-person audio and no speaking indicator anywhere in the DOM: probed
  // live, the active-speaker highlight is painted pixels. What the client does
  // render, while the participants panel is open, is a row per person with
  // everything in the accessible label: name, role, a trailing `me` on the
  // local user's own row, and the mute switch's state.
  //
  // No identifier exists to key on. The measured build's row ids are list
  // positions, and nothing in the document carries a participant id, so rows
  // are keyed on the display name, marked as such by the `zoom-name:` prefix.
  // Two people sharing a name merge into one roster entry, which is tolerable
  // for what this feeds: Zoom emits no speaking signal, so no turns are ever
  // built from it and no name is ever placed on a voice. The roster is a
  // record of who was in the room, and the mute transitions are evidence.
  const tiles = [];
  for (const doc of readDocuments()) {
    // Older builds keyed rows on a real identifier; keep that path first for
    // wherever it still exists. Scoped to the participants panel, because
    // `data-user-id` alone also matches chat rows and reaction senders.
    const containers = doc.querySelectorAll(
      '[class*="participants-"],[aria-label*="articipants"]'
    );
    for (const panel of containers) {
      for (const node of panel.querySelectorAll('[data-participant-id],[data-user-id]')) {
        const id = node.getAttribute('data-participant-id') || node.getAttribute('data-user-id');
        if (!id) continue;
        const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
        tiles.push({
          id: `zoom:${id}`,
          name: label.split(',')[0].split('\n')[0].trim().slice(0, 80) || undefined,
          muted: /\bmuted\b/i.test(label) ? true : undefined,
        });
      }
    }
    if (tiles.length) continue;
    // The current build: one `.participants-li` per person, label-only.
    for (const row of doc.querySelectorAll('.participants-li[aria-label]')) {
      const person = zoomParticipantFromLabel(row.getAttribute('aria-label'));
      if (!person) continue;
      tiles.push({
        id: `zoom-name:${person.name.toLowerCase()}`,
        name: person.name,
        isSelf: person.isSelf,
        muted: person.muted,
      });
    }
  }
  return tiles;
}

function readTiles(provider) {
  // A page the extension does not control can throw from any of this. A tick
  // that reports no roster is a meeting named by voice alone; a tick that throws
  // reports no lifecycle either, and the app stops trusting the sensor.
  try {
    if (provider === 'meet') return readMeetTiles();
    if (provider === 'zoom') return readZoomTiles();
  } catch {
    return [];
  }
  return [];
}

function readPageText() {
  return (document.body && document.body.innerText) ? document.body.innerText.slice(0, 4000) : '';
}

let previous = null;
let lastSentAt = 0;
const speaking = createSpeakingTracker();

function tick() {
  const provider = providerForURL(location.href);
  if (provider === 'unknown') return;
  const now = Date.now();
  const tiles = readTiles(provider);
  const snapshot = buildState({
    href: location.href,
    title: document.title,
    controls: readControls(),
    pageText: readPageText(),
    tabId: null,
    now,
    people: tiles,
    activeSpeaker: speaking.update(tiles, now),
  });
  if (!shouldSend(previous, snapshot, lastSentAt, snapshot.sentAt)) return;
  previous = snapshot;
  lastSentAt = snapshot.sentAt;
  try {
    api.runtime.sendMessage(snapshot);
  } catch {
    // The background page is asleep or reloading; the next tick retries.
  }
}

setInterval(tick, POLL_MS);
new MutationObserver(() => tick()).observe(document.documentElement, {
  subtree: true,
  childList: true,
  attributes: true,
  attributeFilter: ['aria-label', 'aria-pressed', 'data-tooltip'],
});
tick();

window.addEventListener('pagehide', () => {
  try {
    api.runtime.sendMessage({ ...(previous || {}), type: 'state', state: 'ended', sentAt: Date.now() });
  } catch {
    // Nothing to do: the app treats a silent sensor as absent.
  }
});
