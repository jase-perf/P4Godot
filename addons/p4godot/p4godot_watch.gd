@tool
extends "p4godot_menus.gd"

## Watching the workspace, so Perforce keeps up with files changed by any
## program, anywhere in the workspace - not only the Godot project:
## - Opened files are kept honest. A file opened for add that has gone from
##   disk leaves its changelist (otherwise the submit fails on it), and a file
##   opened for delete that is back on disk is reverted when unchanged and
##   opened for edit when changed.
## - Changed files are found by comparing each file's modification time with
##   the one Perforce last vouched for, so only files that changed since are
##   reconciled. Edits are checked out automatically (a setting lists them
##   instead); new and missing files are listed in the dock under "Changed,
##   not checked out".
## - The workspace can be switched to `allwrite`, which leaves files
##   writable, so Godot's own rewrites (every .import on a reimport) never
##   fail on a read-only file.
##
## Measured on a throwaway p4d 2026.1 (Windows, 20,000 small text files): a
## reconcile preview of the whole workspace took 12-16 s with or without -m;
## one of 500 named files 0.47 s; all 20,000 named in one command 70 s. The
## walk below reads 20,000 modification times in 0.8-1.0 s on a thread.

## Files whose modification time is younger than this may still be being
## written, and file times have one-second resolution: a check made within
## this window of a write can't tell two writes in the same second apart.
const WATCH_SETTLE_SEC := 2
## Time between passes, scaled with how long the walk takes so a huge
## workspace isn't walked continuously.
const WATCH_INTERVAL_MIN_SEC := 30.0
const WATCH_INTERVAL_MAX_SEC := 300.0
const WATCH_INTERVAL_WALK_FACTOR := 30.0
## Characters of paths per reconcile. Windows caps a whole command line at
## 32,767; this leaves room for the connection flags. Small chunks also let
## the editor's own commands run in between on the one worker queue.
## Folders never walked: Godot's cache (always ignored, and huge) and other
## version control systems' stores.
const WATCH_SKIP_DIRS := [".godot", ".git", ".svn", ".hg"]
## A walk stops after this many files; the cache would otherwise grow past
## what is worth keeping in memory.
const WATCH_MAX_FILES := 400000
const WATCH_CACHE_VERSION := 2
const WATCH_SAVE_INTERVAL_MSEC := 120000
## How often a file listed as missing is asked about again.
const WATCH_MISSING_RECHECK_SEC := 300
## The focus-in and timer triggers can't start passes closer together than
## this, measured from the end of the last one.
const EXTERNAL_SCAN_MIN_INTERVAL_MSEC := 5000
## How long an unfinished pass blocks the next one before it's written off.
const EXTERNAL_SCAN_STUCK_MSEC := 300000

const CTX_DETECTED_OPEN := 900
const CTX_DETECTED_OPEN_ALL := 901
const CTX_DETECTED_DIFF := 902
const CTX_DETECTED_SHOW := 903
const CTX_DETECTED_HISTORY := 904
const SETTINGS_MENU_ALLWRITE := 11

# Per file, keyed by _path_key: [local path, modification time (-1: missing
# from disk), unix time it was checked, verdict]. The verdict is what
# `reconcile` would open the file for ("edit", "add", "delete"), or "" when
# Perforce had nothing to do - which covers ignored and unmapped files too.
var _watch_cache: Dictionary = {}
# The cache file _watch_cache belongs to ("" until loaded).
var _watch_cache_path_loaded: String = ""
var _watch_cache_dirty: bool = false
var _watch_cache_saved_msec: int = 0
# Keys opened at the last pass. A file that stops being opened (submitted or
# reverted, here or in P4V) is checked again: its old verdict can't be
# trusted. Saved with the cache, so this also works across restarts.
var _watch_opened_prev: Dictionary = {}
# key -> modification time at which an automatic open was tried. Not retried
# until the file changes again: a refusal (a teammate's exclusive lock) would
# otherwise repeat on every pass.
var _watch_attempted: Dictionary = {}
# key -> why Perforce refused to open it, for the dock row.
var _watch_refused: Dictionary = {}
# Keys whose refusal the user has been told about this session.
var _watch_alerted: Dictionary = {}
# Local key -> whether an opened file was on disk when last looked at. The
# opened-file cleanup acts only on a change it saw happen (see _tidy_plan).
var _watch_seen: Dictionary = {}
# The dock's "Changed, not checked out" rows: [{key, local, action}].
var _watch_detected: Array = []
var _watch_thread: Thread
# Shared with the walk thread, which stops at the next folder once it's set.
var _watch_abort: Array = [false]
var _modes_thread: Thread
# Bumped when the connection changes: a pass that started before must not
# write what it learned about the old workspace into the new one's cache.
var _watch_epoch: int = 0
# Bumped by every pass, so one released as stuck can't clear the in-flight
# flag of the pass that replaced it.
var _watch_generation: int = 0
var _watch_timer: Timer
var _watch_followup_queued: bool = false
# Whether the workspace is `allwrite`, from its spec; null until read.
var _client_allwrite: Variant = null
# For self-tests: paths reconciled by the last pass, and passes finished.
var _watch_last_checked: Array = []
var _watch_passes: int = 0

var _external_scan_inflight: bool = false
var _external_scan_started_msec: int = 0
var _external_scan_last_msec: int = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC


# ---------------------------------------------------------------------------
# Starting and stopping
# ---------------------------------------------------------------------------

func _start_watching() -> void:
	_watch_timer = Timer.new()
	_watch_timer.wait_time = WATCH_INTERVAL_MIN_SEC
	_watch_timer.timeout.connect(_on_watch_timer)
	add_child(_watch_timer)
	_watch_timer.start()
	_watch_first_pass()


func _watch_first_pass() -> void:
	if await _ensure_identity():
		_scan_for_external_changes("Godot started")


func _stop_watching() -> void:
	if _watch_timer:
		_watch_timer.stop()
		_watch_timer.queue_free()
		_watch_timer = null
	if _watch_thread != null:
		_watch_abort[0] = true
		_watch_thread.wait_to_finish()
		_watch_thread = null
	if _modes_thread != null:
		_modes_thread.wait_to_finish()
		_modes_thread = null
	_save_watch_cache(true)


func _on_watch_timer() -> void:
	_scan_for_external_changes("timer")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_scan_for_external_changes("Godot regained focus")


func _detect_external_changes() -> bool:
	return detect_external_checkbox != null and detect_external_checkbox.button_pressed


func _reset_connection_state() -> void:
	super()
	_save_watch_cache(true)
	_watch_epoch += 1
	_watch_cache = {}
	_watch_cache_path_loaded = ""
	_watch_opened_prev = {}
	_watch_attempted = {}
	_watch_refused = {}
	_watch_alerted = {}
	_watch_seen = {}
	_watch_detected = []
	_client_allwrite = null


## Look for files changed outside Godot and deal with them. Silent when
## there's nothing to report. `reason` shows only in the verbose log.
func _scan_for_external_changes(reason: String) -> void:
	if not _detect_external_changes() or _shutting_down:
		return
	if _external_scan_inflight:
		# A pass can wait on a dialog, and a dialog freed without an answer
		# leaves its coroutine parked forever. Without this release one such
		# dialog would turn the watcher off for the rest of the session.
		if Time.get_ticks_msec() - _external_scan_started_msec < EXTERNAL_SCAN_STUCK_MSEC:
			return
		_log("The last look for changed files never finished - starting a new one.")
	if _identity_checked and not _p4_available:
		return # p4 was unavailable at startup - the plugin is inert.
	if _server_unreachable():
		return # The breaker is open; don't spend another timeout on a pass.
	var now := Time.get_ticks_msec()
	if now - _external_scan_last_msec < EXTERNAL_SCAN_MIN_INTERVAL_MSEC:
		return
	_external_scan_inflight = true
	_external_scan_started_msec = now
	_watch_generation += 1
	var generation := _watch_generation
	await _scan_for_external_changes_inner(reason)
	if generation != _watch_generation:
		return # Released as stuck; a newer pass owns the flags now.
	# Time from the END of the pass, so a slow one can't immediately re-fire.
	_external_scan_last_msec = Time.get_ticks_msec()
	_external_scan_inflight = false


# ---------------------------------------------------------------------------
# One pass
# ---------------------------------------------------------------------------

func _scan_for_external_changes_inner(reason: String) -> void:
	if not await _ensure_identity():
		return
	var epoch := _watch_epoch
	if _verbose_log:
		_log("Looking for changed files in the workspace (%s)..." % reason)
	var records: Variant = await _opened_records()
	if records == null or _watch_gone(epoch):
		return
	if await _tidy_opened_files(records, true) > 0:
		records = await _opened_records()
		if records == null or _watch_gone(epoch):
			return
	var opened := {}
	for rec: Dictionary in records:
		var local := String(rec.get("clientFile", ""))
		if not local.is_empty():
			opened[_path_key(local)] = true

	var root := _watch_root()
	var started := Time.get_ticks_msec()
	var walked: Dictionary = await _walk_workspace(root)
	if _watch_gone(epoch):
		return
	var walk_sec := (Time.get_ticks_msec() - started) / 1000.0
	if walked.is_empty() and not DirAccess.dir_exists_absolute(root):
		return
	if walked.size() >= WATCH_MAX_FILES:
		_log(("The workspace has more than %d files; P4Godot watches only the first %d it " +
				"finds. Narrow the workspace view or ignore large folders.") % [WATCH_MAX_FILES, WATCH_MAX_FILES])

	_load_watch_cache()
	# A file that stopped being opened was submitted or reverted somewhere;
	# what was known about it before it was opened no longer holds.
	for key: String in _watch_opened_prev:
		if not opened.has(key):
			_watch_cache.erase(key)
			_watch_attempted.erase(key)
			_watch_refused.erase(key)
			_watch_cache_dirty = true
	if _watch_opened_prev.hash() != opened.hash():
		_watch_cache_dirty = true
	_watch_opened_prev = opened

	var now := int(Time.get_unix_time_from_system())
	var plan := _watch_candidates(walked, _watch_cache, opened, now)
	var paths: Array = plan.check
	_watch_last_checked = paths
	if paths.size() > 1000:
		_log(("Checking %d files in the workspace for changes made outside Godot. This " +
				"happens once; after that only files that change are checked.") % paths.size())
	var verdicts: Variant = await _reconcile_preview_paths(paths)
	if verdicts == null or _watch_gone(epoch):
		return # The server stopped answering (nothing learned; try again later), or the workspace changed.
	for path: String in paths:
		var key := _path_key(path)
		var verdict := String(verdicts.get(key, ""))
		var on_disk: Variant = walked.get(key)
		if on_disk == null:
			if verdict.is_empty():
				_watch_cache.erase(key)
			else:
				_watch_cache[key] = [path, -1, now, verdict]
		else:
			_watch_cache[key] = [String(on_disk[0]), int(on_disk[1]), now, verdict]
		_watch_cache_dirty = true

	await _act_on_detected(opened, epoch)
	if _watch_gone(epoch):
		return
	_save_watch_cache(false)
	_watch_passes += 1
	if _watch_timer:
		_watch_timer.wait_time = clampf(walk_sec * WATCH_INTERVAL_WALK_FACTOR,
				WATCH_INTERVAL_MIN_SEC, WATCH_INTERVAL_MAX_SEC)
	if plan.unsettled and not _watch_followup_queued:
		# Something was still being written; look again once it has settled.
		_watch_followup_queued = true
		get_tree().create_timer((EXTERNAL_SCAN_MIN_INTERVAL_MSEC / 1000.0) + 1.0).timeout.connect(
				_on_watch_followup)


## Whether a pass that started in `epoch` must stop: the editor is closing,
## or the connection changed under it.
func _watch_gone(epoch: int) -> bool:
	return _shutting_down or epoch != _watch_epoch


func _on_watch_followup() -> void:
	_watch_followup_queued = false
	_scan_for_external_changes("a file was still being written")


## Which files to ask Perforce about. `walked`: key -> [path, mtime] from the
## disk; `cache`: key -> [path, mtime, checked, verdict]; `opened`: keys of
## opened files, which Perforce already tracks; `now`: unix seconds.
## Returns {check: [paths], unsettled: bool}. A file is checked when it is
## new, its time changed, or its last check came too soon after its write to
## trust; a cached file gone from disk is checked once (a delete, or a file
## Perforce never had), and again every WATCH_MISSING_RECHECK_SEC while it
## stays listed. Files written in the last WATCH_SETTLE_SEC wait.
static func _watch_candidates(walked: Dictionary, cache: Dictionary, opened: Dictionary,
		now: int) -> Dictionary:
	var check: Array = []
	var unsettled := false
	for key: String in walked:
		if opened.has(key):
			continue
		var mtime := int(walked[key][1])
		if mtime > now - WATCH_SETTLE_SEC:
			unsettled = true
			continue
		var entry: Variant = cache.get(key)
		if entry == null or int(entry[1]) != mtime or int(entry[2]) < mtime + WATCH_SETTLE_SEC:
			check.append(String(walked[key][0]))
	for key: String in cache:
		if walked.has(key) or opened.has(key):
			continue
		# Known missing: asked again now and then, since a teammate's delete
		# and a Get Latest can settle it without anything on disk changing.
		if int(cache[key][1]) != -1 or int(cache[key][2]) < now - WATCH_MISSING_RECHECK_SEC:
			check.append(String(cache[key][0]))
	return {"check": check, "unsettled": unsettled}


## `reconcile -n` on exactly these paths, in chunks. Returns key -> action
## for each file Perforce would open, or null when the server didn't answer
## (so nothing is recorded as checked).
func _reconcile_preview_paths(paths: Array) -> Variant:
	var verdicts := {}
	for chunk: Array in _path_chunks(paths, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["-ztag", "reconcile", "-n"]
		for p: String in chunk:
			args.append(p)
		var result := await _p4_exec(args)
		if _shutting_down:
			return null
		var recs := _parse_ztag(result)
		if recs.is_empty() and int(result.exit_code) != 0 and not _reconcile_had_nothing(result):
			return null
		for rec in recs:
			var local := String(rec.get("clientFile", ""))
			var action := String(rec.get("action", ""))
			if local.is_empty() or action.is_empty():
				continue
			verdicts[_path_key(local)] = action.trim_prefix("move/")
	return verdicts


## Whether a failed reconcile answer only means "nothing to do". Measured on
## p4d 2026.1: ignored, clean, and never-tracked-and-gone files answer "no
## file(s) to reconcile" and exit 0; a path outside the workspace root
## answers "is not under client's root" and exits 1.
static func _reconcile_had_nothing(result: Dictionary) -> bool:
	var text := "" if result.output.is_empty() else String(result.output[0])
	if text.strip_edges().is_empty():
		return false
	for line in text.split("\n", false):
		var l := line.strip_edges().to_lower()
		if l.is_empty():
			continue
		if not (l.contains("no file(s) to reconcile") or l.contains("not in client view")
				or l.contains("not under client's root") or l.contains("no such file(s)")):
			return false
	return true


## Open what the settings say to open, and list the rest in the dock.
func _act_on_detected(opened: Dictionary, epoch: int) -> void:
	var detected := _watch_detected_rows(opened)
	var to_open: Array = []
	for row: Dictionary in detected:
		if _watch_attempted.has(row.key) and int(_watch_attempted[row.key]) == int(row.mtime):
			continue
		if row.action == "edit" and auto_checkout_detected_checkbox != null \
				and auto_checkout_detected_checkbox.button_pressed:
			to_open.append(row)
		elif row.action == "add" and _auto_open():
			to_open.append(row)
	if not to_open.is_empty():
		var names: Array = to_open.map(func(r: Dictionary) -> String: return _tree_label(_local_key(r.local)))
		_log("Changed outside Godot - opening in Perforce: %s" % ", ".join(names.slice(0, 10)) \
				+ ("" if names.size() <= 10 else " and %d more" % (names.size() - 10)))
		var now_opened: Variant = await _open_detected(to_open)
		if _watch_gone(epoch):
			return
		if now_opened != null:
			opened = now_opened
			_watch_opened_prev = opened
		detected = _watch_detected_rows(opened)
	_set_watch_detected(detected)


## The cache's changed files that aren't opened, as dock rows.
func _watch_detected_rows(opened: Dictionary) -> Array:
	var rows: Array = []
	for key: String in _watch_cache:
		var entry: Array = _watch_cache[key]
		if String(entry[3]).is_empty() or opened.has(key):
			continue
		rows.append({"key": key, "local": String(entry[0]), "mtime": int(entry[1]),
				"action": String(entry[3])})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.local) < String(b.local))
	return rows


func _set_watch_detected(rows: Array) -> void:
	var before := _watch_detected.map(func(r: Dictionary) -> String: return "%s:%s" % [r.key, r.action])
	var after := rows.map(func(r: Dictionary) -> String: return "%s:%s" % [r.key, r.action])
	_watch_detected = rows
	if before != after:
		_request_refresh()


## `reconcile` the rows' files, which opens each one for what it needs (edit,
## add or delete). Remembers each attempt, so a refusal isn't retried until
## the file changes again, and tells the user about a refused file once per
## session - an artist saving a teammate's locked file every minute would
## otherwise get a dialog every minute. Not awaited: a pass must not wait on
## a dialog. Returns the keys opened afterwards, or null if unknown.
func _open_detected(rows: Array) -> Variant:
	var locals: Array = rows.map(func(r: Dictionary) -> String: return String(r.local))
	var lines: Array = []
	for chunk: Array in _path_chunks(locals, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["reconcile"]
		for p: String in chunk:
			args.append(p)
		lines.append_array(_refusals(await _p4_exec_logged(args)).lines)
	var records: Variant = await _opened_records()
	if records == null:
		return null
	var opened := {}
	for rec: Dictionary in records:
		opened[_path_key(String(rec.get("clientFile", "")))] = true
	var refused_rows: Array = rows.filter(func(r: Dictionary) -> bool: return not opened.has(r.key))
	# p4 names a refused file by its depot path.
	var depot_of := {}
	if not refused_rows.is_empty():
		for chunk: Array in _path_chunks(refused_rows.map(func(r: Dictionary) -> String: return String(r.local)),
				WATCH_CHUNK_CHARS):
			var args: PackedStringArray = ["-ztag", "where"]
			args.append_array(PackedStringArray(chunk))
			for w in _parse_ztag(await _p4_exec(args)):
				if w.has("path") and w.has("depotFile"):
					depot_of[_path_key(String(w.path))] = String(w.depotFile).to_lower()
	var to_tell: Array = []
	for row: Dictionary in rows:
		_watch_attempted[row.key] = row.mtime
		if opened.has(row.key):
			_watch_refused.erase(row.key)
			continue
		var reason := ""
		var depot := String(depot_of.get(row.key, ""))
		for line: String in lines:
			var l := _path_key(line)
			if l.contains(String(row.key)) or (not depot.is_empty() and l.contains(depot)):
				reason = line.strip_edges()
		_watch_refused[row.key] = reason if not reason.is_empty() else "Perforce didn't open it; the Log says why."
		if not _watch_alerted.has(row.key):
			_watch_alerted[row.key] = true
			to_tell.append(_tree_label(_local_key(String(row.local))) + ": " + String(_watch_refused[row.key]))
	_request_refresh()
	if not to_tell.is_empty():
		_log("Perforce refused %d of the %d changed file(s)." % [refused_rows.size(), rows.size()])
		_show_alert(("Perforce wouldn't check out these files you changed:\n\n%s\n\nMost often a " +
				"teammate has the file locked. Your changes are safe on your computer; the P4G panel " +
				"lists the files under \"Changed, not checked out\", where you can check them out once " +
				"the teammate is done.") % _file_listing(to_tell))
	return opened


# ---------------------------------------------------------------------------
# The walk and the cache
# ---------------------------------------------------------------------------

## The folder to watch: the workspace root, or the project when the
## workspace has none (a `null` root, or one that isn't a folder here).
func _watch_root() -> String:
	var root := _client_root
	if root.is_empty() or root == "null" or not DirAccess.dir_exists_absolute(root):
		root = ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
	return root


## Every file under `root` with its modification time, read on a thread.
func _walk_workspace(root: String) -> Dictionary:
	var out := {}
	if _watch_thread != null:
		return out
	_watch_thread = Thread.new()
	_watch_abort = [false]
	_watch_thread.start(_walk_tree.bind(root, out, WATCH_MAX_FILES, _watch_abort))
	while _watch_thread != null and _watch_thread.is_alive():
		await get_tree().process_frame
	if _watch_thread == null:
		return {} # Stopped while walking (the plugin is shutting down).
	_watch_thread.wait_to_finish()
	_watch_thread = null
	return out


## Runs on the walk thread: touches nothing but its arguments.
static func _walk_tree(root: String, out: Dictionary, cap: int, abort: Array) -> void:
	var stack: Array[String] = [root]
	while not stack.is_empty() and not abort[0]:
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		d.include_hidden = true
		for f in d.get_files():
			var p := dir + "/" + f
			out[_path_key(p)] = [p, FileAccess.get_modified_time(p)]
			if out.size() >= cap:
				return
		for sub in d.get_directories():
			# Linked folders can loop back on themselves.
			if sub in WATCH_SKIP_DIRS or d.is_link(sub):
				continue
			stack.append(dir + "/" + sub)


func _watch_cache_file() -> String:
	var id := ("%s|%s|%s" % [_p4_port, _p4_client, _watch_root()]).md5_text()
	return EditorInterface.get_editor_paths().get_cache_dir().path_join(
			"p4godot-watch").path_join("%s.bin" % id)


func _load_watch_cache() -> void:
	var path := _watch_cache_file()
	if path == _watch_cache_path_loaded:
		return
	_watch_cache = {}
	_watch_opened_prev = {}
	_watch_seen = {}
	_watch_cache_path_loaded = path
	_watch_cache_dirty = false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = bytes_to_var(f.get_buffer(f.get_length()))
	f.close()
	if data is Dictionary and int(data.get("version", 0)) == WATCH_CACHE_VERSION \
			and data.get("entries") is Dictionary and data.get("opened") is Dictionary \
			and data.get("seen") is Dictionary:
		_watch_cache = data.entries
		_watch_opened_prev = data.opened
		_watch_seen = data.seen


## Written through a temporary file and a rename, so a crash mid-write can't
## leave a cache that loads half a workspace.
func _save_watch_cache(force: bool) -> void:
	if not _watch_cache_dirty or _watch_cache_path_loaded.is_empty():
		return
	if not force and Time.get_ticks_msec() - _watch_cache_saved_msec < WATCH_SAVE_INTERVAL_MSEC:
		return
	var path := _watch_cache_path_loaded
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(var_to_bytes({"version": WATCH_CACHE_VERSION, "entries": _watch_cache,
			"opened": _watch_opened_prev, "seen": _watch_seen}))
	f.close()
	if DirAccess.rename_absolute(path + ".tmp", path) == OK:
		_watch_cache_dirty = false
		_watch_cache_saved_msec = Time.get_ticks_msec()


# ---------------------------------------------------------------------------
# Opened files whose disk state contradicts the open
# ---------------------------------------------------------------------------

## Every file opened in this workspace (`fstat -Ro`, whose clientFile is a
## local path), or null when the server didn't answer.
func _opened_records() -> Variant:
	var result := await _p4_exec(["-ztag", "fstat", "-Ro", _workspace_scope()])
	var recs := _parse_ztag(result)
	if recs.is_empty() and int(result.exit_code) != 0:
		var text := "" if result.output.is_empty() else String(result.output[0])
		# Nothing opened is an "error" to fstat.
		return [] if text.contains("not opened") else null
	return recs


## What to do about opened files whose disk state changed against the open:
## [{kind, local, change, type, source}]. `kind`: "add gone" (opened for add,
## file gone from disk), "move gone" (the new name of a move, gone; `source`
## is the old name's local path) or "delete back" (opened for delete, file
## back on disk). `exists` answers whether a local path is on disk; `seen`
## maps a path key to whether the file was on disk when last looked at.
##
## Only a change seen to happen counts, because every one of these states
## can also be deliberate (measured on p4d 2026.1): `p4 add` opens a file
## that doesn't exist ("missing, assuming text"), `move -k` renames an add
## without touching the disk, and `delete -k` keeps the file. Files opened
## for branch are never touched: `integrate -v` and `copy -v` open them
## without writing them.
static func _tidy_plan(records: Array, exists: Callable, seen: Dictionary) -> Array:
	var local_of := {}
	for rec: Dictionary in records:
		local_of[String(rec.get("depotFile", ""))] = String(rec.get("clientFile", ""))
	var plan: Array = []
	for rec: Dictionary in records:
		var action := String(rec.get("action", ""))
		var local := String(rec.get("clientFile", ""))
		if local.is_empty() or not seen.has(_path_key(local)):
			continue
		var was_there := bool(seen[_path_key(local)])
		var step := {"local": local, "change": String(rec.get("change", "default")),
				"type": String(rec.get("headType", rec.get("type", "")))}
		if action == "add" and was_there and not exists.call(local):
			step.kind = "add gone"
		elif action == "move/add" and was_there and not exists.call(local):
			step.kind = "move gone"
			step.source = String(local_of.get(String(rec.get("movedFile", "")), ""))
		elif action == "delete" and not was_there and exists.call(local):
			step.kind = "delete back"
		else:
			continue
		plan.append(step)
	return plan


## Whether a filetype leaves synced files writable (the +w modifier).
static func _type_is_writable(filetype: String) -> bool:
	return filetype.contains("+") and filetype.get_slice("+", 1).contains("w")


## What was on disk for each opened add, move/add and delete, as `seen` for
## the next _tidy_plan. A file the watcher had walked before it was opened
## counts as seen on disk, so an add made and deleted between two looks is
## still caught.
func _tidy_seen_now(records: Array, exists: Callable) -> Dictionary:
	var out := {}
	for rec: Dictionary in records:
		var action := String(rec.get("action", ""))
		var local := String(rec.get("clientFile", ""))
		if local.is_empty() or not action in ["add", "move/add", "delete"]:
			continue
		var key := _path_key(local)
		out[key] = bool(exists.call(local))
	return out


## The `seen` a plan is made against: what the last look recorded, plus, for
## a file opened since, whether the watcher's cache had it on disk.
func _tidy_seen_before(records: Array) -> Dictionary:
	var seen := _watch_seen.duplicate()
	for rec: Dictionary in records:
		var key := _path_key(String(rec.get("clientFile", "")))
		if not seen.has(key) and _watch_cache.has(key):
			seen[key] = int(_watch_cache[key][1]) != -1
	return seen


## Act on _tidy_plan. With `settle`, a change must still hold after
## WATCH_SETTLE_SEC - a program replacing a file can leave it briefly
## missing. Returns how many files it changed.
func _tidy_opened_files(records: Array, settle: bool) -> int:
	_load_watch_cache()
	var exists := func(p: String) -> bool: return FileAccess.file_exists(p)
	var seen := _tidy_seen_before(records)
	var plan := _tidy_plan(records, exists, seen)
	if not plan.is_empty() and settle:
		await get_tree().create_timer(WATCH_SETTLE_SEC).timeout
		if _shutting_down:
			return 0
		var again := {}
		for step: Dictionary in _tidy_plan(records, exists, seen):
			again[String(step.local)] = true
		plan = plan.filter(func(step: Dictionary) -> bool: return again.has(String(step.local)))
	_watch_seen = _tidy_seen_now(records, exists)
	_watch_cache_dirty = true
	if plan.is_empty():
		return 0
	var done := 0
	for step: Dictionary in plan:
		var local := String(step.local)
		var change := String(step.change)
		var shown := _tree_label(_local_key(local))
		var where := "the default changelist" if change == "default" else "changelist #%s" % change
		match String(step.kind):
			"add gone":
				if await _p4_ok(["revert", "-k", local]):
					_log("'%s' was deleted from disk, so it no longer belongs in %s - taken out." % [shown, where])
					done += 1
			"move gone":
				if not await _p4_ok(["revert", "-k", local]):
					continue
				done += 1
				var source := String(step.get("source", ""))
				if source.is_empty():
					_log("'%s' was deleted from disk, so its rename was taken out of %s." % [shown, where])
				elif FileAccess.file_exists(source):
					var verdict := await _reopen_if_changed(source, change)
					_log("'%s' is gone and '%s' is back, so the rename was taken out of %s%s." % [
							shown, _tree_label(_local_key(source)), where,
							" (the old name is checked out: it changed)" if verdict == "edit" else ""])
				else:
					await _p4_exec_logged(["delete", "-k", "-c", change, source])
					_log("'%s' was renamed in %s and then deleted from disk, so %s now deletes '%s'." % [
							shown, where, where, _tree_label(_local_key(source))])
			"delete back":
				if not await _p4_ok(["revert", "-k", local]):
					continue
				done += 1
				match await _reopen_if_changed(local, change):
					"edit":
						_log("'%s' was opened for delete but is back on disk, changed - checked out in %s instead." % [shown, where])
					"clean":
						await _make_read_only_if_due(local, String(step.type))
						_log("'%s' was opened for delete but is back on disk, unchanged - the delete was undone." % shown)
					_:
						# Not known whether it changed: leave it writable, so
						# nothing can overwrite it; the watcher lists it if so.
						_log(("'%s' was opened for delete but is back on disk; the delete was undone. " +
								"Perforce didn't say whether it changed - Reconcile will.") % shown)
	if done > 0:
		_forget_watch_entries(plan.map(func(step: Dictionary) -> String: return String(step.local)))
		_request_refresh()
	return done


## Run a p4 command that changes something; true when it exited 0.
func _p4_ok(args: PackedStringArray) -> bool:
	return int((await _p4_exec_logged(args)).exit_code) == 0


## `reconcile -e`: opens `local` for edit in `change` only if its content
## differs from the revision you have. Returns "edit" (opened), "clean"
## (Perforce said there was nothing to do) or "unknown" (anything else: the
## server didn't answer, or refused).
func _reopen_if_changed(local: String, change: String) -> String:
	var result := await _p4_exec_logged(["-ztag", "reconcile", "-e", "-c", change, local])
	for rec in _parse_ztag(result):
		if String(rec.get("action", "")) == "edit":
			return "edit"
	if int(result.exit_code) == 0 and _reconcile_had_nothing(result):
		return "clean"
	return "unknown"


## A file Perforce no longer has open goes back to read-only, as it would
## be after a sync - unless the workspace leaves files writable or its type
## does, or the workspace's setting couldn't be read. A writable unopened
## file in a read-only workspace stops later syncs ("Can't clobber writable
## file").
func _make_read_only_if_due(local: String, filetype: String) -> void:
	if _type_is_writable(filetype):
		return
	if _client_allwrite == null:
		await _read_client_options()
	if _client_allwrite == false:
		_set_file_writable(local, false)


func _forget_watch_entries(locals: Array) -> void:
	for local: String in locals:
		var key := _path_key(local)
		_watch_cache.erase(key)
		_watch_attempted.erase(key)
		_watch_refused.erase(key)
	_watch_cache_dirty = true


## Before a submit, without waiting for files to settle: the user is about
## to send exactly what is opened.
func _submit_changelist(change: String, files: Array, preset_desc: String = "") -> void:
	if await _ensure_identity():
		var records: Variant = await _opened_records()
		if records != null:
			await _tidy_opened_files(records, false)
	await super(change, files, preset_desc)


# ---------------------------------------------------------------------------
# allwrite
# ---------------------------------------------------------------------------

## The workspace's Options words, from its spec; empty when unreadable.
func _read_client_options() -> PackedStringArray:
	var recs := _parse_ztag(await _p4_exec(["-ztag", "client", "-o"]))
	if recs.is_empty() or not recs[0].has("Options"):
		return PackedStringArray()
	var words := String(recs[0].Options).split(" ", false)
	_client_allwrite = "allwrite" in words
	return words


func _workspace_is_allwrite() -> bool:
	if _client_allwrite == null:
		await _read_client_options()
	return _client_allwrite == true


## The spec's Options line, with a leading space so " word" matches whole
## words; "" when there is none.
static func _options_line(spec: String) -> String:
	for line in spec.split("\n"):
		if line.begins_with("Options:"):
			return " " + line.substr("Options:".length()).strip_edges().replace("\t", " ") + " "
	return ""


## The spec with its Options line's noallwrite/allwrite word set to `on`.
## Unchanged when there is no such word to flip.
static func _spec_with_allwrite(spec: String, on: bool) -> String:
	var lines := spec.split("\n")
	for i in lines.size():
		if not lines[i].begins_with("Options:"):
			continue
		var words := lines[i].substr("Options:".length()).strip_edges().split(" ", false)
		for j in words.size():
			if words[j] == "allwrite" or words[j] == "noallwrite":
				words[j] = "allwrite" if on else "noallwrite"
		lines[i] = "Options:\t" + " ".join(words)
	return "\n".join(lines)


## Offered once per project, when the workspace keeps files read-only.
func _offer_allwrite_once() -> void:
	if not await _ensure_identity() or _selftest_mode:
		return # Self-tests answer dialogs on their own; this one changes the workspace.
	var settings := EditorInterface.get_editor_settings()
	if settings.get_project_metadata(SETTINGS_SECTION, "allwrite_offered", false):
		return
	var words := await _read_client_options()
	if words.is_empty() or "allwrite" in words:
		return
	settings.set_project_metadata(SETTINGS_SECTION, "allwrite_offered", true)
	var yes: bool = await _show_confirm_dialog(("Your Perforce workspace keeps files read-only " +
			"until you check them out. Godot rewrites some files on its own - every .import " +
			"file when it reimports, and scenes when it re-saves them - and those writes fail " +
			"on read-only files.\n\nP4Godot can switch the workspace to leave files writable. " +
			"It then watches the workspace and checks out what you change, from Godot or any " +
			"other program, and Get Latest still never overwrites a file you changed.\n\nYou " +
			"can switch back at any time in the P4G panel's settings menu."),
			"Make Files Writable", "Not Now")
	if yes:
		await _switch_allwrite(true, false)


func _build_settings_menu(parent: Control) -> void:
	super(parent)
	var popup := settings_menu.get_popup()
	popup.add_separator()
	popup.add_check_item("Leave workspace files writable", SETTINGS_MENU_ALLWRITE)
	popup.set_item_tooltip(popup.get_item_index(SETTINGS_MENU_ALLWRITE),
			("Switch the Perforce workspace between leaving files writable (\"allwrite\") and " +
			"keeping them read-only until checked out."))


func _sync_settings_menu() -> void:
	super()
	var popup := settings_menu.get_popup()
	popup.set_item_checked(popup.get_item_index(SETTINGS_MENU_ALLWRITE), _client_allwrite == true)


func _on_settings_menu_id_pressed(id: int) -> void:
	if id == SETTINGS_MENU_ALLWRITE:
		settings_menu.get_popup().hide()
		var words := await _read_client_options()
		if words.is_empty():
			await _show_alert(("Godot couldn't read your workspace's settings from Perforce. " +
					"Press \"Log\" in the P4G panel to see what it said."))
			return
		await _switch_allwrite(not ("allwrite" in words), true)
		return
	super(id)


## Switch the workspace to leave files writable (`on`) or read-only, and set
## the files on disk to match. Files changed but not checked out stay
## writable, so nothing can overwrite them.
func _switch_allwrite(on: bool, confirm: bool) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	if confirm:
		var text := ("Leave the files in workspace '%s' writable?\n\nGodot and other programs can " +
				"then change any file, and P4Godot checks out what changed. Get Latest never " +
				"overwrites a file you changed.") % _p4_client if on else \
				("Make the files in workspace '%s' read-only until checked out?\n\nFiles you " +
				"changed but haven't checked out stay writable, so nothing overwrites them; the " +
				"P4G panel lists them.") % _p4_client
		if not await _show_confirm_dialog(text, "Leave Writable" if on else "Make Read-Only", "Cancel"):
			return
	var spec_result := await _p4_exec(["client", "-o"])
	var spec := "" if spec_result.output.is_empty() else String(spec_result.output[0])
	var new_spec := _spec_with_allwrite(spec, on)
	if int(spec_result.exit_code) != 0 or new_spec == spec:
		await _show_alert(("Godot couldn't change your workspace's settings. Press \"Log\" in " +
				"the P4G panel to see what Perforce said."))
		return
	var saved := await _p4_exec_spec(["client", "-i"], new_spec)
	var said := "" if saved.output.is_empty() else String(saved.output[0])
	if int(saved.exit_code) != 0 or not said.contains("saved"):
		await _show_alert("Perforce didn't change the workspace:\n\n%s" % said.strip_edges())
		return
	_client_allwrite = on
	_log("Workspace '%s' now %s." % [_p4_client,
			"leaves files writable (allwrite)" if on else "keeps files read-only until checked out (noallwrite)"])

	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", "-Rh", "-T",
			"clientFile,headType,action", _workspace_scope()]))
	var targets: Array = []
	# Going read-only: a file is locked only when it is known unchanged. The
	# cache vouches for a file whose time is the one Perforce confirmed;
	# Perforce is asked about every other one. A changed file left writable
	# is what keeps a plain sync from overwriting it.
	var unsure: Array = []
	if not on:
		_load_watch_cache()
	for rec: Dictionary in recs:
		var local := String(rec.get("clientFile", ""))
		if local.is_empty() or rec.has("action"):
			continue # Opened files keep the mode their checkout gave them.
		if on:
			targets.append(local)
			continue
		if _type_is_writable(String(rec.get("headType", ""))) or not FileAccess.file_exists(local):
			continue
		var entry: Variant = _watch_cache.get(_path_key(local))
		var mtime := int(FileAccess.get_modified_time(local))
		if entry != null and String(entry[3]).is_empty() and int(entry[1]) == mtime \
				and int(entry[2]) >= mtime + WATCH_SETTLE_SEC:
			targets.append(local)
		else:
			unsure.append(local)
	var kept := 0
	var unanswered := false
	if not unsure.is_empty():
		var verdicts: Variant = await _reconcile_preview_paths(unsure)
		if verdicts == null:
			unanswered = true
			kept = unsure.size()
		else:
			for local: String in unsure:
				if verdicts.has(_path_key(local)):
					kept += 1
				else:
					targets.append(local)
	var changed := await _set_modes(targets, on)
	_request_refresh()
	if not on:
		_external_scan_last_msec = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC
		_scan_for_external_changes("switched to read-only files") # lists what stayed writable
	var text := ("Done. %d file(s) are now %s." % [changed, "writable" if on else "read-only"])
	if unanswered:
		text += ("\n\nPerforce didn't answer while P4Godot checked which files you changed, so " +
				"%d file(s) were left writable to be safe. Switch again once the server is back.") % kept
	elif kept > 0:
		text += ("\n\n%d file(s) you changed without checking out stay writable; the P4G panel " +
				"lists them under \"Changed, not checked out\".") % kept
	if on and " clobber" in _options_line(new_spec):
		text += ("\n\nYour workspace also has the \"clobber\" option, which lets a plain Get Latest " +
				"in P4V overwrite writable files that aren't checked out - with writable files, " +
				"that means your unsubmitted changes. P4Godot's own Get Latest never does; to " +
				"be safe in P4V too, set the workspace to \"noclobber\" in P4V's workspace settings.")
	_log(text.replace("\n\n", " "))
	await _show_alert(text)


## Set many files writable or read-only on a thread; returns how many were
## set (files already that way, or gone, don't count).
func _set_modes(locals: Array, writable: bool) -> int:
	var counter := [0]
	if _modes_thread != null:
		return 0
	_modes_thread = Thread.new()
	_modes_thread.start(_set_modes_on_thread.bind(locals, writable, counter))
	while _modes_thread != null and _modes_thread.is_alive():
		await get_tree().process_frame
	if _modes_thread == null:
		return int(counter[0]) # Joined by _stop_watching: the editor is closing.
	_modes_thread.wait_to_finish()
	_modes_thread = null
	return int(counter[0])


static func _set_modes_on_thread(locals: Array, writable: bool, counter: Array) -> void:
	for local: String in locals:
		if not FileAccess.file_exists(local):
			continue
		if OS.get_name() == "Windows":
			if FileAccess.get_read_only_attribute(local) == (not writable):
				continue
			if FileAccess.set_read_only_attribute(local, not writable) == OK:
				counter[0] += 1
			continue
		var perms: int = FileAccess.get_unix_permissions(local)
		var now_writable := perms & FileAccess.UNIX_WRITE_OWNER != 0
		if now_writable == writable:
			continue
		if writable:
			perms |= FileAccess.UNIX_WRITE_OWNER
		else:
			perms &= ~(FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_WRITE_GROUP | FileAccess.UNIX_WRITE_OTHER)
		if FileAccess.set_unix_permissions(local, perms) == OK:
			counter[0] += 1


# ---------------------------------------------------------------------------
# The dock's "Changed, not checked out" group
# ---------------------------------------------------------------------------

func _rebuild_tree(model: Dictionary) -> void:
	super(model)
	if tree == null or not model.get("available", false):
		return
	var opened := {}
	for cl in model.get("changelists", []):
		for f in cl.files:
			opened[_path_key(ProjectSettings.globalize_path(String(f.res_path)))] = true
	var rows: Array = _watch_detected.filter(func(r: Dictionary) -> bool: return not opened.has(r.key))
	if rows.is_empty():
		return
	var group := tree.create_item(tree.get_root(), 0)
	group.set_text(0, "Changed, not checked out")
	group.set_text(1, "%d file%s" % [rows.size(), "" if rows.size() == 1 else "s"])
	group.set_custom_color(1, _dim_color())
	group.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
	group.set_selectable(1, false)
	group.set_tooltip_text(0, ("Files changed on disk that Perforce doesn't know about yet. " +
			"Right-click a file to check it out, or this row to open them all."))
	var bold := _editor_bold_font()
	if bold:
		group.set_custom_font(0, bold)
	var icon := _theme_icon("StatusWarning")
	if icon:
		group.set_icon(0, icon)
	group.set_metadata(0, {"type": "detected_group"})
	for row: Dictionary in rows:
		var key := _local_key(String(row.local))
		var item := tree.create_item(group)
		var refused := String(_watch_refused.get(row.key, ""))
		item.set_text(0, _tree_label(key) + ("  (locked)" if not refused.is_empty() else ""))
		var tip := "%s\nChanged on disk, not checked out. Right-click to %s." % [row.local,
				_detected_verb(String(row.action)).to_lower()]
		if not refused.is_empty():
			tip += "\nPerforce refused to open it: %s" % refused
			item.set_custom_color(0, ACTION_DELETE_COLOR)
		item.set_tooltip_text(0, tip)
		item.set_text(1, String(row.action))
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(1, _action_color(String(row.action)))
		item.set_selectable(1, false)
		var file_icon := _file_icon(key)
		if file_icon:
			item.set_icon(0, file_icon)
		item.set_metadata(0, {"type": "detected", "res_path": key, "local": String(row.local),
				"action": String(row.action)})


static func _detected_verb(action: String) -> String:
	match action:
		"add": return "Mark for Add"
		"delete": return "Mark for Delete"
	return "Check Out"


func _populate_context_menu(meta: Dictionary) -> void:
	var kind := String(meta.get("type", ""))
	if kind != "detected" and kind != "detected_group":
		super(meta)
		return
	context_menu.clear()
	move_submenu.clear()
	_move_targets.clear()
	if kind == "detected":
		var action := String(meta.get("action", ""))
		context_menu.add_item(_detected_verb(action), CTX_DETECTED_OPEN)
		if action != "delete":
			var in_project := String(meta.get("res_path", "")).begins_with("res://")
			context_menu.add_item("Open" if in_project else "Show in File Manager", CTX_DETECTED_SHOW)
		if action == "edit":
			context_menu.add_item("Diff vs Depot", CTX_DETECTED_DIFF)
		if action != "add":
			context_menu.add_item("History...", CTX_DETECTED_HISTORY)
	else:
		context_menu.add_item("Open All in Perforce", CTX_DETECTED_OPEN_ALL)
	context_menu.add_separator()
	context_menu.add_item("Refresh", CTX_REFRESH)


func _on_context_menu_id_pressed(id: int) -> void:
	var meta := _context_target
	match id:
		CTX_DETECTED_OPEN:
			await _open_detected_rows(_watch_detected.filter(
					func(r: Dictionary) -> bool: return r.local == String(meta.get("local", ""))))
		CTX_DETECTED_OPEN_ALL:
			await _open_detected_rows(_watch_detected.duplicate())
		CTX_DETECTED_DIFF:
			await _diff_path(String(meta.get("res_path", "")))
		CTX_DETECTED_SHOW:
			_open_res_path(String(meta.get("res_path", "")))
		CTX_DETECTED_HISTORY:
			await _show_history(String(meta.get("res_path", "")))
		_:
			await super(id)


func _on_tree_item_activated() -> void:
	var item := tree.get_selected()
	var meta: Variant = null if item == null else item.get_metadata(0)
	if meta is Dictionary and meta.get("type") == "detected":
		if String(meta.action) == "edit":
			await _diff_path(String(meta.res_path))
		elif String(meta.action) == "add":
			_open_res_path(String(meta.res_path))
		return
	super()


## The user asked: open them, and say plainly if Perforce refuses.
func _open_detected_rows(rows: Array) -> void:
	if rows.is_empty():
		return
	for row: Dictionary in rows:
		_watch_attempted.erase(row.key)
		_watch_refused.erase(row.key)
	await _open_detected(rows)
	var records: Variant = await _opened_records()
	if records == null:
		return
	var opened := {}
	for rec: Dictionary in records:
		opened[_path_key(String(rec.get("clientFile", "")))] = true
	_set_watch_detected(_watch_detected_rows(opened))
