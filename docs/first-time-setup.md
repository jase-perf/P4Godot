# Putting a Godot project into Perforce for the first time

One person does this once, for the whole team. Everyone else follows the
[quick start](../README.md#quick-start).

Almost all of it happens in **P4V**, Perforce's desktop app. Each step below
says where you do it. One step, the fourth, uses a terminal, and you can skip
it if you work alone.

New to any of these words? The [glossary](glossary.md) covers them.

## What you need

- **P4V installed.** [Download it here.](https://www.perforce.com/downloads/helix-visual-client-p4v)
  On Windows, leave every box ticked in the installer.
- **A Perforce server, and an account on it that's allowed to create depots.**
  If you set the server up yourself, your account is. If someone else runs
  it, ask them to do step 1 for you. No server yet? Perforce is
  [free for up to five users](https://www.perforce.com/products/helix-core),
  and its [getting-started guide](https://help.perforce.com/helix-core/quickstart/current/Content/quickstart/admin-reference.html)
  walks you through installing one.
- **Your Godot project in a folder on your computer.**

**Do the steps in order.** Steps 3 and 4 only affect files added after them,
so adding your project first means redoing work.

## 1. In P4V: make a home for the project on the server

Perforce keeps each project in a **depot**, and inside the depot a **stream**
holds the files. You make one of each.

Make the depot:

1. In P4V, choose **Tools → Administration**. A second window opens, called
   P4 Admin.
2. In P4 Admin, choose **File → New → Depot**.
3. Type a name with no spaces, such as your game's name, and click **OK**.
   You can't rename a depot later.
4. Make sure **Depot type** is **stream**, and click **OK**.

Close P4 Admin. Back in P4V, make the stream:

1. Choose **File → New → Stream**.
2. **Stream name**: `main`.
3. **Stream type**: **mainline**.
4. **Depot**: click **Browse** and pick the depot you just made.
5. Untick **Create a new workspace to use with this stream** and **Populate
   the mainline stream after it is created**. You do both yourself in the
   next steps, so that you choose where things go.
6. Click **OK**.

## 2. In P4V: make your workspace

A **workspace** links a folder on your computer to the stream.

Choose **Connection → New Workspace** and fill in three things:

- **Workspace name**: the suggested name is fine.
- **Workspace root**: your Godot project folder, the one with `project.godot`
  in it.
- **Stream**: click **Browse** and pick the `main` stream from step 1.

Confirm. Nothing is uploaded yet.

## 3. Add an ignore file

You do this one in any text editor.

Godot keeps a `.godot/` folder inside your project. It's a cache that every
computer rebuilds for itself, and nobody else wants yours. An ignore file
tells Perforce to leave it alone.

Save this as a file named `.p4ignore` in your project folder, next to
`project.godot`:

```
# Godot's cache and your personal editor state
.godot/
# Leftovers from interrupted saves
*.tmp
```

Everything else belongs in Perforce, including the `.import` and `.uid` files
Godot writes next to your assets. Your teammates' copies of the project break
without them.

If your team also works in Blender, Photoshop, or a code editor, the
[universal game-project ignore file](https://gist.github.com/jase-perf/1c24138a68498f7117052b046ca5a215)
covers those tools too. Use it in place of the four lines above.

## 4. In a terminal: lock art files

*Working alone? Skip to step 5.* This is the only step that uses a terminal,
and it needs an admin account on the server.

Two people can't both change the same image: there's no way to combine their
edits, so one person's work is lost. Perforce prevents that with *exclusive
checkout*, where only one person can have a file checked out at a time. The
**typemap** is the server's list of which files get that treatment.

1. In P4V, right-click your project folder in the **Workspace** tab and
   choose **Open Command Window Here** (Windows) or **Open Terminal Here**
   (macOS, Linux). The terminal that opens is already connected to your
   server.
2. Type `p4 typemap` and press Enter. A text file opens.
3. Add these lines at the end, each starting with a tab:

   ```
   TypeMap:
   	binary+l //....png
   	binary+l //....psd
   	binary+l //....blend
   	binary+l //....glb
   	binary+l //....wav
   	text+w //....godot
   ```

   If the file already has a `TypeMap:` line, add only the lines under it.
4. Save the file and close the editor. The terminal answers `Typemap saved.`

`+l` is exclusive checkout. Add a line for every kind of art file your
project uses. `+w` on the last line keeps `project.godot` writable, because
Godot rewrites that file on its own. Perforce's guide has a
[fuller typemap for game projects](https://help.perforce.com/helix-core/quickstart/current/Content/quickstart/admin-create-typemap.html).

## 5. In P4V: add the project and submit it

1. In the **Workspace** tab on the left, right-click your project folder and
   choose **Mark for Add**, then click **OK**.
2. Open **View → Pending Changelists** and expand the **default** changelist.
   It lists every file about to be uploaded. **Check that nothing under
   `.godot/` is in the list.** If something is, the ignore file from step 3
   isn't being read: check its name and location, then see
   [the note on older versions](#if-perforce-ignores-your-ignore-file).
3. Right-click the default changelist and choose **Submit**. Type a
   description such as "First import of the project", and click **Submit**.

Your project is in Perforce. From now on its files are **read-only** until
you check them out. That is Perforce asking you to claim a file before you
change it, and it's the part P4Godot handles for you inside Godot.

## 6. In Godot: install P4Godot

Go to the [quick start](../README.md#quick-start) and begin at step 3. You
already have a workspace, so steps 1 and 2 are done.

Your teammates follow the whole quick start, using the stream you made here.

## If something isn't right

### If Perforce ignores your ignore file

Perforce reads a file named `.p4ignore` by itself from version 2023.2 on.
That needs a 2023.2 or later server, and P4V 2023.4 or later. On anything
older, each person runs this once in a terminal:

```
p4 set P4IGNORE=.p4ignore
```

### If `.godot/` is already in the depot

Someone submitted it before the ignore file existed. An ignore file only
stops files being *added*, so it won't remove what's already there.

In P4V's **Depot** tab, right-click the `.godot` folder and choose **Mark for
Delete**, then submit. This also deletes the folder from your disk. Godot
rebuilds it the next time you open the project, which takes a few minutes on
a large project.

### If you skipped step 4 and Godot can't write `project.godot`

In P4V, right-click `project.godot` → **Check Out**, then right-click it
again → **Change Filetype**, tick the **+w** option (always writable), click
**OK**, and submit.
