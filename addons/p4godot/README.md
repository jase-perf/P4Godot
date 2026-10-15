
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
all in the [glossary](https://github.com/jase-perf/P4Godot/blob/main/docs/glossary.md).

P4Godot is written in GDScript, so there's nothing to compile. Behind the
scenes it runs `p4`, Perforce's command-line program, for you.

<!-- 📷 HERO GIF: the signature loop, captured in one take —
     edit a file in the editor → checkout prompt appears → accept → the file
     shows up under the default changelist in the P4G panel.
     Suggested file: docs/images/hero-checkout.gif -->

## Quick start

This is for joining a project that's already in Perforce, which is the usual
case. If nobody has put your project there yet, one person does the
[first-time setup](https://github.com/jase-perf/P4Godot/blob/main/docs/first-time-setup.md) once, then comes back here.

You do two things in P4V, Perforce's desktop app, and the rest in Godot.
Nothing here asks you to type a command.

### What you need

- **Godot 4.7 or later.**
- **Your server address, user name, and password.** Ask whoever runs your
  team's Perforce server. The address looks like
  `ssl:perforce.example.com:1666`. No server yet? Perforce is
  [free for up to five users](https://www.perforce.com/products/helix-core).
- **P4V.** [Download it here.](https://www.perforce.com/downloads/helix-visual-client-p4v)
  On Windows, leave every box ticked in the installer: one of them is `p4`,
  the small program P4Godot runs for you behind the scenes. On macOS and
  Linux, `p4` is a
  [separate download](https://www.perforce.com/downloads/helix-command-line-client-p4)
  (on macOS, `brew install --cask p4` also works).

### In P4V: download the project

1. **Log in.** Open P4V and enter your server address, user name, and
   password.
2. **Make a workspace.** A workspace links a folder on your computer to your
   team's project on the server. Choose **Connection → New Workspace** and
   fill in three things:
   - **Workspace name**: the suggested name is fine.
   - **Workspace root**: an empty folder where the project will live.
   - **Stream**: click **Browse** and pick your team's stream. A stream is
     the server's copy of the project. Most teams have one called `main`;
     ask if you see several.

   Tick **Automatically get all revisions**, then confirm.
   *You should see* the project's files appear in the folder you chose. If
   the folder stays empty, select it in P4V's **Workspace** tab and click
   **Get Latest** in the toolbar.

That's everything you need P4V for today.

### In Godot: turn on P4Godot

3. **Open the project.** In Godot, import the `project.godot` file inside
   your workspace folder.
4. **Check whether the plugin is already there.** Look for a **P4G** tab at
   the bottom of the editor. If your team already uses P4Godot, it came down
   with the project: skip to step 5. If there's no tab:
   - Download `p4godot-*.zip` from the
     [latest release](https://github.com/jase-perf/P4Godot/releases/latest),
     under **Assets** — not either of the "Source code" zips.
   - Copy the `addons` folder inside it into your project folder, next to
     `project.godot`. If you already have an `addons` folder, merge them.
   - In Godot, open **Project → Project Settings → Plugins** and tick
     **P4Godot**. If Godot says it can't write `project.godot`, go to P4V,
     right-click that file → **Check Out**, and tick the box again.

   *You should see* the **P4G** tab appear.
5. **Connect.** P4Godot asks only for what it can't work out by itself,
   which is usually your password and which workspace to use. Pick the
   workspace you made in step 2.
   *You should see* your user name and workspace in the P4G toolbar.
6. **If you installed the plugin in step 4, share it with your team.** Press
   **Reconcile...** in the P4G panel. It finds the new `addons/p4godot/`
   files and adds them to your **changelist**, the group of files you send to
   the server together. Then send it: right-click **Default changelist** →
   **Submit Changelist...**, type what you did, and confirm. Your teammates
   now get the plugin with the project, so they skip straight to step 5.
   [Why this matters.](#keep-the-plugin-itself-in-perforce)

   Read the list Reconcile shows before you accept it:
   - Anything it calls *missing* gets deleted for the whole team when you
     submit. If a file should still be there, cancel. You probably haven't
     downloaded everything yet.
   - If it lists files under `.godot/`, cancel. That folder is Godot's
     private cache, and your project is missing the file that tells Perforce
     to leave it alone.
     [Add the ignore file](https://github.com/jase-perf/P4Godot/blob/main/docs/first-time-setup.md#3-add-an-ignore-file),
     then press Reconcile again.

Now edit a scene or script. P4Godot offers to check it out the moment you
change it. Files that aren't in Perforce yet get no prompt: add them with
**Reconcile...**.

## Your first change, start to finish

This is the loop you'll repeat all day. Five steps.

1. **Save your work, then get everyone else's.** Press **Get Latest...** in
   the P4G panel. It lists what's about to arrive before downloading anything.
   Any of those files you have open gets reloaded on the downloaded version,
   and unsaved changes in it are lost — the confirmation names those files, so
   read it.
   *You should see* the files land, and any open ones reload.
2. **Change something.** Move a node, edit a script, whatever. The moment you
   do, P4Godot asks whether to check the file out. Say **Check Out**.
   The other button, **Discard My Changes**, reloads the file from disk, which
   throws away *everything* unsaved in that scene — not just the change you
   just made. Press it only if you meant to undo the lot.
   *You should see* the file appear in the P4G panel under **Default
   changelist**.
3. **Work and save normally.** Ctrl+S behaves as it always has. Files you
   change get added to the panel as you go.
4. **Look at what you're about to send.** In the P4G panel, right-click a
   file → **Diff vs Depot** shows exactly what you changed — the *depot* is
   the server's copy of everything. If you changed
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

Put `addons/p4godot/` in the depot — the server's copy of the project —
however you installed it.

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

One person does this for the team. If you forget step 1, P4Godot offers you the
changed files the next time you switch back to Godot.

## Features

### Getting everyone else's work

**Get Latest...** downloads every file in the project that someone has
submitted since you last looked. It shows you the list and the total size
first, then downloads, then reloads anything you had open — so an open scene
shows the new version instead of quietly keeping the old one. That reload is
also why you should save first: unsaved changes to a file being downloaded are
lost, and the confirmation names those files before anything happens.

It also tells you about the two things it can't simply download:

- **A file you changed without checking it out.** Perforce refuses to
  overwrite it, which is the point: your work isn't thrown away. P4Godot names
  those files before it downloads anything and again afterwards, and tells
  you to Reconcile them. It checks each file's contents to find them (a "safe
  sync"), so this holds even for a file that still looks locked.
- **A file you have checked out that someone else changed too.** Perforce
  leaves yours alone and expects the two versions to be combined — *resolved*,
  in Perforce's word. P4Godot names those files and offers to combine them;
  right-click one marked "needs resolve" → **Resolve...** to do it later.

  For an image, a model or a sound there is nothing to combine: resolving means
  keeping one version and losing the other. Talk to whoever made the other
  change before you pick. The way to stop this happening to art at all is
  `+l`, exclusive checkout, which lets only one person hold a file at a time —
  see [filetypes for art](https://github.com/jase-perf/P4Godot/blob/main/docs/first-time-setup.md#4-in-a-terminal-lock-art-files).

It covers the Godot project, not the whole workspace, because a workspace
often holds more than one project. Single files still have right-click →
**P4: Get Latest (Sync)**.

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
  Ctrl+S checks nothing out.

### Why files are locked until you check them out

Files you haven't checked out are read-only. That's Perforce asking you to
claim a file before you change it — and it's the friction P4Godot exists to
remove, because Godot rewrites files whether or not anything changed: every
open scene and its resources on each save, and every reimported asset's
`.import` file.

Left alone, that makes Godot stall for seconds, log "Safe save failed", and
leave `.tmp` files behind, and a fresh download of a project hits it for every
asset. So P4Godot makes each file writable just long enough for Godot's write,
then checks out the ones whose contents really changed and puts the rest back
to read-only. You shouldn't notice any of it.

The details, if you hit one:

- A reimport that changes more than 20 `.import` files at once (usually after
  a Godot upgrade) asks before checking them out.
- If Perforce refuses a checkout — someone else holds an exclusive lock, say —
  your saved file stays on disk and writable so a download can't overwrite it,
  and P4Godot tells you it isn't in a changelist yet.
- Changing an asset's settings in the Import dock works even when its
  `.import` isn't checked out.

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
  ranked by whether their root contains this project. The list says which
  server and user it is for. If that's the wrong server, press **Change
  Server or User...** instead of picking.

To change any of this later, open the settings menu in the P4G toolbar and
choose **Connection settings...**. It asks for the server and user, then the
workspace. Emptying a box goes back to your normal Perforce settings.

Before it asks anything, P4Godot uses the Perforce configuration you already
have: `P4CONFIG` files, values saved with `p4 set`, and login tickets. On
macOS, variables exported in a shell profile don't reach apps launched from
the Dock, so use `p4 set` or these prompts instead of your shell profile.

Whatever you choose here is stored per project and per user, and passed to
`p4` as command-line flags. Your terminal, P4V, and other projects are
unaffected.

<!-- 📷 SCREENSHOT (optional): the workspace-suggestion dialog from connection
     setup. Suggested file: docs/images/connection-setup.png -->

### The P4G panel: everything you have changed

The P4G panel shows your pending changelists and the files in each.
From there you can:

- **Create, edit, submit, and delete changelists.** Editing the default
  changelist's description turns it into a numbered changelist.
- **Drag and drop files between changelists**, or move them from the
  right-click menu.
- **Diff, revert, sync, and reload** individual files, and open a file's
  **History**.
- **Shelve** a changelist for review, and unshelve yours or a teammate's
  (see [Shelving](#shelving-share-work-without-submitting-it)).
- **Get Latest** the whole project, and **Reconcile** it to find edits, adds,
  and deletes made outside the editor. Read Reconcile's list before accepting:
  files it calls *missing* get deleted for everyone when you submit.
- **Revert Unchanged** to clean up files with no actual edits. Files open in
  the editor are skipped, so unsaved changes are never lost.

<!-- 📷 SCREENSHOT: the P4 dock with two or three changelists expanded, a few
     files with different actions (add/edit/delete show in different colors),
     and the right-click context menu open on a file row.
     Suggested file: docs/images/changelist-dock.png -->

Submitting always shows a confirmation that lists the files and the
description first. That list comes from the server as you press Submit, so it
includes files in the same changelist that live outside the Godot project.

While a submit or **Get Latest** runs, a progress window shows how many files
and how much data have moved, and how long it has taken. You can keep working,
or close the window; the transfer carries on. **Cancel** stops it. A cancelled
download keeps the files that had finished and removes the unfinished ones. A
cancelled submit is checked with the server, and you're told whether it
stopped in time.

If a submit doesn't finish cleanly, P4Godot asks the server what happened
before telling you. A dropped connection can leave a submit that went through
anyway, so the message says which it was: submitted, not submitted, or
unknown, with what to do next.

<!-- 📷 SCREENSHOT: the submit confirmation dialog listing files + description.
     Suggested file: docs/images/submit-confirm.png -->

### A file's history

Right-click a file → **P4: History...** (in the FileSystem dock or the P4G
panel) lists every submitted revision: who, when, which changelist, and the
whole description. It follows the file back through moves and renames, so a
file renamed last month still shows its earlier revisions under the old name.

- **Diff vs Previous** compares a revision with the one before it. Select two
  revisions and it becomes **Diff Selected**. Double-clicking a revision does
  the same.
- **Diff vs Workspace** compares a revision with the file on your computer.
- **Get This Revision...** puts an older revision on your computer in place of
  the one there. Nothing on the server changes, and **Get Latest** brings the
  file back up to date. It refuses a checked-out file: submit or revert it
  first.

Binary files (images, sounds, models) and text files over 1 MB list their
revisions but can't be shown side by side.

### Shelving: share work without submitting it

A shelf puts copies of a changelist's files on the server without submitting
them. A teammate can look at them, or unshelve them into their own workspace
to try them out, and nothing reaches the rest of the team until someone
submits. It's how a change gets reviewed before it goes in, and how you move
unfinished work to another computer.

**Your own changelists.** Right-click a changelist in the P4G panel:

- **Shelve Files...** shelves the files in it. Files in the default
  changelist move to a new numbered changelist first, because Perforce only
  shelves numbered ones. Once a changelist has a shelf this reads **Update
  Shelf...**, and the shelf becomes exactly the files open in it now.
- **Shelve and Revert...** shelves the files, then reverts them, so your
  workspace goes back to the server's versions and the work waits on the
  server. Before reverting, P4Godot checks that the shelf holds what is on
  your disk, and reverts nothing if it doesn't.
- **Unshelve Files...** puts the shelved files back into the changelist.
- **Delete Shelved Files...** removes the shelf; your checked-out files are
  untouched.

A changelist with a shelf shows a **Shelved** row listing the shelved files;
right-click one to compare it with the revision it was made from or with your
copy. Submitting deletes the shelf first, because Perforce won't submit a
changelist while it has one, and the confirmation says so.

The shelf takes what is saved on disk. Save in Godot before shelving, and
before **Shelve and Revert** in particular: reverting reloads the files, and
anything unsaved in them is lost. The confirmation lists the changelist's
files that are open in Godot.

**Everyone's shelves.** **Shelves...** in the P4G panel's toolbar lists the
newest shelved changelists with files in this project, everyone's or only
yours, and opens any changelist by its number - the one in a code review or a
teammate's message. Pick one to see its description and files:

- **Diff vs Base** shows what the shelf changes in a file: the shelved version
  beside the revision it was made from. Double-clicking a file does the same.
  Nothing in your workspace changes.
- **Diff vs Workspace** compares the shelved version with your copy.
- **Unshelve...** copies the shelved files (all of them, or the ones you
  selected) into your workspace, checked out in a changelist you pick or in a
  new one named after the shelf.

Unshelving never throws your work away. A file you have checked out keeps
your edits, and P4Godot offers to combine them with the shelved version, as
for a teammate's newer submit. A file that is writable on your computer but
not checked out is left alone, because it may hold changes Perforce doesn't
know about. An exclusive-checkout (`+l`) file someone else has open can't be
unshelved. Afterwards P4Godot says which files came in, which need combining,
which moved from another of your changelists, and which were left out and
why.

A shelf made against older versions of its files unshelves at those
versions. Submitting it then asks you to combine it with the newer ones
first.

### Right-click actions in Godot's file browser

- **Right-click P4 actions** on any file (not folders): **P4: Check Out**,
  **P4: Mark for Add**, **P4: Get Latest (Sync)**, **P4: Diff vs Depot**,
  **P4: History...**, **P4: Revert...**, and **P4: Show Status in Log**. Checking out an imported
  asset also checks out its `.import` file, which holds its import settings.
  The menu is hidden while Perforce isn't connected.
- **Hover tooltips** show each file's Perforce status: the revision you have
  vs. head, any pending action, and who else has it checked out. The first
  hover over a file starts the lookup in the background, and the status shows
  from the next hover, so hovering never waits on the server.
- **Delete, move, and rename tracking.** Deleting a file offers to open it
  for delete. Moving or renaming offers to record a Perforce move, so the
  file keeps its history under the new name even if you also changed it
  (`p4 edit` + `p4 move -k`). The `.import` and `.uid` files Godot moves
  along with an asset are recorded too, and reverting a moved file undoes the
  move for all of them. A rename that only changes capital letters
  (`Hero.png` → `hero.png`) can't be recorded on a server that ignores case;
  P4Godot says so and explains the two-step way round. These actions prompt
  by default, or apply silently with the "Auto add/edit/delete" setting.

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

## Settings

The settings button on the right of the P4G panel toolbar, next to **Log**
(tooltip "P4Godot settings"), holds these settings. They are stored per
project and per user, and never written into project files.

| Setting | Default | What it does |
| --- | --- | --- |
| Checkout on edit | on | Offer to check out a file the moment it is first modified. |
| Checkout on save | on | Check files out just before Godot writes them, and take care of locked files around saves. Leave this on — turning it off means saves can fail. See [Why files are locked](#why-files-are-locked-until-you-check-them-out) and [Turning "Checkout on save" off](#turning-checkout-on-save-off). |
| Auto add/edit/delete | off | Record edits, deletes, and moves in Perforce silently, with no confirmation dialogs. |
| Detect external changes | on | When Godot regains focus, look for files changed by other programs and offer to check them out (see [files you edited elsewhere](#files-you-edited-in-photoshop-blender-or-anywhere-else)). |
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
  checks right before a save). Submit and Get Latest have no limit; their
  progress window tells you when nothing is moving and has a Cancel button.
  But connecting to a server that's
  unreachable, for example after a VPN drop, takes the operating system's
  connect timeout (about 21 seconds on Windows). After one such failure,
  saves and status checks skip the server for a minute and saves go ahead
  without checkout. Press Refresh to retry sooner.
- **Single sign-on:** the login prompt asks for a password. With SSO, log in
  once with `p4 login` or P4V, and P4Godot uses that ticket.
- **Merging the same lines by hand needs P4V.** When you and a teammate
  changed the same lines of a file, P4Godot's **Resolve** can keep one version
  or the other but can't combine them line by line; do that in P4V
  (right-click → **Resolve**). For art files, resolving isn't a merge at all —
  you keep one version and lose the other, so `+l` on art is worth setting up.
- **Shelves are compared file by file.** The Shelves window has no diff of a
  whole shelf at once, and binary files in a shelf can't be shown side by
  side.

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
- **"Perforce would not overwrite" some files after Get Latest.** Those files
  are changed on your disk but not checked out, so Perforce left your version
  alone rather than throw it away. That's usually a checkout it refused
  earlier, or a file another program wrote. Press **Reconcile...** to check
  them out, then **Get Latest...** again — after which Perforce will ask you
  to combine the two versions.
- **"Not connected" in the toolbar.** Click it, or press Refresh (the
  circular-arrow button at the left end of the P4G toolbar), to rerun
  connection setup. It names what's missing. The P4 Log window (toolbar →
  **Log**) shows the exact error.
- **"Couldn't find the p4 command-line client."** Install `p4` (see
  [Quick start](#quick-start)) and press Refresh. P4Godot looks on your
  `PATH`, then in `C:\Program Files\Perforce` on Windows and Homebrew's
  folders on macOS — that fallback exists because apps launched from the macOS
  Dock don't see your shell's `PATH`. If your copy is somewhere else again, set
  **Editor Settings → Perforce → Executable Path** to its full path.
- **Wrong workspace, server, or user.** Open the settings menu in the P4G
  toolbar and choose **Connection settings...**. Clicking the connection
  status (it shows `user @ workspace`) goes straight to the workspace list.
  The choice is stored per project. If you'd rather use a `P4CONFIG` file in the workspace root, it
  works as long as you haven't picked a workspace in P4Godot's setup for this
  project.
- **A Load Error writing `project.godot` when the project opens.** Godot
  sometimes rewrites `project.godot` at startup (version stamps, plugin
  state), which fails while the file is read-only. Give it the
  always-writable filetype once with
  `p4 edit -t text+w project.godot`, then submit. To make that the default for
  new projects, see
  [filetypes for art and `project.godot`](https://github.com/jase-perf/P4Godot/blob/main/docs/first-time-setup.md#4-in-a-terminal-lock-art-files).
- **Something else.** Turn on **Verbose log** in the settings menu and
  repeat the action. The log shows every command and its output. Please
  include it when you
  [open an issue](https://github.com/jase-perf/P4Godot/issues).

## Compatibility and status

**0.15.0, the first public release.** Built and tested on Windows 11 with
Godot 4.7 and a Perforce 2025.2 server. It's written to work on macOS and
Linux as well, but those have had less testing. Please
[open an issue](https://github.com/jase-perf/P4Godot/issues) if something
misbehaves.

Working on the plugin itself? See [CONTRIBUTING.md](https://github.com/jase-perf/P4Godot/blob/main/CONTRIBUTING.md).

## License

The code is licensed under the [MIT License](LICENSE).

The Perforce and P4 names and logos are trademarks of Perforce Software, Inc.,
used here to identify the product this plugin integrates with. This is a
community plugin, not an official Perforce product.
