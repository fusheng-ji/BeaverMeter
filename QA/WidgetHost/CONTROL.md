# Synthetic desktop QA control backend

This backend switches only the reviewed private QA executable's synthetic case.
It contains no UI, AX, screenshot, widget registration, process termination or
collector operations. Actual desktop observations remain in CUA.

Start it from the repository root in an explicitly approved persistent execution
session; the script itself does not daemonize or launch the GUI host:

```sh
python3 QA/WidgetHost/control_runner.py \
  --control .build/widget-desktop-qa/control \
  --app '.build/widget-desktop-qa/Build/Products/Debug/BeaverMeter QA.app' \
  --manifest .build/widget-module-qa/fixtures/manifest.json
```

The app and embedded extension must retain the fixed private identifiers
`com.jiwenbo.beavermeter.widgetqa` and
`com.jiwenbo.beavermeter.widgetqa.widget`. Production application identities are
refused. The manifest whitelist is frozen at startup. Every requested fixture
must still reside within its `fixtures/cases` directory, match its recorded
SHA256 and contain the matching case ID before the private executable receives
an argument array equivalent to `BeaverMeter QA --apply CASE_FILE`.

Write `request.json` atomically inside the control directory:

```json
{"seq": 1, "caseID": "reference-four-rows"}
```

Wait for `ack.json` with the exact sequence and case ID:

```json
{"seq": 1, "caseID": "reference-four-rows", "status": "applied"}
```

Failures use `status: "error"` and include an `error` string. Require the matching
successful acknowledgment before using CUA to inspect the actual Widget and
confirm its accessibility case ID; an acknowledgment is not desktop evidence.
Use strictly increasing, nonnegative integer sequences. A valid sequence is
reserved in `state.json` before applying, including when applying later fails;
reusing it never invokes the executable again, even after backend restart.
After a crash, use a larger sequence rather than resetting the sequence state.
One backend owns `runner.lock` at a time.

Create a file named `stop` in the control directory to exit the polling loop.
Before an intentional restart, remove only that stop file. Backend writes are
limited to its control directory; the approved QA executable owns the separate
synthetic Application Support write. No production files are read or changed.

Run the isolated negative checks without starting the backend or any app:

```sh
python3 QA/WidgetHost/control_runner.py --self-test
```

These checks use temporary synthetic bundles/files and an injected fake executor.
They cover invalid sequence types, forbidden IDs, production bundle rejection,
changed hashes, path/symlink escapes, and idempotency across restarts.
