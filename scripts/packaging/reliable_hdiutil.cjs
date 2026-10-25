'use strict';

const fs = require('node:fs');
const path = require('node:path');

function canonicalPath(value) {
  const resolved = path.resolve(value);
  // hdiutil can retain an image after its temporary file has been removed.
  return path.join(fs.realpathSync(path.dirname(resolved)), path.basename(resolved));
}

function createAdapter({run, parsePlist, canonical = canonicalPath,
  delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
  report = () => {}, attempts = 8}) {
  const attachments = new Map();

  async function ownedImage(image) {
    const info = parsePlist((await run(['info', '-plist'])).stdout);
    const images = info.images ?? [];
    const matches = images.filter(item => typeof item['image-path'] === 'string'
      && canonical(item['image-path']) === image);
    if (matches.length > 1) throw new Error('Ambiguous disk image ownership');
    if (matches.length === 0) return null;
    const item = matches[0];
    const device = (item['system-entities'] ?? []).find(entity =>
      /^\/dev\/disk\d+$/.test(entity['dev-entry'] ?? ''))?.['dev-entry'];
    if (!device) throw new Error('Owned image has no whole-device identifier');
    // Refuse a device also reported under another image path.
    if (images.some(other => other !== item && (other['system-entities'] ?? [])
      .some(entity => entity['dev-entry'] === device))) {
      throw new Error('Disk image device ownership is ambiguous');
    }
    return {device, entities: item['system-entities'] ?? []};
  }

  async function detachImage(image) {
    for (let attempt = 0; attempt < attempts; attempt++) {
      // Revalidate immediately before every detach; never act on a cached disk number.
      const owned = await ownedImage(image);
      if (!owned) return;
      try {
        report(`Detaching verified image device ${owned.device}`);
        await run(['detach', owned.device]);
        if (await ownedImage(image)) throw new Error('Image remains attached after successful detach');
        return;
      } catch (error) {
        const code = error.exitCode ?? error.code;
        report(`Detach attempt ${attempt + 1}: ${error.stderr?.trim() || error.message}`);
        if (code !== 16 || attempt + 1 === attempts) throw error;
        // A busy detach may already unmount APFS. Retrying /Volumes/... then fails;
        // the next iteration resolves this image's current device instead.
        await delay(Math.min(1000 * 2 ** attempt, 8000));
      }
    }
  }

  async function attachImage(imagePath) {
    const image = canonical(imagePath);
    try {
      report('Attaching temporary image with plist ownership verification');
      const result = parsePlist((await run(['attach', imagePath,
        '-nobrowse', '-noverify', '-noautoopen', '-plist'])).stdout);
      const mounted = (result['system-entities'] ?? []).filter(entity => entity['mount-point']);
      if (mounted.length !== 1) throw new Error('Expected exactly one mounted image volume');
      const mount = mounted[0]['mount-point'];
      const owned = await ownedImage(image);
      if (!owned || !owned.entities.some(entity => entity['mount-point'] === mount
        && entity['dev-entry'] === mounted[0]['dev-entry'])) {
        throw new Error('Mounted volume does not belong to the requested image');
      }
      attachments.set(mount, image);
      return mount;
    } catch (error) {
      try {
        await detachImage(image);
      } catch (cleanupError) {
        throw new AggregateError([error, cleanupError],
          `Image attachment failed: ${error.message}; owned-image cleanup failed: ${cleanupError.message}`);
      }
      throw error;
    }
  }

  return {
    attach(image, callback) {
      attachImage(image).then(mount => callback(null, mount), callback);
    },
    detach(mount, callback) {
      const image = attachments.get(mount);
      if (!image) {
        callback(new Error('Refusing to detach a volume not attached by this packaging run'));
        return;
      }
      detachImage(image).then(() => {
        attachments.delete(mount);
        callback(null);
      }, callback);
    }
  };
}

module.exports = {createAdapter};
