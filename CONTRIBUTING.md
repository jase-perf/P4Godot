# Contributing to P4Godot

Bug reports and pull requests are welcome. Please
[open an issue](https://github.com/jase-perf/P4Godot/issues) with the
**Verbose log** output (the settings menu in the P4G toolbar turns it on) when
something misbehaves — the log shows every `p4` command and its output, which
is usually enough to find the cause.

## Layout

Everything is in `addons/p4godot/p4godot.gd`. It's one large GDScript file on
purpose: the plugin is a single `EditorPlugin`, and keeping it in one file
keeps a drop-in install a folder copy with nothing to wire up.

`addons/p4godot/README.md` is generated from the root `README.md` by
`tools/sync-addon-readme.sh`, which rewrites `docs/` links to absolute URLs
because release zips ship the addon folder without `docs/`. Edit the root
README and re-run the script; don't edit the copy.

## Self-tests

The plugin has built-in self-tests, run headless:

```
godot --headless --editor --path <project> -- --p4-selftest-<name>
```

A test that checks a result logs `[selftest] PASS: <name>` or
`[selftest] FAIL: <name>`. Judge by those lines, not by the exit code. Tests
that only list something print what they found.

**Server-independent** tests run anywhere, including a throwaway project:
`save-guards`, `prewrite`, `unchanged-save`, `exec-quoting`, `parse-ztag`,
`sync-report`, `diff-align`, `dismiss-dialog`, `breaker`.

**Live** tests need a real workspace. Read-only ones — `probe`, `list-opened`,
`reconcile-report`, `reconcile-preview` — are safe to run against a workspace
in any state, and `reconcile-report` prints exactly what the Reconcile dialog
would say, which is the first thing to try on any reconcile complaint. Others
change the workspace: some clean up after themselves, some need a clean
workspace and say so, and some need staging beforehand (`get-latest` explains
its own in a comment above it).

`_run_cli_self_test_if_requested` has the full list.
`docs/manual-tests.md` covers the checks that need a real editor window,
because no headless test can see a dialog's layout or a tooltip.

## Before sending a change

- Run the server-independent tests.
- Check for GDScript warnings. Copy the addon into a throwaway project whose
  `project.godot` enables warnings for `res://addons`, then:

  ```
  godot --headless --path <project> --check-only --script res://addons/p4godot/p4godot.gd
  ```

  Grep the output for `SCRIPT ERROR`. The plugin is warning-clean at Godot's
  defaults, and should stay that way — people enable warnings for addons.
- When you fix a bug, add a test and then **neuter the fix and confirm the
  test fails**. A test that passes either way is worse than no test: it looks
  like evidence. Several tests here were rewritten after that check showed
  they proved nothing.
