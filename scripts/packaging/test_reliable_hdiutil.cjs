'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const {createAdapter} = require('./reliable_hdiutil.cjs');

const image = '/temporary/owned.dmg';
const mount = '/Volumes/BeaverMeter 1.0.0';
const device = '/dev/disk4';
const unrelated = {'image-path': '/temporary/other.dmg',
  'system-entities': [{'dev-entry': '/dev/disk99', 'mount-point': '/Volumes/Other'}]};
const entities = mounted => [
  {'dev-entry': device},
  {'dev-entry': '/dev/disk5s1', ...(mounted ? {'mount-point': mount} : {})}
];
const callback = (fn, value) => new Promise((resolve, reject) =>
  fn(value, (error, result) => error ? reject(error) : resolve(result)));

function fixture(options = {}) {
  let attached = true;
  let mounted = true;
  let detaches = 0;
  const commands = [];
  const adapter = createAdapter({
    canonical: value => value,
    parsePlist: JSON.parse,
    delay: async () => {},
    run: async args => {
      commands.push(args);
      if (args[0] === 'attach') {
        if (options.invalidAttach) return {stdout: '{invalid'};
        return {stdout: JSON.stringify({'system-entities': entities(true)})};
      }
      if (args[0] === 'info') {
        const owned = {'image-path': image, 'system-entities': entities(mounted)};
        return {stdout: JSON.stringify({images: [unrelated, ...(attached ? [owned] : [])]})};
      }
      assert.equal(args[0], 'detach');
      assert.equal(args[1], device);
      detaches++;
      if (options.nonBusyError) throw Object.assign(new Error('Permission denied'), {code: 1});
      if (options.busyOnce && detaches === 1) {
        mounted = false;
        throw Object.assign(new Error('Resource busy'), {code: 16});
      }
      attached = false;
      return {stdout: ''};
    }
  });
  return {adapter, commands, removeOwned: () => { attached = false; }};
}

test('partial APFS detach retries the verified device after its mountpoint disappears', async () => {
  const {adapter, commands} = fixture({busyOnce: true});
  assert.equal(await callback(adapter.attach, image), mount);
  await callback(adapter.detach, mount);
  assert.deepEqual(commands.filter(args => args[0] === 'detach'),
    [['detach', device], ['detach', device]]);
  assert.ok(commands.filter(args => args[0] === 'info').length >= 4);
});

test('non-busy errors fail immediately and never detach another image', async () => {
  const {adapter, commands} = fixture({nonBusyError: true});
  await callback(adapter.attach, image);
  await assert.rejects(callback(adapter.detach, mount), /Permission denied/);
  assert.equal(commands.filter(args => args[0] === 'detach').length, 1);
});

test('a disappeared owned image never detaches a potentially reused device', async () => {
  const {adapter, commands, removeOwned} = fixture();
  await callback(adapter.attach, image);
  removeOwned();
  await callback(adapter.detach, mount);
  assert.equal(commands.filter(args => args[0] === 'detach').length, 0);
});

test('unknown mounts fail closed without invoking hdiutil', async () => {
  const {adapter, commands} = fixture();
  await assert.rejects(callback(adapter.detach, '/Volumes/Other'), /not attached by this packaging run/);
  assert.equal(commands.length, 0);
});

test('invalid attach output cleans only its owned image and retains the primary error', async () => {
  const {adapter, commands} = fixture({invalidAttach: true});
  await assert.rejects(callback(adapter.attach, image), SyntaxError);
  assert.deepEqual(commands.filter(args => args[0] === 'detach'), [['detach', device]]);
});

test('ambiguous device ownership is rejected before detach', async () => {
  const adapter = createAdapter({
    canonical: value => value, parsePlist: JSON.parse,
    run: async args => {
      if (args[0] === 'attach') return {stdout: JSON.stringify({'system-entities': entities(true)})};
      assert.equal(args[0], 'info');
      return {stdout: JSON.stringify({images: [
        {'image-path': image, 'system-entities': entities(true)},
        {...unrelated, 'system-entities': entities(false)}
      ]})};
    }
  });
  await assert.rejects(callback(adapter.attach, image), /ownership is ambiguous/);
});
