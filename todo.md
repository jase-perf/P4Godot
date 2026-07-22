# TODO

- [x] Moving p4 commands off of main thread (done in v0.5.0 - worker thread; _apply_changes stays sync by necessity)
- [x] Files and changelist view (v0.7.0 - changelist tree with opened files per CL)
- [x] The current Logs should be tucked away into a window only for those who want to see it, and our main view should switch to show changelists and the files checked out in them. (v0.7.0)
- [x] We should add a `reconcile` button that can be used to find any changed files and check them out. (v0.7.0)
- [x] We should also add a `revert unchanged` button. (v0.7.0)
- [x] Create/edit changelists and submit (v0.7.0 - New Changelist, Edit Description, Move to Changelist, Submit)
- [x] Update UI with P4 branding as seen in <https://github.com/Perforce-Shared-Services/shadcn-force-ui> (v0.7.0 - cyan changelist accent + per-action colors over Godot's native theme)
- [x] Delete empty changelists; edit the default changelist (promotes to numbered); Ctrl+Enter to accept dialogs; verbose command/output log; toolbar acts on tree selection; Revert Unchanged skips files open in the editor (v0.8.0)
- Convert to compiled GDExtension to integrate with commit dock and file-status overlays
  - Add diffing in Godot
- Shelving changelists (deferred)
