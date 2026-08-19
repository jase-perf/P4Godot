<!-- 📷 HEADER IMAGE: your custom header goes here.
     Suggested file: docs/images/header.png (or header.gif).
     The official P4 logos are in docs/images/ if you want them in the composition:
       p4-logo-light.svg / p4-logo-dark.svg (wordmark), p4-icon-light.svg / p4-icon-dark.svg (mark only).
     For a theme-aware header, use the <picture> pattern:
     <picture>
       <source media="(prefers-color-scheme: dark)" srcset="docs/images/header-dark.png">
       <img src="docs/images/header-light.png" alt="P4 for Godot" width="600">
     </picture>
-->

# P4 for Godot

Perforce (Helix Core) integration for the Godot 4 editor. Pure GDScript, no
build step: install the addon, enable it, and Godot starts checking out files
the moment you edit them.

Works with your existing `p4` command-line client and inherits its
configuration — P4CONFIG, tickets, and SSO all work exactly as they do in your
terminal.

<!-- 📷 HERO GIF: the signature loop, captured in one take —
     edit a file in the editor → checkout prompt appears → accept → the file
     shows up under the default changelist in the P4 dock.
     Suggested file: docs/images/hero-checkout.gif -->

## Features

### Automatic checkout

- Offers to check out a file the moment you first modify it in the editor.
- Checks out edited files automatically right before the editor saves them.
- Rescues failed read-only saves with a check-out-and-retry dialog.
- Works in `allwrite` workspaces: if a save succeeds on a file that is not
  checked out, the file is checked out right after, so the changelist stays
  truthful.

### Changelist dock

The P4 dock shows your pending changelists and the files opened in each.
From there you can:

- **Create, edit, submit, and delete changelists** — the default changelist
  promotes to a numbered one on first edit.
- **Move files between changelists** from the right-click menu.
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
FileSystem dock. Unified diffs render in a dedicated window with colored
additions, deletions, and hunk headers.

<!-- 📷 SCREENSHOT: the diff window on a file with a few added and removed
     lines visible. Suggested file: docs/images/diff-viewer.png -->

### Built for slow servers

Every p4 command runs on a background worker thread, so a slow or unreachable
server never freezes the editor. The activity log window records every
state-changing command and its output; a Verbose toggle adds the read-only
status probes when you need to troubleshoot.

## Requirements

- **Godot 4.7+**
- **The `p4` command-line client**, installed and on your `PATH`
  ([download from Perforce](https://www.perforce.com/downloads/helix-command-line-client-p4))
- A Perforce workspace that contains your Godot project, with your login
  ticket valid (`p4 login`). The plugin runs `p4` from the project directory,
  so per-directory `P4CONFIG` files resolve the right server and client
  automatically.

## Installation

1. Copy the `addons/p4_plugin` folder into your project's `addons/` directory
   (create it if it doesn't exist).
2. In Godot, open **Project → Project Settings → Plugins** and enable
   **P4 Perforce Integration**.
3. The **P4** dock appears at the bottom of the editor. If `p4 info` resolves
   your workspace, you're done — edit a file and watch it get checked out.

## Settings

All settings live in the P4 dock toolbar and are stored per-project,
per-user — never written into project files, so they don't churn version
control.

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

- **"Perforce unavailable"** — the startup `p4 info` failed. Check that `p4`
  is on your PATH and `p4 info` works from your project directory in a
  terminal. The P4 Log window (toolbar → **Log**) shows the exact error.
- **Wrong client or user** — the plugin uses whatever `p4 info` reports from
  the project directory. A `P4CONFIG` file in the workspace root is the most
  reliable way to pin the right server/client per project.
- **Something unexpected happened** — turn on **Verbose log** and repeat the
  action; the log shows every command and its full output.

## License

Code is licensed under the [MIT License](LICENSE).

The Perforce and P4 names and logos are trademarks of Perforce Software, Inc.,
used here to identify the product this plugin integrates with. This is a
community plugin, not an official Perforce product.
