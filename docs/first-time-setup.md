# Putting a Godot project into Perforce for the first time

One person does this once, for the whole team. Everyone else just connects to
the server and starts working — that's the [quick start](../README.md#quick-start).

This part happens in **P4V**, the desktop app that comes with Perforce, not in
Godot. P4Godot doesn't set projects up, and neither do the Unity and Unreal
integrations: getting a project into version control in the first place is a
one-time job, and P4V is already good at it.

New to any of these words? The [glossary](glossary.md) covers them.

**Do these steps in order.** The ignore file and the typemap only affect files
added *after* them, so submitting first means redoing work.

## Before you start

- **Perforce installed, including P4V.** Get it from
  [perforce.com](https://www.perforce.com/downloads/helix-visual-client-p4v).
- **A server and an account on it.** Ask whoever runs it for the server
  address (something like `ssl:perforce.example.com:1666`), your user name,
  and your password. No server yet? Perforce is
  [free for up to five users](https://www.perforce.com/products/helix-core).
- **Your Godot project on disk**, not yet in Perforce.

## 1. Make a workspace

A *workspace* is Perforce's link between the server and one folder on your
computer. That folder is the workspace's *root*, and everything inside it is
what this workspace can send to the server.

In P4V: **Connection → New Workspace**. Name it, and set the root to a folder
that holds your Godot project — or that will hold it.

Your project folder has to be the root or sit inside it. If it isn't there
yet, move it now, before anything is submitted.

(The command-line version, `p4 client`, opens a form in a terminal text
editor, which on macOS and Linux is usually `vi`. Use P4V unless you're at
home in `vi`.)

## 2. Tell Perforce to ignore Godot's cache

Godot keeps a `.godot/` folder next to your project file. It's a cache and
your personal editor state: every machine rebuilds it, and nobody else wants
yours. Submitting it means thousands of files and a stream of pointless
conflicts.

Save this as a file called `.p4ignore` in your project folder:

```
# Godot's local cache and per-user editor state
.godot/
# Temporary files from interrupted saves
*.tmp
```

Everything else belongs in Perforce, including the `*.import` and `*.uid`
files. They hold import settings and resource IDs, and your teammates' copies
of the project break without them.

Now check Perforce is really reading the file. In a terminal, in your project
folder:

```
p4 ignores -i -v .godot/x
```

There's no file called `x`. You're asking a hypothetical: *if one existed
there, would you ignore it?* The answer is either `ignored by ...`, which
names the rule that did it, or `not ignored`. If you get `not ignored`, run
`p4 set P4IGNORE=.p4ignore` — that tells Perforce what your ignore file is
called — and ask again.

## 3. Set filetypes for art and `project.godot`

A file's *filetype* is how Perforce handles it: as text, as binary, as
always-writable. That's a different question from "PNG or WAV". The *typemap*
is a table on the server that picks a filetype for each new file from its
name.

**This step needs admin rights on the server.** On a small team that's
probably you. If it isn't, send this section to whoever runs the server.

Run `p4 typemap`, add lines like these under `TypeMap:`, and save. (This also
opens a form in a terminal text editor, usually `vi` on macOS and Linux. If
that's unfamiliar, ask your admin to do it.)

```
TypeMap:
	binary+l //....png
	binary+l //....psd
	binary+l //....blend
	binary+l //....glb
	binary+l //....wav
	text+w //....godot
```

- `+l` means **exclusive checkout**: only one person can have the file
  checked out at a time. Two people's edits to the same `.png` can't be
  combined, so this stops the problem instead of discovering it later. Adjust
  the list to the file types your project actually uses.
- `+w` keeps a file **always writable**. Godot rewrites `project.godot` at
  startup, and without this that write fails.
- `.tscn`, `.tres`, `.gd`, and `.import` files are text, and Perforce's
  defaults already suit them.

The typemap only applies to files added after it. For a file already
submitted, run `p4 edit -t <type> <file>` and submit.

## 4. Submit the project

In P4V, right-click your project folder and choose **Mark for Add**. Before
you submit, read the file list and check that **nothing under `.godot/` is in
it**. If any is, step 2 didn't take — fix it and try again, because taking
files back out afterwards is more work.

Then submit, with a description like "initial import of the project".

Your project is in Perforce. Two things follow from that:

- Your files are now **read-only** until you check them out. That's Perforce
  telling you to claim a file before changing it, and it's the thing P4Godot
  handles for you inside Godot.
- Your teammates can get the project by making their own workspace (step 1)
  and running **Get Latest Revision** on it in P4V.

## 5. Install P4Godot

Now go back to the [quick start](../README.md#quick-start) and add the plugin.
Everyone on the team follows that page, including you.

## If `.godot/` is already in the depot

Someone submitted it before the ignore rule existed. Ignore rules only stop
files being *added*, so the rule alone won't remove it.

```
p4 delete -k .godot/...
```

then submit. The `-k` keeps your local copies while removing them from the
server — without it you'd delete your own cache too, which Godot would just
spend a few minutes rebuilding.
