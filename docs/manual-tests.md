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

## Any platform: GUI-only checks (5 minutes)

The headless self-tests can't click through Godot's own docks, so check these
by hand:

| # | Do this | Expect |
|---|---|---|
| 1 | Select a tracked texture that isn't checked out. In the Import dock, change a setting (e.g. Mipmaps → Generate) and press **Reimport**. | No "Cannot save" error. `p4 opened` lists its `.import`, and the setting stuck. |
| 2 | Select it again and press **Reimport** without changing anything. | Nothing new is opened; the `.import` stays read-only. |
| 3 | Add a file named `icon@2x.png` to the project, right-click → **P4: Mark for Add**, submit it, then rename it in the FileSystem dock. | The add and submit work. The rename is recorded as `move/add` + `move/delete`. Clean up afterwards. |
| 4 | Switch scene tabs between two tracked scenes you haven't edited. | No checkout prompt. |

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
