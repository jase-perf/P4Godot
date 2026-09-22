
<p align="center">
  <img src="docs/images/header.jpg" alt="The Perforce bee and Godot robot plushes in front of the Godot editor" width="850">
</p>

# P4Godot

P4Godot (P4G for short) connects the Godot 4 editor to Perforce P4 (formerly
Helix Core). Edit a file and Godot offers to check it out. Save, and the
changelist stays accurate. Submit, diff, and reconcile without leaving the
editor. It is pure GDScript with no build step, and it drives the `p4`
command-line client you already use.

**Status: 0.14.0, the first public release.** Developed and tested on
Windows 11 with Godot 4.7 and a P4 2025.2 server. It is designed to work on
macOS and Linux too, but those platforms have had less testing. Please
[open an issue](https://github.com/jase-perf/P4Godot/issues) if something
misbehaves.

<!-- 📷 HERO GIF: the signature loop, captured in one take —
     edit a file in the editor → checkout prompt appears → accept → the file
     shows up under the default changelist in the P4G dock.
     Suggested file: docs/images/hero-checkout.gif -->

## Quick start

1. **Install the `p4` command-line client.**
   - Windows: it comes with P4V. You can also get it on its own from
     [perforce.com](https://www.perforce.com/downloads/helix-command-line-client-p4).
   - macOS: `brew install --cask p4`, or download it from the same page.
   - Linux: use Perforce's packages or the download page.
2. **Add the plugin to your project.** Download `p4godot-v0.14.0.zip` from the
   [latest release](https://github.com/jase-perf/P4Godot/releases/latest) and
   extract it into your project folder. You should end up with
   `addons/p4godot/` next to `project.godot`.
3. **Enable it.** In Godot, open **Project → Project Settings → Plugins** and
   tick **P4Godot**.
4. **Connect.** The **P4G** dock appears at the bottom of the editor. If `p4`
   already knows which workspace holds this project, you're done. Otherwise a
   short setup asks for whatever is missing: the server address, your login,
   or which workspace to use.

Now edit a scene or script. P4Godot offers to check it out the moment you
change it.

## Setting up a Godot project in Perforce

These steps apply to any Godot project under Perforce, with or without the
plugin.

**Put the project inside a workspace.** The workspace root can be the project
folder or any folder above it.

**Keep `.godot/` out of the depot.** It is Godot's local cache and per-user
editor state, including the connection choice P4Godot stores for this
project. Commit everything else, including `*.import` and `*.uid` files: they
hold import settings and resource IDs your teammates need. A starting
`.p4ignore` for the project root:

```
# Godot's local cache and per-user editor state
.godot/
# Temporary files from interrupted saves
*.tmp
```

Check that Perforce reads it: `p4 ignores -i .godot/x` should print a line
ending in `ignored`. If it doesn't, run `p4 set P4IGNORE=.p4ignore` once.

**Consider these filetypes** (your server admin sets them with `p4 typemap`).
Binary art can't be merged, so exclusive checkout (`+l`) stops two people from
editing the same file. P4Godot then shows who holds the lock the moment you
try to edit it. `project.godot` gets rewritten by Godot at startup, so make it
always-writable (`+w`), the way Unreal projects treat `.uproject`:

```
TypeMap:
	binary+l //....png
	binary+l //....psd
	binary+l //....blend
	binary+l //....glb
	binary+l //....wav
	text+w //....godot
```

Adjust the list to your asset types. `.tscn`, `.tres`, `.gd`, and `.import`
files are text, and the defaults suit them.

## Features

### Automatic checkout

- Offers to check out a file the moment you first modify it in the editor. A
  dropdown in the prompt picks the pending changelist, and it defaults to the
  default changelist.
- Checks out edited files automatically right before the editor saves them.
- If a save fails because a file is read-only, offers to check it out and
  save again, with the same changelist dropdown.
- In `allwrite` workspaces, a file saved while not checked out is checked
  out right after the save if the save changed it. An untouched Ctrl+S
  opens nothing.

### Read-only files, handled

In a standard workspace, files you haven't checked out are read-only. Godot
rewrites files whether or not anything changed: every open scene and its
resources on each save, and every reimported asset's `.import` file. Without
help, that makes Godot stall for seconds, log "Safe save failed", and leave
`.tmp` files behind. A fresh sync of a project with no `.godot/` folder hits
this for every asset.

P4Godot makes those files writable just long enough for Godot's write:

- Files whose content didn't change go back to read-only and are not
  checked out.
- Files that did change are checked out, so the changelist matches the disk.
  If a reimport changes more than 20 `.import` files at once (usually after
  a Godot upgrade), P4Godot asks before checking them out.
- If Perforce refuses a checkout, for example because someone else holds an
  exclusive lock, the saved file stays on disk and writable, so a sync can't
  overwrite it. P4Godot tells you it isn't in a changelist yet.

### Guided connection setup

If the project doesn't already resolve to a Perforce workspace, a short setup
flow opens at startup and asks only for what's missing:

- **Server address**, if none is configured.
- **Server trust**, the first time you connect to an `ssl:` server. P4Godot
  shows the fingerprint so you can compare it with the one your admin gave
  you.
- **Login**, if your ticket is missing or expired. If the ticket expires
  mid-session, a re-login prompt appears right away.
- **Workspace**, suggested from your existing workspaces on the server,
  ranked by whether their root contains this project.

Your choices are stored per project and per user, and passed to `p4` as
command-line flags. Your terminal, P4V, and other projects are unaffected.

<!-- 📷 SCREENSHOT (optional): the workspace-suggestion dialog from connection
     setup. Suggested file: docs/images/connection-setup.png -->

### Changelist dock

The P4G dock shows your pending changelists and the files opened in each.
From there you can:

- **Create, edit, submit, and delete changelists.** Editing the default
  changelist's description turns it into a numbered changelist.
- **Drag and drop files between changelists**, or move them from the
  right-click menu.
- **Diff, revert, sync, and reload** individual files.
- **Reconcile** the project to find edits, adds, and deletes made outside
  the editor.
- **Revert Unchanged** to clean up files with no actual edits. Files open in
  the editor are skipped, so unsaved changes are never lost.

<!-- 📷 SCREENSHOT: the P4 dock with two or three changelists expanded, a few
     files with different actions (add/edit/delete show in different colors),
     and the right-click context menu open on a file row.
     Suggested file: docs/images/changelist-dock.png -->

Submitting always shows a confirmation that lists the files and the
description first. The list is fetched from the server when you press
Submit, and exactly those files are submitted.

<!-- 📷 SCREENSHOT: the submit confirmation dialog listing files + description.
     Suggested file: docs/images/submit-confirm.png -->

### FileSystem dock integration

- **Right-click P4 actions** on any file: Check Out, Mark for Add, Get Latest
  (Sync), Diff vs Depot, Revert, and Show Status in Log. Checking out an
  imported asset also checks out its `.import` file, which holds its import
  settings.
- **Hover tooltips** show each file's Perforce status: the revision you have
  vs. head, any pending action, and who else has it checked out. They are
  served from a cache, so hovering never waits on the server.
- **Delete, move, and rename tracking.** Deleting a file offers to open it
  for delete. Moving or renaming offers to record a history-preserving move
  (`p4 reconcile -M`). The `.import` and `.uid` files Godot moves along with
  an asset are recorded too. These actions prompt by default, or apply
  silently with the "Auto add/edit/delete" setting.

<!-- 📷 SCREENSHOT: the FileSystem dock with the P4 context menu open on a file,
     and (second shot or same composition) a hover tooltip showing
     "//depot/...#3 (head #5 - out of date) opened for edit".
     Suggested file: docs/images/filesystem-dock.png -->

### Diff viewer

Diff any file against the depot from the dock, the changelist tree, or the
FileSystem dock. A side-by-side window shows the depot revision on the left
and your workspace file on the right, with line numbers, aligned rows, and
colored change bands. Within a changed line, the exact span that differs is
highlighted. Line-ending differences are ignored, because Godot writes LF
while Windows workspaces usually sync CRLF.

<!-- 📷 SCREENSHOT: the diff window on a file with a few added and removed
     lines visible. Suggested file: docs/images/diff-viewer.png -->

### Runs in the background

p4 commands run on a background thread, so the editor stays responsive
while the server works. The one exception is the checkout right before a
save, which has to finish before Godot writes. The activity log window
records every state-changing command and its output, and the Verbose toggle
adds the read-only status queries.

## Requirements

- **Godot 4.7 or later.**
- **The `p4` command-line client.** P4Godot looks for it on your `PATH`,
  then in the usual install locations: `C:\Program Files\Perforce` on
  Windows, and Homebrew's folders on macOS. Apps launched from the macOS Dock
  don't see your shell's `PATH`, which is why the fallback exists. To use a
  different copy, set **Editor Settings → P4godot → P4 Executable**.
- **A Perforce workspace that contains your Godot project.** P4Godot uses
  your existing p4 configuration: `P4CONFIG` files, values saved with
  `p4 set`, and login tickets. On macOS, variables exported in a shell
  profile don't reach apps launched from the Dock, so use `p4 set` or the
  setup prompts instead.

## Settings

The gear menu on the P4G dock toolbar holds these settings. They are stored
per project and per user, and never written into project files.

| Setting | Default | What it does |
| --- | --- | --- |
| Checkout on edit | on | Offer to check out a file the moment it is first modified. |
| Checkout on save | on | Check out edited files right before the editor writes them, and handle read-only files around saves (see [Read-only files, handled](#read-only-files-handled)). When off, a save to a read-only file fails and the rescue dialog asks what to do. |
| Auto add/edit/delete | off | Open edits, deletes, and moves in Perforce silently, with no confirmation dialogs. |
| Verbose log | off | Also log read-only status queries (fstat/opened/where/changes). |

One setting lives in **Editor Settings → P4godot** because it applies to
every project: **P4 Executable**, the full path to `p4` if P4Godot can't
find it on its own.

## Known limitations

- **Declining a checkout on a scene reloads the whole scene**, which discards
  all unsaved changes in it. Godot gives plugins no way to cancel the save of
  a single file.
- **Edits made outside the editor aren't detected automatically.** Use
  **Reconcile** to pick them up. The same applies to `project.godot`, which
  Godot writes without telling plugins.
- **Changing import settings on an asset that isn't checked out fails.** The
  Import dock writes the `.import` file before any plugin can step in. Check
  out the asset first (right-click → **P4: Check Out**, which takes its
  `.import` along), then change its settings.
- **New empty files aren't added automatically**, because Godot doesn't
  announce them. They are added when first saved, or by Reconcile.
- **File names containing `@`, `#`, `%`, or `*`** aren't escaped for
  Perforce yet, so P4 actions on them fail.
- **No timeouts on p4 commands.** If the server stops responding in the
  middle of a command, the dock waits for it, and a save that needs a
  checkout waits too.
- **Single sign-on:** the login prompt asks for a password. With SSO, log in
  once with `p4 login` or P4V, and P4Godot uses that ticket.
- **Shelving** isn't implemented yet.

## Troubleshooting

- **"Not connected" in the toolbar.** Click it, or press Refresh, to rerun
  connection setup. It names what's missing. The P4 Log window (toolbar →
  **Log**) shows the exact error.
- **"Couldn't find the p4 command-line client."** Install `p4` (see
  [Quick start](#quick-start)) and press Refresh. If it's installed somewhere
  unusual, set **Editor Settings → P4godot → P4 Executable** to its full
  path.
- **Wrong workspace or user.** Click the connection status in the toolbar and
  pick a different workspace. The choice is stored per project. A
  `P4CONFIG` file in the workspace root works too, and needs no plugin
  setup.
- **A Load Error writing `project.godot` when the project opens.** Godot
  sometimes rewrites `project.godot` at startup (version stamps, plugin
  state), which fails while the file is read-only. Give it the
  always-writable filetype once with
  `p4 edit -t text+w project.godot`, then submit. See the typemap above to
  make it the default for new projects.
- **Something else.** Turn on **Verbose log** and repeat the action. The log
  shows every command and its full output. Please include it when you
  [open an issue](https://github.com/jase-perf/P4Godot/issues).

## Development

Everything lives in `addons/p4godot/p4godot.gd`. The plugin has built-in
self-tests, run headless:

```
godot --headless --editor --path <project> -- --p4-selftest-<name>
```

Server-independent tests include `save-guards`, `prewrite`,
`unchanged-save`, `exec-quoting`, `parse-ztag`, `diff-align`, and
`dismiss-dialog`. Live tests such as `list-opened` and `create-changelist`
need a workspace. Each test logs a `[selftest] PASS: <name>` or
`[selftest] FAIL: <name>` line. See `_run_cli_self_test_if_requested` for
the full list.

## License

The code is licensed under the [MIT License](LICENSE).

The Perforce and P4 names and logos are trademarks of Perforce Software, Inc.,
used here to identify the product this plugin integrates with. This is a
community plugin, not an official Perforce product.
