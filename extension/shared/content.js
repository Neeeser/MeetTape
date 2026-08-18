// MeetTape browser sensor: observes meeting lifecycle and reports it.
//
// It records nothing, calls no service, and owns no meeting state. If it stops
// working the app falls back to native detection and keeps recording.

import {
  buildState,
  isMeaningfulChange,
  providerForURL,
} from './provider.js';

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

function readPageText() {
  return (document.body && document.body.innerText) ? document.body.innerText.slice(0, 4000) : '';
}

let previous = null;

function tick() {
  if (providerForURL(location.href) === 'unknown') return;
  const snapshot = buildState({
    href: location.href,
    title: document.title,
    controls: readControls(),
    pageText: readPageText(),
    tabId: null,
    now: Date.now(),
  });
  if (!isMeaningfulChange(previous, snapshot)) return;
  previous = snapshot;
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
