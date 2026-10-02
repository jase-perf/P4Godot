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

**On Windows, run the `..._console.exe` build.** The normal `.exe` is a GUI
binary and prints nothing to the terminal, so every test looks silent. The
`[selftest]` lines also go to stdout, which is block-buffered when redirected
and lost if the process is killed — so trust only a run that exited on its
own. No lines at all means the run failed, not that the test passed. Godot's
headless editor also deadlocks on its first filesystem scan now and then; that
run prints the banner and nothing else, and the fix is to wait a few seconds
and run it again.

**Server-independent** tests run anywhere, including a throwaway project:
`save-guards`, `prewrite`, `unchanged-save`, `exec-quoting`, `parse-ztag`,
`sync-report`, `diff-align`, `dismiss-dialog`, `breaker`, and a few more.
One command runs all of them, plus the warnings check below:

```
tools/run-selftests.sh <path-to-godot>
```

It unpacks the addon from `git archive HEAD` into a throwaway project, so it
tests what a release zip would ship — your last commit, not uncommitted
edits — and it retries the deadlocked runs for you. CI runs the same script
on every push and pull request (`.github/workflows/ci.yml`).

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
- Check for GDScript warnings. Godot excludes `res://addons` from warnings by
  default, so you have to ask for them. Copy the addon into a throwaway
  project whose `project.godot` contains at least:

  ```
  [debug]
  gdscript/warnings/directory_rules={"res://addons": 1}
  gdscript/warnings/unused_variable=2
  gdscript/warnings/shadowed_variable=2
  gdscript/warnings/integer_division=2
  gdscript/warnings/unreachable_code=2
  ```

  (`1` warns, `2` is an error. Add any other warning you want treated as one.)
  Then:

  ```
  godot --headless --path <project> --check-only --script res://addons/p4godot/p4godot.gd
  ```

  It exits 1 and prints a `SCRIPT ERROR:` line for both a parse error and a
  warning-turned-error, naming the identifier (measured on Godot 4.7). The
  plugin is warning-clean at Godot's defaults and should stay that way,
  because people do turn warnings on for addons.
- When you fix a bug, add a test and then **neuter the fix and confirm the
  test fails**. A test that passes either way is worse than no test: it looks
  like evidence. Several tests here were rewritten after that check showed
  they proved nothing.

## Releasing

1. Set `version` in `addons/p4godot/plugin.cfg` and add a `## <version>`
   section to `CHANGELOG.md`.
2. Run `tools/sync-addon-readme.sh` if the README changed, and commit.
3. Tag the commit `v<version>` and push the tag.

CI does the rest: it runs the self-tests, refuses a tag that doesn't match
`plugin.cfg`, builds `p4godot-v<version>.zip` with `git archive`, and
publishes a GitHub release with that zip and the changelog section as its
notes. The README's install step points at that zip.
