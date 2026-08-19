// Provider observation, kept free of DOM access so it can be tested directly.
//
// Everything here reads semantic signals: the URL shape and accessibility labels.
// No CSS class names, because providers change those constantly and a class-based
// selector breaks silently.

const MEET_HOST = 'meet.google.com';

export function providerForURL(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return 'unknown';
  }
  // Suffix checks need the dot boundary: `notmeet.google.com` is not Meet.
  const host = url.hostname.toLowerCase();
  const matches = (suffix) => host === suffix || host.endsWith(`.${suffix}`);
  if (matches(MEET_HOST)) return 'meet';
  if (matches('zoom.us') || matches('zoomgov.com')) return 'zoom';
  return 'unknown';
}

export function meetingIdForURL(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  const provider = providerForURL(href);
  if (provider === 'meet') {
    const match = url.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})/i);
    return match ? match[1].toLowerCase() : null;
  }
  if (provider === 'zoom') {
    const match = url.pathname.match(/\/(?:j|wc|s)(?:\/join)?\/(\d{9,})/) ||
      url.pathname.match(/(\d{9,})/);
    return match ? match[1] : null;
  }
  return null;
}

// A control is described by the text a screen reader would announce for it.
const LEAVE_PATTERN = /leave call|end call|leave meeting|hang up|leave the meeting/;
const JOIN_PATTERN = /join now|ask to join|join meeting|join audio|switch here/;
const WAITING_PATTERN = /waiting for the host|asking to be let in|please wait|waiting room/;
const MUTE_ON_PATTERN = /turn on microphone|unmute/;
const MUTE_OFF_PATTERN = /turn off microphone|^mute/;

export function labelFor(control) {
  return [control.ariaLabel, control.tooltip, control.text]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
    .slice(0, 120);
}

/// Derives lifecycle state from the controls a page is currently showing.
///
/// The presence of a leave control is the discriminator between a prejoin screen
/// and an active call. Nothing native can tell those apart: four minutes spanning
/// prejoin, join and leave produced no observable system change at all.
export function stateFromControls(controls, pageText = '') {
  const labels = controls.map(labelFor);
  if (labels.some((label) => LEAVE_PATTERN.test(label))) return 'in_call';
  if (WAITING_PATTERN.test(pageText.toLowerCase().slice(0, 4000))) return 'waiting';
  if (labels.some((label) => JOIN_PATTERN.test(label))) return 'prejoin';
  return 'browsing';
}

export function mutedFromControls(controls) {
  for (const control of controls) {
    const label = labelFor(control);
    if (!/microphone|mute/.test(label)) continue;
    if (MUTE_ON_PATTERN.test(label)) return true;
    if (MUTE_OFF_PATTERN.test(label)) return false;
    if (control.ariaPressed === 'true') return true;
    if (control.ariaPressed === 'false') return false;
  }
  return null;
}

// A meeting URL can carry a passcode in its fragment, and a page controls its own
// title, so both are trimmed before anything is relayed or written to disk.
function scrubURL(href) {
  try {
    const url = new URL(href);
    return `${url.origin}${url.pathname}`.slice(0, 512);
  } catch {
    return null;
  }
}

/// Builds the message the native host relays to MeetTape.
export function buildState({ href, title, controls, pageText, tabId, now, participants }) {
  return {
    type: 'state',
    provider: providerForURL(href),
    state: stateFromControls(controls, pageText),
    meetingId: (meetingIdForURL(href) || '').slice(0, 64) || null,
    url: scrubURL(href),
    title: title ? String(title).slice(0, 200) : null,
    muted: mutedFromControls(controls),
    participants: participants && participants.length
      ? participants.slice(0, 30).map((name) => String(name).slice(0, 80))
      : undefined,
    tabId,
    sentAt: now,
  };
}

/// True when two snapshots differ in a way MeetTape cares about. Suppresses the
/// chatter a 500 ms poll would otherwise produce.
export function isMeaningfulChange(previous, next) {
  if (!previous) return true;
  const keys = ['provider', 'state', 'meetingId', 'url', 'title', 'muted', 'otherAudibleTabs'];
  return keys.some((key) => previous[key] !== next[key]);
}

/// How long a tab may stay silent before the app stops counting it as reporting.
/// The app drops an entry after 10 s, so this leaves room for a missed message.
export const HEARTBEAT_MS = 4000;

/// True when the snapshot should be sent: either it changed, or the last message
/// is old enough that the app would otherwise consider this tab silent. A call
/// that sits in one state for an hour still reports throughout it.
export function shouldSend(previous, next, lastSentAt, now) {
  if (isMeaningfulChange(previous, next)) return true;
  return !lastSentAt || now - lastSentAt >= HEARTBEAT_MS;
}
