# TODO

- [x] Moving p4 commands off of main thread (done in v0.5.0 - worker thread; _apply_changes stays sync by necessity)
- [x] Files and changelist view (v0.7.0 - changelist tree with opened files per CL)
- [x] The current Logs should be tucked away into a window only for those who want to see it, and our main view should switch to show changelists and the files checked out in them. (v0.7.0)
- [x] We should add a `reconcile` button that can be used to find any changed files and check them out. (v0.7.0)
- [x] We should also add a `revert unchanged` button. (v0.7.0)
- [x] Create/edit changelists and submit (v0.7.0 - New Changelist, Edit Description, Move to Changelist, Submit)
- [x] Update UI with P4 branding as seen in <https://github.com/Perforce-Shared-Services/shadcn-force-ui> (v0.7.0 - cyan changelist accent + per-action colors over Godot's native theme)
- Convert to compiled GDExtension to integrate with commit dock and file-status overlays
  - Add diffing in Godot
- Shelving and deleting changelists (deferred from the v0.7.0 changelist-ops pass)
