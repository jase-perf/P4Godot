# TODO

## Release checklist (Godot Asset Store)

- [ ] Capture README screenshots/GIF (placeholders marked with 📷 comments in README.md) — same captures feed the store's Media tab
- [ ] Design a store thumbnail that isn't the bare Perforce logo (trademark: combine the P4 mark with the dock / a Godot motif)
- [ ] Refresh `addons/p4godot/README.md` (it is a copy of the root README — recopy after any README edit)
- [ ] Decide release version (1.0.0?), bump plugin.cfg, update CHANGELOG, tag, cut a GitHub Release
- [ ] Warnings pass: open in editor, fix/suppress all script warnings (store review checks this)
- [ ] Clean-install test: fresh 4.7 project, drop in the release zip, enable, connect
- [ ] Store submission at <https://store.godotengine.org>: publisher + asset "P4Godot", type Addon, license MIT, source link <https://github.com/jase-perf/P4Godot>, min Godot 4.7, **AI usage disclosure (mandatory)**

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
