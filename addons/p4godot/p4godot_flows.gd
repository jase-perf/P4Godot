@tool
extends "p4godot_windows.gd"

## The multi-step operations: Get Latest, resolve, changelist create/edit/move,
## and Submit.
# The changelists from the last refresh - drives the "Move to Changelist" submenu
# without a re-query.
var _last_changelists: Array = []
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
	if not to_resolve.is_empty() and not cancelled:
		await _resolve_flow(to_resolve)
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
	# The retry names each stuck file by its local path, which means "the head
	# revision". A file asked for at a revision (`//depot/f#3`, from the history
	# window) has to be asked for at that revision again.
	var asked_rev := {} # depot path -> "#3" / "@1234"
	for t in targets:
		var mark := t.find("#") if t.find("#") != -1 else t.find("@")
		if t.begins_with("//") and mark != -1:
			asked_rev[t.substr(0, mark)] = t.substr(mark)
	var depot_of := {} # _path_key(local) -> depot path, from the first pass
	for rec in _parse_ztag(result):
		depot_of[_path_key(String(rec.get("clientFile", "")))] = String(rec.get("depotFile", ""))
	var names: Array = notes.clobbered # parallel to `stuck`
	var still: Array = []
	var retry_failed := false
	for start in range(0, stuck.size(), 100):
		var end := mini(start + 100, stuck.size())
		var batch := PackedStringArray(["-ztag", "sync", "-s"])
		for i in range(start, end):
			_set_file_writable(String(stuck[i]), false)
			var depot := String(depot_of.get(_path_key(String(stuck[i])), ""))
			batch.append(depot + String(asked_rev[depot]) if asked_rev.has(depot) else String(stuck[i]))
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


## What `p4 resolve -am|-ay|-at <file>` did, from its answer: "combined",
## "mine", "theirs", "skipped" (-am met lines both sides changed; p4 exits 0
## and leaves the file unresolved), or "failed".
func _resolve_outcome(text: String, exit_code: int) -> String:
	if text.contains(" - resolve skipped"):
		return "skipped"
	if exit_code != 0:
		return "failed"
	if text.contains(" - merge from "):
		return "combined"
	if text.contains(" - copy from "):
		return "theirs"
	if text.contains(" - ignored "):
		return "mine"
	return "failed"


## Godot's own text formats. Perforce merges them line by line like any text,
## and a line-by-line merge of a scene can produce a file Godot can't load.
func _is_godot_text_resource(res_path: String) -> bool:
	return res_path.get_extension().to_lower() in ["tscn", "tres", "godot", "import", "cfg"]


## Combine a teammate's newer version with yours, for every file that needs
## it (or only the ones named). A file gets here when it was checked out here
## and submitted by someone else: after the next sync the server holds their
## version, the disk holds yours, and a submit is refused until one answer is
## chosen per file. Returns how many files are still waiting.
func _resolve_flow(only: Array = []) -> int:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return -1
	var waiting := _unresolved_in(_parse_ztag(await _p4_exec(["-ztag", "resolve", "-n"])))
	if not only.is_empty():
		waiting = waiting.filter(func(w: Dictionary) -> bool: return String(w.res_path) in only)
	if waiting.is_empty():
		await _show_alert("Nothing is waiting to be combined with a teammate's version.")
		_request_refresh()
		return 0
	var left := 0
	var changed_on_disk: Array = []
	for i in waiting.size():
		var outcome := await _resolve_one(waiting[i], i + 1, waiting.size())
		if outcome == "combined" or outcome == "theirs":
			changed_on_disk.append(String(waiting[i].res_path))
		elif outcome == "stop":
			left += waiting.size() - i
			break
		elif outcome != "mine":
			left += 1
	_request_refresh()
	if not changed_on_disk.is_empty():
		EditorInterface.get_resource_filesystem().scan()
		for res: String in changed_on_disk:
			if res.begins_with("res://") and _is_open_in_editor(res):
				await _reload_path(res)
	if left == 0:
		_log("Resolved %d file(s). They can be submitted now." % waiting.size())
	else:
		_log("%d file(s) still need resolving before they can be submitted." % left)
	return left


## One file's question and answer. Returns "combined", "mine", "theirs",
## "later" (this file was skipped), "stop" (the user closed the dialog) or
## "failed".
func _resolve_one(file: Dictionary, position: int, total: int) -> String:
	var res := String(file.res_path)
	var local := String(file.local)
	if bool(file.special):
		await _show_alert(("'%s' needs more than its content combined - it was moved, deleted " +
				"or changed type on the server. P4Godot can't do that one. In P4V, right-click " +
				"the file and choose \"Resolve Files...\".") % res)
		return "later"
	var can_combine := not bool(file.binary)
	while true:
		var options := PackedStringArray()
		var modes: Array = []
		if can_combine:
			options.append("Combine both versions")
			modes.append("combine")
		options.append("Keep mine (their changes are left out)")
		modes.append("mine")
		options.append("Take theirs (my changes are thrown away)")
		modes.append("theirs")
		options.append("Decide later")
		modes.append("later")
		var message := ("A teammate submitted a newer version of this file while you had it " +
				"checked out:\n\n    %s\n\nYour version is on your computer; theirs is on the " +
				"server. Choose what the file should contain when you submit.") % res
		if can_combine:
			message += ("\n\n\"Combine\" keeps both sets of changes, as long as you didn't " +
					"both change the same lines.")
			if _is_godot_text_resource(res):
				message += (" This is one of Godot's own file formats, and a combined one " +
						"can come out broken - open it and check it before you submit.")
		else:
			message += ("\n\nThis kind of file can't be combined: one version wins and the " +
					"other is lost from the newest revision. Talk to whoever made the other " +
					"change before you choose.")
		var pick: Dictionary = await _show_option_dialog("Resolve (%d of %d)" % [position, total],
				message, options, 0, "OK")
		if not pick.ok:
			return "stop"
		var mode := String(modes[int(pick.index)])
		if mode == "later":
			return "later"
		if mode == "theirs" and not await _show_confirm_dialog(
				("Throw away your changes to '%s' and take your teammate's version?\n\n" +
				"Everything you changed in this file is lost, and this can't be undone.") % res,
				"Take Theirs", "Go Back"):
			continue
		var flag: String = {"combine": "-am", "mine": "-ay", "theirs": "-at"}[mode]
		var result := await _p4_exec_logged(["resolve", flag, local])
		var outcome := _resolve_outcome("" if result.output.is_empty() else String(result.output[0]),
				int(result.exit_code))
		# p4 exits 0 on a skipped merge, so the answer alone isn't proof: ask
		# whether the file is still waiting.
		var still := _unresolved_in(_parse_ztag(await _p4_exec(["-ztag", "resolve", "-n", local])))
		if still.is_empty() and outcome in ["combined", "mine", "theirs"]:
			return outcome
		if mode == "combine" and outcome == "skipped":
			await _show_alert(("You and your teammate changed the same lines of '%s', so " +
					"Perforce can't combine the two versions by itself. Nothing was changed.\n\n" +
					"Choose which version to keep. To combine them by hand instead, choose " +
					"\"Decide later\" and use P4V (right-click the file there, \"Resolve " +
					"Files...\").") % res)
			can_combine = false
			continue
		await _show_alert(("Perforce didn't resolve '%s'. Press \"Log\" in the P4G panel to see " +
				"what it said.") % res)
		return "failed"
	return "failed" # unreachable; while-true exits via return


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
		text += ("\n\n%d file(s) you have checked out were also changed by a teammate, " +
				"and the two versions have to be combined before you can submit:\n\n%s\n\n" +
				"P4Godot asks you about each one next. You can also do it later: they are " +
				"marked \"needs resolve\" in the P4G panel, and right-clicking one offers " +
				"\"Resolve...\".") % [to_resolve.size(), _file_listing(to_resolve, 30)]
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
	# The server refuses the whole submit if a teammate got a newer version of
	# any file in first. Say which files before asking for a description,
	# instead of after a numbered changelist exists and the submit has failed.
	var opened_recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", "-Ro",
			"-e", change, "-T", "depotFile,clientFile,headRev,haveRev,action,unresolved",
			_project_scope() if change == "default" else "//%s/..." % _p4_client]))
	var behind := _out_of_date_in(opened_recs)
	if not behind.is_empty():
		var labels := {}
		for f in files:
			labels[String(f.depot_path)] = String(f.label)
		var lines: Array = []
		for depot: String in behind.slice(0, 12):
			lines.append("    " + String(labels.get(depot, depot)))
		if behind.size() > 12:
			lines.append("    ...and %d more" % (behind.size() - 12))
		var go: bool = await _show_confirm_dialog(("Perforce won't take this submit yet. %s " +
				"changed on the server after you downloaded %s:\n\n%s\n\nA teammate submitted " +
				"a newer version first, so their changes and yours have to be combined before " +
				"yours can go in. Nothing was sent.\n\nCombine them now? P4Godot fetches their " +
				"version and asks you about each file. Afterwards, check your project still " +
				"works and submit again.") % [
				"This file" if behind.size() == 1 else "These %d files" % behind.size(),
				"it" if behind.size() == 1 else "them", "\n".join(lines)],
				"Combine Now", "Not Now")
		if not go:
			return
		# The sync is what brings their version in and schedules the merge;
		# on a file that is checked out it never touches the content on disk.
		await _safe_sync(PackedStringArray(behind))
		var wanted: Array = []
		for rec in opened_recs:
			if String(rec.get("depotFile", "")) in behind:
				var local := String(rec.get("clientFile", ""))
				var res := _local_to_res(local)
				wanted.append(res if not res.is_empty() else local)
		await _resolve_flow(wanted)
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
					"right-click it again and choose \"Resolve...\" to combine their changes " +
					"with yours, and submit again.\n\nYour files are in changelist %s in the P4G panel, with " +
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


## Depot paths of the opened files in `fstat` records that the server would
## refuse in a submit: an older revision than the server's newest, or a
## merge still waiting (`unresolved`). A file being added has nothing older to
## be behind, and the server takes a plain delete whatever revision it was.
func _out_of_date_in(records: Array) -> Array:
	var behind: Array = []
	for rec in records:
		var depot := String(rec.get("depotFile", ""))
		if depot.is_empty():
			continue
		if rec.has("unresolved"):
			behind.append(depot)
			continue
		# A delete of a file that moved on at the server is accepted as it is
		# (measured); the old half of a move is not, and stays in the check.
		if String(rec.get("action", "")) in ["add", "move/add", "branch", "import", "delete"]:
			continue
		var head := String(rec.get("headRev", ""))
		var have := String(rec.get("haveRev", ""))
		if head.is_valid_int() and have.is_valid_int() and int(have) < int(head):
			behind.append(depot)
	return behind


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


## How the last _submit_changelist ended: "submitted", "not_submitted" or
## "unknown" ("" before any submit). For self-tests; nothing else reads it.
var _last_submit_outcome: String = ""


## Sync res_path to the head revision, or to `revision` (a depot path with
## #rev, from the history window), and reload it from disk. Shared by the
## dock's per-row menu, the FileSystem dock and the history window. Returns
## whether the file on disk was rewritten.
func _sync_path(res_path: String, revision: String = "") -> bool:
	var target := revision if not revision.is_empty() else ProjectSettings.globalize_path(res_path)
	var synced: Dictionary = await _safe_sync([target])
	var notes: Dictionary = synced.notes
	_request_refresh()
	var which := "the newer version" if revision.is_empty() else "revision #%s" % revision.get_slice("#", 1)
	if not notes.existing.is_empty():
		await _show_alert("Perforce didn't download '%s'.%s" % [res_path,
				_kept_existing_text(notes.existing)])
		return false
	var refused: Array = notes.modified + notes.clobbered
	if not refused.is_empty():
		var next_step := ("Check it out (right-click it in the FileSystem dock and choose " +
				"\"P4: Check Out\"), then sync it again - Perforce will then ask you to combine " +
				"the two versions.") if revision.is_empty() else ("To go back to the older " +
				"version, first throw your change away (right-click the file and choose " +
				"\"P4: Revert...\"), or check it out and submit it.")
		await _show_alert(("Perforce didn't download %s of '%s'.\n\nThe file " +
				"is changed on your disk but not checked out, so Perforce left your version " +
				"alone instead of throwing it away. %s") % [which, res_path, next_step])
		return false
	# Only a sync that rewrote the file changes anything the editor shows ("up
	# to date", or an opened file getting a resolve scheduled, doesn't).
	var rewrote: bool = int(synced.exit_code) == 0 and not synced.done.names.is_empty()
	if not rewrote:
		# For the head revision "nothing downloaded" usually means "already up to
		# date". A revision was asked for on purpose, so say what p4 said - the
		# file being checked out since the history window looked, for one ("is
		# opened at a later revision - not changed", exit 0).
		if not revision.is_empty() and not _shutting_down:
			var said: Array = notes.problems
			await _show_alert("Perforce didn't download %s of '%s'.%s" % [which, res_path,
					("\n\nIt said:\n    " + "\n    ".join(said)) if not said.is_empty()
					else " Press \"Log\" in the P4G panel to see what it said."])
		return false
	EditorInterface.get_resource_filesystem().scan()
	if not _is_open_in_editor(res_path):
		return true
	var reload: bool = await _show_confirm_dialog(("Godot just downloaded %s of " +
			"'%s' from the server, and the file is open in the editor.\n\nShow the " +
			"downloaded version? Anything you changed but didn't save is lost.\n\nIf you " +
			"keep what's in the editor instead, saving it later overwrites the version " +
			"you just downloaded.") % [which, res_path],
			"Show Downloaded Version", "Keep Editor Version")
	if reload:
		await _reload_path(res_path)
	else:
		_log("Kept the editor's version of '%s' - saving it would overwrite the synced revision." % res_path)
	return true
