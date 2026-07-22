@tool
extends EditorPlugin

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
##   succeeds on a file that isn't checked out (the allwrite case), the file
##   is checked out right after so the changelist stays truthful.
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
## - FileSystem dock operations (move/rename/delete), project.godot writes,
##   and edits made outside the editor are not covered.
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

const SETTINGS_SECTION := "p4_plugin"

# A light P4 brand accent over Godot's native theme (from the Perforce Force UI
# palette). The dock otherwise uses editor theme colors/icons so it reads native.
const P4_ACCENT := Color("00cfff") # cyan - tints the changelist icons
const ACTION_ADD_COLOR := Color("138613") # green
const ACTION_EDIT_COLOR := Color("0084e8") # info blue
const ACTION_DELETE_COLOR := Color("d11323") # cranberry


## One queued `p4` invocation, executed on the worker thread. `done` is emitted
## on the MAIN thread (the worker hands the result back via call_deferred), so
## an awaiting coroutine always resumes on the main thread - no locking needed
## anywhere outside the queue itself.
class P4Request extends RefCounted:
	signal done
	var args: PackedStringArray
	# When set, p4 is run through the platform shell with this file redirected
	# onto its stdin (for `p4 change -i`, whose spec input OS.execute can't feed).
	var stdin_path: String = ""
	var exit_code: int = -1
	var output: Array = []
	var completed: bool = false

	func _finish() -> void:
		completed = true
		done.emit()


## Emitted once the startup `p4 info` has resolved, successfully or not.
## _ensure_identity() awaits it so hooks that fire during the first moments of
## the session can't race the detection.
signal identity_checked

var dock: VBoxContainer
var log_box: TextEdit
var log_window: Window
var tree: Tree
var context_menu: PopupMenu
var move_submenu: PopupMenu
var new_changelist_button: Button
var reconcile_button: Button
var revert_unchanged_button: Button
var auto_checkout_checkbox: CheckBox
var checkout_on_save_checkbox: CheckBox

# Metadata dict of the row a context-menu action targets (captured at right-click
# so the action still knows its subject after the menu closes the selection).
var _context_target: Dictionary = {}
# The changelists from the last refresh - drives the "Move to Changelist" submenu
# without a re-query.
var _last_changelists: Array = []
# Parallel to the move submenu's items: index -> target change key ("default", a
# number, or "__new__"). Rebuilt each time the submenu is populated.
var _move_targets: Array = []

# Guards for the changelist-tree refresh coroutine. It awaits several p4 calls,
# during which another mutation or a visibility event can fire - _refresh_inflight
# coalesces those into a single in-flight refresh plus at most one re-run
# (_refresh_pending), so the tree can't end stale and clicks can't stack.
var _refresh_inflight: bool = false
var _refresh_pending: bool = false

# False when `p4 info` failed at startup (p4 missing/unconfigured). All
# automatic hooks bail out early so the plugin never issues doomed p4 calls.
var _p4_available: bool = false
# True once that startup check has RESOLVED either way; identity_checked fires
# at the same moment.
var _identity_checked: bool = false

# The p4 worker: a single thread draining _p4_queue in FIFO order. One command
# at a time keeps operations on the same file naturally serialized (an edit
# and its verifying fstat can never interleave with another request's edit).
var _p4_thread: Thread
var _p4_queue: Array = []
var _p4_queue_mutex := Mutex.new()
var _p4_queue_semaphore := Semaphore.new()
var _p4_thread_exit: bool = false
# Queued-or-running p4 commands. Main-thread-only counter (incremented on
# enqueue, decremented when the awaiting caller resumes); the self-tests use
# it to wait for genuine idle instead of guessing at frame counts.
var _p4_inflight: int = 0

# Set during _exit_tree() so continuations resumed mid-teardown (queued
# requests are failed-out so no coroutine hangs) don't pop dialogs.
var _shutting_down: bool = false

# Our own P4 identity from `p4 info`, so "someone else has this open" can be
# told apart from our own checkout in `p4 opened -a` output.
var _p4_user: String = ""
var _p4_client: String = ""

# res:// path -> true. Session caches so we don't shell out to p4 on every
# keystroke/save:
# - _checked_out_this_session: we confirmed the file is opened in our client.
# - _declined_this_session: the user declined the edit-time checkout prompt;
#   suppresses re-prompting (important if the discard-reload failed and the
#   change survived - without this, every subsequent keystroke would re-prompt).
# - _pending_save_checkout: edited without checkout (e.g. checkout-on-edit
#   disabled); to be checked out in _apply_changes() just before a save.
var _checked_out_this_session: Dictionary = {}
var _declined_this_session: Dictionary = {}
var _pending_save_checkout: Dictionary = {}

# res:// path -> true while an edit-time checkout decision for that file is in
# flight (async fstat probe or open prompt). Keystrokes stream in continuously
# and the caches above only update once the flow RESOLVES - without this,
# every keystroke during the async gap would stack another prompt.
var _inflight_edit_checks: Dictionary = {}

# Whichever CodeEdit backs the active script tab. ScriptEditor's
# editor_script_changed only tells us the active TAB changed (it even fires
# for tabs restored at startup) - real keystrokes come from the CodeEdit's own
# text_changed signal, so we track and re-hook the active one.
var _current_code_edit: CodeEdit = null
var _current_script_path: String = ""

# Set while WE reload a file (reload_scene_from_path() internally calls
# EditorUndoRedoManager.clear_history(), which emits history_changed) so our
# own reload can't re-trigger the checkout prompt it was just declining.
var _suppress_auto_checkout: bool = false

# Pending confirm-dialog state. MUST be member vars, not locals captured by a
# signal-connected lambda: GDScript lambdas capturing a local do NOT share
# storage with the enclosing coroutine (verified via isolated repro - the
# lambda runs and sets its own copy, but an awaiting `while` loop in the
# function never sees the change and hangs forever). _dialog_busy serializes
# access so stacked prompts (e.g. several failed saves during Save All) can't
# clobber each other's state.
var _dialog_busy: bool = false
var _dialog_result_ready: bool = false
var _dialog_result_confirmed: bool = false

# Failed-save rescue batching. Save All emits one scene_saved per scene;
# failures accumulate here and a single deferred dialog covers them all,
# instead of one popup per file. Discovery is now asynchronous (fstat probes
# on the worker thread), so the dialog additionally waits for
# _rescue_probes_inflight to reach zero before snapshotting - every probe
# increments it synchronously at handler entry, BEFORE its first await, which
# is what keeps one save pass = one dialog.
var _rescue_paths: Array = []
var _rescue_scheduled: bool = false
var _rescue_probes_inflight: int = 0

# res:// path -> frame number. Set when a checkout attempt for the file just
# failed during this same save pass (_apply_changes or a rescue retry), so the
# imminent failed write doesn't ALSO queue a rescue dialog - the user was
# already told why the checkout failed. Entries only count in the frame they
# were set; scene_saved handlers therefore consume them at entry, before their
# first await, while still inside the save pass's frame.
var _rescue_skip_frame: Dictionary = {}

# CLI self-test only: "confirm"/"decline" auto-answers dialogs by emitting the
# same signal a real button click would (see the self-test section below).
var _selftest_auto_answer: String = ""


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
	get_editor_interface().get_script_editor().editor_script_changed.connect(
			_on_active_script_changed)
	scene_saved.connect(_on_scene_saved)
	resource_saved.connect(_on_resource_saved)

	_p4_thread = Thread.new()
	_p4_thread.start(_p4_worker_loop)
	# Fire-and-forget coroutine: anything that needs the identity awaits
	# _ensure_identity() instead of assuming this has resolved.
	_detect_p4_identity()
	_log("P4 plugin loaded.")
	_run_cli_self_test_if_requested()


func _exit_tree() -> void:
	_shutting_down = true
	if get_undo_redo().history_changed.is_connected(_on_undo_redo_history_changed):
		get_undo_redo().history_changed.disconnect(_on_undo_redo_history_changed)
	var script_editor := get_editor_interface().get_script_editor()
	if script_editor and script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)
	_disconnect_current_code_edit()
	if _p4_thread:
		_p4_queue_mutex.lock()
		_p4_thread_exit = true
		_p4_queue_mutex.unlock()
		_p4_queue_semaphore.post()
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
		dock.queue_free() # Cascades to log_window and log_box (its descendants).
		dock = null
		log_window = null
		log_box = null


func _detect_p4_identity() -> void:
	var result: Dictionary = await _p4_exec(["info"])
	if result.exit_code == 0 and not result.output.is_empty():
		for raw_line in String(result.output[0]).split("\n"):
			var line: String = raw_line.strip_edges()
			if line.begins_with("User name:"):
				_p4_user = line.substr("User name:".length()).strip_edges()
			elif line.begins_with("Client name:"):
				_p4_client = line.substr("Client name:".length()).strip_edges()
		_p4_available = true
	else:
		_log("Warning: 'p4 info' failed - is p4 installed and configured? Automatic checkout is disabled for this session.")
	_identity_checked = true
	identity_checked.emit()


## Awaitable gate: resolves to _p4_available once the startup `p4 info` check
## has finished. Everything automatic funnels through this so nothing acts on
## a not-yet-known identity.
func _ensure_identity() -> bool:
	if not _identity_checked:
		await identity_checked
	return _p4_available


# ---------------------------------------------------------------------------
# Settings (persisted per-project, per-user via editor metadata - never
# written into project files, so they don't churn version control)
# ---------------------------------------------------------------------------

func _load_settings() -> void:
	var settings := get_editor_interface().get_editor_settings()
	auto_checkout_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "auto_checkout_on_edit", true)
	checkout_on_save_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "checkout_on_save", true)


func _on_setting_toggled(_pressed: bool) -> void:
	var settings := get_editor_interface().get_editor_settings()
	settings.set_project_metadata(SETTINGS_SECTION, "auto_checkout_on_edit",
			auto_checkout_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "checkout_on_save",
			checkout_on_save_checkbox.button_pressed)


# ---------------------------------------------------------------------------
# Edit detection - "checkout on edit"
# ---------------------------------------------------------------------------

func _on_undo_redo_history_changed() -> void:
	# _suppress_auto_checkout is frame-scoped, so it must be read here,
	# synchronously with the emission. p4 availability is _handle_edit's
	# problem (it can await the startup check; this handler can't).
	if _suppress_auto_checkout:
		return

	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		var scene_path := scene_root.get_scene_file_path()
		if not scene_path.is_empty():
			_handle_edit(scene_path)

	# A standalone resource opened from the FileSystem dock (e.g. a .tres not
	# belonging to any scene) commits into a history that isn't tied to the
	# edited scene root above - catch it via the Inspector instead.
	var edited_object := get_editor_interface().get_inspector().get_edited_object()
	if edited_object is Resource:
		var res: Resource = edited_object
		if not res.is_built_in() and not res.resource_path.is_empty():
			_handle_edit(res.resource_path)


func _on_active_script_changed(script: Script) -> void:
	_disconnect_current_code_edit()
	if script == null or script.resource_path.is_empty():
		return
	var current_editor := get_editor_interface().get_script_editor().get_current_editor()
	if current_editor == null:
		return
	var base_editor := current_editor.get_base_editor()
	if base_editor is CodeEdit:
		_current_code_edit = base_editor
		_current_script_path = script.resource_path
		_current_code_edit.text_changed.connect(_on_current_script_text_changed)


func _on_current_script_text_changed() -> void:
	if _current_script_path.is_empty():
		return
	_handle_edit(_current_script_path)


func _disconnect_current_code_edit() -> void:
	if _current_code_edit and is_instance_valid(_current_code_edit) \
			and _current_code_edit.text_changed.is_connected(_on_current_script_text_changed):
		_current_code_edit.text_changed.disconnect(_on_current_script_text_changed)
	_current_code_edit = null
	_current_script_path = ""


## A user edit landed on res_path. Prompt to check out now (checkout-on-edit
## enabled), or remember it for save time.
func _handle_edit(res_path: String) -> void:
	if _identity_checked and not _p4_available:
		return # p4 was unavailable at startup - the plugin is inert.
	if _checked_out_this_session.has(res_path) \
			or _declined_this_session.has(res_path) \
			or _pending_save_checkout.has(res_path) \
			or _inflight_edit_checks.has(res_path):
		return
	# The caches only update once the flow below RESOLVES (fstat round trip,
	# maybe a prompt) - hold the in-flight marker across it so the keystrokes
	# streaming in meanwhile don't each start another flow.
	_inflight_edit_checks[res_path] = true
	await _handle_edit_inner(res_path)
	_inflight_edit_checks.erase(res_path)


func _handle_edit_inner(res_path: String) -> void:
	if not await _ensure_identity():
		return
	if not await _needs_checkout(ProjectSettings.globalize_path(res_path)):
		_checked_out_this_session[res_path] = true
		return

	if auto_checkout_checkbox.button_pressed:
		await _prompt_then_checkout(res_path)
	else:
		_pending_save_checkout[res_path] = true
		_log("'%s' was edited but isn't checked out - it will be handled when you save." % res_path)


func _prompt_then_checkout(res_path: String) -> void:
	_log("'%s' isn't checked out - prompting..." % res_path)
	var proceed: bool = await _show_confirm_dialog(
			"'%s' isn't checked out of Perforce yet.\n\nCheck it out now so your change can be saved?" % res_path,
			"Check Out", "Discard My Changes")
	if proceed:
		var result: Dictionary = await _do_checkout(res_path)
		if not result.ok:
			await _on_edit_checkout_failed(res_path, result.reason)
	else:
		_log("Declined checkout of '%s' - discarding the in-editor change and reloading from disk..." % res_path)
		# _reload_path() clears _declined_this_session (so manual Revert/Sync/
		# Reload get a clean slate) - set the flag AFTER calling it, or it
		# would be wiped immediately and every keystroke would re-prompt.
		_reload_path(res_path)
		_declined_this_session[res_path] = true


## The user said "Check Out" but Perforce refused (most commonly: someone else
## has the file exclusively checked out). Their edit is stranded - it exists
## in the editor but can't reach disk - so explain who has the file and offer
## the two honest options: keep working (checkout retries on save, in case the
## lock clears) or discard the change now.
func _on_edit_checkout_failed(res_path: String, reason: String) -> void:
	var keep: bool = await _show_confirm_dialog(
			("Couldn't check out '%s' - %s.\n\n" +
			"Your change is still in the editor, but it can't be saved until the file " +
			"becomes available (ask the holder to submit, shelve, or revert it).\n\n" +
			"Keep your change (checkout will be retried when you save), or discard it " +
			"and reload the file from disk?") % [res_path, reason],
			"Keep My Changes", "Discard My Changes")
	if keep:
		# Also stops _handle_edit() from re-prompting on every keystroke.
		_pending_save_checkout[res_path] = true
		_log("Keeping in-editor changes to '%s'; checkout will be retried on save." % res_path)
	else:
		_log("Discarding the in-editor change to '%s' and reloading from disk..." % res_path)
		_reload_path(res_path)
		_declined_this_session[res_path] = true


# ---------------------------------------------------------------------------
# Save-time hooks - "checkout on save" and failed-save rescue
# ---------------------------------------------------------------------------

## Called by the editor BEFORE it writes files, for both scene saves
## (EditorNode::_save_scene) and script/resource saves
## (EditorNode::save_resource_in_path). Checking out pending files here means
## the write that immediately follows succeeds on the first try.
##
## This hook is synchronous - the engine writes the files the moment it
## returns, so the checkouts must already be DONE: this is the one place p4
## still runs blocking on the main thread (a hung server will stall this
## save). No dialog can be awaited from here either, so save-time checkout is
## deliberately silent: the user explicitly chose to save, which makes their
## intent to keep the changes clear. Failures fall through to the
## _on_scene_saved() rescue below - as does the edge case where a save lands
## before the startup `p4 info` has resolved (_p4_available still false).
func _apply_changes() -> void:
	if not _p4_available or not checkout_on_save_checkbox.button_pressed:
		return
	var failures: Array = []
	for res_path: String in _pending_save_checkout.keys():
		_log("Checking out '%s' before saving..." % res_path)
		var result: Dictionary = _do_checkout_sync(res_path)
		if not result.ok:
			failures.append("- '%s': %s" % [res_path, result.reason])
			# The write that follows will fail too; the alert below already
			# explains why, so don't ALSO queue the failed-save rescue dialog.
			_rescue_skip_frame[res_path] = Engine.get_process_frames()
	if not failures.is_empty():
		_show_alert(("Perforce couldn't check out before saving:\n\n%s\n\n" +
				"Unsaved changes to these files stay in the editor, but the files can't " +
				"be written until they become available (ask the holder to submit, shelve, " +
				"or revert them). Checkout is retried automatically on your next save.")
				% "\n".join(failures))


## Emitted for every scene save ATTEMPT - including failed ones (verified:
## EditorNode::_save_scene emits scene_saved before it checks the
## ResourceSaver::save() error). That makes it our chance to turn Godot's bare
## "Unable to write to file" into an actionable offer.
func _on_scene_saved(path: String) -> void:
	# The probe counter must move synchronously with the emission (before any
	# await) so _run_rescue_flow() knows a discovery is still in flight.
	_rescue_probes_inflight += 1
	await _scene_saved_probe(path)
	_rescue_probes_inflight -= 1


func _scene_saved_probe(path: String) -> void:
	var res_path := ProjectSettings.localize_path(path)
	# Frame-scoped state, consumed BEFORE the first await while this is still
	# the save pass's frame: was a checkout for this file just refused (by
	# _apply_changes or a rescue retry)? Then the user has already been told
	# why this write failed - don't stack a doomed rescue offer on top.
	var skip_frame: int = _rescue_skip_frame.get(res_path, -1)
	_rescue_skip_frame.erase(res_path)
	var checkout_was_refused_this_save := skip_frame == Engine.get_process_frames()
	# Deferred because scene_saved is emitted BEFORE the editor writes the
	# scene's modified external resources (EditorNode::_save_external_resources
	# runs after the signal); by the time deferreds run, those writes - and
	# their failures - have happened. Checked for EVERY scene save: the scene
	# itself saving fine doesn't mean its companion resources did.
	call_deferred("_check_failed_dependency_writes", res_path)
	if not await _ensure_identity():
		return
	if _checked_out_this_session.has(res_path):
		return
	var global_path := ProjectSettings.globalize_path(res_path)
	if not await _needs_checkout(global_path):
		_checked_out_this_session[res_path] = true
		_pending_save_checkout.erase(res_path)
		return

	# Not checked out. Whether the write actually succeeded tells us which
	# situation we're in: writable file = the save went through without a
	# checkout (allwrite client), read-only file = the save just failed.
	if FileAccess.open(global_path, FileAccess.READ_WRITE) != null:
		_log("'%s' was saved while not checked out (allwrite client?) - checking it out to keep the changelist accurate." % res_path)
		var result: Dictionary = await _do_checkout(res_path)
		if not result.ok:
			_show_alert(("'%s' was saved to disk but couldn't be checked out - %s.\n\n" +
					"Perforce doesn't know about this change yet. Once the file becomes " +
					"available, use 'Checkout Current File' (or `p4 reconcile`) so the " +
					"change lands in a changelist.") % [res_path, result.reason])
		return

	if checkout_was_refused_this_save:
		_log("Save of '%s' failed (checkout was refused this save - see above)." % res_path)
		return

	_log("Save of '%s' failed: the file is read-only and not checked out." % res_path)
	# Batch: Save All emits one scene_saved per failed scene - queue them all
	# into ONE rescue dialog instead of a popup per file.
	if not _rescue_paths.has(res_path):
		_rescue_paths.append(res_path)
	if not _rescue_scheduled:
		_rescue_scheduled = true
		call_deferred("_run_rescue_flow")


## Saving a scene also saves its MODIFIED external resources (e.g. a .tres
## that got format-upgraded when the project loaded) - and a failed write
## there emits NO signal at all (resource_saved is success-only). The evidence
## is on disk instead: a failed safe-save leaves a fresh "<name><digits>.tmp"
## next to the target. A dependency that is Perforce-tracked, not checked out,
## and has such a fresh temp just failed to write - queue it into the same
## batched rescue dialog as failed scenes.
func _check_failed_dependency_writes(scene_path: String) -> void:
	_rescue_probes_inflight += 1
	await _dependency_writes_probe(scene_path)
	_rescue_probes_inflight -= 1


func _dependency_writes_probe(scene_path: String) -> void:
	if not await _ensure_identity():
		return
	for dep: String in ResourceLoader.get_dependencies(scene_path):
		# Entries may be "uid://xxx::res://path" - take the path part.
		var dep_path := dep.get_slice("::", dep.get_slice_count("::") - 1)
		if not dep_path.begins_with("res://"):
			continue
		var ext := dep_path.get_extension().to_lower()
		if ext != "tres" and ext != "res":
			continue # Imported assets and scripts aren't written on scene save.
		if _checked_out_this_session.has(dep_path) or _rescue_paths.has(dep_path):
			continue
		var global_path := ProjectSettings.globalize_path(dep_path)
		if not _has_fresh_failed_write_tmp(global_path):
			continue
		if not await _needs_checkout(global_path):
			_checked_out_this_session[dep_path] = true
			continue
		# Re-check after the await: a probe for another scene sharing this
		# dependency may have queued (or checked out) the file meanwhile.
		if _checked_out_this_session.has(dep_path) or _rescue_paths.has(dep_path):
			continue
		_log("Saving '%s' also failed to write its resource '%s' (read-only and not checked out)." % [scene_path, dep_path])
		_rescue_paths.append(dep_path)
		if not _rescue_scheduled:
			_rescue_scheduled = true
			call_deferred("_run_rescue_flow")


## A safe-save that could not replace its read-only target leaves the temp
## file behind; one modified in the last few seconds means a write just
## failed. (Verified live: every failed editor save leaves exactly one.)
func _has_fresh_failed_write_tmp(global_path: String) -> bool:
	var dir := DirAccess.open(global_path.get_base_dir())
	if dir == null:
		return false
	var fname := global_path.get_file()
	var now := Time.get_unix_time_from_system()
	for f in dir.get_files():
		if not (f.begins_with(fname) and f.ends_with(".tmp")):
			continue
		var middle := f.substr(fname.length(), f.length() - fname.length() - 4)
		if not middle.is_valid_int():
			continue
		var tmp_path := global_path.get_base_dir().path_join(f)
		if now - FileAccess.get_modified_time(tmp_path) < 10.0:
			return true
	return false


## One dialog covering every save that failed for lack of a checkout in this
## save pass. Confirm -> check out all of them, explain any that Perforce
## refused (exclusive checkouts, by whom and where), and re-save the rest.
func _run_rescue_flow() -> void:
	# Wait for every in-flight save probe (scene handlers and deferred
	# dependency checks, each holding _rescue_probes_inflight) to settle before
	# snapshotting - their fstat round trips resolve asynchronously, and this
	# is what keeps all failures from one save pass in ONE dialog. The time cap
	# means a leaked counter degrades to a split dialog instead of parking the
	# rescue forever.
	await get_tree().process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while _rescue_probes_inflight > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var paths: Array = _rescue_paths.duplicate()
	_rescue_paths.clear()
	_rescue_scheduled = false
	if paths.is_empty():
		return

	var message: String
	var ok_text: String
	if paths.size() == 1:
		message = ("Saving '%s' failed because it isn't checked out of Perforce " +
				"(the file is read-only).\n\nCheck it out and save again?") % paths[0]
		ok_text = "Check Out and Save"
	else:
		var lines: Array = []
		for p in paths:
			lines.append("- '%s'" % p)
		message = ("These files couldn't be saved because they aren't checked out " +
				"of Perforce (the files are read-only):\n\n%s\n\nCheck them out and " +
				"save again?") % "\n".join(lines)
		ok_text = "Check Out All and Save"

	var proceed: bool = await _show_confirm_dialog(message, ok_text, "Not Now")
	if not proceed:
		_log("File(s) remain unsaved. Check them out (P4 dock or `p4 edit`) when you're ready.")
		return

	var succeeded: Array = []
	var failed_paths: Array = []
	var failures: Array = []
	for res_path: String in paths:
		var result: Dictionary = await _do_checkout(res_path)
		if result.ok:
			succeeded.append(res_path)
		else:
			failed_paths.append(res_path)
			failures.append("- '%s': %s" % [res_path, result.reason])
	if not failures.is_empty():
		await _show_alert(("Perforce couldn't check out:\n\n%s\n\n" +
				"These files stay unsaved until they become available (ask the holder " +
				"to submit, shelve, or revert them). Save again later to retry.")
				% "\n".join(failures))
	if succeeded.is_empty():
		return

	# Re-save. Mark the still-refused files first so their (inevitably failing)
	# writes during this retry don't queue yet another rescue dialog.
	for res_path: String in failed_paths:
		_rescue_skip_frame[res_path] = Engine.get_process_frames()
	_log("Checked out %s - saving again..." % ", ".join(succeeded))

	var scenes: Array = []
	for res_path: String in succeeded:
		var ext := res_path.get_extension().to_lower()
		if ext == "tscn" or ext == "scn":
			scenes.append(res_path)
		else:
			# A plain resource (its scene saved fine; only this companion file
			# failed) - the modified instance is still in the resource cache,
			# so write it out directly.
			var res := ResourceLoader.load(res_path)
			if res == null:
				_log("Could not reload '%s' to save it." % res_path)
				continue
			var err := ResourceSaver.save(res, res_path)
			if err == OK:
				_log("Saved '%s'." % res_path)
			else:
				_log("Saving '%s' still failed (error %d)." % [res_path, err])
	if scenes.is_empty():
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scenes.size() == 1 and scene_root \
			and scene_root.get_scene_file_path() == scenes[0]:
		get_editor_interface().save_scene()
	else:
		# Multiple scenes, or the rescued scene isn't the active tab - re-run
		# Save All; already-saved scenes are cheap no-ops the second time.
		get_editor_interface().save_all_scenes()


## Success-only (the engine emits no signal for a failed resource write).
## Catches scripts/resources saved without a checkout in an allwrite client.
func _on_resource_saved(res: Resource) -> void:
	if res == null:
		return
	var res_path := res.resource_path
	if res_path.is_empty() or not res_path.begins_with("res://") \
			or _checked_out_this_session.has(res_path):
		return
	if not await _ensure_identity():
		return
	if _checked_out_this_session.has(res_path):
		return # Re-check: a save-time checkout may have resolved during the await.
	if not await _needs_checkout(ProjectSettings.globalize_path(res_path)):
		_checked_out_this_session[res_path] = true
		_pending_save_checkout.erase(res_path)
		return
	_log("'%s' was saved while not checked out (allwrite client?) - checking it out to keep the changelist accurate." % res_path)
	var result: Dictionary = await _do_checkout(res_path)
	if not result.ok:
		_show_alert(("'%s' was saved to disk but couldn't be checked out - %s.\n\n" +
				"Perforce doesn't know about this change yet. Once the file becomes " +
				"available, use 'Checkout Current File' (or `p4 reconcile`) so the " +
				"change lands in a changelist.") % [res_path, result.reason])


# ---------------------------------------------------------------------------
# Dock UI
# ---------------------------------------------------------------------------

func _build_dock() -> void:
	dock = VBoxContainer.new()
	dock.name = "P4"

	# Flow containers wrap their children, so the dock stays usable whether
	# the user leaves it in a narrow side slot, floats it, or widens it.
	var button_row := HFlowContainer.new()
	dock.add_child(button_row)
	_add_dock_button(button_row, "Refresh",
			"Re-query Perforce and rebuild the changelist view.",
			_on_refresh_pressed)
	new_changelist_button = _add_dock_button(button_row, "New Changelist...",
			"Create a new empty pending changelist.",
			_on_new_changelist_pressed)
	reconcile_button = _add_dock_button(button_row, "Reconcile...",
			"Find files changed on disk and open them for add/edit/delete in Perforce.",
			_on_reconcile_pressed)
	revert_unchanged_button = _add_dock_button(button_row, "Revert Unchanged...",
			"Revert opened files that have no actual changes (p4 revert -a).",
			_on_revert_unchanged_pressed)
	_add_dock_button(button_row, "Checkout Active File",
			"Run 'p4 edit' on the scene/script open in the active editor tab.",
			_on_checkout_current_pressed)
	_add_dock_button(button_row, "Revert Selected File",
			"Run 'p4 revert' on the file selected in the changelist tree, then reload it from disk.",
			_on_revert_selected_pressed)
	_add_dock_button(button_row, "Sync Selected File",
			"Run 'p4 sync' on the file selected in the changelist tree, then reload it from disk.",
			_on_sync_selected_pressed)
	_add_dock_button(button_row, "Reload Selected File",
			"Reload the file selected in the changelist tree from disk without touching P4.",
			_on_reload_selected_pressed)
	_add_dock_button(button_row, "Log",
			"Show or hide the P4 activity log window.",
			_on_toggle_log_pressed)

	var settings_row := HFlowContainer.new()
	dock.add_child(settings_row)

	auto_checkout_checkbox = CheckBox.new()
	auto_checkout_checkbox.text = "Checkout on edit"
	auto_checkout_checkbox.tooltip_text = "Offer to check out a file the moment it is first modified in the editor."
	auto_checkout_checkbox.button_pressed = true
	auto_checkout_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(auto_checkout_checkbox)

	checkout_on_save_checkbox = CheckBox.new()
	checkout_on_save_checkbox.text = "Checkout on save"
	checkout_on_save_checkbox.tooltip_text = "Automatically check out edited files right before the editor writes them."
	checkout_on_save_checkbox.button_pressed = true
	checkout_on_save_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(checkout_on_save_checkbox)

	_build_tree()

	# The log lives in its own on-demand Window rather than eating dock space -
	# the toolbar "Log" button toggles it. log_box stays a member (so _log() is
	# untouched) and exists from here on regardless of the window's visibility.
	_build_log_window()

	# A dock (rather than a fixed bottom-panel item) so the user can drag it
	# to any dock slot or float it in its own window via the dock's menu.
	# DOCK_SLOT_BOTTOM keeps the familiar default placement (4.7+ treats the
	# bottom area as a dock slot).
	add_control_to_dock(EditorPlugin.DOCK_SLOT_BOTTOM, dock)

	# Refresh when the dock tab is brought to front (cheap, coalesced), and once
	# now - the deferred refresh awaits the startup identity check, so it fills
	# in as soon as `p4 info` resolves.
	dock.visibility_changed.connect(_on_dock_visibility_changed)
	_request_refresh()


func _add_dock_button(parent: Control, text: String, tooltip: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _log(text: String) -> void:
	print("[P4] ", text)
	if log_box:
		if log_box.text.is_empty():
			log_box.text = text
		else:
			log_box.text += "\n" + text
		log_box.set_caret_line(log_box.get_line_count() - 1)


func _on_clear_log_pressed() -> void:
	log_box.text = ""


## Builds the log window (a Window child of the dock, hidden by default) hosting
## log_box plus a Clear button. A Window - not an AcceptDialog - because the log
## is a non-modal, resizable, leave-it-open panel; AcceptDialog would drag in
## modal semantics and the _dialog_busy serialization used for real prompts.
func _build_log_window() -> void:
	log_window = Window.new()
	log_window.title = "P4 Log"
	log_window.size = Vector2i(640, 360)
	log_window.visible = false
	# Closing HIDES (never frees) so log_box survives to keep receiving _log().
	log_window.close_requested.connect(_on_log_window_close_requested)

	var log_root := VBoxContainer.new()
	log_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	log_window.add_child(log_root)

	var log_tools := HBoxContainer.new()
	log_root.add_child(log_tools)
	_add_dock_button(log_tools, "Clear Log", "", _on_clear_log_pressed)

	log_box = TextEdit.new()
	log_box.editable = false
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_root.add_child(log_box)

	# Child of dock, so dock.queue_free() in _exit_tree() cascades to it.
	dock.add_child(log_window)


func _on_toggle_log_pressed() -> void:
	if log_window.visible:
		log_window.hide()
	else:
		log_window.popup_centered()


func _on_log_window_close_requested() -> void:
	log_window.hide()


# ---------------------------------------------------------------------------
# Changelist tree
# ---------------------------------------------------------------------------

func _build_tree() -> void:
	tree = Tree.new()
	tree.hide_root = true
	tree.columns = 2
	tree.set_column_title(0, "Changelist / File")
	tree.set_column_title(1, "Action")
	tree.set_column_titles_visible(true)
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, 90)
	tree.allow_rmb_select = true # so right-click selects the row under the cursor
	tree.select_mode = Tree.SELECT_ROW
	tree.custom_minimum_size = Vector2(0, 180)
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.item_activated.connect(_on_tree_item_activated)
	tree.item_mouse_selected.connect(_on_tree_item_mouse_selected)
	tree.empty_clicked.connect(_on_tree_empty_clicked)
	dock.add_child(tree)

	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	dock.add_child(context_menu)

	# Submenu of "Move to Changelist". Items fire the submenu's own id_pressed
	# (not the parent's), so route it through the same handler.
	move_submenu = PopupMenu.new()
	move_submenu.id_pressed.connect(_on_context_menu_id_pressed)
	context_menu.add_child(move_submenu)


## Rebuild the whole tree from a model snapshot (see _query_pending_model). Cheap
## enough to clear-and-rebuild - the opened set is small and this only runs on
## refresh, not per frame.
func _rebuild_tree(model: Dictionary) -> void:
	if tree == null:
		return
	_last_changelists = model.get("changelists", [])
	tree.clear()
	var root := tree.create_item()
	if not model.get("available", false):
		var row := tree.create_item(root)
		row.set_text(0, "Perforce unavailable - see the P4 Log.")
		row.set_selectable(0, false)
		return
	var folder_icon := _theme_icon("Folder")
	for cl in model.changelists:
		var cl_item := tree.create_item(root)
		var label: String = "Default changelist" if cl.change == "default" \
				else "#%s  %s" % [cl.change, cl.desc]
		cl_item.set_text(0, label)
		cl_item.set_text(1, "(%d)" % cl.files.size())
		cl_item.set_selectable(1, false)
		cl_item.set_metadata(0, {"type": "cl", "change": cl.change, "desc": cl.desc})
		if folder_icon:
			cl_item.set_icon(0, folder_icon)
			cl_item.set_icon_modulate(0, P4_ACCENT) # the P4 brand touch
		for f in cl.files:
			var f_item := tree.create_item(cl_item)
			f_item.set_text(0, f.res_path)
			f_item.set_text(1, f.action)
			f_item.set_custom_color(1, _action_color(f.action))
			f_item.set_selectable(1, false)
			var icon := _file_icon(f.res_path)
			if icon:
				f_item.set_icon(0, icon)
			f_item.set_metadata(0, {"type": "file", "res_path": f.res_path,
					"depot_path": f.depot_path, "action": f.action, "change": f.change})


## An editor theme icon by name, or null if this build doesn't have it (so
## set_icon(null) just leaves the row icon-less rather than erroring).
func _theme_icon(icon_name: String) -> Texture2D:
	var base := get_editor_interface().get_base_control()
	if base and base.has_theme_icon(icon_name, "EditorIcons"):
		return base.get_theme_icon(icon_name, "EditorIcons")
	return null


func _file_icon(res_path: String) -> Texture2D:
	match res_path.get_extension().to_lower():
		"tscn", "scn": return _theme_icon("PackedScene")
		"gd": return _theme_icon("GDScript")
		"cs": return _theme_icon("CSharpScript")
		"tres", "res": return _theme_icon("Resource")
		"png", "webp", "jpg", "jpeg", "svg", "bmp": return _theme_icon("Image")
		_: return _theme_icon("File")


func _action_color(action: String) -> Color:
	if action.contains("delete"):
		return ACTION_DELETE_COLOR
	if action.contains("add"):
		return ACTION_ADD_COLOR
	return ACTION_EDIT_COLOR # edit / integrate / branch


## Open the double-clicked / Enter-activated file row in the editor.
func _on_tree_item_activated() -> void:
	var item := tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY or meta.get("type") != "file":
		return
	_open_res_path(meta.res_path)


func _open_res_path(res_path: String) -> void:
	var ext := res_path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		get_editor_interface().open_scene_from_path(res_path)
	else:
		var res := ResourceLoader.load(res_path)
		if res:
			get_editor_interface().edit_resource(res)


# Context-menu action ids. Move-to-changelist items use CTX_MOVE_BASE + index
# (into _move_targets) so a variable number of target changelists fit one menu.
enum {
	CTX_OPEN,
	CTX_REVERT,
	CTX_SYNC,
	CTX_RELOAD,
	CTX_REFRESH,
	CTX_EDIT_DESC,
	CTX_SUBMIT,
}
const CTX_MOVE_BASE := 1000


func _on_tree_item_mouse_selected(_mouse_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	_context_target = meta
	_show_context_menu(meta)


func _on_tree_empty_clicked(_click_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	_context_target = {}
	_show_context_menu({})


## Fill context_menu with the actions valid for `meta`. Kept separate from the
## popup so a headless self-test can assert the item set without a display.
func _populate_context_menu(meta: Dictionary) -> void:
	context_menu.clear()
	move_submenu.clear()
	_move_targets.clear()
	var kind: String = meta.get("type", "")
	if kind == "file":
		context_menu.add_item("Open", CTX_OPEN)
		context_menu.add_item("Revert This File", CTX_REVERT)
		context_menu.add_item("Sync This File", CTX_SYNC)
		context_menu.add_item("Reload From Disk", CTX_RELOAD)
		_populate_move_submenu(String(meta.get("change", "")))
		context_menu.add_submenu_node_item("Move to Changelist", move_submenu)
		context_menu.add_separator()
	elif kind == "cl":
		context_menu.add_item("Submit Changelist...", CTX_SUBMIT)
		if String(meta.get("change", "")) != "default":
			context_menu.add_item("Edit Description...", CTX_EDIT_DESC)
	context_menu.add_item("Refresh", CTX_REFRESH)


## Populate the Move-to-Changelist submenu with every pending changelist except
## the file's current one, plus a New Changelist option. _move_targets maps each
## item's id (CTX_MOVE_BASE + index) back to a target change key.
func _populate_move_submenu(current_change: String) -> void:
	for cl in _last_changelists:
		if String(cl.change) == current_change:
			continue
		var label: String = "Default changelist" if cl.change == "default" \
				else "#%s  %s" % [cl.change, cl.desc]
		move_submenu.add_item(label, CTX_MOVE_BASE + _move_targets.size())
		_move_targets.append(String(cl.change))
	move_submenu.add_separator()
	move_submenu.add_item("New Changelist...", CTX_MOVE_BASE + _move_targets.size())
	_move_targets.append("__new__")


func _show_context_menu(meta: Dictionary) -> void:
	_populate_context_menu(meta)
	context_menu.reset_size()
	# get_screen_position() folds in the editor's window/embedding offset, so
	# adding the local mouse position gives screen coordinates for the popup.
	context_menu.position = Vector2i(tree.get_screen_position() + tree.get_local_mouse_position())
	context_menu.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	var meta := _context_target
	if id >= CTX_MOVE_BASE:
		var idx := id - CTX_MOVE_BASE
		if idx >= 0 and idx < _move_targets.size() and meta.has("res_path"):
			await _move_file_to_changelist(meta.res_path, _move_targets[idx])
		return
	match id:
		CTX_OPEN:
			if meta.has("res_path"):
				_open_res_path(meta.res_path)
		CTX_REVERT:
			if meta.has("res_path"):
				await _revert_path(meta.res_path)
		CTX_SYNC:
			if meta.has("res_path"):
				await _sync_path(meta.res_path)
		CTX_RELOAD:
			if meta.has("res_path"):
				_reload_path(meta.res_path)
		CTX_EDIT_DESC:
			if meta.has("change"):
				await _edit_changelist_description(meta.change)
		CTX_SUBMIT:
			if meta.get("type") == "cl":
				await _submit_changelist_from_meta(meta)
		CTX_REFRESH:
			_refresh_changelists()


func _on_refresh_pressed() -> void:
	_refresh_changelists()


func _on_dock_visibility_changed() -> void:
	if dock and dock.is_visible_in_tree():
		_request_refresh()


## Fire-and-forget refresh request, safe to call from synchronous contexts (e.g.
## _apply_changes) and from bursts of mutations - it defers to next frame and the
## coroutine below coalesces. No-op once p4 is known unavailable.
func _request_refresh() -> void:
	if _identity_checked and not _p4_available:
		return
	call_deferred("_refresh_changelists")


## Re-query Perforce and rebuild the tree. Coalescing: a refresh requested while
## one is in flight sets _refresh_pending, and the in-flight run loops once more
## instead of a second coroutine stacking up.
func _refresh_changelists() -> void:
	if tree == null or _shutting_down:
		return
	if _refresh_inflight:
		_refresh_pending = true
		return
	_refresh_inflight = true
	while true:
		_refresh_pending = false
		if not await _ensure_identity():
			_set_actions_enabled(false)
			_rebuild_tree({"available": false, "changelists": []})
		else:
			_set_actions_enabled(true)
			var model: Dictionary = await _query_pending_model()
			if tree == null or _shutting_down:
				break
			_rebuild_tree(model)
			_fold_opened_into_cache(model)
		if not _refresh_pending:
			break
	_refresh_inflight = false


## Grey out the p4-dependent action buttons when Perforce is unavailable, so the
## dock is honestly inert instead of offering doomed actions.
func _set_actions_enabled(enabled: bool) -> void:
	for b: Button in [new_changelist_button, reconcile_button, revert_unchanged_button]:
		if b:
			b.disabled = not enabled


## Every file Perforce reports as opened is, by definition, checked out by us -
## fold them into the session cache so a refresh right after a reconcile (or any
## external checkout) suppresses redundant edit-time prompts. Additive only;
## removal stays with the explicit revert paths.
func _fold_opened_into_cache(model: Dictionary) -> void:
	for cl in model.get("changelists", []):
		for f in cl.files:
			_checked_out_this_session[f.res_path] = true


# ---------------------------------------------------------------------------
# Manual actions
# ---------------------------------------------------------------------------

## The file the manual buttons act on: the active script when the Script
## editor is in front, otherwise the edited scene.
func _get_current_file_path() -> String:
	var script_editor := get_editor_interface().get_script_editor()
	var script := script_editor.get_current_script()
	if script_editor.is_visible_in_tree() and script and not script.resource_path.is_empty():
		return script.resource_path
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root and not scene_root.get_scene_file_path().is_empty():
		return scene_root.get_scene_file_path()
	if script and not script.resource_path.is_empty():
		return script.resource_path
	return ""


func _on_checkout_current_pressed() -> void:
	var path := _get_current_file_path()
	if path.is_empty():
		_log("No current scene/script with a saved path to check out.")
		return
	if not await _needs_checkout(ProjectSettings.globalize_path(path)):
		_checked_out_this_session[path] = true
		_log("'%s' doesn't need checkout (already opened by you, or not tracked by Perforce)." % path)
		return
	var result: Dictionary = await _do_checkout(path)
	if not result.ok:
		_show_alert("Couldn't check out '%s' - %s." % [path, result.reason])


## The file selected in the changelist tree (a file row), or "" if none. The
## revert/sync/reload toolbar buttons act on THIS, not the active editor tab -
## "Current" was ambiguous once files became selectable in the tree.
func _get_selected_res_path() -> String:
	if tree == null:
		return ""
	var item := tree.get_selected()
	if item == null:
		return ""
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) == TYPE_DICTIONARY and meta.get("type") == "file":
		return String(meta.res_path)
	return ""


func _on_revert_selected_pressed() -> void:
	var path := _get_selected_res_path()
	if path.is_empty():
		_log("Select a file in the changelist tree to revert.")
		return
	await _revert_path(path)


## Revert res_path in Perforce and reload it from disk. Confirms first, naming
## the exact file, because revert discards unsaved in-editor changes too - the
## user must not lose work in a file they didn't mean to touch. Shared by the
## toolbar "Revert Selected File" button and the tree's per-row context menu.
func _revert_path(res_path: String) -> void:
	var proceed: bool = await _show_confirm_dialog(
			("Revert '%s'?\n\nThis reverts the Perforce checkout AND discards any unsaved " +
			"changes to this file in the editor, reloading it from disk.") % res_path,
			"Revert", "Cancel")
	if not proceed:
		_log("Revert of '%s' cancelled." % res_path)
		return
	await _p4_exec_logged(["revert", ProjectSettings.globalize_path(res_path)])
	_checked_out_this_session.erase(res_path)
	_reload_path(res_path)


func _on_sync_selected_pressed() -> void:
	var path := _get_selected_res_path()
	if path.is_empty():
		_log("Select a file in the changelist tree to sync.")
		return
	await _sync_path(path)


## Sync res_path to the head revision and reload it from disk. Shared by the
## toolbar "Sync Selected File" button and the tree's per-row context menu.
func _sync_path(res_path: String) -> void:
	await _p4_exec_logged(["sync", ProjectSettings.globalize_path(res_path)])
	_reload_path(res_path)


func _on_reload_selected_pressed() -> void:
	var path := _get_selected_res_path()
	if path.is_empty():
		_log("Select a file in the changelist tree to reload.")
		return
	_reload_path(path)


# ---------------------------------------------------------------------------
# Workspace operations: Reconcile and Revert Unchanged (scoped to res://)
# ---------------------------------------------------------------------------

## The project subtree as a p4 recursive path argument (the res:// root + "...").
## Bounds both operations to the Godot project even when the P4 workspace is
## wider, and P4IGNORE still applies on top.
func _project_scope() -> String:
	var root := ProjectSettings.globalize_path("res://")
	if not (root.ends_with("/") or root.ends_with("\\")):
		root += "/"
	return root + "..."


## Non-mutating preview (`reconcile -n`) of what reconcile would open. Kept
## separate so a self-test can exercise it without changing anything.
func _reconcile_preview() -> Array:
	return _parse_ztag(await _p4_exec(["-ztag", "reconcile", "-n", _project_scope()]))


## Non-mutating preview (`revert -a -n`) of the open-but-unchanged files.
func _revert_unchanged_preview() -> Array:
	return _parse_ztag(await _p4_exec(["-ztag", "revert", "-a", "-n", _project_scope()]))


func _on_reconcile_pressed() -> void:
	await _reconcile_flow()


func _reconcile_flow() -> void:
	if not await _ensure_identity():
		await _show_alert("Perforce is unavailable this session - see the P4 Log.")
		return
	var preview := await _reconcile_preview()
	if preview.is_empty():
		await _show_alert("Reconcile found nothing to open - the workspace already matches Perforce.")
		return
	var adds := 0
	var edits := 0
	var deletes := 0
	for rec in preview:
		var action := String(rec.get("action", ""))
		if action.contains("delete"):
			deletes += 1
		elif action.contains("add"):
			adds += 1
		else:
			edits += 1
	var proceed: bool = await _show_confirm_dialog(
			("Perforce reconcile found %d change(s) on disk:\n\n" +
			"    add: %d\n    edit: %d\n    delete: %d\n\n" +
			"Open these files in Perforce? Your files on disk are not modified.")
			% [preview.size(), adds, edits, deletes],
			"Reconcile", "Cancel")
	if not proceed:
		_log("Reconcile cancelled.")
		return
	await _p4_exec_logged(["reconcile", _project_scope()])
	_request_refresh()


func _on_revert_unchanged_pressed() -> void:
	await _revert_unchanged_flow()


func _revert_unchanged_flow() -> void:
	if not await _ensure_identity():
		await _show_alert("Perforce is unavailable this session - see the P4 Log.")
		return
	var preview := await _revert_unchanged_preview()
	if preview.is_empty():
		await _show_alert("No open-but-unchanged files to revert.")
		return
	var proceed: bool = await _show_confirm_dialog(
			("%d open file(s) have no actual changes.\n\nRevert them? This closes them in " +
			"Perforce (they leave your changelist); your on-disk files are untouched.")
			% preview.size(),
			"Revert Unchanged", "Cancel")
	if not proceed:
		_log("Revert Unchanged cancelled.")
		return
	await _p4_exec_logged(["revert", "-a", _project_scope()])
	# Reverted files are no longer opened - drop them from the caches so a later
	# edit re-prompts. `revert -n`'s clientFile is already a local OS path.
	for rec in preview:
		var res := _local_to_res(String(rec.get("clientFile", "")))
		if not res.is_empty():
			_checked_out_this_session.erase(res)
			_pending_save_checkout.erase(res)
	_request_refresh()


# ---------------------------------------------------------------------------
# Changelist create / edit / move
# ---------------------------------------------------------------------------

func _on_new_changelist_pressed() -> void:
	var res: Dictionary = await _show_input_dialog("New Changelist",
			"Description for the new pending changelist:", "", true, "Create")
	if not res.ok:
		return
	var desc := String(res.text).strip_edges()
	if desc.is_empty():
		await _show_alert("A changelist needs a description.")
		return
	var num := await _create_changelist(desc)
	if num.is_empty():
		await _show_alert("Could not create the changelist - see the P4 Log.")
	_request_refresh()


## Create an EMPTY pending changelist (no Files section in the spec, so nothing
## moves into it) and return its number, or "" on failure.
func _create_changelist(desc: String) -> String:
	var spec := "Change: new\n\nDescription:\n" + _indent_spec_text(desc)
	var result := await _p4_exec_spec(["change", "-i"], spec)
	return _parse_change_number(result)


## Edit a numbered changelist's description in place. Round-trips the existing
## spec (`change -o`) so Files/Jobs are preserved - only Description changes.
func _edit_changelist_description(change: String) -> void:
	var current := await _p4_exec(["change", "-o", change])
	var spec_text := "" if current.output.is_empty() else String(current.output[0])
	if spec_text.is_empty():
		await _show_alert("Could not read changelist #%s - see the P4 Log." % change)
		return
	var res: Dictionary = await _show_input_dialog("Edit Changelist #%s" % change,
			"Description:", _extract_spec_description(spec_text), true, "Save")
	if not res.ok:
		return
	var new_desc := String(res.text).strip_edges()
	if new_desc.is_empty():
		await _show_alert("A changelist needs a description.")
		return
	await _p4_exec_spec(["change", "-i"], _replace_spec_description(spec_text, new_desc))
	_request_refresh()


## Move a file to another changelist via `p4 reopen -c`. `change` is "default", a
## number, or "__new__" to create a changelist first and move into that.
func _move_file_to_changelist(res_path: String, change: String) -> void:
	var target := change
	if target == "__new__":
		var res: Dictionary = await _show_input_dialog("New Changelist",
				"Description for the changelist to move the file into:", "", true, "Create & Move")
		if not res.ok:
			return
		var desc := String(res.text).strip_edges()
		if desc.is_empty():
			await _show_alert("A changelist needs a description.")
			return
		target = await _create_changelist(desc)
		if target.is_empty():
			await _show_alert("Could not create the changelist - see the P4 Log.")
			return
	await _p4_exec_logged(["reopen", "-c", target, ProjectSettings.globalize_path(res_path)])
	_request_refresh()


## Indent each line of `text` with a tab, as p4 spec field values require.
func _indent_spec_text(text: String) -> String:
	var out := ""
	for line in text.split("\n"):
		out += "\t" + line + "\n"
	return out


## Pull the Description field's text out of a `change -o` spec (leading tab of
## each content line removed). Comment lines (`#...`) never match the field line.
func _extract_spec_description(spec_text: String) -> String:
	var lines := spec_text.split("\n")
	var i := 0
	var desc_lines: Array = []
	while i < lines.size():
		if lines[i].begins_with("Description:"):
			i += 1
			while i < lines.size() and (lines[i].begins_with("\t") or lines[i].begins_with(" ")):
				var content: String = lines[i]
				content = content.substr(1) if content.begins_with("\t") else content.strip_edges()
				desc_lines.append(content)
				i += 1
			break
		i += 1
	return "\n".join(desc_lines)


## Return a copy of `spec_text` with its Description block replaced by new_desc
## (tab-indented). Everything else - Files, Jobs, comments - is preserved.
func _replace_spec_description(spec_text: String, new_desc: String) -> String:
	var lines := spec_text.split("\n")
	var out: Array = []
	var i := 0
	var replaced := false
	while i < lines.size():
		if not replaced and lines[i].begins_with("Description:"):
			out.append("Description:")
			for dl in new_desc.split("\n"):
				out.append("\t" + dl)
			i += 1
			# Drop the old indented description lines; stop at the next field
			# (non-indented) or a blank separator, which is left intact.
			while i < lines.size() and (lines[i].begins_with("\t") or lines[i].begins_with(" ")):
				i += 1
			replaced = true
			continue
		out.append(lines[i])
		i += 1
	return "\n".join(out)


## Extract the changelist number from p4 output like "Change 3064 created." /
## "Change 3064 submitted." Returns "" if none is present.
func _parse_change_number(result: Dictionary) -> String:
	if result.output.is_empty():
		return ""
	var re := RegEx.new()
	re.compile("Change (\\d+)")
	var m := re.search(String(result.output[0]))
	return m.get_string(1) if m else ""


# ---------------------------------------------------------------------------
# Submit
# ---------------------------------------------------------------------------

## Resolve the files for the right-clicked changelist row (from the last refresh)
## and submit it.
func _submit_changelist_from_meta(meta: Dictionary) -> void:
	var change := String(meta.get("change", ""))
	var files: Array = []
	for cl in _last_changelists:
		if String(cl.change) == change:
			files = cl.files
			break
	await _submit_changelist(change, files)


## Submit a changelist. Irreversible and team-visible, so it always ends at an
## explicit confirmation that lists the exact files and the description. Numbered
## changelists submit by number (`submit -c`, using their own description); the
## default changelist prompts for a description and submits its project-scoped
## files (`submit -d <desc> <scope>`).
func _submit_changelist(change: String, files: Array) -> void:
	if not await _ensure_identity():
		await _show_alert("Perforce is unavailable this session - see the P4 Log.")
		return
	if files.is_empty():
		await _show_alert("This changelist has no files to submit.")
		return

	var desc := ""
	if change == "default":
		var input: Dictionary = await _show_input_dialog("Submit Default Changelist",
				"Description for this submission:", "", true, "Continue")
		if not input.ok:
			return
		desc = String(input.text).strip_edges()
		if desc.is_empty():
			await _show_alert("A submission needs a description.")
			return
	else:
		var spec := await _p4_exec(["change", "-o", change])
		desc = _extract_spec_description("" if spec.output.is_empty() else String(spec.output[0]))

	# The irreversibility gate: show exactly what will land in the depot.
	var file_lines: Array = []
	var shown: int = mini(files.size(), 20)
	for i in range(shown):
		file_lines.append("    %s  (%s)" % [files[i].res_path, files[i].action])
	if files.size() > shown:
		file_lines.append("    ...and %d more" % (files.size() - shown))
	var label := "the default changelist" if change == "default" else "changelist #%s" % change
	var proceed: bool = await _show_confirm_dialog(
			("Submit %s to Perforce?\n\nDescription:\n%s\n\nFiles (%d):\n%s\n\n" +
			"This is permanent and visible to your whole team.")
			% [label, desc, files.size(), "\n".join(file_lines)],
			"Submit to Perforce", "Cancel")
	if not proceed:
		_log("Submit cancelled.")
		return

	var result: Dictionary
	if change == "default":
		result = await _p4_exec_logged(["submit", "-d", desc, _project_scope()])
	else:
		result = await _p4_exec_logged(["submit", "-c", change])

	if result.exit_code == 0:
		var submitted := _parse_change_number(result)
		_log("Submit complete." if submitted.is_empty() else "Submitted as change %s." % submitted)
		# Submitted files are no longer opened - drop them from the caches.
		for f in files:
			_checked_out_this_session.erase(f.res_path)
			_pending_save_checkout.erase(f.res_path)
	else:
		var msg := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		await _show_alert(("Submit failed:\n\n%s\n\nThe changelist is unchanged. Common causes: " +
				"files are out of date and need syncing/resolving first, or the server rejected " +
				"the change.") % msg)
	_request_refresh()


# ---------------------------------------------------------------------------
# Perforce operations
# ---------------------------------------------------------------------------

## Runs `p4 edit` (on the worker thread) and returns {ok: bool, reason:
## String}. `reason` is a human-readable failure explanation ("already checked
## out by bob (workspace 'bob_ws')" for the exclusive-checkout case, raw p4
## text otherwise) so every caller can surface it in whatever dialog fits its
## context. Logging happens here; dialogs are the caller's job.
func _do_checkout(res_path: String) -> Dictionary:
	if not await _ensure_identity():
		return {"ok": false, "reason": "p4 isn't available this session (see the startup log)"}
	var global_path := ProjectSettings.globalize_path(res_path)
	var edit_result: Dictionary = await _p4_exec_logged(["edit", global_path])
	var fstat_result: Dictionary = await _p4_exec(["fstat", global_path])
	var others := _parse_other_opens(await _p4_exec(["opened", "-a", global_path]))
	return _resolve_checkout(res_path, edit_result, fstat_result, others)


## Blocking twin of _do_checkout() for _apply_changes(), the pre-write hook
## that has no async window. Same three commands, same resolution logic.
func _do_checkout_sync(res_path: String) -> Dictionary:
	var global_path := ProjectSettings.globalize_path(res_path)
	var edit_result := _p4_exec_logged_sync(["edit", global_path])
	var fstat_result := _p4_exec_sync(["fstat", global_path])
	var others := _parse_other_opens(_p4_exec_sync(["opened", "-a", global_path]))
	return _resolve_checkout(res_path, edit_result, fstat_result, others)


## Shared tail of _do_checkout()/_do_checkout_sync(): decide success, update
## the session caches, and build the failure reason. Do NOT trust `p4 edit`'s
## exit code: p4 exits 0 even when the edit is REFUSED (verified live - "can't
## edit exclusive file already opened for edit" arrives on stderr with exit
## code 0). The only reliable success signal is the actual resulting state,
## from the verifying fstat: do WE now have the file opened?
func _resolve_checkout(res_path: String, edit_result: Dictionary,
		fstat_result: Dictionary, others: Array) -> Dictionary:
	var fstat_text := "" if fstat_result.output.is_empty() else String(fstat_result.output[0])
	if _fstat_shows_our_open(fstat_text):
		_checked_out_this_session[res_path] = true
		_declined_this_session.erase(res_path)
		_pending_save_checkout.erase(res_path)
		if not others.is_empty():
			_log("Note: '%s' is ALSO currently open (non-exclusively) elsewhere: %s" % [res_path, _format_other_opens(others)])
		# Newly opened - reflect it in the changelist tree. Deferred + coalesced,
		# so this is safe even from the synchronous _do_checkout_sync/_apply_changes.
		_request_refresh()
		return {"ok": true, "reason": ""}

	var reason: String
	if not others.is_empty():
		reason = "already checked out by %s" % _format_other_opens(others)
	else:
		var raw := ""
		if not edit_result.output.is_empty():
			raw = String(edit_result.output[0]).strip_edges().get_slice("\n", 0)
		reason = "p4 edit failed (exit %d)%s" % [edit_result.exit_code,
				"" if raw.is_empty() else ": " + raw]
	_log("Could not check out '%s' - %s." % [res_path, reason])
	return {"ok": false, "reason": reason}


## Whether global_path is a Perforce-tracked file that our client has NOT yet
## opened (for edit/add/etc) - i.e. a checkout is actually called for.
## Deliberately asks Perforce instead of checking an OS read-only attribute:
## FileAccess.get_read_only_attribute() is only correct on Windows (on
## macOS/BSD it checks the unrelated chflags/UF_IMMUTABLE flag; on Linux it is
## hardcoded false - verified in drivers/unix/file_access_unix.cpp), and no OS
## attribute would ever signal "needs checkout" in an `allwrite` client.
##
## One `p4 fstat` answers everything:
## - "no such file(s)" / "not in client view": not tracked by Perforce (new
##   file, ignored file) - nothing to check out, false.
## - a "... action <edit/add/...>" line: already opened by US (other clients'
##   opens show up as "... otherAction<N>", which doesn't match), false.
## - nonzero exit (server unreachable, config broken): stay out of the way,
##   but LOG it - a silently dead plugin is undiagnosable - and return false.
## - otherwise: tracked and not opened - true.
func _needs_checkout(global_path: String) -> bool:
	if not await _ensure_identity():
		return false
	return _needs_checkout_from(await _p4_exec(["fstat", global_path]), global_path)


func _needs_checkout_from(result: Dictionary, global_path: String) -> bool:
	var text := "" if result.output.is_empty() else String(result.output[0])
	if text.contains("no such file(s)") or text.contains("not in client view") \
			or text.contains("not under client's root"):
		return false
	if _fstat_shows_our_open(text):
		return false
	if result.exit_code != 0:
		_log("Warning: 'p4 fstat' failed (exit %d) for '%s'%s" % [result.exit_code, global_path,
				"" if text.is_empty() else ": " + text.strip_edges().get_slice("\n", 0)])
		return false
	return true


func _fstat_shows_our_open(fstat_text: String) -> bool:
	# "... action edit/add/..." is only present for our own client's open;
	# other clients' opens appear as "... otherAction<N>", which doesn't match.
	for line in fstat_text.split("\n"):
		if line.strip_edges().begins_with("... action "):
			return true
	return false


## Everyone other than us who has the file opened, parsed from a
## `p4 opened -a` result. Turns a generic p4 failure into "checked out by
## so-and-so, in workspace such-and-such" instead of raw p4 error text.
func _parse_other_opens(opened_result: Dictionary) -> Array:
	var others := []
	if opened_result.output.is_empty():
		return others
	var line_regex := RegEx.new()
	# No end anchor: exclusive opens are reported as
	# "... by user@client *exclusive*", with the marker after the identity.
	line_regex.compile("by (\\S+)@(\\S+)")
	for raw_line in String(opened_result.output[0]).split("\n"):
		var m := line_regex.search(raw_line.strip_edges())
		if m == null:
			continue
		var user := m.get_string(1)
		var client := m.get_string(2)
		if user == _p4_user and client == _p4_client:
			continue # That's just our own checkout.
		others.append({"user": user, "client": client})
	return others


func _format_other_opens(others: Array) -> String:
	var parts := []
	for o in others:
		parts.append("%s (workspace '%s')" % [o.user, o.client])
	return ", ".join(parts)


# ---------------------------------------------------------------------------
# Changelist model - the data behind the dock's changelist tree
# ---------------------------------------------------------------------------

## Snapshot the pending changelists and the files opened in each, mapped back to
## res:// paths. Returns:
##   {available: bool, changelists: Array}
## each changelist: {change: "default"|"<n>", desc: String, files: Array}
## each file:       {res_path, depot_path, action, change, type}
## The default changelist is synthesized (p4 never lists it) and always present,
## even empty, so newly-opened files always have a home in the tree.
func _query_pending_model() -> Dictionary:
	if not await _ensure_identity():
		return {"available": false, "changelists": []}

	# 1. Files opened in our client (across all its pending changelists).
	var opened := _parse_ztag(await _p4_exec(["-ztag", "opened"]))

	# 2. Map each opened depotFile to a local path. `opened`'s clientFile is
	#    CLIENT syntax (//workspace/...), not a filesystem path - `p4 where`'s
	#    `path` field is the local OS path we can localize to res://.
	var depot_to_res := {}
	var depot_paths: PackedStringArray = []
	for rec in opened:
		var d := String(rec.get("depotFile", ""))
		if not d.is_empty():
			depot_paths.append(d)
	if not depot_paths.is_empty():
		var where_args: PackedStringArray = ["-ztag", "where"]
		where_args.append_array(depot_paths)
		for wrec in _parse_ztag(await _p4_exec(where_args)):
			# Exclusionary client mappings emit multiple records per file; keep
			# the one that actually carries a local `path`.
			if wrec.has("path") and not String(wrec["path"]).is_empty():
				var res_path := _local_to_res(String(wrec["path"]))
				if not res_path.is_empty():
					depot_to_res[String(wrec.get("depotFile", ""))] = res_path

	# 3. Pending numbered changelists owned by us in this client.
	var changes := _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending",
			"-c", _p4_client, "-u", _p4_user]))

	# Ordered list: default first, then numbered. by_change indexes into it.
	var cls: Array = []
	var by_change: Dictionary = {}
	var default_cl := {"change": "default", "desc": "(default changelist)", "files": []}
	cls.append(default_cl)
	by_change["default"] = default_cl
	for crec in changes:
		var num := String(crec.get("change", ""))
		if num.is_empty():
			continue
		var cl := {"change": num, "desc": String(crec.get("desc", "")).strip_edges(), "files": []}
		cls.append(cl)
		by_change[num] = cl

	# Bucket opened files under their changelist.
	for rec in opened:
		var depot := String(rec.get("depotFile", ""))
		var res_path: String = depot_to_res.get(depot, "")
		if res_path.is_empty():
			continue # Outside the project, or unmapped by `where`.
		var change_key := String(rec.get("change", "default"))
		if not by_change.has(change_key):
			# Opened in a numbered CL that `changes` didn't return - synthesize a
			# bucket so the file is never silently dropped.
			var cl := {"change": change_key, "desc": "", "files": []}
			cls.append(cl)
			by_change[change_key] = cl
		by_change[change_key].files.append({
			"res_path": res_path,
			"depot_path": depot,
			"action": String(rec.get("action", "")),
			"change": change_key,
			"type": String(rec.get("type", "")),
		})

	return {"available": true, "changelists": cls}


## Map a local OS path (from `p4 where`'s `path`) to a res:// path, or "" if the
## file is outside the project. Tries ProjectSettings.localize_path first, then
## falls back to a case-insensitive project-root strip (Windows path casing can
## keep localize_path from folding an otherwise-in-project path).
func _local_to_res(local_path: String) -> String:
	var normalized := local_path.replace("\\", "/")
	var res := ProjectSettings.localize_path(normalized)
	if res.begins_with("res://"):
		return res
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if not project_root.ends_with("/"):
		project_root += "/"
	if normalized.to_lower().begins_with(project_root.to_lower()):
		return "res://" + normalized.substr(project_root.length())
	return ""


# ---------------------------------------------------------------------------
# p4 process execution
#
# All p4 commands funnel through _p4_exec(): the request is queued for the
# worker thread and the awaiting coroutine resumes on the main thread when the
# result is in - the editor never blocks on the Perforce server. The _sync
# variants run OS.execute() directly on the main thread and exist ONLY for
# _apply_changes() (see its doc comment).
# ---------------------------------------------------------------------------

## Async `p4 <args>` via the worker thread. Returns {exit_code, output}. Every
## command and its output are logged (the log window is the troubleshooting view).
func _p4_exec(args: PackedStringArray) -> Dictionary:
	if _p4_thread == null:
		return _p4_exec_sync(args) # Worker gone (shutdown); it logs on its own.
	_log_p4_cmd(args)
	var req := P4Request.new()
	req.args = args
	_p4_inflight += 1
	_p4_queue_mutex.lock()
	_p4_queue.push_back(req)
	_p4_queue_mutex.unlock()
	_p4_queue_semaphore.post()
	if not req.completed:
		await req.done
	_p4_inflight -= 1
	var result := {"exit_code": req.exit_code, "output": req.output}
	_log_p4_result(result)
	return result


## Retained as a semantic alias; _p4_exec now logs every command and its output.
func _p4_exec_logged(args: PackedStringArray) -> Dictionary:
	return await _p4_exec(args)


## Run `p4 <args>` with `spec_text` fed on stdin (for `p4 change -i`). OS.execute
## has no stdin, so the spec is written to a temp file and p4 is run through the
## platform shell with the file redirected in. Goes through the same worker queue
## as _p4_exec so it stays serialized; resumes on the main thread.
func _p4_exec_spec(args: PackedStringArray, spec_text: String) -> Dictionary:
	var tmp := _write_temp_spec(spec_text)
	if tmp.is_empty():
		return {"exit_code": -1, "output": ["Could not write a temporary p4 spec file."]}
	_log_p4_cmd(args + PackedStringArray(["< (spec on stdin)"]))
	if _p4_thread == null:
		var out := []
		var code := _p4_execute_with_stdin(args, tmp, out)
		DirAccess.remove_absolute(tmp)
		var sync_result := {"exit_code": code, "output": out}
		_log_p4_result(sync_result)
		return sync_result
	var req := P4Request.new()
	req.args = args
	req.stdin_path = tmp
	_p4_inflight += 1
	_p4_queue_mutex.lock()
	_p4_queue.push_back(req)
	_p4_queue_mutex.unlock()
	_p4_queue_semaphore.post()
	if not req.completed:
		await req.done
	_p4_inflight -= 1
	DirAccess.remove_absolute(tmp)
	var result := {"exit_code": req.exit_code, "output": req.output}
	_log_p4_result(result)
	return result


## Runs on the worker thread: p4 through the platform shell with the spec file
## on stdin. Uses only OS + its args (no plugin state) so it is thread-safe.
func _p4_execute_with_stdin(args: PackedStringArray, stdin_path: String, output: Array) -> int:
	if OS.get_name() == "Windows":
		var cmd := "p4 " + " ".join(args) + " < \"" + stdin_path.replace("/", "\\") + "\""
		return OS.execute("cmd.exe", ["/c", cmd], output, true)
	var sh_cmd := "p4 " + " ".join(args) + " < '" + stdin_path + "'"
	return OS.execute("sh", ["-c", sh_cmd], output, true)


func _write_temp_spec(spec_text: String) -> String:
	var path := OS.get_cache_dir().path_join("p4_spec_%d.txt" % Time.get_ticks_usec())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log("Could not open a temp spec file at '%s'." % path)
		return ""
	f.store_string(spec_text)
	f.close()
	return path


func _p4_exec_sync(args: PackedStringArray) -> Dictionary:
	_log_p4_cmd(args)
	var output := []
	var exit_code := OS.execute("p4", args, output, true)
	var result := {"exit_code": exit_code, "output": output}
	_log_p4_result(result)
	return result


## Retained as a semantic alias; _p4_exec_sync now logs command and output.
func _p4_exec_logged_sync(args: PackedStringArray) -> Dictionary:
	return _p4_exec_sync(args)


## Log a p4 invocation's command line (truncated if enormous, e.g. a `where`
## over the whole opened set).
func _log_p4_cmd(args: PackedStringArray) -> void:
	var line := "$ p4 " + " ".join(args)
	if line.length() > 400:
		line = line.substr(0, 400) + " ... (%d args total)" % args.size()
	_log(line)


## Log a p4 result: its exit code when nonzero, then its (possibly truncated)
## output. Verbose by design - the log window is where you troubleshoot p4.
func _log_p4_result(result: Dictionary) -> void:
	if int(result.get("exit_code", 0)) != 0:
		_log("  (exit %d)" % int(result.exit_code))
	if not result.output.is_empty():
		var text := String(result.output[0]).strip_edges()
		if not text.is_empty():
			if text.length() > 2000:
				text = text.substr(0, 2000) + "\n  ... (output truncated)"
			_log(text)


## Parse tagged (`p4 -ztag <cmd>`) output into an Array of Dictionaries, one per
## record. Records are separated by blank lines; each field is a `... key value`
## line; a value that spans multiple lines (notably a changelist `desc`)
## continues on the following un-prefixed lines. Robustness notes learned from
## real p4.exe output:
## - p4.exe emits CRLF, so every line is rstrip("\r")'d before inspection (the
##   plain-text parsers elsewhere survive on strip_edges(); a key/value parser
##   does not get that for free).
## - OS.execute() runs with read_stderr=true, so stray p4 error/info lines
##   ("... - file(s) not opened on this client.") can share the blob. Non-"... "
##   lines are treated as continuations ONLY while a record is open, so a stray
##   error line before any field is ignored rather than corrupting a value.
func _parse_ztag(result: Dictionary) -> Array:
	var records: Array = []
	if result.output.is_empty():
		return records
	var current: Dictionary = {}
	var last_key: String = ""
	for raw_line in String(result.output[0]).split("\n"):
		var line: String = raw_line.rstrip("\r")
		if line.strip_edges().is_empty():
			if not current.is_empty():
				records.append(current)
				current = {}
				last_key = ""
			continue
		if line.begins_with("... "):
			var rest: String = line.substr(4)
			var sp: int = rest.find(" ")
			if sp == -1:
				current[rest] = ""
				last_key = rest
			else:
				last_key = rest.substr(0, sp)
				current[last_key] = rest.substr(sp + 1)
		elif not current.is_empty() and not last_key.is_empty():
			current[last_key] = String(current[last_key]) + "\n" + line
	if not current.is_empty():
		records.append(current)
	return records


## Worker thread body: drain the queue in FIFO order, one command at a time.
## Results are handed back to the main thread via call_deferred - the worker
## itself never touches plugin state.
func _p4_worker_loop() -> void:
	while true:
		_p4_queue_semaphore.wait()
		_p4_queue_mutex.lock()
		if _p4_thread_exit:
			_p4_queue_mutex.unlock()
			return
		if _p4_queue.is_empty():
			_p4_queue_mutex.unlock()
			continue
		var req: P4Request = _p4_queue.pop_front()
		_p4_queue_mutex.unlock()
		var output := []
		if req.stdin_path.is_empty():
			req.exit_code = OS.execute("p4", req.args, output, true)
		else:
			req.exit_code = _p4_execute_with_stdin(req.args, req.stdin_path, output)
		req.output = output
		req.call_deferred("_finish")


# ---------------------------------------------------------------------------
# Confirmation dialog
# ---------------------------------------------------------------------------

## Shows a modal confirmation dialog and returns true for OK, false for
## Cancel/close. Modal (popup_exclusive) so no further edits can pile up more
## undo-redo actions while a decision is pending. Serialized via _dialog_busy:
## callers queue up rather than clobbering each other's pending result.
func _show_confirm_dialog(text: String, ok_text: String, cancel_text: String) -> bool:
	if _shutting_down:
		return false # A continuation resumed mid-teardown - nobody left to ask.
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.set_text(text)
	dialog.set_ok_button_text(ok_text)
	dialog.set_cancel_button_text(cancel_text)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	# Belt and braces: also resolve if the window is closed some way that
	# skips confirmed/canceled - never leave the coroutine hanging.
	dialog.close_requested.connect(_on_confirm_dialog_canceled)

	# Do NOT add_child(dialog) first: popup_exclusive_centered() parents the
	# dialog itself (Window::_try_parent_dialog()) and silently no-ops - the
	# dialog never shows, with no error - if it already has a parent.
	dialog.popup_exclusive_centered(get_editor_interface().get_base_control())

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if _selftest_auto_answer == "confirm":
				dialog.confirmed.emit()
			else:
				dialog.canceled.emit()

	while not _dialog_result_ready:
		await get_tree().process_frame
	_discard_dialog(dialog)
	_dialog_busy = false
	return _dialog_result_confirmed


## Shows a modal dialog with a text field and returns {ok: bool, text: String}.
## Used for changelist descriptions. Serialized through the same _dialog_busy
## lock as the other dialogs. `multiline` picks a TextEdit vs a LineEdit.
func _show_input_dialog(title: String, message: String, default_text: String,
		multiline: bool, ok_text: String) -> Dictionary:
	if _shutting_down:
		return {"ok": false, "text": ""}
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.set_ok_button_text(ok_text)
	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = message
	vbox.add_child(label)
	var input: Control
	if multiline:
		var te := TextEdit.new()
		te.text = default_text
		te.custom_minimum_size = Vector2(420, 120)
		te.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.add_child(te)
		input = te
	else:
		var le := LineEdit.new()
		le.text = default_text
		le.custom_minimum_size = Vector2(420, 0)
		vbox.add_child(le)
		input = le
	# Adding CONTENT children to the dialog is fine (and required); the
	# don't-parent-first caveat in _show_confirm_dialog is about the dialog node.
	dialog.add_child(vbox)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(get_editor_interface().get_base_control())

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if _selftest_auto_answer == "confirm":
				dialog.confirmed.emit()
			else:
				dialog.canceled.emit()

	while not _dialog_result_ready:
		await get_tree().process_frame
	var confirmed := _dialog_result_confirmed
	var text: String = input.text if (confirmed and is_instance_valid(input)) else ""
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed, "text": text}


## Shows a modal OK-only notice (checkout failures and other conditions the
## user should see without being asked anything). Serialized through the same
## _dialog_busy lock as _show_confirm_dialog so alerts and prompts can never
## fight over the pending-result state.
func _show_alert(text: String) -> void:
	_log(text.replace("\n\n", "\n"))
	if _shutting_down:
		return # Logged above; no dialog mid-teardown.
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false

	var dialog := AcceptDialog.new()
	dialog.title = "Perforce"
	dialog.set_text(text)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(get_editor_interface().get_base_control())

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			dialog.confirmed.emit()

	while not _dialog_result_ready:
		await get_tree().process_frame
	_discard_dialog(dialog)
	_dialog_busy = false


## Tears a resolved dialog down WITHOUT letting it fire signals at us again:
## freeing a still-visible AcceptDialog emits `canceled` during teardown
## (verified live), which would clobber the pending result of whatever dialog
## the busy-lock admits next. A dialog resolved by emitting its signal
## programmatically (rather than a real button click) is still visible here,
## so this matters beyond the self-tests.
func _discard_dialog(dialog: AcceptDialog) -> void:
	if not is_instance_valid(dialog):
		return
	dialog.confirmed.disconnect(_on_confirm_dialog_confirmed)
	dialog.canceled.disconnect(_on_confirm_dialog_canceled)
	dialog.close_requested.disconnect(_on_confirm_dialog_canceled)
	# Hide BEFORE freeing (and only after disconnecting - hiding an unconfirmed
	# AcceptDialog emits `canceled`): a programmatically-resolved dialog is
	# still visible and EXCLUSIVE, and queue_free() only takes effect at end of
	# frame. A dialog popped in the meantime would get parented to this dying
	# window (Window::_try_parent_dialog picks the topmost exclusive window)
	# and silently die with it, hanging its awaiting coroutine forever -
	# verified live with chained dialogs (checkout prompt -> failure dialog).
	dialog.hide()
	dialog.queue_free()


func _on_confirm_dialog_confirmed() -> void:
	_dialog_result_confirmed = true
	_dialog_result_ready = true


func _on_confirm_dialog_canceled() -> void:
	_dialog_result_confirmed = false
	_dialog_result_ready = true


# ---------------------------------------------------------------------------
# Reloading files from disk
# ---------------------------------------------------------------------------

## Reloads res_path from disk, discarding any in-editor unsaved changes.
func _reload_path(res_path: String) -> void:
	# reload_scene_from_path() internally calls EditorUndoRedoManager.
	# clear_history(), which emits history_changed - suppress our own handler
	# so the reload can't re-trigger the prompt it was just declining. Cleared
	# on a deferred call so same-frame/deferred emissions are covered too.
	_suppress_auto_checkout = true
	call_deferred("_clear_auto_checkout_suppression")

	var ext := res_path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		if res_path in get_editor_interface().get_open_scenes():
			_log("Reloading scene '%s'..." % res_path)
			get_editor_interface().reload_scene_from_path(res_path)
		else:
			_log("'%s' isn't open in a tab - nothing to reload." % res_path)
	elif ext == "gd" or ext == "cs":
		# close_file() is the only scriptable way to force-discard an unsaved
		# script buffer (reload_open_files() only reloads on an on-disk mtime
		# change, which a declined checkout never causes). Costs the tab.
		_log("Closing and discarding unsaved changes to script '%s'..." % res_path)
		get_editor_interface().get_script_editor().close_file(res_path)
	else:
		_log("Reloading resource '%s' from disk..." % res_path)
		var reloaded := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if reloaded:
			get_editor_interface().edit_resource(reloaded)
	_checked_out_this_session.erase(res_path)
	_declined_this_session.erase(res_path)
	_pending_save_checkout.erase(res_path)
	# Revert/sync/reload all change what's opened - reflect it in the tree.
	_request_refresh()


func _clear_auto_checkout_suppression() -> void:
	_suppress_auto_checkout = false


# ---------------------------------------------------------------------------
# CLI self-tests (headless smoke tests; harmless no-ops in normal use)
#
#   godot --headless --editor --path <project> -- --p4-selftest-<name>=res://<file>
#
# --p4-selftest-checkout / --p4-selftest-reload exercise _do_checkout()/
# _reload_path() directly. --p4-selftest-simulate-edit performs a REAL
# commit_action() - the same thing a user edit fires - to regression-test the
# signal hookup itself; combine with --p4-selftest-auto-answer=confirm|decline
# to drive the dialog's resolution path. --p4-selftest-save-checkout and
# --p4-selftest-save-rescue exercise the save-time paths: pre-write checkout
# via _apply_changes(), and the failed-save rescue dialog via scene_saved.
#
# Harness notes (verified the hard way): clear open_scenes/current_scene in
# .godot/editor/editor_layout.cfg before every headless run (restoring real
# scenes at boot hangs the headless editor), expect Main::start to auto-open
# the project's main scene when the session is empty, and expect the process
# to linger after quit() once scene tabs were opened - kill it from the
# harness after output stops; assert on the log lines, not the exit code.
# ---------------------------------------------------------------------------

func _run_cli_self_test_if_requested() -> void:
	var has_selftest_arg := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--p4-selftest-"):
			has_selftest_arg = true
		if arg.begins_with("--p4-selftest-auto-answer="):
			_selftest_auto_answer = arg.substr("--p4-selftest-auto-answer=".length())
	if not has_selftest_arg:
		return
	# Identity detection is async now - resolve it before dispatching so tests
	# exercise the plugin's steady state, not its boot race.
	await _ensure_identity()

	for arg in OS.get_cmdline_user_args():
		if arg == "--p4-selftest-parse-ztag":
			# Server-independent: feed a canned tagged blob (CRLF line endings, a
			# blank-line record separator, and a multi-line desc continuation) to
			# _parse_ztag and assert the structure it recovers.
			var blob := "... action edit\r\n... change default\r\n\r\n" \
					+ "... change 123\r\n... desc first line\r\nsecond line\r\n... user bob\r\n"
			var recs := _parse_ztag({"exit_code": 0, "output": [blob]})
			_log("[selftest] ztag records: %d" % recs.size())
			if recs.size() == 2:
				_log("[selftest] rec0 action=%s change=%s" % [recs[0].get("action", "?"), recs[0].get("change", "?")])
				var desc_lines := String(recs[1].get("desc", "")).split("\n").size()
				_log("[selftest] rec1 change=%s desc-lines=%d" % [recs[1].get("change", "?"), desc_lines])
				if recs[0].get("action") == "edit" and recs[0].get("change") == "default" \
						and recs[1].get("change") == "123" and desc_lines == 2:
					_log("[selftest] PASS: parse-ztag")
				else:
					_log("[selftest] FAIL: parse-ztag field mismatch")
			else:
				_log("[selftest] FAIL: parse-ztag expected 2 records")
			get_tree().quit()
			return
		if arg == "--p4-selftest-list-opened":
			# Live (needs the server): exercise the opened + where + changes
			# pipeline and the depot->res mapping end to end.
			var model := await _query_pending_model()
			_log("[selftest] available=%s changelists=%d" % [model.available, model.changelists.size()])
			for cl in model.changelists:
				_log("[selftest] CL %s: %d file(s) - %s" % [cl.change, cl.files.size(), cl.desc])
				for f in cl.files:
					_log("[selftest] opened: %s (%s) cl=%s" % [f.res_path, f.action, f.change])
			get_tree().quit()
			return
		if arg == "--p4-selftest-tree":
			# Live: refresh and walk the built Tree (items exist in memory even
			# headless) to confirm _rebuild_tree populated CLs and file rows.
			while _refresh_inflight: # let the initial _build_dock refresh settle
				await get_tree().process_frame
			await _refresh_changelists()
			var root := tree.get_root()
			var cl_count := 0
			var file_count := 0
			var cl_item: TreeItem = root.get_first_child() if root else null
			while cl_item != null:
				cl_count += 1
				var f_item := cl_item.get_first_child()
				while f_item != null:
					file_count += 1
					f_item = f_item.get_next()
				cl_item = cl_item.get_next()
			_log("[selftest] tree changelists=%d files=%d" % [cl_count, file_count])
			get_tree().quit()
			return
		if arg == "--p4-selftest-context-menu":
			# Server-independent: assert the per-row menu item sets.
			_populate_context_menu({"type": "file", "res_path": "res://x.gd", "change": "default"})
			_log("[selftest] file-menu items=%d" % context_menu.item_count)
			_populate_context_menu({"type": "cl", "change": "default"})
			_log("[selftest] default-cl-menu items=%d" % context_menu.item_count)
			_populate_context_menu({"type": "cl", "change": "123", "desc": "wip"})
			_log("[selftest] numbered-cl-menu items=%d" % context_menu.item_count)
			get_tree().quit()
			return
		if arg == "--p4-selftest-reconcile-preview":
			# Live, non-destructive (reconcile -n).
			var preview := await _reconcile_preview()
			_log("[selftest] reconcile preview: %d change(s)" % preview.size())
			get_tree().quit()
			return
		if arg == "--p4-selftest-revert-unchanged-preview":
			# Live, non-destructive (revert -a -n); also checks clientFile->res.
			var preview := await _revert_unchanged_preview()
			_log("[selftest] revert-unchanged preview: %d file(s)" % preview.size())
			for rec in preview:
				_log("[selftest]   -> %s" % _local_to_res(String(rec.get("clientFile", ""))))
			get_tree().quit()
			return
		if arg == "--p4-selftest-build-change-spec":
			# Server-independent: replace a spec's Description, keep its Files.
			var template := "Change:\t123\n\nUser:\tbob\n\nDescription:\n\told line\n\nFiles:\n\t//depot/a\t# edit\n"
			var extracted := _extract_spec_description(template)
			var edited := _replace_spec_description(template, "new desc\nsecond")
			_log("[selftest] extracted-desc=%s" % extracted.replace("\n", "|"))
			var ok := extracted == "old line" and edited.contains("new desc") \
					and edited.contains("second") and edited.contains("//depot/a") \
					and not edited.contains("old line")
			_log("[selftest] %s: build-change-spec" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-create-changelist":
			# Live: exercise the full stdin-spec plumbing, then clean up.
			var num := await _create_changelist("[P4 selftest] temp CL - safe to delete")
			_log("[selftest] created CL=%s" % num)
			if not num.is_empty():
				var del := await _p4_exec_logged(["change", "-d", num])
				_log("[selftest] cleanup delete exit=%d" % del.exit_code)
				_log("[selftest] %s: create-changelist" % ("PASS" if del.exit_code == 0 else "FAIL"))
			else:
				_log("[selftest] FAIL: create-changelist (no number returned)")
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-checkout="):
			var path := arg.substr("--p4-selftest-checkout=".length())
			_log("[selftest] Forcing checkout of '%s'" % path)
			if not await _needs_checkout(ProjectSettings.globalize_path(path)):
				_log("[selftest] no checkout needed")
			else:
				await _do_checkout(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-reload="):
			var path := arg.substr("--p4-selftest-reload=".length())
			_log("[selftest] Forcing reload-from-disk of '%s'" % path)
			_reload_path(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-simulate-edit="):
			var path := arg.substr("--p4-selftest-simulate-edit=".length())
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-checkout="):
			var path := arg.substr("--p4-selftest-save-checkout=".length())
			# set_pressed_no_signal: don't let test toggles persist into the
			# user's real project metadata via _on_setting_toggled.
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(true)
			await _selftest_simulate_edit(path)
			# The edit-time flow is async - wait for it to settle so the
			# pending-for-save report below is deterministic.
			await _selftest_drain_frames()
			_log("[selftest] pending-for-save: %s" % [_pending_save_checkout.keys()])
			await _selftest_make_current(path)
			get_editor_interface().save_scene()
			await _selftest_drain_frames()
			await _selftest_report_opened(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-rescue="):
			var path := arg.substr("--p4-selftest-save-rescue=".length())
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(false)
			await _selftest_simulate_edit(path)
			await _selftest_make_current(path)
			var save_err := get_editor_interface().save_scene()
			_log("[selftest] save_scene() returned error code %d" % save_err)
			await _selftest_drain_frames()
			await _selftest_report_opened(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-current="):
			# Open and save a scene WITHOUT editing it - exercises companion-
			# resource writes (a load-modified .tres gets written on every
			# scene save) without touching the scene's own content.
			var path := arg.substr("--p4-selftest-save-current=".length())
			await _selftest_make_current(path)
			get_editor_interface().save_scene()
			await _selftest_drain_frames()
			await _selftest_drain_frames()
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-rescue-multi="):
			# Comma-separated scene list; verifies Save All failures collapse
			# into ONE batched rescue dialog that checks out all of them.
			var paths := arg.substr("--p4-selftest-save-rescue-multi=".length()).split(",")
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(false)
			for p in paths:
				await _selftest_simulate_edit(p)
			# Let the async edit-time flows settle before saving, so the save
			# pass starts from the same state the old synchronous code had.
			await _selftest_drain_frames()
			get_editor_interface().save_all_scenes()
			await _selftest_drain_frames()
			await _selftest_drain_frames()
			for p in paths:
				await _selftest_report_opened(p)
			get_tree().quit()
			return


func _selftest_simulate_edit(path: String) -> void:
	_log("[selftest] Opening '%s' and simulating a real commit_action()..." % path)
	get_editor_interface().open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	# Main::start auto-opens the project's MAIN scene at a nondeterministic
	# point during boot (see _selftest_make_current) - it can steal the
	# current tab between our open and our commit, making the edit land on
	# the wrong scene. Refocus until the requested scene is actually current.
	var scene_root := get_editor_interface().get_edited_scene_root()
	for attempt in range(10):
		if scene_root != null and scene_root.get_scene_file_path() == path:
			break
		get_editor_interface().open_scene_from_path(path)
		await get_tree().process_frame
		await get_tree().process_frame
		scene_root = get_editor_interface().get_edited_scene_root()
	if scene_root == null or scene_root.get_scene_file_path() != path:
		_log("[selftest] FAILED: couldn't make '%s' the edited scene" % path)
		return
	# A harmless do/undo pair (universal Object meta, nothing type-specific):
	# what matters is that commit_action() fires history_changed and our
	# handler reacts, not that the edit does anything meaningful.
	var ur := get_undo_redo()
	ur.create_action("[P4 selftest] dummy edit")
	ur.add_do_method(scene_root, "set_meta", "_p4_selftest", true)
	ur.add_undo_method(scene_root, "remove_meta", "_p4_selftest")
	ur.commit_action()
	await get_tree().process_frame
	_log("[selftest] commit_action() done for '%s'" % path)


## Re-focuses `path` as the current scene tab. Needed because when the editor
## session restored no tabs, Main::start auto-opens the project's MAIN scene
## (main.cpp), stealing current-tab focus from the scene a test opened during
## plugin init - EditorInterface.save_scene() would then save the main scene
## instead of the scene under test.
func _selftest_make_current(path: String) -> void:
	get_editor_interface().open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	var root := get_editor_interface().get_edited_scene_root()
	_log("[selftest] current scene at save time: '%s'" % (root.get_scene_file_path() if root else "<none>"))


## Prompt resolution, p4 round trips, and rescue probes all run as independent
## un-awaited coroutines off the signal handlers. Fixed frame counts can't
## bound that anymore: wait until the p4 worker, save probes, rescue queue,
## and dialogs have ALL been idle for a stretch of consecutive frames (a
## momentary lull between pipeline stages must not end the wait early), with a
## hard time cap so a regression fails loudly instead of hanging the harness.
func _selftest_drain_frames() -> void:
	var deadline := Time.get_ticks_msec() + 20000
	var idle_streak := 0
	while idle_streak < 10 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if _identity_checked and _p4_inflight == 0 and _rescue_probes_inflight == 0 \
				and not _dialog_busy and not _rescue_scheduled and _rescue_paths.is_empty():
			idle_streak += 1
		else:
			idle_streak = 0
	if idle_streak < 10:
		_log("[selftest] WARNING: timed out waiting for idle (inflight=%d probes=%d dialog=%s)"
				% [_p4_inflight, _rescue_probes_inflight, _dialog_busy])
	_log("[selftest] done waiting.")


func _selftest_report_opened(path: String) -> void:
	if not await _needs_checkout(ProjectSettings.globalize_path(path)):
		_log("[selftest] PASS: '%s' is opened for edit in our workspace." % path)
	else:
		_log("[selftest] FAIL: '%s' is NOT opened in our workspace." % path)
