@tool
extends "p4godot_core.gd"

## Following what happens to files in the editor: checkout on edit and on save,
## failed-save rescue, reloading from disk, FileSystem-dock delete/move/rename,
## changes made outside Godot, and the startup checks.

## Shown wherever an action needs Perforce and there's no connection. One
## constant because six copies of it drifted apart.
const NOT_CONNECTED_MESSAGE := ("Godot isn't connected to Perforce, so it can't do " +
		"this.\n\nOpen the P4G panel - normally at the bottom of the editor - and press " +
		"the circular-arrow Refresh button. It walks you through connecting. The \"Log\" " +
		"button in that panel shows what went wrong.")

# res:// path -> true while WE are reloading that file from disk. Refilling a
# script tab emits text_changed exactly like typing does; without this, our
# own reload would prompt for a checkout of the file it just discarded.
var _reloading_paths: Dictionary = {}

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

# res:// paths whose no-op failed save wants the editor's "Unable to write"
# modal dismissed, plus the single-loop guard - the editor reuses ONE
# AcceptDialog for every save error in a pass, so one scan serves the batch
# (see _dismiss_save_error_dialog).
var _error_dismiss_names: Array = []
var _error_dismiss_running: bool = false

# Pre-write pass state (see _prewrite_pass): res:// path -> backup file path
# for files made temporarily writable so the imminent save can't fail.
var _prewrite_managed: Dictionary = {}
var _prewrite_finish_queued: bool = false

# Read-only .import files made writable for an in-progress reimport: global
# path -> original bytes. See _on_resources_reimporting.
var _reimport_backups: Dictionary = {}
const REIMPORT_CONFIRM_THRESHOLD := 20
# The Import dock's Reimport button, hooked by _hook_import_dock.
var _import_reimport_button: Button = null

# Last-seen UndoRedo version per editor history id (see _history_advanced).
var _history_versions: Dictionary = {}

# res:// path -> [mtime, direct res:// dependencies] (see _direct_deps).
var _deps_cache: Dictionary = {}

# res:// path -> Time.get_ticks_msec() when _finish_prewrite_pass settled it.
var _prewrite_settled: Dictionary = {}

# See _shader_files.
var _shader_files_cache: Array = []
var _shader_files_dirty: bool = true
# ---------------------------------------------------------------------------
# Edit detection - "checkout on edit"
# ---------------------------------------------------------------------------

func _on_undo_redo_history_changed() -> void:
	# _suppress_auto_checkout is frame-scoped, so it must be read here,
	# synchronously with the emission. p4 availability is _handle_edit's
	# problem (it can await the startup check; this handler can't).
	if _suppress_auto_checkout:
		return

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		var scene_path := scene_root.get_scene_file_path()
		if not scene_path.is_empty() and _history_advanced(scene_root):
			_handle_edit(scene_path)

	# A standalone resource opened from the FileSystem dock (e.g. a .tres not
	# belonging to any scene) commits into a history that isn't tied to the
	# edited scene root above - catch it via the Inspector instead.
	var edited_object := EditorInterface.get_inspector().get_edited_object()
	if edited_object is Resource:
		var res: Resource = edited_object
		if not res.is_built_in() and not res.resource_path.is_empty() \
				and _history_advanced(res):
			_handle_edit(res.resource_path)


## history_changed also fires without any edit: clear_history() (e.g. switching
## to a scene tab whose instanced sub-scene changed) and set_history_as_unsaved.
## Only a committed action (or a redo) raises the history's UndoRedo version,
## so act only when it went up since we last looked. Versions start at 1.
func _history_advanced(obj: Object) -> bool:
	var ur := get_undo_redo()
	var hid := ur.get_object_history_id(obj)
	var history := ur.get_history_undo_redo(hid)
	if history == null:
		return true # Can't tell - keep the old behavior (prompt).
	var ver := history.get_version()
	var prev: int = _history_versions.get(hid, 1)
	_history_versions[hid] = ver
	return ver > prev


func _on_active_script_changed(script: Script) -> void:
	_disconnect_current_code_edit()
	if script == null or script.resource_path.is_empty():
		return
	var current_editor := EditorInterface.get_script_editor().get_current_editor()
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
			or _inflight_edit_checks.has(res_path) \
			or _reloading_paths.has(res_path):
		return
	# Its last status check failed moments ago (server down, dead ticket):
	# don't start another round trip on every keystroke. Saves still check.
	var gp := ProjectSettings.globalize_path(res_path)
	if _fstat_failed.has(gp) and Time.get_ticks_msec() - int(_fstat_failed[gp]) < 30000:
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
		_remember_no_checkout(res_path, ProjectSettings.globalize_path(res_path))
		return

	if _auto_open():
		# Auto mode: check out silently, no prompt. A failure (e.g. someone else
		# holds it exclusively) still needs a decision, so surface it.
		var result: Dictionary = await _do_checkout(res_path)
		if not result.ok:
			await _on_edit_checkout_failed(res_path, result.reason)
	elif auto_checkout_checkbox.button_pressed:
		await _prompt_then_checkout(res_path)
	else:
		_pending_save_checkout[res_path] = true
		_log("'%s' was edited but isn't checked out - it will be handled when you save." % res_path)


func _prompt_then_checkout(res_path: String) -> void:
	_log("'%s' isn't checked out - prompting..." % res_path)
	var choices: Array = await _pending_changelist_choices()
	var picked: Dictionary = await _show_checkout_target_dialog(
			("Check out '%s'?\n\nChecking out tells Perforce you're editing this file. " +
			"Godot can't save it until you do, and your team can see it's in use.\n\n" +
			"If you don't, the file is reloaded from disk and any unsaved edits to it " +
			"are lost - for a scene, that's all of its unsaved edits, not just this one.")
					% res_path,
			"Check Out", "Discard My Changes", choices)
	if picked.ok:
		var result: Dictionary = await _do_checkout(res_path, picked.change)
		if not result.ok:
			await _on_edit_checkout_failed(res_path, result.reason)
	else:
		_log("Declined checkout of '%s' - discarding the in-editor change and reloading from disk..." % res_path)
		# Suppress re-prompting only when the discard could NOT be confirmed.
		# A reload that silently failed leaves the change sitting in the
		# editor, and every keystroke after it would prompt again. A
		# confirmed reload puts the editor back in step with the depot, so
		# the user's next edit is a genuinely new one and has to prompt -
		# that's what makes declining once not turn checkout off for the
		# rest of the session. (_reload_path clears the flag itself, so this
		# has to be set after it, not before.)
		if not await _reload_path(res_path):
			_declined_this_session[res_path] = true


## The user said "Check Out" but Perforce refused (most commonly: someone else
## has the file exclusively checked out). Their edit is stranded - it exists
## in the editor but can't reach disk - so explain who has the file and offer
## the two honest options: keep working (checkout retries on save, in case the
## lock clears) or discard the change now.
func _on_edit_checkout_failed(res_path: String, reason: String) -> void:
	var keep: bool = await _show_confirm_dialog(
			("Perforce won't let you edit '%s' right now - %s.\n\n" +
			"That usually means a teammate is working on the same file, and only they " +
			"can change it until they're done. Ask them to send their work to the " +
			"server or set it aside.\n\n" +
			"Your edit is still here in Godot. Keep it and Godot will try again each " +
			"time you save.") % [res_path, reason],
			"Keep My Edit", "Throw It Away")
	if keep:
		# Also stops _handle_edit() from re-prompting on every keystroke.
		_pending_save_checkout[res_path] = true
		_log("Keeping in-editor changes to '%s'; checkout will be retried on save." % res_path)
	else:
		_log("Discarding the in-editor change to '%s' and reloading from disk..." % res_path)
		if not await _reload_path(res_path):
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
	if not _p4_available:
		return
	if _server_unreachable():
		# Don't stall the save on a server that just failed to answer. Files
		# that aren't checked out follow the no-checkout save paths (and on
		# macOS/Linux are left writable so a sync can't overwrite them).
		if not _pending_save_checkout.is_empty():
			_log("Saving without checking out %s - the Perforce server isn't answering. Check out or Reconcile once it's back." % ", ".join(_pending_save_checkout.keys()))
		for res_path: String in _pending_save_checkout.keys():
			_rescue_skip_frame[res_path] = Engine.get_process_frames()
		if checkout_on_save_checkbox.button_pressed:
			_prewrite_pass() # cached eligibility only; its status query is skipped
		return
	if checkout_on_save_checkbox.button_pressed:
		var failures: Array = []
		for res_path: String in _pending_save_checkout.keys():
			if FileAccess.open(ProjectSettings.globalize_path(res_path), FileAccess.READ_WRITE) != null:
				# Already writable (an allwrite workspace, a +w file): the write
				# can't fail, so the save doesn't wait on the server. The
				# post-save handlers check it out once it has landed.
				continue
			_log("Checking out '%s' before saving..." % res_path)
			var result: Dictionary = _do_checkout_sync(res_path)
			if not result.ok:
				failures.append("- '%s': %s" % [res_path, result.reason])
				# The write that follows will fail too; the alert below already
				# explains why, so don't ALSO queue the failed-save rescue dialog.
				_rescue_skip_frame[res_path] = Engine.get_process_frames()
		if not failures.is_empty():
			if OS.get_name() == "Windows":
				_show_alert(("Perforce wouldn't let you edit these files, so Godot couldn't " +
						"save them:\n\n%s\n\n" +
						"Your changes are still here in the editor - nothing is lost. The note " +
						"beside each file says why; most often a teammate is working on it, and " +
						"you have to wait for them to send their work to the server or set it " +
						"aside. Godot tries again every time you save.")
						% "\n".join(failures))
			else:
				# macOS/Linux saves replace the file by rename, which a read-only
				# target doesn't block: the write lands anyway (_scene_saved_probe
				# and _on_resource_saved then leave the file writable).
				_show_alert(("Perforce wouldn't let you edit these files:\n\n%s\n\n" +
						"Your work IS saved on disk, so nothing is lost - but Perforce doesn't " +
						"know about it, which means your team won't get it. Godot tries again " +
						"each time you save. You can also press \"Reconcile...\" in the P4G " +
						"panel, which finds changed files and tells Perforce about them.")
						% "\n".join(failures))
		# Only with checkout-on-save on: the pass ends by checking out whatever
		# the save changed. With it off, a read-only file's save fails and the
		# rescue dialog asks first.
		_prewrite_pass()


## The save-can't-fail pass, run synchronously right before the editor
## writes. Godot rewrites files on every save whether or not anything
## changed, and a write to a read-only (not checked out) file fails SLOWLY -
## the safe-save retries the rename over the read-only target with sleeps
## between attempts (a multi-second editor stall) - and then pops the Load
## Errors dialog. So instead of letting the write fail: back up every
## read-only, tracked, unopened file the pass might write and make it
## briefly writable, so the write succeeds instantly. _finish_prewrite_pass
## (deferred to right after the writes, which all happen within this frame)
## then makes files whose content didn't actually change read-only again -
## Perforce untouched - and checks out the ones that did change. A save that
## landed is never rolled back: if Perforce refuses the checkout, the file
## stays as saved and writable, and the user is told it isn't in a changelist.
func _prewrite_pass() -> void:
	var candidates: Array = []  # read-only candidates (res:// paths)
	var unknown: Array = []     # of those, eligibility not cached yet (OS paths)
	for res_path: String in _prewrite_candidates():
		if _prewrite_managed.has(res_path) or _checked_out_this_session.has(res_path) \
				or _pending_save_checkout.has(res_path) \
				or _rescue_skip_frame.get(res_path, -1) == Engine.get_process_frames():
			continue
		var global_path := ProjectSettings.globalize_path(res_path)
		if not FileAccess.file_exists(global_path):
			continue
		if FileAccess.open(global_path, FileAccess.READ_WRITE) != null:
			continue # Writable - checked out, allwrite, or plain untracked.
		candidates.append(res_path)
		if not _prewrite_eligible_cache.has(res_path):
			unknown.append(global_path)
	if candidates.is_empty():
		return
	if not unknown.is_empty():
		# One batched fstat resolves tracked-and-unopened for every unknown
		# candidate. Synchronous by necessity (the writes start the moment
		# _apply_changes returns) - the same tradeoff as the pre-save checkout
		# above. The cache keeps repeat saves at zero extra round trips.
		# Chunked: one command line per 50 paths keeps big projects under the
		# Windows command-line length limit.
		var by_client := {}
		var unknown_failed := {} # OS paths whose chunk failed outright
		for i in range(0, unknown.size(), 50):
			var chunk: Array = unknown.slice(i, i + 50)
			var fstat_result := _p4_exec_sync(PackedStringArray(["-ztag", "fstat"] + chunk))
			var recs := _parse_ztag(fstat_result)
			for rec in recs:
				var cf := String(rec.get("clientFile", ""))
				if not cf.is_empty():
					by_client[cf.replace("\\", "/").to_lower()] = rec
			# A failed fstat with no records (server unreachable, dead ticket) is
			# "unknown", not "untracked": skip those files this time, cache nothing.
			if int(fstat_result.exit_code) != 0 and recs.is_empty():
				for p: String in chunk:
					unknown_failed[p] = true
		for res_path: String in candidates:
			if _prewrite_eligible_cache.has(res_path) \
					or unknown_failed.has(ProjectSettings.globalize_path(res_path)):
				continue
			var key := ProjectSettings.globalize_path(res_path).replace("\\", "/").to_lower()
			var rec: Dictionary = by_client.get(key, {})
			# Tracked (fstat returned a record) and not opened by us (no action).
			_prewrite_eligible_cache[res_path] = not rec.is_empty() and not rec.has("action")
	for res_path: String in candidates:
		if not _prewrite_eligible_cache.get(res_path, false):
			continue
		var global_path := ProjectSettings.globalize_path(res_path)
		var backup := _prewrite_backup_path(res_path)
		if DirAccess.copy_absolute(global_path, backup) != OK:
			continue # No backup, no trick - the old failed-save flow still works.
		if not _set_file_writable(global_path, true):
			DirAccess.remove_absolute(backup)
			continue
		_prewrite_managed[res_path] = backup
	if not _prewrite_managed.is_empty() and not _prewrite_finish_queued:
		_prewrite_finish_queued = true
		call_deferred("_finish_prewrite_pass")


## Files the imminent save pass might write: open scenes, their direct
## .tres/.res dependencies, open scripts, and the inspected resource.
## Over-approximation is fine: a file made writable that the editor then
## doesn't write is byte-identical afterwards and is put back untouched.
func _prewrite_candidates() -> Array:
	var roots: Array = []
	for p in EditorInterface.get_open_scenes():
		roots.append(String(p))
	for s in EditorInterface.get_script_editor().get_open_scripts():
		var sp: String = (s as Script).resource_path
		if not sp.is_empty():
			roots.append(sp)
	var inspected: Object = EditorInterface.get_inspector().get_edited_object()
	if inspected is Resource and not (inspected as Resource).is_built_in() \
			and not (inspected as Resource).resource_path.is_empty():
		roots.append((inspected as Resource).resource_path)
	# Scene saves also write every loaded resource the editor considers edited
	# (EditorNode::_save_external_resources) - notably shaders open in the
	# shader editor, which no dependency list reaches. Loaded = cached.
	for sp: String in _shader_files():
		if ResourceLoader.has_cached(sp):
			roots.append(sp)
	var out: Array = []
	var seen := {}
	for root_path: String in roots:
		if not root_path.begins_with("res://"):
			continue
		if not seen.has(root_path):
			seen[root_path] = true
			out.append(root_path)
		var rext := root_path.get_extension().to_lower()
		if rext != "tscn" and rext != "scn":
			continue
		# Scene saves also write the scene's MODIFIED external resources.
		for dep_path: String in _resource_deps_deep(root_path):
			if not seen.has(dep_path):
				seen[dep_path] = true
				out.append(dep_path)
	return out


## External resources a save of `scene_path` may write: its .tres/.res
## dependencies, followed through nested .tres/.res (a material inside a
## tileset...) but not into other scenes, which a scene save never writes.
## Dependency lists are cached per file by mtime; the walk is capped so a huge
## dependency web can't slow every save.
func _resource_deps_deep(scene_path: String) -> Array:
	var out: Array = []
	var seen := {scene_path: true}
	var queue: Array = [scene_path]
	while not queue.is_empty() and out.size() < 400:
		var cur: String = queue.pop_front()
		for dep_path: String in _direct_deps(cur):
			if seen.has(dep_path):
				continue
			seen[dep_path] = true
			var dext := dep_path.get_extension().to_lower()
			if dext == "tres" or dext == "res":
				out.append(dep_path)
				queue.append(dep_path)
	return out


func _direct_deps(res_path: String) -> Array:
	var mtime := FileAccess.get_modified_time(ProjectSettings.globalize_path(res_path))
	var cached: Array = _deps_cache.get(res_path, [])
	if not cached.is_empty() and int(cached[0]) == mtime:
		return cached[1]
	var deps: Array = []
	for dep: String in ResourceLoader.get_dependencies(res_path):
		# Entries may be "uid://xxx::res://path" - take the path part.
		var dep_path := dep.get_slice("::", dep.get_slice_count("::") - 1)
		if dep_path.begins_with("res://"):
			deps.append(dep_path)
	_deps_cache[res_path] = [mtime, deps]
	return deps


## Shader files in the project (Shader, ShaderInclude, VisualShader), from the
## editor's in-memory filesystem; rebuilt after filesystem changes.
func _shader_files() -> Array:
	if _shader_files_cache.is_empty() or _shader_files_dirty:
		_shader_files_dirty = false
		_shader_files_cache = []
		var root := EditorInterface.get_resource_filesystem().get_filesystem()
		if root:
			_collect_shader_files(root, _shader_files_cache)
	return _shader_files_cache


func _collect_shader_files(dir: EditorFileSystemDirectory, out: Array) -> void:
	for i in dir.get_file_count():
		if String(dir.get_file_type(i)) in ["Shader", "ShaderInclude", "VisualShader"]:
			out.append(dir.get_file_path(i))
	for i in dir.get_subdir_count():
		_collect_shader_files(dir.get_subdir(i), out)


func _on_filesystem_changed() -> void:
	_shader_files_dirty = true
	# Deliberately no external-change scan here. filesystem_changed fires
	# after every editor rescan - every save, every import - and the scan is a
	# reconcile preview of the whole project, so hanging it off this signal
	# would put a full scan on the server every few seconds while someone is
	# just working. Focus-in is the right cadence, and it's what the README
	# promises; the Reconcile button covers anything in between.


func _finish_prewrite_pass() -> void:
	_prewrite_finish_queued = false
	var managed := _prewrite_managed
	_prewrite_managed = {}
	for res_path: String in managed.keys():
		# The dependency probe (deferred after this) must not re-examine files
		# this pass just settled.
		_prewrite_settled[res_path] = Time.get_ticks_msec()
		var backup := String(managed[res_path])
		var global_path := ProjectSettings.globalize_path(res_path)
		var cur := FileAccess.get_file_as_bytes(global_path)
		var old := FileAccess.get_file_as_bytes(backup)
		if cur == old or (not cur.is_empty() and not old.is_empty() \
				and _contents_match(cur, old, global_path.get_extension().to_lower())):
			# No actual change: only the read-only bit goes back. The bytes stay
			# as the editor left them - copying the backup over would move the
			# file's modified time behind the editor's back, and its next focus-in
			# scan would offer to "reload from disk" (discarding unsaved edits).
			# An LF rewrite of a CRLF file is invisible to `p4 reconcile` anyway.
			_set_file_writable(global_path, false)
			DirAccess.remove_absolute(backup)
			if cur != old:
				_log("Save of '%s' only changed line endings - left unopened." % res_path)
			continue
		DirAccess.remove_absolute(backup)
		_log("'%s' changed on save while not checked out - checking it out to keep the changelist accurate." % res_path)
		var result: Dictionary = await _do_checkout(res_path)
		if result.ok or _shutting_down:
			continue
		# Perforce refused (exclusive checkout elsewhere, connection loss...).
		# The editor already recorded this save as done, so rolling the disk
		# back would silently lose the edit. Keep it, writable, so `p4 sync`
		# refuses to overwrite it and Reconcile finds it.
		# (Its next save retries the checkout via the "saved while not checked
		# out" path in _scene_saved_probe / _on_resource_saved.)
		_set_file_writable(global_path, true)
		_show_alert(("Godot saved '%s', but Perforce wouldn't record the change - %s.\n\n" +
				"Your work is safe on your computer. Perforce still doesn't know about " +
				"it, so your team won't get it yet, and Godot has left the file unlocked " +
				"so that downloading the latest version can't overwrite what you wrote. " +
				"Godot tries again each time you save; \"Reconcile...\" in the P4G panel " +
				"also picks it up once the file is free.")
				% [res_path, result.reason])


## Flip the OS-level write protection Perforce puts on unopened files.
## Windows: the FILE_ATTRIBUTE_READONLY flag (exactly what p4 sets and
## clears). macOS/Linux: p4 uses permission bits (chmod 444), so chmod is
## the tool - FileAccess.set_read_only_attribute is wrong there (it flips
## the unrelated immutable flag on macOS and does nothing on Linux).
func _set_file_writable(global_path: String, writable: bool) -> bool:
	if OS.get_name() == "Windows":
		return FileAccess.set_read_only_attribute(global_path, not writable) == OK
	var perms: int = FileAccess.get_unix_permissions(global_path)
	if writable:
		perms |= FileAccess.UNIX_WRITE_OWNER
	else:
		perms &= ~(FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_WRITE_GROUP | FileAccess.UNIX_WRITE_OTHER)
	return FileAccess.set_unix_permissions(global_path, perms) == OK


## Whether the save that just happened actually wrote `global_path`. Windows
## refuses to replace a read-only file, so there "writable" is the answer.
## macOS/Linux safe-saves write a temp file and rename it over the target,
## which a read-only target doesn't block (the new file even inherits the
## read-only mode) - so a fresh modified time is the only reliable evidence.
func _save_landed(global_path: String) -> bool:
	if FileAccess.open(global_path, FileAccess.READ_WRITE) != null:
		return true
	if OS.get_name() == "Windows":
		return false
	var age := Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(global_path))
	return absf(age) < 10.0 # abs: tolerate small clock skew on network drives


## macOS/Linux: a save that lands on a read-only file leaves it read-only (the
## rename keeps the old mode), and `p4 sync` overwrites read-only files without
## asking. When Perforce can't be asked whether the file is checked out, make
## it writable so a sync refuses to clobber the edit. Windows never lands a
## save on a read-only file, so this is a no-op there.
func _protect_landed_save(res_path: String, global_path: String) -> void:
	if OS.get_name() == "Windows" or FileAccess.open(global_path, FileAccess.READ_WRITE) != null:
		return
	if _set_file_writable(global_path, true):
		_log("'%s' was saved while Perforce couldn't be asked about it - left writable so a sync can't overwrite it. Run Reconcile once Perforce is reachable." % res_path)


func _sweep_cache_dir() -> void:
	var dir := _p4godot_cache_dir()
	var now := Time.get_unix_time_from_system()
	for f in DirAccess.get_files_at(dir):
		var path := dir.path_join(f)
		if now - float(FileAccess.get_modified_time(path)) > 3600.0:
			DirAccess.remove_absolute(path)


func _prewrite_backup_path(res_path: String) -> String:
	# Keyed by the absolute path: two open projects can share a res:// path.
	var global_path := ProjectSettings.globalize_path(res_path)
	return _p4godot_cache_dir().path_join("prewrite_%s.bak" % global_path.md5_text())


## Every reimport rewrites `<asset>.import` whether or not anything changed
## (EditorFileSystem::_reimport_file), and when that write fails it also skips
## the `.godot/imported/*.md5` that marks the import done - so in a read-only
## workspace every reimported asset errors ("Cannot open file ... .import") and
## reimports again on the next launch, forever. A fresh sync with no .godot/
## folder hits it for every asset in the project.
##
## resources_reimporting fires synchronously right before the imports run, and
## plugins initialize before the startup scan, so this covers startup too:
## back up each read-only .import (in memory - they're small) and make it
## writable. _on_resources_reimported then sorts them out.
func _on_resources_reimporting(resources: PackedStringArray) -> void:
	for res_path in resources:
		_arm_reimport_guard(ProjectSettings.globalize_path(String(res_path) + ".import"))


## Back up a read-only .import and make it writable for an imminent write.
## Returns true if it armed (false: already armed, missing, or writable).
func _arm_reimport_guard(global_path: String) -> bool:
	if _reimport_backups.has(global_path) or not FileAccess.file_exists(global_path):
		return false
	if FileAccess.open(global_path, FileAccess.READ_WRITE) != null:
		return false # Writable: checked out, allwrite, or untracked.
	var bytes := FileAccess.get_file_as_bytes(global_path)
	if bytes.is_empty() or not _set_file_writable(global_path, true):
		return false
	_reimport_backups[global_path] = bytes
	return true


## The Import dock writes new settings into each selected asset's .import
## BEFORE any plugin hook runs (ImportDock::_reimport_attempt saves, then calls
## reimport_files), so on a read-only .import the settings change fails. Its
## Reimport button's button_down fires before the pressed handler that does
## that save: arm the reimport guard for the dock's files then. The save
## succeeds, and _on_resources_reimported checks out whatever really changed
## (or re-locks it).
func _hook_import_dock() -> void:
	var import_dock := _find_node_of_class(get_tree().root, "ImportDock")
	if import_dock == null:
		return
	for b in import_dock.find_children("*", "Button", true, false):
		# Created with the untranslated text "Reimport" (TTRC); it only reads
		# "Reimport (*)" later, while settings are pending.
		if b.get_class() == "Button" and String((b as Button).text) == "Reimport":
			_import_reimport_button = b
			if not b.button_down.is_connected(_on_import_reimport_down):
				b.button_down.connect(_on_import_reimport_down)
			return


func _find_node_of_class(root: Node, cls: String) -> Node:
	if root.get_class() == cls:
		return root
	for c in root.get_children():
		var found := _find_node_of_class(c, cls)
		if found:
			return found
	return null


func _on_import_reimport_down() -> void:
	var armed := PackedStringArray()
	for res_path: String in _import_dock_targets():
		if _arm_reimport_guard(ProjectSettings.globalize_path(res_path + ".import")):
			armed.append(res_path)
	if armed.is_empty():
		return
	# Normally settled by _on_resources_reimported. If no reimport comes (the
	# user cancels Godot's importer-change confirmation), re-lock them later.
	get_tree().create_timer(30.0).timeout.connect(_settle_armed_reimports.bind(armed))


func _settle_armed_reimports(res_paths: PackedStringArray) -> void:
	if _shutting_down:
		return
	var changed := _classify_reimported(res_paths)
	if not changed.is_empty():
		await _checkout_reimported(changed)


## What the Import dock is editing: the FileSystem selection (folders expanded
## to the imported files under them) plus the resource open in the inspector,
## which the dock also follows. Only assets that have a .import count.
func _import_dock_targets() -> Array:
	var out: Array = []
	var roots: Array = Array(EditorInterface.get_selected_paths())
	var edited: Object = EditorInterface.get_inspector().get_edited_object()
	if edited is Resource and not (edited as Resource).resource_path.is_empty():
		roots.append((edited as Resource).resource_path)
	for p: String in roots:
		if p.ends_with("/"):
			_collect_imported(p, out)
		elif FileAccess.file_exists(ProjectSettings.globalize_path(p + ".import")) and not p in out:
			out.append(p)
	return out


func _collect_imported(dir_path: String, out: Array) -> void:
	if out.size() >= 500:
		return
	var gd := ProjectSettings.globalize_path(dir_path)
	for f in DirAccess.get_files_at(gd):
		if f.ends_with(".import"):
			var asset := dir_path.path_join(f.trim_suffix(".import"))
			if not asset in out:
				out.append(asset)
	for d in DirAccess.get_directories_at(gd):
		if not d.begins_with("."):
			_collect_imported(dir_path.path_join(d) + "/", out)


## After a reimport: .import files whose content didn't change go back to
## read-only, keeping the bytes Godot wrote (it caches the .import md5 right
## after writing, so putting the old bytes back would trigger yet another
## reimport; an LF rewrite of a CRLF file is invisible to `p4 reconcile`).
## Changed ones - an importer upgrade, new import defaults - are checked out.
func _on_resources_reimported(resources: PackedStringArray) -> void:
	var changed := _classify_reimported(resources)
	if not changed.is_empty():
		await _checkout_reimported(changed)


## Returns the global paths of backed-up .import files the reimport really
## changed; unchanged ones are made read-only again. Split out for selftests.
func _classify_reimported(resources: PackedStringArray) -> Array:
	var changed: Array = []
	for res_path in resources:
		var global_path := ProjectSettings.globalize_path(String(res_path) + ".import")
		if not _reimport_backups.has(global_path):
			continue
		var old: PackedByteArray = _reimport_backups[global_path]
		_reimport_backups.erase(global_path)
		var cur := FileAccess.get_file_as_bytes(global_path)
		if cur == old or (not cur.is_empty() and _contents_match(cur, old, "import")):
			_set_file_writable(global_path, false)
		else:
			changed.append(global_path)
	return changed


## Check out .import files a reimport really changed, like a save would. A
## Godot upgrade can change hundreds at once, so big batches ask first.
## Anything not checked out stays writable (as written), so `p4 sync` won't
## overwrite it and Reconcile finds it later.
func _checkout_reimported(global_paths: Array) -> void:
	var sample := ", ".join(global_paths.slice(0, 5).map(
			func(p: String) -> String: return ProjectSettings.localize_path(p)))
	if global_paths.size() > 5:
		sample += ", ..."
	if not checkout_on_save_checkbox.button_pressed or not await _ensure_identity():
		_log("Reimport changed %d .import file(s) that aren't checked out - left writable for Reconcile: %s"
				% [global_paths.size(), sample])
		return
	if global_paths.size() > REIMPORT_CONFIRM_THRESHOLD:
		var ok: bool = await _show_confirm_dialog(("Godot rewrote the settings files for %d " +
				"imported assets (this normally happens after a Godot update, or when import " +
				"settings change).\n\nTell Perforce you changed them? If not, they're left as " +
				"they are, and the \"Reconcile...\" button in the P4G panel can pick them up " +
				"later.") % global_paths.size(), "Check Out", "Not Now")
		if not ok:
			_log("Left %d changed .import file(s) writable and unopened - Reconcile picks them up." % global_paths.size())
			return
	var opened := {}
	for i in range(0, global_paths.size(), 50):
		var chunk: Array = global_paths.slice(i, i + 50)
		await _p4_exec_logged(["edit"] + chunk)
		# p4 edit can exit 0 on a refusal - trust the resulting state instead.
		for rec in _parse_ztag(await _p4_exec(["-ztag", "fstat"] + chunk)):
			if rec.has("action"):
				opened[String(rec.get("clientFile", "")).replace("\\", "/").to_lower()] = true
	var failed: Array = []
	for p: String in global_paths:
		if not opened.has(p.replace("\\", "/").to_lower()):
			failed.append(ProjectSettings.localize_path(p))
	_log("Reimport changed %d .import file(s); checked out %d." % [global_paths.size(),
			global_paths.size() - failed.size()])
	if not failed.is_empty():
		_log("Couldn't check out (left writable for Reconcile): %s" % ", ".join(failed))
	_request_refresh()


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
	if _prewrite_managed.has(res_path):
		# The pre-write pass made this file writable; _finish_prewrite_pass
		# owns its follow-up (restore or checkout). Checked synchronously,
		# while the dict is still populated for this save pass's frame.
		return
	var global_path := ProjectSettings.globalize_path(res_path)
	# Fast path, pure filesystem, BEFORE any p4 round trip: the write failed
	# on a read-only file but would not have changed it (Godot rewrites on
	# every Ctrl+S whether or not anything changed). Nothing was lost, so a
	# checkout offer would be noise - and the editor's own "Unable to write to
	# file" modal (which pops right after this signal handler returns) is pure
	# alarm, so dismiss it too. Running before the awaits means the dismissal
	# is armed by the time that dialog appears.
	if not checkout_was_refused_this_save \
			and FileAccess.open(global_path, FileAccess.READ_WRITE) == null \
			and _failed_write_was_unchanged(global_path):
		_log("Save of '%s' failed (read-only), but its content is unchanged - nothing was lost, no checkout needed." % res_path)
		_queue_error_dialog_dismissal(res_path)
		return
	# Decided now, before any await: the mtime test in _save_landed only holds
	# right after the write, and the p4 queue can take a while.
	var landed := _save_landed(global_path)
	var landed_read_only := landed and FileAccess.open(global_path, FileAccess.READ_WRITE) == null
	if not await _ensure_identity():
		if landed:
			_protect_landed_save(res_path, global_path)
		return
	if _checked_out_this_session.has(res_path):
		if not landed_read_only:
			return
		# Opened files are writable, so the cache is stale (submitted or
		# reverted outside the editor) - re-ask Perforce below.
		_checked_out_this_session.erase(res_path)
	if not await _needs_checkout(global_path):
		if _fstat_failed.has(global_path):
			if landed:
				_protect_landed_save(res_path, global_path)
			return # Unknown, not "no checkout needed": keep any pending retry.
		_remember_no_checkout(res_path, global_path)
		_pending_save_checkout.erase(res_path)
		return

	# Not checked out. Whether the write actually landed tells us which
	# situation we're in: landed = the save went through without a checkout
	# (allwrite client, or macOS/Linux, where read-only doesn't block a save),
	# not landed = the save just failed.
	if landed:
		if checkout_was_refused_this_save:
			# macOS/Linux: saved despite the refusal (already reported). Keep
			# it writable so `p4 sync` refuses to overwrite the edit.
			_set_file_writable(global_path, true)
			return
		var result: Dictionary = await _checkout_if_changed(res_path)
		if result.get("unchanged", false):
			return # Untouched Ctrl+S; the file keeps its mode (writable in allwrite).
		if result.ok:
			_log("'%s' was saved while not checked out - checked it out to keep the changelist accurate." % res_path)
		else:
			_set_file_writable(global_path, true)
			_show_alert(("Godot saved '%s', but Perforce wouldn't record the change - %s.\n\n" +
					"Your work is safe on your computer, but Perforce doesn't know about " +
					"it, so it won't reach your team. Once whoever is using the file lets " +
					"go of it, right-click the file in the FileSystem dock and choose " +
					"'P4 > Check Out' - or press \"Reconcile...\" in the P4G panel - so the " +
					"change joins your list of pending changes.") % [res_path, result.reason])
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
	# Filesystem sweep first, BEFORE the p4 identity await: a dependency whose
	# failed write was a no-op (fresh failed-write temp matching the disk
	# file) joins the error-dialog dismissal batch immediately, so the
	# dismissal loop's first scan already covers the scene AND its
	# dependencies - it never stalls on a p4 round trip. Real failures are
	# collected for the p4-gated handling below.
	var failed: Array = []
	var landed: Array = [] # macOS/Linux: written despite being read-only
	var written: Array = _resource_deps_deep(scene_path)
	# Loaded shaders (e.g. open in the shader editor) are written on scene save too.
	for sp: String in _shader_files():
		if ResourceLoader.has_cached(sp):
			written.append(sp)
	for dep_path: String in written:
		if _checked_out_this_session.has(dep_path) or _rescue_paths.has(dep_path):
			continue
		if Time.get_ticks_msec() - int(_prewrite_settled.get(dep_path, -100000)) < 10000:
			continue # The pre-write pass just handled this save of it.
		var global_path := ProjectSettings.globalize_path(dep_path)
		if OS.get_name() != "Windows":
			# No failed write here - the rename lands on read-only files. A
			# read-only dependency with a fresh mtime was just written while not
			# checked out.
			if FileAccess.open(global_path, FileAccess.READ_WRITE) == null \
					and _save_landed(global_path):
				landed.append(dep_path)
			continue
		if _fresh_failed_write_tmp(global_path).is_empty():
			continue
		if _failed_write_was_unchanged(global_path):
			_log("Resource '%s' failed to write (read-only), but its content is unchanged - no checkout needed." % dep_path)
			_queue_error_dialog_dismissal(dep_path)
			continue
		failed.append({"dep_path": dep_path, "global_path": global_path})
	if failed.is_empty() and landed.is_empty():
		return
	if not await _ensure_identity():
		for dep_path: String in landed:
			_protect_landed_save(dep_path, ProjectSettings.globalize_path(dep_path))
		return
	for dep_path: String in landed:
		var result: Dictionary = await _checkout_if_changed(dep_path)
		if result.get("unchanged", false):
			continue
		if result.ok:
			_log("Saving '%s' also wrote '%s' - checked it out to keep the changelist accurate." % [scene_path, dep_path])
		else:
			_set_file_writable(ProjectSettings.globalize_path(dep_path), true)
			_log("Saving '%s' also wrote '%s', which couldn't be checked out (%s) - left writable so a sync can't overwrite it." % [scene_path, dep_path, result.reason])
	for entry: Dictionary in failed:
		var dep_path := String(entry.dep_path)
		if not await _needs_checkout(String(entry.global_path)):
			_remember_no_checkout(dep_path, String(entry.global_path))
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
## Returns the newest such temp's path, or "" if none. The temp holds the
## COMPLETE content the editor tried to write (the write finished; only the
## rename over the read-only target failed), which is what lets
## _failed_write_was_unchanged() below compare it against the disk file.
func _fresh_failed_write_tmp(global_path: String, max_age_sec: float = 10.0) -> String:
	var dir := DirAccess.open(global_path.get_base_dir())
	if dir == null:
		return ""
	var fname := global_path.get_file()
	var now := Time.get_unix_time_from_system()
	var best := ""
	var best_mtime := 0
	for f in dir.get_files():
		if not (f.begins_with(fname) and f.ends_with(".tmp")):
			continue
		var middle := f.substr(fname.length(), f.length() - fname.length() - 4)
		if not middle.is_valid_int():
			continue
		var tmp_path := global_path.get_base_dir().path_join(f)
		var mtime := FileAccess.get_modified_time(tmp_path)
		if now - mtime < max_age_sec and mtime >= best_mtime:
			best = tmp_path
			best_mtime = mtime
	return best


## True when the save that just failed would not have changed the file: the
## abandoned safe-save temp's content matches what is already on disk. Godot
## rewrites scenes on every Ctrl+S regardless of whether anything changed, so
## without this check an untouched read-only scene produces a checkout offer
## that would open a file with zero real edits. Text resources compare with
## CR stripped (the depot copy may be CRLF while the editor writes LF). A
## confirmed-identical temp is deleted - it is litter Godot never cleans up,
## and it would otherwise show up in Reconcile as a file to add.
func _failed_write_was_unchanged(global_path: String) -> bool:
	var tmp_path := _fresh_failed_write_tmp(global_path)
	if tmp_path.is_empty():
		return false
	var tmp_bytes := FileAccess.get_file_as_bytes(tmp_path)
	var cur_bytes := FileAccess.get_file_as_bytes(global_path)
	if tmp_bytes.is_empty() or cur_bytes.is_empty():
		return false # Unreadable (or genuinely empty) - don't guess; prompt.
	var unchanged := _contents_match(tmp_bytes, cur_bytes, global_path.get_extension().to_lower())
	if unchanged:
		DirAccess.remove_absolute(tmp_path)
	return unchanged


## Byte equality, with a CR-stripped fallback for known-text resource types
## (the synced copy may be CRLF while the editor writes LF). Never
## text-tolerant for binary formats: a lossy UTF-8 decode could mask a real
## change.
func _contents_match(a: PackedByteArray, b: PackedByteArray, ext: String) -> bool:
	if a == b:
		return true
	var text_exts: PackedStringArray = ["tscn", "tres", "gd", "gdshader", "gdshaderinc", "cfg",
			"godot", "import", "json", "txt", "shader"]
	if not ext in text_exts:
		return false
	var a_text := a.get_string_from_utf8().replace("\r\n", "\n")
	var b_text := b.get_string_from_utf8().replace("\r\n", "\n")
	return not a_text.is_empty() and a_text == b_text


## A failed scene write also pops the editor's own error UI, and the plugin
## gets no hook to prevent it. When the failed save carried no changes that
## error is pure alarm (nothing was lost, nothing needs doing), so find it
## and hide it. The editor surfaces failed writes two ways: a bare
## AcceptDialog message (show_accept), and the "Load Errors" dialog, whose
## lines live in a RichTextLabel child while dialog_text stays empty
## (verified live 2026-08-21 - failed saves use THIS one, listing every
## failed file of the pass). Matching therefore reads both, and the window
## is hidden ONLY when every error line in it names a verified no-op file: a
## dialog also reporting a REAL failure stays up. Our own dialogs are all
## ConfirmationDialogs, so the exact-class filter can never hide them.
##
## All no-op failures of one save pass share one batch: this registrar is
## synchronous (callable from the probes with no p4 round trip, so the scene
## and its dependencies are all registered before the deferred loop's first
## scan), and one hide covers the whole pass. If no dialog ever matches
## (future editor rewording/restructuring), an explanatory notice appears
## instead - unless a rescue dialog for a real failure in the same pass is
## on its way, which explains the situation better than a second popup.
func _queue_error_dialog_dismissal(res_path: String) -> void:
	if not _error_dismiss_names.has(res_path):
		_error_dismiss_names.append(res_path)
	if _error_dismiss_running:
		return
	_error_dismiss_running = true
	call_deferred("_run_error_dialog_dismissal")


func _run_error_dialog_dismissal() -> void:
	var found := false
	for i in range(90):
		if _shutting_down:
			_error_dismiss_running = false
			return
		# Scan from the tree root, not base_control: the "Load Errors" dialog
		# is NOT parented under the editor's base control (verified live
		# 2026-08-21 - a base_control scan never found it).
		var scan_root: Node = get_tree().root
		if scan_root == null:
			_error_dismiss_running = false
			return
		for d in scan_root.find_children("*", "AcceptDialog", true, false):
			if d.get_class() != "AcceptDialog":
				continue
			var dlg: AcceptDialog = d
			if not dlg.visible:
				continue
			if _all_error_lines_covered(_accept_dialog_full_text(dlg)):
				dlg.hide()
				found = true
				break
		if found:
			break
		await get_tree().process_frame
	var names := _error_dismiss_names.duplicate()
	_error_dismiss_names.clear()
	_error_dismiss_running = false
	if found:
		return
	if _rescue_scheduled or not _rescue_paths.is_empty() or _dialog_busy:
		_log("No changes in %s; the error dialog also reports a real failure, leaving it up." % ", ".join(PackedStringArray(names)))
		return
	var msg: String
	if names.size() == 1:
		msg = ("'%s' has no changes to save - the file on disk already matches " +
				"what the editor tried to write. Nothing was lost and no checkout " +
				"is needed; the editor's \"Unable to write to file\" message can " +
				"be ignored.") % names[0]
	else:
		msg = ("These files have no changes to save - what the editor tried to " +
				"write already matches what's on disk:\n\n%s\n\nNothing was lost " +
				"and no checkout is needed; the editor's \"Unable to write to " +
				"file\" message can be ignored.") % _file_listing(names)
	await _show_alert(msg)


## The two shapes of the editor's failed-write error UI (see above): a
## message in dialog_text, or lines in a RichTextLabel child. Collect both.
func _accept_dialog_full_text(dlg: AcceptDialog) -> String:
	var text := dlg.dialog_text
	for rtl in dlg.find_children("*", "RichTextLabel", true, false):
		text += "\n" + (rtl as RichTextLabel).get_parsed_text()
	return text


## Does this error line name `res_path`? The editor writes the path in
## several shapes depending on which dialog it is, so accept any of them -
## but a bare file name only counts on a name boundary. Matching it anywhere
## in the line would let a registered `level.tscn` dismiss a REAL failure
## reported for `sublevel.tscn`.
func _line_names_file(line: String, res_path: String) -> bool:
	if line.contains(res_path):
		return true
	var global_path := ProjectSettings.globalize_path(res_path)
	if line.contains(global_path) or line.contains(global_path.replace("/", "\\")):
		return true
	var base := res_path.get_file()
	var from := 0
	while true:
		var at := line.find(base, from)
		if at == -1:
			return false
		var before := "" if at == 0 else line[at - 1]
		var end := at + base.length()
		var after := "" if end >= line.length() else line[end]
		if _is_name_boundary(before) and _is_name_boundary(after):
			return true
		from = at + 1
	return false


## Is this character something a file name can't run through? An empty string
## means the start or end of the line, which always counts. "." counts too,
## so a trailing sentence period doesn't hide a match.
static func _is_name_boundary(c: String) -> bool:
	if c.is_empty():
		return true
	var code := c.unicode_at(0)
	var alphanumeric: bool = (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122)
	return not (alphanumeric or c == "_" or c == "-")


## True when the text has at least one non-empty line and EVERY non-empty
## line names a file registered as a verified no-op. The per-line rule is
## what keeps a mixed dialog (a no-op's line plus a real failure's line)
## visible.
func _all_error_lines_covered(text: String) -> bool:
	var any := false
	for raw_line in text.split("\n"):
		# Inline images (the red error dots) surface as U+FFFC in parsed text.
		var line := raw_line.replace(char(0xFFFC), "").strip_edges()
		if line.is_empty():
			continue
		var covered := false
		for dismiss_name in _error_dismiss_names:
			if _line_names_file(line, String(dismiss_name)):
				covered = true
				break
		if not covered:
			return false
		any = true
	return any


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
		message = ("Godot couldn't save '%s'.\n\nPerforce keeps files locked until you " +
				"tell it you're editing them, and you haven't yet for this one. Tell " +
				"Perforce now and save again?") % paths[0]
		ok_text = "Check Out and Save"
	else:
		var lines: Array = []
		for p in paths:
			lines.append("- '%s'" % p)
		message = ("Godot couldn't save these files:\n\n%s\n\nPerforce keeps files " +
				"locked until you tell it you're editing them, and you haven't yet " +
				"for these. Tell Perforce now and save them again?") % "\n".join(lines)
		ok_text = "Check Out All and Save"

	var choices: Array = await _pending_changelist_choices()
	# "Leave Unsaved" rather than "Not Now": declining means the work stays on
	# screen and not on disk, and nothing asks again.
	var picked: Dictionary = await _show_checkout_target_dialog(message, ok_text,
			"Leave Unsaved", choices)
	if not picked.ok:
		_log("File(s) remain unsaved. Check them out (FileSystem dock 'P4 > Check Out', or `p4 edit`) when you're ready.")
		return

	var succeeded: Array = []
	var failed_paths: Array = []
	var failures: Array = []
	for res_path: String in paths:
		var result: Dictionary = await _do_checkout(res_path, picked.change)
		if result.ok:
			succeeded.append(res_path)
		else:
			failed_paths.append(res_path)
			failures.append("- '%s': %s" % [res_path, result.reason])
	if not failures.is_empty():
		await _show_alert(("Perforce wouldn't let you edit these files:\n\n%s\n\n" +
				"They stay unsaved until whoever is using them finishes - ask them to " +
				"send their work to the server or set it aside. Your changes are still " +
				"in the editor; save again once the files are free.")
				% "\n".join(failures))
	if succeeded.is_empty():
		return

	# Re-save. Mark the still-refused files first so their (inevitably failing)
	# writes during this retry don't queue yet another rescue dialog.
	for res_path: String in failed_paths:
		_rescue_skip_frame[res_path] = Engine.get_process_frames()
	_log("Checked out %s - saving again..." % ", ".join(succeeded))
	# The failed attempt's safe-save temp is litter now (Reconcile would offer
	# to add it); the retry writes the real file.
	for res_path: String in succeeded:
		# 15 min: the user may have taken a while to answer the rescue dialog.
		var stale_tmp := _fresh_failed_write_tmp(ProjectSettings.globalize_path(res_path), 900.0)
		if not stale_tmp.is_empty():
			DirAccess.remove_absolute(stale_tmp)

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
	var scene_root := EditorInterface.get_edited_scene_root()
	if scenes.size() == 1 and scene_root \
			and scene_root.get_scene_file_path() == scenes[0]:
		EditorInterface.save_scene()
	else:
		# Multiple scenes, or the rescued scene isn't the active tab - re-run
		# Save All; already-saved scenes are cheap no-ops the second time.
		EditorInterface.save_all_scenes()


## Success-only (the engine emits no signal for a failed resource write).
## Catches scripts/resources saved without a checkout in an allwrite client.
func _on_resource_saved(res: Resource) -> void:
	if res == null:
		return
	var res_path := res.resource_path
	if res_path.is_empty() or not res_path.begins_with("res://"):
		return
	if _prewrite_managed.has(res_path):
		return # The pre-write pass owns this file's restore-or-checkout decision.
	var global_path := ProjectSettings.globalize_path(res_path)
	# resource_saved only fires for writes that landed. Read-only afterwards
	# (possible only on macOS/Linux) means NOT opened, whatever the cache says.
	var landed_read_only := FileAccess.open(global_path, FileAccess.READ_WRITE) == null
	if _checked_out_this_session.has(res_path):
		if not landed_read_only:
			return
		_checked_out_this_session.erase(res_path) # stale: submitted/reverted elsewhere
	if _rescue_skip_frame.get(res_path, -1) == Engine.get_process_frames():
		# The pre-save checkout was just refused and reported. Keep the file
		# writable so `p4 sync` won't overwrite the edit.
		_set_file_writable(global_path, true)
		return
	if not await _ensure_identity():
		_protect_landed_save(res_path, global_path)
		return
	if _checked_out_this_session.has(res_path):
		return # Re-check: a save-time checkout may have resolved during the await.
	if not await _needs_checkout(global_path):
		if _fstat_failed.has(global_path):
			_protect_landed_save(res_path, global_path)
			return # Unknown, not "no checkout needed": keep any pending retry.
		_remember_no_checkout(res_path, global_path)
		_pending_save_checkout.erase(res_path)
		return
	var result: Dictionary = await _checkout_if_changed(res_path)
	if result.get("unchanged", false):
		return # Untouched Ctrl+S; the file keeps its mode (writable in allwrite).
	if result.ok:
		_log("'%s' was saved while not checked out - checked it out to keep the changelist accurate." % res_path)
	else:
		_set_file_writable(global_path, true)
		_show_alert(("Godot saved '%s', but Perforce wouldn't record the change - %s.\n\n" +
				"Your work is safe on your computer, but Perforce doesn't know about it, " +
				"so it won't reach your team. Once whoever is using the file lets go of " +
				"it, right-click the file in the FileSystem dock and choose 'P4 > Check " +
				"Out' - or press \"Reconcile...\" in the P4G panel - so the change joins " +
				"your list of pending changes.") % [res_path, result.reason])


# ---------------------------------------------------------------------------
# Workspace operations: Reconcile and Revert Unchanged (scoped to res://)
# ---------------------------------------------------------------------------


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
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var result: Dictionary = await _p4_exec(["-ztag", "reconcile", "-n", _project_scope()])
	var found := _summarize_reconcile(_parse_ztag(result))
	var refused := _refusals(result)
	if found.names.is_empty():
		if int(refused.count) > 0:
			await _show_alert(_refusal_alert_text(refused))
		else:
			await _show_alert("Nothing to tell Perforce about - every file in this project already matches what Perforce has.")
		return
	if not await _confirm_reconcile(found, refused, "Reconcile", "Cancel"):
		_log("Reconcile cancelled.")
		return
	await _reconcile_paths(found.locals, found.names)


## Fold a reconcile preview into the shape both callers need: the paths to
## hand back to p4, the names to show, and a count per action. Sorted by name
## as one list, so the paths and the names can't drift out of step.
func _summarize_reconcile(preview: Array) -> Dictionary:
	var rows: Array = []
	var adds := 0
	var edits := 0
	var deletes := 0
	for rec in preview:
		# reconcile's clientFile is the raw local path (only depotFile comes
		# back escaped), which is what a reconcile argument wants.
		var local := String(rec.get("clientFile", ""))
		if local.is_empty() or _is_godot_save_leftover(local):
			continue
		var res := _local_to_res(local)
		var action := String(rec.get("action", ""))
		if action.contains("delete"):
			deletes += 1
		elif action.contains("add"):
			adds += 1
		else:
			edits += 1
		rows.append({"local": local, "name": res if not res.is_empty() else local, "action": action})
	rows.sort_custom(func(a, b): return String(a.name) < String(b.name))
	var locals: Array = []
	var names: Array = []
	for row in rows:
		locals.append(row.local)
		names.append(row.name)
	return {"locals": locals, "names": names, "adds": adds, "edits": edits, "deletes": deletes}


## The confirmation for opening a set of reconciled files. It names them and
## breaks them down by action, because "delete" is the one a user must not
## agree to by accident: an incomplete sync makes depot files look missing,
## and opening those for delete removes them from the depot on the next
## submit.
func _confirm_reconcile(found: Dictionary, refused: Dictionary, ok_text: String,
		cancel_text: String) -> bool:
	var note := ""
	if int(found.deletes) > 0:
		note += ("\n\nCAREFUL: %d of these are missing from your project folder, so " +
				"Perforce will be told to delete them for the whole team the next time " +
				"you submit. If you expected them to still be there, stop here - you " +
				"may simply not have downloaded everything yet.") % found.deletes
	var cache_files: int = _count_godot_cache_paths(found.names)
	if cache_files > 0:
		# .godot/ is Godot's per-machine cache and editor state, and P4Godot
		# keeps this project's server, user and workspace choice in there too.
		# Submitting it hands your connection settings to your teammates and
		# starts a stream of conflicts on files that are rebuilt locally
		# anyway.
		note += ("\n\n%d of these are inside `.godot/`. That folder is Godot's own " +
				"scratch space: every machine rebuilds it, and it holds your personal " +
				"editor settings, so it shouldn't go to the server. Add a line reading " +
				"`.godot/` to the .p4ignore file in this project, then press " +
				"\"Reconcile...\" again.") % cache_files
	if int(refused.count) > 0:
		note += "\n\nPerforce won't open %d other file(s):\n\n%s" \
				% [refused.count, _file_listing(refused.lines)]
	return await _show_confirm_dialog(
			("Perforce doesn't know about %d file(s) yet:\n%d new, %d changed, %d " +
			"missing.\n\n%s\n\nTell Perforce about them? This only records what you " +
			"already did - none of your files are changed, moved or deleted.%s")
			% [found.names.size(), found.adds, found.edits, found.deletes,
			_file_listing(found.names), note],
			ok_text, cancel_text)


## How many of these paths live in Godot's local cache folder? Matches the
## res:// form and either slash, since the list can hold raw local paths for
## files that don't map into the project.
static func _count_godot_cache_paths(names: Array) -> int:
	var n := 0
	for name_any in names:
		var text := String(name_any)
		if text.begins_with("res://.godot/") or text.contains("/.godot/") \
				or text.contains("\\.godot\\"):
			n += 1
	return n


# ---------------------------------------------------------------------------
# Detecting changes made outside Godot
#
# Textures, models and audio get edited in Photoshop, Blender and Audition -
# tools that know nothing about Perforce. Those files land in the workspace
# already changed, and in a read-only workspace the other tool couldn't even
# write them without someone checking them out first. Nothing inside Godot
# fires for that, so the plugin looks for itself: when Godot comes back to the
# front, and when Godot's own filesystem scan reports changes, run the same
# non-mutating `reconcile -n` preview the Reconcile button uses and offer to
# open whatever it found.
#
# The scan runs on the worker thread like every other p4 command. It is
# single-flighted and throttled, because focus-in and filesystem_changed
# normally arrive within a frame of each other.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Is the plugin itself in Perforce?
#
# Godot records the enabled plugins in project.godot, which a team keeps in
# Perforce - but the plugin's own files only get there if somebody adds them.
# When they haven't, a teammate who syncs the project gets:
#
#     WARNING: Addon 'res://addons/p4godot/plugin.cfg' failed to load.
#              No directory found. Removing from enabled plugins.
#
# (verified on Godot 4.7). Godot drops it from the in-memory enabled list, so
# the next thing that saves project settings writes that pruned list back -
# and project.godot is usually `+w`, so the write needs no checkout and makes
# no noise. Submitting it turns P4Godot off for everyone. Worth one prompt.
# ---------------------------------------------------------------------------

## This plugin's own folder as a res:// path, read from the running script so
## it stays right if someone renames or relocates the addon.
func _plugin_dir() -> String:
	var script := get_script() as Script
	if script == null or script.resource_path.is_empty():
		return "res://addons/p4godot"
	return script.resource_path.get_base_dir()


## Is this local path in the depot, or at least on its way in? A path p4 has
## never heard of answers with a bare "no such file(s)" message, which yields
## no tagged record at all.
func _is_in_depot(global_path: String) -> bool:
	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", global_path]))
	if recs.is_empty():
		return false
	var rec: Dictionary = recs[0]
	if String(rec.get("depotFile", "")).is_empty():
		return false
	if not String(rec.get("action", "")).is_empty():
		return true # already opened for add/edit - it's on its way in
	return String(rec.get("headAction", "")) != "delete"


## Does P4IGNORE cover this path? `-i` alone prints the path only when a rule
## matches and stays silent otherwise, which is indistinguishable from the
## command failing. `-v` makes it say which it is - "<path> ignored by
## <file>:<line>:<rule>" or "<path> not ignored" - and the negative contains
## the positive, so test for that first.
func _p4_path_ignored(global_path: String) -> bool:
	var result: Dictionary = await _p4_exec(["ignores", "-i", "-v", global_path])
	var text := "" if result.output.is_empty() else String(result.output[0])
	if text.contains("not ignored"):
		return false
	return text.contains("ignored")


## The file names Perforce reads ignore rules from on this computer, from
## `p4 set -q P4IGNORE`'s answer ("P4IGNORE=<names>", or nothing when unset).
## Unset means ".p4ignore". Setting it to anything else REPLACES that default
## (measured), so a project's .p4ignore can be silently out of force.
func _ignore_file_names(set_output: String, windows: bool) -> PackedStringArray:
	var value := ""
	for raw in set_output.split("\n"):
		var line := String(raw).strip_edges()
		if line.begins_with("P4IGNORE="):
			value = line.substr("P4IGNORE=".length())
			# "p4 set" without -q appends " (set)", " (config 'x')" and so on.
			var note := value.rfind(" (")
			if note >= 0 and value.ends_with(")"):
				value = value.substr(0, note)
	var names := PackedStringArray()
	# ":" separates names too, except on Windows where it follows a drive letter.
	var parts := value.split(";", false)
	if not windows:
		var split_more := PackedStringArray()
		for part in parts:
			split_more.append_array(part.split(":", false))
		parts = split_more
	for part in parts:
		if not part.strip_edges().is_empty():
			names.append(part.strip_edges())
	if names.is_empty():
		names.append(".p4ignore")
	return names


## Whether `p4 -ztag where <path>` says the path is part of this workspace: a
## record with a depot path and no `unmap` marker. A path left out by the
## view or the stream, or outside the workspace, has none; neither has a
## command that failed.
func _where_maps(result: Dictionary) -> bool:
	if int(result.get("exit_code", 1)) != 0:
		return false
	for rec in _parse_ztag(result):
		if not String(rec.get("depotFile", "")).is_empty() and not rec.has("unmap"):
			return true
	return false


## Once per start: make sure Perforce skips Godot's `.godot` folder, and offer
## to add the rule when it doesn't. That folder is thousands of files rebuilt
## on every machine, plus the user's own editor state; without a rule,
## Reconcile offers all of it for the server. Returns what happened, for the
## self-test: "skipped", "ignored", "declined", "added" or "failed".
func _check_godot_cache_ignored(forced: bool = false) -> String:
	if _shutting_down or (_selftest_mode and not forced):
		return "skipped"
	var settings := EditorInterface.get_editor_settings()
	if not forced and settings.get_project_metadata(SETTINGS_SECTION, "godot_cache_ignore_declined", false):
		return "skipped"
	if not await _ensure_identity():
		return "skipped"
	var probe := ProjectSettings.globalize_path("res://.godot/editor/p4godot_ignore_probe")
	if await _p4_path_ignored(probe):
		return "ignored"
	# `p4 ignores` only reads ignore files on this computer. A stream or a
	# workspace view can leave the folder out too, and then there is nothing
	# to fix: ask the server whether the path maps to the depot at all.
	if not _where_maps(await _p4_exec(["-ztag", "where", probe], false)):
		return "ignored"
	var set_result: Dictionary = await _p4_exec(["set", "-q", "P4IGNORE"])
	var names := _ignore_file_names(
			"" if set_result.output.is_empty() else String(set_result.output[0]),
			OS.get_name() == "Windows")
	# The rule goes into an ignore file this project already has, if any.
	var name := names[0]
	for candidate in names:
		if not candidate.contains("/") and not candidate.contains("\\") \
				and FileAccess.file_exists(ProjectSettings.globalize_path("res://" + candidate)):
			name = candidate
			break
	if name.is_absolute_path() or name.contains("/") or name.contains("\\"):
		# One shared file somewhere else on this computer; not ours to edit.
		await _show_alert(("Perforce isn't set to skip Godot's `.godot` folder in this project. " +
				"That folder is Godot's own scratch space - every computer rebuilds it - and " +
				"it shouldn't go to the server.\n\nThis computer reads its ignore rules from " +
				"'%s'. Add a line reading `.godot/` to that file.") % name)
		return "failed"
	var res := "res://" + name
	var global_path := ProjectSettings.globalize_path(res)
	var question := ("Perforce isn't set to skip Godot's `.godot` folder in this project.\n\n" +
			"That folder is Godot's own scratch space: every computer rebuilds it, and it " +
			"holds your personal editor settings. Without a rule, Reconcile offers its " +
			"thousands of files for the server.\n\nAdd the line `.godot/` to '%s' now? " +
			"Submit that file afterwards so your team gets the rule too.") % name
	if not ".p4ignore" in names and FileAccess.file_exists(ProjectSettings.globalize_path("res://.p4ignore")):
		question += ("\n\nThis project has a .p4ignore file, but this computer is set to read " +
				"ignore rules from '%s' instead (the P4IGNORE setting), so the rules in " +
				".p4ignore aren't applied here.") % name
	if not await _show_confirm_dialog(question, "Add the Rule", "Not Now"):
		if not forced:
			settings.set_project_metadata(SETTINGS_SECTION, "godot_cache_ignore_declined", true)
		_log("Left `.godot/` without an ignore rule. Add `.godot/` to '%s' to keep it off the server." % name)
		return "declined"
	var existing := ""
	var existed := FileAccess.file_exists(global_path)
	if existed:
		existing = FileAccess.get_file_as_string(global_path)
		if await _needs_checkout(global_path):
			var checkout: Dictionary = await _do_checkout(res)
			if not checkout.ok:
				await _show_alert(("Godot couldn't check out '%s' to add the rule:\n\n%s\n\n" +
						"Add a line reading `.godot/` to it yourself.") % [name, checkout.reason])
				return "failed"
	if not existing.is_empty() and not existing.ends_with("\n"):
		existing += "\n"
	var out := FileAccess.open(global_path, FileAccess.WRITE)
	if out == null:
		await _show_alert(("Godot couldn't write '%s'. Add a line reading `.godot/` to it " +
				"yourself.") % name)
		return "failed"
	out.store_string(existing + ("" if existed else "# Godot's per-computer cache and editor state\n") + ".godot/\n")
	out.close()
	if not existed:
		await _add_path(res, false)
	_request_refresh()
	if not await _p4_path_ignored(probe):
		await _show_alert(("Godot added `.godot/` to '%s', but Perforce still doesn't skip that " +
				"folder. Press \"Log\" in the P4G panel to see what it said.") % name)
		return "failed"
	_log("Added `.godot/` to '%s'. Submit that file so your team gets the rule." % name)
	return "added"


func _check_plugin_tracked() -> void:
	if _shutting_down or _selftest_mode:
		return
	var settings := EditorInterface.get_editor_settings()
	if settings.get_project_metadata(SETTINGS_SECTION, "plugin_add_declined", false):
		return
	if not await _ensure_identity():
		return
	# Nothing to warn about until the project itself is in Perforce: an
	# un-added project picks the plugin up with everything else on its first
	# Reconcile, and warning there would just be noise.
	if not await _is_in_depot(ProjectSettings.globalize_path("res://project.godot")):
		return
	var plugin_res := _plugin_dir()
	var plugin_dir := ProjectSettings.globalize_path(plugin_res)
	if await _is_in_depot(plugin_dir.path_join("plugin.cfg")):
		return

	var consequence := ("Godot keeps the list of enabled plugins in project.godot, and that " +
			"file IS in Perforce. Teammates who don't have P4Godot's own files get " +
			"\"Addon failed to load\" and Godot switches it off for them - which can then " +
			"be sent back to the server, switching it off for everyone.")

	if await _p4_path_ignored(plugin_dir):
		settings.set_project_metadata(SETTINGS_SECTION, "plugin_add_declined", true)
		await _show_alert(("'%s' isn't in Perforce, and your project's .p4ignore file tells " +
				"Perforce to skip it, so Reconcile can't add it.\n\n%s\n\nEither edit " +
				".p4ignore so it no longer covers this folder and press \"Reconcile...\" " +
				"again, or ask everyone on the team to install P4Godot themselves.")
				% [plugin_res, consequence])
		return

	var proceed: bool = await _show_confirm_dialog(
			("P4Godot itself isn't in Perforce.\n\n%s\n\nAdd '%s' to Perforce now?")
					% [consequence, plugin_res],
			"Add to Perforce", "Not Now")
	if not proceed:
		settings.set_project_metadata(SETTINGS_SECTION, "plugin_add_declined", true)
		_log("Left P4Godot out of Perforce; the dock's Reconcile can add it later.")
		return

	var result: Dictionary = await _p4_exec_logged(["reconcile", _as_recursive(plugin_dir)])
	var refused := _refusals(result)
	_request_refresh()
	if int(refused.count) > 0:
		await _show_alert(_refusal_alert_text(refused))
		return
	if not await _is_in_depot(plugin_dir.path_join("plugin.cfg")):
		await _show_alert(("Perforce wouldn't add '%s'.\n\nPress \"Log\" in the P4G panel " +
				"to see exactly what it said. If the reason isn't obvious, ask whoever " +
				"runs your Perforce server.") % plugin_res)
		return
	await _show_alert(("P4Godot is now lined up to be added to Perforce. Send it to the " +
			"server with Submit, together with project.godot, so your team gets the " +
			"plugin the next time they download the project."))


## Open exactly the files that were listed, naming each one on the command
## line rather than re-running reconcile over the whole project: a second
## whole-project pass would also open anything that changed while the dialog
## was up, which the user never saw and never agreed to. Long lists go out in
## batches so the command line can't overflow. Returns the refusals.
func _reconcile_paths(locals: Array, names: Array) -> Dictionary:
	const BATCH := 50
	var refused := {"count": 0, "lines": [], "locked": false}
	var start := 0
	while start < locals.size():
		var args: PackedStringArray = ["reconcile"]
		for local in locals.slice(start, start + BATCH):
			args.append(String(local))
		var batch_refused := _refusals(await _p4_exec_logged(args))
		refused.count = int(refused.count) + int(batch_refused.count)
		refused.lines.append_array(batch_refused.lines)
		refused.locked = bool(refused.locked) or bool(batch_refused.locked)
		start += BATCH
	_request_refresh()
	if int(refused.count) == 0:
		return refused
	_log("Perforce refused %d of the %d file(s)." % [refused.count, names.size()])
	await _show_alert(_refusal_alert_text(refused))
	return refused


func _on_revert_unchanged_pressed() -> void:
	await _revert_unchanged_flow()


func _revert_unchanged_flow() -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var preview := await _revert_unchanged_preview()
	if preview.is_empty():
		await _show_alert("Nothing to give back - every file you have checked out in this project has real changes in it.")
		return

	# A file "unchanged" on disk can still have UNSAVED edits held only in an open
	# editor tab (the checkout-on-edit prompt fires before you save). Reverting it
	# would silently drop the checkout out from under those pending changes. So
	# skip any file currently open in the editor - the only files that can carry
	# in-memory edits - and revert just the rest. (Open-but-unmodified files are
	# skipped too; revert those individually via the tree if you want.)
	var open_files := _open_editor_files()
	var to_revert: Array = []
	var revert_names: Array = []
	var skipped: Array = []
	for rec in preview:
		var local := String(rec.get("clientFile", ""))
		var res := _local_to_res(local)
		if not res.is_empty() and open_files.has(res):
			skipped.append(res)
		else:
			to_revert.append(rec)
			revert_names.append(res if not res.is_empty() else local)

	if to_revert.is_empty():
		await _show_alert(("All %d of the files you have checked out are unchanged, but every " +
				"one is also open in a Godot tab, so nothing was given back - they may still " +
				"hold edits you haven't saved:\n\n%s\n\nClose a file's tab first, or " +
				"right-click it in the P4G panel and revert it there, if you really mean to " +
				"give up the checkout.")
				% [skipped.size(), _file_listing(skipped)])
		return

	var note := ""
	if not skipped.is_empty():
		note = ("\n\nSkipped (open in the editor, protecting unsaved changes):\n%s"
				% _file_listing(skipped))
	var proceed: bool = await _show_confirm_dialog(
			("%d open file(s) have no actual changes:\n\n%s\n\nRevert them? This closes them in " +
			"Perforce (they leave your changelist); your on-disk files are untouched.%s")
			% [to_revert.size(), _file_listing(revert_names), note],
			"Revert Unchanged", "Cancel")
	if not proceed:
		_log("Revert Unchanged cancelled.")
		return

	# Revert only the specific non-open files (`revert -a <file>...`), not the
	# whole scope, so the skipped open files keep their checkout.
	var revert_args: PackedStringArray = ["revert", "-a"]
	for rec in to_revert:
		revert_args.append(String(rec.get("clientFile", "")))
	await _p4_exec_logged(revert_args)
	# Reverted files are no longer opened - drop them from the caches so a later
	# edit re-prompts.
	for rec in to_revert:
		var res := _local_to_res(String(rec.get("clientFile", "")))
		if not res.is_empty():
			_checked_out_this_session.erase(res)
			_pending_save_checkout.erase(res)
	_request_refresh()


## res:// paths of every file currently open in the editor (open scenes, open
## scripts, and the inspector-edited resource) - i.e. the files that could hold
## unsaved in-memory changes. Used to keep Revert Unchanged from reverting a file
## whose edits haven't been written to disk yet.
func _open_editor_files() -> Dictionary:
	var open: Dictionary = {}
	for scene_path in EditorInterface.get_open_scenes():
		open[String(scene_path)] = true
	for scr in EditorInterface.get_script_editor().get_open_scripts():
		if scr and not scr.resource_path.is_empty():
			open[scr.resource_path] = true
	var edited := EditorInterface.get_inspector().get_edited_object()
	if edited is Resource and not edited.resource_path.is_empty():
		open[edited.resource_path] = true
	return open


## The res:// paths open in the editor with changes that aren't saved:
## Godot's own lists (scenes; scripts and text files in the script editor),
## plus edits P4Godot holds for a checkout at save time, in case a tab's state
## isn't in Godot's lists. A reload or a combine would lose these.
## `open`: the open files, if the caller has them (_open_editor_files).
func _unsaved_editor_files(open: Dictionary = {}) -> Dictionary:
	var out := {}
	for path in EditorInterface.get_unsaved_scenes():
		out[ProjectSettings.localize_path(String(path))] = true
	for path in EditorInterface.get_script_editor().get_unsaved_files():
		out[ProjectSettings.localize_path(String(path))] = true
	if open.is_empty():
		open = _open_editor_files()
	for res: String in _pending_save_checkout.keys() + _declined_this_session.keys():
		if open.has(res):
			out[res] = true
	return out


# ---------------------------------------------------------------------------
# Reloading files from disk
# ---------------------------------------------------------------------------

## Reloads res_path from disk, discarding any in-editor unsaved changes.
## Returns true when the editor's copy of the file demonstrably matches disk
## again - callers use that to decide whether they still have to suppress
## checkout prompts for the file. A file outside the project (a local path)
## is never loaded in the editor, so there is nothing to reload.
func _reload_path(res_path: String) -> bool:
	if not res_path.begins_with("res://"):
		return true
	# reload_scene_from_path() internally calls EditorUndoRedoManager.
	# clear_history(), which emits history_changed - suppress our own handler
	# so the reload can't re-trigger the prompt it was just declining. Cleared
	# on a deferred call so same-frame/deferred emissions are covered too.
	_suppress_auto_checkout = true
	call_deferred("_clear_auto_checkout_suppression")
	# Reopening a script tab re-fills its CodeEdit, which emits text_changed.
	# Our own reload must not read as a user edit. Counted, not a flag: a dock
	# Revert can land while a declined edit's reload is still settling, and
	# whichever finishes first must not un-suppress the other.
	_reloading_paths[res_path] = int(_reloading_paths.get(res_path, 0)) + 1

	var ok := false
	var ext := res_path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		if res_path in EditorInterface.get_open_scenes():
			_log("Reloading scene '%s'..." % res_path)
			EditorInterface.reload_scene_from_path(res_path)
			ok = true
		else:
			# No tab to reload, but the cached PackedScene can still hold the
			# old contents, and opening the scene later would serve that.
			_log("'%s' isn't open in a tab - re-reading it from disk." % res_path)
			ok = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) != null
	elif ext == "gd" or ext == "cs":
		ok = await _reload_script(res_path)
	else:
		_log("Reloading resource '%s' from disk..." % res_path)
		var reloaded := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if reloaded:
			EditorInterface.edit_resource(reloaded)
		ok = reloaded != null
	_checked_out_this_session.erase(res_path)
	_declined_this_session.erase(res_path)
	_pending_save_checkout.erase(res_path)
	# Let the editor finish rebuilding the scene/tab before we stop ignoring
	# its edit signals - reopening a script tab refills its CodeEdit, which
	# looks exactly like typing.
	await _settle_frames(2)
	var still_reloading := int(_reloading_paths.get(res_path, 1)) - 1
	if still_reloading > 0:
		_reloading_paths[res_path] = still_reloading
	else:
		_reloading_paths.erase(res_path)
	# Revert/sync/reload all change what's opened - reflect it in the tree.
	_request_refresh()
	return ok


## Put a script back to its on-disk contents. Two copies have to be replaced,
## not one. Godot keeps the edited source in the cached Script resource as
## well as in the open tab, so reverting in Perforce and closing the tab isn't
## enough: reopening the file serves the cached resource and the discarded
## edit comes back.
##
## CACHE_MODE_IGNORE is the only load mode that re-reads a script from disk -
## plain load() and CACHE_MODE_REPLACE both hand back the cached source
## (measured on Godot 4.7). It refreshes the cached resource in place, so
## every reference to the script sees the depot text. The tab is then closed
## and reopened on that refreshed resource, which is what puts the depot text
## in front of the user. reload_open_files() can't do this job: it skips any
## script whose on-disk modification time matches what it last recorded.
func _reload_script(res_path: String) -> bool:
	var script_editor := EditorInterface.get_script_editor()
	var was_open := false
	for s in script_editor.get_open_scripts():
		if (s as Script).resource_path == res_path:
			was_open = true
			break
	# Keep the user's place in the file across the close/reopen.
	var caret := 0
	var current := script_editor.get_current_script()
	if current != null and current.resource_path == res_path:
		var code := _current_script_code_edit()
		if code:
			caret = code.get_caret_line()

	var fresh := ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if fresh == null:
		_log("Couldn't re-read '%s' from disk - the editor may still show the old contents." % res_path)
		return false
	if not was_open:
		_log("Re-read '%s' from disk." % res_path)
		return true

	_log("Reloading script '%s' from disk..." % res_path)
	script_editor.close_file(res_path)
	EditorInterface.edit_script(fresh)
	await _settle_frames(2)
	# Only if the reopened file is still the one in front - focus can land
	# elsewhere, and moving the caret in an unrelated file would be worse
	# than not restoring it.
	var now_current := script_editor.get_current_script()
	if caret > 0 and now_current != null and now_current.resource_path == res_path:
		var code := _current_script_code_edit()
		if code and caret < code.get_line_count():
			code.set_caret_line(caret)
	return true


## The CodeEdit behind the script tab that's in front, or null.
func _current_script_code_edit() -> CodeEdit:
	var base := EditorInterface.get_script_editor().get_current_editor()
	if base == null:
		return null
	return base.get_base_editor() as CodeEdit


func _settle_frames(count: int) -> void:
	for _i in count:
		# The plugin can be torn down mid-reload (project closed, plugin
		# disabled); there's no tree left to wait on then.
		var scene_tree := get_tree()
		if scene_tree == null or _shutting_down:
			return
		await scene_tree.process_frame


func _clear_auto_checkout_suppression() -> void:
	_suppress_auto_checkout = false


## Open res_path for add (`p4 add`) and return what happened ("added",
## "ignored", "tracked", "failed", or "" when not connected). With `report`
## it explains anything but "added" in a dialog; a caller adding many files
## passes false and reports once.
func _add_path(res_path: String, report: bool = true) -> String:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return ""
	var global_path := ProjectSettings.globalize_path(res_path)
	var result := await _p4_exec_logged(["add", global_path])
	_request_refresh()
	var text := "" if result.output.is_empty() else String(result.output[0])
	var outcome := _add_outcome(text, int(result.exit_code))
	if not report:
		return outcome
	if outcome == "ignored":
		# p4 prints "opened for add" and then refuses, so say which rule did it.
		var why: Dictionary = await _p4_exec(["ignores", "-i", "-v", global_path])
		var rule := _ignore_rule_in("" if why.output.is_empty() else String(why.output[0]))
		await _show_alert(("Perforce didn't add '%s': your ignore rules say to leave it out.%s\n\n" +
				"Nothing was changed. If this file does belong on the server, change that " +
				"rule first, then mark the file for add again.") % [res_path,
				"" if rule.is_empty() else "\n\nThe rule: %s" % rule])
	elif outcome == "tracked":
		await _show_alert("'%s' is already in Perforce, so there's nothing to add." % res_path)
	elif outcome == "failed":
		await _show_alert(("Perforce didn't add '%s'. Press \"Log\" in the P4G panel to see " +
				"what it said.") % res_path)
	return outcome
# ---------------------------------------------------------------------------
# FileSystem dock operations: delete / move / rename
#
# These FileSystemDock signals fire AFTER Godot has already changed the disk, so
# we can't intercept like checkout-on-edit does - we react, bringing Perforce in
# line with what the dock just did. A deletion becomes an open-for-delete; a
# move/rename is recorded as a Perforce move naming both paths, which keeps the
# file's history (see _p4_record_move for why not `reconcile -M`). These prompt by default;
# the "Auto add/edit/delete" setting applies them silently. Our own p4 sync/
# revert/reload never route through these signals, so there's no feedback loop.
# ---------------------------------------------------------------------------

func _auto_open() -> bool:
	return auto_open_checkbox != null and auto_open_checkbox.button_pressed


## Confirm a delete/move recording, or auto-approve it in "Auto add/edit/delete"
## mode. The on-disk delete/move already happened, so declining is always safe -
## it just leaves Perforce a step behind until the next Reconcile.
func _confirm_fs_action(message: String, ok_text: String, cancel_text: String) -> bool:
	if _auto_open():
		return true
	return await _show_confirm_dialog(message, ok_text, cancel_text)


func _on_fs_file_removed(file: String) -> void:
	await _handle_fs_delete(file, false)


func _on_fs_folder_removed(folder: String) -> void:
	await _handle_fs_delete(folder, true)


func _on_fs_files_moved(old_file: String, new_file: String) -> void:
	await _handle_fs_move(old_file, new_file, false)


func _on_fs_folder_moved(old_folder: String, new_folder: String) -> void:
	await _handle_fs_move(old_folder, new_folder, true)


## Record a workspace deletion in Perforce. A folder reconciles its whole subtree
## for deletes; a single file branches on its fstat state (see _delete_action_for).
func _handle_fs_delete(res_path: String, is_folder: bool) -> void:
	if _shutting_down or not await _ensure_identity():
		return
	if is_folder:
		var scope := _as_recursive(ProjectSettings.globalize_path(res_path))
		var count := _count_tracked(_parse_ztag(await _p4_exec(["-ztag", "fstat", scope])))
		if count == 0:
			_log("Deleted folder '%s' - no Perforce-tracked files under it." % res_path)
			return
		if not await _confirm_fs_action(
				("You deleted the folder '%s', which held %d file(s) that are in " +
				"Perforce.\n\nTell Perforce to delete them too, so the deletion reaches " +
				"your team when you submit?")
				% [res_path, count], "Delete in Perforce", "Not Yet"):
			_log("Left the deleted folder '%s' tracked in Perforce - run Reconcile to record it." % res_path)
			return
		# `reconcile -d` skips files opened for add or move/add (measured), and
		# those then fail the submit: their content is gone. Settle them first.
		for folder_rec in _parse_ztag(await _p4_exec(["-ztag", "fstat", scope])):
			var folder_decision := _delete_action_for(folder_rec)
			var folder_local := String(folder_rec.get("clientFile", ""))
			if folder_decision in ["revert", "unmove"] and not folder_local.is_empty() \
					and not FileAccess.file_exists(folder_local):
				var folder_res := _local_to_res(folder_local)
				if not folder_res.is_empty():
					await _p4_open_for_delete(folder_res, folder_decision, folder_rec)
		await _p4_exec_logged(["reconcile", "-d", scope])
		_request_refresh()
		return

	var rec := await _fetch_fstat_record(res_path)
	var decision := _delete_action_for(rec)
	if decision == "none":
		_log("Deleted '%s' - not tracked by Perforce, nothing to record." % res_path)
		return
	if not await _confirm_fs_action(
			("You deleted '%s'.\n\nTell Perforce to delete it too, so the deletion reaches " +
			"your team when you submit?") % res_path, "Delete in Perforce", "Not Yet"):
		_log("Left '%s' tracked in Perforce - run Reconcile to record the deletion." % res_path)
		return
	await _p4_open_for_delete(res_path, decision, rec)
	_forget_path(res_path)
	# Godot deletes an asset's .import (and a script's .uid) along with it.
	for sidecar: String in _sidecars_of(res_path):
		if FileAccess.file_exists(ProjectSettings.globalize_path(sidecar)):
			continue
		var side_rec := await _fetch_fstat_record(sidecar)
		var side_decision := _delete_action_for(side_rec)
		if side_decision != "none":
			await _p4_open_for_delete(sidecar, side_decision, side_rec)
			_forget_path(sidecar)
	_request_refresh()


## Companion files Godot moves and deletes together with a file: an imported
## asset's `.import`, and the `.uid` of scripts and shaders (Godot 4.4+).
func _sidecars_of(res_path: String) -> Array:
	return [res_path + ".import", res_path + ".uid"]


## Record a workspace move/rename in Perforce, history-preserving where possible.
func _handle_fs_move(old_res: String, new_res: String, is_folder: bool) -> void:
	if _shutting_down or not await _ensure_identity():
		return
	var tracked: bool
	if is_folder:
		tracked = _count_tracked(_parse_ztag(await _p4_exec(
				["-ztag", "fstat", _as_recursive(ProjectSettings.globalize_path(old_res))]))) > 0
	else:
		tracked = _delete_action_for(await _fetch_fstat_record(old_res)) != "none"
	if not tracked:
		_log("Moved '%s' -> '%s' - source not tracked by Perforce, nothing to record." % [old_res, new_res])
		return
	if _is_case_only_rename(old_res, new_res, _server_folds_case):
		# Measured: `p4 move` answers "can't move to an existing file" and
		# exits 0, and two moves in one changelist cancel out to a plain edit.
		# It takes two submits, so it can't be done behind the user's back.
		var via := new_res.get_basename() + "_tmp" \
				+ ("" if new_res.get_extension().is_empty() else "." + new_res.get_extension())
		await _show_alert(("You renamed '%s' to '%s'. The two names differ only in capital " +
				"letters, and this Perforce server treats them as the same name, so it can't " +
				"record the rename. For your team the file keeps its old name.\n\nThat matters: " +
				"Godot now uses the new name, and on macOS, on Linux and in an exported game the " +
				"old name no longer matches it.\n\nTo rename it for everyone, do it in two " +
				"steps: rename it to something else (for example '%s') and submit, then rename " +
				"that to '%s' and submit again.") % [old_res, new_res, via.get_file(), new_res.get_file()])
		return
	if not await _confirm_fs_action(
			("You moved '%s'\n     -> '%s'.\n\nRecord this as a Perforce move? Your team then " +
			"gets the move, and the file keeps its history under the new name.")
			% [old_res, new_res], "Record Move", "Skip"):
		_log("Move of '%s' not recorded in Perforce - run Reconcile if you want it tracked." % old_res)
		return
	var result := await _p4_record_move(old_res, new_res, is_folder)
	var stuck: Array = result.not_moved
	if int(result.moved) > 0:
		_forget_path(old_res)
		if not is_folder and stuck.is_empty():
			_checked_out_this_session[new_res] = true
	_request_refresh()
	if int(result.moved) == 0 or not stuck.is_empty():
		var text := ("Perforce didn't record the move of '%s'." % old_res) if int(result.moved) == 0 \
				else ("Perforce recorded the move of %d file(s), but not of these:\n\n%s" \
				% [int(result.moved), _file_listing(stuck, 10)])
		text += ("\n\nOn your disk the move is done. For your team %s at the old place, so " +
				"the project they get won't match yours. Moving %s back in Godot puts things " +
				"right.") % ["the file stays" if is_folder == false and stuck.size() <= 1 else "those files stay",
				"it" if is_folder == false and stuck.size() <= 1 else "them"]
		var reasons: Array = result.reasons
		if not reasons.is_empty():
			text += "\n\nPerforce said:\n\n%s" % _file_listing(reasons, 6)
			if "\n".join(reasons).contains("exclusive"):
				text += ("\n\nA teammate has the file checked out with an exclusive lock, so " +
						"nobody else can change or move it until they submit or revert.")
		await _show_alert(text)


## A rename that changes nothing but upper and lower case, on a server that
## ignores case in names.
func _is_case_only_rename(old_res: String, new_res: String, server_folds_case: bool) -> bool:
	return server_folds_case and old_res != new_res and old_res.to_lower() == new_res.to_lower()


## How to record a single-file deletion, from its `-ztag fstat` record. Pure, so
## a headless self-test can pin the mapping:
## - "none":      untracked, or already deleted at head - nothing to do.
## - "revert":    only open for add (never in the depot) - undo the pending add.
## - "unmove":    the new half of a move. Reverting it would bring the file
##                back at its old path (measured), so forget the move without
##                touching disk and open the old path for delete.
## - "reconcile": tracked (opened for edit or not) but now missing on disk -
##                `p4 reconcile -d` records the delete without restoring the file.
func _delete_action_for(rec: Dictionary) -> String:
	if rec.is_empty() or not rec.has("depotFile"):
		return "none"
	var act := String(rec.get("action", ""))
	if act == "add":
		return "revert"
	if act == "move/add":
		return "unmove"
	if act == "" and String(rec.get("headAction", "")) in ["delete", "move/delete"]:
		return "none"
	return "reconcile"


func _p4_open_for_delete(res_path: String, decision: String, rec: Dictionary = {}) -> void:
	var global_path := ProjectSettings.globalize_path(res_path)
	match decision:
		"revert":
			await _p4_exec_logged(["revert", global_path])
		"unmove":
			var old_depot := String(rec.get("movedFile", ""))
			await _p4_exec_logged(["revert", "-k", global_path])
			if not old_depot.is_empty():
				# In the changelist the move was in, not the default one.
				var delete_args := PackedStringArray(["delete", "-k"])
				if String(rec.get("change", "")).is_valid_int():
					delete_args.append_array(["-c", String(rec.get("change", ""))])
				delete_args.append(old_depot)
				await _p4_exec_logged(delete_args)
		"reconcile":
			await _p4_exec_logged(["reconcile", "-d", global_path])


## Record a move the editor has already made on disk, as a Perforce move:
## `p4 edit <old>` then `p4 move -k <old> <new>` (-k: don't touch the files, they
## are already where they belong). A folder is one pair of "/..." paths; a
## file brings its .import / .uid sidecars. Returns {moved: <files recorded>,
## not_moved: <paths the server still has at the old place>, reasons: <what
## p4 said about those>, exit_code, output}.
##
## Why not `reconcile -M`, which this used to be: that guesses the pairing from
## file content, and for a binary file that was moved and changed it guesses
## "delete + add" - the history is cut (measured). Naming both paths can't
## miss. There is no fallback to that guess: on a file a teammate holds an
## exclusive lock on it opens the new name as an unrelated add and reports
## success (measured), which is worse than saying the move wasn't recorded.
##
## Measured on 2025.2 and 2026.1, all relied on below:
## - `edit` of a file that has left its old path opens it and then exits 1 on
##   "chmod: ... cannot find the file". That exit code is not a failure.
## - `move -k` without the edit answers "not opened on this client", exit 0.
## - A file opened for add moves as a plain add of the new path.
## - The moved file keeps the read-only flag it had before the edit, because
##   p4 never saw it at the new path.
func _p4_record_move(old_res: String, new_res: String, is_folder: bool) -> Dictionary:
	var old_g := ProjectSettings.globalize_path(old_res)
	var new_g := ProjectSettings.globalize_path(new_res)
	var pairs: Array = []
	if is_folder:
		pairs.append([_as_recursive(old_g), _as_recursive(new_g)])
	else:
		pairs.append([old_g, new_g])
		for i in _sidecars_of(old_res).size():
			var new_side := ProjectSettings.globalize_path(_sidecars_of(new_res)[i])
			if FileAccess.file_exists(new_side):
				pairs.append([ProjectSettings.globalize_path(_sidecars_of(old_res)[i]), new_side])
	var old_paths := PackedStringArray()
	for pair in pairs:
		old_paths.append(String(pair[0]))
	# What was open before, so an edit this opens can be told from the user's
	# own, and so newly opened files join the changelist the file is already
	# in instead of splitting the work across two.
	var was_unopened := {}
	var change := ""
	for rec in _parse_ztag(await _p4_exec(PackedStringArray(["-ztag", "fstat"]) + old_paths)):
		var depot := String(rec.get("depotFile", ""))
		if depot.is_empty():
			continue
		if String(rec.get("action", "")).is_empty():
			was_unopened[depot] = true
		elif change.is_empty() and not is_folder and String(rec.get("change", "")).is_valid_int():
			change = String(rec.get("change", ""))
	var edit_args := PackedStringArray(["edit"])
	if not change.is_empty():
		edit_args.append_array(["-c", change])
	var edit_result := await _p4_exec_logged(edit_args + old_paths)
	var reasons: Array = _refusals(edit_result).lines
	var moved := 0
	var said: Array = []
	for pair in pairs:
		var result := await _p4_exec_logged(["-ztag", "move", "-k", String(pair[0]), String(pair[1])])
		var text := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		said.append(text)
		for raw in text.split("\n"):
			var line := String(raw).strip_edges()
			if line.contains(" - can't ") or line.contains("use -f to force"):
				reasons.append(line)
		for local in _moved_paths_in(_parse_ztag(result)):
			moved += 1
			_set_file_writable(local, true)
	# Ask the server what is left at the old place. A count of what moved says
	# nothing about what didn't: one file locked by a teammate, or one whose
	# new name is taken, stays behind without failing the command.
	var not_moved: Array = []
	var undo := PackedStringArray()
	for rec in _parse_ztag(await _p4_exec(PackedStringArray(["-ztag", "fstat"]) + old_paths)):
		var action := String(rec.get("action", ""))
		if action == "move/delete" or _delete_action_for(rec) == "none":
			continue
		var local := String(rec.get("clientFile", ""))
		if local.is_empty() or FileAccess.file_exists(local):
			continue # still on disk at the old place: not part of this move
		var res := _local_to_res(local)
		not_moved.append(res if not res.is_empty() else local)
		if action == "edit" and was_unopened.has(String(rec.get("depotFile", ""))):
			undo.append(String(rec.get("depotFile", "")))
	# An edit opened above for a file that then didn't move would sit in the
	# changelist pointing at a path with nothing in it, and fail the submit.
	for start in range(0, undo.size(), 50):
		await _p4_exec_logged(PackedStringArray(["revert", "-k"]) + undo.slice(start, start + 50))
	return {"exit_code": 0, "output": ["\n".join(said)], "moved": moved,
			"not_moved": not_moved, "reasons": reasons}


## The local paths `p4 -ztag move -k` reports as recorded: one record per file,
## action "move/add" (or "add" when the source was only opened for add).
## Refusals come back as plain lines with no record, and exit 0.
func _moved_paths_in(records: Array) -> PackedStringArray:
	var paths := PackedStringArray()
	for rec in records:
		var local := String(rec.get("path", ""))
		if not local.is_empty() and String(rec.get("action", "")) in ["move/add", "add"]:
			paths.append(local)
	return paths


## A local path as a p4 recursive scope (append "/..."), for folder operations.
func _as_recursive(global_path: String) -> String:
	if global_path.ends_with("/") or global_path.ends_with("\\"):
		return global_path + "..."
	return global_path + "/..."


## Count the Perforce-tracked files in a set of `-ztag fstat` records (anything
## that would need an open-for-delete or a pending-add revert).
func _count_tracked(recs: Array) -> int:
	var n := 0
	for rec in recs:
		if _delete_action_for(rec) != "none":
			n += 1
	return n


## Drop a path from every session cache (after it's deleted or moved away).
func _forget_path(res_path: String) -> void:
	_checked_out_this_session.erase(res_path)
	_declined_this_session.erase(res_path)
	_pending_save_checkout.erase(res_path)
	_fstat_cache.erase(res_path)


