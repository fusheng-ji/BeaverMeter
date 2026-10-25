#!/bin/zsh
set -euo pipefail

# Built products only: no launch, credentials, HTTP, SSH or installed app access.
python3 - "$1" <<'PY'
import plistlib
import struct
import sys
from pathlib import Path

app = Path(sys.argv[1])
widget = app / 'Contents/PlugIns/BeaverMeterWidgetExtension.appex'
def info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())

app_info, widget_info = info(app), info(widget)
scheme = app_info['CFBundleIdentifier']
assert app_info['BeaverMeterMenuURLScheme'] == scheme
assert widget_info['BeaverMeterMenuURLScheme'] == scheme
assert app_info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == [scheme]
for bundle in (app, widget):
    for provider in ('codex', 'claude', 'cursor', 'deepseek'):
        for suffix in ('', '-template'):
            asset = bundle / f'Contents/Resources/ProviderAssets/{provider}{suffix}.png'
            header = asset.read_bytes()[:26]
            assert header[:8] == b'\x89PNG\r\n\x1a\n', asset
            assert struct.unpack('>II', header[16:24]) == (256, 256), asset
            assert header[25] == 6, f'RGBA required: {asset}'
assert not (widget / 'Contents/Resources/BrandAssets').exists(), 'Widget must not bundle beaver logos'
print('App/Widget navigation schemes and bundled service logos passed.')
PY
