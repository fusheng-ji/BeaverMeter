# Troubleshooting

[简体中文](troubleshooting.zh-CN.md) · [README](../../README.md)

## Automatic update checks are unavailable

Source builds, local packages and previews intentionally do not contact the
production updater. Build metadata alone does not make a package an official
release. Use [source installation](development.md#build-and-install) for this
checkout, and see [setup](setup.md#updates) for the supported update flow.

## Codex has no tokens

First identify the reading:

- The menu’s provider-wide total needs local Codex records or the configured SSH source. Run a local session and refresh; verify the configured home if Codex stores data elsewhere.
- A workspace row needs its own verified account API ledger. Reconnect that workspace rather than copy a sibling value or treat its missing data as zero.

A workspace matching the same email is still a separate account context. Its
selected/native/access-token account identities must agree, including an ID
token when present. A workspace-header override is insufficient. A creator ID
in local logs is not request-account proof. See [data](data.md#codex).

## Claude has no local tokens

Run Claude Code once, or set `CLAUDE_CONFIG_DIR` in the private `config.env` for
a non-default directory. Local transcript availability does not prove online
quota authorization. Missing transcripts display no data, not a measured zero.

## Claude Online quota needs attention

| State | Action |
| --- | --- |
| Missing/rejected login | **Sign in to Claude…**, then finish browser authorization |
| Already signed in through Claude Code | **Verify login** |
| Existing Keychain login is inaccessible | **Allow Claude access…** for explicit system authorization |
| Stale unlocked Keychain session | Read the **Repair Keychain session…** confirmation before choosing it |
| Rate limited | Wait for the reported retry time; manual refresh uses the same cooldown |
| CLI absent/cooling down/renewal incomplete | Fix the CLI/profile issue and retry; it is not automatically another browser-login request |

BeaverMeter verifies quota after sign-in; successful CLI exit alone is not a
verified login. Expired/revoked logins may require authorization. Confirmed expiry
or authentication failure clears old online quota/reset readings, while local
transcript activity remains independent.

The repair action locks and then asks macOS to unlock the login Keychain.
Cancelling unlock may leave it locked. It does not delete credentials or change
ACLs. Scheduled reads never initiate this repair or interactive authorization.
Custom profile and CLI switches are described in [data](data.md#claude-code).

## Cursor says Sign in, or monthly allowance is missing

Open Cursor and confirm the intended account is active, then refresh BeaverMeter.
A team pool or administrator cap is not a personal monthly allowance; if Cursor
provides no supported individual limit, the value stays unavailable.

Calls with a valid zero actual charge remain zero. A missing actual charge is
unknown and can withhold the daily total; do not substitute a model list price.

## DeepSeek says Connect

Choose **Connect in browser…**, finish signing in on the official Platform page,
then use **Check now**. In Safari, enable the two developer/Apple Events settings
listed in [setup](setup.md#deepseek) and allow Automation access to the intended
official tab. Do not paste tokens into issue reports or screenshots.

## Remote Codex is missing

Check that the configured SSH alias works noninteractively and the absolute
remote Codex/Python paths still exist. Settings are `CODEX_REMOTE_SSH_HOST`,
`CODEX_REMOTE_ROOT` and `CODEX_REMOTE_PYTHON` in `config.env`. SSH is off by default
on a fresh install and retains its configured state on upgrade.

If Codex moved its home, update the remote root. Discovery can keep today’s
records available during a move, but conflicting homes/read failures remain
explicitly incomplete. A temporary remote failure can preserve compatible
same-day cached records; it does not invent fresh remote usage.

## Data is stale, unknown or has an older report date

`—` means unknown; `0` is an actual known value. **Fetched** is the original
query clock, not a statistics-update guarantee. Workspace service dates are
kept in help/VoiceOver and may differ from the Mac’s date. Cache retention does
not reset that clock. See [periods and clocks](data.md#labels-periods-and-clocks).

Check `~/Library/Logs/BeaverMeter/` and connectivity to the relevant service:
`chatgpt.com`, `api.anthropic.com`, `cursor.com` or `platform.deepseek.com`.
Do not assume one failure affects all other readings.

A full refresh can own the snapshot lock while a fast local poll is due. That
poll exits without changing the snapshot; the next scheduled poll runs normally.
This removes a redundant waiting collector, not every possible UI hesitation.
The [runtime report](../RUNTIME_PERFORMANCE.md) separates measured awake intervals
from unavailable frame timings and controlled post-fix comparisons.

## Widget is empty or a module disappeared

Check **Services** and the particular Widget’s **Edit Widget** selection.
Small reads only the first two slots, Medium four, Large/Extra Large six. Empty,
duplicate, invalid or hidden entries do not pull later slots forward. A removed
workspace remains unavailable until reselected; extra source workspaces do not
automatically appear. Explicitly empty selection remains empty.

## Widget registration is missing or duplicated

Prefer one supported installation path. If you switch application identity,
macOS may require removing that identity's Widget and adding BeaverMeter again.
For a source checkout, the repair tool is:

```sh
./scripts/repair_widget.sh
```

It reconciles registrations, refreshes WidgetKit caches and relaunches the app.
Use it when repair is needed, not as a periodic refresh command. Preserve your
settings and sign-ins; a blank Widget does not by itself require deleting data.

## Update failed or the app did not relaunch

Finish account sign-in before installing. Download/verification failures should
leave the current app intact. Reopen the installed BeaverMeter to complete runtime
recovery if relaunch did not occur. Source/local packages do not use the live
feed, and another-user-owned application folder may need administrator approval.
Do not disable signature validation or replace the release key to bypass an error.

## Reporting an issue

Include the app version/build, macOS version, affected service/Widget size and
whether the state was live, stale or unknown. A synthetic reproduction is best.
Redact email addresses and private profile/host names. Never attach auth files,
browser tokens, cookies, prompts, full transcripts or an unreviewed real snapshot.
