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
function readMeetTiles() {
  // Meet marks the local user's own tile, and finding it matters more than it
  // looks. The far-end track is a mixdown of everyone else, so a turn saying the
  // local user held the floor cannot explain a voice heard there. Without this
  // flag their turns compete for remote clusters and put their own name on
  // whoever they talked over.
  const selfID = readMeetSelfID();
  const tiles = [];
  for (const node of document.querySelectorAll('[data-participant-id]')) {
    const id = node.getAttribute('data-participant-id');
    if (!id) continue;
    const meter = node.querySelector('[jsname="QgSmzd"]');
    tiles.push({
      id,
      name: (node.innerText || '').trim().split('\n')[0] || undefined,
      isSelf: !!selfID && id === selfID,
      // getAttribute, not className: on an SVG element className is an
      // SVGAnimatedString whose toString is a constant, which would make the
      // meter look permanently still and kill speaking detection silently.
      meter: meter ? (meter.getAttribute('class') || '') : undefined,
    });
  }
  return tiles;
}

// The local user's participant id, from the tile Meet labels as theirs.
//
// Meet writes "You" into the local tile's own name. Nothing here falls back to
// a guess: an unknown self is reported as unknown, and the app then keeps the
// local user out of naming by other means rather than picking the wrong tile.
function readMeetSelfID() {
  for (const node of document.querySelectorAll('[data-participant-id]')) {
    const id = node.getAttribute('data-participant-id');
    if (!id) continue;
    const label = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
    if (/\byou\b/i.test(label)) return id;
  }
  return null;
}

// Zoom's roster, when it is on screen at all.
//
// The client decodes in WebAssembly and paints video into a canvas, so there is
// no per-participant element to read while the participants panel is closed, and
// no speaking indicator was found in the DOM at all. This reports names when the
// panel is open and nothing when it is not, which is the honest shape of what
// Zoom offers.
function readZoomTiles() {
  // Zoom gives less than the other two, and the reason is architectural. It
  // decodes in WebAssembly and paints video into a canvas, so a 98 second
  // two-person probe found no participant element, no roster and no speaking
  // indicator anywhere in the DOM. What it does render, while the participants
  // panel is open, is a row per person.
  //
  // Only a real identifier is accepted. Zoom's accessible label mixes the name
  // with role and mute state, so it changes when someone mutes; keying a person
  // on it produced several entries for one person across a call and merged two
  // people who share a display name. An identifier is what ties a person to a
  // voice, so a synthesised one is worse than none.
  const tiles = [];
  for (const doc of readDocuments()) {
    for (const node of doc.querySelectorAll('[data-participant-id],[data-user-id]')) {
      const id = node.getAttribute('data-participant-id') || node.getAttribute('data-user-id');
      if (!id) continue;
      const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
      tiles.push({
        id: `zoom:${id}`,
        // The label carries state as well as the name, so only the part before
        // the first comma is treated as the name.
        name: label.split(',')[0].split('\n')[0].trim().slice(0, 80) || undefined,
        muted: /\bmuted\b/i.test(label) ? true : undefined,
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
