import test from 'node:test';
import assert from 'node:assert/strict';
import {
  providerForURL,
  meetingIdForURL,
  stateFromControls,
  mutedFromControls,
  buildState,
  isMeaningfulChange,
  shouldSend,
  HEARTBEAT_MS,
  rosterFromTiles,
  zoomParticipantFromLabel,
  createSpeakingTracker,
  meetTileName,
} from '../shared/provider.js';

const leaveControl = { ariaLabel: 'Leave call' };
const joinControl = { ariaLabel: 'Join now' };
const micOn = { ariaLabel: 'Turn off microphone' };
const micOff = { ariaLabel: 'Turn on microphone' };

test('recognises Meet and Zoom URLs', () => {
  assert.equal(providerForURL('https://meet.google.com/jfp-btbt-owm'), 'meet');
  assert.equal(providerForURL('https://app.zoom.us/wc/81771591841/join'), 'zoom');
  assert.equal(providerForURL('https://example.com'), 'unknown');
  assert.equal(providerForURL('not a url'), 'unknown');
});

test('reads the meeting identifier out of the URL', () => {
  assert.equal(meetingIdForURL('https://meet.google.com/jfp-btbt-owm'), 'jfp-btbt-owm');
  assert.equal(meetingIdForURL('https://meet.google.com/'), null);
  // Zoom's numeric ID lives only in the URL; the window title carries the name.
  assert.equal(meetingIdForURL('https://app.zoom.us/wc/81771591841/join'), '81771591841');
  assert.equal(meetingIdForURL('https://us02web.zoom.us/j/81771591841?pwd=x'), '81771591841');
});

test('a leave control is what separates prejoin from an active call', () => {
  assert.equal(stateFromControls([joinControl]), 'prejoin');
  assert.equal(stateFromControls([leaveControl, micOn]), 'in_call');
  assert.equal(stateFromControls([]), 'browsing');
  // A leave control wins even when a join control is still in the DOM.
  assert.equal(stateFromControls([joinControl, leaveControl]), 'in_call');
});

test('a waiting room is reported as waiting, not as a call', () => {
  assert.equal(
    stateFromControls([], 'Asking to be let in. Waiting for the host to admit you.'),
    'waiting',
  );
});

test('mute state comes from the inverted control label', () => {
  assert.equal(mutedFromControls([micOn]), false);
  assert.equal(mutedFromControls([micOff]), true);
  assert.equal(mutedFromControls([leaveControl]), null);
  assert.equal(mutedFromControls([{ ariaLabel: 'microphone', ariaPressed: 'true' }]), true);
});

test('builds the message the app consumes', () => {
  const message = buildState({
    href: 'https://meet.google.com/jfp-btbt-owm?authuser=0',
    title: 'Meet - jfp-btbt-owm',
    controls: [leaveControl, micOn],
    pageText: '',
    tabId: 7,
    now: 1787070000000,
  });
  assert.equal(message.type, 'state');
  assert.equal(message.provider, 'meet');
  assert.equal(message.state, 'in_call');
  assert.equal(message.meetingId, 'jfp-btbt-owm');
  assert.equal(message.url, 'https://meet.google.com/jfp-btbt-owm');
  assert.equal(message.muted, false);
  assert.equal(message.tabId, 7);
});

test('only meaningful changes are reported', () => {
  const base = { provider: 'meet', state: 'in_call', meetingId: 'a', url: 'u', title: 't', muted: false };
  assert.equal(isMeaningfulChange(null, base), true);
  assert.equal(isMeaningfulChange(base, { ...base }), false);
  assert.equal(isMeaningfulChange(base, { ...base, muted: true }), true);
  assert.equal(isMeaningfulChange(base, { ...base, state: 'ended' }), true);
  // A changing timestamp alone is not a change worth sending.
  assert.equal(isMeaningfulChange(base, { ...base, sentAt: 99 }), false);
});

// The built artefact is what actually loads in a browser, and a content script
// cannot be an ES module: an import statement makes the whole script fail
// silently and the sensor never runs.
test('the built content scripts carry no module syntax', async () => {
  const { execFileSync } = await import('node:child_process');
  const fs = await import('node:fs');
  const path = await import('node:path');
  const root = path.dirname(import.meta.dirname);
  execFileSync(path.join(root, 'build.sh'), { stdio: 'pipe' });

  for (const browser of ['firefox', 'chrome']) {
    const dir = path.join(root, 'dist', browser, 'shared');
    for (const file of ['provider.js', 'content.js', 'background.js']) {
      const source = fs.readFileSync(path.join(dir, file), 'utf8');
      assert.equal(/^\s*import\s/m.test(source), false, `${browser}/${file} still imports`);
      assert.equal(/^\s*export\s/m.test(source), false, `${browser}/${file} still exports`);
    }
    const manifest = JSON.parse(
      fs.readFileSync(path.join(root, 'dist', browser, 'manifest.json'), 'utf8'),
    );
    // provider.js has to load first: content.js calls into it.
    assert.deepEqual(manifest.content_scripts[0].js, ['shared/provider.js', 'shared/content.js']);
  }
});

test('the built provider still defines what the content script calls', async () => {
  const fs = await import('node:fs');
  const path = await import('node:path');
  const root = path.dirname(import.meta.dirname);
  const provider = fs.readFileSync(
    path.join(root, 'dist', 'firefox', 'shared', 'provider.js'), 'utf8',
  );
  const content = fs.readFileSync(
    path.join(root, 'dist', 'firefox', 'shared', 'content.js'), 'utf8',
  );
  for (const name of ['buildState', 'isMeaningfulChange', 'shouldSend', 'providerForURL']) {
    assert.ok(new RegExp(`function ${name}\\b`).test(provider), `${name} missing from provider.js`);
  }
  for (const name of ['buildState', 'shouldSend', 'providerForURL']) {
    assert.ok(content.includes(name), `${name} unused by content.js`);
  }
  assert.ok(/const HEARTBEAT_MS/.test(provider), 'the heartbeat interval survived the build');
});

test('an unchanged call still reports before the app stops trusting it', () => {
  const state = { provider: 'meet', state: 'in_call', meetingId: 'abc', url: 'u', title: 't', muted: false };
  // Nothing changed and the last message was recent: stay quiet.
  assert.equal(shouldSend(state, state, 1000, 1000 + HEARTBEAT_MS - 1), false);
  // Nothing changed but the app is about to treat the tab as silent.
  assert.equal(shouldSend(state, state, 1000, 1000 + HEARTBEAT_MS), true);
  // A change always sends, however recent the last message was.
  assert.equal(shouldSend(state, { ...state, state: 'ended' }, 1000, 1001), true);
  // The first snapshot of a tab always sends.
  assert.equal(shouldSend(null, state, 0, 500), true);
});

// --- roster -----------------------------------------------------------------

test('a tile without an identifier is dropped rather than guessed at', () => {
  // The identifier is what ties a person to a voice. A made-up one ties them
  // to the wrong voice, which is worse than leaving the cluster unnamed.
  const people = rosterFromTiles([
    { id: 'spaces/x/devices/406', name: 'Ada' },
    { id: '', name: 'Nameless' },
    { name: 'No id at all' },
  ]);
  assert.equal(people.length, 1);
  assert.equal(people[0].id, 'spaces/x/devices/406');
});

test('a duplicate tile collapses to one person', () => {
  // Meet renders a participant in the grid and again in the people panel.
  const people = rosterFromTiles([
    { id: 'd406', name: 'Ada' },
    { id: 'd406', name: 'Ada' },
    { id: 'd409', name: 'Grace' },
  ]);
  assert.equal(people.length, 2);
});

test('a name arriving later fills in a blank one', () => {
  const people = rosterFromTiles([{ id: 'd406' }, { id: 'd406', name: 'Ada' }]);
  assert.equal(people[0].name, 'Ada');
});

test('a meter that changed recently is speaking, one that settled is not', () => {
  // Meet animates a per-participant level meter while someone talks and lets it
  // settle when they stop. Reading the animation rather than a class name means
  // no selector has to be kept in step with whatever Meet renames next.
  //
  // Timed at the real read cadence of 500 ms, because that is what broke: a hold
  // shorter than the gap between reads expires before the next read can renew
  // it, so the floor drops on every tick and no turn ever grows.
  const tracker = createSpeakingTracker();
  assert.equal(tracker.update([{ id: 'd406', meter: 'a' }], 0), null);
  assert.equal(tracker.update([{ id: 'd406', meter: 'b' }], 500), 'd406');
  assert.equal(tracker.update([{ id: 'd406', meter: 'c' }], 1000), 'd406');
  // Settled: the meter stops changing and the hold runs out.
  assert.equal(tracker.update([{ id: 'd406', meter: 'c' }], 1500), 'd406');
  assert.equal(tracker.update([{ id: 'd406', meter: 'c' }], 3000), null);
});

test('a turn survives the gap between reads', () => {
  // Ten seconds of continuous speech has to come out as one turn, not twenty.
  // Six seconds in a single turn is what makes somebody a speaker downstream.
  const tracker = createSpeakingTracker();
  let held = 0;
  for (let t = 0; t <= 10_000; t += 500) {
    if (tracker.update([{ id: 'd406', meter: `m${t}` }], t) === 'd406') held += 1;
  }
  assert.ok(held >= 19, `floor held on ${held} of 21 reads`);
});

test('the floor goes to whoever changed most recently', () => {
  const tracker = createSpeakingTracker();
  tracker.update([{ id: 'a', meter: '1' }, { id: 'b', meter: '1' }], 0);
  tracker.update([{ id: 'a', meter: '2' }, { id: 'b', meter: '1' }], 500);
  assert.equal(tracker.update([{ id: 'a', meter: '2' }, { id: 'b', meter: '2' }], 1000), 'b');
});

test('a roster of one is still a roster', () => {
  // A call can legitimately hold one person, and reporting nothing would read
  // as the sensor being broken.
  assert.equal(rosterFromTiles([{ id: 'd406', name: 'Ada' }]).length, 1);
});

test('the roster rides along in the state message', () => {
  const state = buildState({
    href: 'https://meet.google.com/abc-defg-hij',
    title: 'Meet',
    controls: [leaveControl],
    pageText: '',
    tabId: 3,
    now: 1000,
    people: [{ id: 'd406', name: 'Ada', isSelf: true, muted: false }],
    activeSpeaker: 'd406',
  });
  assert.equal(state.people.length, 1);
  assert.equal(state.activeSpeaker, 'd406');
});

test('no roster leaves the fields off entirely', () => {
  // Absent means the page did not say. An empty array would claim an empty room.
  const state = buildState({
    href: 'https://meet.google.com/abc-defg-hij',
    title: 'Meet',
    controls: [leaveControl],
    pageText: '',
    tabId: 3,
    now: 1000,
  });
  assert.equal(state.people, undefined);
  assert.equal(state.activeSpeaker, undefined);
});

test('the floor moving is a change worth sending', () => {
  const base = {
    provider: 'meet', state: 'in_call', meetingId: 'abc', url: 'u', title: 't',
    muted: false, activeSpeaker: 'a', people: [{ id: 'a' }, { id: 'b' }],
  };
  assert.equal(isMeaningfulChange(base, { ...base, activeSpeaker: 'b' }), true);
  assert.equal(isMeaningfulChange(base, { ...base }), false);
});

test('someone joining is a change worth sending', () => {
  const base = { provider: 'meet', state: 'in_call', people: [{ id: 'a' }] };
  assert.equal(
    isMeaningfulChange(base, { ...base, people: [{ id: 'a' }, { id: 'b' }] }),
    true
  );
});

test('a zoom row label yields name, self and mute state', () => {
  // Measured on the web client: the label is the whole surface. The row id is
  // a list position and no element carries a participant identifier.
  assert.deepEqual(
    zoomParticipantFromLabel('Andrew Neeser (Host, me),computer audio muted,video off'),
    { name: 'Andrew Neeser', isSelf: true, muted: true }
  );
  assert.deepEqual(
    zoomParticipantFromLabel('A 2 (Guest),computer audio unmuted,video off'),
    { name: 'A 2', isSelf: false, muted: false }
  );
});

test('a zoom label without an audio clause still names the person', () => {
  assert.deepEqual(
    zoomParticipantFromLabel('Grace Hopper (Co-host)'),
    { name: 'Grace Hopper', isSelf: false, muted: undefined }
  );
});

test('a zoom name containing parentheses keeps them', () => {
  // Only a trailing role list is stripped, and only a role reading exactly
  // "me" marks the local user: a person named Me Someone does not.
  assert.deepEqual(
    zoomParticipantFromLabel('Ada (she/her) (Guest),computer audio muted,video off'),
    { name: 'Ada (she/her)', isSelf: false, muted: true }
  );
});

test('an empty or roleless-empty zoom label is nobody', () => {
  assert.equal(zoomParticipantFromLabel(''), null);
  assert.equal(zoomParticipantFromLabel('   '), null);
  assert.equal(zoomParticipantFromLabel('(Host, me),computer audio muted,video off'), null);
});

// --- Meet tile names -------------------------------------------------------

test('a grid tile name is the first line', () => {
  assert.equal(meetTileName('Chris Latimer\nsomething else'), 'Chris Latimer');
  assert.equal(meetTileName('  Nicol\u00f2 Boschi  '), 'Nicol\u00f2 Boschi');
});

test('a people-panel row is cut back to the name', () => {
  // Measured from a real recording. A panel row has no line break, so taking
  // the first line returned the whole run: the name, the host badge, an icon
  // ligature, and the mute tooltip, truncated mid-word at 80 characters.
  assert.equal(
    meetTileName("Chris LatimerMeeting hostdevicesYou can't remotely mute Chris Latimer's microphone"),
    'Chris Latimer',
  );
  assert.equal(
    meetTileName('2303 TLVdomain_disabledVisitorAdmitmore_vertMore actions'),
    '2303 TLV',
  );
});

test('a row that is chrome all the way down yields no name', () => {
  // Nothing is better than something wrong: an unnamed sensor key renders
  // through the fallback and waits for a person, and a wrong name does not.
  assert.equal(meetTileName('more_vertMore actions'), undefined);
  assert.equal(meetTileName('   '), undefined);
  assert.equal(meetTileName(null), undefined);
});

// --- Who holds the floor ---------------------------------------------------

const metered = (id, meter) => ({ id, meter, hasMeter: true });

test('tiles changing together name nobody', () => {
  // The 863-second turn. Meet renamed the meter element, every tile fell back
  // to its whole class string, and any DOM churn moved all of them at once.
  // The tie went to whichever tile was seen first, so one participant held the
  // floor for fourteen minutes and every remote word in the meeting was filed
  // under their name.
  const tracker = createSpeakingTracker();
  tracker.update([metered('a', '1'), metered('b', '1'), metered('c', '1')], 0);
  assert.equal(
    tracker.update([metered('a', '2'), metered('b', '2'), metered('c', '2')], 500),
    null,
  );
});

test('one tile changing alone still holds the floor', () => {
  const tracker = createSpeakingTracker();
  tracker.update([metered('a', '1'), metered('b', '1')], 0);
  assert.equal(tracker.update([metered('a', '2'), metered('b', '1')], 500), 'a');
});

test('a tile with no meter cannot hold the floor while another has one', () => {
  // A people-panel row carries no level meter, so its churn is layout rather
  // than audio. It stays in the roster and out of the floor.
  const tracker = createSpeakingTracker();
  tracker.update([metered('grid', '1'), { id: 'panel', meter: 'x', hasMeter: false }], 0);
  assert.equal(
    tracker.update([metered('grid', '1'), { id: 'panel', meter: 'y', hasMeter: false }], 500),
    null,
  );
  assert.equal(
    tracker.update([metered('grid', '2'), { id: 'panel', meter: 'z', hasMeter: false }], 1000),
    'grid',
  );
});

test('with no meter anywhere the old tie-break still decides', () => {
  // Meet rotates the meter element's name. When it does, no tile has one and
  // this falls back to what shipped before: something is named rather than
  // nothing. Returning null here instead would collapse every turn to a single
  // read and name nobody for the whole call, which is the failure this file
  // already records having shipped once.
  const tracker = createSpeakingTracker();
  const soup = (id, meter) => ({ id, meter, hasMeter: false });
  tracker.update([soup('a', '1'), soup('b', '1')], 0);
  assert.equal(tracker.update([soup('a', '2'), soup('b', '2')], 500), 'a');
});
