# Changelog

Notable changes to P4Godot. Versions before 0.5.0 predate this repository.

## 0.14.1 — 2026-09-23

- **Plain-English rewrite of the dialogs, aimed at someone who has never used
  version control.** Two of them were misleading rather than merely dense:
  - Reverting a file said it discarded "any unsaved changes". It also throws
    away everything you *saved*, because Perforce puts the file back to the
    server's version. It now says so, and the button reads "Throw Away My
    Changes".
  - The prompt after a sync didn't mention what happens if you keep the
    editor's version: your next save overwrites the teammate's work you just
    downloaded.
  - "Open for Delete" / "Leave in Perforce" read backwards — the second
    sounded like the safe choice while quietly leaving the depot out of step.
    Now "Delete in Perforce" / "Not Yet".
  - "Keep My Changes" / "Discard My Changes" differed by one word on an
    unrecoverable choice. Now "Keep My Edit" / "Throw It Away".
  - Messages that reported a problem without a next step now end in one, and
    "Perforce is unavailable" (six copies that had drifted) is one constant.
- README: says what Perforce *is* before using its vocabulary, and a new
  `docs/glossary.md` covers the words that don't mean what you'd guess —
  "open" means "put in a changelist", "revert" throws work away.
- The `p4 ignores` checks in the README could not be followed. They said the
  answer "should end in `ignored`, not `not ignored`", which is not a usable
  test, and `p4 ignores -i` prints nothing at all when a path isn't ignored.
  Both now use `-i -v`, which says which it is and names the rule.

- **P4Godot checks that it is itself in Perforce**, and offers to add itself
  when it isn't. Godot keeps the enabled-plugin list in `project.godot`,
  which teams do track, so a teammate who syncs a project referencing a
  plugin they don't have sees "Addon failed to load. No directory found.
  Removing from enabled plugins" — and the next project-settings save can put
  that removal in the depot, turning the plugin off for everyone. If ignore
  rules cover the addon folder, it says so instead of offering an add that
  Perforce would skip. Asked once; declining is remembered per project.

- **Reconcile tells you what it found and what it couldn't do.** The
  confirmation now lists the files by name and breaks them down by action,
  and anything Perforce refused is reported instead of swallowed. Refusals
  were invisible before: `p4` reports them on stderr and still exits 0, so
  reconciling a file another user holds with an exclusive (`+l`) lock looked
  like it worked and silently did nothing.
- **A refused file no longer turns into a phantom change that never clears.**
  `p4` reports a refusal as a message whose second line begins with `... `,
  the same way a tagged field does. Read as a field, it became a record with
  no action, which the dock counted as "1 file to edit" that reconciling
  could never open, and it could swallow the fields of the record printed
  after it.
- Reconcile opens exactly the files its confirmation listed, instead of
  re-running over the whole project, where anything that changed while the
  dialog was open would be opened too.
- Reconcile warns before opening files for delete, naming the count. Files
  missing because of an incomplete sync look identical to deleted ones, and
  submitting that removes them from the depot.

- **Changes made outside Godot are detected.** When Godot regains focus,
  P4Godot looks for files that other programs changed and offers to check
  them out, naming any that Perforce refused (usually a `+l` file someone
  else holds). New **Detect external changes** setting, on by default. The
  scan runs on focus only, never on Godot's own filesystem rescans, so
  working normally doesn't put a reconcile on the server every few seconds.
- **Declining a checkout no longer turns checkout off for that file.** The
  decline suppressed re-prompting so a failed reload couldn't prompt on every
  keystroke, but nothing cleared the suppression: the next edit went
  unnoticed until you saved. Suppression now applies only when the reload
  couldn't be confirmed.
- **Reverting a script puts the depot text back in the editor.** It used to
  close the script's tab and leave the edited source in Godot's resource
  cache, so reopening the file served the reverted change straight back. The
  tab now reopens on the file's real contents with your place in it kept.
- A submit or revert done outside Godot (P4V, a terminal) no longer leaves a
  file marked checked out for the rest of the session, which made later edits
  to it skip the checkout. The session's record is rebuilt from `p4 opened`
  on every refresh.

## 0.14.0 — 2026-09-22

First public release.

- Renamed the plugin to **P4Godot** (P4G for short). The addon folder is now
  `addons/p4godot` and the dock tab reads **P4G**. If you used an earlier
  build, re-enable the plugin under its new path.
- **Reimports no longer fail on read-only `.import` files.** Godot rewrites
  every reimported asset's `.import`. In a read-only workspace that logged
  "Safe save failed" and left a `.tmp` file for each asset, and a fresh sync
  hits every asset. Unchanged files now go back to read-only. Changed ones
  are checked out, with a prompt when more than 20 change at once.
- **Saves never roll back.** If Perforce refuses a checkout after a save
  landed, the file stays as saved and writable, and you're told it isn't in
  a changelist. Earlier versions put the old content back on disk, which
  could lose the edit.
- Saves that don't change a read-only file no longer touch it on disk. The
  old copy-back moved its modified time, which could trigger Godot's
  "reload from disk" prompt.
- Shaders open in the shader editor are covered by the read-only save
  handling. Every scene save writes them.
- In `allwrite` workspaces (and with `+w` filetypes), an untouched Ctrl+S no
  longer opens the file. Saves go through `p4 reconcile -e`, which opens only
  real changes.
- FileSystem-dock renames and moves are recorded as real moves (`reconcile
  -M`; earlier versions passed `-m` by mistake and recorded delete + add).
  The `.import` and `.uid` files Godot moves or deletes alongside an asset
  are recorded too.
- FileSystem-dock **P4: Check Out** on an imported asset also checks out its
  `.import`.
- Changing import settings in the Import dock works on assets whose
  `.import` isn't checked out. Godot writes the settings before any plugin
  hook, so P4Godot arms its read-only handling when the Reimport button is
  pressed, and checks the file out if the settings really changed.
- File names containing `@`, `#`, `%`, or `*` (like `icon@2x.png`) work with
  every P4 action. They're escaped for Perforce, and add and reconcile get
  `-f`.
- p4 commands give up on a server that stops answering: 2 minutes in the
  background, 30 seconds right before a save. After a connection failure,
  saves and status checks skip the server for a minute, so a dropped VPN
  costs one wait instead of one per command.
- The default changelist submits exactly the files the confirmation lists.
  They're fetched fresh, and files opened while the dialog is up aren't
  included. Numbered-changelist confirmations list files outside the project
  too.
- macOS and Linux:
  - Arguments containing `$`, backticks, quotes, or backslashes (for example
    in changelist descriptions) are passed to p4 intact.
  - `p4` is found in Homebrew's folders even when Godot is launched from the
    Dock.
  - A missing `p4` is reported as missing instead of "can't reach server".
- New **Editor Settings → Perforce → Executable Path** setting for a `p4` in an
  unusual place.
- First connection to an `ssl:` server shows the fingerprint and offers to
  trust exactly that fingerprint. A changed fingerprint shows a warning
  instead.
- Connection setup asks you to log in before it lists your workspaces.
  Logged out on a first run, it used to say "No workspaces found".
- Clicking the connection status while connected lets you switch to a
  different workspace.
- macOS and Linux: a save that lands on a read-only file while Perforce
  can't be reached is left writable, so a later sync can't silently
  overwrite it.
- Nested resources a scene save writes (a material inside a tileset, for
  example) are covered by the read-only save handling.
- Checkout-on-edit no longer prompts for a scene you didn't edit. Switching
  to a scene tab whose instanced sub-scene had changed could trigger it.
- **Sync This File** reloads the file only if the sync changed it, and asks
  first when the file is open in the editor.
- A failed status query (a network blip) no longer turns off checkout for
  that file for the rest of the session.
- Failed-save `.tmp` files are cleaned up after a successful retry.
- The "Checkout on save" setting now also governs the read-only save
  handling.
- The temporary file that carries your login password to `p4 login` is
  private to your user, and stale ones are removed at startup.
- Packaging: release archives contain only the addon folder, with a copy of
  the license and readme inside it.
- No GDScript warnings at Godot's default warning settings, even with
  warnings enabled for addons.

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
  with history-preserving moves.
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
