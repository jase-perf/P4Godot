# TODO

- [x] Moving p4 commands off of main thread (done in v0.5.0 - worker thread; _apply_changes stays sync by necessity)
- [x] Files and changelist view (v0.7.0 - changelist tree with opened files per CL)
- [x] The current Logs should be tucked away into a window only for those who want to see it, and our main view should switch to show changelists and the files checked out in them. (v0.7.0)
- [x] We should add a `reconcile` button that can be used to find any changed files and check them out. (v0.7.0)
- [x] We should also add a `revert unchanged` button. (v0.7.0)
- [x] Create/edit changelists and submit (v0.7.0 - New Changelist, Edit Description, Move to Changelist, Submit)
- [x] Update UI with P4 branding as seen in <https://github.com/Perforce-Shared-Services/shadcn-force-ui> (v0.7.0 - cyan changelist accent + per-action colors over Godot's native theme)
- [x] Delete empty changelists; edit the default changelist (promotes to numbered); Ctrl+Enter to accept dialogs; verbose command/output log; toolbar acts on tree selection; Revert Unchanged skips files open in the editor (v0.8.0)
- [x] Diff files (v0.9.0 - `p4 diff -du` rendered in a colored diff window; no GDExtension needed)
- [x] FileSystem-dock integration (v0.10.0 - right-click P4 context menu via EditorContextMenuPlugin, hover status tooltips via EditorResourceTooltipPlugin with a cached background fstat, delete/move/rename tracking via FileSystemDock signals with `p4 reconcile -m` history-preserving moves, and an Auto add/edit/delete setting)
- GDExtension is only actually required for Godot's built-in Version Control panel (EditorVCSInterface), which is git-shaped (stage/commit/branch/push) and fits Perforce poorly. File-status overlays have NO Godot hook - they'd need an engine PR or a fragile FileSystem-dock-tree hack (GDScript-doable, no GDExtension needed). Reassess whether the commit-panel integration is worth the build cost. See memory: gdextension-vs-gdscript-assessment.
- Shelving changelists (deferred)
