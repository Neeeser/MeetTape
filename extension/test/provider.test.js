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
