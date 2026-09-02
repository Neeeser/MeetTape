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

// Text Meet renders inside a participant row that is a control rather than a
// person. A people-panel row concatenates all of it onto the name with no
// separator, so the name is whatever comes before the first of these.
const MEET_TILE_CHROME = [
  'Meeting host', 'More actions', 'More options', 'Remove from meeting',
  'Deny entry', 'Admit', 'Visitor', 'Presenting', 'is presenting',
  'Pin to screen', "You can't remotely mute", 'Mute for everyone',
];
// Material icon ligatures render as their own text inside the row, glued onto
// the name with no separator. Matched as whole known tokens rather than by
// pattern: a pattern for "a lowercase run containing an underscore" starts at
// the run, and the run begins inside the name, so `Chris Latimermore_vert` cut
// back to `Chris L`. A ligature this list does not know leaves the name
// uncut, which is the safe direction.
const MEET_TILE_LIGATURE = [
  'domain_disabled', 'more_vert', 'more_horiz', 'push_pin', 'present_to_all',
  'mic_off', 'mic_none', 'videocam_off', 'devices', 'volume_up',
  'do_not_disturb_on', 'visibility_off',
];

/// The person's name out of a Meet participant row.
///
/// Grid tiles put the name on its own line, so the first line is the answer and
/// always was. Panel rows do not: measured on a real call, one read
/// `Chris LatimerMeeting hostdevicesYou can't remotely mute Chris Latimer's
/// microphone` on a single line, and taking that line whole put the entire run
/// into the roster, truncated mid-word at the 80-character cap. The roster is
/// what names a voice, so that string became a speaker's name.
///
/// Both rows are read on purpose. A name can render in the panel a beat before
/// the grid tile has one, and `rosterFromTiles` merges them, so dropping panel
/// rows would lose names rather than fix them.
///
/// Undefined rather than a placeholder where nothing survives the cut. An
/// unnamed sensor key renders through the fallback and waits for a person; a
/// wrong one does not ask to be corrected.
export function meetTileName(raw) {
  // Trimmed before the split, not after. A tile whose text opens with a blank
  // line would otherwise yield the empty first line and no name at all, and
  // because only a name that survives is cached, that tile would be re-read
  // with innerText on every tick forever.
  const line = String(raw ?? '').trim().split('\n')[0];
  if (!line.trim()) return undefined;
  let cut = line.length;
  for (const marker of [...MEET_TILE_CHROME, ...MEET_TILE_LIGATURE]) {
    const at = line.indexOf(marker);
    if (at >= 0 && at < cut) cut = at;
  }
  // A cut lands mid-phrase often enough that the punctuation leading into it
  // survives: "Bob (Presenting)" would otherwise read "Bob (".
  const name = line.slice(0, cut).replace(/[\s(\[{,\-\u2013\u2014]+$/, '').trim();
  return name ? name.slice(0, 80) : undefined;
}

/// One entry per participant, from the several nodes Meet renders for each.
///
/// The grid tile and the people-panel row carry the same
/// `data-participant-id`, which `rosterFromTiles` relies on to merge a name
/// that reached one before the other. The floor cannot be decided from them
/// unmerged: two entries under one id write that id's meter twice per tick with
/// two different strings, so every participant registers a change on every
/// tick whether or not anyone is speaking, and the floor goes to whichever id
/// was seen first for the rest of the call. That is the 863-second turn.
///
/// The metered node wins the meter, because a panel row has none and its churn
/// is layout.
export function collapseMeetTiles(tiles) {
  const byID = new Map();
  for (const tile of tiles || []) {
    if (!tile || !tile.id) continue;
    const existing = byID.get(tile.id);
    if (!existing) {
      byID.set(tile.id, { ...tile });
      continue;
    }
    if (!existing.name && tile.name) existing.name = tile.name;
    if (tile.isSelf) existing.isSelf = true;
    if (typeof tile.muted === 'boolean') existing.muted = tile.muted;
    if (tile.hasMeter && !existing.hasMeter) {
      existing.hasMeter = true;
      existing.meter = tile.meter;
    }
  }
  return [...byID.values()];
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
/// Two rules keep a moving string from being read as a voice.
///
/// Only a tile carrying a real meter can hold the floor, and only while some
/// tile does. A people-panel row has no meter, so what changes under it is
/// layout; without this it competed for the floor on equal terms. When no tile
/// anywhere has one the meter element has been renamed, and every tile falls
/// back to its class string exactly as before.
///
/// And a tie among those candidates names nobody. The comparison used to be
/// `at > mostRecent`, which is strict, so tiles that changed in the same tick
/// were settled by which was seen first. With every tile falling back to its
/// whole class string that was every tick, and one participant held the floor
/// for fourteen straight minutes. A tick where they all moved says nothing
/// about who is talking, and saying nothing is the honest answer.
///
/// The tie rule is scoped to candidates for the same reason the fallback
/// exists. Applied when no tile has a meter it would return nothing on every
/// tick, and `SensorTimelineBuilder` closes a turn on every nothing, so a
/// renamed meter element would produce zero turns and name nobody for a whole
/// call. That is the failure the hold below already records having shipped.
export function createSpeakingTracker({ holdMs = 1_500 } = {}) {
  const lastMeter = new Map();
  const lastChange = new Map();
  // The last tick that named somebody without ambiguity, so a moment of
  // crosstalk does not read as silence.
  let held = null;
  let heldAt = -Infinity;
  return {
    update(tiles, now) {
      const present = collapseMeetTiles(tiles);
      const metered = present.filter((tile) => tile && tile.id && tile.hasMeter);
      // The candidates this tick, and whether they were chosen by meter or by
      // there being no meter to choose on.
      const scoped = metered.length > 0;
      const candidates = new Set((scoped ? metered : present)
        .filter((tile) => tile && tile.id)
        .map((tile) => tile.id));

      for (const tile of present) {
        if (!tile || !tile.id) continue;
        const meter = String(tile.meter ?? '');
        if (lastMeter.has(tile.id) && lastMeter.get(tile.id) !== meter) {
          lastChange.set(tile.id, now);
        }
        lastMeter.set(tile.id, meter);
      }
      // Only the change clock is evicted, so a tile that stops being a
      // candidate cannot win the floor on the strength of a change made while
      // it was not one. `lastMeter` is kept: dropping the baseline too means
      // the tile's next change goes unseen, which costs a speaker an extra
      // tick every time their meter node flickers.
      for (const id of [...lastChange.keys()]) {
        if (!candidates.has(id)) lastChange.delete(id);
      }

      const live = [...lastChange.entries()].filter(([, at]) => now - at <= holdMs);
      // Every meter has settled, so nobody is talking. This is the hold
      // expiring, and it is the only path that ends a turn on purpose.
      if (live.length === 0) return null;

      const newest = live.reduce((best, [, at]) => Math.max(best, at), -Infinity);
      const movers = live.filter(([, at]) => at === newest);
      if (movers.length === 1 || !scoped) {
        // Not scoped means no tile anywhere has a meter, so every tile is
        // reporting its subtree's churn and ties are the norm. Refusing to
        // answer there would close every turn and name nobody for a whole
        // call, which is the failure the hold above records having shipped.
        held = movers[0][0];
        heldAt = newest;
        return held;
      }
      // Several candidates moved at once, which says nothing about who is
      // talking. The last tick that did say still stands, while it is inside
      // the hold: answering null instead suppressed the floor for the full
      // 1.5 s and split a turn one moment of crosstalk should not have. Where
      // nothing has ever said, as when a stuck reader ties on every tick from
      // the first, there is nothing to stand and the answer is nobody.
      return held !== null && now - heldAt <= holdMs ? held : null;
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
