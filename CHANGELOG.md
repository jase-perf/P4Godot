# Changelog

Notable changes to P4Godot. Versions before 0.5.0 predate this repository.

## Unreleased

- Renamed the plugin to **P4Godot** (P4G for short). The addon folder is now
  `addons/p4godot` and the dock tab reads **P4G**.
- Packaging for the Godot Asset Store: source archives now contain only the
  addon folder, and copies of the license and readme ship inside it.

## 0.13.0 — 2026-08-20

- Checkout prompts (checkout-on-edit and the failed-save rescue) gained a
  dropdown to pick the target pending changelist (`p4 edit -c N`).
- Saves never stall or error on read-only files: a pre-write pass backs up
  each tracked read-only file and makes it briefly writable, restores
  unchanged files byte-for-byte, and checks out changed files right after
  the save.
- No-change saves of read-only files no longer prompt: the failed safe-save
  `.tmp` is compared against disk (CRLF-tolerant), Godot's "Unable to write"
  and "Load Errors" modals are dismissed, and leftover `.tmp` files are
  deleted.
- Diff viewer: next/previous change navigation, a changes-only mode, and
  higher-contrast colors.

## 0.12.0 — 2026-08-19

- Side-by-side p4merge-style diff viewer: depot revision vs. workspace with
  aligned rows, line numbers, full-row add/delete backgrounds, intraline
  changed-span highlighting, and synced scrolling.
- The dock toolbar wraps to two rows when the dock is narrow.
- The Revert Unchanged confirmation lists the affected files.

## 0.11.0 — 2026-08-19

- Guided connection setup: detects what's missing (server, login,
  workspace), suggests existing workspaces ranked by whether their root
  contains the project, and stores the choice per-project, per-user.
- Automatic re-login prompt when a ticket expires mid-session.
- Drag-and-drop files between changelists.
- Line-ending-tolerant diffs (`p4 diff -dul`), so CRLF/LF differences no
  longer mark every line changed.
- Redesigned single-row toolbar with connection status and a gear settings
  menu.
- Added README, MIT license, and brand assets.

## 0.10.0 — 2026-08-19

- FileSystem dock integration: right-click P4 actions (Check Out, Mark for
  Add, Get Latest, Diff vs Depot, Revert, Show Status in Log), hover status
  tooltips served from a background cache, and delete/move/rename tracking
  with history-preserving moves (`p4 reconcile -m`).
- "Auto add/edit/delete" setting to apply those actions silently.

## 0.9.0 — 2026-07-22

- File diff viewer: `p4 diff -du` rendered in a colored diff window.
- Warn before Reload; Verbose log toggle.

## 0.8.0 — 2026-07-22

- Activity log records every p4 command and its output.
- Toolbar buttons act on the tree selection; reverts confirm by file name.
- Ctrl+Enter accepts text-entry dialogs.
- Edit the default changelist (promotes to a numbered one); delete empty
  changelists.
- Revert Unchanged skips files open in the editor, protecting unsaved
  in-memory edits.

## 0.7.0 — 2026-07-21

- Changelist tree as the main dock view: pending changelists with the files
  opened in each, and a per-row right-click menu.
- Create, edit, move-to, and submit changelists.
- Reconcile and Revert Unchanged.
- Log moved into a separate on-demand window.
- P4 brand accent colors over Godot's native theme.

## 0.5.0 — 2026-07-21

- First version in this repository: checkout-on-edit and checkout-on-save
  prompts, the failed-save rescue dialog, and all p4 commands running on a
  background worker thread.
