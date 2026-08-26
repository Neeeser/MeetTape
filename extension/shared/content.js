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
      if (frame.contentDocument) documents.push(frame.contentDocument);
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
  const tiles = [];
  for (const node of document.querySelectorAll('[data-participant-id]')) {
    const id = node.getAttribute('data-participant-id');
    if (!id) continue;
    const meter = node.querySelector('[jsname="QgSmzd"]');
    tiles.push({
      id,
      name: (node.innerText || '').trim().split('\n')[0] || undefined,
      meter: meter ? (meter.className || '').toString() : undefined,
    });
  }
  return tiles;
}

// Zoom's roster, when it is on screen at all.
//
// The client decodes in WebAssembly and paints video into a canvas, so there is
// no per-participant element to read while the participants panel is closed, and
// no speaking indicator was found in the DOM at all. This reports names when the
// panel is open and nothing when it is not, which is the honest shape of what
// Zoom offers.
function readZoomTiles() {
  const tiles = [];
  for (const doc of readDocuments()) {
    for (const node of doc.querySelectorAll('[class*="participants-item"]')) {
      const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
      if (!label) continue;
      const name = label.split('\n')[0].slice(0, 80);
      if (!name) continue;
      tiles.push({
        id: `zoom:${name}`,
        name,
        muted: /(^|[^n])muted/i.test(label) ? true : undefined,
      });
    }
  }
  return tiles;
}

function readTiles(provider) {
  if (provider === 'meet') return readMeetTiles();
  if (provider === 'zoom') return readZoomTiles();
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
