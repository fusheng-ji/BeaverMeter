#!/usr/bin/env node
// Keep create-dmg's pinned artwork, Finder layout, icon composition and format.
// Only replace appdmg's text-parsed mountpoint cleanup with verified device cleanup.
import {createRequire} from 'node:module';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {pathToFileURL} from 'node:url';

const require = createRequire(import.meta.url);
const {createAdapter} = require('./reliable_hdiutil.cjs');
const plist = require('plist');
const exec = promisify(execFile);
for (const [name, version] of [['create-dmg', '8.1.0'], ['appdmg', '0.6.6']]) {
  if (require(`${name}/package.json`).version !== version) {
    throw new Error(`Packaging adapter requires ${name} ${version}; review it before updating the dependency`);
  }
}
const report = message => console.error(`[dmg] ${message}`);
const adapter = createAdapter({
  run: args => exec('/usr/bin/hdiutil', args, {maxBuffer: 4 * 1024 * 1024}),
  parsePlist: plist.parse,
  report
});
const hdiutil = require('appdmg/lib/hdiutil');
hdiutil.attach = adapter.attach;
hdiutil.detach = adapter.detach;

const Pipeline = require('appdmg/lib/pipeline');
const progress = Pipeline.prototype._progress;
Pipeline.prototype._progress = function (info) {
  if (info.type === 'step-begin') report(info.title);
  return progress.call(this, info);
};
await import(pathToFileURL(require.resolve('create-dmg/cli.js')).href);
