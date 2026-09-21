# TODO

## Release checklist (Godot Asset Store)

- [ ] Capture README screenshots/GIF (placeholders marked with 📷 comments in README.md) — same captures feed the store's Media tab
- [ ] Design a store thumbnail that isn't the bare Perforce logo (trademark: combine the P4 mark with the dock / a Godot motif)
- [ ] Refresh `addons/p4godot/README.md` (it is a copy of the root README — recopy after any README edit)
- [ ] Decide release version (1.0.0?), bump plugin.cfg, update CHANGELOG, tag, cut a GitHub Release
- [ ] Warnings pass: open in editor, fix/suppress all script warnings (store review checks this)
- [ ] Clean-install test: fresh 4.7 project, drop in the release zip, enable, connect
- [ ] Store submission at <https://store.godotengine.org>: publisher + asset "P4Godot", type Addon, license MIT, source link <https://github.com/jase-perf/P4Godot>, min Godot 4.7, **AI usage disclosure (mandatory)**

## Allwrite workspaces + change detection (Godot) — designed, not started

Goal: make `allwrite` workspaces the smooth path. Godot rewrites files it didn't change (every `.import` on each reimport, re-saved scenes), which errors in read-only workspaces. Detect edits from any tool, including external editors, and open them in Perforce after the fact.

- [ ] Bug: FileSystem-dock renames call `p4 reconcile -m`, which is the timestamp flag; move detection is `-M`. Renames record delete + add and lose history. Fix `_p4_record_move` and the README/CHANGELOG wording.
- [ ] Bug (allwrite): `_scene_saved_probe` and `_on_resource_saved` run `p4 edit` after any successful save with no content check, so Ctrl+S on an untouched file opens it. Route them through reconcile.
- [ ] Bug (allwrite): `_checked_out_this_session` only grows. After a P4V submit or revert, new edits to that file are ignored. Rebuild it from `p4 opened` on every refresh.
- [ ] Bug: submitting the default changelist runs `submit -d <desc> <project scope>`, which would include files opened after the confirm dialog appeared. Submit the confirmed file list.
- [ ] Workspace check at startup and in connection setup: offer `noallwrite` → `allwrite` (keep `noclobber` while the plugin is the only watcher); clear the read-only bit on synced files under the project folder (batch chmod on macOS/Linux; never `p4 sync -f`); offer switch-back; warn if `.godot/` isn't ignored.
- [ ] Verified-mtime cache: per file {mtime, size, verdict}, with the verdict written only from a reconcile result. A file whose mtime differs gets reconciled without `-m` (full digest). No dependence on the client `modtime` option; a no-op rewrite is digested once; failed reconciles retry; saved to disk so startup only checks files changed while Godot was closed. Recheck verdicts recorded within ~2 s of the file's mtime (1-second timestamps).
- [ ] Background scanner (polling, own thread) feeding the cache: on editor focus-in, `filesystem_changed`, and an adaptive timer, plus exact paths from `scene_saved` / `resource_saved` / `resources_reimported`. Skip `.godot/`, Godot's safe-save `.tmp`, `*.blend1`, `~$*`. Act only once a file's mtime is ≥2 s old and unchanged across two scans.
- [ ] Reconcile queue: `p4 -x <file> -b <n>` (`-b` ≥ list size, or move pairs split across the default 128-argument batches), `-e -a -d -M`, verify with one batched `fstat`, and don't delay the interactive checkout-on-edit `fstat`.
- [ ] UX: detected edits open silently; adds/deletes go to a non-modal "Detected changes" dock group; a Godot upgrade that changes every `.import` asks once; exclusive-lock conflicts batched into one dialog (Revert = `p4 clean -e`; Keep = back up the file and list it under "Not checked out" with the lock holder; never auto-open after the head revision moved).
- [ ] `_apply_changes` allwrite branch: skip the blocking checkout and fix the "can't be written" wording.
- [ ] Live tests needing a second throwaway workspace: reconcile against a `+l` file held elsewhere; allwrite+noclobber running `sync -s` by default.
- [ ] Fallback for teams that stay read-only: on `resources_reimporting`, make each `.import` writable; afterwards restore only the read-only bit and keep Godot's LF content (Godot caches the `.import` md5, so restoring the old bytes causes a reimport loop). Admin alternative: typemap `text+w //....import`.
- Open decisions: scanner scope (project folder vs whole workspace root); silent open vs prompt for detected edits.
- Verified 2026-09-17 on the Skeleton2D workspace (2025.2 server, `text` files, LineEnd local): `reconcile -e` and `sync -s` both ignore a CRLF→LF-only rewrite and catch real edits; `reconcile -m` trusts mtime alone (a real edit with the original mtime restored is missed). Godot 4.7 `_reimport_file` writes `.import` unconditionally and, if that fails, skips the `.md5` that stops the next reimport, so read-only `.import` files error on every launch. GDScript mtime scan: ~0.7 s per 20,000 files.

## Future idea: one machine-wide workspace watcher (not now — Godot first)

- A standalone, always-running app that efficiently watches every P4 workspace on the machine (threaded, background) and exposes a local API, so plugins for Godot, Photoshop, Blender, and other DCC tools share one implementation, and edits are caught even when Godot is closed.
- Detect with polling plus the verified-mtime cache, not OS change notifications: Helix Sync reportedly avoided Windows change notifications because events got lost. (Helix Sync is retired.)
- P4 One watches only P4 One workspaces, and (we believe) only files/folders marked as tracked. That subsetting exists for performance: full reconciles take seconds to minutes on very large workspaces. P4 One also has some mtime-change detection; how the two interact is unknown.
- If an always-on watcher owns syncs, `clobber` (what P4 One and Helix Sync default to) becomes reasonable. While only the Godot plugin watches, keep `noclobber`.
- Build the Godot detection behind a "change source" boundary so this service could feed it later.

- [x] Side-by-side diff viewer (v0.12.0 - p4merge-style: depot#have vs workspace panes from `p4 print -q` + local file, rows aligned via `p4 diff -dul` hunks, full-row add/delete backgrounds, filler rows, baked line-number gutter, intraline changed-span highlighting via a custom SyntaxHighlighter, synced scrolling)
- [x] Moving p4 commands off of main thread (done in v0.5.0 - worker thread; _apply_changes stays sync by necessity)
- [x] Files and changelist view (v0.7.0 - changelist tree with opened files per CL)
- [x] The current Logs should be tucked away into a window only for those who want to see it, and our main view should switch to show changelists and the files checked out in them. (v0.7.0)
- [x] We should add a `reconcile` button that can be used to find any changed files and check them out. (v0.7.0)
- [x] We should also add a `revert unchanged` button. (v0.7.0)
- [x] Create/edit changelists and submit (v0.7.0 - New Changelist, Edit Description, Move to Changelist, Submit)
- [x] Update UI with P4 branding as seen in <https://github.com/Perforce-Shared-Services/shadcn-force-ui> (v0.7.0 - cyan changelist accent + per-action colors over Godot's native theme)
- [x] Delete empty changelists; edit the default changelist (promotes to numbered); Ctrl+Enter to accept dialogs; verbose command/output log; toolbar acts on tree selection; Revert Unchanged skips files open in the editor (v0.8.0)
- [x] Diff files (v0.9.0 - `p4 diff -du` rendered in a colored diff window; no GDExtension needed)
- [x] Guided connection setup (server/login/workspace wizard with root-matched workspace suggestions, per-project -p/-u/-c overrides), re-login prompt on expired tickets, line-ending-tolerant diffs (`p4 diff -dul`), drag-and-drop between changelists, single-row toolbar with connection status + gear settings menu (v0.11.0)
- [x] Checkout prompts offer a target-changelist dropdown (checkout-on-edit + failed-save rescue, `p4 edit -c N`); no-change saves of read-only files no longer prompt (failed safe-save .tmp content compared against disk, CRLF-tolerant, tmp litter deleted) (v0.13.0)
- [x] FileSystem-dock integration (v0.10.0 - right-click P4 context menu via EditorContextMenuPlugin, hover status tooltips via EditorResourceTooltipPlugin with a cached background fstat, delete/move/rename tracking via FileSystemDock signals with `p4 reconcile -m` history-preserving moves, and an Auto add/edit/delete setting)
- GDExtension is only actually required for Godot's built-in Version Control panel (EditorVCSInterface), which is git-shaped (stage/commit/branch/push) and fits Perforce poorly. File-status overlays have NO Godot hook - they'd need an engine PR or a fragile FileSystem-dock-tree hack (GDScript-doable, no GDExtension needed). Reassess whether the commit-panel integration is worth the build cost. See memory: gdextension-vs-gdscript-assessment.
- Shelving changelists (deferred)
