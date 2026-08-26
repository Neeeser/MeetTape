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

/// Collapses raw tiles into one entry per person.
///
/// A tile with no identifier is dropped rather than given a placeholder. The
/// identifier is what ties a person to a voice downstream, so inventing one puts
/// a name on somebody else's words, which is worse than leaving the cluster
/// blank for a human to fill in.
///
/// The same person appears more than once, in the grid and again in the people
/// panel, and a name can render a beat after the tile does. So entries merge and
/// a real name always beats a missing one.
export function rosterFromTiles(tiles) {
  const byID = new Map();
  for (const tile of tiles || []) {
    const id = tile && typeof tile.id === 'string' ? tile.id.trim() : '';
    if (!id) continue;
    const name = tile.name ? String(tile.name).trim().slice(0, 80) : '';
    const existing = byID.get(id);
    if (existing) {
      if (!existing.name && name) existing.name = name;
      if (tile.isSelf) existing.isSelf = true;
      if (typeof tile.muted === 'boolean') existing.muted = tile.muted;
      continue;
    }
    byID.set(id, {
      id: id.slice(0, 200),
      name: name || undefined,
      isSelf: !!tile.isSelf,
      muted: typeof tile.muted === 'boolean' ? tile.muted : undefined,
    });
  }
  return [...byID.values()].slice(0, 50);
}

/// Decides who holds the floor from a per-participant level meter.
///
/// Meet animates a meter inside each participant's tile while that person is
/// audible and lets it settle when they stop, measured at about 50 ms from the
/// start of speech. Reading the animation rather than a class name is the point:
/// the class names are obfuscated and rotate, but a meter that keeps changing is
/// a meter with audio behind it whatever its classes are called.
///
/// The hold has to outlast the gap between reads, or it does nothing at all.
/// Reads are 500 ms apart, so a 400 ms hold expired before the next one could
/// ever renew it: every turn collapsed to a single read, no turn reached the six
/// seconds that make somebody a speaker, and Meet named nobody. It also has to
/// outlast a natural pause inside a sentence, which is the same order as Slack's
/// own release of about 1.5 s.
export function createSpeakingTracker({ holdMs = 1_500 } = {}) {
  const lastMeter = new Map();
  const lastChange = new Map();
  return {
    update(tiles, now) {
      for (const tile of tiles || []) {
        if (!tile || !tile.id) continue;
        const meter = String(tile.meter ?? '');
        if (lastMeter.has(tile.id) && lastMeter.get(tile.id) !== meter) {
          lastChange.set(tile.id, now);
        }
        lastMeter.set(tile.id, meter);
      }
      let floor = null;
      let mostRecent = -Infinity;
      for (const [id, at] of lastChange) {
        if (now - at > holdMs) continue;
        if (at > mostRecent) { mostRecent = at; floor = id; }
      }
      return floor;
    },
  };
}

/// Reads one participants-panel row out of Zoom's accessible label.
///
/// Measured on the web client (PWA 7.1.0), a row reads
/// `Andrew Neeser (Host, me),computer audio muted,video off`. The label is the
/// whole surface: the row's DOM id is a list position, and no element in the
/// document carries a participant identifier. The parenthesised role list ends
/// in `me` on the local user's own row, and the audio clause tracks the mute
/// switch, nothing else: the active-speaker highlight is painted into canvas,
/// so Zoom has no speaking signal to read.
export function zoomParticipantFromLabel(label) {
  const text = String(label || '').trim();
  if (!text) return null;
  const audio = text.match(/computer audio (muted|unmuted)/i);
  let namePart = audio ? text.slice(0, text.search(/,\s*computer audio/i)) : text;
  namePart = namePart.trim();
  if (!namePart) return null;
  let isSelf = false;
  const roles = namePart.match(/\(([^)]*)\)\s*$/);
  if (roles) {
    isSelf = roles[1].split(',').some((role) => role.trim().toLowerCase() === 'me');
    namePart = namePart.slice(0, roles.index).trim();
  }
  if (!namePart) return null;
  return {
    name: namePart.slice(0, 80),
    isSelf,
    muted: audio ? audio[1].toLowerCase() === 'muted' : undefined,
  };
}

/// Builds the message the native host relays to Pipit.
export function buildState({
  href, title, controls, pageText, tabId, now, participants, people, activeSpeaker,
}) {
  const roster = people && people.length ? rosterFromTiles(people) : null;
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
    // Absent rather than empty when the page said nothing. An empty roster is a
    // claim that the room is empty, which the app would then act on.
    people: roster && roster.length ? roster : undefined,
    activeSpeaker: activeSpeaker || undefined,
    tabId,
    sentAt: now,
  };
}

/// True when two snapshots differ in a way Pipit cares about. Suppresses the
/// chatter a 500 ms poll would otherwise produce.
export function isMeaningfulChange(previous, next) {
  if (!previous) return true;
  const keys = [
    'provider', 'state', 'meetingId', 'url', 'title', 'muted', 'otherAudibleTabs',
    // The floor moving is the whole point of the roster, and a 4 s heartbeat
    // would round a short turn away entirely.
    'activeSpeaker',
  ];
  if (keys.some((key) => previous[key] !== next[key])) return true;
  return (previous.people || []).length !== (next.people || []).length;
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
