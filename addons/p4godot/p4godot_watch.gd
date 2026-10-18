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
##   reconciled. Edits, new files, deleted files and moves are opened in
##   Perforce automatically; a setting lists them in the dock under "Changed,
##   not checked out" instead. Folders the workspace doesn't map, and folders
##   the ignore rules leave out with nothing tracked in them, aren't walked.
## - A teammate's lock that stops an automatic checkout is reported at once,
##   with the choice to revert the change or keep it until the lock goes.
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
const WATCH_CACHE_VERSION := 3
## A folder left out of the walk is asked about again this often, so a
## changed client view brings it back.
const WATCH_PRUNE_RECHECK_SEC := 600
## The made-up file name `add -n` is asked about to learn whether a folder is
## ignored or unmapped. No extension, so a rule like "*.tmp" can't match it.
const WATCH_PROBE_NAME := "__p4godot_folder_probe__"
## More new and deleted files than this at once - a first look at a workspace
## full of untracked files, or a folder deleted by mistake - are asked about
## before anything is opened.
const WATCH_BULK_ASK := 20
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
const CTX_DETECTED_REVERT := 905
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
# Key -> the pass (_watch_generation) that first found the file deleted. A
# delete is opened on a later pass only.
var _watch_delete_first: Dictionary = {}
# Keys whose refusal the user has been asked about this session.
var _watch_alerted: Dictionary = {}
# Whether the revert-or-keep question is on screen.
var _watch_asking: bool = false
# Folder key -> [verdict, unix time asked]: "" walked, "ignored" or
# "unmapped" skipped. Saved with the cache.
var _watch_dirs: Dictionary = {}
# The ignore files' names and times when _watch_dirs' "ignored" verdicts were
# made; they are asked about again when it changes. Saved with the cache.
var _watch_ignore_stamp: String = ""
# Where those ignore files are, so an edit to one is noticed before the walk
# skips the folders it decided about. Saved with the cache.
var _watch_ignore_files: Array = []
# P4IGNORE's file names, lower case; null until read.
var _watch_ignore_names: Variant = null
# P4IGNORE's entries that are full paths.
var _watch_ignore_fixed: Array = []
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
	_watch_delete_first = {}
	_watch_asking = false
	_watch_seen = {}
	_watch_dirs = {}
	_watch_ignore_stamp = ""
	_watch_ignore_files = []
	_watch_ignore_names = null
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
	_load_watch_cache()
	_forget_ignored_if_rules_changed()
	var skip := _pruned_dirs(int(Time.get_unix_time_from_system()))
	var dirs: Array = []
	var started := Time.get_ticks_msec()
	var walked: Dictionary = await _walk_workspace(root, skip, dirs)
	if _watch_gone(epoch):
		return
	var walk_sec := (Time.get_ticks_msec() - started) / 1000.0
	if walked.is_empty() and not DirAccess.dir_exists_absolute(root):
		return
	if walked.size() >= WATCH_MAX_FILES:
		_log(("The workspace has more than %d files; P4Godot watches only the first %d it " +
				"finds. Narrow the workspace view or ignore large folders.") % [WATCH_MAX_FILES, WATCH_MAX_FILES])

	await _classify_dirs(dirs, walked)
	if _watch_gone(epoch):
		return
	_drop_pruned(walked)
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


## `reconcile -n -M` on exactly these paths, in chunks. Returns key ->
## action ("edit", "add", "delete", "move/add", "move/delete") for each file
## Perforce would open, or null when the server didn't answer (so nothing is
## recorded as checked). -M pairs a deleted file with a new one of the same
## content as a move, when both are in one chunk.
func _reconcile_preview_paths(paths: Array) -> Variant:
	var verdicts := {}
	for chunk: Array in _path_chunks(paths, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["-ztag", "reconcile", "-n", "-M"]
		for p: String in chunk:
			args.append(p)
		var result := await _p4_exec(args)
		if _shutting_down:
			return null
		var recs := _parse_ztag(result)
		var refused := _preview_refusals(_refusals(result).lines)
		if recs.is_empty() and refused.is_empty() and int(result.exit_code) != 0 \
				and not _reconcile_had_nothing(result):
			return null
		# A file Perforce won't open (a teammate's exclusive lock) gets no
		# record, only a refusal naming its depot path - measured on 2026.1.
		# It is still changed, and has to be reported as such.
		if not refused.is_empty():
			var local_of := await _locals_of_depots(refused.keys())
			for depot: String in refused:
				if local_of.has(depot.to_lower()):
					verdicts[_path_key(String(local_of[depot.to_lower()]))] = String(refused[depot])
		for rec in recs:
			var local := String(rec.get("clientFile", ""))
			var action := String(rec.get("action", ""))
			if local.is_empty() or action.is_empty():
				continue
			# A move is reported as a delete and an add first, then paired:
			# the last record for a file is the one that counts.
			verdicts[_path_key(local)] = action
	return verdicts


## Depot path, as p4 spelled it -> what reconcile wanted to open it for,
## from its refusal lines ("//d/f - can't edit exclusive file already
## opened"). The spelling is kept for `where`: a case-sensitive server
## doesn't find a lower-cased path.
static func _preview_refusals(lines: Array) -> Dictionary:
	var out := {}
	for line: String in lines:
		for pair in [["can't edit", "edit"], ["can't delete", "delete"], ["can't add", "add"]]:
			var at := line.find(" - " + String(pair[0]))
			if at > 0 and line.begins_with("//"):
				out[line.substr(0, at)] = String(pair[1])
	return out


## Depot paths -> local paths in this workspace, via `where`; keyed by the
## depot path in lower case.
func _locals_of_depots(depots: Array) -> Dictionary:
	var out := {}
	for chunk: Array in _path_chunks(depots, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["-ztag", "where"]
		args.append_array(PackedStringArray(chunk))
		for w in _parse_ztag(await _p4_exec(args)):
			if w.has("path") and w.has("depotFile"):
				out[String(w.depotFile).to_lower()] = String(w.path)
	return out


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
	var automatic := auto_checkout_detected_checkbox != null and auto_checkout_detected_checkbox.button_pressed
	var held_delete := false
	for row: Dictionary in detected:
		# A change kept after a refusal is tried on every pass, so it is
		# checked out as soon as the teammate's lock goes.
		var kept := _watch_refused.has(row.key)
		if not kept and _watch_attempted.has(row.key) \
				and int(_watch_attempted[row.key]) == int(row.mtime):
			continue
		if not (automatic or kept):
			continue
		# A delete waits for the next look: a file being replaced, or a sync
		# that is still writing, can be briefly missing. By then the walk
		# has seen it again if it came back. It also lets a rename's new
		# name settle, so the two pair up as a move.
		if String(row.action).ends_with("delete"):
			if int(_watch_delete_first.get(row.key, _watch_generation)) == _watch_generation:
				_watch_delete_first[row.key] = _watch_generation
				held_delete = true
				continue
		to_open.append(row)
	# Forget first sightings of files no longer listed as deleted.
	var deleted_now := {}
	for row: Dictionary in detected:
		if String(row.action).ends_with("delete"):
			deleted_now[row.key] = true
	for key: String in _watch_delete_first.keys():
		if not deleted_now.has(key):
			_watch_delete_first.erase(key)
	if held_delete:
		# New files wait with it: one may be the deleted file's new name.
		to_open = to_open.filter(func(r: Dictionary) -> bool:
			return String(r.action) == "edit" or _watch_refused.has(r.key))
	var bulk: Array = to_open.filter(func(r: Dictionary) -> bool:
		return String(r.action) != "edit" and not _watch_refused.has(r.key))
	if bulk.size() > WATCH_BULK_ASK:
		to_open = to_open.filter(func(r: Dictionary) -> bool: return not bulk.has(r))
		for row: Dictionary in bulk:
			_watch_attempted[row.key] = row.mtime
		_ask_about_bulk(bulk) # not awaited: a pass mustn't wait on a dialog
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
				"checked": int(entry[2]), "action": String(entry[3])})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.local) < String(b.local))
	return rows


func _set_watch_detected(rows: Array) -> void:
	var before := _watch_detected.map(func(r: Dictionary) -> String: return "%s:%s" % [r.key, r.action])
	var after := rows.map(func(r: Dictionary) -> String: return "%s:%s" % [r.key, r.action])
	_watch_detected = rows
	# A file no longer listed has had its refusal settled; a later one is
	# asked about afresh.
	var listed := {}
	for row: Dictionary in rows:
		listed[row.key] = true
	for key: String in _watch_alerted.keys():
		if not listed.has(key):
			_watch_alerted.erase(key)
	if before != after:
		_request_refresh()


## `reconcile -e -a -d -M` the rows' files, which opens each one for what it
## needs (edit, add, delete, or a move when a delete and an add pair up).
## Remembers each attempt, so a refusal isn't retried until the file changes
## again - unless the user chose to keep the change, see _act_on_detected.
## A refusal is put to the user once per file per session, without making
## the pass wait for the answer. Returns the keys opened afterwards, or null
## if unknown.
func _open_detected(rows: Array) -> Variant:
	var epoch := _watch_epoch
	# Moves first, so a pair lands in one command and -M can match it.
	var ordered := rows.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.action) != "edit" and String(b.action) == "edit")
	var locals: Array = ordered.map(func(r: Dictionary) -> String: return String(r.local))
	var lines: Array = []
	for chunk: Array in _path_chunks(locals, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["reconcile", "-e", "-a", "-d", "-M"]
		for p: String in chunk:
			args.append(p)
		lines.append_array(_refusals(await _p4_exec_logged(args)).lines)
		if _watch_gone(epoch):
			return null
	var records: Variant = await _opened_records()
	if records == null or _watch_gone(epoch):
		return null
	var opened := {}
	for rec: Dictionary in records:
		opened[_path_key(String(rec.get("clientFile", "")))] = true
	var refused_rows: Array = rows.filter(func(r: Dictionary) -> bool: return not opened.has(r.key))
	# p4 names a refused file by its depot path.
	var depot_of := {}
	if not refused_rows.is_empty():
		var local_of := await _locals_of_depots(_preview_refusals(lines).keys())
		if _watch_gone(epoch):
			return null
		for depot: String in local_of:
			depot_of[_path_key(String(local_of[depot]))] = depot
	var to_ask: Array = []
	var unexplained: Array = []
	for row: Dictionary in rows:
		_watch_attempted[row.key] = row.mtime
		if opened.has(row.key):
			if _watch_refused.has(row.key):
				_watch_refused.erase(row.key)
				_log("'%s' is checked out now - Perforce let it go." % _tree_label(_local_key(String(row.local))))
			continue
		if not depot_of.has(row.key):
			# Not opened, and Perforce didn't refuse it by name: the verdict
			# was stale (an ignore rule, a teammate's delete synced) or the
			# command failed. Looked at again, not asked about.
			unexplained.append(String(row.local))
			_watch_refused.erase(row.key)
			continue
		_watch_refused[row.key] = _refusal_reason(lines, String(row.key), String(depot_of[row.key]))
		if not _watch_alerted.has(row.key):
			to_ask.append(row)
	if not unexplained.is_empty():
		for local: String in unexplained:
			_watch_cache.erase(_path_key(local))
		_watch_cache_dirty = true
	_request_refresh()
	if not to_ask.is_empty():
		_log("Perforce refused %d of the %d changed file(s)." % [refused_rows.size(), rows.size()])
		_ask_about_refused(to_ask) # not awaited: a pass mustn't wait on a dialog
	return opened


## Why Perforce refused a file, from `reconcile`'s refusal lines: "locked by
## <user@workspace>" when the file is exclusive and someone has it.
static func _refusal_reason(lines: Array, key: String, depot: String) -> String:
	var reason := ""
	for line: String in lines:
		var l := _path_key(line)
		if not (l.contains(key) or (not depot.is_empty() and l.contains(depot))):
			continue
		var at := l.find("also opened by ")
		if at >= 0:
			return "locked by " + line.substr(at + "also opened by ".length()).strip_edges()
		if reason.is_empty():
			reason = line.strip_edges()
	return reason if not reason.is_empty() else "Perforce didn't open it; the Log says why."


## How to undo a change on disk with `p4 clean`, by what reconcile would
## open the file for; "" when there is nothing to put back (a new file).
static func _clean_flag(action: String) -> String:
	match action:
		"edit": return "-e"
		"delete", "move/delete": return "-d"
	return ""


## Ask about changes Perforce wouldn't check out: put back the version the
## user had, or keep the change and let P4Godot check it out once Perforce
## allows it. Asked when the change is found - in a read-only workspace
## that is the moment checking out would have refused the edit.
func _ask_about_refused(rows: Array) -> void:
	if _watch_asking or _shutting_down:
		return # Asked on a later pass, which tries these files again.
	_watch_asking = true
	var epoch := _watch_epoch
	for row: Dictionary in rows:
		_watch_alerted[row.key] = true
	var listing: Array = rows.map(func(r: Dictionary) -> String:
		return "%s - %s" % [_tree_label(_local_key(String(r.local))), _watch_refused.get(r.key, "")])
	var revertable: Array = rows.filter(func(r: Dictionary) -> bool: return not _clean_flag(String(r.action)).is_empty())
	var text := ("Perforce wouldn't check out %s you changed:\n\n%s\n\nUsually that means a " +
			"teammate has it checked out exclusively: only one person can change such a file at a " +
			"time. Your change can't be submitted until they submit or revert theirs, and if " +
			"they submit, yours has to be redone on top of their version.") % [
			"this file" if rows.size() == 1 else "these files", _file_listing(listing)]
	if revertable.is_empty():
		await _show_alert(text + ("\n\nP4Godot keeps trying, and checks it out as soon as " +
				"Perforce allows."))
		_watch_asking = false
		return
	var revert: bool = await _show_confirm_dialog(text + ("\n\nRevert puts back the version " +
			"you had - your change is lost. Keep leaves it on your computer, listed in the P4G " +
			"panel under \"Changed, not checked out\", and P4Godot checks it out as soon as " +
			"Perforce allows."),
			"Revert My Change" if revertable.size() == 1 else "Revert My Changes",
			"Keep It" if rows.size() == 1 else "Keep Them")
	if epoch != _watch_epoch:
		return # The workspace changed while the question was up.
	if revert:
		await _revert_detected(revertable)
	else:
		_log("Kept %d change(s) Perforce wouldn't check out; trying again on each look." % rows.size())
	_watch_asking = false


## Many new or deleted files at once: one question before opening them.
## They stay listed under "Changed, not checked out" either way.
func _ask_about_bulk(rows: Array) -> void:
	if _watch_asking or _shutting_down:
		return
	_watch_asking = true
	var epoch := _watch_epoch
	var adds := rows.filter(func(r: Dictionary) -> bool: return String(r.action).ends_with("add")).size()
	var deletes := rows.size() - adds
	var names: Array = rows.map(func(r: Dictionary) -> String:
		return "%s  (%s)" % [_tree_label(_local_key(String(r.local))), r.action])
	var yes: bool = await _show_confirm_dialog(("P4Godot found %d new and %d deleted files in your " +
			"workspace at once:\n\n%s\n\nThat many usually means a first look at a workspace " +
			"with files Perforce doesn't have yet (build output, say), or a folder deleted by " +
			"mistake. Open them all in Perforce now?\n\nEither way they're listed in the P4G " +
			"panel under \"Changed, not checked out\". Files that shouldn't be in Perforce " +
			"belong in your ignore file (.p4ignore).") % [adds, deletes, _file_listing(names)],
			"Open Them in Perforce", "Not Now")
	if epoch == _watch_epoch:
		if yes:
			await _open_detected_rows(rows)
		_watch_asking = false


## Put back the version the user had for each row (`p4 clean`), reloading
## any that are open in the editor.
func _revert_detected(rows: Array) -> void:
	var epoch := _watch_epoch
	# Only what is still as it was when listed: not checked out meanwhile, and
	# not changed again (that would be a newer change than the one asked about).
	var records: Variant = await _opened_records()
	if records == null or epoch != _watch_epoch:
		return
	var opened := {}
	for rec: Dictionary in records:
		opened[_path_key(String(rec.get("clientFile", "")))] = true
	var done: Array = []
	for row: Dictionary in rows:
		var flag := _clean_flag(String(row.action))
		var local := String(row.local)
		var same: bool = (not FileAccess.file_exists(local)) if flag == "-d" \
				else FileAccess.get_modified_time(local) == int(row.mtime)
		if flag.is_empty() or opened.has(row.key) or not same:
			continue
		if epoch != _watch_epoch:
			return
		if await _p4_ok(["clean", flag, local]):
			done.append(local)
			var key := _local_key(local)
			if key.begins_with("res://") and _is_open_in_editor(key):
				await _reload_path(key)
	if done.is_empty():
		return
	_forget_watch_entries(done)
	var gone := {}
	for local: String in done:
		gone[_path_key(local)] = true
	_set_watch_detected(_watch_detected.filter(func(r: Dictionary) -> bool: return not gone.has(r.key)))
	EditorInterface.get_resource_filesystem().scan()
	_log("Put back the version you had of %d file(s)." % done.size())


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


## Every file under `root` with its modification time, read on a thread,
## leaving out the folders in `skip` (keys). `dirs` gets every folder walked.
func _walk_workspace(root: String, skip: Dictionary, dirs: Array) -> Dictionary:
	var out := {}
	if _watch_thread != null:
		return out
	_watch_thread = Thread.new()
	_watch_abort = [false]
	_watch_thread.start(_walk_tree.bind(root, out, WATCH_MAX_FILES, _watch_abort, skip, dirs))
	while _watch_thread != null and _watch_thread.is_alive():
		await get_tree().process_frame
	if _watch_thread == null:
		return {} # Stopped while walking (the plugin is shutting down).
	_watch_thread.wait_to_finish()
	_watch_thread = null
	return out


## Runs on the walk thread: touches nothing but its arguments.
static func _walk_tree(root: String, out: Dictionary, cap: int, abort: Array, skip: Dictionary,
		dirs: Array) -> void:
	var stack: Array[String] = [root]
	while not stack.is_empty() and not abort[0]:
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		d.include_hidden = true
		for f in d.get_files():
			var p := dir + "/" + f
			if _is_godot_save_leftover(p):
				continue
			out[_path_key(p)] = [p, FileAccess.get_modified_time(p)]
			if out.size() >= cap:
				return
		for sub in d.get_directories():
			# Linked folders can loop back on themselves.
			if sub in WATCH_SKIP_DIRS or d.is_link(sub):
				continue
			var child := dir + "/" + sub
			if skip.has(_path_key(child)):
				continue
			dirs.append(child)
			stack.append(child)


## Folders the walk leaves out: unmapped, or ignored with nothing tracked in
## them. One whose verdict is older than WATCH_PRUNE_RECHECK_SEC is forgotten
## here, so this pass walks it and asks about it again.
func _pruned_dirs(now: int) -> Dictionary:
	var out := {}
	for key: String in _watch_dirs.keys():
		var verdict: Array = _watch_dirs[key]
		if String(verdict[0]).is_empty():
			continue
		if int(verdict[1]) < now - WATCH_PRUNE_RECHECK_SEC:
			_watch_dirs.erase(key)
			continue
		out[key] = true
	return out


static func _under_any(key: String, dir_keys: Array) -> bool:
	for d: String in dir_keys:
		if key.begins_with(d + "/"):
			return true
	return false


## Learn which of the newly walked folders to leave out from now on, top
## down, so a folder under one just left out isn't asked about. Measured on
## p4d 2026.1: `add -n` of a made-up file answers "ignored file can't be
## added" in an ignored folder and "file(s) not in client view" in an
## unmapped one; and an edit to a tracked file inside an ignored folder is
## still reported, which is why such a folder is kept.
func _classify_dirs(dirs: Array, walked: Dictionary) -> void:
	var ignore := await _ignore_files_state(walked)
	if String(ignore.stamp) != _watch_ignore_stamp:
		# The rules changed: what they decided before - left out or not - no
		# longer holds.
		_watch_dirs = {}
		_watch_ignore_stamp = String(ignore.stamp)
		_watch_cache_dirty = true
	var by_depth := {}
	for d: String in dirs:
		if _watch_dirs.has(_path_key(d)):
			continue
		var depth := d.count("/")
		if not by_depth.has(depth):
			by_depth[depth] = []
		by_depth[depth].append(d)
	if by_depth.is_empty():
		return
	var depths: Array = by_depth.keys()
	depths.sort()
	var now := int(Time.get_unix_time_from_system())
	var newly: Array = []
	for depth: int in depths:
		var batch: Array = (by_depth[depth] as Array).filter(
				func(d: String) -> bool: return not _under_any(_path_key(d), newly))
		if batch.is_empty():
			continue
		var verdicts: Variant = await _probe_dirs(batch)
		if verdicts == null or _shutting_down:
			return # Not answered: asked again next pass.
		for d: String in batch:
			var key := _path_key(d)
			var verdict := String(verdicts.get(key, ""))
			# A "!" rule can bring single files back into an ignored folder,
			# which a made-up file name can't detect: then nothing is left out
			# for being ignored.
			if verdict == "ignored" and (bool(ignore.negations) or await _has_tracked_files(d)):
				verdict = ""
			_watch_dirs[key] = [verdict, now]
			if not verdict.is_empty():
				newly.append(key)
	_watch_cache_dirty = true
	if not newly.is_empty():
		_log("Not watching %d folder(s) that the workspace leaves out or ignores: %s" % [newly.size(),
				", ".join(newly.slice(0, 5).map(func(k: String) -> String: return _tree_label(_local_key(k))))
				+ ("" if newly.size() <= 5 else ", ...")])


## `add -n` of a made-up file in each folder. Returns folder key -> "ignored"
## or "unmapped" for those left out (others are absent), or null when p4
## didn't answer.
##
## Two made-up files per folder, one in it and one a level below, must agree:
## a rule like "Build/*" ignores only a folder's own files, and a view can
## map one subfolder of a folder it otherwise leaves out. An "unmapped"
## answer is also checked with `where <folder>/...`, which names any
## mapping under the folder (measured on 2026.1).
func _probe_dirs(batch: Array) -> Variant:
	var read_any := {}
	var answered := false
	var probes: Array = []
	for d: String in batch:
		probes.append(d + "/" + WATCH_PROBE_NAME)
		probes.append(d + "/" + WATCH_PROBE_NAME + "/" + WATCH_PROBE_NAME)
	for chunk: Array in _path_chunks(probes, WATCH_CHUNK_CHARS):
		var args: PackedStringArray = ["add", "-n"]
		args.append_array(PackedStringArray(chunk))
		var result := await _p4_exec(args)
		if _server_unreachable():
			return null
		var text := "" if result.output.is_empty() else String(result.output[0])
		var read := _probe_verdicts_in(text)
		read_any.merge(read.verdicts)
		answered = answered or not text.strip_edges().is_empty()
	if not answered:
		return null
	var verdicts := {}
	for d: String in batch:
		var key := _path_key(d)
		var verdict := String(read_any.get(key, ""))
		if verdict.is_empty() or String(read_any.get(key + "/" + WATCH_PROBE_NAME.to_lower(), "")) != verdict:
			continue
		if verdict == "unmapped":
			var where := await _p4_exec(["-ztag", "where", d + "/..."])
			if _parse_ztag(where).any(func(w: Dictionary) -> bool: return w.has("path")) \
					or _server_unreachable():
				continue # Something under it is mapped (or no answer): walk it.
		verdicts[key] = verdict
	return verdicts


## Read `add -n`'s answer about probe files: {verdicts: folder key ->
## "ignored" / "unmapped", answered: whether p4 said anything about them}.
static func _probe_verdicts_in(text: String) -> Dictionary:
	var verdicts := {}
	var answered := false
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		var verdict := ""
		var at := line.find(" - ignored file can't be added")
		if at >= 0:
			verdict = "ignored"
		else:
			at = line.find(" - file(s) not in client view")
			if at >= 0:
				verdict = "unmapped"
		if verdict.is_empty():
			answered = answered or line.contains(" - opened for add")
			continue
		answered = true
		verdicts[_path_key(line.substr(0, at).replace("\\", "/").get_base_dir())] = verdict
	return {"verdicts": verdicts, "answered": answered}


## Whether Perforce has files under a folder in this workspace. Unknown (no
## answer) counts as yes, so a folder is never left out on a guess.
func _has_tracked_files(dir: String) -> bool:
	var result := await _p4_exec(["-ztag", "fstat", "-m1", "-Rh", "-T", "depotFile", dir + "/..."])
	if not _parse_ztag(result).is_empty():
		return true
	var text := "" if result.output.is_empty() else String(result.output[0])
	return not text.contains("no such file")


## The ignore files the walk found (by P4IGNORE's names): {stamp, negations}.
## `stamp` changes when one is added, removed or edited; `negations` is
## whether any has a "!" rule.
func _ignore_files_state(walked: Dictionary) -> Dictionary:
	if _watch_ignore_names == null:
		var result := await _p4_exec(["set", "-q", "P4IGNORE"])
		var text := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		var names: Array = []
		var fixed: Array = []
		if text.contains("="):
			for part in text.get_slice("=", 1).replace(",", ";").split(";", false):
				var entry := part.strip_edges().replace("\\", "/")
				# A full path names one file wherever it is, maybe outside
				# the workspace; a bare name means that name in any folder.
				if _is_local_path(entry):
					fixed.append(entry)
				else:
					names.append(entry.get_file().to_lower())
		_watch_ignore_names = names
		_watch_ignore_fixed = fixed
	var parts := PackedStringArray()
	var negations := false
	_watch_ignore_files = []
	var found: Array = []
	if not (_watch_ignore_names as Array).is_empty():
		for key: String in walked:
			if key.get_file() in _watch_ignore_names:
				found.append(String(walked[key][0]))
	for path: String in _watch_ignore_fixed:
		if FileAccess.file_exists(path):
			found.append(path)
	for path: String in found:
		_watch_ignore_files.append(path)
		parts.append("%s:%d" % [_path_key(path), FileAccess.get_modified_time(path)])
		for line in FileAccess.get_file_as_string(path).split("\n"):
			if line.strip_edges().begins_with("!"):
				negations = true
	parts.sort()
	return {"stamp": "|".join(parts), "negations": negations}


## Before the walk: if an ignore file found last time was edited or removed,
## forget the folders it left out, so this walk goes into them again. (A new
## ignore file is only found by the walk itself; _classify_dirs handles it.)
func _forget_ignored_if_rules_changed() -> void:
	if _watch_ignore_files.is_empty():
		return
	var parts := PackedStringArray()
	for path: String in _watch_ignore_files:
		if FileAccess.file_exists(path):
			parts.append("%s:%d" % [_path_key(path), FileAccess.get_modified_time(path)])
	parts.sort()
	if "|".join(parts) == _watch_ignore_stamp:
		return
	_watch_dirs = {}
	_watch_cache_dirty = true


## Drop what is under a left-out folder from this pass and from the cache.
func _drop_pruned(walked: Dictionary) -> void:
	var pruned: Array = []
	for key: String in _watch_dirs:
		if not String(_watch_dirs[key][0]).is_empty():
			pruned.append(key)
	if pruned.is_empty():
		return
	for key: String in walked.keys():
		if _under_any(key, pruned):
			walked.erase(key)
	for key: String in _watch_cache.keys():
		if _under_any(key, pruned):
			_watch_cache.erase(key)
			_watch_cache_dirty = true


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
	_watch_dirs = {}
	_watch_ignore_stamp = ""
	_watch_ignore_files = []
	_watch_cache_path_loaded = path
	_watch_cache_dirty = false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = bytes_to_var(f.get_buffer(f.get_length()))
	f.close()
	if data is Dictionary and int(data.get("version", 0)) == WATCH_CACHE_VERSION \
			and data.get("entries") is Dictionary and data.get("opened") is Dictionary \
			and data.get("seen") is Dictionary and data.get("dirs") is Dictionary:
		_watch_cache = data.entries
		_watch_opened_prev = data.opened
		_watch_seen = data.seen
		_watch_dirs = data.dirs
		_watch_ignore_stamp = String(data.get("ignore_stamp", ""))
		_watch_ignore_files = data.get("ignore_files", []) as Array


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
			"opened": _watch_opened_prev, "seen": _watch_seen, "dirs": _watch_dirs,
			"ignore_stamp": _watch_ignore_stamp, "ignore_files": _watch_ignore_files}))
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


## Offered at startup and when connection setup connects a workspace, if the
## workspace keeps files read-only - once per workspace: "Not Now" is
## remembered for that server and workspace, so reconnecting doesn't ask
## again, but picking another workspace does.
func _offer_allwrite_once() -> void:
	if not await _ensure_identity() or _selftest_mode:
		return # Self-tests answer dialogs on their own; this one changes the workspace.
	await _offer_allwrite_inner()
	await _offer_project_godot_writable()


func _offer_allwrite_inner() -> void:
	var settings := EditorInterface.get_editor_settings()
	var asked: Array = settings.get_project_metadata(SETTINGS_SECTION, "allwrite_asked", [])
	var which := "%s|%s" % [_p4_port, _p4_client]
	if which in asked:
		return
	# Recorded before anything is awaited, so the startup call and the
	# connection-setup call can't both get past this and ask twice.
	asked.append(which)
	settings.set_project_metadata(SETTINGS_SECTION, "allwrite_asked", asked)
	var epoch := _watch_epoch
	var words := await _read_client_options()
	if words.is_empty() or "allwrite" in words or epoch != _watch_epoch:
		return
	var yes := await _show_allwrite_offer()
	if yes and epoch == _watch_epoch:
		await _switch_allwrite(true, false)


## Godot 4.7's editor writes project.godot every time it starts with a
## window, changed or not - measured: a read-only project.godot failed to
## write on every windowed start, with this plugin enabled and without it -
## and shows "Load Errors" when it can't. In a workspace that keeps files
## read-only, the fix is the always-writable filetype, which the whole team
## gets once it's submitted. Offered once per project.
func _offer_project_godot_writable() -> void:
	if _client_allwrite == true or _selftest_mode or _shutting_down:
		return
	var settings := EditorInterface.get_editor_settings()
	if settings.get_project_metadata(SETTINGS_SECTION, "project_godot_writable_asked", false):
		return
	var rec := await _fetch_fstat_record("res://project.godot")
	if rec.is_empty() or not rec.has("headType") or rec.has("action") \
			or _type_is_writable(String(rec.headType)):
		return # Not in Perforce, already checked out, or already writable.
	settings.set_project_metadata(SETTINGS_SECTION, "project_godot_writable_asked", true)
	if not await _show_project_godot_offer():
		return
	var local := ProjectSettings.globalize_path("res://project.godot")
	if await _p4_ok(["edit", "-t", "+w", local]):
		_log(("project.godot is checked out with the always-writable filetype. Submit it, and " +
				"nobody on your team gets Godot's \"Unable to write project.godot\" error again."))
	else:
		await _show_alert(("Perforce wouldn't change project.godot's filetype. Press \"Log\" in " +
				"the P4G panel to see what it said."))
	_request_refresh()


func _show_project_godot_offer() -> bool:
	return await _show_confirm_dialog(("Godot writes project.godot every time the editor " +
			"starts, and when the file is read-only - as it is in your workspace - Godot shows " +
			"\"Load Errors: Unable to write project.godot\".\n\nP4Godot can check project.godot " +
			"out with the always-writable filetype (+w). Submit it, and nobody on your team sees " +
			"that error again."), "Make It Writable", "Not Now")


func _show_allwrite_offer() -> bool:
	return await _show_confirm_dialog(("Your Perforce workspace keeps files read-only " +
			"until you check them out. Godot rewrites some files on its own - every .import " +
			"file when it reimports, and scenes when it re-saves them - and those writes fail " +
			"on read-only files.\n\nP4Godot can switch the workspace to leave files writable. " +
			"It then watches the workspace and checks out what you change, from Godot or any " +
			"other program, and Get Latest still never overwrites a file you changed.\n\nYou " +
			"can switch back at any time in the P4G panel's settings menu."),
			"Make Files Writable", "Not Now")


func _on_workspace_connected() -> void:
	_offer_allwrite_once()


func _add_workspace_settings(popup: PopupMenu) -> void:
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
			item.set_custom_color(0, _action_color("delete"))
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
		"move/add", "move/delete": return "Record the Move"
	return "Check Out"


func _populate_context_menu(meta: Dictionary) -> void:
	var kind := String(meta.get("type", ""))
	if kind != "detected" and kind != "detected_group":
		super(meta)
		return
	context_menu.clear()
	move_submenu.clear()
	_move_targets.clear()
	var m := context_menu
	if kind == "detected":
		var action := String(meta.get("action", ""))
		_menu_add(m, "ArrowUp" if action == "edit" else "Add" if action.ends_with("add") else "Remove",
				_detected_verb(action), CTX_DETECTED_OPEN)
		m.add_separator()
		if not action.ends_with("delete"):
			var in_project := String(meta.get("res_path", "")).begins_with("res://")
			_menu_add(m, "Load" if in_project else "Filesystem",
					"Open" if in_project else "Show in File Manager", CTX_DETECTED_SHOW)
		if action == "edit":
			_menu_add(m, "Search", "Diff vs Depot", CTX_DETECTED_DIFF)
		if not action.ends_with("add"):
			_menu_add(m, "History", "History...", CTX_DETECTED_HISTORY)
		if not _clean_flag(action).is_empty():
			m.add_separator()
			_menu_add(m, "UndoRedo", "Revert My Change...", CTX_DETECTED_REVERT)
	else:
		_menu_add(m, "ArrowUp", "Open All in Perforce", CTX_DETECTED_OPEN_ALL)
	m.add_separator()
	_menu_add(m, "Reload", "Refresh", CTX_REFRESH)


func _on_context_menu_id_pressed(id: int) -> void:
	var meta := _context_target
	match id:
		CTX_DETECTED_OPEN:
			# A move is both of its halves, which -M has to see together.
			var whole_move := String(meta.get("action", "")).begins_with("move/")
			await _open_detected_rows(_watch_detected.filter(func(r: Dictionary) -> bool:
				return r.local == String(meta.get("local", "")) \
						or (whole_move and String(r.action).begins_with("move/"))))
		CTX_DETECTED_REVERT:
			var row: Array = _watch_detected.filter(
					func(r: Dictionary) -> bool: return r.local == String(meta.get("local", "")))
			if not row.is_empty() and await _show_confirm_dialog(("Put back the version of '%s' " +
					"you had? Your change to it is lost, and this can't be undone.") % _tree_label(
					String(meta.get("res_path", ""))), "Revert My Change", "Cancel"):
				await _revert_detected(row)
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
		elif String(meta.action).ends_with("add"):
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
		_watch_alerted.erase(row.key) # asked for it: a refusal is worth saying again
	await _open_detected(rows)
	var records: Variant = await _opened_records()
	if records == null:
		return
	var opened := {}
	for rec: Dictionary in records:
		opened[_path_key(String(rec.get("clientFile", "")))] = true
	_set_watch_detected(_watch_detected_rows(opened))
