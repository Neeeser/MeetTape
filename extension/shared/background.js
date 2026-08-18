// Relays content-script observations to the native host, and counts audible tabs.

const api = globalThis.browser ?? globalThis.chrome;
const HOST_NAME = 'com.meettape.sensor';

let port = null;

function connect() {
  if (port) return port;
  try {
    port = api.runtime.connectNative(HOST_NAME);
    port.onDisconnect.addListener(() => {
      port = null;
    });
    port.onMessage.addListener(() => {
      // The host acknowledges; nothing here depends on the reply.
    });
    port.postMessage({
      type: 'hello',
      extensionVersion: api.runtime.getManifest().version,
      sentAt: Date.now(),
    });
  } catch {
    port = null;
  }
  return port;
}

function post(message) {
  const active = connect();
  if (!active) return;
  try {
    active.postMessage(message);
  } catch {
    port = null;
  }
}

// Firefox routes every tab through one CoreAudio object, so meeting audio cannot
// be separated from a video playing in another tab. The count is reported so the
// app can say so; it never blocks or delays recording.
async function countOtherAudibleTabs(senderTabId) {
  try {
    const tabs = await api.tabs.query({ audible: true });
    return tabs.filter((tab) => tab.id !== senderTabId).length;
  } catch {
    return undefined;
  }
}

api.runtime.onMessage.addListener(async (message, sender) => {
  // Only this extension's own content scripts, running in a tab.
  if (!sender || sender.id !== api.runtime.id || !sender.tab) return;
  if (!message || message.type !== 'state') return;
  const tabId = sender.tab ? sender.tab.id : null;
  const otherAudibleTabs = await countOtherAudibleTabs(tabId);
  post({ ...message, tabId, otherAudibleTabs, sentAt: Date.now() });
});

api.tabs.onRemoved.addListener((tabId) => {
  post({ type: 'tab_removed', tabId, sentAt: Date.now() });
});

// Content scripts do not appear in tabs that were already open when the
// extension loaded, so they are injected explicitly at startup.
async function injectIntoOpenTabs() {
  try {
    const tabs = await api.tabs.query({ url: ['*://meet.google.com/*', '*://*.zoom.us/*'] });
    for (const tab of tabs) {
      try {
        await api.scripting.executeScript({
          target: { tabId: tab.id },
          // Order matters: provider.js defines what content.js calls.
          files: ['shared/provider.js', 'shared/content.js'],
          injectImmediately: true,
        });
      } catch {
        // A tab that refuses injection simply reports nothing.
      }
    }
  } catch {
    // scripting is unavailable; new tabs still work.
  }
}

// The native host is connected lazily on the first meeting-shaped observation,
// rather than spawned at browser start whether or not one ever happens.
injectIntoOpenTabs();
