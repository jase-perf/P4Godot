# Changelog

Notable changes to P4Godot. Versions before 0.5.0 predate this repository.

## Unreleased

- **P4Godot checks that Perforce skips Godot's `.godot` folder.** At
  startup, if no ignore rule covers it, P4Godot offers to add `.godot/` to
  the ignore file - checking the file out, or creating it. It also notices
  when this computer's `P4IGNORE` setting names a different file, which
  silently puts the project's `.p4ignore` out of force, and says so.
- **The automatic check for changes made outside Godot is faster on large
  projects.** It now reads a file's content only when its modification time
  has changed, where it used to read every file each time. The
  **Reconcile...** button still compares everything.
- **A moved file keeps its history even when you also changed it.** Moves
  are now recorded by naming both paths to Perforce (`p4 edit` +
  `p4 move -k`). Before, Perforce was left to match the old and new file by
  content, and for a binary file that had been moved and changed it recorded
  a delete and an unrelated add.
- **A rename that only changes capital letters is explained.** A server
  that ignores case can't record `Hero.png` → `hero.png`; it refused without
  an error and the rename stayed on your disk only. P4Godot now says so, why
  it matters on macOS, Linux and in exports, and how to do it in two steps.
- **Submit names out-of-date files before sending anything.** If a teammate
  submitted a newer version of a file in your changelist, the dialog lists
  those files and what to do, before it asks for a description. It used to
  be the server's refusal after the fact.
- **Diff vs Depot no longer calls a changed file identical.** For a file
  changed on disk but not checked out - the files Reconcile finds - the
  dialog said it was identical to the server's version. It now shows the
  differences. The same wrong answer came up with an external diff tool
  configured (`P4DIFF`), and for a file deleted from disk; both fixed. A
  file that isn't on the server yet says so, and an answer from Perforce
  that P4Godot can't read is reported as such instead of as "identical".
- **Reverting a moved file undoes the move.** Reverting the old path of a
  move used to do nothing and say nothing: Perforce refuses it without
  reporting an error. Reverting either path now asks "Undo the move of A to
  B?" and puts the file back, together with its `.import` or `.uid`.
- **Revert works on a file that isn't checked out.** If it was changed or
  deleted on your computer, Revert offers to put back the version you
  downloaded. If it matches, it says there is nothing to throw away.
- **Deleting a file you had just moved** now marks the original for delete.
  It used to bring the file back under its old name.
- **Mark for Add explains itself.** A file your ignore rules leave out used
  to be skipped silently; now a message names the rule. A file already in
  Perforce says so. Adding several files gives one summary.
- **An expired password can be changed inside Godot.** When the server
  refuses everything because your password has expired, or an admin asked
  for it to be changed, P4Godot asks for the current password and a new one,
  changes it and logs you in. Before, every action failed with the server's
  message in the Log and nothing else, and the login prompt could not get
  past it.
- For contributors: `tools/run-live-tests.sh` starts a throwaway Perforce
  server on this machine (`tools/p4-test-server.sh`, a pinned `p4d` download
  checked against Perforce's published checksum) and runs the tests that need
  a real server there, as an ordinary user. This includes two cases that had
  never been run: a submit that waits at a slow server trigger, and Cancel
  pressed after every file was sent - the server finishes that submit
  alone, and P4Godot reports "too late to cancel" with the change number.

- **Submit and Get Latest show their progress, and can be cancelled.** A
  window shows how many files and how much data have moved, the file in
  hand, and the time taken. It isn't modal: the editor stays usable, and
  closing the window leaves the transfer running.
  - It works when the server transfers files in parallel, which is where
    `p4`'s documented progress option goes silent. P4Godot uses the same
    progress reporting P4V does (`p4 --progress=debug`, in clients from 2021.1
    on); with an older `p4` the bar shows activity without a percentage.
  - **No more time limit on a transfer.** `p4` used to be given up on after
    2 minutes of silence (10 for a submit). A long submit or download now runs
    as long as it needs. If nothing has been reported for a minute the window
    says so, says that isn't a failure, and leaves the choice to you.
  - **Cancel on a submit** stops `p4`, then reports what the server says
    happened: cancelled in time, or too late and already submitted. When a
    file was part-way up, that takes a few seconds. It needs no special
    access on the server; all of this was tested as an ordinary user.
  - **Cancel on Get Latest** stops the download and removes the unfinished
    files it leaves behind. Left alone, those empty files made every later
    download refuse them. Files that had finished are kept and reloaded.
  - Files sent by Delta Transfer (`binary+F`, where only the changed parts
    travel) report in different units, or not at all on a download; the bar
    handles both and fills in at the end.
  - When the server reports it, the Log (for a submit) or the final report
    (for Get Latest) says how much data crossed the network, and notes when
    that is well under the size of the files. The server doesn't report it
    for parallel transfers.
  - Closing the editor during a transfer leaves `p4` running to finish, where
    it used to wait for it.
  - If you close the progress window, a **Transfer running...** button in the
    P4G toolbar brings it back, since the window holds the only Cancel.
  - One transfer at a time: starting a submit while a download runs (or the
    reverse) is refused with an explanation.

- **Get Latest and Sync This File can no longer overwrite an edit Perforce
  doesn't know about.** They ran a plain `p4 sync`, which replaces any
  read-only file without looking at it. A file can be changed and still
  read-only: on macOS and Linux Godot saves by renaming a temporary file over
  the target, which a read-only target doesn't stop. A plain sync then replaced
  that edit with the server's version and reported only "updating"
  (reproduced on Windows against a 2025.2 server, with a file edited and set
  back to read-only). Both now run `p4 sync -s`, which compares each file with
  the revision you have and leaves a changed one alone.
  - The refused files are named before the download (the preview predicts
    them), in the report afterwards, and when they are the only thing newer on
    the server, where the old answer would have been "already up to date".
  - A file that is unlocked but unchanged used to be reported as "would not
    overwrite" with advice to Reconcile, which found nothing to do, so it
    stayed behind the server for good. Those are now set back to read-only and
    downloaded. The second pass is a safe sync too.
  - Cost: `sync -s` reads every file it is about to replace, once for the
    preview and once for the download.

- **A failed submit no longer says "nothing was sent" without checking.** When
  the connection drops partway through, the server may still finish the
  submit. P4Godot now asks the server what became of the changelist before it
  says anything, and reports one of three things: it was submitted (and as
  which number), it was not, or it can't tell and you shouldn't submit again
  yet.
  - The default changelist is submitted as a numbered changelist carrying your
    description, because the number is what makes the question askable. After
    a refused submit your files are in that changelist, which the message
    names.
  - `p4 submit` no longer has a time limit, so a slow server-side check
    isn't cut off (see the progress entry above).

- **You can change the server, user, or workspace after setup.** The gear menu
  has a new **Connection settings...** item, and the workspace picker shows
  which server and user it is listing workspaces for, with a **Change Server
  or User...** button. Until now the only route back was clicking the
  connection status, which offered the workspace list and nothing else, and a
  P4PORT pointing at another project's server looked the same as having no
  workspace. Emptying a box goes back to your normal Perforce settings.

## 0.15.0 — 2026-09-24

- **New "Get Latest..." button downloads the whole project.** Until now
  P4Godot synced one file at a time, and getting a teammate's work meant
  leaving Godot for P4V. It lists the files and the total size first, then
  downloads, then reloads whatever you had open — an open scene showed the old
  version otherwise, and saving it later would have overwritten the work just
  downloaded. Scoped to the Godot project, not the whole workspace.

  Two outcomes are reported instead of passing silently, because `p4 sync`
  hides both (verified against a 2025.2 server):
  - **A file changed on disk but not checked out.** Perforce refuses to
    overwrite it, which is the point — and that is a state P4Godot creates on
    purpose, since a refused checkout leaves the file writable so a later sync
    can't erase it. `sync -n` predicts nothing, and the failing sync reports
    the file as `action updated` while exiting 1, so counting records alone
    would have claimed the file was downloaded when the user's own version was
    still sitting there. Those files are now named, with the fix: Reconcile
    them, then Get Latest again.
  - **A file you have checked out that someone else changed too.** p4 moves
    your have revision to head and leaves the file alone, emitting no record
    at all — so it silently became a file that couldn't be submitted until it
    was merged. Those files are now named, pointing at P4V's Resolve, since
    P4Godot has no merge of its own. For art it says the part that matters:
    resolving isn't a merge, you keep one version and lose the other.

  Everything the report says comes from what the sync itself printed, never
  from the preview. Counting the preview would have claimed a file downloaded
  when Perforce had refused to overwrite it, and it would have missed a file a
  teammate submitted while the confirmation sat open — whose open tab needs
  reloading just as much. The rest of that pass:
  - A tab left open on a file the sync **deleted** is called out before and
    after. Godot can't close a scene tab, so the tab survives on a file that no
    longer exists, and saving it would put the file back and re-add it to the
    depot — undoing the team's delete from the other direction.
  - Files Godot has **cached but has no tab for** are reloaded too. Closing a
    tab doesn't drop the resource, so reopening it later served the pre-sync
    copy, and saving that overwrote the downloaded work.
  - "Your project is already up to date" is no longer said over the top of a
    message Perforce did give. Anything unrecognised — a permissions refusal on
    part of the tree, say — is reported instead of dropped.
  - A sync that failed for a reason p4 didn't explain says so rather than
    reading as success, and a double-click no longer runs two syncs.
  - Deletions are described as removals rather than downloads, and lines of
    p4's answer that couldn't be read are counted and reported instead of
    silently shortening the list.

- Documentation split by what the reader is actually doing. The README now
  assumes the normal case — the project is already in Perforce and you're
  joining it — and putting a project in for the first time moved to
  `docs/first-time-setup.md`, which does it in P4V. That is a one-time job for
  one person, and no engine integration does it, the Unity and Unreal ones
  included.
- A "What you need" section that repeated the quick start's own list is gone;
  the two facts only it carried (where P4Godot looks for `p4`, and which
  Perforce configuration it reads before asking) moved to the places that
  need them. Notes for people working on the plugin moved to
  `CONTRIBUTING.md`.
- The quick start now starts where a new teammate actually starts: making a
  workspace in P4V and downloading the project. It never said how to do that,
  so every later step assumed a project already on disk.
- Warnings the dialogs give but the page didn't: that Get Latest reloads open
  files and loses unsaved changes in them, that **Discard My Changes** on the
  checkout prompt throws away everything unsaved in the scene rather than just
  your last edit, and that files Reconcile lists as *missing* get deleted for
  the whole team on submit.
- `docs/first-time-setup.md` sets up the `p4` command line before using it.
  P4V keeps its connection settings to itself, so a P4V-only reader hit
  "Connect to server failed" on the page's first command.
- Glossary: added **Resolve** and a short section of Godot words (dock, addon,
  scene, resource, `.import`/`.uid`) for people new to the engine too.
  **Revert** said it gives the file "back to the server", which sounds like
  uploading; it doesn't send anything.

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
