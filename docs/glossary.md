# Words you'll see

Perforce has its own vocabulary, and several of its words mean something
different from what you'd guess. Here's the short version. You don't need to
read this end to end — come back when a word trips you up.

## The pieces

**Perforce** — a version control system: a server that stores every version
of every file in your project, so a team can work on it at once without
overwriting each other. It used to be called Helix Core, and it's often
written as "P4". Studios like it because it handles big art files well, which
most version control doesn't.

**Depot** — the storage on the server. The master copy of the project that
everyone shares.

**Workspace** — the link between the depot and a folder on your computer. Its
*root* is that folder. Your Godot project has to live inside it.

**`p4`** — a small program you run by typing commands in a terminal. It's how
your computer talks to the server. P4Godot runs it for you.

**P4V** — Perforce's desktop app: windows and buttons instead of typed
commands. Separate from Godot and from P4Godot.

**Revision** — one saved version of a file. Perforce numbers them `#1`, `#2`,
and so on. The **head revision** is the newest one on the server.

## The things you do

**Check out** — tell the server you're about to change a file. Perforce makes
it writable and records that you have it. Nothing to do with library books or
git branches.

**Changelist** — a group of files you've changed, with a description of why.
You send the whole group up at once. Files land in the **default changelist**
unless you put them somewhere else; give a changelist a description and it
becomes a **numbered** one. **Pending** means "not sent yet".

**Submit** — send a changelist to the server so your teammates can get it.

**Sync** (also **Get Latest**) — download the newest files from the server
onto your disk.

**Revert** — throw away your changes to a file and go back to the copy you
last downloaded. The file also leaves your changelist. Nothing is sent to the
server. It does **not** mean "go back one version". This one deletes work —
what you saved as well as what you didn't — so read the confirmation.

**Reconcile** — compare the files on your disk against what the server thinks
you have, and list what's new, changed, or missing.

**Resolve** — combine your version of a file with a newer one from the server.
Perforce won't let you submit until you do. For text, it can usually merge the
two automatically. For an image, a model or a sound there is nothing to
combine: you keep one version and the other is lost, which is why studios put
`+l` on art.

**Diff** — show, line by line, what's different between your copy and the
server's.

**Open** — in Perforce, "opening" a file means putting it in a changelist,
not opening it in an editor. A file can be open *for edit*, *for add*, or
*for delete*. This is the word most likely to confuse you.

**Shelve** — park your changes on the server without submitting them, so you
can hand them to someone or pick them up on another machine. (P4Godot doesn't
do this yet.)

## Markers on files

**Read-only** — files you haven't checked out are read-only on disk. That's
how Perforce stops you changing something without telling anyone. P4Godot
handles this for you.

**`+l` (exclusive checkout)** — only one person can have this file checked
out at a time. Studios set it on images, models and audio, because those
can't be **merged**: if two people change the same `.png`, there's no way to
combine the results, so somebody's work would be lost. When a file is locked,
P4Godot tells you who has it.

**`+w`** — always leave this file writable, even when it isn't checked out.
Commonly set on `project.godot`, which Godot rewrites on its own.

**Filetype** — how Perforce handles a file: text, binary, always-writable,
exclusively-locked. Not the same idea as "PNG vs WAV". The **typemap** is a
server-wide table that picks a filetype for each new file from its name.

## Configuration

**`.p4ignore`** — a list of files Perforce should never add: caches, build
output. **P4IGNORE** is the setting that tells `p4` what that file is called.

**`p4 set`** — saves Perforce settings for your user account. A **P4CONFIG**
file does the same thing for one folder, so different projects can use
different servers.

**Ticket** — the pass the server gives you when you log in. It expires after
a while, and then you log in again.

**`...`** — in a Perforce command, `...` means "this folder and everything
inside it". It's part of the command; type it literally.

## Godot words, if Godot is new too

**Dock** (also **panel**) — one of the areas around the edge of the Godot
editor holding a tool: the FileSystem dock, the Inspector, the Import dock.
P4Godot adds one called **P4G** at the bottom.

**Addon** (also **plugin**) — code you drop into your project's `addons/`
folder to add features to the editor. P4Godot is one. You switch it on under
**Project → Project Settings → Plugins**.

**Scene** (`.tscn`) — a tree of nodes saved as a file: a level, a character, a
menu. Scenes can contain other scenes.

**Resource** (`.tres`, and every asset) — anything Godot loads from a file: a
texture, a material, a tileset, a script.

**`.import` and `.uid`** — small files Godot writes next to each asset.
`.import` holds that asset's import settings, `.uid` its stable identity. Both
belong in Perforce: without them your teammates' copies of the project break.
Godot rewrites them on its own, which is why P4Godot has special handling for
them.
