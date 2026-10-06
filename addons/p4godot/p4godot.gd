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
##   succeeds on a file that isn't checked out (the allwrite case), it goes
##   through `p4 reconcile -e` right after, which opens it only if it changed.
## - Delete / move / rename: deleting or moving a file (or folder) in the
##   FileSystem dock is caught via FileSystemDock signals and offered to
##   Perforce - open-for-delete for a deletion, a history-preserving move
##   (`p4 reconcile -M`) for a rename. Prompts by default, or applies silently
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
##   add them with the FileSystem dock's "P4: Mark for Add" or via Reconcile.
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

const SETTINGS_SECTION := "p4godot"

## Shown wherever an action needs Perforce and there's no connection. One
## constant because six copies of it drifted apart.
const NOT_CONNECTED_MESSAGE := ("Godot isn't connected to Perforce, so it can't do " +
		"this.\n\nOpen the P4G panel - normally at the bottom of the editor - and press " +
		"the circular-arrow Refresh button. It walks you through connecting. The \"Log\" " +
		"button in that panel shows what went wrong.")

# A light P4 brand accent over Godot's native theme (from the Perforce Force UI
# palette). The dock otherwise uses editor theme colors/icons so it reads native.
const P4_ACCENT := Color("00cfff") # cyan - tints the changelist icons
const ACTION_ADD_COLOR := Color("138613") # green
const ACTION_EDIT_COLOR := Color("0084e8") # info blue
const ACTION_DELETE_COLOR := Color("d11323") # cranberry

# How long a hovered file's cached p4 status stays fresh before the next hover
# triggers a background refresh (see _prefetch_fstat).
const FSTAT_CACHE_TTL_SEC := 5.0


## One queued `p4` invocation, executed on the worker thread. `done` is emitted
## on the MAIN thread (the worker hands the result back via call_deferred), so
## an awaiting coroutine always resumes on the main thread - no locking needed
## anywhere outside the queue itself.
class P4Request extends RefCounted:
	signal done
	var bin: String = "p4" # copied from _p4_bin on the main thread
	var args: PackedStringArray
	# When set, p4 is run through the platform shell with this file redirected
	# onto its stdin (for `p4 change -i`, whose spec input OS.execute can't feed).
	var stdin_path: String = ""
	var exit_code: int = -1
	var output: Array = []
	var completed: bool = false
	# A streamed request (see _p4_exec_streamed) is read through pipes while p4
	# runs. `lines` carries p4's progress and tracking lines to the main thread
	# as they arrive. `cancel` and `detach` are set by the main thread and read
	# by the worker: cancel kills p4, detach stops watching it and leaves it
	# running (the editor is closing).
	signal lines(batch: PackedStringArray)
	var streamed: bool = false
	var cancel: bool = false
	var detach: bool = false
	var killed: bool = false

	func _finish() -> void:
		completed = true
		done.emit()

	func _emit_lines(batch: PackedStringArray) -> void:
		lines.emit(batch)


## Running totals for a submit or sync, fed the lines `p4 --progress=debug`
## prints while it works:
##   progress (total|update|done): <local path> (type T units U) - <pos> of <n>
## Unlike `p4 -I`, that mode keeps reporting when the server runs the transfer
## in parallel threads (measured on a 2025.2 client and server; the mode has
## been in Perforce's client source since 2021.1 and isn't in `p4 help usage`).
##
## Units matter. 3 is kilobytes. A file sent by Delta Transfer (`binary+F`,
## only the changed parts travel) reports 5, "deltas", such as "17 of 22" -
## still a usable fraction, but not a size. And a Delta Transfer SYNC reports
## nothing at all for the file. So a file's size comes from what the caller
## knew up front where it can, its position is always pos/n, and finish()
## fills in whatever was never reported.
class P4Progress extends RefCounted:
	const UNIT_KBYTES := 3
	const UNIT_MBYTES := 4
	const UNIT_DELTAS := 5

	## What the caller knew before starting: how many files will transfer, their
	## total size, and each one's size by _path_key(local path). All optional.
	var total_files: int = 0
	var total_bytes: int = 0
	var sizes: Dictionary = {}

	var files_done: int = 0
	var delta_files: int = 0
	## The file most recently reported on, for display.
	var current: String = ""
	## True once any progress line has been read.
	var reporting: bool = false
	## Megabytes the server's tracking output says crossed the network
	## (`-Ztrack`); -1 until a tracking line with a size is seen.
	var network_mb: int = -1

	var _files: Dictionary = {} # key -> {"bytes": int, "frac": float, "done": bool}
	var _bytes_done: float = 0.0
	var _seen_bytes: int = 0
	var _line_re := RegEx.create_from_string(
			"^progress \\((total|update|done)\\): (.*) \\(type (\\d+) units (\\d+)\\) - (-?\\d+) of (-?\\d+)$")
	var _rpc_re := RegEx.create_from_string(
			"^--- rpc msgs/size in\\+out \\d+\\+\\d+/(\\d+)mb\\+(\\d+)mb")

	static func key_of(path: String) -> String:
		return path.replace("\\", "/").to_lower()

	## Feed one line of p4 output. Returns true if it was a progress or
	## tracking line (and so isn't part of the command's own answer).
	func feed(line: String) -> bool:
		if line.begins_with("--- "):
			var rpc := _rpc_re.search(line)
			if rpc:
				# One line per connection phase; the larger direction is the
				# file content (in for a submit, out for a sync).
				var mb: int = maxi(int(rpc.get_string(1)), int(rpc.get_string(2)))
				network_mb = maxi(network_mb, 0) + mb
			return true
		var m := _line_re.search(line)
		if m == null:
			return line.begins_with("progress (")
		reporting = true
		var kind := m.get_string(1)
		var path := m.get_string(2)
		var transfer := int(m.get_string(3))
		var units := int(m.get_string(4))
		var pos := float(m.get_string(5))
		var out_of := float(m.get_string(6))
		if transfer != 1 and transfer != 2:
			return true # not a file being sent (1) or received (2)
		current = path
		var key := key_of(path)
		var f: Dictionary = _files.get(key, {})
		if f.is_empty():
			var size := int(sizes.get(key, -1))
			if size < 0:
				size = int(out_of * 1024.0) if units == UNIT_KBYTES \
						else (int(out_of * 1048576.0) if units == UNIT_MBYTES else 0)
			f = {"bytes": size, "frac": 0.0, "done": false}
			_files[key] = f
			_seen_bytes += size
			if units == UNIT_DELTAS:
				delta_files += 1
		if f.done:
			return true
		var frac := 1.0 if kind == "done" \
				else (clampf(pos / out_of, 0.0, 1.0) if out_of > 0.0 else 0.0)
		_bytes_done += float(f.bytes) * (frac - float(f.frac))
		f.frac = frac
		if kind == "done":
			f.done = true
			files_done += 1
		return true

	func is_done(path: String) -> bool:
		var f: Dictionary = _files.get(key_of(path), {})
		return not f.is_empty() and bool(f.done)

	## How many files p4 has started on and not reported done.
	func in_flight() -> int:
		var n := 0
		for f: Dictionary in _files.values():
			if not bool(f.done):
				n += 1
		return n

	## The command ended successfully: everything expected has arrived,
	## including files p4 never reported on.
	func finish() -> void:
		files_done = maxi(files_done, expected_files())
		_bytes_done = float(expected_bytes())

	func expected_files() -> int:
		return maxi(total_files, _files.size())

	func expected_bytes() -> int:
		return maxi(total_bytes, _seen_bytes)

	func bytes_done() -> int:
		return int(clampf(_bytes_done, 0.0, float(expected_bytes())))

	## 0..1, by bytes when sizes are known and by file count otherwise.
	func fraction() -> float:
		var bytes := expected_bytes()
		if bytes > 0:
			return clampf(_bytes_done / float(bytes), 0.0, 1.0)
		var files := expected_files()
		return clampf(float(files_done) / float(files), 0.0, 1.0) if files > 0 else 0.0


## Right-click Perforce actions on files in the editor's FileSystem dock. This is
## Godot's EditorContextMenuPlugin hook - the same native integration Nick Poole's
## C++ plugin used, but reachable from GDScript. Menu construction and the action
## handlers live on the main plugin (this class just forwards), so the logic
## reuses the plugin's existing worker-thread p4 methods and can be exercised
## headless.
class P4FileSystemContextMenu extends EditorContextMenuPlugin:
	var plugin # the main P4 EditorPlugin (untyped to avoid a cyclic self-type)

	func _popup_menu(paths: PackedStringArray) -> void:
		if plugin != null:
			plugin._populate_fs_context_menu(self, paths)


## Hover tooltips for files in the FileSystem dock (Godot's
## EditorResourceTooltipPlugin hook). _make_tooltip_for_path is synchronous, so it
## only reads the plugin's cached status and asks for a background refresh - it
## never blocks the editor on a p4 round trip.
class P4FileSystemTooltip extends EditorResourceTooltipPlugin:
	var plugin

	func _handles(_type: String) -> bool:
		return true

	func _make_tooltip_for_path(path: String, _metadata: Dictionary, base: Control) -> Control:
		if plugin != null:
			plugin._on_tooltip_for_path(path, base)
		return base


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
var diff_window: Window
var diff_left: TextEdit
var diff_right: TextEdit
var diff_left_label: Label
var diff_right_label: Label
var diff_prev_button: Button
var diff_next_button: Button
var diff_change_label: Label
var diff_full_file_toggle: CheckButton
var _diff_scroll_syncing: bool = false
# The full aligned rows of the current diff (collapse is a re-render of these)
# and the rendered-row index where each contiguous change block starts.
var _diff_rows: Array = []
var _diff_change_blocks: Array = []
var new_changelist_button: Button
var get_latest_button: Button
var reconcile_button: Button
var revert_unchanged_button: Button
# Right side of the toolbar: connection status (click = connection setup) and
# the gear menu fronting the hidden setting checkboxes.
var conn_status_button: Button
var settings_menu: MenuButton
# Responsive toolbar: the action buttons (_toolbar_actions) live in the top
# row while they fit, and drop to a second row when the dock is narrow;
# connection status / settings / Log (_toolbar_right) hold the top row.
var _toolbar: VBoxContainer
var _toolbar_top: HBoxContainer
var _toolbar_second: HBoxContainer
var _toolbar_actions: HBoxContainer
var _toolbar_right: HBoxContainer
var _toolbar_wrapped: bool = false
var auto_checkout_checkbox: CheckBox
var detect_external_checkbox: CheckBox
var checkout_on_save_checkbox: CheckBox
var verbose_log_checkbox: CheckBox
var auto_open_checkbox: CheckBox

# Native FileSystem-dock hooks (Godot's EditorContextMenuPlugin /
# EditorResourceTooltipPlugin), registered in _enter_tree. GDScript-reachable -
# no GDExtension required.
var _fs_context_menu: P4FileSystemContextMenu
var _fs_tooltip: P4FileSystemTooltip

# Mirrors verbose_log_checkbox so the logging hot path never touches a UI node.
# When false, read-only probes (fstat/opened/where/changes/info/change -o and -n
# previews) are kept out of the log; state-changing commands always show.
var _verbose_log: bool = false

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
var _p4_port: String = ""

# Optional per-project connection overrides (persisted in editor metadata,
# chosen via connection setup). Passed to every command as p4 global flags
# (-p/-u/-c), so a project binds to the right server/client without touching
# the user's machine-wide p4 configuration (P4CONFIG, registry, env).
# The p4 executable (see _resolve_p4_bin); "" until found. Read by the worker
# only through the copy each P4Request carries.
var _p4_bin: String = ""
const P4_PATH_SETTING := "perforce/executable_path"
# That executable's release as a number (2025.2), from `p4 -V`; 0.0 if unknown.
var _p4_version: float = 0.0
# The last connection probe's p4 output, for setup prompts that quote it.
var _last_probe_text: String = ""

var _override_port: String = ""
var _override_user: String = ""
var _override_client: String = ""

# Ticket-expiry re-login. _login_prompt_active single-flights the prompt (a
# dead ticket fails many commands at once); _login_declined stops re-prompting
# after a cancel until the user presses Refresh. _setup_active single-flights
# the connection setup flow the same way.
var _login_prompt_active: bool = false
var _login_declined: bool = false
var _setup_active: bool = false

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

# res:// path -> true while WE are reloading that file from disk. Refilling a
# script tab emits text_changed exactly like typing does; without this, our
# own reload would prompt for a checkout of the file it just discarded.
var _reloading_paths: Dictionary = {}

# Hover-tooltip status cache: res:// path -> {data: <parsed -ztag fstat record>,
# time: <unix seconds>}. The tooltip callback is synchronous and must never wait
# on a p4 round trip, so it renders whatever is cached and kicks a background
# refresh (_prefetch_fstat) for next time. _fstat_prefetch_inflight dedups the
# background fetches so repeated hovers don't queue a burst of identical fstats.
var _fstat_cache: Dictionary = {}
var _fstat_prefetch_inflight: Dictionary = {}

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
# Set when a dialog was closed by its extra button (see _show_option_dialog).
var _dialog_result_extra: bool = false

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
# res:// path -> bool: whether the file is Perforce-tracked and unopened
# (eligible for the pre-write pass). Filled by one batched fstat per save
# pass; cleared on every dock refresh so it can't drift far.
var _prewrite_eligible_cache: Dictionary = {}

# Read-only .import files made writable for an in-progress reimport: global
# path -> original bytes. See _on_resources_reimporting.
var _reimport_backups: Dictionary = {}
const REIMPORT_CONFIRM_THRESHOLD := 20
# The Import dock's Reimport button, hooked by _hook_import_dock.
var _import_reimport_button: Button = null

# Global path -> Time.get_ticks_msec() of its last failed `p4 fstat` (see
# _remember_no_checkout and the keystroke throttle in _handle_edit).
var _fstat_failed: Dictionary = {}

# Network limits and the circuit breaker (see _with_connection_flags).
const NET_MAXWAIT_SEC := 120     # background commands: bound a hung server
const NET_MAXWAIT_SAVE_SEC := 30 # the blocking calls right before a save
# Submit and whole-project sync have no limit at all: they run streamed, with
# a progress window and a Cancel button (see _p4_exec_streamed).
const UNREACHABLE_BACKOFF_MSEC := 60000
var _unreachable_until_msec: int = 0

# Last-seen UndoRedo version per editor history id (see _history_advanced).
var _history_versions: Dictionary = {}

# res:// path -> [mtime, direct res:// dependencies] (see _direct_deps).
var _deps_cache: Dictionary = {}

# res:// path -> Time.get_ticks_msec() when _finish_prewrite_pass settled it.
var _prewrite_settled: Dictionary = {}

# See _shader_files.
var _shader_files_cache: Array = []
var _shader_files_dirty: bool = true

# CLI self-test only: "confirm"/"decline" auto-answers dialogs by emitting the
# same signal a real button click would (see the self-test section below).
var _selftest_auto_answer: String = ""
## True while a --p4-selftest-* run is driving the plugin. Startup prompts and
## the focus-in scan stay out of the way so a test sees only its own actions.
var _selftest_mode: bool = false


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
	# Fire-and-forget coroutine: anything that needs the identity awaits
	# _ensure_identity() instead of assuming this has resolved.
	_detect_p4_identity()
	_log("P4Godot loaded.")
	_run_cli_self_test_if_requested()
	# Also fire-and-forget; it waits on the identity itself.
	_check_plugin_tracked()


func _exit_tree() -> void:
	_shutting_down = true
	_unregister_filesystem_hooks()
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


## Startup probe: resolve who we are via `p4 -ztag info`, decide availability,
## and when the connection is misconfigured (no server, dead ticket, wrong or
## missing client) open the interactive connection setup instead of failing
## quietly into the log.
func _detect_p4_identity() -> void:
	var status: String = await _probe_connection()
	_p4_available = status == "ok"
	_identity_checked = true
	identity_checked.emit()
	_update_conn_status()
	if status == "ok":
		_request_refresh()
		# Surface a dead ticket now (`login -s` fails -> the re-login prompt),
		# not on the user's first checkout attempt.
		_p4_exec(["login", "-s"])
		return
	_log("Perforce is not ready (%s) - opening connection setup." % status)
	_offer_connection_setup()


## One `p4 -ztag info` probe. On success fills _p4_user/_p4_client/_p4_port and
## returns "ok"; otherwise names what is wrong: "p4 missing" (CLI not found),
## "no server" (can't connect), "not logged in", or "no client" (workspace
## unknown, or its root doesn't contain this project).
func _probe_connection() -> String:
	if _p4_bin.is_empty():
		_p4_bin = _resolve_p4_bin() # retried on every probe: p4 may have been installed since
		if _p4_bin.is_empty():
			return "p4 missing"
	var result: Dictionary = await _p4_exec(["-ztag", "info"])
	var text := "" if result.output.is_empty() else String(result.output[0])
	_last_probe_text = text
	if result.exit_code != 0:
		if _looks_like_login_error(result):
			return "not logged in"
		if text.contains("IDENTIFICATION HAS CHANGED"):
			return "fingerprint changed"
		if text.contains("'p4 trust'"):
			return "not trusted"
		if text.contains("Connect to server failed") or text.contains("check $P4PORT") \
				or text.to_lower().contains("tcp connect"):
			return "no server"
		# macOS/Linux run p4 through a shell: a missing binary is exit 127.
		if text.strip_edges().is_empty() or result.exit_code == 127 \
				or text.contains("command not found") or text.contains(": not found"):
			return "p4 missing"
		return "no server"
	var records := _parse_ztag(result)
	var info: Dictionary = {} if records.is_empty() else records[0]
	_p4_user = String(info.get("userName", ""))
	_p4_port = String(info.get("serverAddress", ""))
	var client := String(info.get("clientName", ""))
	var root := String(info.get("clientRoot", ""))
	if client == "*unknown*" or client.is_empty() or not _project_inside_root(root):
		# `p4 info` works without a ticket but listing workspaces doesn't, so
		# log in before the workspace picker - or it finds nothing.
		if _looks_like_login_error(await _p4_exec(["login", "-s"], false)):
			return "not logged in"
		return "no client"
	_p4_client = client
	return "ok"


## The executable to run: the resolved one, else plain "p4" (whose failure the
## connection probe then reports as "p4 missing").
func _p4_cmd() -> String:
	return _p4_bin if not _p4_bin.is_empty() else "p4"


## Find a working p4 executable, or "". Godot launched from the macOS Dock or
## Finder gets launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which
## hides Homebrew's p4 - so after the PATH lookup, try the usual install
## locations. The "perforce/executable_path" editor setting (shown as Perforce >
## Executable Path) is tried first.
func _resolve_p4_bin() -> String:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(P4_PATH_SETTING):
		settings.set_setting(P4_PATH_SETTING, "")
	settings.set_initial_value(P4_PATH_SETTING, "", false)
	settings.add_property_info({"name": P4_PATH_SETTING, "type": TYPE_STRING,
			"hint": PROPERTY_HINT_GLOBAL_FILE})
	var home := OS.get_environment("HOME")
	var candidates := PackedStringArray()
	var configured := String(settings.get_setting(P4_PATH_SETTING)).strip_edges()
	if not configured.is_empty():
		candidates.append(configured)
	candidates.append("p4")
	match OS.get_name():
		"Windows":
			candidates.append_array(["C:/Program Files/Perforce/p4.exe",
					"C:/Program Files (x86)/Perforce/p4.exe"])
		"macOS":
			candidates.append_array(["/opt/homebrew/bin/p4", "/usr/local/bin/p4",
					home.path_join("bin/p4")])
		_:
			candidates.append_array(["/usr/local/bin/p4", "/usr/bin/p4",
					"/opt/perforce/bin/p4", home.path_join("bin/p4")])
	for c in candidates:
		if c != "p4" and not FileAccess.file_exists(c):
			continue
		var out := []
		if OS.execute(c, _os_args(["-V"]), out, true) == 0 \
				and not out.is_empty() and String(out[0]).contains("Perforce"):
			if c != "p4":
				_log("Using p4 at %s." % c)
			_p4_version = _p4_version_in(String(out[0]))
			return c
	if not configured.is_empty():
		_log("The %s editor setting ('%s') isn't a working p4." % [P4_PATH_SETTING, configured])
	return ""


## The client release in `p4 -V` output, as a number: the line
## "Rev. P4/NTX64/2025.2/2907753 (2026/03/09)." gives 2025.2. 0.0 if absent.
static func _p4_version_in(version_text: String) -> float:
	var m := RegEx.create_from_string("Rev\\. P4/[^/]+/(\\d{4})\\.(\\d+)/").search(version_text)
	return float("%s.%s" % [m.get_string(1), m.get_string(2)]) if m else 0.0


## Whether the project directory lives under `client_root` (case-insensitive,
## slash-normalized - p4 reports Windows roots with backslashes).
func _project_inside_root(client_root: String) -> bool:
	if client_root.is_empty() or client_root == "null":
		return false
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/").to_lower()
	var root := client_root.replace("\\", "/").to_lower()
	return (project.rstrip("/") + "/").begins_with(root.rstrip("/") + "/")


## Interactive connection setup: figure out what's missing (server -> login ->
## client), ask for just that piece, and re-probe until `p4 info` resolves this
## project. Workspace suggestions come from the user's existing clients on the
## server, ranked by whether their root contains this project.
func _offer_connection_setup() -> void:
	if _setup_active or _shutting_down:
		return
	if DisplayServer.get_name() == "headless":
		_log("Connection setup skipped - headless session has nobody to ask.")
		return
	_setup_active = true
	var attempts := 0
	while attempts < 8: # each pass fixes one piece; 8 is a runaway stop, not a budget
		attempts += 1
		var status: String = await _probe_connection()
		if status == "ok":
			_p4_available = true
			_save_connection_overrides()
			_log("Perforce connected: user %s, client %s, server %s." \
					% [_p4_user, _p4_client, _p4_port])
			_request_refresh()
			break
		if status == "p4 missing":
			await _show_alert("Couldn't find the p4 command-line client.\n\n" +
					"Install it from perforce.com/downloads (on Windows it comes with P4V;\n" +
					"on macOS, `brew install --cask p4` works), then press Refresh in the P4G dock.\n\n" +
					"If p4 is installed somewhere unusual, set its full path in\n" +
					"Editor Settings > Perforce > Executable Path.")
			break
		if status == "not trusted":
			var fp_re := RegEx.create_from_string("(?:[0-9A-Fa-f]{2}:){15,}[0-9A-Fa-f]{2}")
			var fp_match := fp_re.search(_last_probe_text)
			if not fp_match:
				await _show_alert("This computer hasn't connected to this Perforce server over " +
						"SSL before, and P4Godot couldn't read the server's fingerprint (see the P4 " +
						"Log). Run `p4 trust` in a terminal to check and accept it, then press Refresh.")
				break
			var fp := fp_match.get_string()
			var trust: bool = await _show_confirm_dialog(("This computer hasn't connected to this " +
					"Perforce server over SSL before.\n\nServer fingerprint:\n%s\n\nTrust it only if it " +
					"matches the fingerprint your server admin gave you (or the one P4V showed you).")
					% fp, "Trust This Server", "Cancel")
			if not trust:
				break
			# Install exactly the fingerprint shown, not whatever the next
			# connection happens to present.
			await _p4_exec_logged(["trust", "-i", fp])
			continue
		if status == "fingerprint changed":
			await _show_alert("WARNING: this Perforce server's SSL fingerprint has CHANGED since " +
					"this computer last connected.\n\nThat can mean the server was reinstalled - or " +
					"that something is intercepting the connection. Ask your server admin before " +
					"trusting the new fingerprint (`p4 trust -f -y` in a terminal).")
			break
		if status == "no server":
			var prefill: String = await _suggest_port()
			var res: Dictionary = await _show_input_dialog("P4 Connection Setup",
					"Couldn't reach a Perforce server.\n" +
					"Enter the server address (host:port, e.g. ssl:p4.example.com:1666):",
					prefill, false, "Connect")
			if not res.ok:
				break
			_override_port = String(res.text).strip_edges()
			continue
		if status == "not logged in":
			if not await _login_flow():
				break
			continue
		if status == "no client":
			if not await _pick_client():
				break
			continue
	_setup_active = false
	_update_conn_status()
	if not _p4_available:
		_log("Perforce is still not configured - press Refresh (the circular-arrow button) in the P4G dock to run setup again.")


## Best guess for the server-address prompt: a stored override, else whatever
## `p4 set` reports for P4PORT (env, registry, or an inherited P4CONFIG).
func _suggest_port() -> String:
	if not _override_port.is_empty():
		return _override_port
	var result: Dictionary = await _p4_exec(["set", "-q", "P4PORT"])
	var text := "" if result.output.is_empty() else String(result.output[0])
	for raw_line in text.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.begins_with("P4PORT="):
			return line.substr("P4PORT=".length())
	return ""


const CHANGE_SERVER_TEXT := "Change Server or User..."


## Suggest one of the user's existing workspaces for this project; the picked
## name becomes the per-project client override. Returns false on cancel, and
## true when something changed that setup should re-probe: a workspace was
## picked, or the server or user was changed from here.
##
## The dialog names the server and user it is listing workspaces for. A
## P4PORT that is set and reachable but belongs to a different project's
## server looks, from here, like "you have no workspace for this project" -
## and without the server on screen there is nothing to tell the two apart.
func _pick_client() -> bool:
	while not _shutting_down:
		var user := _override_user if not _override_user.is_empty() else _p4_user
		var result: Dictionary = await _p4_exec(["-ztag", "clients", "--me"])
		if result.exit_code != 0:
			# --me needs 2020.1+; fall back to filtering by user name.
			if not user.is_empty():
				result = await _p4_exec(["-ztag", "clients", "-u", user])
		var clients: Array = _parse_ztag(result) if result.exit_code == 0 else []
		var matches: Array = []
		var others: Array = []
		for c in clients:
			if String(c.get("client", "")).is_empty():
				continue
			if _project_inside_root(String(c.get("Root", ""))):
				matches.append(c)
			else:
				others.append(c)
		var ordered: Array = matches + others
		var where := "Server:  %s\nUser:  %s\n\n" % [
				_p4_port if not _p4_port.is_empty() else _override_port, user]
		if ordered.is_empty():
			# "No workspaces" is only true if the server was asked and answered.
			var listed: bool = int(result.exit_code) == 0
			var res: Dictionary = await _show_input_dialog("P4 Connection Setup", where +
					("You have no workspaces on this server.\n\n" if listed else
					"P4Godot couldn't list your workspaces on this server:\n%s\n\n"
							% _first_line(result)) +
					"If that's the wrong server or user, press \"" + CHANGE_SERVER_TEXT + "\".\n" +
					"Otherwise create a workspace in P4V (or with `p4 client`) whose root contains\n" +
					"this project, then press Refresh (the circular-arrow button) in the P4G dock.\n" +
					"Or enter a workspace name to use directly:",
					"", false, "Use Workspace", false, CHANGE_SERVER_TEXT)
			if res.extra:
				if (await _edit_connection()).changed:
					return true
				continue
			if not res.ok or String(res.text).strip_edges().is_empty():
				return false
			_override_client = String(res.text).strip_edges()
			return true
		var options := PackedStringArray()
		var preselect := 0
		for i in ordered.size():
			var ws_name := String(ordered[i].get("client", ""))
			options.append("%s   (%s)" % [ws_name, String(ordered[i].get("Root", ""))])
			if ws_name == _p4_client:
				preselect = i
		var head := "Found a workspace whose root contains this project.\n" if not matches.is_empty() \
				else "None of your workspaces' roots contain this project - pick one anyway,\nor cancel and create a workspace for it first.\n"
		var picked: Dictionary = await _show_option_dialog("P4 Connection Setup",
				where + head + "Workspace to use for this project (stored per-project, per-user):",
				options, preselect, "Use This Workspace", CHANGE_SERVER_TEXT)
		if picked.extra:
			if (await _edit_connection()).changed:
				return true
			continue
		if not picked.ok:
			return false
		_override_client = String(ordered[picked.index].get("client", ""))
		return true
	return false


## Let the user change the server address and user name this project connects
## with. Returns {ok, changed}: `ok` false means they cancelled.
##
## A box left showing what it showed is "no change", even when that value came
## from the user's own Perforce settings rather than from an earlier choice
## here - so pressing Connect without editing never turns inherited settings
## into stored ones. An emptied box clears the stored value, which is the way
## back to plain P4CONFIG / `p4 set` behaviour.
##
## A changed server or user also drops the stored workspace: workspaces belong
## to a server and, nearly always, to one user.
func _edit_connection() -> Dictionary:
	var shown_port: String = await _suggest_port()
	var shown_user := _override_user if not _override_user.is_empty() else _p4_user
	var res: Dictionary = await _show_connection_dialog(shown_port, shown_user)
	if not res.ok:
		return {"ok": false, "changed": false}
	# An untouched box keeps whatever was stored (possibly nothing). Emptying a
	# box that showed an inherited value stores nothing either, so it isn't a
	# change.
	var new_port := String(res.port) if String(res.port) != shown_port else _override_port
	var new_user := String(res.user) if String(res.user) != shown_user else _override_user
	var changed := new_port != _override_port or new_user != _override_user
	if changed:
		_override_port = new_port
		_override_user = new_user
		_override_client = ""
		_log("Connection settings changed - reconnecting...")
		_reset_connection_state()
		# Saved now, not when setup next succeeds: setup can stop at a login
		# prompt or an empty workspace list, and a restart would then bring the
		# old server back.
		_save_connection_overrides()
	return {"ok": true, "changed": changed}


## Everything cached about the old server or workspace is wrong once the
## connection changes. Leaves the plugin "not connected" until setup re-probes.
func _reset_connection_state() -> void:
	_checked_out_this_session.clear()
	_declined_this_session.clear()
	_pending_save_checkout.clear()
	_prewrite_eligible_cache.clear()
	_fstat_cache.clear()
	_fstat_failed.clear()
	_external_scan_dismissed = ""
	_unreachable_until_msec = 0
	_p4_available = false
	_update_conn_status()


## The interactive login loop: password prompt -> `p4 login` (password fed via
## the stdin temp-file plumbing, so it never appears on a command line or in
## the log) -> retry on a wrong password. Returns true once logged in.
func _login_flow() -> bool:
	var who := _p4_user if not _p4_user.is_empty() else \
			(_override_user if not _override_user.is_empty() else "your Perforce user")
	var where := "" if _p4_port.is_empty() else (" on %s" % _p4_port)
	while true:
		var res: Dictionary = await _show_input_dialog("P4 Login",
				"Perforce needs you to log in again%s.\nPassword for %s:" % [where, who],
				"", false, "Log In", true)
		if not res.ok:
			return false
		var result: Dictionary = await _p4_exec_spec(["login"], String(res.text) + "\n")
		if result.exit_code == 0:
			_log("Logged in to Perforce as %s." % who)
			return true
		var msg := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		if msg.contains("doesn't exist"):
			# Wrong Perforce user (e.g. the OS username default). Let them fix
			# the user name and go around again.
			var ures: Dictionary = await _show_input_dialog("P4 Login",
					"That Perforce user doesn't exist on %s.\nUser name to log in as:" % _p4_port,
					who, false, "Set User")
			if ures.ok and not String(ures.text).strip_edges().is_empty():
				_override_user = String(ures.text).strip_edges()
				who = _override_user
				continue
		await _show_alert(("Perforce didn't accept that:\n\n%s\n\nYou can try again in a " +
				"moment. If it keeps failing, ask whoever runs your Perforce server to " +
				"reset your password.") % msg)
	return false # unreachable; while-true exits via return


## Auto-prompt wrapper used when the ticket dies mid-session: single-flight,
## and a cancel suppresses further auto-prompts until the user presses Refresh.
func _offer_login() -> void:
	if _login_prompt_active or _login_declined or _setup_active or _shutting_down:
		return
	_login_prompt_active = true
	if await _login_flow():
		_p4_available = true
		_update_conn_status()
		_request_refresh()
	else:
		_login_declined = true
		_log("Login declined - Perforce operations will fail until you log in. Press Refresh to try again.")
	_login_prompt_active = false


## p4's standard messages for a missing/expired/revoked auth ticket.
func _looks_like_login_error(result: Dictionary) -> bool:
	if int(result.get("exit_code", 0)) == 0:
		return false
	for chunk in result.get("output", []):
		var text := String(chunk)
		if text.contains("please login again") \
				or text.contains("Perforce password (P4PASSWD) invalid or unset"):
			return true
	return false


## Called after every plain p4 result: a dead-ticket failure pops one re-login
## prompt. (Spec-stdin commands skip this - `p4 login` itself is one of them.)
func _maybe_offer_login(result: Dictionary) -> void:
	if _looks_like_login_error(result):
		_offer_login()


## p4 global flags for the stored connection overrides; prepended to every
## command. Empty overrides mean plain inherited configuration, unchanged.
## Also: `-vnet.maxwait` makes p4 give up on a server that stops answering (it
## bounds each network read; verified: "TCP receive exceeded maximum configured
## duration"). It can't shorten the OS's TCP connect timeout (~21 s on
## Windows) for an unreachable host - the circuit breaker covers that.
func _with_connection_flags(args: PackedStringArray, maxwait_sec: int = NET_MAXWAIT_SEC) -> PackedStringArray:
	# maxwait_sec <= 0: no read limit at all (see _p4_exec_streamed).
	var flags := PackedStringArray()
	if maxwait_sec > 0:
		flags.append("-vnet.maxwait=%d" % maxwait_sec)
	if not _override_port.is_empty():
		flags.append_array(["-p", _override_port])
	if not _override_user.is_empty():
		flags.append_array(["-u", _override_user])
	if not _override_client.is_empty():
		flags.append_array(["-c", _override_client])
	var combined := flags.duplicate()
	combined.append_array(args)
	return combined


## Circuit breaker: after a connect failure or network timeout, the blocking
## pre-save calls and background status queries skip the server for a minute,
## so a dropped VPN costs one ~21 s wait instead of one per command.
func _note_connectivity(result: Dictionary) -> void:
	var text := "" if result.output.is_empty() else String(result.output[0])
	if text.contains("Connect to server failed") or text.contains("TCP connect to") \
			or text.contains("exceeded maximum configured duration"):
		if not _server_unreachable():
			_log("The Perforce server isn't answering - saves won't wait on it for the next minute (press Refresh to retry sooner).")
		_unreachable_until_msec = Time.get_ticks_msec() + UNREACHABLE_BACKOFF_MSEC
	elif int(result.get("exit_code", -1)) == 0:
		_unreachable_until_msec = 0


func _server_unreachable() -> bool:
	return _unreachable_until_msec != 0 and Time.get_ticks_msec() < _unreachable_until_msec


## A fast failure for a status query skipped by the circuit breaker. Worded
## like p4's own connect failure so every caller treats it as "unknown".
func _skipped_result() -> Dictionary:
	return {"exit_code": 1, "output": ["Perforce client error:\n\tConnect to server failed; " +
			"check $P4PORT. (P4Godot skipped this: the server wasn't answering moments ago.)"]}


# ---------------------------------------------------------------------------
# Where the connection overrides live
#
# The server, user and workspace this project should connect as are one
# person's business, not the team's. They used to sit with the other settings
# in the project's metadata, which is a file inside `.godot/` - so a team that
# submitted `.godot/` (against the advice in the README, but it happens) gave
# every teammate this machine's user name and workspace, and they would all
# try to connect as each other.
#
# They live in the editor's own per-user config folder now, in one file keyed
# by the project's path, so they follow the person rather than the project.
# Anything left in the old place is moved on first load and blanked there.
# ---------------------------------------------------------------------------

func _connection_store_path() -> String:
	return EditorInterface.get_editor_paths().get_config_dir().path_join(
			"p4godot").path_join("connections.cfg")


## One section per project, named by a hash of its path so the section name
## can't contain characters a config file would choke on. The readable path
## goes inside the section.
func _project_store_section() -> String:
	return ProjectSettings.globalize_path("res://").sha256_text()


func _save_connection_overrides() -> void:
	var path := _connection_store_path()
	var cfg := ConfigFile.new()
	cfg.load(path) # keep the other projects already in the file
	var section := _project_store_section()
	cfg.set_value(section, "project", ProjectSettings.globalize_path("res://"))
	cfg.set_value(section, "port", _override_port)
	cfg.set_value(section, "user", _override_user)
	cfg.set_value(section, "client", _override_client)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := cfg.save(path)
	if err != OK:
		_log("Warning: couldn't save the Perforce connection settings to '%s' (error %d)."
				% [path, err])


func _load_connection_overrides() -> void:
	var cfg := ConfigFile.new()
	var section := _project_store_section()
	if cfg.load(_connection_store_path()) == OK and cfg.has_section(section):
		_override_port = String(cfg.get_value(section, "port", ""))
		_override_user = String(cfg.get_value(section, "user", ""))
		_override_client = String(cfg.get_value(section, "client", ""))
		return
	# Nothing stored for this project yet. Take whatever the old in-project
	# location holds, move it, and blank it there so submitting `.godot/`
	# can't spread it.
	var settings := EditorInterface.get_editor_settings()
	_override_port = settings.get_project_metadata(SETTINGS_SECTION, "override_port", "")
	_override_user = settings.get_project_metadata(SETTINGS_SECTION, "override_user", "")
	_override_client = settings.get_project_metadata(SETTINGS_SECTION, "override_client", "")
	if _override_port.is_empty() and _override_user.is_empty() and _override_client.is_empty():
		return
	_log("Moved this project's Perforce connection settings out of .godot/ and into your own editor config.")
	_save_connection_overrides()
	for key in ["override_port", "override_user", "override_client"]:
		settings.set_project_metadata(SETTINGS_SECTION, key, "")


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
	var settings := EditorInterface.get_editor_settings()
	auto_checkout_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "auto_checkout_on_edit", true)
	checkout_on_save_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "checkout_on_save", true)
	verbose_log_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "verbose_log", false)
	auto_open_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "auto_open_no_prompt", false)
	detect_external_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "detect_external_changes", true)
	_verbose_log = verbose_log_checkbox.button_pressed
	_load_connection_overrides()


func _on_setting_toggled(_pressed: bool) -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_project_metadata(SETTINGS_SECTION, "auto_checkout_on_edit",
			auto_checkout_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "checkout_on_save",
			checkout_on_save_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "verbose_log",
			verbose_log_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "auto_open_no_prompt",
			auto_open_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "detect_external_changes",
			detect_external_checkbox.button_pressed)
	_verbose_log = verbose_log_checkbox.button_pressed


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


## Scratch folder for pre-write backups and temporary p4 spec files. Swept of
## stale leftovers (a crash mid-save or mid-login) at startup.
func _p4godot_cache_dir() -> String:
	var dir := OS.get_cache_dir().path_join("p4godot")
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
		if OS.get_name() != "Windows":
			# Backups and the login spec live here: owner-only (rwx------).
			FileAccess.set_unix_permissions(dir, FileAccess.UNIX_READ_OWNER
					| FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER)
	return dir


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
					"'P4: Check Out' - or press \"Reconcile...\" in the P4G panel - so the " +
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
		_log("File(s) remain unsaved. Check them out (FileSystem dock 'P4: Check Out', or `p4 edit`) when you're ready.")
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
				"it, right-click the file in the FileSystem dock and choose 'P4: Check " +
				"Out' - or press \"Reconcile...\" in the P4G panel - so the change joins " +
				"your list of pending changes.") % [res_path, result.reason])


# ---------------------------------------------------------------------------
# Dock UI
# ---------------------------------------------------------------------------

func _build_dock() -> void:
	dock = VBoxContainer.new()
	dock.name = "P4G"

	# Toolbar: one row when everything fits, two when the dock is narrow. Per-
	# file actions live in the tree's right-click menu (and the FileSystem
	# dock), not here - the toolbar carries only the project-wide operations,
	# with connection status and settings on the right. _update_toolbar_layout
	# reparents _toolbar_actions between the rows as the dock resizes.
	_toolbar = VBoxContainer.new()
	dock.add_child(_toolbar)
	_toolbar_top = HBoxContainer.new()
	_toolbar.add_child(_toolbar_top)
	_toolbar_second = HBoxContainer.new()
	_toolbar_second.visible = false
	_toolbar.add_child(_toolbar_second)

	_toolbar_actions = HBoxContainer.new()
	_toolbar_top.add_child(_toolbar_actions)
	_add_toolbar_button(_toolbar_actions, "Reload", "Refresh",
			"Refresh: re-query Perforce and rebuild the changelist view.",
			_on_refresh_pressed, true)
	new_changelist_button = _add_toolbar_button(_toolbar_actions, "Add", "New Changelist...",
			"Create a new empty pending changelist.",
			_on_new_changelist_pressed)
	_toolbar_actions.add_child(VSeparator.new())
	# First in the row because it is the first step of the day's loop: get
	# everyone else's work before you start changing things.
	get_latest_button = _add_toolbar_button(_toolbar_actions, "", "Get Latest...",
			"Download every file in this project that someone else has submitted (p4 sync).",
			_on_get_latest_pressed)
	reconcile_button = _add_toolbar_button(_toolbar_actions, "", "Reconcile...",
			"Find files changed on disk and open them for add/edit/delete in Perforce.",
			_on_reconcile_pressed)
	revert_unchanged_button = _add_toolbar_button(_toolbar_actions, "", "Revert Unchanged...",
			"Revert opened files that have no actual changes (p4 revert -a).",
			_on_revert_unchanged_pressed)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar_top.add_child(spacer)

	_toolbar_right = HBoxContainer.new()
	_toolbar_top.add_child(_toolbar_right)
	# Shown only while a submit or download is running with its progress
	# window closed: the window holds the only Cancel, so there has to be a
	# way back to it.
	_progress_show_button = Button.new()
	_progress_show_button.text = "Transfer running..."
	_progress_show_button.tooltip_text = "A submit or download is still running. Click to show its progress and the Cancel button."
	_progress_show_button.visible = false
	_progress_show_button.pressed.connect(_on_progress_show_pressed)
	_toolbar_right.add_child(_progress_show_button)
	conn_status_button = Button.new()
	conn_status_button.flat = true
	conn_status_button.pressed.connect(_on_conn_status_pressed)
	_toolbar_right.add_child(conn_status_button)
	_update_conn_status()
	_toolbar_right.add_child(VSeparator.new())
	_build_settings_menu(_toolbar_right)
	_add_toolbar_button(_toolbar_right, "", "Log",
			"Show or hide the P4 activity log window.",
			_on_toggle_log_pressed)

	_toolbar.resized.connect(_on_toolbar_resized)

	# The setting checkboxes stay real nodes - self-tests poke them, hot paths
	# and _load_settings read/write them - but the row is hidden: the gear menu
	# above is their visible face.
	var settings_row := HFlowContainer.new()
	settings_row.visible = false
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

	verbose_log_checkbox = CheckBox.new()
	verbose_log_checkbox.text = "Verbose log"
	verbose_log_checkbox.tooltip_text = "Log every p4 command and its output, including read-only status probes (fstat/opened/where/changes). When off, only state-changing commands are logged."
	verbose_log_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(verbose_log_checkbox)

	auto_open_checkbox = CheckBox.new()
	auto_open_checkbox.text = "Auto add/edit/delete"
	auto_open_checkbox.tooltip_text = "When on, edits, deletes, and moves/renames are opened in Perforce automatically, with no confirmation dialog. When off, deletes and moves prompt first (and edits follow 'Checkout on edit')."
	auto_open_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(auto_open_checkbox)

	detect_external_checkbox = CheckBox.new()
	detect_external_checkbox.text = "Detect external changes"
	detect_external_checkbox.tooltip_text = "When Godot regains focus, look for files changed by other programs (Photoshop, Blender, a text editor) and offer to check them out."
	detect_external_checkbox.button_pressed = true
	detect_external_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(detect_external_checkbox)

	_build_tree()

	# The log lives in its own on-demand Window rather than eating dock space -
	# the toolbar "Log" button toggles it. log_box stays a member (so _log() is
	# untouched) and exists from here on regardless of the window's visibility.
	_build_log_window()
	_build_diff_window()

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


## A flat toolbar button. With `icon_only` the editor-theme icon replaces the
## label (tooltip carries the name); a missing icon falls back to the label so
## the button is never blank.
func _add_toolbar_button(parent: Control, icon_name: String, text: String,
		tooltip: String, handler: Callable, icon_only: bool = false) -> Button:
	var button := Button.new()
	button.flat = true
	button.tooltip_text = tooltip
	button.pressed.connect(handler)
	var icon: Texture2D = null if icon_name.is_empty() else _theme_icon(icon_name)
	if icon:
		button.icon = icon
		if not icon_only:
			button.text = text
	else:
		button.text = text
	parent.add_child(button)
	return button


## Menu id of the one settings-menu item that isn't a checkbox (ids 0-4 are).
const SETTINGS_MENU_CONNECTION := 10


## The gear menu fronting the setting checkboxes. Checkable popup items
## sync from the checkboxes on open and toggle them on click, so the existing
## persistence (_on_setting_toggled) and every reader stay untouched.
func _build_settings_menu(parent: Control) -> void:
	settings_menu = MenuButton.new()
	settings_menu.flat = true
	settings_menu.tooltip_text = "P4Godot settings (stored per-project, per-user)."
	var gear := _theme_icon("Tools")
	if gear:
		settings_menu.icon = gear
	else:
		settings_menu.text = "Settings"
	var popup := settings_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	popup.add_check_item("Checkout on edit", 0)
	popup.add_check_item("Checkout on save", 1)
	popup.add_check_item("Auto add/edit/delete", 2)
	popup.add_check_item("Detect external changes", 3)
	popup.add_check_item("Verbose log", 4)
	popup.set_item_tooltip(0, "Offer to check out a file the moment it is first modified in the editor.")
	popup.set_item_tooltip(1, "Automatically check out edited files right before the editor writes them.")
	popup.set_item_tooltip(2, "Open edits, deletes, and moves in Perforce silently, with no confirmation dialogs.")
	popup.set_item_tooltip(3, "When Godot regains focus, look for files changed by other programs and offer to check them out.")
	popup.set_item_tooltip(4, "Log read-only status probes too, not just state-changing commands.")
	popup.add_separator()
	popup.add_item("Connection settings...", SETTINGS_MENU_CONNECTION)
	popup.set_item_tooltip(popup.get_item_index(SETTINGS_MENU_CONNECTION),
			"Change the Perforce server, user, or workspace this project uses.")
	popup.about_to_popup.connect(_sync_settings_menu)
	popup.id_pressed.connect(_on_settings_menu_id_pressed)
	parent.add_child(settings_menu)


func _settings_menu_checkbox(id: int) -> CheckBox:
	match id:
		0: return auto_checkout_checkbox
		1: return checkout_on_save_checkbox
		2: return auto_open_checkbox
		3: return detect_external_checkbox
		4: return verbose_log_checkbox
	return null


func _sync_settings_menu() -> void:
	var popup := settings_menu.get_popup()
	for id in 5:
		var cb := _settings_menu_checkbox(id)
		popup.set_item_checked(popup.get_item_index(id), cb != null and cb.button_pressed)


func _on_settings_menu_id_pressed(id: int) -> void:
	if id == SETTINGS_MENU_CONNECTION:
		_open_connection_settings()
		return
	var cb := _settings_menu_checkbox(id)
	if cb:
		# Setting button_pressed emits toggled, which persists the change.
		cb.button_pressed = not cb.button_pressed
		_sync_settings_menu()


## Reflect the connection in the toolbar status button: who we are when
## connected, an invitation to set up when not.
func _update_conn_status() -> void:
	if conn_status_button == null:
		return
	if _p4_available:
		conn_status_button.text = "%s @ %s" % [_p4_user, _p4_client]
		conn_status_button.icon = _theme_icon("StatusSuccess")
		conn_status_button.tooltip_text = "Connected to %s as %s, workspace %s.\nClick to change the connection." \
				% [_p4_port, _p4_user, _p4_client]
	elif _identity_checked:
		conn_status_button.text = "Not connected"
		conn_status_button.icon = _theme_icon("StatusError")
		conn_status_button.tooltip_text = "Perforce is not connected. Click to run connection setup."
	else:
		conn_status_button.text = "Connecting..."
		conn_status_button.icon = null
		conn_status_button.tooltip_text = "Waiting for the startup p4 info probe."


func _on_conn_status_pressed() -> void:
	_login_declined = false
	if _p4_available and not _setup_active:
		# Connected: a click means "use a different workspace" - and from that
		# dialog, a different server or user. (Setup alone would stop at its
		# first probe, which already says "ok".)
		_setup_active = true
		var old_client := _p4_client
		var picked := await _pick_client()
		_setup_active = false
		if not picked:
			return
		# Still connected means the server and user are untouched (changing
		# either disconnects), so only the workspace can have changed.
		if _p4_available:
			if _override_client == old_client:
				return
			_reset_connection_state()
	_offer_connection_setup()


## Settings menu > "Connection settings...": the server and user first, then
## on to the workspace. Unlike the status button, this works the same whether
## or not the plugin is connected - it is the way out when setup keeps stopping
## at a login prompt for a server that was never the right one.
func _open_connection_settings() -> void:
	_login_declined = false
	if _setup_active:
		return
	_setup_active = true
	var edited: Dictionary = await _edit_connection()
	_setup_active = false
	if not edited.ok:
		return
	if edited.changed or not _p4_available:
		_offer_connection_setup()
	else:
		await _on_conn_status_pressed()


func _on_toolbar_resized() -> void:
	# resized fires mid-layout; reparenting there is unsafe. Decide after the
	# layout pass settles. (Repeat deferrals coalesce via the mode check.)
	call_deferred("_update_toolbar_layout")


## One toolbar row when everything fits, two when the dock is narrow: the
## action buttons drop to a second row while connection status, settings, and
## Log hold the top. Conditional reparenting rather than an HFlowContainer,
## because flow wraps left-to-right and would push the status cluster - not
## the buttons - onto the second row. The minimum-width math uses the two
## clusters' own minimums, so it is independent of which row the actions are
## currently in and the mode can't oscillate.
func _update_toolbar_layout() -> void:
	if _shutting_down or not is_instance_valid(_toolbar) \
			or not is_instance_valid(_toolbar_actions):
		return
	var one_row_min: float = _toolbar_actions.get_combined_minimum_size().x \
			+ _toolbar_right.get_combined_minimum_size().x + 16.0
	var narrow: bool = _toolbar.size.x < one_row_min
	if narrow == _toolbar_wrapped:
		return
	_toolbar_wrapped = narrow
	_toolbar_actions.get_parent().remove_child(_toolbar_actions)
	if narrow:
		_toolbar_second.add_child(_toolbar_actions)
	else:
		_toolbar_top.add_child(_toolbar_actions)
		_toolbar_top.move_child(_toolbar_actions, 0)
	_toolbar_second.visible = narrow


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
	_add_toolbar_button(log_tools, "", "Clear Log", "Empty the P4 activity log.", _on_clear_log_pressed)

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
# Transfer progress window
#
# Shown while a submit or a whole-project sync runs. It is not modal: the
# editor stays usable, and closing the window hides it without stopping the
# transfer. It answers the two things a long transfer leaves a person
# wondering - is it still working, and how far along is it - and it is the
# only place a running p4 can be stopped from.
# ---------------------------------------------------------------------------

## How long with no progress line before the window says so. Not a failure:
## a server-side check or one very large file can be quiet for longer.
const PROGRESS_QUIET_SEC := 60

var _progress_window: Window
var _progress_headline: Label
var _progress_bar: ProgressBar
var _progress_detail: Label
var _progress_file: Label
var _progress_quiet: Label
var _progress_cancel_button: Button
var _progress_show_button: Button
var _progress_timer: Timer
# True from _progress_begin to _progress_end. One transfer at a time: the
# window, the tracker and the Cancel button all belong to a single p4, and a
# second one started alongside would run with nobody able to see or stop it.
var _transfer_running: bool = false
var _progress_tracker: P4Progress = null
var _progress_started_msec: int = 0
var _progress_last_activity_msec: int = 0
# Set by _progress_note: the transfer is over and something else is going on
# (asking the server what became of a submit), so there is nothing to count.
var _progress_note_text: String = ""


func _build_progress_window() -> void:
	_progress_window = Window.new()
	_progress_window.title = "Perforce"
	_progress_window.size = Vector2i(560, 200)
	_progress_window.visible = false
	_progress_window.unresizable = false
	# Closing HIDES it. The transfer carries on, and the Log says so.
	_progress_window.close_requested.connect(_on_progress_window_close_requested)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	_progress_window.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	_progress_headline = Label.new()
	box.add_child(_progress_headline)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.custom_minimum_size = Vector2(0, 22)
	box.add_child(_progress_bar)
	_progress_detail = Label.new()
	box.add_child(_progress_detail)
	_progress_file = Label.new()
	_progress_file.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_progress_file.clip_text = true
	_progress_file.add_theme_color_override("font_color", _dim_color())
	box.add_child(_progress_file)
	_progress_quiet = Label.new()
	_progress_quiet.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_progress_quiet.visible = false
	box.add_child(_progress_quiet)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	_progress_cancel_button = Button.new()
	_progress_cancel_button.text = "Cancel"
	_progress_cancel_button.pressed.connect(_on_progress_cancel_pressed)
	buttons.add_child(_progress_cancel_button)

	_progress_timer = Timer.new()
	_progress_timer.wait_time = 0.25
	_progress_timer.timeout.connect(_progress_refresh)
	_progress_window.add_child(_progress_timer)
	# Child of dock, so dock.queue_free() in _exit_tree() cascades to it.
	dock.add_child(_progress_window)


## Open the window for a transfer `tracker` will be fed the progress of.
func _progress_begin(title: String, headline: String, tracker: P4Progress) -> void:
	if _progress_window == null:
		_build_progress_window()
	_transfer_running = true
	_progress_show_button.visible = false
	_progress_tracker = tracker
	_progress_note_text = ""
	_progress_started_msec = Time.get_ticks_msec()
	_progress_last_activity_msec = _progress_started_msec
	_progress_window.title = title
	_progress_headline.text = headline
	_progress_cancel_button.disabled = false
	_progress_cancel_button.text = "Cancel"
	_progress_cancel_button.visible = true
	_progress_refresh()
	_progress_timer.start()
	if DisplayServer.get_name() != "headless":
		_progress_window.popup_centered()


## The transfer is over but the work isn't (the server is being asked what
## became of a submit): keep the window up, with `text` and a bar that only
## shows activity. Cancel is hidden, because there is no p4 left to stop.
func _progress_note(text: String) -> void:
	if _shutting_down or not is_instance_valid(_progress_window):
		return
	_progress_note_text = text
	_progress_cancel_button.visible = false
	_progress_refresh()


func _progress_end() -> void:
	_transfer_running = false
	if _shutting_down or not is_instance_valid(_progress_window):
		return
	_progress_timer.stop()
	_progress_tracker = null
	_progress_show_button.visible = false
	_progress_window.hide()


## The gate every transfer goes through before it starts. False, with an
## explanation, if another one is still running.
func _transfer_slot_free() -> bool:
	if not _transfer_running:
		return true
	_on_progress_show_pressed()
	await _show_alert("A submit or download is already running. Wait for it to finish, " +
			"or cancel it from its progress window, then try again.")
	return false


func _on_progress_window_close_requested() -> void:
	_progress_window.hide()
	_progress_show_button.visible = _transfer_running
	_log("Progress window closed - the transfer is still running. \"Transfer running...\" in the P4G toolbar brings the window back.")


func _on_progress_show_pressed() -> void:
	if is_instance_valid(_progress_window) and _transfer_running \
			and DisplayServer.get_name() != "headless":
		_progress_show_button.visible = false
		_progress_window.popup_centered()


func _on_progress_cancel_pressed() -> void:
	# Nothing to stop between p4 runs (a retry pass, or the questions asked of
	# the server afterwards): leave the button as it is.
	if _streamed_req == null:
		return
	_progress_cancel_button.disabled = true
	_progress_cancel_button.text = "Cancelling..."
	_log("Cancel requested - stopping p4.")
	_cancel_streamed()


## Redraw from the tracker. Runs on a timer, not on each progress line: a sync
## of thousands of small files reports thousands of lines a second.
func _progress_refresh() -> void:
	if _shutting_down or not is_instance_valid(_progress_window) or _progress_tracker == null:
		return
	var now := Time.get_ticks_msec()
	var elapsed := (now - _progress_started_msec) / 1000.0
	if not _progress_note_text.is_empty():
		_progress_bar.indeterminate = true
		_progress_detail.text = _progress_note_text
		_progress_file.text = ""
		_progress_quiet.visible = false
		return
	var t := _progress_tracker
	# Until p4 reports something there is nothing to measure: the server is
	# locking files, or this p4 is too old to report. Show activity, not 0%.
	_progress_bar.indeterminate = not t.reporting
	_progress_bar.value = t.fraction() * 100.0
	_progress_detail.text = _progress_detail_text(t, elapsed)
	_progress_file.text = t.current.get_file() if not t.current.is_empty() else ""
	var quiet_sec := (now - _progress_last_activity_msec) / 1000.0
	_progress_quiet.visible = quiet_sec >= PROGRESS_QUIET_SEC
	if _progress_quiet.visible:
		_progress_quiet.text = ("Nothing has been reported for %s. That isn't a failure: the " +
				"server may be running a check, or working through one large file. Cancel " +
				"stops it if you'd rather not wait.") % _duration_text(quiet_sec)


## "37 of 212 files  -  410 MB of 1.9 GB  -  1:23". Pure, so a self-test can
## pin what the user is shown.
static func _progress_detail_text(t: P4Progress, elapsed_sec: float) -> String:
	var parts := PackedStringArray()
	if not t.reporting:
		parts.append("Working...")
	else:
		var files := t.expected_files()
		if files > 0:
			parts.append("%d of %d file%s" % [mini(t.files_done, files), files,
					"" if files == 1 else "s"])
		var bytes := t.expected_bytes()
		if bytes > 0:
			parts.append("%s of %s" % [_human_bytes(t.bytes_done()), _human_bytes(bytes)])
	parts.append(_duration_text(elapsed_sec))
	return "  -  ".join(parts)


## "0:07", "1:23", "1:02:05".
static func _duration_text(seconds: float) -> String:
	var s := int(seconds)
	@warning_ignore("integer_division")
	var h := s / 3600
	@warning_ignore("integer_division")
	var m := (s % 3600) / 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s % 60]
	return "%d:%02d" % [m, s % 60]


## One sentence on what a finished transfer moved, for the Log and the final
## report. The network figure comes from the server's tracking output and is
## only shown when it says something: it reads 0 for a parallel transfer, and
## it is in whole megabytes. When it is well under the size of the files, say
## why - that difference is Delta Transfer (or compression) doing its job.
static func _transfer_summary(t: P4Progress) -> String:
	var files := t.expected_files()
	var bytes := t.expected_bytes()
	if files <= 0:
		return ""
	var text := "%d file%s, %s." % [files, "" if files == 1 else "s", _human_bytes(bytes)]
	if t.network_mb > 0:
		text += " About %d MB crossed the network." % t.network_mb
		var mb := bytes / 1048576.0
		if mb >= 4.0 and float(t.network_mb) <= mb * 0.6:
			text += (" That is less than the files' size because Perforce compressed them " +
					"or sent only the parts that changed%s.") \
					% (" (Delta Transfer)" if t.delta_files > 0 else "")
	return text


# ---------------------------------------------------------------------------
# Diff viewer
# ---------------------------------------------------------------------------

# Side-by-side row backgrounds (alpha over the darkened pane base).
const DIFF_BG_DEL := Color(0.60, 0.14, 0.14, 0.42)
const DIFF_BG_ADD := Color(0.16, 0.55, 0.22, 0.38)
const DIFF_BG_FILL := Color(0.5, 0.5, 0.55, 0.10) # alignment filler rows
const DIFF_GUTTER_COLS := 7 # "12345  " line-number prefix baked into each line
const DIFF_CONTEXT_KEEP := 3 # context lines kept around each change when collapsed


## Per-character foreground coloring for the diff panes: dims the baked-in
## line-number gutter and brightens the changed span of paired lines. Plain
## data driven - _populate_diff_panes fills line_spans per rebuild.
class P4DiffHighlighter extends SyntaxHighlighter:
	# line index -> Array of [start_col, end_col, Color]
	var line_spans: Dictionary = {}
	var default_color := Color(0.83, 0.84, 0.88)
	var gutter_color := Color(0.55, 0.57, 0.62, 0.8)

	func _get_line_syntax_highlighting(line: int) -> Dictionary:
		var map := {}
		map[0] = {"color": gutter_color}
		map[DIFF_GUTTER_COLS] = {"color": default_color}
		for s: Array in line_spans.get(line, []):
			map[int(s[0])] = {"color": s[2]}
			map[int(s[1])] = {"color": default_color}
		return map


## The diff window: a p4merge-style side-by-side view. Left pane is the depot
## revision you have, right pane the workspace file, rows aligned by the p4
## diff hunks (the shorter side of a change is padded with filler rows),
## full-row backgrounds mark adds/deletes, and within a changed line pair the
## span that actually differs is brightened. Repopulated and popped per diff.
func _build_diff_window() -> void:
	diff_window = Window.new()
	diff_window.title = "P4 Diff"
	diff_window.size = Vector2i(1160, 640)
	diff_window.visible = false
	diff_window.close_requested.connect(_on_diff_window_close_requested)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	diff_window.add_child(root)

	# Nav row: hop between changes p4merge-style; toggle between the compact
	# changes-only view (default) and the full file.
	var nav := HBoxContainer.new()
	root.add_child(nav)
	diff_prev_button = _add_toolbar_button(nav, "MoveUp", "Previous",
			"Jump to the previous change.", _on_diff_prev_pressed)
	diff_next_button = _add_toolbar_button(nav, "MoveDown", "Next",
			"Jump to the next change.", _on_diff_next_pressed)
	diff_change_label = Label.new()
	nav.add_child(diff_change_label)
	var nav_spacer := Control.new()
	nav_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(nav_spacer)
	diff_full_file_toggle = CheckButton.new()
	diff_full_file_toggle.text = "Full file"
	diff_full_file_toggle.tooltip_text = "Show the whole file. When off, unchanged runs collapse to '... N unchanged lines ...' markers with %d context lines around each change." % DIFF_CONTEXT_KEEP
	diff_full_file_toggle.toggled.connect(_on_diff_full_file_toggled)
	nav.add_child(diff_full_file_toggle)

	var headers := HBoxContainer.new()
	root.add_child(headers)
	diff_left_label = Label.new()
	diff_left_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_left_label.clip_text = true
	headers.add_child(diff_left_label)
	diff_right_label = Label.new()
	diff_right_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_right_label.clip_text = true
	headers.add_child(diff_right_label)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	diff_left = _make_diff_pane()
	split.add_child(diff_left)
	diff_right = _make_diff_pane()
	split.add_child(diff_right)

	# Either pane scrolls both (rows are 1:1 after alignment padding).
	diff_left.get_v_scroll_bar().value_changed.connect(
			_on_diff_pane_scrolled.bind(diff_right, true))
	diff_right.get_v_scroll_bar().value_changed.connect(
			_on_diff_pane_scrolled.bind(diff_left, true))
	diff_left.get_h_scroll_bar().value_changed.connect(
			_on_diff_pane_scrolled.bind(diff_right, false))
	diff_right.get_h_scroll_bar().value_changed.connect(
			_on_diff_pane_scrolled.bind(diff_left, false))

	dock.add_child(diff_window)


func _make_diff_pane() -> TextEdit:
	var te := TextEdit.new()
	te.editable = false
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var hl := P4DiffHighlighter.new()
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_color("font_color", "Editor"):
		hl.default_color = base.get_theme_color("font_color", "Editor")
	te.syntax_highlighter = hl
	# Monospace so columns line up; fall back to the default font if missing.
	var mono := base.get_theme_font("source", "EditorFonts")
	if mono:
		te.add_theme_font_override("font", mono)
	# A darker base than the editor's default TextEdit so the change bands and
	# text stand out. read_only is the stylebox a non-editable TextEdit draws.
	var style := StyleBoxFlat.new()
	style.bg_color = base.get_theme_color("dark_color_2", "Editor") \
			if base.has_theme_color("dark_color_2", "Editor") else Color(0.09, 0.10, 0.12)
	style.set_content_margin_all(4)
	te.add_theme_stylebox_override("normal", style)
	te.add_theme_stylebox_override("read_only", style)
	return te


func _on_diff_pane_scrolled(value: float, target: TextEdit, vertical: bool) -> void:
	if _diff_scroll_syncing or not is_instance_valid(target):
		return
	_diff_scroll_syncing = true
	if vertical:
		target.get_v_scroll_bar().value = value
	else:
		target.get_h_scroll_bar().value = value
	_diff_scroll_syncing = false


func _on_diff_window_close_requested() -> void:
	diff_window.hide()


## Diff res_path (workspace vs the depot revision you have) and show it side by
## side. `p4 diff -dul` is read-only; the `l` flag ignores line-ending
## differences - Godot always writes LF, so on a Windows client (LineEnd:
## local, CRLF) every line would otherwise count as changed and the diff
## degenerates into remove-all/add-all.
func _diff_path(res_path: String) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var local_path := ProjectSettings.globalize_path(res_path)
	var result := await _p4_exec(["diff", "-dul", local_path])
	var text := "" if result.output.is_empty() else String(result.output[0])
	if not _diff_has_changes(text):
		await _show_alert("'%s' is identical to the version you downloaded from the server - there's nothing to compare." % res_path)
		return
	if text.contains("files differ"):
		await _show_alert("'%s' is different from the version you downloaded, but it isn't text - it's an image, sound or model - so there's nothing to show side by side." % res_path)
		return
	# Revision syntax goes on the depot path from the diff header: it comes back
	# from p4 already escaped (a local path with @/#/% in it can't carry "#have").
	var depot_path := _diff_depot_path(text, "")
	if not depot_path.begins_with("//"):
		await _show_alert("Godot couldn't work out where '%s' lives on the Perforce server, so it can't compare the two. Press \"Log\" in the P4G panel to see what Perforce said." % res_path)
		return
	var have := await _p4_exec(["print", "-q", depot_path + "#have"])
	if have.exit_code != 0:
		await _show_alert("Godot couldn't download the server's copy of '%s' to compare against. Press \"Log\" in the P4G panel to see what Perforce said." % res_path)
		return
	var old_text := "" if have.output.is_empty() else String(have.output[0])
	var f := FileAccess.open(local_path, FileAccess.READ)
	if f == null:
		await _show_alert("Godot couldn't read '%s' from your computer, so it can't compare it. Check the file still exists and isn't open in another program." % res_path)
		return
	var new_text := f.get_as_text()
	f.close()
	_diff_rows = _align_diff(_split_lines(old_text), _split_lines(new_text),
			_parse_unified_hunks(text))
	diff_left_label.text = "  %s#have" % _diff_depot_path(text, res_path)
	diff_right_label.text = "  %s (workspace)" % res_path
	_render_diff()
	diff_window.title = "P4 Diff: %s" % res_path
	diff_window.popup_centered()


## Re-render the stored rows in the current context mode and land on the
## first change.
func _render_diff() -> void:
	var rows := _diff_rows if diff_full_file_toggle.button_pressed \
			else _collapse_context(_diff_rows)
	_populate_diff_panes(rows)
	if not _diff_change_blocks.is_empty():
		_goto_diff_row(int(_diff_change_blocks[0]), 1)
	_update_diff_nav(1)


func _on_diff_full_file_toggled(_pressed: bool) -> void:
	if not _diff_rows.is_empty():
		_render_diff()


## Collapse long unchanged runs to a single "... N unchanged lines ..." marker
## row, keeping DIFF_CONTEXT_KEEP context lines on the side(s) that touch a
## change. Pure row transform - toggling just re-renders the stored rows.
func _collapse_context(rows: Array) -> Array:
	var out: Array = []
	var i := 0
	var n := rows.size()
	while i < n:
		if String(rows[i].kind) != "ctx":
			out.append(rows[i])
			i += 1
			continue
		var j := i
		while j < n and String(rows[j].kind) == "ctx":
			j += 1
		var lead := DIFF_CONTEXT_KEEP if i > 0 else 0 # trailing context of the change above
		var tail := DIFF_CONTEXT_KEEP if j < n else 0 # leading context of the change below
		if j - i > lead + tail + 1:
			for k in range(i, i + lead):
				out.append(rows[k])
			out.append({"kind": "gap", "old_line": 0, "new_line": 0,
					"left": "", "right": "", "count": j - i - lead - tail})
			for k in range(j - tail, j):
				out.append(rows[k])
		else:
			for k in range(i, j):
				out.append(rows[k])
		i = j
	return out


## Center both panes on a rendered row and update the "n / m" readout.
func _goto_diff_row(row: int, ordinal: int) -> void:
	_diff_scroll_syncing = true
	diff_left.set_line_as_center_visible(row)
	diff_right.set_line_as_center_visible(row)
	_diff_scroll_syncing = false
	_update_diff_nav(ordinal)


func _update_diff_nav(ordinal: int) -> void:
	var m := _diff_change_blocks.size()
	diff_change_label.text = "  %d / %d changes" % [ordinal, m] if m > 0 else "  no changes"
	diff_prev_button.disabled = m == 0
	diff_next_button.disabled = m == 0


## Stateless prev/next: measured from what is on screen now, so manual
## scrolling between clicks never causes a jump to somewhere unexpected.
func _on_diff_next_pressed() -> void:
	var center := diff_left.get_first_visible_line() + floori(diff_left.get_visible_line_count() / 2.0)
	for b in _diff_change_blocks.size():
		if int(_diff_change_blocks[b]) > center:
			_goto_diff_row(int(_diff_change_blocks[b]), b + 1)
			return
	if not _diff_change_blocks.is_empty(): # wrap to the first change
		_goto_diff_row(int(_diff_change_blocks[0]), 1)


func _on_diff_prev_pressed() -> void:
	var center := diff_left.get_first_visible_line() + floori(diff_left.get_visible_line_count() / 2.0)
	for b in range(_diff_change_blocks.size() - 1, -1, -1):
		if int(_diff_change_blocks[b]) < center - 1:
			_goto_diff_row(int(_diff_change_blocks[b]), b + 1)
			return
	if not _diff_change_blocks.is_empty(): # wrap to the last change
		var last := _diff_change_blocks.size() - 1
		_goto_diff_row(int(_diff_change_blocks[last]), last + 1)


## Whether `p4 diff` output shows an actual change. A unified diff always has
## an "@@" hunk header when content differs; an unchanged-but-opened file emits
## only the ---/+++ header. "files differ" is p4's binary-difference message.
func _diff_has_changes(text: String) -> bool:
	if text.contains("files differ"):
		return true
	for line in text.split("\n"):
		if line.begins_with("@@"):
			return true
	return false


## The depot path from the diff's "--- //depot/...<TAB>date" header line.
func _diff_depot_path(diff_text: String, fallback: String) -> String:
	for raw_line in diff_text.split("\n"):
		var line := String(raw_line).rstrip("\r")
		if line.begins_with("--- "):
			return line.trim_prefix("--- ").get_slice("\t", 0)
	return fallback


## Split file/print text into display lines: normalize CRLF (p4.exe emits CRLF
## and Godot writes LF) and drop the empty artifact after a trailing newline.
func _split_lines(text: String) -> PackedStringArray:
	var lines := text.replace("\r\n", "\n").split("\n")
	if not lines.is_empty() and lines[lines.size() - 1].is_empty():
		lines.remove_at(lines.size() - 1)
	return lines


## Parse unified-diff hunks into [{old_start, new_start, ops: ["ctx"/"del"/"add"]}].
## File headers before the first "@@" are skipped; "\ No newline" markers too.
func _parse_unified_hunks(diff_text: String) -> Array:
	var hunks: Array = []
	var current: Dictionary = {}
	for raw_line in diff_text.split("\n"):
		var line := String(raw_line).rstrip("\r")
		if line.begins_with("@@"):
			var parts := line.split(" ", false) # ["@@", "-A,B", "+C,D", "@@"]
			if parts.size() < 3:
				continue
			current = {
				"old_start": int(parts[1].trim_prefix("-").get_slice(",", 0)),
				"new_start": int(parts[2].trim_prefix("+").get_slice(",", 0)),
				"ops": [],
			}
			hunks.append(current)
		elif current.is_empty():
			continue # --- / +++ headers (they begin with -/+ but precede any @@)
		elif line.begins_with("-"):
			current.ops.append("del")
		elif line.begins_with("+"):
			current.ops.append("add")
		elif line.begins_with(" "):
			current.ops.append("ctx")
		# "\ No newline at end of file" and the trailing blank are ignored.
	return hunks


## Build the aligned side-by-side rows for the whole file. Each row:
## {kind: "ctx"|"pair"|"del"|"add", old_line, new_line (1-based; 0 = filler),
##  left, right}. Hunks drive the classification and cursor advance; displayed
## text always comes from the actual files, so a drifted diff can misalign a
## region but never show wrong content. Runs of deletes followed by adds are
## paired up ("pair") for intraline highlighting, remainder padded as pure
## del/add rows.
func _align_diff(old_lines: PackedStringArray, new_lines: PackedStringArray,
		hunks: Array) -> Array:
	var rows: Array = []
	var oi := 0
	var ni := 0
	for hunk in hunks:
		var hunk_old: int = int(hunk.old_start) - 1
		while oi < hunk_old and oi < old_lines.size() and ni < new_lines.size():
			rows.append({"kind": "ctx", "old_line": oi + 1, "new_line": ni + 1,
					"left": old_lines[oi], "right": new_lines[ni]})
			oi += 1
			ni += 1
		var dels: Array = []
		var adds: Array = []
		for op: String in hunk.ops:
			match op:
				"ctx":
					_flush_diff_runs(rows, dels, adds)
					if oi < old_lines.size() and ni < new_lines.size():
						rows.append({"kind": "ctx", "old_line": oi + 1, "new_line": ni + 1,
								"left": old_lines[oi], "right": new_lines[ni]})
						oi += 1
						ni += 1
				"del":
					if oi < old_lines.size():
						dels.append([oi + 1, old_lines[oi]])
						oi += 1
				"add":
					if ni < new_lines.size():
						adds.append([ni + 1, new_lines[ni]])
						ni += 1
		_flush_diff_runs(rows, dels, adds)
	while oi < old_lines.size() and ni < new_lines.size():
		rows.append({"kind": "ctx", "old_line": oi + 1, "new_line": ni + 1,
				"left": old_lines[oi], "right": new_lines[ni]})
		oi += 1
		ni += 1
	# Tail imbalance only happens when the diff drifted from the files;
	# show the leftovers honestly rather than dropping them.
	while oi < old_lines.size():
		rows.append({"kind": "del", "old_line": oi + 1, "new_line": 0,
				"left": old_lines[oi], "right": ""})
		oi += 1
	while ni < new_lines.size():
		rows.append({"kind": "add", "old_line": 0, "new_line": ni + 1,
				"left": "", "right": new_lines[ni]})
		ni += 1
	return rows


## Pair up buffered delete/add runs at a run boundary and clear the buffers.
func _flush_diff_runs(rows: Array, dels: Array, adds: Array) -> void:
	var n_pair := mini(dels.size(), adds.size())
	for k in n_pair:
		rows.append({"kind": "pair", "old_line": dels[k][0], "new_line": adds[k][0],
				"left": dels[k][1], "right": adds[k][1]})
	for k in range(n_pair, dels.size()):
		rows.append({"kind": "del", "old_line": dels[k][0], "new_line": 0,
				"left": dels[k][1], "right": ""})
	for k in range(n_pair, adds.size()):
		rows.append({"kind": "add", "old_line": 0, "new_line": adds[k][0],
				"left": "", "right": adds[k][1]})
	dels.clear()
	adds.clear()


## The changed span of a paired line: trim the common prefix and suffix, return
## [Vector2i(start, end) for a, Vector2i(start, end) for b] in character columns.
func _intraline_span(a: String, b: String) -> Array:
	var p := 0
	var max_p := mini(a.length(), b.length())
	while p < max_p and a.unicode_at(p) == b.unicode_at(p):
		p += 1
	var ea := a.length()
	var eb := b.length()
	while ea > p and eb > p and a.unicode_at(ea - 1) == b.unicode_at(eb - 1):
		ea -= 1
		eb -= 1
	return [Vector2i(p, ea), Vector2i(p, eb)]


## Fill both panes from the aligned rows: text with a baked line-number gutter,
## full-row backgrounds, and intraline emphasis spans for paired lines.
func _populate_diff_panes(rows: Array) -> void:
	var left_hl := diff_left.syntax_highlighter as P4DiffHighlighter
	var right_hl := diff_right.syntax_highlighter as P4DiffHighlighter
	left_hl.line_spans.clear()
	right_hl.line_spans.clear()
	var left_text := ""
	var right_text := ""
	var left_bg: Array = []
	var right_bg: Array = []
	var none := Color(0, 0, 0, 0)
	var del_hi := ACTION_DELETE_COLOR.lerp(Color.WHITE, 0.45)
	var add_hi := ACTION_ADD_COLOR.lerp(Color.WHITE, 0.45)
	_diff_change_blocks.clear()
	var in_block := false
	var i := 0
	for r: Dictionary in rows:
		var kind := String(r.kind)
		var changed := kind == "pair" or kind == "del" or kind == "add"
		if changed and not in_block:
			_diff_change_blocks.append(i)
		in_block = changed
		if kind == "gap":
			var marker := "       ... %d unchanged lines ..." % int(r.count)
			left_text += marker + "\n"
			right_text += marker + "\n"
			left_bg.append(DIFF_BG_FILL)
			right_bg.append(DIFF_BG_FILL)
			left_hl.line_spans[i] = [[0, marker.length(), left_hl.gutter_color]]
			right_hl.line_spans[i] = [[0, marker.length(), right_hl.gutter_color]]
			i += 1
			continue
		left_text += ("%5d  %s\n" % [r.old_line, r.left]) if int(r.old_line) > 0 else "\n"
		right_text += ("%5d  %s\n" % [r.new_line, r.right]) if int(r.new_line) > 0 else "\n"
		match kind:
			"pair":
				left_bg.append(DIFF_BG_DEL)
				right_bg.append(DIFF_BG_ADD)
				var spans := _intraline_span(String(r.left), String(r.right))
				left_hl.line_spans[i] = [[spans[0].x + DIFF_GUTTER_COLS,
						spans[0].y + DIFF_GUTTER_COLS, del_hi]]
				right_hl.line_spans[i] = [[spans[1].x + DIFF_GUTTER_COLS,
						spans[1].y + DIFF_GUTTER_COLS, add_hi]]
			"del":
				left_bg.append(DIFF_BG_DEL)
				right_bg.append(DIFF_BG_FILL)
			"add":
				left_bg.append(DIFF_BG_FILL)
				right_bg.append(DIFF_BG_ADD)
			_:
				left_bg.append(none)
				right_bg.append(none)
		i += 1
	diff_left.text = left_text.trim_suffix("\n")
	diff_right.text = right_text.trim_suffix("\n")
	# Backgrounds only apply to existing lines, so this runs after set_text;
	# every line gets an explicit color so nothing lingers from the last diff.
	for line in left_bg.size():
		diff_left.set_line_background_color(line, left_bg[line])
		diff_right.set_line_background_color(line, right_bg[line])
	diff_left.get_v_scroll_bar().value = 0
	diff_left.get_h_scroll_bar().value = 0


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
	tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM
	tree.set_drag_forwarding(_tree_get_drag_data, _tree_can_drop_data, _tree_drop_data)
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
		row.set_text(0, "Perforce unavailable - double-click here to set up the connection.")
		row.set_metadata(0, {"type": "setup"})
		return
	var folder_icon := _theme_icon("Folder")
	var bold := _editor_bold_font()
	var dim := _dim_color()
	for cl in model.changelists:
		var cl_item := tree.create_item(root)
		var label: String = "Default changelist" if cl.change == "default" \
				else "#%s  %s" % [cl.change, cl.desc]
		cl_item.set_text(0, label)
		if bold:
			cl_item.set_custom_font(0, bold)
		var count: int = cl.files.size()
		cl_item.set_text(1, "%d file%s" % [count, "" if count == 1 else "s"])
		cl_item.set_custom_color(1, dim)
		cl_item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		cl_item.set_selectable(1, false)
		cl_item.set_metadata(0, {"type": "cl", "change": cl.change, "desc": cl.desc,
				"file_count": cl.files.size()})
		if folder_icon:
			cl_item.set_icon(0, folder_icon)
			cl_item.set_icon_modulate(0, P4_ACCENT) # the P4 brand touch
		for f in cl.files:
			var f_item := tree.create_item(cl_item)
			# res:// is implied for everything in the tree; dropping it leaves
			# more room for the paths themselves. Tooltip keeps the full story.
			f_item.set_text(0, String(f.res_path).trim_prefix("res://"))
			f_item.set_tooltip_text(0, "%s\n%s" % [f.res_path, f.depot_path])
			f_item.set_text(1, f.action)
			f_item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
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
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_icon(icon_name, "EditorIcons"):
		return base.get_theme_icon(icon_name, "EditorIcons")
	return null


func _editor_bold_font() -> Font:
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_font("bold", "EditorFonts"):
		return base.get_theme_font("bold", "EditorFonts")
	return null


func _dim_color() -> Color:
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_color("font_disabled_color", "Editor"):
		return base.get_theme_color("font_disabled_color", "Editor")
	return Color(0.62, 0.62, 0.67)


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
	if typeof(meta) != TYPE_DICTIONARY:
		return
	if meta.get("type") == "setup":
		_offer_connection_setup()
		return
	if meta.get("type") != "file":
		return
	_open_res_path(meta.res_path)


func _open_res_path(res_path: String) -> void:
	var ext := res_path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		EditorInterface.open_scene_from_path(res_path)
	else:
		var res := ResourceLoader.load(res_path)
		if res:
			EditorInterface.edit_resource(res)


# --- Drag & drop: drag a file row onto another changelist to move it -------

## Drag data for a file row: {type: "p4_file", res_path, change}. Non-file rows
## (changelist headers, the unavailable notice) aren't draggable.
func _tree_get_drag_data(at_position: Vector2) -> Variant:
	var item := tree.get_item_at_position(at_position)
	if item == null:
		return null
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY or meta.get("type") != "file":
		return null
	var preview := Label.new()
	preview.text = "  %s  " % String(meta.res_path)
	var icon := _file_icon(String(meta.res_path))
	if icon:
		var row := HBoxContainer.new()
		var tex := TextureRect.new()
		tex.texture = icon
		tex.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		row.add_child(tex)
		row.add_child(preview)
		tree.set_drag_preview(row)
	else:
		tree.set_drag_preview(preview)
	return {"type": "p4_file", "res_path": meta.res_path, "change": meta.change}


## The changelist a drop at this position would move the file into, or "" when
## the drop is invalid (not our data, not over a row, or the file's own
## changelist). Dropping on a file row targets that row's changelist.
func _tree_drop_target_change(at_position: Vector2, data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY or data.get("type") != "p4_file":
		return ""
	var item := tree.get_item_at_position(at_position)
	if item == null:
		return ""
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return ""
	var target := ""
	if meta.get("type") == "cl" or meta.get("type") == "file":
		target = String(meta.get("change", ""))
	if target.is_empty() or target == String(data.get("change", "")):
		return ""
	return target


func _tree_can_drop_data(at_position: Vector2, data: Variant) -> bool:
	return not _tree_drop_target_change(at_position, data).is_empty()


func _tree_drop_data(at_position: Vector2, data: Variant) -> void:
	var target := _tree_drop_target_change(at_position, data)
	if target.is_empty():
		return
	_move_file_to_changelist(String(data.res_path), target)


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
	CTX_DELETE_CL,
	CTX_DIFF,
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
		context_menu.add_item("Diff vs Depot", CTX_DIFF)
		context_menu.add_item("Revert This File", CTX_REVERT)
		context_menu.add_item("Sync This File", CTX_SYNC)
		context_menu.add_item("Reload From Disk", CTX_RELOAD)
		_populate_move_submenu(String(meta.get("change", "")))
		context_menu.add_submenu_node_item("Move to Changelist", move_submenu)
		context_menu.add_separator()
	elif kind == "cl":
		var fc := int(meta.get("file_count", -1)) # -1 (unknown) is treated non-empty
		if fc != 0:
			context_menu.add_item("Submit Changelist...", CTX_SUBMIT)
		# Editing the default changelist's description promotes it to a numbered one.
		context_menu.add_item("Edit Description...", CTX_EDIT_DESC)
		if String(meta.get("change", "")) != "default" and fc == 0:
			context_menu.add_item("Delete Changelist", CTX_DELETE_CL)
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
		CTX_DIFF:
			if meta.has("res_path"):
				await _diff_path(meta.res_path)
		CTX_REVERT:
			if meta.has("res_path"):
				await _revert_path(meta.res_path)
		CTX_SYNC:
			if meta.has("res_path"):
				await _sync_path(meta.res_path)
		CTX_RELOAD:
			if meta.has("res_path"):
				await _reload_path_confirmed(meta.res_path)
		CTX_EDIT_DESC:
			if meta.has("change"):
				await _edit_changelist_description(meta.change)
		CTX_SUBMIT:
			if meta.get("type") == "cl":
				await _submit_changelist_from_meta(meta)
		CTX_DELETE_CL:
			if meta.has("change"):
				await _delete_changelist(meta.change)
		CTX_REFRESH:
			_refresh_changelists()


func _on_refresh_pressed() -> void:
	_login_declined = false # a manual Refresh re-arms the auto login prompt
	if _identity_checked and not _p4_available:
		_detect_p4_identity() # re-probe; reopens connection setup if still broken
		return
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
	_prewrite_eligible_cache.clear() # Checkout state may have changed - re-fstat on next save.
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
			_sync_opened_cache(model)
		if not _refresh_pending:
			break
	_refresh_inflight = false


## Grey out the p4-dependent action buttons when Perforce is unavailable, so the
## dock is honestly inert instead of offering doomed actions.
func _set_actions_enabled(enabled: bool) -> void:
	for b: Button in [new_changelist_button, get_latest_button, reconcile_button,
			revert_unchanged_button]:
		if b:
			b.disabled = not enabled


## `p4 opened` is the truth about what this workspace has checked out, so a
## successful refresh REPLACES the session cache with it instead of adding to
## it. Growing it only - what earlier versions did - meant a submit or a
## revert done anywhere else (P4V, a terminal, a teammate's script) left the
## file marked checked out here for the rest of the session, and every later
## edit to it was silently ignored.
##
## A refresh racing a checkout can drop an entry that is really open. That
## costs one fstat on the next edit to the file, which re-adds it; keeping a
## stale entry instead loses a checkout, which is the worse trade.
func _sync_opened_cache(model: Dictionary) -> void:
	if not model.get("opened_ok", false):
		return # The query failed - keep what we know rather than forget it.
	var opened_now: Dictionary = {}
	for cl in model.get("changelists", []):
		for f in cl.files:
			opened_now[f.res_path] = true
	_checked_out_this_session = opened_now


# ---------------------------------------------------------------------------
# Manual actions
# ---------------------------------------------------------------------------

## The file the manual buttons act on: the active script when the Script
## editor is in front, otherwise the edited scene.
func _get_current_file_path() -> String:
	var script_editor := EditorInterface.get_script_editor()
	var script := script_editor.get_current_script()
	if script_editor.is_visible_in_tree() and script and not script.resource_path.is_empty():
		return script.resource_path
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root and not scene_root.get_scene_file_path().is_empty():
		return scene_root.get_scene_file_path()
	if script and not script.resource_path.is_empty():
		return script.resource_path
	return ""


## Check out one file: skip if it doesn't need it, otherwise `p4 edit` and surface
## any failure. Shared by the toolbar "Checkout Active File" button and the
## FileSystem-dock context menu.
func _checkout_path(res_path: String) -> void:
	# An imported asset's .import holds its import settings, and the Import dock
	# writes it before any plugin hook runs - so check it out alongside (the
	# FileSystem dock hides .import files, so users can't pick it themselves).
	# Asset first: if it's exclusively locked elsewhere, the .import shouldn't
	# end up opened on its own.
	if not await _needs_checkout(ProjectSettings.globalize_path(res_path)):
		_remember_no_checkout(res_path, ProjectSettings.globalize_path(res_path))
		_log("'%s' doesn't need checkout (already opened by you, or not tracked by Perforce)." % res_path)
	else:
		var result: Dictionary = await _do_checkout(res_path)
		if not result.ok:
			_show_alert(("Perforce won't let you edit '%s' - %s.\n\nMost often that means a " +
					"teammate has it. You can keep working, but Godot can't save this file " +
					"until they're done.") % [res_path, result.reason])
			return
	var import_res := res_path + ".import"
	if FileAccess.file_exists(ProjectSettings.globalize_path(import_res)) \
			and await _needs_checkout(ProjectSettings.globalize_path(import_res)):
		var side: Dictionary = await _do_checkout(import_res)
		if not side.ok:
			_show_alert(("Perforce won't let you edit the import-settings file that goes " +
					"with this asset ('%s') - %s.\n\nYou can still edit the asset itself, " +
					"but changes to its import settings can't be saved yet.")
					% [import_res, side.reason])


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


## Revert res_path in Perforce and reload it from disk. Confirms first, naming
## the exact file, because revert discards unsaved in-editor changes too - the
## user must not lose work in a file they didn't mean to touch. Shared by the
## toolbar "Revert Selected File" button and the tree's per-row context menu.
func _revert_path(res_path: String) -> void:
	var proceed: bool = await _show_confirm_dialog(
			("Throw away your changes to '%s'?\n\nPerforce puts this file back to the " +
			"version on the server. Everything you changed is lost - what you saved as " +
			"well as anything unsaved in the editor - and this can't be undone.") % res_path,
			"Throw Away My Changes", "Cancel")
	if not proceed:
		_log("Revert of '%s' cancelled." % res_path)
		return
	await _p4_exec_logged(["revert", ProjectSettings.globalize_path(res_path)])
	_checked_out_this_session.erase(res_path)
	await _reload_path(res_path)


## Sync res_path to the head revision and reload it from disk. Shared by the
## toolbar "Sync Selected File" button and the tree's per-row context menu.
func _sync_path(res_path: String) -> void:
	var synced: Dictionary = await _safe_sync([ProjectSettings.globalize_path(res_path)])
	var notes: Dictionary = synced.notes
	_request_refresh()
	if not notes.existing.is_empty():
		await _show_alert("Perforce didn't download '%s'.%s" % [res_path,
				_kept_existing_text(notes.existing)])
		return
	var refused: Array = notes.modified + notes.clobbered
	if not refused.is_empty():
		await _show_alert(("Perforce didn't download the newer version of '%s'.\n\nThe file " +
				"is changed on your disk but not checked out, so Perforce left your version " +
				"alone instead of throwing it away. Check it out (right-click it in the " +
				"FileSystem dock and choose \"P4: Check Out\"), then sync it again - Perforce " +
				"will then ask you to combine the two versions.") % res_path)
		return
	# Only a sync that rewrote the file changes anything the editor shows ("up
	# to date", or an opened file getting a resolve scheduled, doesn't).
	var rewrote: bool = int(synced.exit_code) == 0 and not synced.done.names.is_empty()
	if not rewrote:
		return
	EditorInterface.get_resource_filesystem().scan()
	if not _is_open_in_editor(res_path):
		return
	var reload: bool = await _show_confirm_dialog(("Godot just downloaded a newer version of " +
			"'%s' from the server, and the file is open in the editor.\n\nShow the new " +
			"version? Anything you changed but didn't save is lost.\n\nIf you keep what's " +
			"in the editor instead, saving it later overwrites the version you just " +
			"downloaded - your teammate's work.") % res_path,
			"Show New Version", "Keep Editor Version")
	if reload:
		await _reload_path(res_path)
	else:
		_log("Kept the editor's version of '%s' - saving it would overwrite the synced revision." % res_path)


## Whether res_path is open as a scene tab or in the script editor.
func _is_open_in_editor(res_path: String) -> bool:
	if res_path in EditorInterface.get_open_scenes():
		return true
	for s in EditorInterface.get_script_editor().get_open_scripts():
		if (s as Script).resource_path == res_path:
			return true
	return false


## Confirm-then-reload for the user-initiated Reload actions (toolbar button and
## context menu). Reload discards unsaved in-editor changes, so it warns first,
## naming the file. Internal reloads (after revert/sync/decline) call _reload_path
## directly - they either already confirmed or the reload IS the intended effect.
func _reload_path_confirmed(res_path: String) -> void:
	var proceed: bool = await _show_confirm_dialog(
			("Reload '%s' from disk?\n\nThis discards any unsaved changes to this file " +
			"in the editor.") % res_path,
			"Reload", "Cancel")
	if not proceed:
		_log("Reload of '%s' cancelled." % res_path)
		return
	await _reload_path(res_path)


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


## An indented one-per-line listing of paths for confirmation dialogs, capped
## so a huge file set can't grow the dialog past the screen.
func _file_listing(paths: Array, cap: int = 15) -> String:
	var shown: Array = paths.slice(0, cap)
	var listing := ""
	for p in shown:
		listing += "    %s\n" % String(p)
	if paths.size() > shown.size():
		listing += "    ... and %d more\n" % (paths.size() - shown.size())
	return listing.rstrip("\n")


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
		if local.is_empty():
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


## The scan is a full reconcile preview of the project, so it costs real work
## on a large workspace. One every few seconds is plenty for "the user just
## alt-tabbed back".
const EXTERNAL_SCAN_MIN_INTERVAL_MSEC := 5000
## How long an unfinished scan blocks the next one before it's written off.
const EXTERNAL_SCAN_STUCK_MSEC := 300000

var _external_scan_inflight: bool = false
var _external_scan_started_msec: int = 0
var _external_scan_last_msec: int = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC
## The set of changes the user last answered "Not Now" to, so the same set
## doesn't ask again on every alt-tab. Cleared as soon as the set changes.
var _external_scan_dismissed: String = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_scan_for_external_changes("Godot regained focus")


func _detect_external_changes() -> bool:
	return detect_external_checkbox != null and detect_external_checkbox.button_pressed


## Look for files changed outside Godot and offer to open them. Silent when
## there's nothing to report. `reason` shows only in the verbose log.
func _scan_for_external_changes(reason: String) -> void:
	if not _detect_external_changes() or _shutting_down:
		return
	if _external_scan_inflight:
		# A scan waits on dialogs, and a dialog that is freed without
		# answering leaves its awaiting coroutine parked forever. Without this
		# release, one such dialog would turn external-change detection off
		# for the rest of the session with nothing said about it.
		if Time.get_ticks_msec() - _external_scan_started_msec < EXTERNAL_SCAN_STUCK_MSEC:
			return
		_log("The last external-change scan never finished - starting a new one.")
	if _identity_checked and not _p4_available:
		return # p4 was unavailable at startup - the plugin is inert.
	if _server_unreachable():
		return # The breaker is open; don't spend another timeout on a scan.
	var now := Time.get_ticks_msec()
	if now - _external_scan_last_msec < EXTERNAL_SCAN_MIN_INTERVAL_MSEC:
		return
	_external_scan_inflight = true
	_external_scan_started_msec = now
	await _scan_for_external_changes_inner(reason)
	# Time from the END of the scan, so a slow one can't immediately re-fire.
	_external_scan_last_msec = Time.get_ticks_msec()
	_external_scan_inflight = false


func _scan_for_external_changes_inner(reason: String) -> void:
	if not await _ensure_identity():
		return
	if _verbose_log:
		_log("Scanning for changes made outside Godot (%s)..." % reason)
	var result: Dictionary = await _p4_exec(["-ztag", "reconcile", "-n", _project_scope()])
	await _offer_external_changes(_summarize_reconcile(_parse_ztag(result)), _refusals(result))


## Ask about a set of externally changed files and open the ones the user
## agreed to. Split out from the scan so the decision - including "don't ask
## about this same set again" - can be exercised on a known list.
func _offer_external_changes(found: Dictionary, refused: Dictionary) -> void:
	var names: Array = found.names
	if names.is_empty():
		# Nothing outstanding: forget any set the user waved away, so the same
		# files can be offered again if they change later.
		_external_scan_dismissed = ""
		if int(refused.count) > 0 and _verbose_log:
			_log("Perforce won't open %d changed file(s); press Reconcile for details." % refused.count)
		return

	var signature := _external_scan_signature(found.locals, names)
	if signature == _external_scan_dismissed:
		return # Already asked about exactly this state and was told no.
	_external_scan_dismissed = ""

	# "Auto add/edit/delete" is about the user's own edits, so it doesn't get
	# to silently act on a project-wide scan they didn't start when the scan
	# wants to open files for DELETE - that would quietly stage the removal of
	# anything an incomplete sync left missing.
	if _auto_open() and int(found.deletes) == 0:
		_log("%d file(s) changed outside Godot - opening them in Perforce." % names.size())
		await _reconcile_paths(found.locals, names, signature)
		return

	if not await _confirm_reconcile(found, refused, "Check Out", "Not Now"):
		_external_scan_dismissed = signature
		_log("Left %d externally changed file(s) unopened." % names.size())
		return
	await _reconcile_paths(found.locals, names, signature)


## What the user was shown, as a string that changes when the files do. Paths
## alone aren't enough: someone who says "Not Now" and then re-exports the
## same file has to be asked again, and a path-only signature would silence
## that second change for the rest of the session.
func _external_scan_signature(locals: Array, names: Array) -> String:
	var parts := PackedStringArray()
	for i in names.size():
		var local := String(locals[i])
		var stamp := 0
		if FileAccess.file_exists(local):
			stamp = FileAccess.get_modified_time(local)
		parts.append("%s:%d" % [String(names[i]), stamp])
	return "\n".join(parts)


## Open exactly the files that were listed, naming each one on the command
## line rather than re-running reconcile over the whole project: a second
## whole-project pass would also open anything that changed while the dialog
## was up, which the user never saw and never agreed to. Long lists go out in
## batches so the command line can't overflow.
##
## `signature`, when given, is remembered if Perforce refuses anything, so a
## file locked by someone else doesn't re-ask on every alt-tab.
func _reconcile_paths(locals: Array, names: Array, signature: String = "") -> void:
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
		return
	if not signature.is_empty():
		_external_scan_dismissed = signature
	_log("Perforce refused %d of the %d file(s)." % [refused.count, names.size()])
	await _show_alert(_refusal_alert_text(refused))


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


# ---------------------------------------------------------------------------
# Get Latest: download everyone else's work
#
# `p4 sync` over the project subtree. It takes more than the one command,
# because of three things sync does that "download the new files" doesn't
# cover (all three verified against a 2025.2 server):
#
#  1. `sync -n` cannot predict a refusal. A file changed on disk but not
#     checked out is a state P4Godot creates on purpose - a refused checkout
#     leaves the file writable so a later sync can't erase it - and
#     `noclobber`, the workspace default, makes p4 refuse to overwrite it. The
#     preview reports such a file as `action updated` with no hint of trouble.
#     The real sync prints "Can't clobber writable file <path>", exits 1, and
#     STILL prints an `action updated` record for it. So a real sync's records
#     don't say what landed, and the messages have to be read.
#  2. A file you have checked out is never overwritten. p4 moves your have
#     revision up to head and schedules a resolve, reporting that only as
#     messages - `sync -n` emits no record at all for such a file. Left
#     unsaid, the file quietly becomes one that can't be submitted until the
#     two versions are combined, and P4Godot has no merge UI. `resolve -n`
#     afterwards is the authoritative list and gives a clientFile per file, so
#     that part needs no message parsing.
#  3. Godot serves open tabs and cached resources from memory. A file rewritten
#     underneath an open tab keeps showing the old text, and saving that later
#     overwrites the work just downloaded - so open files get reloaded.
#
# Scoped to the Godot project, like Reconcile: a workspace often holds more
# than one project, and pulling all of it is P4V's job, not a Godot plugin's.
# ---------------------------------------------------------------------------

## p4's refusal to overwrite a writable file. The local path follows the
## prefix on the same line.
const CLOBBER_MESSAGE := "Can't clobber writable file "

## `sync -s`'s refusal to overwrite a file whose contents differ from the
## revision you have: "<depot>#<rev> - can't update modified file <local>".
## It comes with no record and exit code 0, and `sync -n -s` predicts it
## (measured against a 2025.2 server, 2026-10-02).
const MODIFIED_MESSAGE := " - can't update modified file "

## `sync -s`'s refusal to write a file the server is adding over one that is
## already on disk and that Perforce never put there (it isn't in the "have"
## list): "<depot>#<rev> - can't overwrite existing file <local>". No record,
## exit code 0, and it holds whether or not the local file is read-only
## (measured 2026-10-02).
const EXISTING_MESSAGE := " - can't overwrite existing file "

## p4's plain-text line for a file a sync handled normally (see _sync_notes).
var _sync_success_re := RegEx.create_from_string(
		"^//.*#\\d+ - (added as|updating|refreshing|replacing|deleted as) ")

## Above this, the confirmation warns that the download will take a while.
const BIG_DOWNLOAD_BYTES := 50 * 1024 * 1024


# Single-flights the flow. The dock's other long operations each have one
# (_refresh_inflight, _external_scan_inflight). Without it a double-click runs
# two flows: the second confirms against a preview the first already satisfied,
# then reloads every tab a second time - discarding whatever was typed since
# the first reload, having warned about it before the first sync even started.
var _get_latest_inflight: bool = false


func _on_get_latest_pressed() -> void:
	await _get_latest_flow()


## Returns the text it put in front of the user, so a self-test can assert on
## what the flow actually concluded rather than re-deriving it.
func _get_latest_flow() -> String:
	if _get_latest_inflight:
		_log("Get Latest is already running.")
		return ""
	_get_latest_inflight = true
	var report := await _get_latest_body()
	_get_latest_inflight = false
	return report


func _get_latest_body() -> String:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return ""
	if not await _transfer_slot_free():
		return ""
	var preview: Dictionary = await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])
	var preview_records := _parse_ztag(preview)
	var found := _summarize_sync(preview_records)
	var notes := _sync_notes(preview)
	var kept_only: bool = not (notes.modified.is_empty() and notes.existing.is_empty())
	if bool(notes.nothing_in_depot) and found.names.is_empty() and not kept_only:
		var none := ("Perforce has nothing stored under this project folder yet, so there " +
				"is nothing to download. Press \"Reconcile...\" to put the project into " +
				"Perforce for the first time.")
		await _show_alert(none)
		return none
	if found.names.is_empty() and int(preview.get("exit_code", 0)) != 0 \
			and notes.problems.is_empty():
		var failed := "Perforce couldn't work out what to download:\n\n%s" % _first_line(preview)
		await _show_alert(failed)
		return failed
	if not _get_latest_has_work(found, notes):
		# Anything p4 said that is neither a record nor a shape _sync_notes
		# recognises has to surface here. Claiming "up to date" over the top of
		# it is how a protected subtree - or any message not enumerated below -
		# would leave someone working against a stale project.
		var idle := ("Your project is already up to date - nobody has submitted anything " +
				"you don't have yet.")
		if kept_only:
			# Newer versions exist, but only of files p4 won't overwrite. "Up to
			# date" would be false, and nothing else would ever tell the user.
			idle = "Nothing was downloaded."
			if not notes.modified.is_empty():
				idle += _kept_modified_text(notes.modified)
			if not notes.existing.is_empty():
				idle += _kept_existing_text(notes.existing)
		if not notes.problems.is_empty():
			idle = ("Nothing to download." if not kept_only else idle + "\n\n") \
					+ " Perforce also said:\n\n%s" % _file_listing(notes.problems, 5)
		await _show_alert(idle)
		return idle
	if not await _confirm_get_latest(found, notes):
		_log("Get Latest cancelled.")
		return ""
	if not await _transfer_slot_free():
		return "" # a submit was started while the confirmation sat open
	_log("Get Latest: %d file(s), %s..." % [found.names.size(), _human_bytes(int(found.bytes))])
	var tracker := P4Progress.new()
	tracker.total_files = int(found.adds) + int(found.updates)
	tracker.total_bytes = int(found.bytes)
	tracker.sizes = found.sizes
	# Which of the files about to be added are ALREADY on disk. Needed if the
	# sync is cancelled: only a file that appeared during it may be cleaned up.
	var preexisting := {}
	for local in found.added_locals:
		if FileAccess.file_exists(String(local)):
			preexisting[_path_key(String(local))] = true
	var started_unix := int(Time.get_unix_time_from_system())
	_progress_begin("Get Latest", "Downloading %d file(s) from Perforce" % tracker.total_files,
			tracker)
	var synced: Dictionary = await _safe_sync([_project_scope()], tracker)
	if _shutting_down:
		return ""
	var cancelled: bool = bool(synced.get("cancelled", false))
	var cleaned := 0
	if cancelled:
		_progress_note("Tidying up after the cancelled download...")
		cleaned = await _cleanup_cancelled_sync(found, preexisting, tracker, started_unix)
	elif int(synced.exit_code) == 0:
		tracker.finish()
	_progress_end()
	var after: Dictionary = synced.notes
	# Everything below is driven by what the sync ITSELF reported, never by the
	# preview. Two reasons: p4 prints a normal-looking record for a file it
	# refused to overwrite, and a file a teammate submitted while the
	# confirmation sat open is in this output and was never in the preview - its
	# open tab needs reloading just as much.
	var done: Dictionary = synced.done
	var remaining := -1
	if cancelled:
		# A killed p4 printed few records or none (a parallel sync prints them
		# all at the end), and its progress lines miss whatever it deleted or
		# sent by Delta Transfer. So ask again what is still behind: every file
		# the first preview listed that this one doesn't has arrived, been
		# replaced, or been removed - and needs the same reload, and the same
		# warnings, as after a sync that ran to the end.
		var again: Dictionary = await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])
		var still := {}
		for rec in _parse_ztag(again):
			still[_path_key(String(rec.get("clientFile", "")))] = true
		var again_notes := _sync_notes(again)
		var asked: bool = int(again.get("exit_code", -1)) == 0 or not still.is_empty()
		var kept_names := {}
		for held in again_notes.modified + again_notes.existing:
			kept_names[String(held)] = true
		var arrived: Array = []
		for rec in preview_records:
			var local := String(rec.get("clientFile", ""))
			var res := _local_to_res(local)
			if still.has(_path_key(local)) or kept_names.has(res if not res.is_empty() else local):
				continue
			# Without an answer, fall back to what p4 itself reported done.
			if asked or tracker.is_done(local):
				arrived.append(rec)
		done = _summarize_sync(arrived)
		if asked:
			remaining = still.size()
			after = again_notes
	_request_refresh()
	EditorInterface.get_resource_filesystem().scan()
	var reload := await _reload_after_sync(done, after.clobbered)
	# The resolve list only means anything after the sync: the sync is what
	# moves the have revision and schedules the merge.
	var to_resolve: Array = await _resolve_preview_names()
	var report := _get_latest_report(done, after, reload, to_resolve,
			0 if cancelled else int(synced.exit_code))
	if cancelled:
		var head := "Get Latest was cancelled before it finished."
		if cleaned > 0:
			head += " %d unfinished file(s) were removed from the project folder." % cleaned
		var tail := "Press \"Get Latest...\" again to fetch the rest."
		if remaining == 0:
			tail = "As it turns out, everything had already arrived."
		elif remaining > 0:
			tail = "%d file(s) are still to download. Press \"Get Latest...\" again to fetch them." \
					% remaining
		report = "%s\n\n%s\n\n%s" % [head, report, tail]
	else:
		var moved := _transfer_summary(tracker)
		if not moved.is_empty() and tracker.network_mb > 0:
			report += "\n\n" + moved
	await _show_alert(report)
	return report


## After a cancelled sync, remove what the killed p4 left half-written.
## Measured (2025.2, parallel sync killed mid-way):
##   - a file being ADDED is created under its final name before its content
##     arrives, so the kill leaves an empty or partial file there - and every
##     later `sync -s` then refuses it ("can't overwrite existing file"),
##     because the server never recorded it as delivered;
##   - a file being REPLACED is written to `t<n>t<n>t<n>.tmp` beside the
##     target, which is left behind; the target itself is untouched.
## The server only records a file as delivered after it is complete, so it
## never believes the workspace has something it doesn't.
##
## A file is removed only if the preview said it would be added, it was NOT on
## disk before the sync started, p4 never reported it done, AND the server
## confirms it has no record of delivering it. Returns how many were removed.
## `known_delivered` lets a self-test supply that last answer.
func _cleanup_cancelled_sync(found: Dictionary, preexisting: Dictionary, tracker: P4Progress,
		started_unix: int, known_delivered: Variant = null) -> int:
	var removed: Array = []
	var dirs := {}
	for local_any in found.locals:
		dirs[String(local_any).get_base_dir()] = true
	var candidates: Array = []
	for local_any in found.added_locals:
		var local := String(local_any)
		if preexisting.has(_path_key(local)) or tracker.is_done(local):
			continue
		if FileAccess.file_exists(local):
			candidates.append(local)
	# The tracker alone is not enough to delete on: an old p4 reports no
	# progress at all, so "never reported done" would cover every file that
	# arrived. Ask the server which of these it has recorded as delivered, and
	# keep those. No answer, no deleting.
	var delivered := {}
	var answered := true
	if known_delivered != null:
		delivered = known_delivered # a self-test standing in for the server
	else:
		for start in range(0, candidates.size(), 100):
			var ask := PackedStringArray(["-ztag", "have"])
			for i in range(start, mini(start + 100, candidates.size())):
				ask.append(String(candidates[i]))
			var have: Dictionary = await _p4_exec(ask, false)
			var said := "" if have.output.is_empty() else String(have.output[0])
			if int(have.get("exit_code", -1)) != 0 and not said.contains("not on client"):
				answered = false
				break
			for rec in _parse_ztag(have):
				delivered[_path_key(String(rec.get("path", "")))] = true
	if not answered:
		_log("Couldn't ask the server which files had arrived, so nothing was removed. " +
				"If the next Get Latest lists files it would not download, delete those " +
				"files from the project folder and run it again.")
		candidates.clear()
	for local_any in candidates:
		var local := String(local_any)
		if delivered.has(_path_key(local)):
			continue
		_set_file_writable(local, true)
		if DirAccess.remove_absolute(local) == OK:
			removed.append(local)
	var temp_re := RegEx.create_from_string("^t\\d+t\\d+t\\d+\\.tmp$")
	for dir_path in dirs.keys():
		var dir := DirAccess.open(String(dir_path))
		if dir == null:
			continue
		for name_any in dir.get_files():
			var file_name := String(name_any)
			if temp_re.search(file_name) == null:
				continue
			var full := String(dir_path).path_join(file_name)
			# Only p4's own leftovers from THIS sync: its naming pattern, and
			# written since the sync began.
			if int(FileAccess.get_modified_time(full)) + 2 < started_unix:
				continue
			_set_file_writable(full, true)
			DirAccess.remove_absolute(full)
	if not removed.is_empty():
		_log("Removed %d unfinished file(s) left by the cancelled download." % removed.size())
	return removed.size()


## Every sync P4Godot runs goes through here, as `p4 sync -s` ("safe sync").
##
## Plain `sync` overwrites any read-only file without looking at it. That is
## fine while read-only means "unchanged", but a file can be changed and still
## read-only: on macOS and Linux, Godot saves by renaming a temp file over the
## target, which a read-only target doesn't stop and which keeps its mode. A
## plain sync then replaces that edit with the server's version and says only
## "updating" (reproduced on Windows too, with a file edited and set back to
## read-only). `-s` compares each file's contents with the revision you have
## and refuses to overwrite one that differs - MODIFIED_MESSAGE.
##
## Under `-s` the other refusal, CLOBBER_MESSAGE, means something narrower than
## it does for a plain sync: the file is writable but its contents are
## UNCHANGED (a changed one gets MODIFIED_MESSAGE instead; measured). There is
## nothing in it to protect and nothing Reconcile could open, so it would stay
## stuck behind the server for good. Those files are put back to read-only and
## synced once more. The second pass is `-s` as well, so a file edited in
## between is still refused rather than overwritten.
##
## Returns {result, done, notes, exit_code}: the first sync's raw result, its
## records folded by _summarize_sync, _sync_notes with the retry folded in
## (`clobbered` holds only what is STILL refused), and an exit code that
## forgets a clobber failure the retry fixed.
##
## With a `tracker`, the sync is streamed (_p4_exec_streamed) so a progress
## window can follow it and Cancel can stop it; the result then also carries
## `cancelled`.
func _safe_sync(targets: PackedStringArray, tracker: P4Progress = null) -> Dictionary:
	var args := PackedStringArray(["-ztag", "sync", "-s"])
	args.append_array(targets)
	var result: Dictionary
	if tracker != null:
		result = await _p4_exec_streamed(args, tracker)
	else:
		result = await _p4_exec_logged(args)
	var cancelled: bool = bool(result.get("cancelled", false))
	var notes := _sync_notes(result)
	var done := _summarize_sync(_parse_ztag(result))
	var exit_code := int(result.get("exit_code", 0))
	var stuck: Array = notes.clobbered_locals
	if stuck.is_empty() or _shutting_down or cancelled:
		return {"result": result, "done": done, "notes": notes, "exit_code": exit_code,
				"cancelled": cancelled}
	_log("Retrying %d unlocked but unchanged file(s) as read-only..." % stuck.size())
	var names: Array = notes.clobbered # parallel to `stuck`
	var still: Array = []
	var retry_failed := false
	for start in range(0, stuck.size(), 100):
		var end := mini(start + 100, stuck.size())
		var batch := PackedStringArray(["-ztag", "sync", "-s"])
		for i in range(start, end):
			_set_file_writable(String(stuck[i]), false)
			batch.append(String(stuck[i]))
		var again: Dictionary = await _p4_exec_logged(batch)
		var again_notes := _sync_notes(again)
		notes.problems.append_array(again_notes.problems)
		if int(again.get("exit_code", 0)) != 0:
			retry_failed = true
		# A file counts as downloaded only if this pass printed a record for it
		# and didn't refuse it. No record - the connection dropped, the editor
		# is closing, p4 said something else - means it is still not written,
		# and the first sync's record for it must not be counted.
		var written := {}
		for rec in _parse_ztag(again):
			written[_path_key(String(rec.get("clientFile", "")))] = true
		for refused in again_notes.clobbered_locals:
			written.erase(_path_key(String(refused)))
		for i in range(start, end):
			if not written.has(_path_key(String(stuck[i]))):
				still.append(names[i])
	# The first sync printed a record for each of these, so anything still
	# not written has to stay in `clobbered`, which the report subtracts from
	# the download count.
	notes.clobbered = still
	if not retry_failed and still.is_empty() and notes.problems.is_empty():
		exit_code = 0
	return {"result": result, "done": done, "notes": notes, "exit_code": exit_code,
			"cancelled": false}


## A local path in a form two spellings of it compare equal in: p4 prints
## Windows paths with backslashes and its own idea of the drive letter's case.
static func _path_key(path: String) -> String:
	return path.replace("\\", "/").to_lower()


## The paragraph naming files `sync -s` left alone. Shared by the confirmation,
## the "nothing to download" message and the final report, because all three
## have to say it and it must not drift between them.
func _kept_modified_text(modified: Array) -> String:
	return ("\n\nPerforce would not overwrite %d file(s) that have a newer version on the " +
			"server:\n\n%s\n\nThose are changed on your disk but not checked out, so Perforce " +
			"left your version alone instead of throwing it away. Press \"Reconcile...\" to " +
			"check them out, then \"Get Latest...\" again.") \
			% [modified.size(), _file_listing(modified, 30)]


## The paragraph naming files the server added that collide with a file
## already on disk which Perforce never put there. Reconcile is the wrong
## advice here: the local file isn't a changed copy of anything.
func _kept_existing_text(existing: Array) -> String:
	return ("\n\n%d new file(s) from the server were not downloaded, because a file with " +
			"the same name is already on your disk and Perforce didn't put it there:\n\n%s\n\n" +
			"Your file is untouched. Move or rename it, then press \"Get Latest...\" again to " +
			"get the server's version.") % [existing.size(), _file_listing(existing, 30)]


## Whether a sync has anything to do. Records alone are not the answer: a file
## you have checked out that is behind head produces no record at all, only a
## message, so counting records makes a sync with real work look idle.
static func _get_latest_has_work(found: Dictionary, notes: Dictionary) -> bool:
	return not found.names.is_empty() or int(notes.opened_behind) > 0


## Fold a sync's records into counts and names. `action` says what happens to
## the file on disk - `added` is a file that isn't there yet,
## `updated`/`refreshed`/`replaced` a rewrite, `deleted` a removal - which is a
## different vocabulary from reconcile's, where `add` means "open for add".
func _summarize_sync(records: Array) -> Dictionary:
	var rows: Array = []
	var updates := 0
	var adds := 0
	var deletes := 0
	var total := 0
	var malformed := 0
	var deleted_names: Array = []
	var sizes := {} # _path_key(local) -> bytes, for the progress tracker
	var added_locals: Array = []
	for rec in records:
		var local := String(rec.get("clientFile", ""))
		var action := String(rec.get("action", ""))
		# A record missing either field, or holding a clientFile that swallowed
		# the line after it, means p4's message output interleaved into the
		# record stream. Dropping it silently would take a real file out of the
		# download list and out of the reload set with it, so it is counted and
		# reported instead.
		if local.is_empty() or action.is_empty() or local.contains("\n"):
			malformed += 1
			continue
		var res := _local_to_res(local)
		var shown := res if not res.is_empty() else local
		if action.contains("delete"):
			deletes += 1
			deleted_names.append(shown)
		elif action.contains("add"):
			adds += 1
			added_locals.append(local)
		else:
			updates += 1
		total += int(rec.get("fileSize", 0))
		sizes[_path_key(local)] = int(rec.get("fileSize", 0))
		rows.append({"local": local, "name": shown})
	rows.sort_custom(func(a, b): return String(a.name) < String(b.name))
	var locals: Array = []
	var names: Array = []
	for row in rows:
		locals.append(row.local)
		names.append(row.name)
	deleted_names.sort()
	return {"locals": locals, "names": names, "updates": updates, "adds": adds,
			"deletes": deletes, "bytes": total, "malformed": malformed,
			"deleted_names": deleted_names, "sizes": sizes, "added_locals": added_locals}


## What a sync's output says that its records don't:
##   - `clobbered`: files p4 would not overwrite because they are writable and
##     not checked out. Nothing in the preview predicts these, and the failing
##     sync still prints a normal-looking record for each one.
##     `clobbered_locals` holds the same files as raw local paths.
##   - `modified`: files `sync -s` would not overwrite because their contents
##     differ from the revision you have (MODIFIED_MESSAGE). No record at all.
##   - `existing`: files the server is adding that `sync -s` would not write
##     over a local file of the same name (EXISTING_MESSAGE). No record either.
##   - `opened_behind`: files left alone because you have them checked out.
##     These produce no record either, so without counting them a sync that has
##     real work to do looks like "already up to date".
##   - `nothing_in_depot`: p4 has never heard of this path.
##   - `problems`: anything else p4 said, so an unexpected failure gets
##     reported rather than swallowed.
func _sync_notes(result: Dictionary) -> Dictionary:
	var clobbered: Array = []
	var clobbered_locals: Array = []
	var modified: Array = []
	var existing: Array = []
	var opened_behind := 0
	var nothing_in_depot := false
	var problems: Array = []
	var output: Array = result.get("output", [])
	if output.is_empty():
		return {"clobbered": clobbered, "clobbered_locals": clobbered_locals,
				"modified": modified, "existing": existing, "opened_behind": 0,
				"problems": problems, "nothing_in_depot": false}
	for raw_line in String(output[0]).split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("... "):
			var rest := line.substr(4)
			var sp := rest.find(" ")
			if _is_ztag_key(rest if sp == -1 else rest.substr(0, sp)):
				continue # a real tagged field, not a message - see _parse_ztag
			line = rest.strip_edges()
		if line.begins_with(CLOBBER_MESSAGE):
			var local := line.substr(CLOBBER_MESSAGE.length()).strip_edges()
			var res := _local_to_res(local)
			clobbered.append(res if not res.is_empty() else local)
			clobbered_locals.append(local)
		elif line.contains(MODIFIED_MESSAGE):
			var kept := line.substr(line.find(MODIFIED_MESSAGE) + MODIFIED_MESSAGE.length()).strip_edges()
			var kept_res := _local_to_res(kept)
			modified.append(kept_res if not kept_res.is_empty() else kept)
		elif line.contains(EXISTING_MESSAGE):
			var mine := line.substr(line.find(EXISTING_MESSAGE) + EXISTING_MESSAGE.length()).strip_edges()
			var mine_res := _local_to_res(mine)
			existing.append(mine_res if not mine_res.is_empty() else mine)
		elif line.contains("is opened and not being changed"):
			opened_behind += 1
		elif line.contains("no such file"):
			nothing_in_depot = true
		elif line.contains("must resolve") or line.contains("up-to-date"):
			pass # reported from `resolve -n`, or simply nothing to act on
		elif _sync_success_re.search(line) != null:
			# A file p4 reports in words even under -ztag. Seen after a
			# cancelled sync: a file that had fully arrived, but that the
			# server hadn't recorded yet, is taken as it stands on the next
			# sync and announced as "<depot>#1 - added as <local>" with no
			# record. It is a success, not something to warn about.
			pass
		else:
			problems.append(line)
	modified.sort()
	existing.sort()
	return {"clobbered": clobbered, "clobbered_locals": clobbered_locals, "modified": modified,
			"existing": existing, "opened_behind": opened_behind, "problems": problems,
			"nothing_in_depot": nothing_in_depot}


## The confirmation text, composed apart from the dialog so a self-test can
## assert on it. Every warning a user gets before a project-wide download is in
## this string; while it lived inside the dialog call, deleting the warnings
## broke nothing that any test could see.
func _get_latest_confirm_text(found: Dictionary, notes: Dictionary,
		open_files: Dictionary) -> String:
	# Open files split two ways. A file being rewritten gets its tab reloaded.
	# A file being DELETED cannot be, and its surviving tab is the dangerous
	# one: saving it puts back what the team just deleted.
	var deleted: Dictionary = {}
	for d in found.deleted_names:
		deleted[String(d)] = true
	var reloading: Array = []
	var orphaned: Array = []
	for name_any in found.names:
		var res := String(name_any)
		if not open_files.has(res):
			continue
		if deleted.has(res):
			orphaned.append(res)
		else:
			reloading.append(res)

	var note := ""
	if not reloading.is_empty():
		note += ("\n\n%d of them %s open in the editor:\n\n%s\n\nThose tabs will be " +
				"reloaded on the downloaded version, so anything you changed in them and " +
				"didn't save is lost. Save first if you want to keep it.") \
				% [reloading.size(), "is" if reloading.size() == 1 else "are",
				_file_listing(reloading)]
	if not orphaned.is_empty():
		note += ("\n\nCAREFUL: %d file(s) being deleted %s open in the editor:\n\n%s\n\n" +
				"Godot can't close a scene tab for you, so the tab stays open on a file " +
				"that no longer exists - and saving it would put the file back and add it " +
				"to the depot again. Close those tabs without saving.") \
				% [orphaned.size(), "is" if orphaned.size() == 1 else "are",
				_file_listing(orphaned)]
	if int(notes.opened_behind) > 0:
		note += ("\n\nYou have %d file(s) checked out that are behind the server. " +
				"Perforce never overwrites a file you have checked out, so your version " +
				"is safe - but you will have to combine the two before you can submit. " +
				"P4Godot names them when it's finished.") % notes.opened_behind
	var kept: Array = notes.get("modified", [])
	if not kept.is_empty():
		note += ("\n\n%d file(s) will NOT be downloaded, because you changed them on your " +
				"disk without checking them out and Perforce won't overwrite that:\n\n%s\n\n" +
				"Your versions stay as they are. Press \"Reconcile...\" afterwards to check " +
				"them out.") % [kept.size(), _file_listing(kept)]
	var colliding: Array = notes.get("existing", [])
	if not colliding.is_empty():
		note += ("\n\n%d new file(s) from the server will NOT be downloaded, because a " +
				"file with the same name is already on your disk and Perforce didn't put " +
				"it there:\n\n%s\n\nMove or rename yours first if you want the server's.") \
				% [colliding.size(), _file_listing(colliding)]
	if int(found.malformed) > 0:
		note += ("\n\n%d line(s) of Perforce's answer couldn't be read, so this list may " +
				"be incomplete. Run \"Get Latest...\" again afterwards.") % found.malformed
	if int(found.bytes) >= BIG_DOWNLOAD_BYTES:
		note += "\n\nThis is a large download and may take a while. The editor stays usable."

	# Say what will happen, not just how many files are involved: "download 200
	# files" is wrong when all 200 are being erased from the project folder.
	var writes: int = int(found.adds) + int(found.updates)
	var size := _human_bytes(int(found.bytes))
	var headline := ""
	if writes > 0 and int(found.deletes) > 0:
		headline = ("Download %d file(s) (%s) from the server, and remove %d from your " +
				"project folder?") % [writes, size, found.deletes]
	elif writes > 0:
		headline = "Download %d file(s) (%s) from the server?" % [writes, size]
	elif int(found.deletes) > 0:
		headline = ("Remove %d file(s) from your project folder? They were deleted on the " +
				"server. Nothing is downloaded.") % found.deletes
	else:
		# No records at all, but _get_latest_has_work said yes - so the work is
		# on files you have checked out, which p4 never overwrites, or on lines
		# of p4's answer that couldn't be read.
		headline = "No files need downloading. Bring Perforce's record of what you have up to date?"
	return "%s\n\n%s%s" % [headline, _file_listing(found.names), note]


func _confirm_get_latest(found: Dictionary, notes: Dictionary) -> bool:
	return await _show_confirm_dialog(
			_get_latest_confirm_text(found, notes, _open_editor_files()),
			"Get Latest", "Cancel")


## Put the downloaded contents in front of the user. Godot serves open tabs AND
## its resource cache from memory, so a file rewritten underneath either one
## keeps showing the old contents - and saving that later overwrites the work
## just downloaded. Open tabs are not the whole set: a scene whose tab was
## closed earlier is still cached, and reopening it would serve the pre-sync
## copy, which is exactly why _reload_path has a branch for files with no tab.
## Anything Godot never loaded needs nothing, and the filesystem scan covers it.
##
## Files p4 refused to overwrite are skipped - they still hold the user's own
## version, so there is nothing new to show.
func _reload_after_sync(done: Dictionary, clobbered: Array) -> Dictionary:
	var reloaded: Array = []
	var orphaned: Array = []
	if _shutting_down:
		return {"reloaded": reloaded, "orphaned": orphaned}
	var open_files := _open_editor_files()
	for name_any in done.names:
		var res := String(name_any)
		if not res.begins_with("res://") or clobbered.has(res):
			continue
		# A sync can delete a file. There is nothing to reload then, and asking
		# the editor to reload a missing scene is an error rather than a no-op.
		# An open tab on a deleted file is worth naming, though: saving it would
		# put back what the team deleted.
		if not FileAccess.file_exists(res):
			if open_files.has(res):
				orphaned.append(res)
			continue
		if not (open_files.has(res) or ResourceLoader.has_cached(res)):
			continue
		if _shutting_down:
			break
		await _reload_path(res)
		reloaded.append(res)
	return {"reloaded": reloaded, "orphaned": orphaned}


## The files that now need their two versions combined before they can be
## submitted, from `resolve -n` - real tagged records with a clientFile, so no
## message text is read. Only meaningful after a sync.
func _resolve_preview_names() -> Array:
	var records := _parse_ztag(await _p4_exec(["-ztag", "resolve", "-n", _project_scope()]))
	var names: Array = []
	for rec in records:
		var local := String(rec.get("clientFile", ""))
		if local.is_empty():
			continue
		var res := _local_to_res(local)
		names.append(res if not res.is_empty() else local)
	names.sort()
	return names


## What actually happened, taken from the sync's own output rather than the
## preview's - p4 prints a normal-looking record for a file it refused to
## overwrite, so the refusals are subtracted here. Every problem names its next
## step, because each one leaves work for the user to finish by hand.
func _get_latest_report(done: Dictionary, after: Dictionary, reload: Dictionary,
		to_resolve: Array, exit_code: int) -> String:
	var clobbered: Array = after.clobbered
	var written: int = maxi(int(done.adds) + int(done.updates) - clobbered.size(), 0)
	var parts: Array = []
	if written > 0:
		parts.append("downloaded %d file(s)" % written)
	if int(done.deletes) > 0:
		parts.append("removed %d file(s) that were deleted on the server" % done.deletes)
	var text := "Nothing was downloaded." if parts.is_empty() \
			else "Get Latest %s." % " and ".join(parts)
	var reloaded: Array = reload.reloaded
	if not reloaded.is_empty():
		text += " %d file(s) already loaded in the editor %s reloaded." \
				% [reloaded.size(), "was" if reloaded.size() == 1 else "were"]
	if not reload.orphaned.is_empty():
		text += ("\n\nCAREFUL: %d deleted file(s) %s still open in the editor:\n\n%s\n\n" +
				"The file is gone from your project folder but the tab is still there. " +
				"Close those tabs WITHOUT saving - a save would put the files back and " +
				"add them to the depot again.") \
				% [reload.orphaned.size(), "is" if reload.orphaned.size() == 1 else "are",
				_file_listing(reload.orphaned)]
	# Two refusals, one paragraph: both leave the user's own version on disk and
	# both end at Reconcile. Only `clobbered` is subtracted from the count
	# above, because only those came with a record.
	var kept: Array = after.get("modified", []) + clobbered
	if not kept.is_empty():
		text += _kept_modified_text(kept)
	var colliding: Array = after.get("existing", [])
	if not colliding.is_empty():
		text += _kept_existing_text(colliding)
	if not to_resolve.is_empty():
		text += ("\n\n%d file(s) you have checked out need the two versions combined " +
				"before you can submit them:\n\n%s\n\nP4Godot can't do that merge. In " +
				"P4V, right-click the file and choose Resolve, or run `p4 resolve` in a " +
				"terminal. For an image or a model there is nothing to combine - you keep " +
				"one version and lose the other - so talk to whoever made the other " +
				"change first.") % [to_resolve.size(), _file_listing(to_resolve, 30)]
	if int(done.malformed) > 0:
		text += ("\n\n%d line(s) of Perforce's answer couldn't be read, so this summary " +
				"may be incomplete. Press \"Get Latest...\" again to check.") % done.malformed
	if not after.problems.is_empty():
		text += "\n\nPerforce also said:\n\n%s" % _file_listing(after.problems, 5)
	elif exit_code != 0 and clobbered.is_empty():
		text += ("\n\nPerforce reported a failure but didn't say why (exit code %d). The " +
				"Log window has the full output. Press \"Get Latest...\" again to see " +
				"what arrived.") % exit_code
	return text


## The first line of a p4 result. OS.execute hands back one string holding the
## whole blob, so `output[0]` is everything p4 printed, not its first line -
## dumping all of it into a dialog buries the part that matters.
static func _first_line(result: Dictionary) -> String:
	var output: Array = result.get("output", [])
	if output.is_empty():
		return ""
	for raw in String(output[0]).split("\n"):
		var line := raw.rstrip("\r").strip_edges()
		if not line.is_empty():
			return line
	return ""


## A file size for a dialog: "940 KB", "12.4 MB". Rounded on purpose - it is
## there to warn about a big download, not to account for it.
static func _human_bytes(bytes: int) -> String:
	if bytes < 1024:
		return "%d bytes" % bytes
	if bytes < 1024 * 1024:
		return "%d KB" % int(round(bytes / 1024.0))
	if bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	return "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))


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


## Edit a changelist's description. For a numbered changelist this updates it in
## place; the `change -o` round-trip preserves Files/Jobs. For the DEFAULT
## changelist there is no description to edit, so `change -o` (no number) returns
## a `Change: new` spec that already carries the default's files - saving it
## promotes those files into a new numbered changelist (matching P4V).
func _edit_changelist_description(change: String) -> void:
	var is_default := change == "default"
	var read_args: PackedStringArray = ["change", "-o"]
	if not is_default:
		read_args.append(change)
	var current := await _p4_exec(read_args)
	var spec_text := "" if current.output.is_empty() else String(current.output[0])
	if spec_text.is_empty():
		await _show_alert("Could not read the changelist spec - see the P4 Log.")
		return
	var title := "Edit Default Changelist (creates a numbered changelist)" if is_default \
			else "Edit Changelist #%s" % change
	var initial := "" if is_default else _extract_spec_description(spec_text)
	var res: Dictionary = await _show_input_dialog(title, "Description:", initial, true, "Save")
	if not res.ok:
		return
	var new_desc := String(res.text).strip_edges()
	if new_desc.is_empty():
		await _show_alert("A changelist needs a description.")
		return
	await _p4_exec_spec(["change", "-i"], _replace_spec_description(spec_text, new_desc))
	_request_refresh()


## Delete an empty numbered changelist (`p4 change -d`). p4 refuses if it still
## has open files; the menu only offers this on empty numbered changelists, and
## the failure is surfaced if the state changed underneath us.
func _delete_changelist(change: String) -> void:
	if change == "default":
		return # The default changelist can't be deleted.
	var proceed: bool = await _show_confirm_dialog(
			"Delete empty changelist #%s?" % change, "Delete", "Cancel")
	if not proceed:
		return
	var result := await _p4_exec_logged(["change", "-d", change])
	if result.exit_code != 0:
		var msg := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		await _show_alert(("Perforce wouldn't delete changelist #%s:\n\n%s\n\nMost often " +
				"it still has files in it - move them to another changelist or submit " +
				"them first.") % [change, msg])
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
	var text := String(result.output[0])
	# A submit the server renumbers says "Change 12 renamed change 14 and
	# submitted." - the final number is the one after "renamed change".
	var renamed_m := RegEx.create_from_string("renamed change (\\d+)").search(text)
	if renamed_m:
		return renamed_m.get_string(1)
	var m := RegEx.create_from_string("Change (\\d+)").search(text)
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
## explicit confirmation that lists the exact files and the description.
##
## Everything is submitted by number (`submit -c N`). The default changelist
## has no number, so its confirmed files are first moved into a new numbered
## changelist carrying the description (`change -i`). The number is what makes
## the outcome checkable: when the answer to `submit` never arrives, it is the
## only handle for asking the server what became of it (see _submit_verdict).
func _submit_changelist(change: String, files: Array, preset_desc: String = "") -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	if not await _transfer_slot_free():
		return
	# The dock's file list can be stale; confirm (and submit) what's opened now.
	files = await _submit_file_list(change, files)
	if files.is_empty():
		await _show_alert("This changelist has no files to submit.")
		return

	var desc := ""
	if change == "default":
		# preset_desc exists for the live submit selftest (no input dialog).
		var input: Dictionary = {"ok": true, "text": preset_desc} if not preset_desc.is_empty() \
				else await _show_input_dialog("Submit Default Changelist",
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
		file_lines.append("    %s  (%s)" % [files[i].label, files[i].action])
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
	if not await _transfer_slot_free():
		return # a download was started while the confirmation sat open

	var number := change
	if change == "default":
		# A spec on stdin listing exactly the confirmed files: nothing opened
		# while the dialog was up rides along, and the description never
		# passes through a command line.
		var spec := "Change: new\n\nDescription:\n" + _indent_spec_text(desc) + "\nFiles:\n"
		for f in files:
			spec += "\t%s\n" % f.depot_path
		var made: Dictionary = await _p4_exec_spec(["change", "-i"], spec)
		# Read the "created" line, not the exit code: a changelist can be
		# created and the command still exit non-zero (a server-side check on
		# the form), and then the files are in it, not in the default one.
		number = _created_change_in(made)
		if number.is_empty():
			var why := "" if made.output.is_empty() else String(made.output[0]).strip_edges()
			await _show_alert(("Perforce couldn't get your files ready to submit:\n\n%s\n\n" +
					"Nothing was sent. Press Refresh in the P4G panel to see where your files " +
					"are - normally still in the default changelist.") % why)
			_request_refresh()
			return

	var tracker := _submit_tracker(files)
	_progress_begin("Submitting to Perforce", "Submitting changelist %s" % number, tracker)
	var result: Dictionary = await _p4_exec_streamed(["submit", "-c", number], tracker)
	var cancelled: bool = bool(result.get("cancelled", false))
	# What p4 printed and how it exited are not the outcome. A submit whose
	# answer never arrived may still have gone through - and a cancelled one
	# may have been past the point of no return - so on anything short of an
	# explicit "submitted", ask the server what became of the changelist.
	var final := _submitted_change_in(result)
	var outcome := "submitted"
	var said := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
	if final.is_empty():
		var lost: bool = cancelled or _submit_connection_lost(result)
		if lost:
			_log("The submit didn't end with a clear answer - asking the server what became of it...")
			_progress_note("Asking the server what became of the submit...")
		# A file that was part-way up when p4 stopped never fully arrived, so
		# the server cannot go on to commit this changelist: if it reads as
		# pending, it was not submitted, and that can be said within seconds.
		# Measured as an ordinary user on a 2025.2 server: after a cancel the
		# server went on listing its `submit` as running for minutes, yet the
		# same changelist resubmitted in seconds - the entry holds nothing.
		# Waiting on it only turned a known answer into "unknown".
		# With no file in flight (stopped between files, or the connection
		# lost after the last one) the server may have everything, so it is
		# asked repeatedly, as for any lost connection.
		var verdict: Dictionary = await _submit_verdict(number, lost,
				lost and tracker.in_flight() > 0)
		outcome = String(verdict.outcome)
		final = String(verdict.change)
		_progress_end()
		await _show_alert(_submit_outcome_text(outcome, number, final, said, lost, cancelled))
	elif int(result.exit_code) != 0:
		_progress_end()
		# The server said "submitted" and then something failed - a check that
		# runs after the submit, say. The files are in; the complaint still
		# has to reach the user.
		await _show_alert(("Your files were submitted as change %s, but Perforce reported a " +
				"problem afterwards:\n\n%s") % [final, said])
	else:
		tracker.finish()
		_progress_end()

	_last_submit_outcome = outcome
	if outcome == "submitted":
		_log("Submit complete." if final.is_empty() else "Submitted as change %s." % final)
		var moved := _transfer_summary(tracker)
		if not moved.is_empty():
			_log("  " + moved)
		# Submitted files are no longer opened. The cache is keyed by res://
		# path, which files missing from the last refresh don't have here - so
		# drop it all; the refresh below re-adds whatever is still opened.
		_checked_out_this_session.clear()
		for f in files:
			_pending_save_checkout.erase(f.label)
	else:
		_log("Submit of changelist %s: %s." % [number,
				"not submitted" if outcome == "not_submitted" else "outcome unknown"])
	_request_refresh()


## What a submit of `files` (entries from _submit_file_list) will transfer:
## every file except the ones being deleted, with the size of each one whose
## local path is known. Files outside the Godot project have no local path
## here; the tracker takes their sizes from p4's own progress lines.
func _submit_tracker(files: Array) -> P4Progress:
	var tracker := P4Progress.new()
	for f in files:
		if String(f.action).contains("delete"):
			continue
		tracker.total_files += 1
		var label := String(f.label)
		if not label.begins_with("res://"):
			continue
		var local := ProjectSettings.globalize_path(label)
		var handle := FileAccess.open(local, FileAccess.READ)
		if handle == null:
			continue
		var size := int(handle.get_length())
		handle.close()
		tracker.sizes[P4Progress.key_of(local)] = size
		tracker.total_bytes += size
	return tracker


## The number a submit landed as, read from p4's own "submitted" line - or ""
## when the output doesn't say it was submitted. A submit the server renumbers
## says "Change 12 renamed change 14 and submitted."
static func _submitted_change_in(result: Dictionary) -> String:
	var output: Array = result.get("output", [])
	if output.is_empty():
		return ""
	var text := String(output[0])
	var renamed := RegEx.create_from_string("renamed change (\\d+) and submitted").search(text)
	if renamed:
		return renamed.get_string(1)
	var plain := RegEx.create_from_string("Change (\\d+) submitted").search(text)
	return plain.get_string(1) if plain else ""


## The number `p4 change -i` created, from its "Change N created" line, or "".
static func _created_change_in(result: Dictionary) -> String:
	var output: Array = result.get("output", [])
	if output.is_empty():
		return ""
	var m := RegEx.create_from_string("Change (\\d+) created").search(String(output[0]))
	return m.get_string(1) if m else ""


## Whether a submit that didn't say "submitted" may have lost its connection,
## as opposed to the server answering "no". Only the second is an answer.
## After the first, the server may have finished the submit, may still be
## working on it, or may never have started.
##
## The default is "may have been lost". It is the server's own refusal that
## has to be recognised, because guessing wrong the other way ends in telling
## someone nothing was sent while the server finishes sending it. A network
## error outranks a refusal line in the same output.
static func _submit_connection_lost(result: Dictionary) -> bool:
	var output: Array = result.get("output", [])
	var text := "" if output.is_empty() else String(output[0])
	for marker in ["TCP receive", "TCP send", "TCP connect", "SSL receive", "SSL send",
			"Connect to server failed", "exceeded maximum configured duration",
			"Partner exited unexpectedly", "Connection reset", "WSAECONN", "Broken pipe"]:
		if text.contains(marker):
			return true
	for refusal in ["Submit failed", "Submit aborted", "Submit validation failed",
			"No files to submit"]:
		if text.contains(refusal):
			return false
	return true


## What `p4 -ztag describe -s [-O] <n>` says about a changelist:
## {"status": "submitted" | "pending" | "missing" | "unknown", "change": <n>}.
## "missing" is p4's "no such changelist" - which is also what a changelist
## that was renumbered on submit answers under its old number. "unknown" is
## anything else, a failed connection included.
##
## `describe` prints a blank line after the description, in the middle of the
## record, so _parse_ztag hands back two records and `status` is in the second.
func _describe_status(result: Dictionary) -> Dictionary:
	var status := ""
	var number := ""
	for rec in _parse_ztag(result):
		if rec.has("status"):
			status = String(rec.status)
		if rec.has("change"):
			number = String(rec.change)
	if status == "submitted" or status == "pending":
		return {"status": status, "change": number}
	var output: Array = result.get("output", [])
	var text := "" if output.is_empty() else String(output[0])
	if text.contains("no such changelist"):
		return {"status": "missing", "change": ""}
	return {"status": "unknown", "change": ""}


## Whether `p4 -ztag monitor show` lists a submit this user is running:
## 1 yes, 0 no, -1 can't tell (monitoring is off, or we aren't allowed to look).
## A working answer always lists at least our own `monitor` command, so an
## answer with no records at all is "can't tell", never "no".
func _monitor_submit_running(result: Dictionary, user: String, commit_only: bool = false) -> int:
	if int(result.get("exit_code", 0)) != 0:
		return -1
	var records := _parse_ztag(result)
	if records.is_empty():
		return -1
	# Matched loosely on purpose. A submit is listed as `submit` while it
	# uploads and as `dm-CommitSubmit` while the server commits it (both seen
	# on a 2025.2 server), and a miss here reads as "nothing running", which
	# turns a submit in progress into "not submitted".
	for rec in records:
		if String(rec.get("user", "")) == user \
				and String(rec.get("command", "")).to_lower().contains("commit" if commit_only else "submit"):
			return 1
	return 0


const SUBMIT_VERDICT_WINDOW_MSEC := 30000
const SUBMIT_VERDICT_POLL_SEC := 2.0


## Ask the server what became of changelist `number` after a submit that
## didn't report success: {"outcome": "submitted" | "not_submitted" |
## "unknown", "change": <the number it was submitted as, or "">}.
##
## When the server answered the submit with a refusal (`connection_lost`
## false), a changelist that is still pending was simply not submitted.
##
## When the answer never arrived, "still pending" proves nothing: the server
## finishes a submit whose files it has already received even after the client
## is gone, and until it does the changelist reads as pending. So keep asking
## for SUBMIT_VERDICT_WINDOW_MSEC while the server still lists a submit of ours
## as running. Pending with none running is "not submitted". If the server
## can't tell us what is running, or a submit is still running when the window
## closes, the honest answer is "unknown". The window is a deadline and not a
## number of tries because one try against an unreachable server already costs
## the operating system's connect timeout.
##
##
## Everything asked here is open to an ordinary user: `describe` and the plain
## `monitor show`. Nothing is terminated on the server. (An earlier version
## did, with `p4 monitor terminate`; an ordinary account is refused that even
## for its own command, and it turned out not to be needed - see the caller.)
##
## `upload_cut` says p4 stopped with a file part-way up (the caller knows from
## the progress lines). The server then can't have the whole changelist, and a
## lingering `submit` in its process list means nothing. The one way that
## could be wrong is a file that finished in the instant before p4 stopped,
## with its "done" line unprinted - and then the server moves on to the commit
## within moments. So: look twice, a poll apart, and call it not submitted
## unless the changelist has gone or a commit is running.
func _submit_verdict(number: String, connection_lost: bool, upload_cut: bool = false) -> Dictionary:
	var deadline := Time.get_ticks_msec() + SUBMIT_VERDICT_WINDOW_MSEC
	var attempt := 0
	while not _shutting_down:
		if attempt > 0:
			if not connection_lost or Time.get_ticks_msec() >= deadline:
				break
			await get_tree().create_timer(SUBMIT_VERDICT_POLL_SEC).timeout
		attempt += 1
		# Ask what is running BEFORE asking for the status. In the other order a
		# submit that finishes between the two questions reads as "pending,
		# nothing running" - not submitted - when it just was.
		var running := -1
		if connection_lost:
			running = _monitor_submit_running(
					await _p4_exec(["-ztag", "monitor", "show"], false), _p4_user, upload_cut)
		var seen := _describe_status(await _p4_exec(["-ztag", "describe", "-s", number], false))
		if seen.status == "missing":
			# Gone under its own number: either renumbered on submit, which
			# `-O` finds by the original number, or deleted.
			seen = _describe_status(
					await _p4_exec(["-ztag", "describe", "-s", "-O", number], false))
		match String(seen.status):
			"submitted":
				return {"outcome": "submitted", "change": String(seen.change)}
			"pending":
				if not connection_lost:
					return {"outcome": "not_submitted", "change": ""}
				if upload_cut:
					# `running` here means "a commit is running" only. The
					# second look is what covers the file that finished just
					# before p4 stopped.
					if attempt >= 2 and running != 1:
						return {"outcome": "not_submitted", "change": ""}
				elif running == 0:
					return {"outcome": "not_submitted", "change": ""}
			_:
				pass # can't reach the server, or it has no such changelist: ask again
	return {"outcome": "unknown", "change": ""}


## What the user is told after a submit that didn't simply succeed. Composed
## apart from the dialog so a self-test can assert on it: this is the text that
## used to say "nothing was sent" without anyone having checked.
func _submit_outcome_text(outcome: String, number: String, final: String, said: String,
		connection_lost: bool, cancelled: bool = false) -> String:
	match outcome:
		"submitted":
			if cancelled:
				return ("Too late to cancel: your files were submitted as change %s.\n\n" +
						"The server had already received them when the submit was stopped, " +
						"and it finished the job. P4Godot checked with the server afterwards.") \
						% (final if not final.is_empty() else number)
			return ("Your files were submitted as change %s.\n\nThe server's answer didn't " +
					"reach Godot, so P4Godot asked it afterwards - the submit went through.") \
					% (final if not final.is_empty() else number)
		"not_submitted":
			if cancelled:
				return ("Submit cancelled.\n\nP4Godot checked with the server afterwards: " +
						"nothing was submitted, and your work is untouched. Your files are in " +
						"changelist %s in the P4G panel - submit it from there when you're " +
						"ready.") % number
			if connection_lost:
				return ("The connection to the Perforce server dropped before your files " +
						"were submitted:\n\n%s\n\nP4Godot checked with the server afterwards: " +
						"nothing was sent, and your work is untouched. Your files are in " +
						"changelist %s in the P4G panel - submit it again from there.") \
						% [said, number]
			return ("Perforce didn't accept your files:\n\n%s\n\nNothing was sent, and your " +
					"work is untouched. The usual cause is that a teammate changed one of the " +
					"same files first, so you need their version before you can send yours: " +
					"right-click the file in the P4G panel and choose \"Sync This File\", then " +
					"combine their changes with yours (P4V, or `p4 resolve` in a terminal) and " +
					"submit again.\n\nYour files are in changelist %s in the P4G panel, with " +
					"your description. Submit it from there once the problem is sorted out.") \
					% [said, number]
	# The panel is only evidence once it is showing real data again: with the
	# server unreachable it lists nothing, and "changelist gone" would then
	# read as "submitted" when nothing was asked.
	return ("P4Godot can't tell whether your files were submitted.\n\n%s\n\nThe submit " +
			"didn't finish cleanly, and when P4Godot asked the server afterwards it got no " +
			"clear answer - the server couldn't be reached, or was still working on it.\n\n" +
			"Don't submit again yet. Wait a minute and press Refresh in the P4G panel. An " +
			"empty panel only means the server still isn't answering, so wait until your " +
			"checked-out files are listed again. Then: if changelist %s is listed, it was " +
			"not submitted - submit it again. If it isn't, the submit went through. " +
			"(`p4 describe -s %s` in a terminal answers the same question.)") \
			% [said, number, number]


## The files a submit will include, queried fresh: the default changelist's
## files under this project (the scope a default submit covers), or every file
## in a numbered changelist - including any outside the project, which
## `submit -c` takes along. Each entry: {depot_path, action, label}, where the
## label is the res:// path when known, else the depot path.
func _submit_file_list(change: String, known: Array) -> Array:
	var res_by_depot := {}
	for f in known:
		res_by_depot[String(f.depot_path)] = String(f.res_path)
	var args: PackedStringArray = ["-ztag", "opened", "-c", change]
	if change == "default":
		args.append(_project_scope())
	var out: Array = []
	for rec in _parse_ztag(await _p4_exec(args)):
		var depot := String(rec.get("depotFile", ""))
		if depot.is_empty():
			continue
		out.append({"depot_path": depot, "action": String(rec.get("action", "")),
				"label": String(res_by_depot.get(depot, depot))})
	return out


# ---------------------------------------------------------------------------
# Perforce operations
# ---------------------------------------------------------------------------

## Runs `p4 edit` (on the worker thread) and returns {ok: bool, reason:
## String}. `reason` is a human-readable failure explanation ("already checked
## out by bob (workspace 'bob_ws')" for the exclusive-checkout case, raw p4
## text otherwise) so every caller can surface it in whatever dialog fits its
## context. Logging happens here; dialogs are the caller's job.
## `change` targets a pending changelist (`p4 edit -c N`); "" or "default"
## opens in the default changelist.
func _do_checkout(res_path: String, change: String = "") -> Dictionary:
	if not await _ensure_identity():
		return {"ok": false, "reason": "p4 isn't available this session (see the startup log)"}
	var global_path := ProjectSettings.globalize_path(res_path)
	var edit_args: PackedStringArray = ["edit"]
	if not change.is_empty() and change != "default":
		edit_args.append_array(["-c", change])
	edit_args.append(global_path)
	var edit_result: Dictionary = await _p4_exec_logged(edit_args)
	var fstat_result: Dictionary = await _p4_exec(["fstat", global_path])
	var others := _parse_other_opens(await _p4_exec(["opened", "-a", global_path]))
	return _resolve_checkout(res_path, edit_result, fstat_result, others)


## The changelist targets the checkout dialogs offer: the default changelist
## first, then every pending numbered changelist owned by us in this client.
## Queried fresh each time (not from _last_changelists) so the dropdown never
## offers a changelist that was submitted or deleted since the last dock
## refresh. Each entry is {change: String, label: String}.
func _pending_changelist_choices() -> Array:
	var choices: Array = [{"change": "default", "label": "Default changelist"}]
	if not await _ensure_identity():
		return choices
	for crec in _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending",
			"-c", _p4_client, "-u", _p4_user])):
		var num := String(crec.get("change", ""))
		if num.is_empty():
			continue
		var desc := String(crec.get("desc", "")).strip_edges().get_slice("\n", 0)
		choices.append({"change": num, "label": "#%s  %s" % [num, desc]})
	return choices


## For a file that was saved while not checked out (allwrite workspace, a +w
## filetype, or macOS/Linux): open it only if the save really changed it.
## `p4 reconcile -e` compares content (line-ending tolerant - verified), so an
## untouched Ctrl+S doesn't land the file in a changelist. Same result shape
## as _do_checkout, plus "unchanged": true when there was nothing to open.
func _checkout_if_changed(res_path: String) -> Dictionary:
	if not await _ensure_identity():
		return {"ok": false, "reason": "p4 isn't available this session (see the startup log)"}
	var global_path := ProjectSettings.globalize_path(res_path)
	var rec_result: Dictionary = await _p4_exec_logged(["reconcile", "-e", global_path])
	var rec_text := "" if rec_result.output.is_empty() else String(rec_result.output[0])
	if rec_text.contains("no file(s) to reconcile"):
		return {"ok": true, "reason": "", "unchanged": true}
	var fstat_result: Dictionary = await _p4_exec(["fstat", global_path])
	var others := _parse_other_opens(await _p4_exec(["opened", "-a", global_path]))
	return _resolve_checkout(res_path, rec_result, fstat_result, others)


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
	_fstat_failed.erase(global_path)
	if text.contains("no such file(s)") or text.contains("not in client view") \
			or text.contains("not under client's root"):
		return false
	if _fstat_shows_our_open(text):
		return false
	if result.exit_code != 0:
		_fstat_failed[global_path] = Time.get_ticks_msec()
		_log("Warning: 'p4 fstat' failed (exit %d) for '%s'%s" % [result.exit_code, global_path,
				"" if text.is_empty() else ": " + text.strip_edges().get_slice("\n", 0)])
		return false
	return true


## Cache "no checkout needed" for the session - unless that answer came from a
## failed fstat (a network blip, an expired ticket), which must not switch
## checkout off for this file until the editor restarts.
func _remember_no_checkout(res_path: String, global_path: String) -> void:
	if not _fstat_failed.has(global_path):
		_checked_out_this_session[res_path] = true


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
##   {available: bool, opened_ok: bool, changelists: Array}
## `opened_ok` says the `p4 opened` query itself succeeded (it exits 0 with an
## empty list when nothing is open), which is what lets _sync_opened_cache
## tell "nothing is checked out" from "we couldn't ask".
## each changelist: {change: "default"|"<n>", desc: String, files: Array}
## each file:       {res_path, depot_path, action, change, type}
## The default changelist is synthesized (p4 never lists it) and always present,
## even empty, so newly-opened files always have a home in the tree.
func _query_pending_model() -> Dictionary:
	if not await _ensure_identity():
		return {"available": false, "opened_ok": false, "changelists": []}

	# 1. Files opened in our client (across all its pending changelists).
	var opened_result: Dictionary = await _p4_exec(["-ztag", "opened"])
	var opened := _parse_ztag(opened_result)

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

	return {
		"available": true,
		"opened_ok": int(opened_result.get("exit_code", 1)) == 0,
		"changelists": cls,
	}


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

## Async `p4 <args>` via the worker thread. Returns {exit_code, output}. Commands
## are logged to the log window per the Verbose setting (see _should_log_cmd).
func _p4_exec(args: PackedStringArray, offer_login: bool = true,
		maxwait_sec: int = NET_MAXWAIT_SEC) -> Dictionary:
	if _shutting_down:
		# Continuations that resume during teardown must not start new p4
		# commands (they'd run blocking on the main thread while the editor quits).
		return {"exit_code": -1, "output": [""]}
	if _p4_thread == null:
		return _p4_exec_sync(args)
	# Circuit breaker: status queries skip a server that just stopped answering
	# (connection probes and logins always try - they're how it recovers; `set`
	# never contacts the server, and connection settings need its answer most
	# exactly when the server is unreachable).
	if _server_unreachable() and _is_probe_command(args) \
			and not _p4_subcommand(args) in ["info", "login", "set"]:
		return _skipped_result()
	var loud := _should_log_cmd(args) # decided BEFORE the -p/-u/-c flags join in
	args = _with_connection_flags(_escape_path_args(args), maxwait_sec)
	if loud:
		_log_p4_cmd(args)
	var req := P4Request.new()
	req.bin = _p4_cmd()
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
	_finish_p4_log(args, result, loud)
	_note_connectivity(result)
	if offer_login:
		_maybe_offer_login(result)
	return result


## The p4 subcommand in `args` (the first word that isn't a flag).
static func _p4_subcommand(args: PackedStringArray) -> String:
	for a in args:
		if not a.begins_with("-"):
			return a
	return ""


## Retained as a semantic alias; _p4_exec now logs every command and its output.
func _p4_exec_logged(args: PackedStringArray) -> Dictionary:
	return await _p4_exec(args)


## Run `p4 <args>` with `spec_text` fed on stdin (for `p4 change -i`). OS.execute
## has no stdin, so the spec is written to a temp file and p4 is run through the
## platform shell with the file redirected in. Goes through the same worker queue
## as _p4_exec so it stays serialized; resumes on the main thread.
func _p4_exec_spec(args: PackedStringArray, spec_text: String) -> Dictionary:
	if _shutting_down:
		return {"exit_code": -1, "output": [""]}
	var tmp := _write_temp_spec(spec_text)
	if tmp.is_empty():
		return {"exit_code": -1, "output": ["Could not write a temporary p4 spec file."]}
	var loud := _should_log_cmd(args) # change -i is always loud (never a probe)
	args = _with_connection_flags(_escape_path_args(args))
	var display_args := args + PackedStringArray(["< (spec on stdin)"])
	if loud:
		_log_p4_cmd(display_args)
	if _p4_thread == null:
		var out := []
		var code := _p4_execute_with_stdin(_p4_cmd(), args, tmp, out)
		DirAccess.remove_absolute(tmp)
		var sync_result := {"exit_code": code, "output": out}
		_finish_p4_log(display_args, sync_result, loud)
		return sync_result
	var req := P4Request.new()
	req.bin = _p4_cmd()
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
	_finish_p4_log(display_args, result, loud)
	_note_connectivity(result)
	return result


## Runs on the worker thread: p4 through the platform shell with the spec file
## on stdin. Static - only OS and its arguments - so it is thread-safe. Every
## word is quoted for the shell that parses it.
static func _p4_execute_with_stdin(bin: String, args: PackedStringArray, stdin_path: String,
		output: Array) -> int:
	var words := PackedStringArray([bin])
	words.append_array(args)
	if OS.get_name() == "Windows":
		var cmd := ""
		for w in words:
			cmd += _cmd_quote(w) + " "
		cmd += "< " + _cmd_quote(stdin_path.replace("/", "\\"))
		return OS.execute("cmd.exe", ["/c", cmd], output, true)
	var sh_cmd := ""
	for w in words:
		sh_cmd += _sh_quote(w) + " "
	sh_cmd += "< " + _sh_quote(stdin_path)
	return OS.execute("sh", _os_args(["-c", sh_cmd]), output, true)


## cmd.exe word quoting. Perforce names and paths can't contain `"`, so wrapping
## in quotes is enough to neutralize spaces and & | < > ^ ( ).
static func _cmd_quote(word: String) -> String:
	for c in " &|<>^()%!,;=":
		if word.contains(c):
			return "\"" + word + "\""
	return word if not word.is_empty() else "\"\""


## POSIX shell word quoting: single quotes, with embedded ones spliced as '\''.
static func _sh_quote(word: String) -> String:
	return "'" + word.replace("'", "'\\''") + "'"


## Perforce reads @ # % * in a file argument as revision/wildcard syntax, so a
## file named `icon@2x.png` must be passed as `icon%402x.png`. Output gives local
## paths (clientFile, where's third column) raw and depot paths escaped, so only
## arguments need this. `p4 add` is the exception: it wants the raw name plus -f.
static func _p4_escape_path(path: String) -> String:
	return path.replace("%", "%25").replace("@", "%40").replace("#", "%23").replace("*", "%2A")


## An absolute local path (C:/... or /...), as opposed to a depot/client path
## (//...), a flag, or a value.
static func _is_local_path(arg: String) -> bool:
	if arg.length() >= 3 and arg[1] == ":" and (arg[2] == "/" or arg[2] == "\\"):
		return true
	return arg.begins_with("/") and not arg.begins_with("//")


## Escape every local-path argument (see _p4_escape_path). For `p4 add`, pass
## raw names and add -f when any has a special character. Revision suffixes
## must never be appended to local paths by callers (use depot paths for that).
static func _escape_path_args(args: PackedStringArray) -> PackedStringArray:
	var cmd_idx := -1
	for i in args.size():
		if not args[i].begins_with("-"):
			cmd_idx = i
			break
	if cmd_idx == -1:
		return args
	var out := PackedStringArray(args)
	if args[cmd_idx] == "reconcile":
		# Like add, `reconcile -f` takes RAW local names (verified: with escaped
		# names it finds nothing) and without -f it skips such files entirely -
		# so always pass -f; it changes nothing for ordinary names.
		if not "-f" in args:
			out.insert(cmd_idx + 1, "-f")
		return out
	if args[cmd_idx] == "add":
		var special := false
		for a in args:
			if _is_local_path(a) and _p4_escape_path(a) != a:
				special = true
		if special and not "-f" in args:
			out.insert(cmd_idx + 1, "-f")
		return out
	for i in range(cmd_idx + 1, out.size()):
		if _is_local_path(out[i]):
			out[i] = _p4_escape_path(out[i])
	return out


## Godot's OS.execute on macOS/Linux runs the command through popen(), wrapping
## each argument in bare double quotes (drivers/unix/os_unix.cpp in 4.7), so a
## `$`, backtick, `"` or `\` inside an argument would be read by the shell - a
## changelist description with `$VER` or backticks would be mangled or even
## run. Escape exactly those. Windows hands arguments to CreateProcess (no shell).
static func _os_args(args: PackedStringArray) -> PackedStringArray:
	if OS.get_name() == "Windows":
		return args
	var out := PackedStringArray()
	for a in args:
		out.append(a.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$").replace("`", "\\`"))
	return out


func _write_temp_spec(spec_text: String) -> String:
	var path := _p4godot_cache_dir().path_join("spec_%d.txt" % Time.get_ticks_usec())
	if OS.get_name() != "Windows":
		# The login password travels through this file, so it must be owner-only
		# BEFORE the content is written. The editor's safe-save writes a temp
		# sibling and renames it over the target, copying the target's mode - so
		# create the file empty, restrict it, and only then write for real.
		var pre := FileAccess.open(path, FileAccess.WRITE)
		if pre == null:
			_log("Could not open a temp spec file at '%s'." % path)
			return ""
		pre.close()
		if FileAccess.set_unix_permissions(path,
				FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER) != OK:
			DirAccess.remove_absolute(path)
			_log("Could not make the temp spec file private - not writing it.")
			return ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log("Could not open a temp spec file at '%s'." % path)
		return ""
	f.store_string(spec_text)
	f.close()
	return path


## Blocking p4 on the main thread - only for the pre-save hook (see
## _apply_changes), so it uses the short network limit and the circuit breaker
## applies to every command: a save never waits on a server that just failed.
func _p4_exec_sync(args: PackedStringArray) -> Dictionary:
	if _shutting_down:
		return {"exit_code": -1, "output": [""]}
	if _server_unreachable():
		return _skipped_result()
	var loud := _should_log_cmd(args)
	args = _with_connection_flags(_escape_path_args(args), NET_MAXWAIT_SAVE_SEC)
	if loud:
		_log_p4_cmd(args)
	var output := []
	var exit_code := OS.execute(_p4_cmd(), _os_args(args), output, true)
	var result := {"exit_code": exit_code, "output": output}
	_finish_p4_log(args, result, loud)
	_note_connectivity(result)
	_maybe_offer_login(result)
	return result


## Retained as a semantic alias; _p4_exec_sync now logs command and output.
func _p4_exec_logged_sync(args: PackedStringArray) -> Dictionary:
	return _p4_exec_sync(args)


## The oldest p4 client that understands `--progress=debug`. An older one
## rejects the whole command line, so the flag is only passed from here up.
const P4_PROGRESS_MIN_VERSION := 2021.1

## Self-tests only (see the lambda in _p4_exec_streamed).
var _selftest_cancel_on_progress: bool = false
## How the last _submit_changelist ended: "submitted", "not_submitted" or
## "unknown" ("" before any submit). For self-tests; nothing else reads it.
var _last_submit_outcome: String = ""

## The request _p4_exec_streamed is waiting on, so Cancel and editor shutdown
## can reach it. Only one runs at a time (the worker queue is serial).
var _streamed_req: P4Request = null


## Async `p4 <args>` for a transfer that can run long: a submit or a sync.
## Same queue and same result shape as _p4_exec, plus:
##   - `tracker` is fed p4's progress lines while the command runs, so a
##     progress window can show files and bytes as they move;
##   - the result carries `cancelled`, true if _cancel_streamed() stopped it;
##   - there is NO read time limit (`net.maxwait`). A transfer that is moving
##     can take as long as it takes, and one that isn't is the user's to stop:
##     the progress window says when nothing has moved and offers Cancel.
##
## `-Ztrack` asks the server for its tracking output, whose "rpc size" line is
## the only measure of what really crossed the network (it is what shows a
## Delta Transfer sending 6 MB of a 24 MB file). It reads 0 for a parallel
## transfer, whose traffic runs on other connections.
func _p4_exec_streamed(args: PackedStringArray, tracker: P4Progress) -> Dictionary:
	if _shutting_down:
		return {"exit_code": -1, "output": [""], "cancelled": false}
	var flags := PackedStringArray(["-Ztrack"])
	if _p4_version >= P4_PROGRESS_MIN_VERSION:
		flags.append("--progress=debug")
	var plain := _escape_path_args(args)
	if _p4_thread == null:
		var blocking := _p4_exec_sync(args)
		blocking["cancelled"] = false
		return blocking
	var loud := _should_log_cmd(args)
	var full := _with_connection_flags(flags + plain, 0)
	if loud:
		_log_p4_cmd(full)
	var req := P4Request.new()
	req.bin = _p4_cmd()
	req.args = full
	req.streamed = true
	req.lines.connect(func(batch: PackedStringArray) -> void:
		for line in batch:
			tracker.feed(line)
		_progress_last_activity_msec = Time.get_ticks_msec()
		# Self-tests only: press Cancel the moment the transfer is under way.
		if _selftest_cancel_on_progress and tracker.reporting:
			_selftest_cancel_on_progress = false
			_cancel_streamed())
	_streamed_req = req
	_p4_inflight += 1
	_p4_queue_mutex.lock()
	_p4_queue.push_back(req)
	_p4_queue_mutex.unlock()
	_p4_queue_semaphore.post()
	if not req.completed:
		await req.done
	_p4_inflight -= 1
	if _streamed_req == req:
		_streamed_req = null
	var result := {"exit_code": req.exit_code, "output": req.output, "cancelled": req.killed}
	_finish_p4_log(full, result, loud)
	if not req.killed:
		_note_connectivity(result)
		_maybe_offer_login(result)
	return result


## Stop the transfer _p4_exec_streamed is running. p4 is killed, so whatever
## it was doing is left half-done: the caller decides what that means (see
## _submit_verdict and _cleanup_cancelled_sync).
func _cancel_streamed() -> void:
	if _streamed_req != null:
		_streamed_req.cancel = true


## Log a p4 invocation's command line (truncated if enormous, e.g. a `where`
## over the whole opened set).
func _log_p4_cmd(args: PackedStringArray) -> void:
	var shown := PackedStringArray()
	for a in args:
		if not a.begins_with("-vnet.maxwait="): # on every command; just noise here
			shown.append(a)
	var line := "$ p4 " + " ".join(shown)
	if line.length() > 400:
		line = line.substr(0, 400) + " ... (%d args total)" % args.size()
	_log(line)


## Log a p4 result: its exit code when nonzero, then its (possibly truncated)
## output.
func _log_p4_result(result: Dictionary) -> void:
	if int(result.get("exit_code", 0)) != 0:
		_log("  (exit %d)" % int(result.exit_code))
	if not result.output.is_empty():
		var text := String(result.output[0]).strip_edges()
		if not text.is_empty():
			if text.length() > 2000:
				text = text.substr(0, 2000) + "\n  ... (output truncated)"
			_log(text)


## True if `args` is a read-only probe whose successful output is just noise
## unless Verbose logging is on. Mutating commands (edit, revert, sync, submit,
## reopen, reconcile, change -i/-d, ...) are never probes and always log.
func _is_probe_command(args: PackedStringArray) -> bool:
	if "-n" in args:
		return true # a dry-run preview (reconcile -n, revert -a -n) never mutates
	var sub := ""
	for a in args:
		if not a.begins_with("-"):
			sub = a
			break
	match sub:
		"info", "fstat", "opened", "where", "changes", "print", "have", "files", "dirs", \
		"diff", "diff2", "set", "clients":
			return true
		"change":
			return "-o" in args # change -o reads; change -i / -d mutate
		"login":
			return "-s" in args # login -s only reports ticket status
		_:
			return false


## Whether to log this command's line and its successful output right now.
func _should_log_cmd(args: PackedStringArray) -> bool:
	return _verbose_log or not _is_probe_command(args)


## Finish logging a p4 invocation. If the command line was logged, log its
## result. Otherwise (a quiet probe) stay silent UNLESS it failed - a failure is
## always surfaced, with its command line for context, even in non-verbose mode.
func _finish_p4_log(args: PackedStringArray, result: Dictionary, cmd_was_logged: bool) -> void:
	if cmd_was_logged:
		_log_p4_result(result)
	elif int(result.get("exit_code", 0)) != 0:
		_log_p4_cmd(args)
		_log_p4_result(result)


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
			var key: String = rest if sp == -1 else rest.substr(0, sp)
			if not _is_ztag_key(key):
				# A p4 message, not a field. p4 reports a refused file as a
				# bare line plus a "... " continuation whose first word is a
				# file path, with no blank line before whatever follows:
				#     //depot/f - can't edit exclusive file already opened
				#     ... //depot/f - also opened by user@client
				#     ... depotFile //depot/g        <- the next real record
				# Read as a field, that continuation opens a bogus record and
				# then swallows the next real record's fields into it. That
				# made a reconcile preview lose a file that needed opening,
				# and left a phantom record with no `action` that the dock
				# counted as an edit it could never open.
				if not current.is_empty():
					records.append(current)
					current = {}
				last_key = ""
				continue
			if sp == -1:
				current[key] = ""
			else:
				current[key] = rest.substr(sp + 1)
			last_key = key
		elif not current.is_empty() and not last_key.is_empty():
			current[last_key] = String(current[last_key]) + "\n" + line
	if not current.is_empty():
		records.append(current)
	return records


## Perforce tag names are bare identifiers: `depotFile`, `action`, `otherOpen0`,
## `how0,0`, `attr-name`. A "field name" holding a path separator, a drive
## colon or an `@` is really a message line - see _parse_ztag.
static func _is_ztag_key(key: String) -> bool:
	if key.is_empty():
		return false
	return not (key.contains("/") or key.contains("\\") or key.contains(":") \
			or key.contains("@"))


## The messages in a p4 command's output that say it would not, or did not,
## open a file: {"count": <refusals>, "lines": <refusals plus their detail
## lines>, "locked": <a +l file is held elsewhere>}.
##
## Reading the text is the only option here. p4 writes these to stderr, which
## shares the output blob, and it still exits 0 - `p4 reconcile` on a file
## another workspace holds exclusively reports the refusal and returns success
## (verified against a `+l` file opened by a second client).
func _refusals(result: Dictionary) -> Dictionary:
	var lines: Array = []
	var count := 0
	var locked := false
	var output: Array = result.get("output", [])
	if output.is_empty():
		return {"count": 0, "lines": lines, "locked": false}
	# OS.execute hands back one string holding the whole blob, not a line per
	# entry, so it has to be split here.
	for raw_line in String(output[0]).split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line.begins_with("... "):
			line = line.substr(4).strip_edges()
		if line.is_empty():
			continue
		var refusal: bool = line.contains("can't edit") or line.contains("can't add") \
				or line.contains("can't delete") or line.contains("can't open") \
				or line.contains("no permission for operation")
		if line.contains("exclusive file already opened"):
			locked = true
		if refusal:
			count += 1
			lines.append(line)
		elif line.contains("also opened by"):
			lines.append(line) # detail for the refusal above it
	return {"count": count, "lines": lines, "locked": locked}


## The alert text for files Perforce would not open. The exclusive-lock
## explanation only appears when a lock was actually the reason.
func _refusal_alert_text(refused: Dictionary) -> String:
	var text := "Perforce wouldn't let you take %d file(s):\n\n%s" \
			% [refused.count, _file_listing(refused.lines)]
	if refused.locked:
		text += ("\n\nThese files are set up so only one person can change them at a " +
				"time - studios do that for art, because two people's edits to the same " +
				"image can't be combined. The name after \"also opened by\" above is who " +
				"has it. Your work is safe on disk, but you can't send it to the server " +
				"until they finish with the file and let it go.")
	return text


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
		if req.streamed:
			_p4_run_streamed(req, output)
		elif req.stdin_path.is_empty():
			req.exit_code = OS.execute(req.bin, _os_args(req.args), output, true)
		else:
			req.exit_code = _p4_execute_with_stdin(req.bin, req.args, req.stdin_path, output)
		req.output = output
		req.call_deferred("_finish")


## Runs on the worker thread: p4 with its output read through pipes while it
## works, instead of collected at the end. Static - it touches only OS and the
## request - so it is thread-safe.
##
## Progress lines ("progress (...") and the server's tracking lines ("--- ...")
## are handed to the main thread as they arrive and kept OUT of the result.
## Everything else is collected into one text blob, the same shape OS.execute
## returns, so the callers' parsers don't need to know which way p4 was run.
##
## Arguments go to the process as they are. Godot starts it with CreateProcess
## on Windows and fork/execvp elsewhere - no shell - so the escaping _os_args
## does for OS.execute would corrupt them here.
static func _p4_run_streamed(req: P4Request, output: Array) -> void:
	var started: Dictionary = OS.execute_with_pipe(req.bin, req.args, false)
	if started.is_empty():
		req.exit_code = 127
		output.append("Couldn't start '%s'.\n" % req.bin)
		return
	var pipes: Array = [started["stdio"], started["stderr"]]
	var pid: int = started["pid"]
	var pending: Array = [PackedByteArray(), PackedByteArray()]
	# stdout and stderr are kept apart and joined at the end, stdout first. p4
	# writes its records to stdout and its messages (and progress) to stderr;
	# read through two pipes their true order is lost, and a message dropped
	# into the middle of a tagged record would corrupt it.
	var kept: Array = [[], []]
	var idle_polls := 0
	while true:
		# Sample "still running" BEFORE reading, so output written just before
		# p4 exits is still collected on this pass.
		var running := OS.is_process_running(pid)
		var batch := PackedStringArray()
		var got_data := false
		for i in 2:
			var pipe: FileAccess = pipes[i]
			var chunk: PackedByteArray = pipe.get_buffer(65536)
			if chunk.is_empty():
				continue
			got_data = true
			var buf: PackedByteArray = pending[i]
			buf.append_array(chunk)
			# Whole lines only: a chunk can end mid-line, or mid-character.
			var start := 0
			while true:
				var nl := buf.find(10, start)
				if nl == -1:
					break
				var line := _decode_p4_bytes(buf.slice(start, nl)).rstrip("\r")
				start = nl + 1
				if line.begins_with("progress (") or line.begins_with("--- "):
					batch.append(line)
				else:
					kept[i].append(line)
			pending[i] = buf.slice(start)
		if not batch.is_empty():
			req.call_deferred("_emit_lines", batch)
		if req.detach:
			# The editor is closing. Leave p4 running: a submit or download
			# that finishes by itself beats one cut off half-way.
			req.exit_code = -1
			break
		# Only a p4 that is still running can be cancelled. One that finished
		# in the same instant completed, and must be reported as completed.
		if req.cancel and not req.killed and running:
			req.killed = true
			OS.kill(pid)
		if not running and not got_data:
			# One more empty pass after exit, in case the pipe was still
			# filling when the first one looked.
			idle_polls += 1
			if idle_polls >= 2:
				break
			OS.delay_msec(10)
		elif not got_data:
			OS.delay_msec(30)
		else:
			idle_polls = 0
	var joined := PackedStringArray()
	for i in 2:
		var rest: PackedByteArray = pending[i]
		if not rest.is_empty():
			kept[i].append(_decode_p4_bytes(rest).rstrip("\r"))
		for line in kept[i]:
			joined.append(String(line))
	if not req.detach:
		req.exit_code = OS.get_process_exit_code(pid)
	output.append("\n".join(joined) + ("\n" if not joined.is_empty() else ""))


## p4's output bytes as text, decoded the way OS.execute decodes them, so a
## file name reads the same whichever way p4 was run. On Windows that is the
## system's ANSI code page first, UTF-8 if that fails (Godot's own order, in
## os_windows.cpp); elsewhere UTF-8.
static func _decode_p4_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	if OS.get_name() == "Windows":
		var text := bytes.get_string_from_multibyte_char()
		if not text.is_empty():
			return text
	return bytes.get_string_from_utf8()


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
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

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
## lock as the other dialogs. `multiline` picks a TextEdit vs a LineEdit;
## `secret` masks a single-line field (passwords).
func _show_input_dialog(title: String, message: String, default_text: String,
		multiline: bool, ok_text: String, secret: bool = false,
		extra_text: String = "") -> Dictionary:
	if _shutting_down:
		return {"ok": false, "text": "", "extra": false}
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false
	_dialog_result_extra = false

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.set_ok_button_text(ok_text)
	if not extra_text.is_empty():
		dialog.add_button(extra_text, true, "extra")
		dialog.custom_action.connect(_on_dialog_extra_action)
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
		# Ctrl+Enter accepts the dialog (P4V-style); plain Enter still newlines.
		# Routes through the dialog's `confirmed` signal (which sets the member
		# result flags), so the awaiting loop below sees it - a lambda writing a
		# local would not (see the _show_confirm_dialog note on lambda capture).
		var submit_on_ctrl_enter := func(event: InputEvent) -> void:
			if event is InputEventKey and event.pressed and not event.echo \
					and event.ctrl_pressed \
					and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
				te.accept_event()
				if is_instance_valid(dialog):
					dialog.confirmed.emit()
		te.gui_input.connect(submit_on_ctrl_enter)
		vbox.add_child(te)
		input = te
	else:
		var le := LineEdit.new()
		le.text = default_text
		le.secret = secret
		le.custom_minimum_size = Vector2(420, 0)
		vbox.add_child(le)
		input = le
	# Adding CONTENT children to the dialog is fine (and required); the
	# don't-parent-first caveat in _show_confirm_dialog is about the dialog node.
	dialog.add_child(vbox)
	# Plain Enter in a single-line field accepts the dialog.
	if not multiline:
		dialog.register_text_enter(input)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if _selftest_auto_answer == "confirm":
				dialog.confirmed.emit()
			elif _selftest_auto_answer == "extra" and not extra_text.is_empty():
				dialog.custom_action.emit(&"extra")
			else:
				dialog.canceled.emit()

	while not _dialog_result_ready:
		await get_tree().process_frame
	var confirmed := _dialog_result_confirmed
	var text: String = input.text if (confirmed and is_instance_valid(input)) else ""
	var extra := _dialog_result_extra
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed, "text": text, "extra": extra}


## Shows a modal dialog with a message and a dropdown of options; returns
## {ok: bool, index: int, extra: bool}. Used by connection setup to pick a
## workspace. `extra_text` adds a third button; pressing it closes the dialog
## with `extra` true and `ok` false.
func _show_option_dialog(title: String, message: String, options: PackedStringArray,
		preselect: int, ok_text: String, extra_text: String = "") -> Dictionary:
	if _shutting_down:
		return {"ok": false, "index": -1, "extra": false}
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false
	_dialog_result_extra = false

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.set_ok_button_text(ok_text)
	if not extra_text.is_empty():
		dialog.add_button(extra_text, true, "extra")
		dialog.custom_action.connect(_on_dialog_extra_action)
	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = message
	vbox.add_child(label)
	var picker := OptionButton.new()
	for opt in options:
		picker.add_item(opt)
	if preselect >= 0 and preselect < options.size():
		picker.select(preselect)
	picker.custom_minimum_size = Vector2(460, 0)
	vbox.add_child(picker)
	dialog.add_child(vbox)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if _selftest_auto_answer == "confirm":
				dialog.confirmed.emit()
			elif _selftest_auto_answer == "extra" and not extra_text.is_empty():
				dialog.custom_action.emit(&"extra")
			else:
				dialog.canceled.emit()

	while not _dialog_result_ready:
		await get_tree().process_frame
	var confirmed := _dialog_result_confirmed
	var extra := _dialog_result_extra
	var index: int = picker.selected if (confirmed and is_instance_valid(picker)) else -1
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed and index >= 0, "index": index, "extra": extra}


## The connection dialog: the server address and user name this project
## connects with. Returns {ok: bool, port: String, user: String}.
func _show_connection_dialog(port: String, user: String) -> Dictionary:
	if _shutting_down:
		return {"ok": false, "port": port, "user": user}
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.title = "P4 Connection Settings"
	dialog.set_ok_button_text("Connect")
	var vbox := VBoxContainer.new()
	var intro := Label.new()
	intro.text = ("Which Perforce server this project uses, and who you are on it.\n" +
			"Stored for this project only, for you only. Leave a box empty to use\n" +
			"your normal Perforce settings (a P4CONFIG file, or `p4 set`).")
	vbox.add_child(intro)
	var port_label := Label.new()
	port_label.text = "Server address:"
	vbox.add_child(port_label)
	var port_edit := LineEdit.new()
	port_edit.text = port
	port_edit.placeholder_text = "ssl:perforce.example.com:1666"
	port_edit.custom_minimum_size = Vector2(420, 0)
	vbox.add_child(port_edit)
	var user_label := Label.new()
	user_label.text = "User name:"
	vbox.add_child(user_label)
	var user_edit := LineEdit.new()
	user_edit.text = user
	vbox.add_child(user_edit)
	dialog.add_child(vbox)
	dialog.register_text_enter(port_edit)
	dialog.register_text_enter(user_edit)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

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
	var new_port: String = port_edit.text.strip_edges() if confirmed else port
	var new_user: String = user_edit.text.strip_edges() if confirmed else user
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed, "port": new_port, "user": new_user}


## The checkout prompt: a confirm dialog with a "Check out to:" dropdown of
## pending changelists (see _pending_changelist_choices). Returns {ok: bool,
## change: String} - `change` is "default" or a changelist number, valid only
## when ok. The dropdown defaults to the first choice (the default changelist).
func _show_checkout_target_dialog(text: String, ok_text: String,
		cancel_text: String, choices: Array) -> Dictionary:
	if _shutting_down:
		return {"ok": false, "change": "default"}
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.title = "Check Out"
	dialog.set_ok_button_text(ok_text)
	dialog.set_cancel_button_text(cancel_text)
	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = text
	vbox.add_child(label)
	var row := HBoxContainer.new()
	var row_label := Label.new()
	row_label.text = "Check out to:"
	row.add_child(row_label)
	var picker := OptionButton.new()
	for c in choices:
		picker.add_item(String(c.label))
	picker.select(0)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.custom_minimum_size = Vector2(280, 0)
	row.add_child(picker)
	vbox.add_child(row)
	dialog.add_child(vbox)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

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
	var change := "default"
	if confirmed and is_instance_valid(picker) \
			and picker.selected >= 0 and picker.selected < choices.size():
		change = String(choices[picker.selected].change)
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed, "change": change}


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
	dialog.popup_exclusive_centered(EditorInterface.get_base_control())

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


## A dialog's extra button (AcceptDialog.add_button) doesn't close it or emit
## `confirmed`; it emits `custom_action`. Recorded as "not confirmed, extra".
func _on_dialog_extra_action(_action: StringName) -> void:
	_dialog_result_confirmed = false
	_dialog_result_extra = true
	_dialog_result_ready = true


# ---------------------------------------------------------------------------
# Reloading files from disk
# ---------------------------------------------------------------------------

## Reloads res_path from disk, discarding any in-editor unsaved changes.
## Returns true when the editor's copy of the file demonstrably matches disk
## again - callers use that to decide whether they still have to suppress
## checkout prompts for the file.
func _reload_path(res_path: String) -> bool:
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


# ---------------------------------------------------------------------------
# FileSystem dock integration (native tooltips + right-click menu)
#
# Two Godot editor hooks, both reachable from GDScript (no GDExtension needed):
# EditorContextMenuPlugin adds Perforce actions to the FileSystem dock's
# right-click menu, and EditorResourceTooltipPlugin adds P4 status to a file's
# hover tooltip. Both delegate to the methods here, so they reuse the same
# worker-thread p4 plumbing as the rest of the plugin and never block the editor.
# ---------------------------------------------------------------------------

func _register_filesystem_hooks() -> void:
	var fsd := EditorInterface.get_file_system_dock()
	if fsd and fsd.has_method("add_resource_tooltip_plugin"):
		var tip := P4FileSystemTooltip.new()
		tip.plugin = self
		fsd.add_resource_tooltip_plugin(tip)
		_fs_tooltip = tip
	if ClassDB.class_exists("EditorContextMenuPlugin"):
		var menu := P4FileSystemContextMenu.new()
		menu.plugin = self
		add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, menu)
		_fs_context_menu = menu
	# Delete / move / rename done in the dock arrive as these signals (emitted
	# AFTER the on-disk change), so we react by recording the change in Perforce.
	if fsd:
		if fsd.has_signal("file_removed") and not fsd.file_removed.is_connected(_on_fs_file_removed):
			fsd.file_removed.connect(_on_fs_file_removed)
		if fsd.has_signal("folder_removed") and not fsd.folder_removed.is_connected(_on_fs_folder_removed):
			fsd.folder_removed.connect(_on_fs_folder_removed)
		if fsd.has_signal("files_moved") and not fsd.files_moved.is_connected(_on_fs_files_moved):
			fsd.files_moved.connect(_on_fs_files_moved)
		if fsd.has_signal("folder_moved") and not fsd.folder_moved.is_connected(_on_fs_folder_moved):
			fsd.folder_moved.connect(_on_fs_folder_moved)


func _unregister_filesystem_hooks() -> void:
	var fsd := EditorInterface.get_file_system_dock()
	if fsd:
		if fsd.has_signal("file_removed") and fsd.file_removed.is_connected(_on_fs_file_removed):
			fsd.file_removed.disconnect(_on_fs_file_removed)
		if fsd.has_signal("folder_removed") and fsd.folder_removed.is_connected(_on_fs_folder_removed):
			fsd.folder_removed.disconnect(_on_fs_folder_removed)
		if fsd.has_signal("files_moved") and fsd.files_moved.is_connected(_on_fs_files_moved):
			fsd.files_moved.disconnect(_on_fs_files_moved)
		if fsd.has_signal("folder_moved") and fsd.folder_moved.is_connected(_on_fs_folder_moved):
			fsd.folder_moved.disconnect(_on_fs_folder_moved)
	if _fs_tooltip and fsd and fsd.has_method("remove_resource_tooltip_plugin"):
		fsd.remove_resource_tooltip_plugin(_fs_tooltip)
	_fs_tooltip = null
	if _fs_context_menu:
		remove_context_menu_plugin(_fs_context_menu)
	_fs_context_menu = null


## The FileSystem-dock right-click actions as {label, method} - one source of
## truth shared by the live menu (_populate_fs_context_menu) and the headless
## self-test. Each method is a `_ctx_*` handler below that receives the selected
## res:// paths.
func _fs_context_actions() -> Array:
	return [
		{"label": "P4: Check Out", "method": "_ctx_checkout"},
		{"label": "P4: Mark for Add", "method": "_ctx_add"},
		{"label": "P4: Get Latest (Sync)", "method": "_ctx_sync"},
		{"label": "P4: Diff vs Depot", "method": "_ctx_diff"},
		{"label": "P4: Revert...", "method": "_ctx_revert"},
		{"label": "P4: Show Status in Log", "method": "_ctx_status"},
	]


## Called by P4FileSystemContextMenu._popup_menu: add the Perforce actions to the
## dock's right-click menu when the selection contains at least one file. Silent
## when Perforce is known-unavailable this session.
func _populate_fs_context_menu(menu: EditorContextMenuPlugin, paths: PackedStringArray) -> void:
	if _identity_checked and not _p4_available:
		return
	if _fs_files_only(paths).is_empty():
		return
	for action in _fs_context_actions():
		menu.add_context_menu_item(String(action.label), Callable(self, String(action.method)))


## The res:// file paths in `paths`, dropping folders (a trailing slash or an
## actual directory on disk): the file-oriented p4 actions here don't recurse.
func _fs_files_only(paths: PackedStringArray) -> Array:
	var files: Array = []
	for p in paths:
		var res := String(p)
		if res.ends_with("/"):
			continue
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(res)):
			continue
		files.append(res)
	return files


func _ctx_checkout(paths: PackedStringArray) -> void:
	for res in _fs_files_only(paths):
		await _checkout_path(res)


func _ctx_add(paths: PackedStringArray) -> void:
	for res in _fs_files_only(paths):
		await _add_path(res)


func _ctx_sync(paths: PackedStringArray) -> void:
	for res in _fs_files_only(paths):
		await _sync_path(res)


func _ctx_revert(paths: PackedStringArray) -> void:
	for res in _fs_files_only(paths):
		await _revert_path(res)


## Diff acts on one file (the diff window shows one file at a time); if several
## are selected, diff the first and say so.
func _ctx_diff(paths: PackedStringArray) -> void:
	var files := _fs_files_only(paths)
	if files.is_empty():
		return
	if files.size() > 1:
		_log("Diffing only '%s' (the first of %d selected files)." % [files[0], files.size()])
	await _diff_path(files[0])


func _ctx_status(paths: PackedStringArray) -> void:
	await _status_to_log(_fs_files_only(paths))


## Open res_path for add (`p4 add`). No-ops (with a p4 message) on already-tracked
## files. Refreshes the changelist tree.
func _add_path(res_path: String) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	await _p4_exec_logged(["add", ProjectSettings.globalize_path(res_path)])
	_request_refresh()


## Log a concise Perforce status line for each selected file - a quick read-only
## "where does P4 think this is" without leaving the editor. Also warms the hover
## tooltip cache for these files.
func _status_to_log(files: Array) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	for res in files:
		var rec := await _fetch_fstat_record(res)
		_log("P4 status: %s" % _fstat_summary_line(res, rec))


# --- Hover tooltip: a non-blocking per-file status cache -------------------

## Called by P4FileSystemTooltip._make_tooltip_for_path (synchronous): render
## whatever P4 status is cached for res_path, then kick a background refresh so a
## later hover is up to date.
func _on_tooltip_for_path(res_path: String, base: Control) -> void:
	_decorate_tooltip(res_path, base)
	if not res_path.ends_with("/"):
		_prefetch_fstat(res_path) # fire-and-forget coroutine


## Append cached P4 status rows to the base tooltip. Reads only the cache, so the
## first hover of a file (nothing cached yet) just shows Godot's default tooltip;
## the P4 rows appear from the second hover on, once the background fetch landed.
func _decorate_tooltip(res_path: String, base: Control) -> void:
	var cached: Variant = _fstat_cache.get(res_path)
	if cached == null or base == null:
		return
	var rec: Dictionary = cached.data
	base.add_child(HSeparator.new())
	if rec.is_empty() or not rec.has("depotFile"):
		_add_tooltip_label(base, "P4: not in Perforce", Color(0.6, 0.6, 0.6))
		return
	var have := String(rec.get("haveRev", "?"))
	var head := String(rec.get("headRev", have))
	_add_tooltip_label(base, "P4  %s#%s" % [rec.get("depotFile"), have], P4_ACCENT)
	if head != have:
		_add_tooltip_label(base, "head is #%s - out of date" % head, ACTION_DELETE_COLOR)
	if rec.has("action"):
		_add_tooltip_label(base, "opened for %s" % rec.get("action"), _action_color(String(rec.get("action"))))
	if rec.has("ourLock"):
		_add_tooltip_label(base, "locked by you", ACTION_EDIT_COLOR)
	var others := _fstat_other_openers(rec)
	if not others.is_empty():
		_add_tooltip_label(base, "also open by %s" % ", ".join(others), ACTION_DELETE_COLOR)


func _add_tooltip_label(base: Control, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	base.add_child(label)


## Background-refresh the cached fstat for a hovered file, skipping if one is
## already in flight or the cache entry is still fresh. Fire-and-forget: the
## tooltip callback calls this without awaiting.
func _prefetch_fstat(res_path: String) -> void:
	if _identity_checked and not _p4_available:
		return
	if _fstat_prefetch_inflight.has(res_path):
		return
	var cached: Variant = _fstat_cache.get(res_path)
	if cached != null and Time.get_unix_time_from_system() - float(cached.time) < FSTAT_CACHE_TTL_SEC:
		return
	_fstat_prefetch_inflight[res_path] = true
	await _fetch_fstat_record(res_path)
	_fstat_prefetch_inflight.erase(res_path)


## Run `p4 -ztag fstat` for one file, cache the parsed record (or {} if untracked/
## unavailable), and return it. Shared by the tooltip prefetch and Show Status.
func _fetch_fstat_record(res_path: String) -> Dictionary:
	if not await _ensure_identity():
		return {}
	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", ProjectSettings.globalize_path(res_path)]))
	var rec: Dictionary = recs[0] if not recs.is_empty() else {}
	_fstat_cache[res_path] = {"data": rec, "time": Time.get_unix_time_from_system()}
	return rec


## Everyone other than us who has the file open, from an fstat record's
## otherOpen0..N fields ("user@client").
func _fstat_other_openers(rec: Dictionary) -> Array:
	var openers: Array = []
	var i := 0
	while rec.has("otherOpen%d" % i):
		openers.append(String(rec.get("otherOpen%d" % i)))
		i += 1
	return openers


## A one-line human summary of an fstat record for res_path (for the log). An
## empty record means untracked/unknown.
func _fstat_summary_line(res_path: String, rec: Dictionary) -> String:
	if rec.is_empty() or not rec.has("depotFile"):
		return "%s - not in Perforce (or unknown)" % res_path
	var parts: Array = []
	var have := String(rec.get("haveRev", "?"))
	var head := String(rec.get("headRev", have))
	parts.append("%s#%s" % [rec.get("depotFile"), have])
	if head != have:
		parts.append("(head #%s - out of date)" % head)
	if rec.has("action"):
		parts.append("opened for %s" % rec.get("action"))
	if rec.has("ourLock"):
		parts.append("locked by you")
	var others := _fstat_other_openers(rec)
	if not others.is_empty():
		parts.append("also open by %s" % ", ".join(others))
	return "%s - %s" % [res_path, " ".join(parts)]


# ---------------------------------------------------------------------------
# FileSystem dock operations: delete / move / rename
#
# These FileSystemDock signals fire AFTER Godot has already changed the disk, so
# we can't intercept like checkout-on-edit does - we react, bringing Perforce in
# line with what the dock just did. A deletion becomes an open-for-delete; a
# move/rename is recorded with `p4 reconcile -M` (Perforce move detection), which
# preserves history when the file's content is unchanged and degrades to a
# delete + add when Godot rewrote it during the move. These prompt by default;
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
	await _p4_open_for_delete(res_path, decision)
	_forget_path(res_path)
	# Godot deletes an asset's .import (and a script's .uid) along with it.
	for sidecar: String in _sidecars_of(res_path):
		if FileAccess.file_exists(ProjectSettings.globalize_path(sidecar)):
			continue
		var side_decision := _delete_action_for(await _fetch_fstat_record(sidecar))
		if side_decision != "none":
			await _p4_open_for_delete(sidecar, side_decision)
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
	if not await _confirm_fs_action(
			("You moved '%s'\n     -> '%s'.\n\nRecord this as a Perforce move? It preserves the " +
			"file's history (and falls back to delete + add if the contents changed during the " +
			"move).") % [old_res, new_res], "Record Move", "Skip"):
		_log("Move of '%s' not recorded in Perforce - run Reconcile if you want it tracked." % old_res)
		return
	var result := await _p4_record_move(old_res, new_res, is_folder)
	if result.exit_code != 0:
		var msg := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		await _show_alert(("Couldn't record the move of '%s' in Perforce:\n\n%s\n\nThe files are " +
				"already moved on disk - use Reconcile to record it.") % [old_res, msg])
	else:
		_forget_path(old_res)
		if not is_folder:
			_checked_out_this_session[new_res] = true
	_request_refresh()


## How to record a single-file deletion, from its `-ztag fstat` record. Pure, so
## a headless self-test can pin the mapping:
## - "none":      untracked, or already deleted at head - nothing to do.
## - "revert":    only open for add (never in the depot) - undo the pending add.
## - "reconcile": tracked (opened for edit or not) but now missing on disk -
##                `p4 reconcile -d` records the delete without restoring the file.
func _delete_action_for(rec: Dictionary) -> String:
	if rec.is_empty() or not rec.has("depotFile"):
		return "none"
	var act := String(rec.get("action", ""))
	if act == "add" or act == "move/add":
		return "revert"
	if act == "" and String(rec.get("headAction", "")) in ["delete", "move/delete"]:
		return "none"
	return "reconcile"


func _p4_open_for_delete(res_path: String, decision: String) -> void:
	var global_path := ProjectSettings.globalize_path(res_path)
	match decision:
		"revert":
			await _p4_exec_logged(["revert", global_path])
		"reconcile":
			await _p4_exec_logged(["reconcile", "-d", global_path])


## Record a move via `p4 reconcile -M`, scoped to just the two paths plus their
## sidecars (or the two subtrees for a folder). Move detection pairs the now-missing source with the
## new file by content: matched -> a history-preserving move/delete + move/add;
## unmatched (Godot rewrote it) -> a plain delete + add.
func _p4_record_move(old_res: String, new_res: String, is_folder: bool) -> Dictionary:
	var old_g := ProjectSettings.globalize_path(old_res)
	var new_g := ProjectSettings.globalize_path(new_res)
	if is_folder:
		old_g = _as_recursive(old_g)
		new_g = _as_recursive(new_g)
		return await _p4_exec_logged(["reconcile", "-M", old_g, new_g])
	var args: PackedStringArray = ["reconcile", "-M", old_g, new_g]
	# Godot moved the .import / .uid sidecar too; record it in the same pass.
	for i in _sidecars_of(old_res).size():
		var new_side := ProjectSettings.globalize_path(_sidecars_of(new_res)[i])
		if FileAccess.file_exists(new_side):
			args.append_array([ProjectSettings.globalize_path(_sidecars_of(old_res)[i]), new_side])
	return await _p4_exec_logged(args)


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
	_selftest_mode = true
	# The focus-in / filesystem_changed scan would otherwise fire in the
	# middle of whatever a test is doing and reconcile the workspace behind
	# its back, which makes every live test's result depend on what else was
	# lying around. The external-scan test turns it back on for itself.
	if detect_external_checkbox:
		detect_external_checkbox.set_pressed_no_signal(false)
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
			var basic_ok := false
			if recs.size() == 2:
				_log("[selftest] rec0 action=%s change=%s" % [recs[0].get("action", "?"), recs[0].get("change", "?")])
				var desc_lines := String(recs[1].get("desc", "")).split("\n").size()
				_log("[selftest] rec1 change=%s desc-lines=%d" % [recs[1].get("change", "?"), desc_lines])
				basic_ok = recs[0].get("action") == "edit" and recs[0].get("change") == "default" \
						and recs[1].get("change") == "123" and desc_lines == 2
				if not basic_ok:
					_log("[selftest] FAIL: parse-ztag field mismatch")
			else:
				_log("[selftest] FAIL: parse-ztag expected 2 records")

			# A refused file, copied from what the server really prints: a bare
			# message line, then a "... " detail line whose first word is a
			# depot path, then the NEXT record with no blank line between.
			# Treating that detail line as a field used to open a bogus record
			# and swallow the following record's fields, which lost a file
			# from the reconcile preview and left a phantom "1 edit" the dock
			# could never open.
			var refused_blob := "//depot/proj/locked.tscn - can't edit exclusive file already opened\n" \
					+ "... //depot/proj/locked.tscn - also opened by bob@bob_ws\n" \
					+ "... depotFile //depot/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n... action edit\n... type text\n\n" \
					+ "... depotFile //depot/proj/new.txt\n" \
					+ "... clientFile C:\\ws\\proj\\new.txt\n... action add\n... type text\n\n"
			var rrecs := _parse_ztag({"exit_code": 0, "output": [refused_blob]})
			var actions: Array = []
			for r in rrecs:
				actions.append(r.get("action", "<none>"))
			_log("[selftest] refusal blob -> %d record(s), actions=%s" % [rrecs.size(), actions])
			var kept_edit: bool = rrecs.size() == 2 \
					and rrecs[0].get("action", "") == "edit" \
					and rrecs[0].get("depotFile", "") == "//depot/proj/level.gd" \
					and rrecs[1].get("action", "") == "add"
			# No message text may leak into a record as a field name.
			var clean_keys := true
			for r in rrecs:
				for k in r.keys():
					if not _is_ztag_key(String(k)):
						clean_keys = false
						_log("[selftest] leaked field name: %s" % k)

			# A refusal on its own has to produce NO records. As a record it
			# carries no `action`, and the dock counted that as an edit - the
			# phantom "1 file to edit" that came back after every reconcile
			# and that clicking Reconcile could never clear.
			var only_refusal := "//depot/proj/locked.tscn - can't edit exclusive file already opened\n" \
					+ "... //depot/proj/locked.tscn - also opened by bob@bob_ws\n"
			var orecs := _parse_ztag({"exit_code": 0, "output": [only_refusal]})
			_log("[selftest] refusal-only blob -> %d record(s)" % orecs.size())
			var no_phantom: bool = orecs.is_empty()

			var refused := _refusals({"exit_code": 0, "output": [refused_blob]})
			_log("[selftest] refusals: count=%d locked=%s" % [refused.count, refused.locked])
			var refusal_ok: bool = int(refused.count) == 1 and bool(refused.locked) \
					and refused.lines.size() == 2
			if not no_phantom:
				_log("[selftest] FAIL: parse-ztag - a refusal became a phantom record")
			elif not clean_keys:
				_log("[selftest] FAIL: parse-ztag - message text leaked into a record")
			elif basic_ok and kept_edit and refusal_ok and no_phantom and clean_keys:
				_log("[selftest] PASS: parse-ztag")
			elif not kept_edit:
				_log("[selftest] FAIL: parse-ztag - a p4 message corrupted the record stream")
			elif not refusal_ok:
				_log("[selftest] FAIL: parse-ztag - refusal detection")
			get_tree().quit()
			return
		if arg == "--p4-selftest-sync-report":
			# Server-independent: the `p4 sync` output shapes whose records say
			# the wrong thing, copied from what a 2025.2 server really printed.
			# It asserts on the two user-facing strings as well as the parsers,
			# because the parsers were never where a lie would reach the user.
			#
			# (a) A refused overwrite. `sync -n` predicts nothing, and the
			# failing sync prints a perfectly normal `action updated` record for
			# the file alongside "Can't clobber writable file <path>", exiting
			# 1. Counting records reports that file as downloaded when the
			# user's own version is still sitting there.
			var clobber_blob := "//d/proj/nope.txt - no such file(s).\n" \
					+ "... depotFile //d/proj/.p4ignore\n" \
					+ "... clientFile C:\\ws\\proj\\.p4ignore\n" \
					+ "... rev 3\n... action updated\n... fileSize 14625\n" \
					+ "... totalFileSize 25044\n... totalFileCount 2\n... change 3132\n\n" \
					+ "Can't clobber writable file C:\\ws\\proj\\.p4ignore\n" \
					+ "... depotFile //d/proj/level.tscn\n" \
					+ "... clientFile C:\\ws\\proj\\level.tscn\n" \
					+ "... rev 2\n... action updated\n... fileSize 10419\n\n"
			var cres := {"exit_code": 1, "output": [clobber_blob]}
			var crecs := _parse_ztag(cres)
			var csum := _summarize_sync(crecs)
			var cnotes := _sync_notes(cres)
			var no_reload := {"reloaded": [], "orphaned": []}
			var creport := _get_latest_report(csum, cnotes, no_reload, [], 1)
			_log("[selftest] clobber blob -> %d record(s), %d changed, clobbered=%s, problems=%s"
					% [crecs.size(), csum.updates, cnotes.clobbered, cnotes.problems])
			_log("[selftest] clobber report: %s" % creport.replace("\n", " | "))
			# The report must count ONE download, not two, and must name the
			# file it could not write. "problems" must stay empty: the tagged
			# lines are fields, and "no such file(s)" is nothing to act on.
			var clobber_ok: bool = crecs.size() == 2 and int(csum.updates) == 2 \
					and cnotes.clobbered.size() == 1 \
					and String(cnotes.clobbered[0]) == "C:\\ws\\proj\\.p4ignore" \
					and cnotes.problems.is_empty() \
					and creport.contains("downloaded 1 file(s)") \
					and not creport.contains("downloaded 2 file(s)") \
					and creport.contains("would not overwrite") \
					and creport.contains("C:\\ws\\proj\\.p4ignore")

			# (b) A file you have checked out that is behind the server. p4
			# emits NO record for it, only messages, so counting records makes a
			# sync with real work to do look like "already up to date".
			var opened_blob := "//d/proj/.p4ignore#3 - is opened and not being changed\n" \
					+ "... //d/proj/.p4ignore - must resolve #2,#3 before submitting\n"
			var ores := {"exit_code": 0, "output": [opened_blob]}
			var osum := _summarize_sync(_parse_ztag(ores))
			var onotes := _sync_notes(ores)
			var has_work: bool = _get_latest_has_work(osum, onotes)
			var empty_notes := _sync_notes({"exit_code": 0, "output": ["... - file(s) up-to-date.\n"]})
			var idle_is_idle: bool = not _get_latest_has_work(
					_summarize_sync([]), empty_notes)
			_log("[selftest] opened-behind blob -> %d to write, opened_behind=%d, has_work=%s, idle-blob has_work=%s"
					% [osum.names.size(), onotes.opened_behind, has_work, not idle_is_idle])
			var opened_ok: bool = osum.names.is_empty() and int(onotes.opened_behind) == 1 \
					and onotes.problems.is_empty() and has_work and idle_is_idle

			# (c) sync's action vocabulary is its own: `added` is a file that
			# wasn't on disk yet, `deleted` one being removed from disk - not
			# reconcile's "open for add" / "open for delete". totalFileSize is
			# deliberately NOT the sum of the fileSizes, so summing and reading
			# the total can be told apart.
			var mixed_blob := "... depotFile //d/proj/new.png\n" \
					+ "... clientFile C:\\ws\\proj\\new.png\n" \
					+ "... rev 1\n... action added\n... fileSize 2048\n" \
					+ "... totalFileSize 999999\n... totalFileCount 3\n... change 9\n\n" \
					+ "... depotFile //d/proj/gone.tscn\n" \
					+ "... clientFile C:\\ws\\proj\\gone.tscn\n" \
					+ "... rev 1\n... action deleted\n... fileSize 0\n\n" \
					+ "... depotFile //d/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n" \
					+ "... rev 4\n... action updated\n... fileSize 1024\n\n"
			var msum := _summarize_sync(_parse_ztag({"exit_code": 0, "output": [mixed_blob]}))
			_log("[selftest] mixed blob -> %d new, %d changed, %d removed, %s, first=%s, deleted=%s"
					% [msum.adds, msum.updates, msum.deletes, _human_bytes(int(msum.bytes)),
					"" if msum.names.is_empty() else msum.names[0], msum.deleted_names])
			var mixed_ok: bool = int(msum.adds) == 1 and int(msum.updates) == 1 \
					and int(msum.deletes) == 1 and int(msum.bytes) == 3072 \
					and msum.names.size() == 3 \
					and String(msum.names[0]).ends_with("gone.tscn") \
					and msum.deleted_names.size() == 1 \
					and String(msum.deleted_names[0]).ends_with("gone.tscn")

			# (d) The confirmation carries every warning the user gets before a
			# project-wide download, and none of it was reachable by a test
			# while it lived inside the dialog call. Two open files here: one
			# being rewritten (its tab reloads, unsaved work is lost) and one
			# being deleted (its tab CANNOT reload, and saving it would put the
			# file back into the depot).
			var open_files := {"C:\\ws\\proj\\level.gd": true, "C:\\ws\\proj\\gone.tscn": true}
			var confirm := _get_latest_confirm_text(msum, {"opened_behind": 2}, open_files)
			_log("[selftest] confirm text: %s" % confirm.replace("\n", " | "))
			var confirm_ok: bool = confirm.contains("didn't save is lost") \
					and confirm.contains("C:\\ws\\proj\\level.gd") \
					and confirm.contains("CAREFUL") \
					and confirm.contains("put the file back") \
					and confirm.contains("C:\\ws\\proj\\gone.tscn") \
					and confirm.contains("checked out that are behind the server") \
					and confirm.contains("remove 1 from your project folder")

			# (e) p4 writes its messages to stderr and its records to stdout,
			# and OS.execute merges both into one blob, so a message can land
			# mid-record. That leaves a record with no clientFile and a
			# clientFile with a newline in it. Silently dropping those would
			# take a real file out of the download list and out of the reload
			# set with it, so they are counted and the user is told the list may
			# be short.
			var torn_blob := "... depotFile //d/proj/a.tscn\n" \
					+ "//d/proj/b.gd#3 - is opened and not being changed\n" \
					+ "... //d/proj/b.gd - must resolve #2,#3 before submitting\n" \
					+ "... clientFile C:\\ws\\proj\\a.tscn\n"
			var tsum := _summarize_sync(_parse_ztag({"exit_code": 0, "output": [torn_blob]}))
			var tconfirm := _get_latest_confirm_text(tsum, {"opened_behind": 0}, {})
			_log("[selftest] torn blob -> %d usable, %d unreadable" % [tsum.names.size(), tsum.malformed])
			var torn_ok: bool = int(tsum.malformed) > 0 \
					and tconfirm.contains("couldn't be read")

			# (f) The two after-the-fact outcomes the user has to act on by
			# hand: a tab left open on a deleted file, and a file that now needs
			# the two versions combined. Both are reported from data the records
			# don't carry, so both need asserting.
			var orphan_reload := {"reloaded": [], "orphaned": ["res://gone.tscn"]}
			var quiet_notes := {"clobbered": [], "opened_behind": 0, "problems": [],
					"nothing_in_depot": false}
			var handwork := _get_latest_report(msum, quiet_notes, orphan_reload,
					["res://player.gd"], 0)
			_log("[selftest] hand-work report: %s" % handwork.replace("\n", " | "))
			var handwork_ok: bool = handwork.contains("res://gone.tscn") \
					and handwork.contains("WITHOUT saving") \
					and handwork.contains("res://player.gd") \
					and handwork.contains("Resolve") \
					and handwork.contains("removed 1 file(s)")

			# (g) A sync that failed for a reason p4 didn't explain must not
			# read as success.
			var silent_fail := _get_latest_report(_summarize_sync([]), quiet_notes,
					no_reload, [], 1)
			_log("[selftest] silent-failure report: %s" % silent_fail.replace("\n", " | "))
			var silent_ok: bool = silent_fail.contains("didn't say why")

			# (h) `sync -s` refusing to overwrite a file whose contents changed
			# without a checkout - the macOS/Linux "saved over a read-only file"
			# case. Copied from a 2025.2 server: one message per file, NO record,
			# exit code 0. Read as "nothing to say", that is a project silently
			# left behind the server; read as a download, it is a lie.
			var modified_blob := "//d/proj/.p4ignore#3 - can't update modified file " \
					+ "C:\\ws\\proj\\.p4ignore\n" \
					+ "//d/proj/project.godot#5 - can't update modified file " \
					+ "C:\\ws\\proj\\project.godot\n" \
					+ "... depotFile //d/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n" \
					+ "... rev 4\n... action updated\n... fileSize 1024\n\n"
			var mres := {"exit_code": 0, "output": [modified_blob]}
			var mnotes := _sync_notes(mres)
			var mdone := _summarize_sync(_parse_ztag(mres))
			var mreport := _get_latest_report(mdone, mnotes, no_reload, [], 0)
			var mconfirm := _get_latest_confirm_text(mdone, mnotes, {})
			var only_modified := _sync_notes({"exit_code": 0, "output": [
					"//d/proj/.p4ignore#3 - can't update modified file C:\\ws\\proj\\.p4ignore\n"]})
			# The third refusal: the server adds a file where an untracked one of
			# the same name already sits. Reconcile is the wrong advice for it.
			var enotes := _sync_notes({"exit_code": 0, "output": [
					"//d/proj/notes.md#1 - can't overwrite existing file C:\\ws\\proj\\notes.md\n"]})
			var ereport := _get_latest_report(_summarize_sync([]), enotes, no_reload, [], 0)
			_log("[selftest] existing-file report: %s" % ereport.replace("\n", " | "))
			# A success p4 reports in words in the middle of tagged output must not
			# be listed under "Perforce also said" (seen after a cancelled sync).
			var wordy := _sync_notes({"exit_code": 0, "output": [
					"... depotFile //d/proj/a.png\n... clientFile C:\\ws\\proj\\a.png\n... rev 2\n" \
					+ "... action added\n... fileSize 9\n\n" \
					+ "//d/proj/a.png.import#1 - added as C:\\ws\\proj\\a.png.import\n" \
					+ "//d/proj/odd.txt#1 - some message nobody anticipated\n"]})
			var existing_ok: bool = wordy.problems.size() == 1 \
					and String(wordy.problems[0]).contains("nobody anticipated") \
					and enotes.existing.size() == 1 and enotes.problems.is_empty() \
					and enotes.modified.is_empty() \
					and ereport.contains("C:\\ws\\proj\\notes.md") \
					and ereport.contains("Move or rename") and not ereport.contains("Reconcile")
			_log("[selftest] modified blob -> modified=%s, clobbered=%s, problems=%s, %d record(s)"
					% [mnotes.modified, mnotes.clobbered, mnotes.problems, mdone.names.size()])
			_log("[selftest] modified report: %s" % mreport.replace("\n", " | "))
			var modified_ok: bool = mnotes.modified.size() == 2 \
					and String(mnotes.modified[0]) == "C:\\ws\\proj\\.p4ignore" \
					and mnotes.clobbered.is_empty() and mnotes.problems.is_empty() \
					and mdone.names.size() == 1 \
					and mreport.contains("downloaded 1 file(s)") \
					and mreport.contains("would not overwrite 2 file(s)") \
					and mreport.contains("C:\\ws\\proj\\project.godot") \
					and mreport.contains("Reconcile") \
					and mconfirm.contains("will NOT be downloaded") \
					and mconfirm.contains("C:\\ws\\proj\\.p4ignore") \
					and only_modified.modified.size() == 1 \
					and not _get_latest_has_work(_summarize_sync([]), only_modified) \
					and existing_ok

			if clobber_ok and opened_ok and mixed_ok and confirm_ok and torn_ok \
					and handwork_ok and silent_ok and modified_ok:
				_log("[selftest] PASS: sync-report")
			elif not modified_ok:
				_log("[selftest] FAIL: sync-report - a file safe sync refused to overwrite wasn't reported")
			elif not clobber_ok:
				_log("[selftest] FAIL: sync-report - a refused overwrite read as a successful download")
			elif not opened_ok:
				_log("[selftest] FAIL: sync-report - a checked-out file behind the server read as nothing to do")
			elif not mixed_ok:
				_log("[selftest] FAIL: sync-report - wrong counts for sync's own actions")
			elif not confirm_ok:
				_log("[selftest] FAIL: sync-report - the confirmation dropped a data-loss warning")
			elif not torn_ok:
				_log("[selftest] FAIL: sync-report - an unreadable record was dropped silently")
			elif not handwork_ok:
				_log("[selftest] FAIL: sync-report - the report didn't name the work left to do by hand")
			else:
				_log("[selftest] FAIL: sync-report - an unexplained failure read as success")
			get_tree().quit()
			return
		if arg == "--p4-selftest-unchanged-save":
			# Server-independent: a failed safe-save's leftover .tmp vs the disk
			# file. Same text modulo CRLF -> unchanged (and the tmp is deleted);
			# different text -> changed; binary extension gets no CRLF tolerance.
			var base := OS.get_cache_dir().path_join("p4_unchg_test.tscn")
			var tmp := base + "1234.tmp"
			var f := FileAccess.open(base, FileAccess.WRITE)
			f.store_string("line1\r\nline2\r\n")
			f.close()
			f = FileAccess.open(tmp, FileAccess.WRITE)
			f.store_string("line1\nline2\n")
			f.close()
			var same := _failed_write_was_unchanged(base)
			var tmp_deleted := not FileAccess.file_exists(tmp)
			f = FileAccess.open(tmp, FileAccess.WRITE)
			f.store_string("line1\nlineX\n")
			f.close()
			var diff_detected := not _failed_write_was_unchanged(base)
			var bin_base := OS.get_cache_dir().path_join("p4_unchg_test.res")
			var bin_tmp := bin_base + "1234.tmp"
			f = FileAccess.open(bin_base, FileAccess.WRITE)
			f.store_string("line1\r\nline2\r\n")
			f.close()
			f = FileAccess.open(bin_tmp, FileAccess.WRITE)
			f.store_string("line1\nline2\n")
			f.close()
			var bin_strict := not _failed_write_was_unchanged(bin_base)
			for leftover in [base, tmp, bin_base, bin_tmp]:
				DirAccess.remove_absolute(leftover)
			_log("[selftest] unchanged=%s tmp-deleted=%s diff-detected=%s bin-strict=%s"
					% [same, tmp_deleted, diff_detected, bin_strict])
			if same and tmp_deleted and diff_detected and bin_strict:
				_log("[selftest] PASS: unchanged-save")
			else:
				_log("[selftest] FAIL: unchanged-save")
			get_tree().quit()
			return
		if arg == "--p4-selftest-dismiss-dialog":
			# Server-independent. The no-op-save dismissal must hide (1) a bare
			# AcceptDialog whose dialog_text mentions the file and (2) a
			# Load-Errors-shaped dialog (empty dialog_text, error lines in a
			# RichTextLabel child) once every line is covered - and must leave
			# (3) a mixed dialog with an uncovered line, and ConfirmationDialogs
			# (all of the plugin's own dialogs), untouched.
			_selftest_auto_answer = "confirm" # resolves case 3's fallback alert
			var gui := EditorInterface.get_base_control()
			var ours := ConfirmationDialog.new()
			ours.dialog_text = "Check out level.tscn?"
			gui.add_child(ours)
			ours.visible = true

			var bare := AcceptDialog.new()
			bare.dialog_text = "Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions."
			gui.add_child(bare)
			bare.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var bare_hidden := not bare.visible
			bare.queue_free()

			var loaderr := AcceptDialog.new()
			var rtl := RichTextLabel.new()
			rtl.text = " Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions.\n" \
					+ " Unable to write to file 'C:\\ws\\level\\tileset\\tileset.tres', file in use, locked or lacking permissions."
			loaderr.add_child(rtl)
			gui.add_child(loaderr)
			loaderr.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			_queue_error_dialog_dismissal("res://level/tileset/tileset.tres")
			while _error_dismiss_running:
				await get_tree().process_frame
			var loaderr_hidden := not loaderr.visible
			loaderr.queue_free()

			var mixed := AcceptDialog.new()
			var rtl2 := RichTextLabel.new()
			rtl2.text = " Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions.\n" \
					+ " Unable to write to file 'C:\\ws\\other.tscn', file in use, locked or lacking permissions."
			mixed.add_child(rtl2)
			gui.add_child(mixed)
			mixed.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var mixed_untouched: bool = mixed.visible
			var ours_untouched: bool = ours.visible
			mixed.queue_free()
			ours.queue_free()

			# A real failure for a DIFFERENT file whose name merely ends with
			# the registered one must stay up. Matching the bare file name
			# anywhere in the line dismissed this, hiding a genuine error.
			var lookalike := AcceptDialog.new()
			lookalike.dialog_text = "Unable to write to file 'C:\\ws\\sublevel.tscn', file in use, locked or lacking permissions."
			gui.add_child(lookalike)
			lookalike.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var lookalike_untouched: bool = lookalike.visible
			lookalike.queue_free()

			_log("[selftest] bare-hidden=%s loaderr-hidden=%s mixed-untouched=%s ours-untouched=%s lookalike-untouched=%s"
					% [bare_hidden, loaderr_hidden, mixed_untouched, ours_untouched, lookalike_untouched])
			if bare_hidden and loaderr_hidden and mixed_untouched and ours_untouched \
					and lookalike_untouched:
				_log("[selftest] PASS: dismiss-dialog")
			else:
				_log("[selftest] FAIL: dismiss-dialog")
			get_tree().quit()
			return
		if arg == "--p4-selftest-prewrite":
			# Server-independent: the pre-write-pass helpers on a real temp
			# file - the writable flip both ways, the CRLF-tolerant unchanged
			# classification, real-change detection, and backup restore.
			var target := OS.get_cache_dir().path_join("p4_prewrite_test.tscn")
			var f2 := FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\r\nnode B\r\n")
			f2.close()
			var ro_ok := _set_file_writable(target, false)
			var locked := FileAccess.open(target, FileAccess.READ_WRITE) == null
			var backup := _prewrite_backup_path("res://p4_prewrite_test.tscn")
			var copied := DirAccess.copy_absolute(target, backup) == OK
			var rw_ok := _set_file_writable(target, true)
			var unlocked := FileAccess.open(target, FileAccess.READ_WRITE) != null
			f2 = FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\nnode B\n") # the editor's rewrite: same content, LF
			f2.close()
			var same := _contents_match(FileAccess.get_file_as_bytes(target),
					FileAccess.get_file_as_bytes(backup), "tscn")
			f2 = FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\nnode CHANGED\n")
			f2.close()
			var diff_detected := not _contents_match(FileAccess.get_file_as_bytes(target),
					FileAccess.get_file_as_bytes(backup), "tscn")
			var restored := DirAccess.copy_absolute(backup, target) == OK \
					and FileAccess.get_file_as_bytes(target) == FileAccess.get_file_as_bytes(backup)
			_set_file_writable(target, true)
			DirAccess.remove_absolute(target)
			DirAccess.remove_absolute(backup)
			_log("[selftest] ro=%s locked=%s copied=%s rw=%s unlocked=%s same=%s diff=%s restored=%s"
					% [ro_ok, locked, copied, rw_ok, unlocked, same, diff_detected, restored])
			if ro_ok and locked and copied and rw_ok and unlocked and same and diff_detected and restored:
				_log("[selftest] PASS: prewrite")
			else:
				_log("[selftest] FAIL: prewrite")
			get_tree().quit()
			return
		if arg == "--p4-selftest-special-names":
			# Live and DESTRUCTIVE (four real submits): files named with @ # %
			# through the plugin's add, submit, checkout, diff, move and delete
			# paths. Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: special-names - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var dir := "res://p4g_special_names_test"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			var names := ["icon@2x.txt", "take#1.txt", "50%.txt"]
			var ok := true
			for n: String in names:
				var fw := FileAccess.open(ProjectSettings.globalize_path(dir.path_join(n)), FileAccess.WRITE)
				fw.store_string("special name %s\n" % n)
				fw.close()
				await _add_path(dir.path_join(n))
				var added := String((await _fetch_fstat_record(dir.path_join(n))).get("action", "")) == "add"
				_log("[selftest] add %s -> %s" % [n, added])
				ok = ok and added
			await _submit_changelist("default", [], "P4Godot selftest: special file names")
			var edit_res := dir.path_join("icon@2x.txt")
			var co: Dictionary = await _do_checkout(edit_res)
			var fw2 := FileAccess.open(ProjectSettings.globalize_path(edit_res), FileAccess.WRITE)
			fw2.store_string("special name icon@2x.txt\nchanged\n")
			fw2.close()
			var diff := await _p4_exec(["diff", "-dul", ProjectSettings.globalize_path(edit_res)])
			var diff_ok := int(diff.exit_code) == 0 and _diff_has_changes(String(diff.output[0]))
			var depot := _diff_depot_path(String(diff.output[0]), "")
			var have := await _p4_exec(["print", "-q", depot + "#have"])
			var print_ok := int(have.exit_code) == 0 and String(have.output[0]).contains("special name")
			await _p4_exec_logged(["revert", ProjectSettings.globalize_path(edit_res)])
			_log("[selftest] checkout=%s diff=%s print-have=%s" % [co.ok, diff_ok, print_ok])
			ok = ok and co.ok and diff_ok and print_ok
			var old_res := dir.path_join("take#1.txt")
			var new_res := dir.path_join("take#2.txt")
			DirAccess.rename_absolute(ProjectSettings.globalize_path(old_res), ProjectSettings.globalize_path(new_res))
			await _p4_record_move(old_res, new_res, false)
			var moved := String((await _fetch_fstat_record(new_res)).get("action", "")) == "move/add"
			_log("[selftest] move take#1 -> take#2: %s" % moved)
			ok = ok and moved
			await _submit_changelist("default", [], "P4Godot selftest: special names move")
			for n: String in ["icon@2x.txt", "take#2.txt", "50%.txt"]:
				await _p4_exec_logged(["delete", ProjectSettings.globalize_path(dir.path_join(n))])
			await _submit_changelist("default", [], "P4Godot selftest: special names cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			for n: String in ["icon@2x.txt", "take#2.txt", "50%.txt"]:
				var st := await _fetch_fstat_record(dir.path_join(n))
				ok = ok and String(st.get("headAction", "")) == "delete"
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: special-names" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-breaker":
			# Live, read-only: point at an unroutable server once (one ~21 s
			# connect timeout), then check that save-path and status calls return
			# instantly while connection probes still try.
			var saved_port := _override_port
			_override_port = "10.255.255.1:1666"
			var first := await _p4_exec(["-ztag", "fstat", "C:/nothing"])
			var tripped := _server_unreachable()
			var t0 := Time.get_ticks_msec()
			var sync_r := _p4_exec_sync(["fstat", "C:/nothing"])
			var async_r := await _p4_exec(["-ztag", "opened"])
			var fast_ms := Time.get_ticks_msec() - t0
			var skipped: bool = String(sync_r.output[0]).contains("skipped") \
					and String(async_r.output[0]).contains("skipped")
			_override_port = saved_port
			_unreachable_until_msec = 0
			_log("[selftest] first-exit=%d tripped=%s skipped=%s fast=%dms" % [int(first.exit_code), tripped, skipped, fast_ms])
			_log("[selftest] %s: breaker" % ("PASS" if tripped and skipped and fast_ms < 1000 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-probe":
			# Live, read-only: log what the connection probe decides. Run it with
			# P4TICKETS pointing at an empty file to see the logged-out path.
			var status: String = await _probe_connection()
			_log("[selftest] probe status=%s" % status)
			get_tree().quit()
			return
		if arg == "--p4-selftest-exec-quoting":
			# Needs a local p4 binary, no server. Pins the shell quoting helpers,
			# then runs `p4 -V` through the spec-on-stdin shell path with a temp
			# file in a directory whose name has a space and an ampersand (and,
			# on Windows, through the absolute "C:/Program Files/..." p4 if present).
			var sh_ok := _sh_quote("it's") == "'it'\\''s'"
			var cmd_ok := _cmd_quote("a b") == "\"a b\"" and _cmd_quote("ab") == "ab" \
					and _cmd_quote("x&y") == "\"x&y\""
			var esc := _os_args(PackedStringArray(["$V `x` \"q\" \\"]))
			var os_ok := esc[0] == ("$V `x` \"q\" \\" if OS.get_name() == "Windows"
					else "\\$V \\`x\\` \\\"q\\\" \\\\")
			# Perforce path escaping: local paths escaped, depot paths and flags
			# untouched, `add` gets raw names plus -f.
			var pe_ok := _escape_path_args(PackedStringArray(["-ztag", "fstat", "C:/p/icon@2x.png"])) \
					== PackedStringArray(["-ztag", "fstat", "C:/p/icon%402x.png"]) \
				and _escape_path_args(PackedStringArray(["edit", "-c", "12", "/home/u/50%.txt"])) \
					== PackedStringArray(["edit", "-c", "12", "/home/u/50%25.txt"]) \
				and _escape_path_args(PackedStringArray(["add", "C:/p/take#1.txt"])) \
					== PackedStringArray(["add", "-f", "C:/p/take#1.txt"]) \
				and _escape_path_args(PackedStringArray(["add", "C:/p/plain.txt"])) \
					== PackedStringArray(["add", "C:/p/plain.txt"]) \
				and _escape_path_args(PackedStringArray(["print", "-q", "//d/x%40y#have"])) \
					== PackedStringArray(["print", "-q", "//d/x%40y#have"]) \
				and _escape_path_args(PackedStringArray(["reconcile", "C:/My Game/..."])) \
					== PackedStringArray(["reconcile", "-f", "C:/My Game/..."]) \
				and _escape_path_args(PackedStringArray(["-ztag", "reconcile", "-n", "C:/p/take#1.txt"])) \
					== PackedStringArray(["-ztag", "reconcile", "-f", "-n", "C:/p/take#1.txt"]) \
				and _p4_escape_path("/a/*%@#") == "/a/%2A%25%40%23"
			_log("[selftest] path-escaping=%s" % pe_ok)
			os_ok = os_ok and pe_ok
			var odd_dir := ProjectSettings.globalize_path("user://p4 selftest & quoting")
			DirAccess.make_dir_recursive_absolute(odd_dir)
			var stdin_file := odd_dir.path_join("in put.txt")
			var fw := FileAccess.open(stdin_file, FileAccess.WRITE)
			fw.store_string("ignored\n")
			fw.close()
			var bins := [_p4_cmd()]
			if OS.get_name() == "Windows" and FileAccess.file_exists("C:/Program Files/Perforce/p4.exe"):
				bins.append("C:/Program Files/Perforce/p4.exe")
			var runs_ok := true
			for b: String in bins:
				var out := []
				var code := _p4_execute_with_stdin(b, PackedStringArray(["-V"]), stdin_file, out)
				var ran := code == 0 and not out.is_empty() and String(out[0]).contains("Perforce")
				_log("[selftest] stdin-exec bin=%s exit=%d ran=%s" % [b, code, ran])
				runs_ok = runs_ok and ran
			DirAccess.remove_absolute(stdin_file)
			DirAccess.remove_absolute(odd_dir)
			_log("[selftest] sh=%s cmd=%s os-args=%s stdin-runs=%s bin=%s" % [sh_ok, cmd_ok, os_ok, runs_ok, _p4_bin])
			if sh_ok and cmd_ok and os_ok and runs_ok and not _p4_bin.is_empty():
				_log("[selftest] PASS: exec-quoting")
			else:
				_log("[selftest] FAIL: exec-quoting")
			get_tree().quit()
			return
		if arg == "--p4-selftest-save-guards":
			# Server-independent, on real files under user:// (never the project):
			# 1. _finish_prewrite_pass leaves an LF-only rewrite in place (no
			#    copy-back that would move the mtime) and makes it read-only.
			# 2. The reimport guard flips read-only .import files writable, then
			#    re-locks an unchanged one (keeping Godot's LF bytes) and reports a
			#    changed one, leaving it writable.
			var dir := "user://p4_selftest_guards"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			var put := func(res: String, text: String) -> void:
				var gp := ProjectSettings.globalize_path(res)
				_set_file_writable(gp, true)
				var fw := FileAccess.open(gp, FileAccess.WRITE)
				fw.store_string(text)
				fw.close()
			var is_rw := func(res: String) -> bool:
				return FileAccess.open(ProjectSettings.globalize_path(res), FileAccess.READ_WRITE) != null
			var body := "[remap]\r\n\r\nimporter=\"texture\"\r\n"
			# 1. Pre-write finish, unchanged content.
			var scene := dir + "/a.tscn"
			put.call(scene, "node A\r\n")
			var scene_g := ProjectSettings.globalize_path(scene)
			var backup := _prewrite_backup_path(scene)
			DirAccess.copy_absolute(scene_g, backup)
			_prewrite_managed[scene] = backup
			put.call(scene, "node A\n") # the editor's LF rewrite
			_finish_prewrite_pass()
			var pw_kept := FileAccess.get_file_as_string(scene_g) == "node A\n"
			var pw_locked: bool = not is_rw.call(scene)
			var pw_backup_gone := not FileAccess.file_exists(backup)
			# 2. Reimport guard.
			var same_res := dir + "/same.png"
			var changed_res := dir + "/changed.png"
			put.call(same_res + ".import", body)
			put.call(changed_res + ".import", body)
			_set_file_writable(ProjectSettings.globalize_path(same_res + ".import"), false)
			_set_file_writable(ProjectSettings.globalize_path(changed_res + ".import"), false)
			var both := PackedStringArray([same_res, changed_res])
			_on_resources_reimporting(both)
			var ri_unlocked: bool = is_rw.call(same_res + ".import") and is_rw.call(changed_res + ".import")
			put.call(same_res + ".import", body.replace("\r\n", "\n"))
			put.call(changed_res + ".import", body.replace("\r\n", "\n") + "uid=\"uid://abc\"\n")
			var changed := _classify_reimported(both)
			var ri_same_locked: bool = not is_rw.call(same_res + ".import")
			var ri_same_lf := FileAccess.get_file_as_string(
					ProjectSettings.globalize_path(same_res + ".import")) == body.replace("\r\n", "\n")
			var ri_changed: bool = changed.size() == 1 \
					and changed[0] == ProjectSettings.globalize_path(changed_res + ".import") \
					and is_rw.call(changed_res + ".import")
			var ri_drained := _reimport_backups.is_empty()
			# 3. Move/delete sidecars.
			var sidecars_ok := _sidecars_of("res://a.png") == ["res://a.png.import", "res://a.png.uid"]
			for f in DirAccess.get_files_at(ProjectSettings.globalize_path(dir)):
				_set_file_writable(ProjectSettings.globalize_path(dir.path_join(f)), true)
				DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
			_log("[selftest] pw-kept=%s pw-locked=%s pw-backup-gone=%s ri-unlocked=%s ri-same-locked=%s ri-same-lf=%s ri-changed=%s ri-drained=%s sidecars=%s"
					% [pw_kept, pw_locked, pw_backup_gone, ri_unlocked, ri_same_locked, ri_same_lf,
					ri_changed, ri_drained, sidecars_ok])
			if pw_kept and pw_locked and pw_backup_gone and ri_unlocked and ri_same_locked \
					and ri_same_lf and ri_changed and ri_drained and sidecars_ok:
				_log("[selftest] PASS: save-guards")
			else:
				_log("[selftest] FAIL: save-guards")
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
			# Server-independent: log the per-row menu item labels.
			_populate_context_menu({"type": "file", "res_path": "res://x.gd", "change": "default"})
			_log("[selftest] file-menu: %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "default", "file_count": 2})
			_log("[selftest] default-cl(2): %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "123", "desc": "wip", "file_count": 3})
			_log("[selftest] numbered-cl(3): %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "124", "desc": "empty", "file_count": 0})
			_log("[selftest] numbered-cl(0): %s" % _selftest_menu_labels())
			get_tree().quit()
			return
		if arg == "--p4-selftest-fs-menu":
			# Server-independent: folder filtering + the FileSystem-dock action set.
			var fs_files := _fs_files_only(PackedStringArray(
					["res://a.gd", "res://sub/", "res://scenes/b.tscn"]))
			_log("[selftest] fs files kept: %s" % [fs_files])
			var labels: Array = []
			for action in _fs_context_actions():
				labels.append(String(action.label))
			_log("[selftest] fs-menu: %s" % " | ".join(labels))
			var ok := fs_files.size() == 2 and ("res://a.gd" in fs_files) \
					and not ("res://sub/" in fs_files) and labels.size() == 6
			_log("[selftest] %s: fs-menu" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-fstat-summary":
			# Server-independent: the human status line from a canned fstat record.
			var rec := {"depotFile": "//depot/a.gd", "haveRev": "3", "headRev": "5",
					"action": "edit", "otherOpen0": "bob@bob_ws"}
			var line := _fstat_summary_line("res://a.gd", rec)
			_log("[selftest] summary: %s" % line)
			var untracked := _fstat_summary_line("res://b.gd", {})
			_log("[selftest] untracked: %s" % untracked)
			var ok := line.contains("//depot/a.gd#3") and line.contains("out of date") \
					and line.contains("opened for edit") and line.contains("bob@bob_ws") \
					and untracked.contains("not in Perforce")
			_log("[selftest] %s: fstat-summary" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-delete-action":
			# Server-independent: the delete-recording decision per fstat state,
			# plus the recursive-scope helper for folder ops.
			var cases := {
				"untracked": [{}, "none"],
				"tracked": [{"depotFile": "//d/a", "headRev": "3"}, "reconcile"],
				"opened-add": [{"depotFile": "//d/a", "action": "add"}, "revert"],
				"opened-edit": [{"depotFile": "//d/a", "action": "edit", "headRev": "3"}, "reconcile"],
				"gone-at-head": [{"depotFile": "//d/a", "headAction": "delete"}, "none"],
			}
			var all_ok := true
			for case_name in cases:
				var got := _delete_action_for(cases[case_name][0])
				var want := String(cases[case_name][1])
				var matched := got == want
				all_ok = all_ok and matched
				_log("[selftest] delete-action %s: got=%s want=%s %s"
						% [case_name, got, want, "OK" if matched else "MISMATCH"])
			var scope_ok := _as_recursive("C:/p/dir") == "C:/p/dir/..." \
					and _as_recursive("C:/p/dir/") == "C:/p/dir/..."
			_log("[selftest] as-recursive: %s" % ("OK" if scope_ok else "BAD"))
			all_ok = all_ok and scope_ok
			_log("[selftest] %s: delete-action" % ("PASS" if all_ok else "FAIL"))
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
		if arg == "--p4-selftest-revert-unchanged-skip":
			# Live, non-destructive: verify open-editor files are split out of the
			# revert set so their unsaved in-memory edits are protected.
			var preview := await _revert_unchanged_preview()
			var open_files := _open_editor_files()
			_log("[selftest] open editor files: %d" % open_files.size())
			var revertable := 0
			var skipped := 0
			for rec in preview:
				var res := _local_to_res(String(rec.get("clientFile", "")))
				if not res.is_empty() and open_files.has(res):
					skipped += 1
					_log("[selftest] skip (open): %s" % res)
				else:
					revertable += 1
			_log("[selftest] revert-unchanged: preview=%d revertable=%d skipped=%d"
					% [preview.size(), revertable, skipped])
			get_tree().quit()
			return
		if arg == "--p4-selftest-diff-align":
			# Server-independent: hunk parsing, side-by-side row alignment
			# (pairing + filler), and the intraline changed-span trim.
			var old_lines := PackedStringArray(["a", "b", "c", "d"])
			var new_lines := PackedStringArray(["a", "B2", "c", "x", "d"])
			var sample := "--- //depot/f\t2026-01-01\n+++ C:\\w\\f\t2026-01-01\n" \
					+ "@@ -1,4 +1,5 @@\n a\n-b\n+B2\n c\n+x\n d\n"
			var rows := _align_diff(old_lines, new_lines, _parse_unified_hunks(sample))
			var kinds: Array = []
			for r: Dictionary in rows:
				kinds.append(r.kind)
			var span := _intraline_span("-0.08553267", "-0.085532665")
			# Collapse: 10 ctx, 1 add, 10 ctx -> gap(7), 3 ctx, add, 3 ctx, gap(7).
			var many: Array = []
			for k in 10:
				many.append({"kind": "ctx", "old_line": k + 1, "new_line": k + 1,
						"left": "l", "right": "l"})
			many.append({"kind": "add", "old_line": 0, "new_line": 11,
					"left": "", "right": "n"})
			for k in 10:
				many.append({"kind": "ctx", "old_line": k + 11, "new_line": k + 12,
						"left": "l", "right": "l"})
			var collapsed := _collapse_context(many)
			var col_kinds: Array = []
			for r in collapsed:
				col_kinds.append(r.kind)
			var ok: bool = kinds == ["ctx", "pair", "ctx", "add", "ctx"] \
					and rows[1].left == "b" and rows[1].right == "B2" \
					and rows[3].old_line == 0 and rows[3].right == "x" \
					and span[0] == Vector2i(10, 11) and span[1] == Vector2i(10, 12) \
					and _diff_depot_path(sample, "?") == "//depot/f" \
					and col_kinds == ["gap", "ctx", "ctx", "ctx", "add",
							"ctx", "ctx", "ctx", "gap"] \
					and int(collapsed[0].count) == 7 and int(collapsed[8].count) == 7
			_log("[selftest] rows: %s  span: %s  collapsed: %s" % [str(kinds), str(span), str(col_kinds)])
			_log("[selftest] %s: diff-align" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-diff="):
			# Live, read-only: run p4 diff -du and report change detection.
			var path := arg.substr("--p4-selftest-diff=".length())
			var result := await _p4_exec(["diff", "-dul", ProjectSettings.globalize_path(path)])
			var text := "" if result.output.is_empty() else String(result.output[0])
			_log("[selftest] diff '%s': has_changes=%s" % [path, _diff_has_changes(text)])
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
		if arg == "--p4-selftest-submit-roundtrip":
			# Live and DESTRUCTIVE (two real submits): adds res://p4godot_submit_test.txt
			# through the default-changelist submit path with a description full of
			# shell metacharacters, checks the depot recorded it byte-for-byte, then
			# submits its deletion. Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			var opened := _parse_ztag(await _p4_exec(["-ztag", "opened"]))
			if not opened.is_empty():
				_log("[selftest] FAIL: submit-roundtrip - %d file(s) already opened; needs a clean workspace" % opened.size())
				get_tree().quit()
				return
			var test_res := "res://p4godot_submit_test.txt"
			var test_g := ProjectSettings.globalize_path(test_res)
			var fw := FileAccess.open(test_g, FileAccess.WRITE)
			fw.store_string("P4Godot submit selftest %d\n" % Time.get_unix_time_from_system())
			fw.close()
			await _p4_exec_logged(["add", test_g])
			var desc := "P4Godot selftest: \"quotes\" $VER `ticks` & ^ %PATH% 'single' trailing\\"
			await _submit_changelist("default", [], desc)
			var ch := _parse_ztag(await _p4_exec(["-ztag", "changes", "-m1", "-s", "submitted", test_g]))
			var num := "" if ch.is_empty() else String(ch[0].get("change", ""))
			var recorded := ""
			if not num.is_empty():
				var d := _parse_ztag(await _p4_exec(["-ztag", "describe", "-s", num]))
				recorded = "" if d.is_empty() else String(d[0].get("desc", "")).strip_edges()
			var desc_ok := recorded == desc
			_log("[selftest] add submitted as %s; desc recorded=[%s] match=%s" % [num, recorded, desc_ok])
			await _p4_exec_logged(["delete", test_g])
			await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_submit_test.txt")
			var st := _parse_ztag(await _p4_exec(["-ztag", "fstat", test_g]))
			var head_action := "" if st.is_empty() else String(st[0].get("headAction", ""))
			var left_open := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] cleanup headAction=%s opened-after=%d" % [head_action, left_open])
			if desc_ok and head_action == "delete" and left_open == 0:
				_log("[selftest] PASS: submit-roundtrip")
			else:
				_log("[selftest] FAIL: submit-roundtrip")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-verdict":
			# Server-independent: the pieces that decide what a user is told
			# after a submit that didn't plainly succeed. Blobs are copied from
			# a 2025.2 server (2026-10-02). The point of all of it: "the command
			# failed" and "nothing was sent" are different claims, and only the
			# server can back the second one.
			#
			# `describe` puts a blank line after the description, so the status
			# sits in what _parse_ztag sees as a second record.
			var pending_blob := "... change 3148\n... user jase\n... client ws\n... time 1790968052\n" \
					+ "... desc a description\n\n... status pending\n... changeType public\n" \
					+ "... depotFile0 //d/proj/a.txt\n... action0 add\n... type0 text\n... rev0 1\n\n"
			var renamed_blob := "... change 3150\n... user jase\n... client ws\n... time 1790968053\n" \
					+ "... desc a description\n\n... status submitted\n... changeType public\n" \
					+ "... path //d/proj/*\n... oldChange 3148\n... depotFile0 //d/proj/a.txt\n\n"
			var p_status := _describe_status({"exit_code": 0, "output": [pending_blob]})
			var r_status := _describe_status({"exit_code": 0, "output": [renamed_blob]})
			# A renumbered changelist answers "no such changelist" under its old
			# number - with exit code 0.
			var gone_status := _describe_status({"exit_code": 0,
					"output": ["3148 - no such changelist.\n"]})
			var dead_status := _describe_status({"exit_code": 1, "output": [
					"Perforce client error:\n\tConnect to server failed; check $P4PORT.\n"]})
			_log("[selftest] describe: pending=%s renamed=%s gone=%s dead=%s"
					% [p_status, r_status, gone_status, dead_status])
			var describe_ok: bool = p_status.status == "pending" and p_status.change == "3148" \
					and r_status.status == "submitted" and r_status.change == "3150" \
					and gone_status.status == "missing" and dead_status.status == "unknown"

			# The submit's own output. Trigger chatter follows the line that
			# matters, and a failed submit also contains the word "Change".
			var ok_out := {"exit_code": 0, "output": ["Submitting change 3148.\nLocking 1 files ...\n" \
					+ "add //d/proj/a.txt#1\nChange 3148 submitted.\n/usr/bin/python3.9\n"]}
			var renamed_out := {"exit_code": 0, "output": ["Submitting change 3148.\n" \
					+ "Change 3148 renamed change 3150 and submitted.\nCalled subprocess with PID: 4\n"]}
			var refused_out := {"exit_code": 1, "output": ["Submitting change 3148.\n" \
					+ "//d/proj/a.txt - must sync/resolve #5 before submitting\n" \
					+ "Out of date files must be resolved or reverted.\n" \
					+ "Submit failed -- fix problems above then use 'p4 submit -c 3148'.\n"]}
			var dropped_out := {"exit_code": 1, "output": ["Submitting change 3148.\n" \
					+ "Perforce client error:\n\tTCP receive exceeded maximum configured duration of 600 seconds.\n"]}
			var silent_out := {"exit_code": 1, "output": [""]}
			var parse_ok: bool = _submitted_change_in(ok_out) == "3148" \
					and _submitted_change_in(renamed_out) == "3150" \
					and _submitted_change_in(refused_out) == "" \
					and _submitted_change_in(dropped_out) == ""
			# Only a refusal the server itself wrote counts as an answer. Text
			# nobody anticipated, an SSL failure, and a refusal line followed by
			# a network error all have to be treated as "may have been lost".
			var odd_out := {"exit_code": 1, "output": ["Perforce client error:\n\tsomething new\n"]}
			var ssl_out := {"exit_code": 1, "output": ["SSL receive failed.\n"]}
			var both_out := {"exit_code": 1, "output": ["Submit failed -- fix problems above.\n" \
					+ "TCP send failed.\n"]}
			var lost_ok: bool = not _submit_connection_lost(refused_out) \
					and _submit_connection_lost(dropped_out) \
					and _submit_connection_lost(silent_out) \
					and _submit_connection_lost(odd_out) \
					and _submit_connection_lost(ssl_out) \
					and _submit_connection_lost(both_out)
			# `change -i` can create the changelist and still exit non-zero.
			var created_ok: bool = _created_change_in({"exit_code": 1, "output": [
					"Change 3151 created with 1 open file(s).\nsome trigger said no\n"]}) == "3151" \
					and _created_change_in({"exit_code": 1, "output": [
					"Error in change specification.\nChange 12 unknown.\n"]}) == ""
			lost_ok = lost_ok and created_ok
			_log("[selftest] submitted-as: ok=%s renamed=%s refused='%s' dropped='%s'; lost: refused=%s dropped=%s silent=%s"
					% [_submitted_change_in(ok_out), _submitted_change_in(renamed_out),
					_submitted_change_in(refused_out), _submitted_change_in(dropped_out),
					_submit_connection_lost(refused_out), _submit_connection_lost(dropped_out),
					_submit_connection_lost(silent_out)])

			# `monitor show`: a working answer always lists our own `monitor`
			# command, so "no records" must read as can't-tell, never as "no
			# submit running" - that reading turns an unknown into "not sent".
			var mon_idle := {"exit_code": 0, "output": [
					"... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_busy := {"exit_code": 0, "output": [
					"... id 41470\n... status R\n... user jase\n... time 00:01:10\n... command submit\n\n" \
					+ "... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_other := {"exit_code": 0, "output": [
					"... id 41470\n... status R\n... user bob\n... time 00:01:10\n... command submit\n\n" \
					+ "... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_off := {"exit_code": 1, "output": ["Monitor not currently enabled.\n"]}
			var mon_empty := {"exit_code": 0, "output": [""]}
			var monitor_ok: bool = _monitor_submit_running(mon_idle, "jase") == 0 \
					and _monitor_submit_running(mon_busy, "jase") == 1 \
					and _monitor_submit_running(mon_other, "jase") == 0 \
					and _monitor_submit_running({"exit_code": 0, "output": [
					"... id 7\n... status R\n... user jase\n... time 00:00:09\n... command dm-CommitSubmit\n\n"]},
					"jase") == 1 \
					and _monitor_submit_running(mon_off, "jase") == -1 \
					and _monitor_submit_running(mon_empty, "jase") == -1
			_log("[selftest] monitor: idle=%d busy=%d other-user=%d off=%d empty=%d"
					% [_monitor_submit_running(mon_idle, "jase"), _monitor_submit_running(mon_busy, "jase"),
					_monitor_submit_running(mon_other, "jase"), _monitor_submit_running(mon_off, "jase"),
					_monitor_submit_running(mon_empty, "jase")])

			# A submit stopped while a file was part-way up cannot be finished by
			# the server, whatever its process list goes on showing. That is what
			# lets a cancel be reported at once, with no special access. Stopped
			# BETWEEN files it proves nothing: the server may hold everything.
			var cut := P4Progress.new()
			cut.feed("progress (total): C:\\ws\\a.bin (type 1 units 3) - 0 of 100")
			cut.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 100 of 100")
			var between_files := cut.in_flight()
			cut.feed("progress (total): C:\\ws\\b.bin (type 1 units 3) - 0 of 100")
			cut.feed("progress (update): C:\\ws\\b.bin (type 1 units 3) - 40 of 100")
			var mid_file := cut.in_flight()
			_log("[selftest] in flight: between files=%d, mid-file=%d, nothing reported=%d"
					% [between_files, mid_file, P4Progress.new().in_flight()])
			# After a cut upload only a COMMIT counts as the server still working;
			# its leftover `submit` entry does not.
			var committing := {"exit_code": 0, "output": [
					"... id 7\n... status R\n... user jase\n... time 00:00:09\n... command dm-CommitSubmit\n\n"]}
			monitor_ok = monitor_ok and between_files == 0 and mid_file == 1 \
					and P4Progress.new().in_flight() == 0 \
					and _monitor_submit_running(mon_busy, "jase", true) == 0 \
					and _monitor_submit_running(committing, "jase", true) == 1

			# What the user reads. Only a checked "not submitted" may say
			# nothing was sent; "unknown" must not, and must say not to resubmit.
			var t_sub := _submit_outcome_text("submitted", "3148", "3150", "TCP receive failed", true)
			var t_not := _submit_outcome_text("not_submitted", "3148", "", "must sync/resolve", false)
			var t_not_lost := _submit_outcome_text("not_submitted", "3148", "", "TCP receive failed", true)
			var t_unk := _submit_outcome_text("unknown", "3148", "", "TCP receive failed", true)
			_log("[selftest] unknown text: %s" % t_unk.replace("\n", " | "))
			var text_ok: bool = t_sub.contains("submitted as change 3150") \
					and t_not.contains("Nothing was sent") and t_not.contains("changelist 3148") \
					and t_not.contains("must sync/resolve") \
					and t_not_lost.contains("nothing was sent") and t_not_lost.contains("dropped") \
					and not t_unk.to_lower().contains("nothing was sent") \
					and t_unk.contains("can't tell") and t_unk.contains("Don't submit again") \
					and t_unk.contains("empty panel") and not t_unk.contains("never arrived") \
					and t_unk.contains("3148")

			if describe_ok and parse_ok and lost_ok and monitor_ok and text_ok:
				_log("[selftest] PASS: submit-verdict")
			elif not describe_ok:
				_log("[selftest] FAIL: submit-verdict - misread a changelist's status")
			elif not parse_ok:
				_log("[selftest] FAIL: submit-verdict - misread the submit's own output")
			elif not lost_ok:
				_log("[selftest] FAIL: submit-verdict - a refusal and a dropped connection were confused")
			elif not monitor_ok:
				_log("[selftest] FAIL: submit-verdict - misread what the server is running")
			else:
				_log("[selftest] FAIL: submit-verdict - the outcome text claims more than was checked")
			get_tree().quit()
			return
		if arg == "--p4-selftest-progress":
			# Server-independent: the progress tracker against lines copied from a
			# 2025.2 client and server (2026-10-02), and the cleanup after a
			# cancelled sync against real files in a scratch folder.
			#
			# (a) A parallel submit: kilobyte units, two files interleaved, one of
			# them reporting "done" with no "update" before it.
			var t := P4Progress.new()
			t.total_files = 2
			t.total_bytes = 3000000
			t.sizes = {"c:/ws/a.bin": 1500000, "c:/ws/b.bin": 1500000}
			var answer_line := not t.feed("Change 3171 submitted.")
			t.feed("progress (total): C:\\ws\\a.bin (type 1 units 3) - 0 of 1464")
			t.feed("progress (total): C:\\ws\\b.bin (type 1 units 3) - 0 of 1464")
			t.feed("progress (update): C:\\ws\\b.bin (type 1 units 3) - 732 of 1464")
			var half_b := t.bytes_done()
			var mid_text := _progress_detail_text(t, 83.0)
			t.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 1464 of 1464")
			var after_a := t.files_done
			# A repeated "done" must not count twice.
			t.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 1464 of 1464")
			_log("[selftest] kb: half-b=%d bytes, files after a=%d (repeat: %d), fraction=%.3f, text=%s"
					% [half_b, after_a, t.files_done, t.fraction(), mid_text])
			var kb_ok: bool = answer_line and half_b == 750000 and after_a == 1 \
					and t.files_done == 1 and absf(t.fraction() - 0.75) < 0.001 \
					and t.is_done("C:/ws/a.bin") and not t.is_done("C:\\ws\\b.bin") \
					and mid_text == "0 of 2 files  -  732 KB of 2.9 MB  -  1:23"

			# (b) Delta Transfer on submit: units 5 ("deltas"), "17 of 22". The
			# position is a fraction of the file, the size is what we knew.
			var d := P4Progress.new()
			d.total_files = 1
			d.total_bytes = 24000000
			d.sizes = {"c:/ws/big.bin": 24000000}
			d.feed("progress (total): C:\\ws\\big.bin (type 1 units 5) - 0 of 22")
			d.feed("progress (update): C:\\ws\\big.bin (type 1 units 5) - 11 of 22")
			var delta_half := d.bytes_done()
			d.feed("--- rpc msgs/size in+out 2+2/0mb+0mb himarks 318788/64836 snd/rcv .000s/.011s")
			d.feed("--- rpc msgs/size in+out 28+9/6mb+0mb himarks 318788/64836 snd/rcv .000s/.899s")
			d.feed("---   locks read/write 0/1 rows get+pos+scan put+del 0+0+0 1+0")
			d.feed("progress (done): C:\\ws\\big.bin (type 1 units 5) - 22 of 22")
			var delta_summary := _transfer_summary(d)
			_log("[selftest] delta: half=%d, delta files=%d, network=%d MB, summary=%s"
					% [delta_half, d.delta_files, d.network_mb, delta_summary])
			var delta_ok: bool = delta_half == 12000000 and d.delta_files == 1 \
					and d.network_mb == 6 and d.files_done == 1 \
					and delta_summary.contains("About 6 MB crossed the network") \
					and delta_summary.contains("Delta Transfer")

			# (c) A Delta Transfer SYNC reports nothing for the file. Without
			# finish() the bar would stop short of the end for good.
			var s := P4Progress.new()
			s.total_files = 2
			s.total_bytes = 25000000
			s.feed("progress (total): C:\\ws\\small.gd (type 2 units 3) - 0 of 976")
			s.feed("progress (done): C:\\ws\\small.gd (type 2 units 3) - 976 of 976")
			var before_finish := s.fraction()
			var idle_text := _progress_detail_text(P4Progress.new(), 7.0)
			s.finish()
			# A parallel transfer's tracking line reads 0 MB: say nothing about
			# the network instead of "0 MB crossed".
			s.feed("--- rpc msgs/size in+out 3+811/0mb+0mb himarks 318788/64836 snd/rcv .022s/7.68s")
			var quiet_summary := _transfer_summary(s)
			# Paths with spaces and brackets, and a line that isn't a transfer
			# (type 4, a computation), must not confuse the count.
			var odd := P4Progress.new()
			odd.feed("progress (total): C:\\my ws\\art (final)\\a b.png (type 2 units 3) - 0 of 10")
			odd.feed("progress (done): C:\\my ws\\art (final)\\a b.png (type 2 units 3) - 10 of 10")
			odd.feed("progress (update): digest (type 4 units 6) - 3 of 9")
			_log("[selftest] silent sync: %.3f before finish, %.3f after, %d files; idle text=%s; summary=%s; odd path done=%s files=%d"
					% [before_finish, s.fraction(), s.files_done, idle_text, quiet_summary,
					odd.is_done("C:/my ws/art (final)/a b.png"), odd.expected_files()])
			var finish_ok: bool = before_finish < 0.1 and s.fraction() == 1.0 and s.files_done == 2 \
					and idle_text == "Working...  -  0:07" \
					and not quiet_summary.contains("crossed the network") \
					and odd.is_done("C:/my ws/art (final)/a b.png") and odd.expected_files() == 1

			# (d) Small pure pieces.
			var misc_ok: bool = _duration_text(3725.0) == "1:02:05" and _duration_text(7.9) == "0:07" \
					and absf(_p4_version_in("Rev. P4/NTX64/2025.2/2907753 (2026/03/09).") - 2025.2) < 0.001 \
					and _p4_version_in("Rev. P4/LINUX26X86_64/2020.2/2075706 (2021/01/12).") < P4_PROGRESS_MIN_VERSION \
					and _p4_version_in("nonsense") == 0.0 \
					and _submit_outcome_text("not_submitted", "12", "", "", true, true).contains("Submit cancelled") \
					and _submit_outcome_text("submitted", "12", "14", "", true, true).contains("Too late to cancel") \
					and _submit_outcome_text("submitted", "12", "14", "", true, true).contains("change 14")

			# (e) Cleanup after a cancelled sync. Four files the preview said
			# would be added: one p4 reported done (keep), one that was already
			# on disk before the sync (keep - it is the user's), one left empty
			# by the kill (remove), one that never appeared (nothing to do). Plus
			# a p4 temp file (remove) and a stranger's .tmp (keep).
			var scratch := _p4godot_cache_dir().path_join("selftest_cancel_%d" % Time.get_ticks_usec())
			DirAccess.make_dir_recursive_absolute(scratch)
			var paths := {}
			# And "recorded.bin": p4 never reported it done (an old p4 reports
			# nothing), but the server says it was delivered - it must stay.
			for n in ["done.bin", "mine.txt", "partial.bin", "never.bin", "t123t456t7.tmp", "notes.tmp", "kept.gd", "recorded.bin"]:
				paths[n] = scratch.path_join(n)
			for n in ["done.bin", "mine.txt", "partial.bin", "t123t456t7.tmp", "notes.tmp", "kept.gd", "recorded.bin"]:
				var wf := FileAccess.open(paths[n], FileAccess.WRITE)
				wf.store_string("" if n == "partial.bin" else "content")
				wf.close()
			_set_file_writable(paths["done.bin"], false)
			var ct := P4Progress.new()
			ct.feed("progress (total): %s (type 2 units 3) - 0 of 1" % paths["done.bin"])
			ct.feed("progress (done): %s (type 2 units 3) - 1 of 1" % paths["done.bin"])
			var fake_found := {"locals": [paths["done.bin"], paths["mine.txt"], paths["partial.bin"],
					paths["never.bin"], paths["kept.gd"]],
					"added_locals": [paths["done.bin"], paths["mine.txt"], paths["partial.bin"],
					paths["never.bin"], paths["recorded.bin"]]}
			# First with no server to ask (this test has none): nothing at all
			# may be deleted on the tracker's word alone.
			var blind_count: int = await _cleanup_cancelled_sync(fake_found,
					{_path_key(paths["mine.txt"]): true}, ct,
					int(Time.get_unix_time_from_system()) + 3600)
			var blind_kept: bool = blind_count == 0 and FileAccess.file_exists(paths["partial.bin"])
			# Then with the server's answer supplied.
			var removed_count: int = await _cleanup_cancelled_sync(fake_found,
					{_path_key(paths["mine.txt"]): true}, ct,
					int(Time.get_unix_time_from_system()) - 5,
					{_path_key(paths["recorded.bin"]): true})
			var left := {}
			for n in paths:
				left[n] = FileAccess.file_exists(paths[n])
			_log("[selftest] cleanup with no answer removed %d; with one removed %d; left on disk: %s"
					% [blind_count, removed_count, left])
			var cleanup_ok: bool = blind_kept and removed_count == 1 and left["done.bin"] \
					and left["mine.txt"] and left["recorded.bin"] \
					and not left["partial.bin"] and not left["t123t456t7.tmp"] \
					and left["notes.tmp"] and left["kept.gd"]
			for n in paths:
				_set_file_writable(paths[n], true)
				DirAccess.remove_absolute(paths[n])
			DirAccess.remove_absolute(scratch)

			if kb_ok and delta_ok and finish_ok and misc_ok and cleanup_ok:
				_log("[selftest] PASS: progress")
			elif not kb_ok:
				_log("[selftest] FAIL: progress - wrong totals from kilobyte progress lines")
			elif not delta_ok:
				_log("[selftest] FAIL: progress - Delta Transfer lines or the network total misread")
			elif not finish_ok:
				_log("[selftest] FAIL: progress - a file p4 never reported left the bar short, or an odd line broke the count")
			elif not misc_ok:
				_log("[selftest] FAIL: progress - duration, version or cancel text")
			else:
				_log("[selftest] FAIL: progress - cleanup after a cancelled sync removed the wrong files")
			get_tree().quit()
			return
		if arg == "--p4-selftest-streamed-exec":
			# Needs a local p4 binary, no server. Runs p4 through the piped,
			# streamed path: output must come back in the same shape OS.execute
			# gives, and a command stuck connecting to an address that never
			# answers must be stopped by Cancel in about a second, not after the
			# operating system's connect timeout.
			var st := P4Progress.new()
			var ver: Dictionary = await _p4_exec_streamed(["-V"], st)
			var ver_text := "" if ver.output.is_empty() else String(ver.output[0])
			_log("[selftest] streamed -V: exit=%d cancelled=%s, %d chars, version parsed=%.1f"
					% [ver.exit_code, ver.cancelled, ver_text.length(), _p4_version_in(ver_text)])
			var ver_ok: bool = int(ver.exit_code) == 0 and not ver.cancelled \
					and ver_text.contains("Perforce") and _p4_version_in(ver_text) > 2000.0
			get_tree().create_timer(0.6).timeout.connect(_cancel_streamed)
			var began := Time.get_ticks_msec()
			var stuck: Dictionary = await _p4_exec_streamed(["-p", "10.255.255.1:1666", "info"], st)
			var took := Time.get_ticks_msec() - began
			_log("[selftest] cancelled a stuck connect after %d ms: exit=%d cancelled=%s breaker tripped=%s"
					% [took, stuck.exit_code, stuck.cancelled, _server_unreachable()])
			var cancel_ok: bool = bool(stuck.cancelled) and took < 5000 and int(stuck.exit_code) != 0 \
					and _streamed_req == null
			if ver_ok and cancel_ok:
				_log("[selftest] PASS: streamed-exec")
			elif not ver_ok:
				_log("[selftest] FAIL: streamed-exec - a streamed command's output didn't come back intact")
			else:
				_log("[selftest] FAIL: streamed-exec - Cancel didn't stop a running p4")
			get_tree().quit()
			return
		if arg == "--p4-selftest-connection-dialogs":
			# Server-independent: run the connection dialogs' code. Nothing here
			# can see how a dialog looks; it proves the dialogs open, answer and
			# close without a script error, that the third button is told apart
			# from OK and Cancel, and the one rule with consequences: pressing
			# Connect without editing must not turn inherited Perforce settings
			# into stored per-project ones.
			_selftest_auto_answer = "confirm"
			var conn: Dictionary = await _show_connection_dialog("ssl:example:1666", "ana")
			var opt_ok: Dictionary = await _show_option_dialog("t", "m",
					PackedStringArray(["one", "two"]), 1, "OK", CHANGE_SERVER_TEXT)
			var before := [_override_port, _override_user, _override_client]
			var untouched: Dictionary = await _edit_connection()
			var after_edit := [_override_port, _override_user, _override_client]
			_selftest_auto_answer = "extra"
			var opt_extra: Dictionary = await _show_option_dialog("t", "m",
					PackedStringArray(["one", "two"]), 0, "OK", CHANGE_SERVER_TEXT)
			var in_extra: Dictionary = await _show_input_dialog("t", "m", "", false, "OK",
					false, CHANGE_SERVER_TEXT)
			# No third button on this one, so "extra" has nothing to press: cancel.
			var in_plain: Dictionary = await _show_input_dialog("t", "m", "", false, "OK")
			_selftest_auto_answer = "cancel"
			var conn_cancel: Dictionary = await _show_connection_dialog("ssl:example:1666", "ana")
			var cancelled_edit: Dictionary = await _edit_connection()
			var picked_nothing: bool = not await _pick_client()
			_log("[selftest] connection=%s option-ok=%s option-extra=%s input-extra=%s edit-unchanged=%s"
					% [conn, opt_ok, opt_extra, in_extra, untouched])
			var dialogs_ok: bool = conn.ok and conn.port == "ssl:example:1666" and conn.user == "ana" \
					and opt_ok.ok and opt_ok.index == 1 and not opt_ok.extra \
					and opt_extra.extra and not opt_extra.ok \
					and in_extra.extra and not in_extra.ok \
					and not in_plain.extra and not in_plain.ok \
					and not conn_cancel.ok
			var edit_ok: bool = untouched.ok and not untouched.changed and before == after_edit \
					and not cancelled_edit.ok and not cancelled_edit.changed and picked_nothing
			if dialogs_ok and edit_ok:
				_log("[selftest] PASS: connection-dialogs")
			elif not dialogs_ok:
				_log("[selftest] FAIL: connection-dialogs - a dialog reported the wrong button")
			else:
				_log("[selftest] FAIL: connection-dialogs - an unedited Connect changed the stored settings")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-cancel":
			# Live and DESTRUCTIVE: uploads part (or all) of a 24 MB file.
			# Cancels a submit the moment p4 reports the transfer under way, then
			# checks that what the user is told matches the server. Either answer
			# is legitimate - cancelled in time, or too late - but it must be the
			# TRUE one, and the workspace must be left usable. Needs a clean
			# workspace.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-cancel - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var c_res := "res://p4godot_cancel_test.bin"
			var c_g := ProjectSettings.globalize_path(c_res)
			var cf := FileAccess.open(c_g, FileAccess.WRITE)
			var block := PackedByteArray()
			block.resize(1048576)
			for mb in 24:
				for i in range(0, block.size(), 8):
					block.encode_s64(i, randi() << 32 | randi())
				cf.store_buffer(block)
			cf.close()
			await _p4_exec_logged(["add", "-t", "binary", c_g])
			_selftest_cancel_on_progress = true
			var c_began := Time.get_ticks_msec()
			await _submit_changelist("default", [], "P4Godot selftest: cancelled submit (add)")
			var c_took := Time.get_ticks_msec() - c_began
			var c_outcome := _last_submit_outcome
			var c_head := _parse_ztag(await _p4_exec(["-ztag", "files", c_g]))
			var in_depot: bool = not c_head.is_empty() \
					and String(c_head[0].get("action", "")) != "delete"
			var c_opened := _parse_ztag(await _p4_exec(["-ztag", "opened", c_g]))
			var still_change := "" if c_opened.is_empty() else String(c_opened[0].get("change", ""))
			_log("[selftest] cancelled after %d ms: outcome=%s; in depot=%s; still opened in change '%s'"
					% [c_took, c_outcome, in_depot, still_change])
			# The claim has to match the server, whichever way it went.
			var truthful: bool = (c_outcome == "submitted" and in_depot and c_opened.is_empty()) \
					or (c_outcome == "not_submitted" and not in_depot and not still_change.is_empty())
			# Clean up, through the same code a user would use next.
			var c_clean := false
			if c_outcome == "not_submitted":
				# The promise was "submit it again from the panel": do exactly that.
				await _submit_changelist(still_change, [])
				c_clean = _last_submit_outcome == "submitted"
			if _last_submit_outcome == "submitted":
				await _p4_exec_logged(["delete", c_g])
				await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_cancel_test.bin")
				c_clean = c_clean or c_outcome == "submitted"
			var c_left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] resubmit-after-cancel ok=%s, opened-after=%d" % [c_clean, c_left])
			if truthful and c_clean and c_left == 0:
				_log("[selftest] PASS: submit-cancel (%s)" % c_outcome)
			elif not truthful:
				_log("[selftest] FAIL: submit-cancel - the outcome reported doesn't match the server")
			else:
				_log("[selftest] FAIL: submit-cancel - the workspace wasn't usable after the cancel")
			get_tree().quit()
			return
		if arg == "--p4-selftest-get-latest-cancel":
			# Live. Stage it outside Godot first: make the project several files
			# and at least ~20 MB behind (`p4 sync <path>#none` on some of it), so
			# the download lasts long enough to be stopped part-way.
			# Cancels Get Latest the moment the transfer is under way, then checks
			# the two things a killed sync gets wrong on its own: it leaves
			# half-written files that every later sync refuses to overwrite, and
			# it says nothing useful. A second Get Latest must then finish the job.
			_selftest_auto_answer = "confirm"
			var gl_before := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])))
			_selftest_cancel_on_progress = true
			var gl_report := await _get_latest_flow()
			await _selftest_drain_frames()
			_log("[selftest] report: %s" % gl_report.replace("\n", " | "))
			var gl_mid: Dictionary = await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])
			var gl_mid_sum := _summarize_sync(_parse_ztag(gl_mid))
			var gl_mid_notes := _sync_notes(gl_mid)
			_log("[selftest] staged %d behind; after cancel %d still behind, %d refused as existing, %d as modified"
					% [gl_before.names.size(), gl_mid_sum.names.size(), gl_mid_notes.existing.size(),
					gl_mid_notes.modified.size()])
			var gl_second := await _get_latest_flow()
			await _selftest_drain_frames()
			var gl_after := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])))
			_log("[selftest] second run: %s | still behind afterwards: %d"
					% [gl_second.replace("\n", " | ").left(160), gl_after.names.size()])
			var was_cancelled: bool = gl_report.contains("was cancelled")
			var no_wreckage: bool = gl_mid_notes.existing.is_empty() and gl_mid_notes.modified.is_empty()
			var recovered: bool = gl_after.names.is_empty() and not gl_second.contains("would not overwrite") \
					and not gl_second.contains("were not downloaded")
			if gl_before.names.size() < 2:
				_log("[selftest] FAIL: get-latest-cancel - stage the project behind head first (see the source comment)")
			elif not was_cancelled:
				_log("[selftest] FAIL: get-latest-cancel - the sync finished before Cancel landed; stage a bigger download")
			elif not gl_mid_sum.names.size() > 0:
				_log("[selftest] FAIL: get-latest-cancel - nothing was left to download, so Cancel stopped nothing")
			elif not no_wreckage:
				_log("[selftest] FAIL: get-latest-cancel - half-written files were left behind")
			elif not recovered:
				_log("[selftest] FAIL: get-latest-cancel - a second Get Latest didn't finish the job")
			else:
				_log("[selftest] PASS: get-latest-cancel")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-verdict-live":
			# Live and DESTRUCTIVE (two real submits). Asks a real server what
			# became of a changelist in the two cases a dropped connection leaves
			# behind: submitted under a NEW number, and still pending.
			# Staging a renumber: a changelist is renumbered on submit when a
			# higher-numbered one exists, so an empty one is created after it.
			# Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-verdict-live - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var v_res := "res://p4godot_verdict_test.txt"
			var v_g := ProjectSettings.globalize_path(v_res)
			var vf := FileAccess.open(v_g, FileAccess.WRITE)
			vf.store_string("P4Godot verdict selftest %d\n" % Time.get_unix_time_from_system())
			vf.close()
			await _p4_exec_logged(["add", v_g])
			var v_opened := _parse_ztag(await _p4_exec(["-ztag", "opened", v_g]))
			var v_depot := "" if v_opened.is_empty() else String(v_opened[0].get("depotFile", ""))
			var first := _parse_change_number(await _p4_exec_spec(["change", "-i"],
					"Change: new\n\nDescription:\n\tP4Godot selftest: verdict (add)\n\nFiles:\n\t%s\n" % v_depot))
			var blocker := await _create_changelist("P4Godot selftest: forces a renumber - safe to delete")
			_log("[selftest] staged: file in change %s, empty change %s after it" % [first, blocker])

			# Still pending, and no submit of ours running: whether or not the
			# connection was lost, that is "not submitted".
			var v_pending: Dictionary = await _submit_verdict(first, true)
			var v_pending_answered: Dictionary = await _submit_verdict(first, false)
			_log("[selftest] verdict while pending: lost=%s answered=%s" % [v_pending, v_pending_answered])

			await _submit_changelist(first, [])
			# Asked about under its OLD number, as after a lost connection.
			var v_done: Dictionary = await _submit_verdict(first, true)
			var by_file := _parse_ztag(await _p4_exec(["-ztag", "changes", "-m1", "-s", "submitted", v_g]))
			var landed := "" if by_file.is_empty() else String(by_file[0].get("change", ""))
			_log("[selftest] verdict after submit: %s; the file's newest change is %s" % [v_done, landed])

			await _p4_exec_logged(["change", "-d", blocker])
			await _p4_exec_logged(["delete", v_g])
			await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_verdict_test.txt")
			var v_left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			var v_ok: bool = not first.is_empty() and not blocker.is_empty() \
					and v_pending.outcome == "not_submitted" \
					and v_pending_answered.outcome == "not_submitted" \
					and v_done.outcome == "submitted" and v_done.change == landed \
					and landed != first and not landed.is_empty() and v_left == 0
			_log("[selftest] renumbered %s -> %s, opened-after=%d" % [first, landed, v_left])
			_log("[selftest] %s: submit-verdict-live" % ("PASS" if v_ok else "FAIL"))
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
		if arg.begins_with("--p4-selftest-import-dock="):
			# Live: the Import dock hook. Part 1 presses the real Reimport button
			# with unchanged settings (armed, then re-locked, not opened). Part 2
			# changes a parameter while armed, as the dock's own save does, and
			# reimports (checked out). Leaves the .import opened - revert after.
			var path := arg.substr("--p4-selftest-import-dock=".length())
			var gp_imp := ProjectSettings.globalize_path(path + ".import")
			var is_rw := func() -> bool: return FileAccess.open(gp_imp, FileAccess.READ_WRITE) != null
			EditorInterface.select_file(path)
			await _selftest_drain_frames()
			var hooked := is_instance_valid(_import_reimport_button)
			var armed := false
			var relocked := false
			if hooked:
				_import_reimport_button.button_down.emit()
				armed = is_rw.call() and _reimport_backups.has(gp_imp)
				_import_reimport_button.pressed.emit()
				await _selftest_drain_frames()
				# Headless, the dock may not have picked up the selection, so the
				# press reimports nothing - exactly a user's cancel. Then the 30 s
				# fallback timer must re-lock it.
				var until := Time.get_ticks_msec() + 40000
				while (is_rw.call() or _reimport_backups.has(gp_imp)) and Time.get_ticks_msec() < until:
					await get_tree().create_timer(0.5).timeout
				relocked = not is_rw.call() and not _reimport_backups.has(gp_imp)
			var untouched: bool = await _needs_checkout(gp_imp)
			# Part 2: a real settings change.
			if hooked:
				_import_reimport_button.button_down.emit()
			else:
				_arm_reimport_guard(gp_imp)
			var cf := ConfigFile.new()
			cf.load(gp_imp)
			cf.set_value("params", "mipmaps/generate", not bool(cf.get_value("params", "mipmaps/generate", false)))
			cf.save(gp_imp)
			EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray([path]))
			await _selftest_drain_frames()
			var checked_out := not await _needs_checkout(gp_imp)
			_log("[selftest] hooked=%s armed=%s relocked=%s untouched=%s changed-checked-out=%s"
					% [hooked, armed, relocked, untouched, checked_out])
			_log("[selftest] %s: import-dock" % ("PASS" if hooked and armed and relocked
					and untouched and checked_out else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-script-revert="):
			# Live: reverting a script has to put the DEPOT text back in front
			# of the user. Godot holds the edited source in the cached Script
			# resource as well as in the open tab, so a reload that only
			# closes the tab hands the edit straight back the moment the file
			# is reopened.
			#
			# This has to run against a real `p4 revert`, not a simulated one.
			# Restoring the file with FileAccess moves its modification time
			# FORWARD, and Godot then reloads the script by itself, which
			# hides the bug. Perforce restores the depot file's own modtime,
			# which is older than the edit - Godot sees nothing to reload, and
			# the stale cached resource is what the user gets.
			# Self-cleaning: the revert is the cleanup.
			var path := arg.substr("--p4-selftest-script-revert=".length())
			var global := ProjectSettings.globalize_path(path)
			var marker := "# p4godot selftest edit"
			_selftest_auto_answer = "confirm"
			await _do_checkout(path)
			var original := FileAccess.get_file_as_string(global)
			var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
			EditorInterface.edit_script(scr)
			await _settle_frames(2)
			# Edit it the way the editor does: the tab's text and the cached
			# resource both carry the change, and a save puts it on disk.
			var edited := original + "\n" + marker + "\n"
			scr.source_code = edited
			var typed := _current_script_code_edit()
			if typed:
				typed.text = edited
			var f := FileAccess.open(global, FileAccess.WRITE)
			f.store_string(edited)
			f.close()
			await _selftest_drain_frames()
			var dirty_before: bool = (ResourceLoader.load(path) as Script).source_code.contains(marker)

			# What _revert_path does, with a sample taken in between: whether
			# the cached resource is still dirty once Perforce has put the
			# depot file back is the whole question the fix turns on.
			await _p4_exec_logged(["revert", global])
			_checked_out_this_session.erase(path)
			var cached_dirty_at_reload: bool = (ResourceLoader.load(path) as Script).source_code.contains(marker)
			_log("[selftest] cached still dirty when the reload starts: %s" % cached_dirty_at_reload)
			await _reload_path(path)

			var disk_clean: bool = not FileAccess.get_file_as_string(global).contains(marker)
			var cached_clean: bool = not (ResourceLoader.load(path) as Script).source_code.contains(marker)
			var still_open := false
			for s in EditorInterface.get_script_editor().get_open_scripts():
				if (s as Script).resource_path == path:
					still_open = true
			var shown := _current_script_code_edit()
			var tab_clean: bool = shown != null and not shown.text.contains(marker)
			_log("[selftest] dirty before revert=%s; disk clean=%s; cached clean=%s; tab still open=%s; tab clean=%s"
					% [dirty_before, disk_clean, cached_clean, still_open, tab_clean])

			# Second case, and the one only the CACHE_MODE_IGNORE load can
			# cover: the script has no tab open when the revert happens. There
			# is nothing to close and reopen, so if the cached resource isn't
			# re-read, the edit is still sitting there waiting to be served
			# the next time the user opens the file.
			await _do_checkout(path)
			var f2 := FileAccess.open(global, FileAccess.WRITE)
			f2.store_string(edited)
			f2.close()
			(ResourceLoader.load(path) as Script).source_code = edited
			EditorInterface.get_script_editor().close_file(path)
			await _settle_frames(2)
			var closed: bool = not _is_open_in_editor(path)
			await _p4_exec_logged(["revert", global])
			_checked_out_this_session.erase(path)
			await _reload_path(path)
			var closed_cached_clean: bool = not (ResourceLoader.load(path) as Script).source_code.contains(marker)
			_log("[selftest] with no tab open: closed=%s cached clean after reload=%s"
					% [closed, closed_cached_clean])

			var ok: bool = dirty_before and disk_clean and cached_clean and still_open \
					and tab_clean and closed and closed_cached_clean
			_log("[selftest] %s: script-revert" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-decline-reprompt="):
			# Live: declining a checkout must not turn checkout off for the
			# rest of the session. The decline reloads the file from disk, so
			# the NEXT edit is a genuinely new one and has to prompt again.
			# Leaves the scene opened - revert afterwards.
			var path := arg.substr("--p4-selftest-decline-reprompt=".length())
			var global := ProjectSettings.globalize_path(path)
			auto_checkout_checkbox.set_pressed_no_signal(true)
			_selftest_auto_answer = "cancel"
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			var opened_after_decline := not await _needs_checkout(global)
			var suppressed := _declined_this_session.has(path)
			# A second edit, accepted this time. Reaching the prompt at all is
			# what's under test; the checkout is how we observe it.
			#
			# It has to land in the SAME tab, with no reopen: opening the
			# scene again would hand the editor a fresh undo history, which
			# hides a stale recorded version (the reload resets the version to
			# 1, so a version left on record from before the reload is a
			# number later edits can never reach).
			_selftest_auto_answer = "confirm"
			var root := EditorInterface.get_edited_scene_root()
			var root_path := "<none>" if root == null else root.get_scene_file_path()
			if root != null:
				var ur2 := get_undo_redo()
				ur2.create_action("[P4 selftest] second edit, same tab")
				ur2.add_do_method(root, "set_meta", "_p4_selftest_2", true)
				ur2.add_undo_method(root, "remove_meta", "_p4_selftest_2")
				ur2.commit_action()
			await _selftest_drain_frames()
			var opened_after_second := not await _needs_checkout(global)
			_log("[selftest] after decline: opened=%s suppressed=%s; second edit in tab '%s': opened=%s"
					% [opened_after_decline, suppressed, root_path, opened_after_second])
			var ok: bool = not opened_after_decline and not suppressed and opened_after_second
			_log("[selftest] %s: decline-reprompt" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-opened-cache="):
			# Live: the session's "already checked out" cache is rebuilt from
			# `p4 opened` on every refresh, so a submit or revert made outside
			# Godot can't leave a file marked checked out here for the rest of
			# the session (which would make later edits to it silently skip
			# the checkout). Leaves the file opened - revert afterwards.
			var path := arg.substr("--p4-selftest-opened-cache=".length())
			_selftest_auto_answer = "confirm"
			await _do_checkout(path)
			await _selftest_drain_frames()
			# A file someone else reverted or submitted, still on record here.
			_checked_out_this_session["res://a_file_reverted_elsewhere.tscn"] = true
			_refresh_changelists()
			await _selftest_drain_frames()
			var stale_dropped: bool = not _checked_out_this_session.has("res://a_file_reverted_elsewhere.tscn")
			var real_kept: bool = _checked_out_this_session.has(path)
			_log("[selftest] stale entry dropped=%s; really-open entry kept=%s (cache holds %d)"
					% [stale_dropped, real_kept, _checked_out_this_session.size()])
			_log("[selftest] %s: opened-cache" % ("PASS" if stale_dropped and real_kept else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-connection-store":
			# Server-independent: the connection overrides round-trip through
			# the per-user store, a second project doesn't clobber the first,
			# and anything left in the old in-project location is moved out
			# and blanked - that location is a file inside .godot/, which a
			# team can submit by accident.
			var settings := EditorInterface.get_editor_settings()
			var store := _connection_store_path()
			var saved_port := _override_port
			var saved_user := _override_user
			var saved_client := _override_client

			_override_port = "ssl:example:1666"
			_override_user = "alice"
			_override_client = "alice_ws"
			_save_connection_overrides()
			_override_port = ""
			_override_user = ""
			_override_client = ""
			_load_connection_overrides()
			var round_trip: bool = _override_port == "ssl:example:1666" \
					and _override_user == "alice" and _override_client == "alice_ws"

			# A second project must not overwrite the first project's section.
			var other := ConfigFile.new()
			other.load(store)
			other.set_value("some_other_project_hash", "user", "bob")
			other.save(store)
			_load_connection_overrides()
			var kept_separate: bool = _override_user == "alice"

			# Migration: clear the new store for this project, put values in
			# the old place, and load.
			var cfg := ConfigFile.new()
			cfg.load(store)
			cfg.erase_section(_project_store_section())
			cfg.save(store)
			settings.set_project_metadata(SETTINGS_SECTION, "override_user", "legacy_user")
			_override_user = ""
			_load_connection_overrides()
			var migrated: bool = _override_user == "legacy_user"
			var old_cleared: bool = String(settings.get_project_metadata(
					SETTINGS_SECTION, "override_user", "")).is_empty()
			var in_new_store := ConfigFile.new()
			in_new_store.load(store)
			var landed: bool = String(in_new_store.get_value(
					_project_store_section(), "user", "")) == "legacy_user"

			# Put the real settings back, and take the test data out.
			_override_port = saved_port
			_override_user = saved_user
			_override_client = saved_client
			_save_connection_overrides()
			var cleanup := ConfigFile.new()
			cleanup.load(store)
			cleanup.erase_section("some_other_project_hash")
			cleanup.save(store)

			_log("[selftest] store=%s" % store)
			_log("[selftest] round-trip=%s kept-separate=%s migrated=%s old-cleared=%s landed-in-new=%s"
					% [round_trip, kept_separate, migrated, old_cleared, landed])
			var ok: bool = round_trip and kept_separate and migrated and old_cleared and landed
			_log("[selftest] %s: connection-store" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-plugin-prompt":
			# Live: run the startup check for real. Meant for a project whose
			# project.godot is in Perforce while the addon folder is not -
			# it reports what the check decided either way, and asserts it
			# only opens the plugin when the plugin was actually missing.
			var plugin_cfg := ProjectSettings.globalize_path(
					_plugin_dir().path_join("plugin.cfg"))
			var before := await _is_in_depot(plugin_cfg)
			_selftest_mode = false # the whole point is to let the check run
			EditorInterface.get_editor_settings().set_project_metadata(
					SETTINGS_SECTION, "plugin_add_declined", false)
			_selftest_auto_answer = "confirm"
			await _check_plugin_tracked()
			await _selftest_drain_frames()
			var after := await _is_in_depot(plugin_cfg)
			_log("[selftest] plugin in depot before=%s after=%s" % [before, after])
			_log("[selftest] %s: plugin-prompt" % ("PASS" if after else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-plugin-tracked":
			# Live and read-only: the three questions the startup check asks -
			# where the plugin lives, whether a path is in the depot, and
			# whether P4IGNORE covers it. A path p4 has never heard of must
			# read as "not in the depot", which only works because a bare
			# "no such file(s)" message yields no tagged record.
			var plugin_res := _plugin_dir()
			var plugin_dir := ProjectSettings.globalize_path(plugin_res)
			var project_file := ProjectSettings.globalize_path("res://project.godot")
			var absent := ProjectSettings.globalize_path("res://p4godot_no_such_file.txt")
			var project_tracked := await _is_in_depot(project_file)
			var absent_tracked := await _is_in_depot(absent)
			var plugin_tracked := await _is_in_depot(plugin_dir.path_join("plugin.cfg"))
			var godot_dir_ignored := await _p4_path_ignored(
					ProjectSettings.globalize_path("res://.godot/x"))
			var project_ignored := await _p4_path_ignored(project_file)
			_log("[selftest] plugin dir=%s" % plugin_res)
			_log("[selftest] in-depot: project.godot=%s plugin.cfg=%s absent-file=%s"
					% [project_tracked, plugin_tracked, absent_tracked])
			_log("[selftest] ignored: .godot/x=%s project.godot=%s"
					% [godot_dir_ignored, project_ignored])
			var ok: bool = plugin_res.ends_with("/p4godot") and project_tracked \
					and not absent_tracked and godot_dir_ignored and not project_ignored
			_log("[selftest] %s: plugin-tracked" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-reconcile-report":
			# Live and read-only: exactly what the Reconcile dialog would say
			# about this workspace right now - the files, the per-action
			# counts, and anything Perforce says it won't open. Opens nothing,
			# so it is safe to run against a workspace in any state.
			var result: Dictionary = await _p4_exec(["-ztag", "reconcile", "-n", _project_scope()])
			var records := _parse_ztag(result)
			var found := _summarize_reconcile(records)
			var refused := _refusals(result)
			_log("[selftest] reconcile would open %d file(s): add=%d edit=%d delete=%d"
					% [found.names.size(), found.adds, found.edits, found.deletes])
			for n in found.names:
				_log("[selftest]   %s" % n)
			_log("[selftest] refused=%d locked=%s" % [refused.count, refused.locked])
			for refusal_line in refused.lines:
				_log("[selftest]   ! %s" % refusal_line)
			# The invariant the dock depends on: every record it counts is a
			# real file with an action. A p4 message parsed as a record breaks
			# this, and used to show up as a file to edit that could never be
			# opened.
			var well_formed := true
			for rec in records:
				if String(rec.get("clientFile", "")).is_empty() \
						or String(rec.get("action", "")).is_empty():
					well_formed = false
					_log("[selftest] malformed record: %s" % [rec])
			_log("[selftest] %s: reconcile-report" % ("PASS" if well_formed else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-get-latest="):
			# Live: the real Get Latest flow against a workspace that is
			# genuinely behind. STAGE IT OUTSIDE GODOT first - a revision
			# specifier can't travel through _p4_exec, which escapes the `#` in
			# a path argument (for files really named that):
			#
			#   p4 sync <file>#1                       ordinary case
			#   p4 sync <file>#1; chmod +w; append     the case sync -n cannot
			#                                          predict - changed on
			#                                          disk, not checked out
			#   p4 sync <file>#1; p4 edit <file>       checked out and behind:
			#                                          p4 leaves the file alone
			#                                          and wants a resolve
			#
			# Then restore with `p4 revert <file>` (third case) and
			# `p4 sync -f <file>`. The test accepts any of the three and asserts
			# the outcome that staging demands, so one test covers all of them;
			# it fails if nothing was staged at all, because "already up to
			# date" would otherwise pass for free. Note the third staging
			# produces NO preview record - only a message - which is why the
			# staging check has to consult the notes as well as the records.
			# Pass a `.gd` as well as a `.tscn` across runs: scripts take the
			# _reload_script path, which is the one with the CACHE_MODE_IGNORE
			# subtlety, and a scene that only ever loads as a scene never
			# exercises it.
			var path := arg.substr("--p4-selftest-get-latest=".length())
			_selftest_auto_answer = "confirm"
			var ext := path.get_extension().to_lower()
			if ext == "tscn" or ext == "scn":
				EditorInterface.open_scene_from_path(path)
				await _selftest_drain_frames()
			elif ext == "gd" or ext == "cs":
				var scr := load(path) as Script
				if scr:
					EditorInterface.edit_script(scr)
					await _selftest_drain_frames()
			var was_open: bool = _open_editor_files().has(path)
			var before: Dictionary = await _p4_exec(["-ztag", "sync", "-n", _project_scope()])
			var staged := _summarize_sync(_parse_ztag(before))
			var staged_notes := _sync_notes(before)
			var checked_out_behind: bool = int(staged_notes.opened_behind) > 0
			_log("[selftest] staged: %d record(s) behind head %s, %d checked-out-and-behind (open in editor=%s)"
					% [staged.names.size(), staged.names, staged_notes.opened_behind, was_open])
			var report := await _get_latest_flow()
			await _selftest_drain_frames()
			_log("[selftest] report: %s" % report.replace("\n", " | "))
			var still_behind := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", _project_scope()])))
			_log("[selftest] after the flow, %d file(s) still behind: %s"
					% [still_behind.names.size(), still_behind.names])
			var was_staged: bool = staged.names.has(path) or checked_out_behind
			var came_up_to_date: bool = not still_behind.names.has(path)
			var refusal_reported: bool = report.contains("would not overwrite") \
					and report.contains(path)
			var resolve_reported: bool = report.contains("two versions combined") \
					and report.contains(path)
			var outcome := ""
			var outcome_ok := false
			if checked_out_behind:
				# p4 never overwrites a file you have checked out. It moves the
				# have revision and wants a resolve, and the report must say so
				# - left unsaid, the file silently can't be submitted.
				outcome_ok = resolve_reported
				outcome = "resolve reported"
			elif not came_up_to_date:
				# A file p4 refused to overwrite MUST still be behind - that is
				# the protection working - and the report must name it.
				outcome_ok = refusal_reported
				outcome = "refusal reported"
			else:
				outcome_ok = true
				outcome = "downloaded and reloaded"
			var reload_ok: bool = not (was_open and came_up_to_date and not checked_out_behind) \
					or report.contains("reloaded")
			if not was_staged:
				_log("[selftest] FAIL: get-latest - '%s' was not behind head; stage it first (see the source comment)" % path)
			elif not outcome_ok:
				_log("[selftest] FAIL: get-latest - expected '%s' and the report doesn't say it" % outcome)
			elif not reload_ok:
				_log("[selftest] FAIL: get-latest - the open tab was not reloaded onto the downloaded version")
			else:
				_log("[selftest] PASS: get-latest (%s)" % outcome)
			get_tree().quit()
			return
		if arg == "--p4-selftest-external-scan":
			# Live: a file another program dropped into the workspace must be
			# found by the focus-in scan and offered for checkout, and a set
			# the user declined must not ask again. Self-cleaning: it adds its
			# own scratch file, then reverts and deletes it.
			var rel := "res://p4godot_external_%d.txt" % Time.get_unix_time_from_system()
			var global := ProjectSettings.globalize_path(rel)
			var f := FileAccess.open(rel, FileAccess.WRITE)
			f.store_string("written by a program that knows nothing about Perforce\n")
			f.close()
			detect_external_checkbox.set_pressed_no_signal(true)
			auto_open_checkbox.set_pressed_no_signal(false)

			# The focus notification is what drives the scan in normal use, and
			# a headless session never gets a real one. Propagating it by hand
			# at least proves it reaches this plugin node and starts a scan
			# (the scan stamps _external_scan_last_msec when it finishes).
			_selftest_auto_answer = "cancel"
			_external_scan_last_msec = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC
			var stamp_before := _external_scan_last_msec
			get_tree().root.propagate_notification(NOTIFICATION_APPLICATION_FOCUS_IN)
			await _selftest_drain_frames()
			var focus_scanned := _external_scan_last_msec != stamp_before
			_log("[selftest] focus notification started a scan: %s" % focus_scanned)
			_external_scan_dismissed = ""

			# The scan reconciles everything it finds, and this workspace can
			# hold unrelated changes - narrow it to our own file.
			var preview := await _reconcile_preview()
			var found := false
			for rec in preview:
				if _local_to_res(String(rec.get("clientFile", ""))) == rel:
					found = true
			_log("[selftest] reconcile preview saw the new file: %s" % found)

			var one_file := {"locals": [global], "names": [rel],
					"adds": 1, "edits": 0, "deletes": 0}
			var no_refusals := {"count": 0, "lines": [], "locked": false}

			# Decline once: the file stays unopened and the set is remembered,
			# so the same set can't ask again on every alt-tab.
			_selftest_auto_answer = "cancel"
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var opened_after_decline := not _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()
			var remembered := not _external_scan_dismissed.is_empty()

			# Asked again with the identical set: the dialog must not reappear,
			# so even a "confirm" answer leaves the file unopened.
			_selftest_auto_answer = "confirm"
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var still_unopened := _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()

			# A fresh set does ask, and accepting opens the file for add.
			_external_scan_dismissed = ""
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var opened := not _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()

			await _p4_exec_logged(["revert", global])
			DirAccess.remove_absolute(global)
			_log("[selftest] preview-found=%s opened-after-decline=%s remembered=%s still-unopened-on-repeat=%s opened-after-accept=%s"
					% [found, opened_after_decline, remembered, still_unopened, opened])
			var ok: bool = found and focus_scanned and not opened_after_decline \
					and remembered and still_unopened and opened
			_log("[selftest] %s: external-scan" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-history-gate="):
			# Live: a history_changed with no edit (clear_history, as a tab switch
			# does) must NOT check the scene out; a real commit_action must.
			# Leaves the scene opened - revert afterwards.
			var path := arg.substr("--p4-selftest-history-gate=".length())
			var global := ProjectSettings.globalize_path(path)
			_selftest_auto_answer = "confirm"
			auto_checkout_checkbox.set_pressed_no_signal(true)
			await _selftest_make_current(path)
			await _selftest_drain_frames()
			var ur := get_undo_redo()
			ur.clear_history(ur.get_object_history_id(EditorInterface.get_edited_scene_root()), false)
			await _selftest_drain_frames()
			var opened_after_clear := not await _needs_checkout(global)
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			var opened_after_edit := not await _needs_checkout(global)
			_log("[selftest] opened after clear_history=%s, after real edit=%s" % [opened_after_clear, opened_after_edit])
			_log("[selftest] %s: history-gate" % ("PASS" if not opened_after_clear and opened_after_edit else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-fs-checkout="):
			# Live: the FileSystem-dock "P4: Check Out" path (an imported asset's
			# .import comes along). Leaves the files opened - revert afterwards.
			var path := arg.substr("--p4-selftest-fs-checkout=".length())
			await _checkout_path(path)
			var both := true
			for p: String in [path, path + ".import"]:
				var opened := not await _needs_checkout(ProjectSettings.globalize_path(p))
				_log("[selftest] %s opened=%s" % [p, opened])
				both = both and opened
			_log("[selftest] %s: fs-checkout" % ("PASS" if both else "FAIL"))
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
			await _reload_path(path)
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
			EditorInterface.save_scene()
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
			var save_err := EditorInterface.save_scene()
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
			EditorInterface.save_scene()
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
			EditorInterface.save_all_scenes()
			await _selftest_drain_frames()
			await _selftest_drain_frames()
			for p in paths:
				await _selftest_report_opened(p)
			get_tree().quit()
			return


func _selftest_menu_labels() -> String:
	var labels: Array = []
	for i in range(context_menu.item_count):
		labels.append(context_menu.get_item_text(i))
	return " | ".join(labels)


func _selftest_simulate_edit(path: String) -> void:
	_log("[selftest] Opening '%s' and simulating a real commit_action()..." % path)
	EditorInterface.open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	# Main::start auto-opens the project's MAIN scene at a nondeterministic
	# point during boot (see _selftest_make_current) - it can steal the
	# current tab between our open and our commit, making the edit land on
	# the wrong scene. Refocus until the requested scene is actually current.
	var scene_root := EditorInterface.get_edited_scene_root()
	for attempt in range(10):
		if scene_root != null and scene_root.get_scene_file_path() == path:
			break
		EditorInterface.open_scene_from_path(path)
		await get_tree().process_frame
		await get_tree().process_frame
		scene_root = EditorInterface.get_edited_scene_root()
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
	EditorInterface.open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	var root := EditorInterface.get_edited_scene_root()
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
