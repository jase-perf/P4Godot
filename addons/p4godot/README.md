
<p align="center">
  <img src="docs/images/header.jpg" alt="The Perforce bee and Godot robot plushes in front of the Godot editor" width="850">
</p>

# P4Godot

P4Godot (P4G for short) is a Perforce P4 (formerly Helix Core) integration for the Godot 4 editor. Pure GDScript, no build step: install the addon, enable it, and Godot starts checking out files the moment you edit them.

Works with your existing `p4` command-line client and inherits its configuration — P4CONFIG, tickets, and SSO all work exactly as they do in your terminal.

<!-- 📷 HERO GIF: the signature loop, captured in one take —
     edit a file in the editor → checkout prompt appears → accept → the file
     shows up under the default changelist in the P4G dock.
     Suggested file: docs/images/hero-checkout.gif -->

## Features

### Automatic checkout

- Offers to check out a file the moment you first modify it in the editor —
  and the prompt has a dropdown to pick which pending changelist to open it
  in (defaults to the default changelist).
- Checks out edited files automatically right before the editor saves them.
- Rescues failed read-only saves with a check-out-and-retry dialog, with the
  same changelist dropdown.
- **Saves never stall or error on read-only files.** Godot rewrites files on
  every save whether or not anything changed, and writing to a read-only
  file fails slowly (a multi-second retry stall) and loudly ("Unable to
  write to file"). The plugin instead backs up each tracked read-only file
  right before the save and makes it briefly writable, so the write succeeds
  instantly. Files the save didn't actually change are put back exactly as
  they were — original bytes, read-only bit, Perforce untouched. Files that
  did change are checked out right after the save, keeping the changelist
  truthful; if Perforce refuses that checkout, the disk is restored from the
  backup and your changes stay safe in the editor.
- Works in `allwrite` workspaces: if a save succeeds on a file that is not
  checked out, the file is checked out right after, so the changelist stays
  truthful.

### Guided connection setup

No P4CONFIG, no environment variables, no manual configuration required. If
the project doesn't already resolve to a Perforce workspace, a short setup
flow opens at startup and asks only for what's actually missing:

- **Server address**, if none is configured.
- **Login**, if your ticket is missing or expired — and if your ticket
  expires mid-session, a re-login prompt appears right away instead of
  commands quietly failing.
- **Workspace**, suggested from your existing clients on the server, ranked
  by whether their root contains this project — confirm and go.

The choice is stored per-project, per-user and passed to `p4` directly, so
your terminal, P4V, and other projects are untouched.

<!-- 📷 SCREENSHOT (optional): the workspace-suggestion dialog from connection
     setup. Suggested file: docs/images/connection-setup.png -->

### Changelist dock

The P4G dock shows your pending changelists and the files opened in each.
From there you can:

- **Create, edit, submit, and delete changelists** — the default changelist
  promotes to a numbered one on first edit.
- **Drag and drop files between changelists**, or move them from the
  right-click menu.
- **Diff, revert, sync, and reload** individual files.
- **Reconcile** the project to find offline edits, adds, and deletes.
- **Revert Unchanged** to clean up files with no actual edits — files open in
  the editor are skipped, so unsaved in-memory changes are never lost.

<!-- 📷 SCREENSHOT: the P4 dock with two or three changelists expanded, a few
     files with different actions (add/edit/delete show in different colors),
     and the right-click context menu open on a file row.
     Suggested file: docs/images/changelist-dock.png -->

Submitting always shows a confirmation that lists the exact files and the
description before anything reaches the server.

<!-- 📷 SCREENSHOT: the submit confirmation dialog listing files + description.
     Suggested file: docs/images/submit-confirm.png -->

### FileSystem dock integration

The Godot FileSystem dock gets native Perforce hooks:

- **Right-click P4 actions** on any file: Check Out, Mark for Add, Get Latest
  (Sync), Diff vs Depot, Revert, and Show Status in Log.
- **Hover tooltips** show each file's Perforce status — revision you have vs.
  head, pending action, and who else has it checked out — served from a cache
  so hovering never stalls the editor.
- **Delete / move / rename tracking**: deleting a file offers to open it for
  delete; moving or renaming offers to record a history-preserving move
  (`p4 reconcile -m`). Prompts by default, or silent with the
  "Auto add/edit/delete" setting.

<!-- 📷 SCREENSHOT: the FileSystem dock with the P4 context menu open on a file,
     and (second shot or same composition) a hover tooltip showing
     "//depot/...#3 (head #5 - out of date) opened for edit".
     Suggested file: docs/images/filesystem-dock.png -->

### Diff viewer

Diff any file against the depot from the dock, the changelist tree, or the
FileSystem dock. A p4merge-style side-by-side window shows the depot revision
on the left and your workspace file on the right, with line numbers, aligned
rows, colored change bands — and within a changed line, the exact span that
differs is highlighted, so a one-digit change in a 4000-line scene reads at a
glance. Line-ending differences are ignored (Godot writes LF; Windows
workspaces usually sync CRLF), so diffs show only real changes.

<!-- 📷 SCREENSHOT: the diff window on a file with a few added and removed
     lines visible. Suggested file: docs/images/diff-viewer.png -->

### Built for uninterrupted work

Every p4 command runs on a background worker thread, so a slow or unreachable
server never freezes the editor. The activity log window records every
state-changing command and its output; a Verbose toggle adds the read-only
status probes when you need to troubleshoot.

## Requirements

- **Godot 4.7+**
- **The `p4` command-line client**, installed and on your `PATH`
  (On Windows this is installed by default along with P4V. If you need to download it separately, you can [download from Perforce](https://www.perforce.com/downloads/helix-command-line-client-p4))
- A Perforce workspace that contains your Godot project. Existing
  configuration (`P4CONFIG`, tickets, SSO) is picked up automatically; if
  anything is missing, the built-in connection setup asks for it on first
  run.

## Installation

1. Copy the `addons/p4godot` folder into your project's `addons/` directory
   (create it if it doesn't exist).
2. In Godot, open **Project → Project Settings → Plugins** and enable
   **P4Godot**.
3. The **P4G** dock appears at the bottom of the editor. If `p4 info` resolves
   your workspace, you're done — edit a file and watch it get checked out.
   Otherwise the connection setup flow opens and walks you through server,
   login, and workspace.

## Settings

All settings live in the gear menu on the P4G dock toolbar and are stored
per-project, per-user — never written into project files, so they don't
churn version control.

| Setting | Default | What it does |
| --- | --- | --- |
| Checkout on edit | on | Offer to check out a file the moment it is first modified. |
| Checkout on save | on | Automatically check out edited files right before the editor writes them. |
| Auto add/edit/delete | off | Open edits, deletes, and moves in Perforce silently, with no confirmation dialogs. |
| Verbose log | off | Log read-only status probes (fstat/opened/where/changes) in addition to state-changing commands. |

## Known limitations

- Declining a checkout on a **scene** reloads the whole scene, discarding all
  unsaved changes in it — Godot gives the plugin no way to cancel just one
  file's save.
- Edits made **outside the editor** (and writes to `project.godot`) are not
  auto-detected — use **Reconcile** to pick them up.
- New empty files are not auto-added (Godot emits no create signal); they are
  added when first saved, or via Reconcile.
- Shelving is not implemented yet.

## Troubleshooting

- **"Not connected" in the toolbar** — click it (or press Refresh) to rerun
  connection setup; it names what's missing. The P4 Log window (toolbar →
  **Log**) shows the exact error.
- **Wrong client or user** — click the connection status in the toolbar and
  pick a different workspace; the choice is stored per-project. A `P4CONFIG`
  file in the workspace root works too and needs no plugin configuration.
- **Load Error writing `project.godot` when opening the project** — Godot
  sometimes rewrites `project.godot` at startup (version stamps, plugin
  state), which fails while the file is read-only under Perforce. The fix is
  Perforce's always-writable filetype, the same one Unreal projects use for
  `.uproject`: run `p4 edit -t text+w project.godot` once and submit it, and
  ask your server admin to add `text+w //....godot` to `p4 typemap` so new
  Godot projects get it automatically. Pick up any startup edits later with
  **Reconcile**.
- **Something unexpected happened** — turn on **Verbose log** and repeat the
  action; the log shows every command and its full output.

## License

Code is licensed under the [MIT License](LICENSE).

The Perforce and P4 names and logos are trademarks of Perforce Software, Inc.,
used here to identify the product this plugin integrates with. This is a
community plugin, not an official Perforce product.
