# Manual tests

These checks need a real editor window or a platform the headless self-tests
can't reach. Run them before a release.

## macOS (about 15 minutes)

Setup:

1. Install Godot 4.7 and the p4 client: `brew install --cask p4`.
2. Have a workspace containing a Godot project, synced and with nothing
   opened. Copy `addons/p4godot` into the project from the release zip, and
   enable the plugin.
3. Quit Godot, then **launch it from the Dock or Finder, not from a
   terminal.** Launching from a terminal hides the PATH problem this test
   checks.

| # | Do this | Expect |
|---|---|---|
| 1 | Open the project. Open the P4G dock's **Log**. | `Using p4 at /opt/homebrew/bin/p4.` (or `/usr/local/bin/p4` on Intel Macs). The toolbar shows connected, or setup asks for what's missing. |
| 2 | If this Mac never connected to the `ssl:` server before: follow setup. | A "Trust This Server" prompt showing the fingerprint. After Trust, setup continues. |
| 3 | Open a scene that isn't checked out, move a node. | Checkout prompt. Accept → the scene shows in the default changelist. |
| 4 | Open a second scene. Press Ctrl+S without changing anything. In Terminal: `ls -l <scene>` and `p4 opened`. | The scene is still read-only (`-r--r--r--`) and not opened. No "Unable to write" dialog. |
| 5 | Submit the default changelist with the description ``Mac test "quotes" $HOME `uname` \`` | The confirmation lists your file. Then `p4 describe -s <change>` shows the description exactly as typed: no expanded `$HOME`, no `Darwin`. |
| 6 | In the FileSystem dock, rename a tracked `.png`. Accept "Record Move". | `p4 opened` shows `move/add` + `move/delete` for the `.png` **and** its `.png.import`. Revert both afterwards. |
| 7 | Quit Godot. Delete the project's `.godot/` folder. Relaunch from the Dock. | Import runs with no "Safe save failed" or "Cannot open file" errors. Afterwards `p4 opened` is empty (or lists only real `.import` changes), and `ls -l *.import` shows them read-only. |
| 8 | Right-click a tracked `.png` → **P4: Check Out**. | `p4 opened` lists the `.png` and its `.png.import`. Revert afterwards. |
| 9 | Editor Settings → search "Executable Path". Set it to a bad path and restart Godot. | The setting exists under **Perforce**. After the restart the Log names the bad setting and falls back to the Homebrew p4. Clear it again. |

If a step fails, turn on **Verbose log** in the settings menu, repeat it,
and save the Log contents.

## Any platform: GUI-only checks (10 minutes)

The headless self-tests can't click through Godot's own docks, so check these
by hand:

| # | Do this | Expect |
|---|---|---|
| 1 | Select a tracked texture that isn't checked out. In the Import dock, change a setting (e.g. Mipmaps → Generate) and press **Reimport**. | No "Cannot save" error. `p4 opened` lists its `.import`, and the setting stuck. |
| 2 | Select it again and press **Reimport** without changing anything. | Nothing new is opened; the `.import` stays read-only. |
| 3 | Add a file named `icon@2x.png` to the project, right-click → **P4: Mark for Add**, submit it, then rename it in the FileSystem dock. | The add and submit work. The rename is recorded as `move/add` + `move/delete`. Clean up afterwards. |
| 4 | Switch scene tabs between two tracked scenes you haven't edited. | No checkout prompt. |
| 5 | Edit a tracked scene, answer the prompt with **Discard My Changes**, then edit it again. | The second edit prompts again straight away, not only at save time. |
| 6 | Check out a tracked `.gd`, add a line, save, then revert it from the P4G dock. | The script's tab stays open and shows the depot text, at roughly the line you were on. Close and reopen the file: still the depot text. |
| 7 | With Godot in front, change a tracked `.png` in another program and save it. Click back into Godot. | A dialog lists the file and offers **Check Out**. Accept: it appears in the default changelist. |
| 8 | Repeat step 7 but answer **Not Now**, then alt-tab away and back twice. | It asks once and stays quiet after that. |
| 9 | Create two new files and change one tracked file outside Godot, then press **Reconcile**. | The confirmation lists all three by name and reads `add: 2, edit: 1, delete: 0`. Accept: all three appear in the default changelist. |
| 10 | Have a teammate check out a `+l` file, change that file locally in another program, then press **Reconcile** (and separately, click back into Godot and accept the checkout). | A dialog names the file Perforce refused and says who has it. Pressing Reconcile again does not report a phantom change that nothing can clear. |
| 11 | In a project whose `project.godot` is in Perforce but whose `addons/p4godot/` is not, open the project. | On startup, a dialog explains that teammates would see the plugin fail to load, and offers **Add to Perforce**. Accept: the addon files show as adds in the default changelist. Reopen the project — it does not ask twice once answered. |
| 12 | With nothing out of date, press **Get Latest...**. | One dialog: "Your project is already up to date". No sync runs. |
| 13 | Have a teammate submit a change to a scene you have open in a tab. Press **Get Latest...**. | The confirmation names the file, gives the download size, and warns that the open tab will reload. Accept: the tab shows the new version, and the report says 1 file downloaded and 1 reloaded. |
| 14 | In a terminal: `p4 sync <file>#1`, then make that file writable and change it without checking it out. Press **Get Latest...**. | No download is offered: one dialog says nothing was downloaded, names the file under "Perforce would not overwrite", and tells you to Reconcile. The file on disk still has your change. |
| 14b | As step 14, but set the file back to read-only after changing it (`attrib +R` / `chmod a-w`). This is what a macOS or Linux save over a locked file leaves behind. | Same result as step 14. With a plain `p4 sync` this file is overwritten without a word. |
| 14c | `p4 sync <file>#1`, then make the file writable and do **not** change it. Press **Get Latest...**. | The file downloads. The report counts it and does not list it under "would not overwrite". Afterwards it is read-only again. |
| 15 | Check out a file, then have a teammate submit a change to that same file. Press **Get Latest...**. | The confirmation warns that a checked-out file is behind the server. The report names the file as needing the two versions combined and points at P4V's **Resolve**. Your version on disk is untouched. |
| 16 | Open the settings menu (the tools icon in the P4G toolbar) and choose **Connection settings...**. Press **Connect** without changing anything. | A dialog with the server address and user name filled in. After Connect, the workspace list opens, headed by `Server:` and `User:` lines, with your current workspace selected. Cancel: nothing changes. |
| 17 | In the workspace list, press **Change Server or User...**, enter an address nothing listens on (`127.0.0.1:1`), and press Connect. | The toolbar shows "Not connected" and setup asks for a server address. Open **Connection settings...** again, empty the server box, Connect: it reconnects with your normal settings. Restart Godot: still connected. |
| 18 | Click the `user @ workspace` status, pick a different workspace, then switch back the same way. | The toolbar and the changelist tree follow each switch. |
| 19 | Check out a file, have a teammate submit a change to it, then submit your changelist. | Before any description is asked for: "Perforce won't take this submit yet", naming that file and no other, with the steps (Get Latest, resolve in P4V, submit again). Nothing is sent and no numbered changelist appears. |
| 20 | Submit a changelist with a file of 50 MB or more. | A progress window opens: a bar that fills, a line like `1 of 1 file  -  12.4 MB of 50.0 MB  -  0:03`, and the file name. The editor stays usable. Closing the window does not stop the submit; the Log says so. On completion the window closes and the Log says how many files and how much data went. |
| 21 | Start the same kind of submit and press **Cancel** in the first few seconds. | The button reads "Cancelling...", then the window says it is asking the server what became of the submit. Within a few seconds: "Submit cancelled", naming the changelist your files are in. Submit that changelist again: it goes through. |
| 22 | With the project well behind the server (many files, tens of MB), press **Get Latest...** and then **Cancel** part-way. | "Get Latest was cancelled", with how many files had finished. Press **Get Latest...** again: it downloads the rest, with nothing listed under "would not overwrite" or "were not downloaded". No `t…t….tmp` files are left in the project. |
| 23 | Edit a few megabytes inside a large `binary+F` file and submit it alone. | The bar still fills. The Log line says roughly how much crossed the network, less than the file's size, and mentions Delta Transfer. |
| 24 | Make a tracked file writable outside Godot and change it without checking it out. Right-click it in the FileSystem dock → **P4: Diff vs Depot**. | The diff window opens and shows the change. (It used to say the file was identical.) |
| 25 | Rename a tracked file in the FileSystem dock. In the P4G panel, right-click the **old** name (shown as moved/deleted) → Revert. | The question reads "Undo the move of A to B?". After **Undo Move** the file is back under its old name, the new name is gone from the dock, and neither is in the panel. |
| 26 | Add `*.log` to `.p4ignore`, create `notes.log` in the project, right-click it → **P4: Mark for Add**. | A message says your ignore rules leave it out and names the rule and its line. Nothing appears in the panel. |
| 27 | Have an admin run `p4 admin resetpassword -u <you>`, then press Refresh. | "P4 Password Expired" asks for the current password, a new one, and the new one again. A wrong current password is reported and the questions start over. After a correct one the panel fills in and no login prompt follows. |
| 28 | Edit an image outside Godot, then move it to another folder in the FileSystem dock and accept **Record Move**. Submit. | The panel shows the old path as moved/deleted and the new one as moved/added, with the `.import` alongside. In P4V the file's history at the new path continues from the old one. |
| 29 | Rename `Hero.png` to `hero.png` in the FileSystem dock (any tracked file; change only capitals). | A message says the server treats both names as the same and can't record the rename, and gives the two-step way to do it. Nothing new appears in the panel. |
| 30 | Change a tracked file outside Godot without checking it out, then right-click it → **P4: Revert**. | "...was changed on your computer without being checked out. Put back the version you downloaded?" After **Put It Back** the file has its old content. |
| 31 | Move a tracked file, accept **Record Move**, then delete the moved file in the FileSystem dock and accept. | The panel shows the original path opened for delete. The file does not reappear under its old name. |
| 32 | Select several files, some already tracked and one ignored, → **P4: Mark for Add**. | One message: "Marked N of M files for add", listing the ignored and the already-tracked ones. |
| 33 | Check out `.p4ignore`, delete its `.godot/` line, save, revert the checkout with `p4 revert -k`, and restart Godot. | A question offers to add `.godot/` to '.p4ignore'. After **Add the Rule** the file is checked out with the line at its end, and Reconcile no longer lists files under `.godot/`. **Not Now** is remembered: no question at the next start. |

## Screenshots for the README

Capture on the Skeleton2D project, and save into `docs/images/` under these
names. Use a window about 1600 px wide with the editor's default theme, and
crop to the relevant area. The README placeholders are HTML comments marked 📷.

| File | What it shows |
|---|---|
| `hero-checkout.gif` | One take, 6–10 s: move a node in a scene that isn't checked out → the checkout prompt → accept → the file appears under the default changelist in the P4G dock. (ScreenToGif on Windows works well; keep it under ~5 MB.) |
| `changelist-dock.png` | The P4G dock with two or three changelists expanded, files with different actions (add/edit/delete colors), and the right-click menu open on a file row. |
| `submit-confirm.png` | The submit confirmation listing files and the description. |
| `filesystem-dock.png` | The FileSystem dock with the P4 context menu open, plus a hover tooltip like `//depot/...#3 (head #5 - out of date) opened for edit`. Two shots side by side is fine. |
| `diff-viewer.png` | The side-by-side diff window on a file with a few added and removed lines. |
| `connection-setup.png` | Optional: the workspace-suggestion dialog from connection setup. |
