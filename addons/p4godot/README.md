
<p align="center">
  <img src="https://raw.githubusercontent.com/jase-perf/P4Godot/main/docs/images/header.jpg" alt="The Perforce bee and Godot robot plushes in front of the Godot editor" width="850">
</p>

# P4Godot

**Use Perforce without leaving the Godot editor.**

Perforce is a version control system: a server that keeps every version of
every file in your game, so a whole team can work on it without overwriting
each other. Game studios use it because it handles big art files well. It
used to be called Helix Core, and you'll see it written as "P4".

P4Godot (P4G for short) brings it into Godot 4. Start changing a file and it
offers to *check the file out* — to tell the server you're working on it.
Everything you've changed collects in a panel at the bottom of the editor,
where you can compare it against the server's copy and send it to your team.
No alt-tabbing to another program.

New to version control? This page assumes you've never used it. Perforce
words that don't mean what you'd guess — *open*, *revert*, *check out* — are
all in the [glossary](docs/glossary.md).

P4Godot is written in GDScript, so there's nothing to compile. Behind the
scenes it runs `p4`, Perforce's command-line program, for you.

<!-- 📷 HERO GIF: the signature loop, captured in one take —
     edit a file in the editor → checkout prompt appears → accept → the file
     shows up under the default changelist in the P4G dock.
     Suggested file: docs/images/hero-checkout.gif -->

## Quick start

Before you start, you need:

- **Godot 4.7 or later.**
- **A Perforce server and an account on it.** P4Godot connects to a server
  that already exists; it doesn't include one. Ask whoever runs it for the
  server address (something like `ssl:perforce.example.com:1666`), your user
  name, and your password. Don't have a server? Perforce is
  [free for up to five users](https://www.perforce.com/products/helix-core) —
  set that up first, then come back.
- **A Godot project inside a Perforce workspace folder**, or the willingness
  to put one there. Step 4 explains what a workspace is.

1. **Install the `p4` command-line client.** To check whether you already
   have it, run `p4 -V` in a terminal. If it prints a version, skip this step.
   - Windows: it comes with P4V. You can also get it on its own from
     [perforce.com](https://www.perforce.com/downloads/helix-command-line-client-p4).
   - macOS: `brew install --cask p4`, or download it from the same page.
   - Linux: download it from the same page.
2. **Add the plugin to your project.** From the
   [latest release](https://github.com/jase-perf/P4Godot/releases/latest),
   download `p4godot-v0.14.1.zip` under **Assets**, not the "Source code"
   zips. It contains an `addons` folder. Copy that folder into your project
   folder, next to `project.godot`, merging it with any `addons` folder you
   already have.
3. **Enable it.** In Godot, open **Project → Project Settings → Plugins**
   and tick **P4Godot**.
   *You should see* a new **P4G** tab at the bottom of the editor.
   Godot records enabled plugins in `project.godot`. If that file is already
   in Perforce and Godot says it can't write it, check it out first — in P4V,
   right-click it → **Check Out**, or run `p4 edit project.godot` — then tick
   the box again.
4. **Connect.** P4Godot needs a *workspace*: Perforce's link between a folder
   on the server and a folder on your disk. The one you want is whichever
   workspace folder contains this project. If the `p4` command line already
   knows it, P4Godot connects by itself; if you've only ever used P4V, it
   asks you to pick. It asks only for what's missing — the server address,
   your password, or the workspace.
   *You should see* your user name and workspace in the P4G toolbar.
5. **Tell Perforce what to ignore — before your first submit.** Godot keeps
   a `.godot/` cache folder that every machine rebuilds for itself, and it
   must stay out of the depot. Save this as `.p4ignore` in your project
   folder:

   ```
   # Godot's local cache and per-user editor state
   .godot/
   # Temporary files from interrupted saves
   *.tmp
   ```

   Then check the rule is working. In a terminal, in your project folder:

   ```
   p4 ignores -i -v .godot/x
   ```

   There is no file called `x` — you're asking Perforce a hypothetical: *if
   one existed there, would you ignore it?* The answer ends in either
   **ignored** (good, and it names the rule that did it) or **not ignored**.
   If you get `not ignored`, run `p4 set P4IGNORE=.p4ignore` and ask again.
   Skip this step and your next submit pushes thousands of cache files to
   the server.
   [More on setting up a project →](#setting-up-a-godot-project-in-perforce)
6. **Share the plugin with your team.** Press **Reconcile** in the P4G dock.
   It finds the new `addons/p4godot/` files and adds them to your changelist;
   submit them along with `project.godot`. This matters —
   [here's why](#keep-the-plugin-itself-in-perforce).

Now edit a scene or script that's already in Perforce. P4Godot offers to
check it out the moment you change it. Files not yet in Perforce get no
prompt: add them with Reconcile.

**Getting your teammates' work.** P4Godot syncs one file at a time
(right-click → **P4: Get Latest (Sync)**). It has no whole-project "get
latest" yet, so use P4V's **Get Latest Revision** on the project folder, or
run `p4 sync` in a terminal. Restart Godot afterwards if scenes or scripts
changed.

## Your first change, start to finish

This is the loop you'll repeat all day. Five steps.

1. **Get everyone else's work first.** In P4V, right-click the project folder
   → **Get Latest Revision**. (P4Godot does this one file at a time, not the
   whole project — see the note above.) If scenes or scripts changed,
   restart Godot.
2. **Change something.** Move a node, edit a script, whatever. The moment you
   do, P4Godot asks whether to check the file out. Say **Check Out**.
   *You should see* the file appear in the P4G panel under **Default
   changelist**.
3. **Work and save normally.** Ctrl+S behaves as it always has. Files you
   change get added to the panel as you go.
4. **Look at what you're about to send.** In the P4G panel, right-click a
   file → **Diff vs Depot** shows exactly what you changed. If you changed
   something by mistake, → **Revert This File** throws your changes away and
   puts the file back to the server's version. That deletes work, so read
   the confirmation.
5. **Send it to the team.** Right-click **Default changelist** →
   **Submit Changelist...**, and type a sentence saying what you did.
   P4Godot shows you the file list before anything is sent.
   *You should see* the files leave the panel. They're on the server now.

If a submit is refused, it's almost always because a teammate changed the
same file first. Get their version (step 1), combine it with yours, and
submit again.

## Keep the plugin itself in Perforce

Put `addons/p4godot/` in the depot, however you installed it.

**Why it matters:** Godot stores the list of enabled plugins inside
`project.godot`, which your team *does* keep in Perforce. If a teammate gets
the project but not the plugin files, Godot quietly drops P4Godot from that
list — and the next time anyone saves project settings, that removal can be
submitted, switching the plugin off for everyone. P4Godot checks for this at
startup and offers to add itself.

Nothing about the plugin needs to be writable at runtime: it keeps its cache
and temporary files in your user cache folder, never inside `addons/`.

Make sure your ignore rules aren't blocking the plugin folder. Run
`p4 ignores -i -v addons/p4godot/x` in your project folder — here you *want*
the answer **not ignored**. Many ready-made `.p4ignore` files for game
projects skip all of `addons/` to avoid build output, which would silently
leave the plugin out of Perforce. If the answer is `ignored`, it names the
rule and the line to change.

### Updating P4Godot to a new version

Tracked files are read-only, so an installer can't overwrite them. Check the
folder out first, whichever way you install:

1. **Check out** `addons/p4godot/` — right-click it in the FileSystem dock →
   **P4: Check Out**, or `p4 edit addons/p4godot/...`.
2. **Install the new version**, from the asset store or by extracting the zip
   over the folder.
3. **Reconcile.** A new version can add or remove files, which a checkout
   alone doesn't cover.
4. **Revert Unchanged**, so the changelist holds only what really changed.
5. **Submit.** Everyone else gets it on their next sync; they should restart
   Godot afterwards.

One person does this for the team. On macOS and Linux an installer can
replace a read-only file, so if you forget step 1 the files end up changed
but not checked out — the focus-in scan offers them on your next alt-tab. On
Windows the install fails instead, which is at least obvious.

## Setting up a Godot project in Perforce

These steps apply to any Godot project under Perforce, with or without the
plugin. Do them in order: the ignore file and the typemap only affect files
added after them.

**1. Put the project inside a workspace.** A workspace is Perforce's link
between the server and one folder on your computer, called its *root*. Your
project folder has to be that root, or inside it. If you don't have a
workspace yet, the easiest way is P4V → **Connection → New Workspace**. (The
command-line equivalent, `p4 client`, opens a form in a terminal text editor
— on macOS and Linux that's usually `vi`, which is hard to escape if you
haven't met it. Use P4V unless you're comfortable there.)

**2. Keep `.godot/` out of the depot.** It is Godot's local cache and
per-user editor state, including the connection choice P4Godot stores for
this project. Submit everything else, including `*.import` and `*.uid` files:
they hold import settings and resource IDs your teammates need. Save this as
`.p4ignore` in the project folder:

```
# Godot's local cache and per-user editor state
.godot/
# Temporary files from interrupted saves
*.tmp
```

Then check it in a terminal, in the project folder:

```
p4 ignores -i -v .godot/x
```

`x` isn't a real file — you're asking whether a file there *would* be
ignored. The answer says either **ignored** (and names the rule) or **not
ignored**. If you get `not ignored`, run `p4 set P4IGNORE=.p4ignore`, which
tells `p4` what your ignore file is called, and ask again.

Ignore rules only stop files being *added*. If `.godot/` is already in the
depot, take it out with `p4 delete -k .godot/...` and submit. The `-k` keeps
your local copy of the files while removing them from the server.

**3. Set filetypes for art and `project.godot`.** A file's *filetype* is how
Perforce handles it — as text, as binary, as always-writable — which is a
different idea from "PNG versus WAV". The *typemap* is a server-wide table
that picks a filetype for each new file from its name.

Changing it needs admin rights on the server. On a small team that's probably
you; if it isn't, send this section to whoever runs your server. Run
`p4 typemap`, add lines like these under `TypeMap:`, and save. (This opens a
form in a terminal text editor — on macOS and Linux usually `vi`. If that's
unfamiliar territory, ask your admin.)

```
TypeMap:
	binary+l //....png
	binary+l //....psd
	binary+l //....blend
	binary+l //....glb
	binary+l //....wav
	text+w //....godot
```

- `+l` is exclusive checkout. Binary art can't be merged, so it stops two
  people from editing the same file, and P4Godot shows who holds the lock the
  moment you try to edit it. Adjust the list to your asset types.
- `+w` keeps a file always writable. Godot rewrites `project.godot` at
  startup, and this stops that from failing.
- `.tscn`, `.tres`, `.gd`, and `.import` files are text, and the defaults
  suit them.

The typemap only affects files added afterward. For a file already
submitted, run `p4 edit -t <type> <file>` and submit.

**4. Add and submit the project.** Press **Reconcile** in the P4G dock (or
use P4V), check that nothing under `.godot/` is listed, and submit.

## Features

### Claiming files as you edit them

- Offers to check out a file the moment you first modify it in the editor. A
  dropdown in the prompt picks the pending changelist, and it defaults to the
  default changelist.
- Checks out edited files automatically right before the editor saves them.
- If a save fails because a file is read-only, offers to check it out and
  save again, with the same changelist dropdown.
- In `allwrite` workspaces (a workspace option that leaves synced files
  writable instead of read-only), a file saved while not checked out is
  checked out right after the save if the save changed it. An untouched
  Ctrl+S opens nothing.

### Why files are locked until you check them out

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
- Changing an asset's settings in the Import dock works even when its
  `.import` isn't checked out. The file is checked out if the settings really
  changed.

### Connecting to your server

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

### The P4G panel: everything you have changed

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
Submit, so it includes files outside the Godot project that are in the same
changelist. For the default changelist, exactly the listed files are
submitted.

<!-- 📷 SCREENSHOT: the submit confirmation dialog listing files + description.
     Suggested file: docs/images/submit-confirm.png -->

### Right-click actions in Godot's file browser

- **Right-click P4 actions** on any file (not folders): **P4: Check Out**,
  **P4: Mark for Add**, **P4: Get Latest (Sync)**, **P4: Diff vs Depot**,
  **P4: Revert...**, and **P4: Show Status in Log**. Checking out an imported
  asset also checks out its `.import` file, which holds its import settings.
  The menu is hidden while Perforce isn't connected.
- **Hover tooltips** show each file's Perforce status: the revision you have
  vs. head, any pending action, and who else has it checked out. The first
  hover over a file starts the lookup in the background, and the status shows
  from the next hover, so hovering never waits on the server.
- **Delete, move, and rename tracking.** Deleting a file offers to open it
  for delete. Moving or renaming offers to record a history-preserving move
  (`p4 reconcile -M`, which falls back to delete + add if the content changed
  during the move). The `.import` and `.uid` files Godot moves along with an
  asset are recorded too. These actions prompt by default, or apply silently
  with the "Auto add/edit/delete" setting.

### Files you edited in Photoshop, Blender, or anywhere else

Textures, models and audio get edited in Photoshop, Blender and Audition,
which know nothing about Perforce. Each time you switch back to Godot,
P4Godot checks for files those programs changed and offers to check them out.
It acts on exactly the files it listed for you, and tells you when Perforce
says no — which usually means a teammate has the file exclusively locked.

Answering **Not Now** stops it asking about those files until one of them
changes again, so it can't pester you every time you alt-tab. With **Auto
add/edit/delete** on, it adds them to your changelist without asking.
Deletes are the one exception; it always asks first. A file that simply
failed to download looks exactly like one you deleted on purpose, and
marking it deleted by mistake would remove it for everyone.

The scan runs when Godot regains focus, and only then: Godot's own filesystem
rescans fire on every save, and a reconcile preview of the whole project is
too expensive to run at that rate. On a very large workspace you may want the
setting off entirely; **Reconcile** still does the job on demand.

<!-- 📷 SCREENSHOT: the FileSystem dock with the P4 context menu open on a file,
     and (second shot or same composition) a hover tooltip showing
     "//depot/...#3 (head #5 - out of date) opened for edit".
     Suggested file: docs/images/filesystem-dock.png -->

### Diff viewer

Diff any file against the depot from the dock, the changelist tree, or the
FileSystem dock. A side-by-side window shows the revision you last synced on
the left and your workspace file on the right, with line numbers, aligned rows, and
colored change bands. Within a changed line, the exact span that differs is
highlighted. Line-ending differences are ignored, because Godot writes LF
while Windows workspaces usually sync CRLF.

<!-- 📷 SCREENSHOT: the diff window on a file with a few added and removed
     lines visible. Suggested file: docs/images/diff-viewer.png -->

### Speed, and the activity log

p4 commands run on a background thread, so the editor stays responsive
while the server works. The exception is the work right before a save (a
status check and any checkout), which has to finish before Godot writes. The
**Log** window records every state-changing command and its output (very
long output is truncated), and the Verbose setting adds the read-only status
queries.

## What you need

- **Godot 4.7 or later.**
- **The `p4` command-line client.** P4Godot looks for it on your `PATH`,
  then in the usual install locations: `C:\Program Files\Perforce` on
  Windows, and Homebrew's folders on macOS. Apps launched from the macOS Dock
  don't see your shell's `PATH`, which is why the fallback exists. To use a
  different copy, set **Editor Settings → Perforce → Executable Path**.
- **A Perforce workspace that contains your Godot project.** P4Godot uses
  your existing p4 configuration: `P4CONFIG` files, values saved with
  `p4 set`, and login tickets. On macOS, variables exported in a shell
  profile don't reach apps launched from the Dock, so use `p4 set` or the
  setup prompts instead.

## Settings

The settings button on the right of the P4G dock toolbar, next to **Log**
(tooltip "P4Godot settings"), holds these settings. They are stored per
project and per user, and never written into project files.

| Setting | Default | What it does |
| --- | --- | --- |
| Checkout on edit | on | Offer to check out a file the moment it is first modified. |
| Checkout on save | on | Check files out just before Godot writes them, and take care of locked files around saves. Leave this on — turning it off means saves can fail. See [Why files are locked](#why-files-are-locked-until-you-check-them-out) and [Turning "Checkout on save" off](#turning-checkout-on-save-off). |
| Auto add/edit/delete | off | Open edits, deletes, and moves in Perforce silently, with no confirmation dialogs. |
| Detect external changes | on | When Godot regains focus, look for files changed by other programs and offer to check them out (see [Changes made outside Godot](#files-you-edited-in-photoshop-blender-or-anywhere-else)). |
| Verbose log | off | Also log the commands that only ask questions and change nothing (`fstat`, `opened`, `where`, `changes`). |

One setting lives in **Editor Settings → Perforce** because it applies to
every project: **Executable Path**, the full path to `p4` if P4Godot can't
find it on its own.

### Turning "Checkout on save" off

On Windows, saving a scene to a file you haven't checked out fails, and
P4Godot asks what you want to do. Saving a script shows Godot's own error
message instead.

On macOS and Linux nothing blocks the save, so the file is written. If the
contents really changed, P4Godot checks it out afterwards.

## Known limitations

- **Declining the checkout prompt reloads the file.** Choosing **Discard My
  Changes** reloads the file from disk. For a scene, that discards all of its
  unsaved changes, not only the edit that triggered the prompt. A script's
  tab is closed and reopened on the file's contents, which loses that file's
  undo history.
- **`project.godot` isn't covered by change detection while you edit it.**
  Godot writes it without telling plugins. The focus-in scan picks it up
  afterwards, and **Reconcile** always does.
- **New files aren't added the moment you create them**, because Godot
  doesn't announce them. The focus-in scan offers them on the next alt-tab;
  to add one straight away, use right-click → **P4: Mark for Add**, or
  Reconcile.
- **Import groups** (atlas textures and other assets imported as a group)
  aren't covered by the read-only reimport handling. Check out their
  `.import` files before reimporting.
- **An unreachable server costs one long wait.** If the server stops
  answering mid-command, p4 gives up after 2 minutes (30 seconds for the
  checks right before a save). But connecting to a server that's
  unreachable, for example after a VPN drop, takes the operating system's
  connect timeout (about 21 seconds on Windows). After one such failure,
  saves and status checks skip the server for a minute and saves go ahead
  without checkout. Press Refresh to retry sooner.
- **Single sign-on:** the login prompt asks for a password. With SSO, log in
  once with `p4 login` or P4V, and P4Godot uses that ticket.
- **Shelving** isn't implemented yet.

## Troubleshooting

- **"Perforce won't let you edit this file."** Someone else is working on
  it. Studios mark art files — images, models, audio — so only one person
  can change them at a time, because there's no way to combine two people's
  edits to the same `.png`. The message names who has it; ask them to submit
  their work or set it aside. Meanwhile your own changes are safe: they stay
  in the editor, or on disk if you already saved, and P4Godot keeps the file
  unlocked so a download can't overwrite them. It tries again every time you
  save.
- **"Addon 'res://addons/p4godot/plugin.cfg' failed to load. No directory
  found."** Whoever set this project up didn't put the plugin's own files
  into Perforce. Ask them to, or install P4Godot yourself. Don't ignore it:
  Godot switches the plugin off when it sees this, and that can get
  submitted and switch it off for the whole team. See
  [Keep the plugin itself in Perforce](#keep-the-plugin-itself-in-perforce).
- **P4Godot says it can't add itself.** Your `.p4ignore` covers the plugin
  folder. Run `p4 ignores -i -v addons/p4godot/x` — if it answers `ignored`,
  it names the rule and the line number to change.
- **"Not connected" in the toolbar.** Click it, or press Refresh (the
  circular-arrow button at the left end of the P4G toolbar), to rerun
  connection setup. It names what's missing. The P4 Log window (toolbar →
  **Log**) shows the exact error.
- **"Couldn't find the p4 command-line client."** Install `p4` (see
  [Quick start](#quick-start)) and press Refresh. If it's installed somewhere
  unusual, set **Editor Settings → Perforce → Executable Path** to its full
  path.
- **Wrong workspace.** Click the connection status in the toolbar (it shows
  `user @ workspace`) and pick a different workspace. The choice is stored per
  project. If you'd rather use a `P4CONFIG` file in the workspace root, it
  works as long as you haven't picked a workspace in P4Godot's setup for this
  project.
- **A Load Error writing `project.godot` when the project opens.** Godot
  sometimes rewrites `project.godot` at startup (version stamps, plugin
  state), which fails while the file is read-only. Give it the
  always-writable filetype once with
  `p4 edit -t text+w project.godot`, then submit. See the typemap above to
  make it the default for new projects.
- **Something else.** Turn on **Verbose log** in the settings menu and
  repeat the action. The log shows every command and its output. Please
  include it when you
  [open an issue](https://github.com/jase-perf/P4Godot/issues).

## Compatibility and status

**0.14.1, the first public release.** Built and tested on Windows 11 with
Godot 4.7 and a Perforce 2025.2 server. It's written to work on macOS and
Linux as well, but those have had less testing. Please
[open an issue](https://github.com/jase-perf/P4Godot/issues) if something
misbehaves.

## Development

Everything lives in `addons/p4godot/p4godot.gd`. The plugin has built-in
self-tests, run headless:

```
godot --headless --editor --path <project> -- --p4-selftest-<name>
```

Server-independent tests include `save-guards`, `prewrite`,
`unchanged-save`, `exec-quoting`, `parse-ztag`, `diff-align`, and
`dismiss-dialog`. Live tests such as `probe`, `list-opened`, and
`create-changelist` need a workspace. Tests that check a result log
`[selftest] PASS: <name>` or `[selftest] FAIL: <name>`, and the listing tests
print what they found. See `_run_cli_self_test_if_requested` for the full
list, and `docs/manual-tests.md` for the checks that need a real editor
window.

## License

The code is licensed under the [MIT License](LICENSE).

The Perforce and P4 names and logos are trademarks of Perforce Software, Inc.,
used here to identify the product this plugin integrates with. This is a
community plugin, not an official Perforce product.
