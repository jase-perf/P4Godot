# What the tests cover, and what still needs a person

`docs/manual-tests.md` lists the checks a person runs before a release. This
page says which of them a script now does, so that list can shrink. Status
on 2026-10-17, Windows 11, Godot 4.7, p4d 2026.1.

## The three ways tests run

- **Offline** (`tools/run-selftests.sh`): no server. Parsers, decisions,
  menus, dialogs' wording. Runs in CI.
- **Live** (`tools/run-live-tests.sh`): a throwaway p4d on this machine, two
  ordinary users (`dev`, `mate`), a project in a folder of the workspace with
  an `art/` folder beside it, checked in after Godot's own first import (so
  `project.godot`, the `.uid` and `.import` files are in Perforce, as in a
  real team's project). The editor runs headless.
- **GUI** (`GUI=1 SHOTS=<folder> tools/run-live-tests.sh <godot> gui-dock
  gui-dialogs gui-windows gui-editor`): the same, in a real editor window.
  Each test drives the plugin, waits for what it shows, answers dialogs, and
  saves PNGs of the editor, menus, dialogs and windows into `SHOTS`. The PNGs
  are what a design review reads. Only Godot's own windows are captured,
  never the desktop. `THEME=light` runs the same tour in Godot's light theme.

GUI mode found two things headless runs can't: Godot opens its own "Load
Errors" dialog when it can't write a read-only `project.godot` at startup,
and a second exclusive dialog then never appears (the plugin's question
would wait for an answer that can't come). The tests close Godot's dialog
first; see the todo list for the product side.

## The manual list, row by row

"Automated" means a test checks the outcome, not only that nothing crashed.
"Screenshot" means a GUI test captures the screen for review but asserts
little about it. "Next" means the harness can do it and the test isn't
written yet.

### GUI-only checks (`manual-tests.md`, 53 rows)

| Row | Status | How |
|---|---|---|
| 1-2 Import dock reimport, with and without a change | Automated | `import-dock` presses the Import dock's real Reimport button on `art/icon.svg` |
| 3 Special-character file through the FileSystem dock | Mostly automated | `special-names`, `moves-live`; the dock's own rename UI is not driven |
| 4 Switching scene tabs prompts nothing | Automated | `history-gate` |
| 5 Discard, then edit again: prompts again | Automated | `decline-reprompt` |
| 6 Revert keeps the script tab | Automated | `script-revert` |
| 7-8 Watcher: automatic and listed | Automated | `watch-live`; panel in `gui-dock` |
| 9 Reconcile's confirmation | Screenshot | `gui-dialogs` |
| 10 A teammate's lock | Automated | `watch-live` (both answers); dialog in `gui-dialogs` |
| 11 Addon not in Perforce | Automated | `plugin-prompt`: the runner takes the addon out of the depot first (`delete -k`), then puts it back |
| 12 Get Latest, nothing to do | Screenshot | `gui-dialogs` |
| 13-15b Get Latest: reload, refusals, behind, your work kept | Automated | `get-latest-scene`, `-script`, `-modified`, `-checked-out`, `-keep-mine` (the new button combines a change made on disk), `-unsaved` and `-unsaved-checked-out` (an unsaved edit survives, and is combined only after the save): the runner has `mate` submit a newer revision first. The last two were checked against a build with the protection switched off, and fail there |
| 16-18 Connection settings and workspace switching | Screenshot | dialogs in `gui-dialogs`; `connection-dialogs`, `connection-store` offline |
| 19, 34-36 Resolve | Automated | `submit-behind-live`, `resolve-live`; dialogs captured in `gui-dialogs` |
| 20-22 Progress window, cancel | Automated | `submit-slow-trigger-live`, `submit-cancel`, `get-latest-cancel` (40 files of 3 MB synced away first); the window is captured in `gui-windows` |
| 23 Delta transfer of a large binary | Next | needs a `binary+F` file of a few MB in the live project |
| 24 Diff of an unopened changed file | Automated | `file-actions-live`; the window is captured for an opened file in `gui-windows` |
| 25, 30 Revert: undo a move, an unopened changed file | Automated | `file-actions-live` checks the question's wording |
| 28, 29, 37 Moves: with `.import`, case only, exclusive lock | Automated | `moves-live` |
| 31 A move, then the moved file deleted | Partly | `delete-action` (offline) decides the action; not run live |
| 26, 32 Mark for Add with ignore rules | Automated | `file-actions-live` |
| 27 Expired password | Automated | `password-expired-live` |
| 33 `.godot/` not ignored | Automated | `ignore-check-live` |
| 38 Server certificate changed | Automated | `ssl-fingerprint-live`: the runner trusts a second p4d on an `ssl:` port, then gives it a new certificate (`p4d -Gc`) |
| 39 Diff of a big or binary file | Automated | `diff-limits-live` |
| 40-41 History window | Automated | `history-live`; window in `gui-windows` |
| 42-44 Shelving | Automated | `shelves-live`; Shelves window in `gui-windows` |
| 45-47 Editor menus, Who Changed This Line, changed-line marks | Automated | `editor-menus`, `history-live`; the gutter isn't captured yet |
| 48-51, 53 Watcher and allwrite | Automated | `watch-live`, `allwrite-live` |
| 52 Allwrite offer, once per workspace | Automated | `allwrite-offer-live` lets the startup offers run, including the project.godot one |

Counted: 45 rows automated, 2 partly, 5 with screenshots only, 1 next (23, a delta transfer, needs server configuration to research).
None of the 53 needs a person in principle; the slowest to automate are 23
(large files) and 38 (an SSL test server).

### macOS (9 rows)

All nine need a Mac: launching from the Dock (the PATH problem), Finder,
POSIX permissions after a safe-save, and the Homebrew p4. A macOS CI runner
could run the offline and live suites, but not a Dock launch. Until then a
person runs these.

### README screenshots (10)

Automated. `gui-readme` takes them in a copy of Godot's Skeleton2D demo, in
a realistic state: a teammate's submits in the history, three changelists
(one shelved), a file outside the project, and an edit, a new file and a
deleted file the watcher lists. Each picture is cropped to what its README
section describes. The hero GIF is real: the test types into a script that
isn't checked out, answers the prompt, and saves a frame at each step.

```
DEMO=<the Skeleton2D demo folder> GUI=1 SHOTS=<folder> tools/run-live-tests.sh <godot> gui-readme
uv run --no-project --with pillow python tools/readme-gif.py <folder>/gif docs/images/hero-checkout.gif
```

Then copy the PNGs from `<folder>` into `docs/images/`. `DEMO` copies the
demo's game files into the test project, leaving its addons, Perforce
settings and editor cache behind.

Taking them found six problems, all fixed:

- The submit confirmation listed a file outside the project by its full
  path, where the panel shows `../art/readme.txt`.
- Changelist names were cut at 31 characters (`p4 changes` without `-L`).
- A `.tres` file had no icon, so its row sat out of line with the rest.
- The P4 submenus offered Check Out and Mark for Add on a file already
  checked out, and Revert on one that isn't. These items are greyed out now.
- Some dialogs were titled only "Check Out" or "P4 Login", which doesn't say
  which plugin is asking. Every title now starts with "P4Godot".
- Every plugin window had Godot's default grey behind it. That looks fine
  in the dark theme, but the light theme put dark text on dark grey.
