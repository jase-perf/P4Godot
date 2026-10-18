@tool
extends "p4godot_watch.gd"

## Perforce (P4) integration for the Godot editor. Requires Godot 4.7+.
##
## What it does:
## - Checkout on edit: the first time you modify a file that isn't opened for
##   edit in your P4 workspace, a dialog offers to check it out. Declining
##   discards the in-editor change by reloading the file from disk (the disk
##   copy was never touched, so nothing is lost from Perforce's perspective).
## - Checkout on save: any file you edited without checking out (e.g. with
##   checkout-on-edit disabled) is checked out automatically just before the
##   editor writes it, via EditorPlugin._apply_changes() - which the engine
##   calls before the actual file write for both scene saves and
##   script/resource saves (verified: EditorNode::_save_scene and
##   EditorNode::save_resource_in_path both call apply_changes_in_editors()
##   ahead of ResourceSaver::save()).
## - Failed-save rescue: if a scene save still fails because the file is
##   read-only and not checked out, a dialog explains why and offers to check
##   the file out and save again - instead of Godot's bare "Unable to write to
##   file" error. (Possible because EditorPlugin.scene_saved is emitted even
##   when the write fails.) All failures from one Save All are batched into a
##   single dialog.
## - Checkout failures (most commonly an exclusive checkout held elsewhere)
##   are surfaced as dialogs on every path, naming who has the file and in
##   which workspace, with honest options: at edit time, keep the stranded
##   change (checkout retries on save) or discard it; at save time, an
##   explanation of which files can't be written and why.
## - allwrite support: "needs checkout" is decided by asking Perforce
##   (`p4 fstat`), never by OS read-only attributes, so everything above also
##   works in an `allwrite` client where P4 leaves files writable. If a save
##   succeeds on a file that isn't checked out (the allwrite case), it goes
##   through `p4 reconcile -e` right after, which opens it only if it changed.
## - Delete / move / rename: deleting or moving a file (or folder) in the
##   FileSystem dock is caught via FileSystemDock signals and offered to
##   Perforce - open-for-delete for a deletion, a history-preserving move
##   (`p4 edit` + `p4 move -k`) for a rename. Prompts by default, or applies silently
##   when the "Auto add/edit/delete" setting is on.
##
## Known limitations:
## - Declining checkout on a SCENE reloads the whole scene, discarding ALL of
##   its unsaved changes, not just the triggering edit. The confirmation
##   dialog is modal, which narrows this to "the one edit" in the common case.
## - Declining checkout on a SCRIPT closes its tab (ScriptEditor.close_file()
##   is the only scriptable force-reload; reload_open_files() only acts on an
##   on-disk mtime change, which never happened here). No data loss, but the
##   tab must be reopened. close_file() is also why this plugin needs 4.7+.
## - A failed SCRIPT save with both checkout options disabled only shows
##   Godot's generic error: the engine emits no signal on a failed resource
##   write (EditorPlugin.resource_saved fires only on success).
## - project.godot writes and edits made OUTSIDE the editor are not covered
##   (use Reconcile for those). New files aren't auto-added either - Godot
##   emits no create signal, and the save handlers skip untracked files - so
##   add them with the FileSystem dock's "P4 > Mark for Add" or via Reconcile.
## - p4 commands run on a background worker thread (one at a time, in order),
##   so a slow or unreachable server no longer stalls the editor. Results are
##   cached per file per session as before. Two deliberate exceptions stay on
##   the main thread: _apply_changes() (the engine writes files the moment it
##   returns, so its checkouts must already be done - there is no async
##   window; a hung server WILL stall that save) and plugin shutdown (the
##   worker must be joined). If `p4 info` fails at startup, all automatic
##   behavior is disabled for the session.
## - Because the checkout prompt now appears only after an async fstat round
##   trip, a fast typist can land a few more keystrokes before the modal
##   opens. Those are part of the same undo history, so declining still
##   discards them together with the triggering edit (same rule as the
##   scene-reload limitation above).
# ---------------------------------------------------------------------------
# Plugin lifecycle
# ---------------------------------------------------------------------------

func _enter_tree() -> void:
	_build_dock()
	_load_settings()

	# history_changed (not version_changed!) is what fires on an ORIGINAL
	# edit: commit_action() emits history_changed; version_changed only fires
	# from undo()/redo() (verified in editor_undo_redo_manager.cpp).
	get_undo_redo().history_changed.connect(_on_undo_redo_history_changed)
	EditorInterface.get_script_editor().editor_script_changed.connect(
			_on_active_script_changed)
	scene_saved.connect(_on_scene_saved)
	resource_saved.connect(_on_resource_saved)
	var efs := EditorInterface.get_resource_filesystem()
	efs.resources_reimporting.connect(_on_resources_reimporting)
	efs.resources_reimported.connect(_on_resources_reimported)
	efs.filesystem_changed.connect(_on_filesystem_changed)
	call_deferred("_hook_import_dock")

	_p4_bin = _resolve_p4_bin()
	_p4_thread = Thread.new()
	_p4_thread.start(_p4_worker_loop)
	_sweep_cache_dir()
	_register_filesystem_hooks()
	_register_editor_menus()
	_start_watching()
	# Fire-and-forget coroutine: anything that needs the identity awaits
	# _ensure_identity() instead of assuming this has resolved.
	_detect_p4_identity()
	_log("P4Godot loaded.")
	_run_cli_self_test_if_requested()
	# Also fire-and-forget; they wait on the identity themselves.
	_check_plugin_tracked()
	_check_godot_cache_ignored()
	_offer_allwrite_once()


func _exit_tree() -> void:
	_shutting_down = true
	_unregister_filesystem_hooks()
	_unregister_editor_menus()
	_stop_watching()
	var efs := EditorInterface.get_resource_filesystem()
	if efs:
		if efs.resources_reimporting.is_connected(_on_resources_reimporting):
			efs.resources_reimporting.disconnect(_on_resources_reimporting)
		if efs.resources_reimported.is_connected(_on_resources_reimported):
			efs.resources_reimported.disconnect(_on_resources_reimported)
		if efs.filesystem_changed.is_connected(_on_filesystem_changed):
			efs.filesystem_changed.disconnect(_on_filesystem_changed)
	if is_instance_valid(_import_reimport_button) \
			and _import_reimport_button.button_down.is_connected(_on_import_reimport_down):
		_import_reimport_button.button_down.disconnect(_on_import_reimport_down)
	_import_reimport_button = null
	if get_undo_redo().history_changed.is_connected(_on_undo_redo_history_changed):
		get_undo_redo().history_changed.disconnect(_on_undo_redo_history_changed)
	var script_editor := EditorInterface.get_script_editor()
	if script_editor and script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)
	_disconnect_current_code_edit()
	if _p4_thread:
		_p4_queue_mutex.lock()
		_p4_thread_exit = true
		_p4_queue_mutex.unlock()
		_p4_queue_semaphore.post()
		# A submit or sync still transferring: stop watching it and let p4
		# finish on its own, so closing the editor doesn't cut it off.
		if _streamed_req != null:
			_streamed_req.detach = true
			_log("Leaving the running Perforce transfer to finish in the background.")
		# Blocks until any p4 command already running finishes - a hung server
		# can delay plugin unload, but a Thread must be joined before freeing.
		_p4_thread.wait_to_finish()
		_p4_thread = null
		# Fail out whatever was still queued (exit_code stays -1, which every
		# consumer reads as failure) so no coroutine is left suspended forever.
		for req: P4Request in _p4_queue:
			req._finish()
		_p4_queue.clear()
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free() # Cascades to log_window/diff_window and their descendants.
		dock = null
		log_window = null
		log_box = null
		diff_window = null
		history_window = null
		_history_tree = null
		shelves_window = null
		_shelves_tree = null
		_shelf_files_tree = null
		diff_left = null
		diff_right = null
		diff_left_label = null
		diff_right_label = null
		diff_prev_button = null
		diff_next_button = null
		diff_change_label = null
		diff_full_file_toggle = null
		_diff_rows.clear()
		_diff_change_blocks.clear()


## The self-tests live outside the addon (tests/p4godot_test.gd), in a
## plugin that extends this one and overrides this. Nothing to do here.
func _run_cli_self_test_if_requested() -> void:
	pass
