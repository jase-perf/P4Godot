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
## - Delete / move / rename: deleting or moving a file (or folder) in the
##   FileSystem dock is caught via FileSystemDock signals and offered to
##   Perforce - open-for-delete for a deletion, a history-preserving move
##   (`p4 reconcile -m`) for a rename. Prompts by default, or applies silently
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
##   (use Reconcile for those). New empty files aren't auto-added either - Godot
##   emits no create signal - but a new file gets added when you save it or via
##   Reconcile.
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

# How long a hovered file's cached p4 status stays fresh before the next hover
# triggers a background refresh (see _prefetch_fstat).
const FSTAT_CACHE_TTL_SEC := 5.0


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
var diff_view: RichTextLabel
var new_changelist_button: Button
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
	_register_filesystem_hooks()
	# Fire-and-forget coroutine: anything that needs the identity awaits
	# _ensure_identity() instead of assuming this has resolved.
	_detect_p4_identity()
	_log("P4 plugin loaded.")
	_run_cli_self_test_if_requested()


func _exit_tree() -> void:
	_shutting_down = true
	_unregister_filesystem_hooks()
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
		dock.queue_free() # Cascades to log_window/diff_window and their descendants.
		dock = null
		log_window = null
		log_box = null
		diff_window = null
		diff_view = null


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
	var result: Dictionary = await _p4_exec(["-ztag", "info"])
	var text := "" if result.output.is_empty() else String(result.output[0])
	if result.exit_code != 0:
		if _looks_like_login_error(result):
			return "not logged in"
		if text.contains("Connect to server failed") or text.contains("check $P4PORT") \
				or text.to_lower().contains("tcp connect"):
			return "no server"
		return "p4 missing" if text.strip_edges().is_empty() else "no server"
	var records := _parse_ztag(result)
	var info: Dictionary = {} if records.is_empty() else records[0]
	_p4_user = String(info.get("userName", ""))
	_p4_port = String(info.get("serverAddress", ""))
	var client := String(info.get("clientName", ""))
	var root := String(info.get("clientRoot", ""))
	if client == "*unknown*" or client.is_empty() or not _project_inside_root(root):
		return "no client"
	_p4_client = client
	return "ok"


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
			await _show_alert("The p4 command-line client isn't installed (or isn't on PATH).\n\n" +
					"Install the Helix Command-Line Client (P4) from perforce.com/downloads,\n" +
					"then press Refresh in the P4 dock.")
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
		_log("Perforce is still not configured - press Refresh in the P4 dock to run setup again.")


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


## Suggest one of the user's existing workspaces for this project; the picked
## name becomes the per-project client override. Returns false on cancel.
func _pick_client() -> bool:
	var result: Dictionary = await _p4_exec(["-ztag", "clients", "--me"])
	if result.exit_code != 0:
		# --me needs 2020.1+; fall back to filtering by user name.
		var user := _override_user if not _override_user.is_empty() else _p4_user
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
	if ordered.is_empty():
		var res: Dictionary = await _show_input_dialog("P4 Connection Setup",
				("No workspaces found for your user on %s.\n" % _p4_port) +
				"Create one in P4V (or with `p4 client`) whose root contains this project,\n" +
				"then press Refresh in the P4 dock. Or enter a workspace name to use directly:",
				"", false, "Use Workspace")
		if not res.ok or String(res.text).strip_edges().is_empty():
			return false
		_override_client = String(res.text).strip_edges()
		return true
	var options := PackedStringArray()
	for c in ordered:
		options.append("%s   (%s)" % [String(c.get("client", "")), String(c.get("Root", ""))])
	var head := "Found a workspace whose root contains this project.\n" if not matches.is_empty() \
			else "None of your workspaces' roots contain this project - pick one anyway,\nor cancel and create a workspace for it first.\n"
	var picked: Dictionary = await _show_option_dialog("P4 Connection Setup",
			head + "Workspace to use for this project (stored per-project, per-user):",
			options, 0, "Use This Workspace")
	if not picked.ok:
		return false
	_override_client = String(ordered[picked.index].get("client", ""))
	return true


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
		await _show_alert("Login failed:\n\n%s" % msg)
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
func _with_connection_flags(args: PackedStringArray) -> PackedStringArray:
	var flags := PackedStringArray()
	if not _override_port.is_empty():
		flags.append_array(["-p", _override_port])
	if not _override_user.is_empty():
		flags.append_array(["-u", _override_user])
	if not _override_client.is_empty():
		flags.append_array(["-c", _override_client])
	if flags.is_empty():
		return args
	var combined := flags.duplicate()
	combined.append_array(args)
	return combined


## Persist the connection overrides next to the other per-project settings.
func _save_connection_overrides() -> void:
	var settings := get_editor_interface().get_editor_settings()
	settings.set_project_metadata(SETTINGS_SECTION, "override_port", _override_port)
	settings.set_project_metadata(SETTINGS_SECTION, "override_user", _override_user)
	settings.set_project_metadata(SETTINGS_SECTION, "override_client", _override_client)


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
	verbose_log_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "verbose_log", false)
	auto_open_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "auto_open_no_prompt", false)
	_verbose_log = verbose_log_checkbox.button_pressed
	_override_port = settings.get_project_metadata(SETTINGS_SECTION, "override_port", "")
	_override_user = settings.get_project_metadata(SETTINGS_SECTION, "override_user", "")
	_override_client = settings.get_project_metadata(SETTINGS_SECTION, "override_client", "")


func _on_setting_toggled(_pressed: bool) -> void:
	var settings := get_editor_interface().get_editor_settings()
	settings.set_project_metadata(SETTINGS_SECTION, "auto_checkout_on_edit",
			auto_checkout_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "checkout_on_save",
			checkout_on_save_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "verbose_log",
			verbose_log_checkbox.button_pressed)
	settings.set_project_metadata(SETTINGS_SECTION, "auto_open_no_prompt",
			auto_open_checkbox.button_pressed)
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


## The gear menu fronting the four setting checkboxes. Checkable popup items
## sync from the checkboxes on open and toggle them on click, so the existing
## persistence (_on_setting_toggled) and every reader stay untouched.
func _build_settings_menu(parent: Control) -> void:
	settings_menu = MenuButton.new()
	settings_menu.flat = true
	settings_menu.tooltip_text = "P4 plugin settings (stored per-project, per-user)."
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
	popup.add_check_item("Verbose log", 3)
	popup.set_item_tooltip(0, "Offer to check out a file the moment it is first modified in the editor.")
	popup.set_item_tooltip(1, "Automatically check out edited files right before the editor writes them.")
	popup.set_item_tooltip(2, "Open edits, deletes, and moves in Perforce silently, with no confirmation dialogs.")
	popup.set_item_tooltip(3, "Log read-only status probes too, not just state-changing commands.")
	popup.about_to_popup.connect(_sync_settings_menu)
	popup.id_pressed.connect(_on_settings_menu_id_pressed)
	parent.add_child(settings_menu)


func _settings_menu_checkbox(id: int) -> CheckBox:
	match id:
		0: return auto_checkout_checkbox
		1: return checkout_on_save_checkbox
		2: return auto_open_checkbox
		3: return verbose_log_checkbox
	return null


func _sync_settings_menu() -> void:
	var popup := settings_menu.get_popup()
	for id in 4:
		var cb := _settings_menu_checkbox(id)
		popup.set_item_checked(popup.get_item_index(id), cb != null and cb.button_pressed)


func _on_settings_menu_id_pressed(id: int) -> void:
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
	_offer_connection_setup()


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
# Diff viewer
# ---------------------------------------------------------------------------

## The diff window (a hidden Window child of the dock) hosting a RichTextLabel
## that renders colored unified-diff text. Repopulated and popped per diff.
func _build_diff_window() -> void:
	diff_window = Window.new()
	diff_window.title = "P4 Diff"
	diff_window.size = Vector2i(820, 560)
	diff_window.visible = false
	diff_window.close_requested.connect(_on_diff_window_close_requested)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	diff_window.add_child(root)

	diff_view = RichTextLabel.new()
	diff_view.bbcode_enabled = true
	diff_view.scroll_active = true
	diff_view.selection_enabled = true # let the user copy the diff
	diff_view.focus_mode = Control.FOCUS_ALL
	diff_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Monospace so diff columns line up; fall back to default if unavailable.
	var mono := get_editor_interface().get_base_control().get_theme_font("source", "EditorFonts")
	if mono:
		diff_view.add_theme_font_override("normal_font", mono)
		diff_view.add_theme_font_override("bold_font", mono)
		diff_view.add_theme_font_override("mono_font", mono)
	root.add_child(diff_view)

	dock.add_child(diff_window)


func _on_diff_window_close_requested() -> void:
	diff_window.hide()


## Diff res_path (workspace vs the depot revision you have) and show it in the
## diff window. `p4 diff -dul` is read-only; the `l` flag ignores line-ending
## differences - Godot always writes LF, so on a Windows client (LineEnd:
## local, CRLF) every line would otherwise count as changed and the diff
## degenerates into remove-all/add-all.
func _diff_path(res_path: String) -> void:
	if not await _ensure_identity():
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
		return
	var result := await _p4_exec(["diff", "-dul", ProjectSettings.globalize_path(res_path)])
	var text := "" if result.output.is_empty() else String(result.output[0])
	if not _diff_has_changes(text):
		await _show_alert("No differences: '%s' matches the depot revision you have." % res_path)
		return
	diff_window.title = "P4 Diff: %s" % res_path
	diff_view.text = _diff_to_bbcode(text)
	diff_window.popup_centered()


## Whether `p4 diff -du` output shows an actual change. A unified diff always has
## an "@@" hunk header when content differs; an unchanged-but-opened file emits
## only the ---/+++ header. "files differ" is p4's binary-difference message.
func _diff_has_changes(text: String) -> bool:
	if text.contains("files differ"):
		return true
	for line in text.split("\n"):
		if line.begins_with("@@"):
			return true
	return false


## Turn unified-diff text into BBCode with per-line coloring (add=green,
## remove=red, hunk=cyan, file header=dim). BBCode's '[' is escaped to '[lb]' so
## code brackets in the diff aren't parsed as tags.
func _diff_to_bbcode(diff_text: String) -> String:
	var out := ""
	for raw_line in diff_text.split("\n"):
		var line := String(raw_line).rstrip("\r") # p4.exe emits CRLF
		var esc := line.replace("[", "[lb]")
		var color := ""
		if line.begins_with("+++") or line.begins_with("---") \
				or line.begins_with("====") or line.begins_with("diff "):
			color = "9c9ca8" # neutral - file headers
		elif line.begins_with("@@"):
			color = P4_ACCENT.to_html(false) # cyan hunk header
		elif line.begins_with("+"):
			color = ACTION_ADD_COLOR.to_html(false) # green
		elif line.begins_with("-"):
			color = ACTION_DELETE_COLOR.to_html(false) # red
		if color.is_empty():
			out += esc + "\n"
		else:
			out += "[color=#%s]%s[/color]\n" % [color, esc]
	return out


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
	var base := get_editor_interface().get_base_control()
	if base and base.has_theme_icon(icon_name, "EditorIcons"):
		return base.get_theme_icon(icon_name, "EditorIcons")
	return null


func _editor_bold_font() -> Font:
	var base := get_editor_interface().get_base_control()
	if base and base.has_theme_font("bold", "EditorFonts"):
		return base.get_theme_font("bold", "EditorFonts")
	return null


func _dim_color() -> Color:
	var base := get_editor_interface().get_base_control()
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
		get_editor_interface().open_scene_from_path(res_path)
	else:
		var res := ResourceLoader.load(res_path)
		if res:
			get_editor_interface().edit_resource(res)


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


## Check out one file: skip if it doesn't need it, otherwise `p4 edit` and surface
## any failure. Shared by the toolbar "Checkout Active File" button and the
## FileSystem-dock context menu.
func _checkout_path(res_path: String) -> void:
	if not await _needs_checkout(ProjectSettings.globalize_path(res_path)):
		_checked_out_this_session[res_path] = true
		_log("'%s' doesn't need checkout (already opened by you, or not tracked by Perforce)." % res_path)
		return
	var result: Dictionary = await _do_checkout(res_path)
	if not result.ok:
		_show_alert("Couldn't check out '%s' - %s." % [res_path, result.reason])


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
			("Revert '%s'?\n\nThis reverts the Perforce checkout AND discards any unsaved " +
			"changes to this file in the editor, reloading it from disk.") % res_path,
			"Revert", "Cancel")
	if not proceed:
		_log("Revert of '%s' cancelled." % res_path)
		return
	await _p4_exec_logged(["revert", ProjectSettings.globalize_path(res_path)])
	_checked_out_this_session.erase(res_path)
	_reload_path(res_path)


## Sync res_path to the head revision and reload it from disk. Shared by the
## toolbar "Sync Selected File" button and the tree's per-row context menu.
func _sync_path(res_path: String) -> void:
	await _p4_exec_logged(["sync", ProjectSettings.globalize_path(res_path)])
	_reload_path(res_path)


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
	_reload_path(res_path)


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
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
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
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
		return
	var preview := await _revert_unchanged_preview()
	if preview.is_empty():
		await _show_alert("No open-but-unchanged files to revert.")
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
		await _show_alert(("All %d open-but-unchanged file(s) are open in the editor and were " +
				"skipped to protect unsaved changes:\n\n%s\n\nClose a file (or revert it from " +
				"the tree) if you really mean to revert it.")
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
	for scene_path in get_editor_interface().get_open_scenes():
		open[String(scene_path)] = true
	for scr in get_editor_interface().get_script_editor().get_open_scripts():
		if scr and not scr.resource_path.is_empty():
			open[scr.resource_path] = true
	var edited := get_editor_interface().get_inspector().get_edited_object()
	if edited is Resource and not edited.resource_path.is_empty():
		open[edited.resource_path] = true
	return open


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
		await _show_alert("Could not delete changelist #%s:\n\n%s" % [change, msg])
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
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
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

## Async `p4 <args>` via the worker thread. Returns {exit_code, output}. Commands
## are logged to the log window per the Verbose setting (see _should_log_cmd).
func _p4_exec(args: PackedStringArray) -> Dictionary:
	if _p4_thread == null:
		return _p4_exec_sync(args) # Worker gone (shutdown); it logs on its own.
	var loud := _should_log_cmd(args) # decided BEFORE the -p/-u/-c flags join in
	args = _with_connection_flags(args)
	if loud:
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
	_finish_p4_log(args, result, loud)
	_maybe_offer_login(result)
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
	var loud := _should_log_cmd(args) # change -i is always loud (never a probe)
	args = _with_connection_flags(args)
	var display_args := args + PackedStringArray(["< (spec on stdin)"])
	if loud:
		_log_p4_cmd(display_args)
	if _p4_thread == null:
		var out := []
		var code := _p4_execute_with_stdin(args, tmp, out)
		DirAccess.remove_absolute(tmp)
		var sync_result := {"exit_code": code, "output": out}
		_finish_p4_log(display_args, sync_result, loud)
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
	_finish_p4_log(display_args, result, loud)
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
	var loud := _should_log_cmd(args)
	args = _with_connection_flags(args)
	if loud:
		_log_p4_cmd(args)
	var output := []
	var exit_code := OS.execute("p4", args, output, true)
	var result := {"exit_code": exit_code, "output": output}
	_finish_p4_log(args, result, loud)
	_maybe_offer_login(result)
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
## lock as the other dialogs. `multiline` picks a TextEdit vs a LineEdit;
## `secret` masks a single-line field (passwords).
func _show_input_dialog(title: String, message: String, default_text: String,
		multiline: bool, ok_text: String, secret: bool = false) -> Dictionary:
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


## Shows a modal dialog with a message and a dropdown of options; returns
## {ok: bool, index: int}. Used by connection setup to pick a workspace.
func _show_option_dialog(title: String, message: String, options: PackedStringArray,
		preselect: int, ok_text: String) -> Dictionary:
	if _shutting_down:
		return {"ok": false, "index": -1}
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
	var index: int = picker.selected if (confirmed and is_instance_valid(picker)) else -1
	_discard_dialog(dialog)
	_dialog_busy = false
	return {"ok": confirmed and index >= 0, "index": index}


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
# FileSystem dock integration (native tooltips + right-click menu)
#
# Two Godot editor hooks, both reachable from GDScript (no GDExtension needed):
# EditorContextMenuPlugin adds Perforce actions to the FileSystem dock's
# right-click menu, and EditorResourceTooltipPlugin adds P4 status to a file's
# hover tooltip. Both delegate to the methods here, so they reuse the same
# worker-thread p4 plumbing as the rest of the plugin and never block the editor.
# ---------------------------------------------------------------------------

func _register_filesystem_hooks() -> void:
	var fsd := get_editor_interface().get_file_system_dock()
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
	var fsd := get_editor_interface().get_file_system_dock()
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
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
		return
	await _p4_exec_logged(["add", ProjectSettings.globalize_path(res_path)])
	_request_refresh()


## Log a concise Perforce status line for each selected file - a quick read-only
## "where does P4 think this is" without leaving the editor. Also warms the hover
## tooltip cache for these files.
func _status_to_log(files: Array) -> void:
	if not await _ensure_identity():
		await _show_alert("Perforce is unavailable - press Refresh in the P4 dock to run connection setup (details in the P4 Log).")
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
# move/rename is recorded with `p4 reconcile -m` (Perforce move detection), which
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
				("You deleted the folder '%s' (%d Perforce-tracked file(s)).\n\nOpen those " +
				"files for delete in Perforce so the deletion lands in your changelist?")
				% [res_path, count], "Open for Delete", "Leave in Perforce"):
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
			("You deleted '%s'.\n\nOpen it for delete in Perforce so the deletion lands in " +
			"your changelist?") % res_path, "Open for Delete", "Leave in Perforce"):
		_log("Left '%s' tracked in Perforce - run Reconcile to record the deletion." % res_path)
		return
	await _p4_open_for_delete(res_path, decision)
	_forget_path(res_path)
	_request_refresh()


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


## Record a move via `p4 reconcile -m`, scoped to just the two paths (or the two
## subtrees for a folder). Move detection pairs the now-missing source with the
## new file by content: matched -> a history-preserving move/delete + move/add;
## unmatched (Godot rewrote it) -> a plain delete + add.
func _p4_record_move(old_res: String, new_res: String, is_folder: bool) -> Dictionary:
	var old_g := ProjectSettings.globalize_path(old_res)
	var new_g := ProjectSettings.globalize_path(new_res)
	if is_folder:
		old_g = _as_recursive(old_g)
		new_g = _as_recursive(new_g)
	return await _p4_exec_logged(["reconcile", "-m", old_g, new_g])


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
		if arg == "--p4-selftest-diff-bbcode":
			# Server-independent: per-line coloring + BBCode escaping.
			var sample := "--- //depot/a\n+++ /local/a\n@@ -1,2 +1,2 @@\n context\n-old[x]\n+new\n"
			var bb := _diff_to_bbcode(sample)
			var ok := bb.contains("[color=#%s]" % ACTION_ADD_COLOR.to_html(false)) \
					and bb.contains("[color=#%s]" % ACTION_DELETE_COLOR.to_html(false)) \
					and bb.contains("[color=#%s]" % P4_ACCENT.to_html(false)) \
					and bb.contains("[lb]x]") # the '[' in old[x] escaped
			_log("[selftest] %s: diff-bbcode" % ("PASS" if ok else "FAIL"))
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


func _selftest_menu_labels() -> String:
	var labels: Array = []
	for i in range(context_menu.item_count):
		labels.append(context_menu.get_item_text(i))
	return " | ".join(labels)


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
