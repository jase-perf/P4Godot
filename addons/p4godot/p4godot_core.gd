@tool
extends EditorPlugin

## Running p4 (worker thread, streamed transfers, the save-path connect check),
## reading its answers, the connection and login, settings, dialogs, and the
## changelist model. Nothing here knows about the dock.

const SETTINGS_SECTION := "p4godot"
const ACTION_ADD_COLOR := Color("138613") # green
const ACTION_EDIT_COLOR := Color("0084e8") # info blue
const ACTION_DELETE_COLOR := Color("d11323") # cranberry


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


## Emitted once the startup `p4 info` has resolved, successfully or not.
## _ensure_identity() awaits it so hooks that fire during the first moments of
## the session can't race the detection.
signal identity_checked
var log_box: TextEdit
var auto_checkout_checkbox: CheckBox
var detect_external_checkbox: CheckBox
var auto_checkout_detected_checkbox: CheckBox
var checkout_on_save_checkbox: CheckBox
var verbose_log_checkbox: CheckBox
var auto_open_checkbox: CheckBox

# Mirrors verbose_log_checkbox so the logging hot path never touches a UI node.
# When false, read-only probes (fstat/opened/where/changes/info/change -o and -n
# previews) are kept out of the log; state-changing commands always show.
var _verbose_log: bool = false

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
# The workspace's root folder on this computer (`p4 info` clientRoot, forward
# slashes), which can hold more than the Godot project.
var _client_root: String = ""

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
## Whether the server treats "Hero.png" and "hero.png" as one file (`p4 info`'s
## caseHandling). Windows and macOS servers do; Linux servers usually don't.
var _server_folds_case: bool = false

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
# res:// path -> bool: whether the file is Perforce-tracked and unopened
# (eligible for the pre-write pass). Filled by one batched fstat per save
# pass; cleared on every dock refresh so it can't drift far.
var _prewrite_eligible_cache: Dictionary = {}

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
# The save path's own connect check (see _tcp_dialable): p4 has no connect
# timeout, and an unreachable host costs ~21 s on Windows, measured, whatever
# net.maxwait says. A server that answered this recently isn't checked again.
const REACHABLE_TRUST_MSEC := 30000
const DIAL_DEADLINE_MSEC := 2000
var _last_contact_msec: int = 0
# The P4PORT this computer dials, from the override or `p4 set`. Not
# _p4_port: that is the server's own serverAddress, which can be a name only
# the server knows.
var _dial_port: String = ""

# CLI self-test only: "confirm"/"decline" auto-answers dialogs by emitting the
# same signal a real button click would (see the self-test section below).
var _selftest_auto_answer: String = ""
## Self-tests only: text to type into the next input dialogs, first in first
## out, and every alert and confirmation shown so far.
var _selftest_typed: Array = []
## Self-tests only: which entry to choose in the next option dialogs.
var _selftest_option_picks: Array = []
var _selftest_shown: Array = []
## True while a --p4-selftest-* run is driving the plugin. Startup prompts and
## the focus-in scan stay out of the way so a test sees only its own actions.
var _selftest_mode: bool = false


# ---------------------------------------------------------------------------
# Connection and login
#
# Finding p4, probing the server, connection setup, login and password
# changes, the per-command connection flags, and the circuit breaker and
# connect check that keep an unreachable server from stalling the editor.
# ---------------------------------------------------------------------------


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
	_dial_port = await _suggest_port()
	_server_folds_case = String(info.get("caseHandling", "")) == "insensitive"
	var client := String(info.get("clientName", ""))
	var root := String(info.get("clientRoot", ""))
	if client == "*unknown*" or client.is_empty() or not _project_inside_root(root):
		# `p4 info` works without a ticket but listing workspaces doesn't, so
		# log in before the workspace picker - or it finds nothing.
		var ticket: Dictionary = await _p4_exec(["login", "-s"], false)
		if _looks_like_password_expired(ticket):
			return "password expired"
		if _looks_like_login_error(ticket):
			return "not logged in"
		return "no client"
	_p4_client = client
	_client_root = root.replace("\\", "/").trim_suffix("/")
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


## From p4's "P4PORT IDENTIFICATION HAS CHANGED" warning: the address it names
## ("127.0.0.1:2199" - the form `p4 trust -l` keys on) and the new fingerprint,
## exactly as printed. p4 compares fingerprints case-sensitively: a lowercase
## copy installs but doesn't match (measured on 2026.1).
func _fingerprint_change_in(text: String) -> Dictionary:
	var address := ""
	var addr_match := RegEx.create_from_string("P4PORT '([^']+)'").search(text)
	if addr_match:
		address = addr_match.get_string(1)
	var fp_match := RegEx.create_from_string("(?:[0-9A-Fa-f]{2}:){15,}[0-9A-Fa-f]{2}").search(text)
	return {"address": address, "new": fp_match.get_string() if fp_match else ""}


## The fingerprint `p4 trust -l` lists for an address ("host:port fp" lines),
## or "" when there is none.
func _trusted_fingerprint_for(trust_list: String, address: String) -> String:
	if address.is_empty():
		return ""
	for raw_line in trust_list.split("\n"):
		var parts := String(raw_line).strip_edges().split(" ", false)
		if parts.size() == 2 and parts[0] == address:
			return parts[1]
	return ""


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
			_on_workspace_connected()
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
			if not await _handle_fingerprint_change():
				break
			continue
		if status == "no server":
			var prefill: String = await _suggest_port()
			var res: Dictionary = await _show_input_dialog("P4Godot - Connection Setup",
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
		if status == "password expired":
			if not await _change_password_flow():
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


## The server's SSL fingerprint differs from the one this computer trusted:
## warn, naming both, and install exactly the new one if the user says so.
## Returns whether it was trusted.
func _handle_fingerprint_change() -> bool:
	var change := _fingerprint_change_in(_last_probe_text)
	if String(change.new).is_empty():
		await _show_alert("WARNING: this Perforce server's SSL fingerprint has CHANGED since " +
				"this computer last connected, and P4Godot couldn't read the new one (see " +
				"the P4 Log).\n\nThat can mean the server's certificate was replaced - or " +
				"that something is intercepting the connection. Ask your server admin before " +
				"trusting it (`p4 trust -f` in a terminal).")
		return false
	var known := await _p4_exec(["trust", "-l"])
	var old_fp := _trusted_fingerprint_for("" if known.output.is_empty() \
			else String(known.output[0]), String(change.address))
	var trust_new: bool = await _show_confirm_dialog(("WARNING: the SSL fingerprint of the " +
			"Perforce server at %s has CHANGED since this computer last connected.\n\n" +
			"Fingerprint you trusted before:\n%s\n\nFingerprint the server shows now:\n%s\n\n" +
			"That happens when an admin replaces the server's certificate - and when " +
			"something is intercepting the connection. Trust the new fingerprint only if " +
			"your server admin confirms the change and the new fingerprint matches the one " +
			"they gave you, character for character.") \
			% [change.address, old_fp if not old_fp.is_empty() else "(not found)", change.new],
			"Trust New Fingerprint", "Cancel")
	if not trust_new:
		return false
	# -f replaces the old entry; -i installs exactly the fingerprint shown.
	# p4 installs any value it is given without checking it (measured), so
	# the next pass's probe is what confirms it matches.
	await _p4_exec_logged(["trust", "-f", "-i", String(change.new)])
	return true


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
			var res: Dictionary = await _show_input_dialog("P4Godot - Connection Setup", where +
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
		var picked: Dictionary = await _show_option_dialog("P4Godot - Connection Setup",
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
	_client_root = ""
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
		var res: Dictionary = await _show_input_dialog("Log In to Perforce",
				"Perforce needs you to log in again%s.\nPassword for %s:" % [where, who],
				"", false, "Log In", true)
		if not res.ok:
			return false
		var result: Dictionary = await _p4_exec_spec(["login"], String(res.text) + "\n")
		if result.exit_code == 0:
			_log("Logged in to Perforce as %s." % who)
			return true
		if _looks_like_password_expired(result):
			# Logging in again can't fix this one; only a new password does.
			return await _change_password_flow()
		var msg := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		if msg.contains("doesn't exist"):
			# Wrong Perforce user (e.g. the OS username default). Let them fix
			# the user name and go around again.
			var ures: Dictionary = await _show_input_dialog("Log In to Perforce",
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


## The server's answer to every command, `login` included, once a password has
## expired or an admin ran `p4 admin resetpassword` (measured on a 2026.1
## server). Only `p4 passwd` gets past it, so this is not a login error:
## asking for the same password again can never work.
func _looks_like_password_expired(result: Dictionary) -> bool:
	if int(result.get("exit_code", 0)) == 0:
		return false
	for chunk in result.get("output", []):
		if String(chunk).contains("Your password has expired"):
			return true
	return false


## What `p4 passwd` said, without the prompts it echoes before its answer
## ("Enter old password: ", "Enter new password: ", ...).
func _passwd_answer(output_text: String) -> String:
	var lines: Array = []
	for raw in output_text.split("\n"):
		var line := String(raw).strip_edges()
		if line.is_empty() or line.ends_with("password:"):
			continue
		lines.append(line)
	return "\n".join(lines)


## Choose a new Perforce password from inside the editor, then log in with
## it. Returns true once the server has accepted both. A Godot-only user may
## have no P4V and no terminal habit, so this can't just point them elsewhere.
func _change_password_flow() -> bool:
	var who := _p4_user if not _p4_user.is_empty() else \
			(_override_user if not _override_user.is_empty() else "your Perforce user")
	var where := "" if _p4_port.is_empty() else (" on %s" % _p4_port)
	while true:
		var old: Dictionary = await _show_input_dialog("Password Expired",
				("Your Perforce password%s has expired. The server refuses everything " +
				"until you choose a new one.\n\nCurrent password for %s:") % [where, who],
				"", false, "Next", true)
		if not old.ok:
			return false
		var fresh: Dictionary = await _show_input_dialog("Password Expired",
				"New password for %s:" % who, "", false, "Next", true)
		if not fresh.ok:
			return false
		var again: Dictionary = await _show_input_dialog("Password Expired",
				"Type the new password once more:", "", false, "Change Password", true)
		if not again.ok:
			return false
		if String(fresh.text) != String(again.text):
			await _show_alert("The two new passwords didn't match, so nothing was changed. Try again.")
			continue
		var result: Dictionary = await _p4_exec_spec(["passwd"],
				"%s\n%s\n%s\n" % [String(old.text), String(fresh.text), String(fresh.text)])
		var answer := _passwd_answer("" if result.output.is_empty() else String(result.output[0]))
		if result.exit_code != 0 or not answer.contains("Password updated"):
			await _show_alert(("Perforce didn't change your password:\n\n%s\n\nNothing was " +
					"changed. You can try again.") % answer)
			continue
		# A new password ends every ticket the old one issued (measured), so
		# log in straight away instead of prompting for what was just typed.
		var login: Dictionary = await _p4_exec_spec(["login"], String(fresh.text) + "\n")
		if login.exit_code != 0:
			await _show_alert("Perforce changed your password, but logging in with it failed. " +
					"Press Refresh in the P4G panel and log in with the new password.")
			return false
		_log("Changed the Perforce password for %s and logged in." % who)
		return true
	return false # unreachable; while-true exits via return


## Auto-prompt wrapper for an expired password met mid-session. Shares the
## login prompt's single-flight flags: one prompt at a time, and a cancel
## silences both until the user presses Refresh.
func _offer_password_change() -> void:
	if _login_prompt_active or _login_declined or _setup_active or _shutting_down:
		return
	_login_prompt_active = true
	if await _change_password_flow():
		_p4_available = true
		_update_conn_status()
		_request_refresh()
	else:
		_login_declined = true
		_log("The password change didn't finish - Perforce operations will fail until it does. Press Refresh to try again.")
	_login_prompt_active = false


## Called after every plain p4 result: a dead-ticket failure pops one re-login
## prompt. (Spec-stdin commands skip this - `p4 login` itself is one of them.)
func _maybe_offer_login(result: Dictionary) -> void:
	if _looks_like_password_expired(result):
		_offer_password_change()
	elif _looks_like_login_error(result):
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
		_mark_unreachable()
	elif int(result.get("exit_code", -1)) == 0:
		_unreachable_until_msec = 0
		_last_contact_msec = Time.get_ticks_msec()


func _mark_unreachable() -> void:
	if not _server_unreachable():
		_log("The Perforce server isn't answering - saves won't wait on it for the next minute (press Refresh to retry sooner).")
	_unreachable_until_msec = Time.get_ticks_msec() + UNREACHABLE_BACKOFF_MSEC
	_last_contact_msec = 0


## Host and port from a P4PORT, for the save path's connect check:
## "ssl:host:1666", "tcp6:[::1]:1666", "host:1666", "1666" (this computer).
## {} for a form that doesn't dial a TCP port directly (rsh:, jsh:) or doesn't
## parse - those are left to p4.
static func _p4port_host_and_port(p4port: String) -> Dictionary:
	var s := p4port.strip_edges()
	if s.is_empty() or s.begins_with("rsh:") or s.begins_with("jsh:"):
		return {}
	var protocol := RegEx.create_from_string("^(?:ssl|tcp)(?:4|6|46|64)?:").search(s)
	if protocol:
		s = s.substr(protocol.get_end())
	var host := "localhost"
	var port_text := s
	var colon := s.rfind(":")
	if colon != -1:
		host = s.substr(0, colon).trim_prefix("[").trim_suffix("]")
		port_text = s.substr(colon + 1)
	if host.is_empty() or not port_text.is_valid_int():
		return {}
	var port := port_text.to_int()
	if port <= 0 or port > 65535:
		return {}
	return {"host": host, "port": port}


## Whether something accepts a TCP connection at the P4PORT within
## deadline_msec, name lookup included. Blocking: for the main-thread save
## path, where p4's own ~21 s connect timeout would freeze the editor. Answers
## true whenever it can't tell (a P4PORT it can't parse, a name lookup still
## running at the deadline), so p4 decides as it did before: a false "the
## server is down" would skip the checkout a save needs.
func _tcp_dialable(p4port: String, deadline_msec: int) -> bool:
	var target := _p4port_host_and_port(p4port)
	if target.is_empty():
		return true
	var deadline := Time.get_ticks_msec() + deadline_msec
	var address := String(target.host)
	if not address.is_valid_ip_address():
		var item := IP.resolve_hostname_queue_item(address)
		if item == IP.RESOLVER_INVALID_ID:
			return true
		while IP.get_resolve_item_status(item) == IP.RESOLVER_STATUS_WAITING \
				and Time.get_ticks_msec() < deadline:
			OS.delay_msec(5)
		var status := IP.get_resolve_item_status(item)
		address = IP.get_resolve_item_address(item) if status == IP.RESOLVER_STATUS_DONE else ""
		IP.erase_resolve_item(item)
		if status == IP.RESOLVER_STATUS_WAITING:
			return true
		if address.is_empty():
			return false
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host(address, int(target.port)) != OK:
		return false
	var connected := false
	while Time.get_ticks_msec() < deadline:
		tcp.poll()
		var st := tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			connected = true
			break
		if st != StreamPeerTCP.STATUS_CONNECTING:
			break
		OS.delay_msec(5)
	tcp.disconnect_from_host()
	return connected


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
	auto_checkout_detected_checkbox.button_pressed = settings.get_project_metadata(
			SETTINGS_SECTION, "auto_checkout_detected", true)
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
	settings.set_project_metadata(SETTINGS_SECTION, "auto_checkout_detected",
			auto_checkout_detected_checkbox.button_pressed)
	_verbose_log = verbose_log_checkbox.button_pressed


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


func _log(text: String) -> void:
	print("[P4] ", text)
	if log_box:
		if log_box.text.is_empty():
			log_box.text = text
		else:
			log_box.text += "\n" + text
		log_box.set_caret_line(log_box.get_line_count() - 1)
var _progress_last_activity_msec: int = 0


## An editor theme icon by name, or null if this build doesn't have it (so
## set_icon(null) just leaves the row icon-less rather than erroring).
func _theme_icon(icon_name: String) -> Texture2D:
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_icon(icon_name, "EditorIcons"):
		return base.get_theme_icon(icon_name, "EditorIcons")
	return null


func _dim_color() -> Color:
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_color("font_disabled_color", "Editor"):
		return base.get_theme_color("font_disabled_color", "Editor")
	return Color(0.62, 0.62, 0.67)


## The colour for an action word, from the editor theme, so it keeps its
## contrast in light themes and dark ones alike. The constants are the
## fallback when the editor theme lacks the colour.
func _action_color(action: String) -> Color:
	var base := EditorInterface.get_base_control()
	var pair: Array = ["accent_color", ACTION_EDIT_COLOR] # edit / integrate / branch
	if action.contains("delete"):
		pair = ["error_color", ACTION_DELETE_COLOR]
	elif action.contains("add"):
		pair = ["success_color", ACTION_ADD_COLOR]
	if base and base.has_theme_color(String(pair[0]), "Editor"):
		return base.get_theme_color(String(pair[0]), "Editor")
	return pair[1]


func _file_icon(res_path: String) -> Texture2D:
	match res_path.get_extension().to_lower():
		"tscn", "scn": return _theme_icon("PackedScene")
		"gd": return _theme_icon("GDScript")
		"cs": return _theme_icon("CSharpScript")
		"png", "webp", "jpg", "jpeg", "svg", "bmp": return _theme_icon("Image")
	# Anything else by its resource type, as the FileSystem dock shows it
	# ("TileSet" for a tileset.tres), else a plain file: a row without an
	# icon sits out of line with the rest.
	if res_path.begins_with("res://"):
		var type := EditorInterface.get_resource_filesystem().get_file_type(res_path)
		var icon := _theme_icon(type) if not type.is_empty() else null
		if icon:
			return icon
	return _theme_icon("File")


## Whether res_path is open as a scene tab or in the script editor.
func _is_open_in_editor(res_path: String) -> bool:
	if res_path in EditorInterface.get_open_scenes():
		return true
	for s in EditorInterface.get_script_editor().get_open_scripts():
		if (s as Script).resource_path == res_path:
			return true
	return false

## The project subtree as a p4 recursive path argument (the res:// root + "...").
## Bounds both operations to the Godot project even when the P4 workspace is
## wider, and P4IGNORE still applies on top.
func _project_scope() -> String:
	var root := ProjectSettings.globalize_path("res://")
	if not (root.ends_with("/") or root.ends_with("\\")):
		root += "/"
	return root + "..."


## The whole workspace, in client syntax: every file it maps, wherever on
## disk the Godot project sits inside it.
func _workspace_scope() -> String:
	return "//%s/..." % _p4_client


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


## The files with a merge waiting, from `p4 -ztag resolve -n` records:
## [{res_path, local, binary, special, shelf}], sorted by path, one entry per
## file. `shelf`: the changelist whose shelf is the other version, or "" for
## a newer submitted revision.
## `binary`: Perforce can't combine the two versions (contentResolveType is
## not a text merge), so one of them has to win. `special`: the file also needs
## a kind of resolve this plugin doesn't offer (a move, a delete, a filetype
## change), which P4V handles.
func _unresolved_in(records: Array) -> Array:
	var by_local := {}
	for rec in records:
		var local := String(rec.get("clientFile", ""))
		if local.is_empty():
			continue
		var entry: Dictionary = by_local.get(local, {"res_path": _local_key(local),
				"local": local, "binary": false, "special": false, "shelf": ""})
		# Set when the other version is a shelf unshelved onto this file
		# rather than a newer submitted revision.
		if not String(rec.get("shelvedChange", "")).is_empty():
			entry.shelf = String(rec.shelvedChange)
		if String(rec.get("resolveType", "content")) != "content":
			entry.special = true
		elif not String(rec.get("contentResolveType", "")).contains("text"):
			entry.binary = true
		by_local[local] = entry
	var out: Array = by_local.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.res_path) < String(b.res_path))
	return out


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
	for crec in _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending", "-L",
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
# Shelves
#
# `p4 -Mj -ztag describe -S -s N...` and `p4 -Mj -ztag changes -s shelved -l`.
# JSON (-Mj) for the same reason as the file history: a description holding a
# blank line ends a tagged record early. One describe call takes any number of
# changelists and prints one JSON object per changelist (measured on 2026.1).
# ---------------------------------------------------------------------------

## The changelists in `p4 -Mj -ztag describe -S` or `changes -l` output, each
## {change, user, client, time, desc, files}; `files` (describe only) holds
## {depot, action, rev, type, size} per shelved file, where `rev` is the
## revision the shelved file was based on. A delete has no type or size.
## p4's messages ({"data": ...}) are skipped.
static func _shelf_records(text: String) -> Array:
	var out: Array = []
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if not line.begins_with("{"):
			continue
		var rec: Variant = JSON.parse_string(line)
		if not rec is Dictionary or not rec.has("change"):
			continue
		var files: Array = []
		var i := 0
		while rec.has("depotFile%d" % i):
			files.append({
				"depot": String(rec["depotFile%d" % i]),
				"action": String(rec.get("action%d" % i, "")),
				"rev": int(rec.get("rev%d" % i, "0")),
				"type": String(rec.get("type%d" % i, "")),
				"size": int(rec.get("fileSize%d" % i, "0")),
			})
			i += 1
		out.append({
			"change": String(rec.change),
			"user": String(rec.get("user", "")),
			"client": String(rec.get("client", "")),
			"time": int(rec.get("time", "0")),
			"desc": String(rec.get("desc", "")).strip_edges(),
			"files": files,
		})
	return out


## The shelved files of the given numbered changelists: {change: files}, with
## each file as in _shelf_records. A changelist with nothing shelved is absent.
func _read_shelves(changes: Array) -> Dictionary:
	var out := {}
	if changes.is_empty():
		return out
	var args: PackedStringArray = ["-Mj", "-ztag", "describe", "-S", "-s"]
	for c in changes:
		args.append(String(c))
	var result := await _p4_exec(args)
	for shelf in _shelf_records("" if result.output.is_empty() else String(result.output[0])):
		if not shelf.files.is_empty():
			out[String(shelf.change)] = shelf.files
	return out


# ---------------------------------------------------------------------------
# Changelist model - the data behind the dock's changelist tree
# ---------------------------------------------------------------------------

## Snapshot the pending changelists and the files opened in each, mapped back to
## res:// paths. Returns:
##   {available: bool, opened_ok: bool, changelists: Array}
## `opened_ok` says the `p4 opened` query itself succeeded (it exits 0 with an
## empty list when nothing is open), which is what lets _sync_opened_cache
## tell "nothing is checked out" from "we couldn't ask".
## each changelist: {change: "default"|"<n>", desc: String, files: Array,
##                   shelved: Array}
## each file:       {res_path, depot_path, action, change, type}
## each shelved file: {res_path ("" if this workspace doesn't map it),
##                   depot_path, action, rev, type, size, change}
## The default changelist is synthesized (p4 never lists it) and always present,
## even empty, so newly-opened files always have a home in the tree.
func _query_pending_model() -> Dictionary:
	if not await _ensure_identity():
		return {"available": false, "opened_ok": false, "changelists": []}

	# 1. Files opened in our client (across all its pending changelists).
	var opened_result: Dictionary = await _p4_exec(["-ztag", "opened"])
	var opened := _parse_ztag(opened_result)

	# 1b. Pending numbered changelists owned by us in this client, and the
	#     files shelved in those that have a shelf (`changes` tags them with
	#     an empty `shelved` field).
	var changes := _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending", "-L",
			"-c", _p4_client, "-u", _p4_user]))
	var with_shelf: Array = []
	for crec in changes:
		if crec.has("shelved") and not String(crec.get("change", "")).is_empty():
			with_shelf.append(String(crec.change))
	var shelves := await _read_shelves(with_shelf)

	# 2. Map each opened or shelved depotFile to a local path. `opened`'s
	#    clientFile is CLIENT syntax (//workspace/...), not a filesystem path -
	#    `p4 where`'s `path` field is the local OS path we can localize to res://.
	var depot_to_res := {}
	var depot_paths: PackedStringArray = []
	for rec in opened:
		var d := String(rec.get("depotFile", ""))
		if not d.is_empty():
			depot_paths.append(d)
	for files: Array in shelves.values():
		for f: Dictionary in files:
			if not depot_paths.has(String(f.depot)):
				depot_paths.append(String(f.depot))
	for chunk: Array in _path_chunks(Array(depot_paths), WATCH_CHUNK_CHARS):
		var where_args: PackedStringArray = ["-ztag", "where"]
		where_args.append_array(PackedStringArray(chunk))
		for wrec in _parse_ztag(await _p4_exec(where_args)):
			# Exclusionary client mappings emit multiple records per file; keep
			# the one that actually carries a local `path`.
			if wrec.has("path") and not String(wrec["path"]).is_empty():
				depot_to_res[String(wrec.get("depotFile", ""))] = _local_key(String(wrec["path"]))

	# 2b. Which of them have a merge waiting. Only asked when something is
	#     opened: the answer is empty otherwise.
	var unresolved := {}
	if not opened.is_empty():
		for waiting in _unresolved_in(_parse_ztag(await _p4_exec(["-ztag", "resolve", "-n"]))):
			unresolved[String(waiting.res_path)] = true

	# 3. Ordered list: default first, then numbered. by_change indexes into it.
	var cls: Array = []
	var by_change: Dictionary = {}
	var default_cl := {"change": "default", "desc": "(default changelist)", "files": [], "shelved": []}
	cls.append(default_cl)
	by_change["default"] = default_cl
	for crec in changes:
		var num := String(crec.get("change", ""))
		if num.is_empty():
			continue
		var shelved: Array = []
		for f: Dictionary in shelves.get(num, []):
			shelved.append({"res_path": String(depot_to_res.get(String(f.depot), "")),
					"depot_path": String(f.depot), "action": String(f.action), "rev": int(f.rev),
					"type": String(f.type), "size": int(f.size), "change": num})
		var cl := {"change": num, "desc": String(crec.get("desc", "")).strip_edges(), "files": [],
				"shelved": shelved}
		cls.append(cl)
		by_change[num] = cl

	# Bucket opened files under their changelist.
	for rec in opened:
		var depot := String(rec.get("depotFile", ""))
		var res_path: String = depot_to_res.get(depot, "")
		if res_path.is_empty():
			continue # Unmapped by `where`.
		var change_key := String(rec.get("change", "default"))
		if not by_change.has(change_key):
			# Opened in a numbered CL that `changes` didn't return - synthesize a
			# bucket so the file is never silently dropped.
			var cl := {"change": change_key, "desc": "", "files": [], "shelved": []}
			cls.append(cl)
			by_change[change_key] = cl
		by_change[change_key].files.append({
			"res_path": res_path,
			"depot_path": depot,
			"action": String(rec.get("action", "")),
			"change": change_key,
			"type": String(rec.get("type", "")),
			"unresolved": unresolved.has(res_path),
		})

	return {
		"available": true,
		"opened_ok": int(opened_result.get("exit_code", 1)) == 0,
		"changelists": cls,
	}


## How the dock and its actions name a file: its res:// path inside the
## project, and its local path (forward slashes) elsewhere in the workspace.
## ProjectSettings.globalize_path returns a local path unchanged, so actions
## that globalize what they're given work on both.
func _local_key(local_path: String) -> String:
	var res := _local_to_res(local_path)
	return res if not res.is_empty() else local_path.replace("\\", "/")


## Characters of paths per command when a list is spread over several. Windows
## caps a whole command line at 32,767; this leaves room for the connection
## flags.
const WATCH_CHUNK_CHARS := 24000


## Paths grouped so each group's characters stay under `budget`.
static func _path_chunks(paths: Array, budget: int) -> Array:
	var chunks: Array = []
	var current: Array = []
	var used := 0
	for p: String in paths:
		if not current.is_empty() and used + p.length() + 3 > budget:
			chunks.append(current)
			current = []
			used = 0
		current.append(p)
		used += p.length() + 3
	if not current.is_empty():
		chunks.append(current)
	return chunks


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
			and not _p4_subcommand(args) in ["info", "login", "set", "describe"]:
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
	if args[cmd_idx] == "clean":
		# `clean` is `reconcile -w` and, measured, also wants raw local names:
		# with %40 for an @ it answers "no file(s) to reconcile", exit 0, and
		# puts nothing back. It takes no -f.
		return out
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
	var recently := _last_contact_msec != 0 \
			and Time.get_ticks_msec() - _last_contact_msec < REACHABLE_TRUST_MSEC
	if not recently and not _tcp_dialable(_dial_port, DIAL_DEADLINE_MSEC):
		_mark_unreachable()
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
## Self-tests only: press Cancel once p4 reports every file sent - the server
## then has the whole submit and only its triggers and commit are left.
var _selftest_cancel_when_sent: bool = false

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
			_cancel_streamed()
		if _selftest_cancel_when_sent and tracker.reporting and tracker.in_flight() == 0 \
				and tracker.files_done >= tracker.expected_files():
			_selftest_cancel_when_sent = false
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
		"diff", "diff2", "set", "clients", "describe", "filelog", "annotate", "users", \
		"ignores", "streams", "sizes":
			return true
		"client":
			return "-o" in args # client -o reads; client -i / -d change the workspace
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
			# Here, not only on the main thread after the await: the file can
			# hold a password, and an editor quit mid-command never resumes
			# that await.
			DirAccess.remove_absolute(req.stdin_path)
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
		# Not after a kill: on Linux and macOS OS.kill() also reaps the process
		# (waitpid), so asking again is an error ("not a child of the calling
		# process") on every poll until the pipes drain.
		var running := not req.killed and OS.is_process_running(pid)
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
	if req.killed:
		# The status of a killed p4 is lost where OS.kill() reaps it, and
		# Godot then reports 0 - a cancel that reads as success. Callers read
		# `cancelled` and ask the server what happened.
		req.exit_code = -1
	elif not req.detach:
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
	if _selftest_mode:
		_selftest_shown.append(text)
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.title = "P4Godot"
	dialog.set_text(text)
	dialog.set_ok_button_text(ok_text)
	dialog.set_cancel_button_text(cancel_text)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	# Belt and braces: also resolve if the window is closed some way that
	# skips confirmed/canceled - never leave the coroutine hanging.
	dialog.close_requested.connect(_on_confirm_dialog_canceled)

	_popup_dialog(dialog)

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
	vbox.add_child(_message_label(message))
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
	_popup_dialog(dialog)

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if not _selftest_typed.is_empty():
				input.text = String(_selftest_typed.pop_front())
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
		preselect: int, ok_text: String, extra_text: String = "", cancel_text: String = "Cancel") -> Dictionary:
	if _shutting_down:
		return {"ok": false, "index": -1, "extra": false}
	if _selftest_mode:
		_selftest_shown.append(message)
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false
	_dialog_result_extra = false

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.set_ok_button_text(ok_text)
	dialog.set_cancel_button_text(cancel_text)
	if not extra_text.is_empty():
		dialog.add_button(extra_text, true, "extra")
		dialog.custom_action.connect(_on_dialog_extra_action)
	var vbox := VBoxContainer.new()
	vbox.add_child(_message_label(message))
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
	_popup_dialog(dialog)

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if not _selftest_option_picks.is_empty():
				picker.select(int(_selftest_option_picks.pop_front()))
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
	dialog.title = "P4Godot - Connection Settings"
	dialog.set_ok_button_text("Connect")
	var vbox := VBoxContainer.new()
	vbox.add_child(_message_label(("Which Perforce server this project uses, and who you are " +
			"on it. Stored for this project only, for you only. Leave a box empty to use your " +
			"normal Perforce settings (a P4CONFIG file, or `p4 set`).")))
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
	_popup_dialog(dialog)

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
		cancel_text: String, choices: Array, title: String = "Check Out",
		picker_label: String = "Check out to:") -> Dictionary:
	if _shutting_down:
		return {"ok": false, "change": "default"}
	if _selftest_mode:
		_selftest_shown.append(text)
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false
	_dialog_result_confirmed = false

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.set_ok_button_text(ok_text)
	dialog.set_cancel_button_text(cancel_text)
	var vbox := VBoxContainer.new()
	vbox.add_child(_message_label(text))
	var row := HBoxContainer.new()
	var row_label := Label.new()
	row_label.text = picker_label
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
	_popup_dialog(dialog)

	if not _selftest_auto_answer.is_empty():
		await get_tree().process_frame
		if is_instance_valid(dialog):
			if not _selftest_option_picks.is_empty():
				picker.select(int(_selftest_option_picks.pop_front()))
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


## Whether `local` is the temporary file a Godot save left behind when it
## couldn't replace the real file (a read-only one, say): the real file's
## name plus digits and ".tmp" - "project.godot4667122.tmp" - with the real
## file beside it. Never worth adding to Perforce; Godot replaces or drops it.
static func _is_godot_save_leftover(local: String) -> bool:
	if not local.ends_with(".tmp"):
		return false
	var stem := local.trim_suffix(".tmp")
	# The digits can also end the real name ("music.mp3" + "4667122"), so
	# every split of the trailing digits is tried, leaving at least four.
	var digits := 0
	while digits < stem.length() and stem[stem.length() - 1 - digits].is_valid_int():
		digits += 1
	for k in range(digits, 3, -1):
		if FileAccess.file_exists(stem.left(stem.length() - k)):
			return true
	return false


## A plugin window's background, from the editor theme. Without it a window
## shows Godot's default grey, which is close to the dark theme by chance and
## puts dark text on dark grey in the light one (seen in the GUI tour). Call
## right after creating the window, so it is drawn under everything else.
func _themed_background(window: Window) -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_color_background(bg)
	# Windows built with the panel outlive a theme change: follow it.
	bg.theme_changed.connect(_color_background.bind(bg))
	window.add_child(bg)


func _color_background(bg: ColorRect) -> void:
	var base := EditorInterface.get_base_control()
	bg.color = base.get_theme_color("base_color", "Editor") \
			if base and base.has_theme_color("base_color", "Editor") else Color(0.13, 0.14, 0.16)


## A code editor colour from the live editor theme (what the script editor
## draws with), or `fallback`. The theme, not the text editor settings: those
## kept their dark values when the theme changed to light at run time.
static func _code_color(name: String, fallback: Color) -> Color:
	var base := EditorInterface.get_base_control()
	return base.get_theme_color(name, "CodeEdit") if base and base.has_theme_color(name, "CodeEdit") else fallback


## A file's name in the tree. res:// is implied for project files; dropping
## it leaves more room for the paths themselves. A file elsewhere in the
## workspace is shown relative to the project folder ("../art/hero.psd"), so
## it reads as the neighbour it is. The tooltip keeps the full story.
func _tree_label(key: String) -> String:
	if key.begins_with("res://"):
		return key.trim_prefix("res://")
	if key.begins_with("//"):
		return key # a depot path: not on this computer

	return _relative_to_project(key)


## `local` relative to the project folder, climbing out with "../" as far as
## needed; unchanged when the two share no folder (another drive).
func _relative_to_project(local: String) -> String:
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
	var a := project.split("/")
	var b := local.replace("\\", "/").split("/")
	var fold := OS.get_name() in ["Windows", "macOS"]
	var common := 0
	while common < a.size() and common < b.size() - 1:
		var same := a[common].to_lower() == b[common].to_lower() if fold else a[common] == b[common]
		if not same:
			break
		common += 1
	if common == 0:
		return local
	var parts := PackedStringArray()
	for i in a.size() - common:
		parts.append("..")
	parts.append_array(b.slice(common))
	return "/".join(parts)


## How wide every dialog's text is, before editor scaling: long text wraps
## at a reading width instead of stretching the dialog across the screen.
const DIALOG_WIDTH := 560
## An alert longer than this is cut short (its whole text is in the Log), so
## its OK button stays on the screen.
const ALERT_MAX_LINES := 30

static var _res_prefix_re: RegEx


## Show one of the plugin's dialogs: at the reading width with its text
## wrapped, titled "P4Godot" unless it has a title of its own, and with
## project paths written as the P4G panel writes them (no "res://").
func _popup_dialog(dialog: AcceptDialog) -> void:
	# Every dialog says it is the plugin's: "Check Out" alone could be any
	# plugin's, or Godot's.
	if dialog.title.is_empty():
		dialog.title = "P4Godot"
	elif not dialog.title.begins_with("P4Godot"):
		dialog.title = "P4Godot - " + dialog.title
	dialog.dialog_text = _plain_paths(dialog.dialog_text)
	dialog.dialog_autowrap = true
	var width := int(DIALOG_WIDTH * EditorInterface.get_editor_scale())
	# Do NOT add_child(dialog) first: popup_exclusive_centered() parents the
	# dialog itself (Window::_try_parent_dialog()) and silently no-ops - the
	# dialog never shows, with no error - if it already has a parent.
	dialog.popup_exclusive_centered(EditorInterface.get_base_control(), Vector2i(width, 0))
	_fit_dialog_height(dialog, width)


## A wrapping label reports its height before it knows its width, which left
## dialogs with a tall empty band above their buttons (measured in the GUI
## tour). Once laid out at its width, the dialog takes the height it needs.
func _fit_dialog_height(dialog: AcceptDialog, width: int) -> void:
	for i in 2:
		await get_tree().process_frame
	if not is_instance_valid(dialog) or not dialog.visible:
		return
	dialog.size = Vector2i(width, int(dialog.get_contents_minimum_size().y))
	dialog.move_to_center()


## The message of a dialog with fields of its own: wrapped at the reading
## width, with paths written as the panel writes them - what _popup_dialog
## does for a plain dialog's text.
func _message_label(text: String) -> Label:
	var label := Label.new()
	label.text = _plain_paths(text)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = (DIALOG_WIDTH - 32) * EditorInterface.get_editor_scale()
	return label


## `text` with "res://" dropped from the start of each project path. The P4G
## panel names project files that way, so dialogs and panel agree.
static func _plain_paths(text: String) -> String:
	if _res_prefix_re == null:
		_res_prefix_re = RegEx.create_from_string("(^|[\\s'\"(])res://(?=\\S)")
	return _res_prefix_re.sub(text, "$1", true)


## Shows a modal OK-only notice (checkout failures and other conditions the
## user should see without being asked anything). Serialized through the same
## _dialog_busy lock as _show_confirm_dialog so alerts and prompts can never
## fight over the pending-result state.
func _show_alert(text: String) -> void:
	_log(text.replace("\n\n", "\n"))
	if _selftest_mode:
		_selftest_shown.append(text)
	if _shutting_down:
		return # Logged above; no dialog mid-teardown.
	while _dialog_busy:
		await get_tree().process_frame
	_dialog_busy = true
	_dialog_result_ready = false

	var dialog := AcceptDialog.new()
	dialog.title = "P4Godot"
	# Raw p4 output can run to hundreds of lines; the Log (above) has it all.
	var lines := text.split("\n")
	if lines.size() > ALERT_MAX_LINES:
		text = "\n".join(lines.slice(0, ALERT_MAX_LINES)) + \
				"\n\n... and %d more lines - press \"Log\" in the P4G panel for the rest." % (lines.size() - ALERT_MAX_LINES)
	dialog.set_text(text)
	dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	dialog.canceled.connect(_on_confirm_dialog_canceled)
	dialog.close_requested.connect(_on_confirm_dialog_canceled)
	_popup_dialog(dialog)

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


## What `p4 add <one file>` did: "added", "ignored" (P4IGNORE covers the file;
## p4 prints a misleading "opened for add" line first and then refuses),
## "tracked" (already on the server; p4 exits 0), or "failed".
func _add_outcome(text: String, exit_code: int) -> String:
	if text.contains("ignored file can't be added"):
		return "ignored"
	if text.contains("can't add existing file") or text.contains("can't add (already opened"):
		return "tracked"
	if exit_code == 0 and (text.contains("opened for add") or text.contains("currently opened for add")):
		return "added"
	return "failed"


## The "<file>:<line>:<rule>" part of `p4 ignores -i -v`'s
## "<path> ignored by <file>:<line>:<rule>", or "" when it isn't there.
func _ignore_rule_in(text: String) -> String:
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		var at := line.find(" ignored by ")
		if at >= 0:
			return line.substr(at + " ignored by ".length())
	return ""


## Run `p4 -ztag fstat` for one file, cache the parsed record (or {} if untracked/
## unavailable), and return it. Shared by the tooltip prefetch and Show Status.
func _fetch_fstat_record(res_path: String) -> Dictionary:
	if not await _ensure_identity():
		return {}
	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", ProjectSettings.globalize_path(res_path)]))
	var rec: Dictionary = recs[0] if not recs.is_empty() else {}
	_fstat_cache[res_path] = {"data": rec, "time": Time.get_unix_time_from_system()}
	return rec


## Ask the dock to redraw from fresh p4 state. The dock overrides this; below
## it there is nothing to redraw.
func _request_refresh() -> void:
	pass


## Show the connection state in the dock's toolbar. The dock overrides this.
func _update_conn_status() -> void:
	pass


## Connection setup just connected a workspace (on first setup, or after the
## user picked another one). The watch layer overrides this to offer
## leaving the workspace's files writable.
func _on_workspace_connected() -> void:
	pass
