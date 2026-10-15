@tool
extends "p4godot_history.gd"

## Shelving: put a changelist's files on the server without submitting them,
## so a teammate can review them or you can carry on elsewhere, and unshelve
## anyone's shelf into this workspace. Your own changelists' shelves are
## handled from the dock's changelist menu; everyone's are in the Shelves
## window, which can diff a shelf without touching the workspace.
##
## Measured on 2026.1 as ordinary users:
##   - `shelve` without -c, for files in the default changelist, opens the
##     editor on a new changelist form. Every shelve here names a numbered
##     changelist, created with `change -i` when the files are in the default.
##   - Shelving again refuses ("already shelved, use -f") unless told; -r
##     makes the shelf exactly the files open now.
##   - A changelist that has a shelf can be neither submitted ("has shelved
##     files -- cannot submit") nor deleted until the shelf is.
##   - Unshelving onto a checked-out file keeps the file on disk and schedules
##     a resolve against the shelf. Onto a writable file that isn't checked out
##     it refuses that file ("Can't clobber writable file", exit 1) and opens
##     the rest. An exclusive (+l) file someone has open is skipped with exit
##     0. A shelf made against an older revision opens the file at that
##     revision, so the submit asks for a resolve with the newer one.
##   - `revert -w` then `unshelve` into the same changelist puts back every
##     file - adds and both halves of a move included.

# How many shelves the Shelves window lists (`changes -m`).
const SHELVES_LIST_MAX := 100

# Shelved actions that leave no file behind: nothing to diff.
const SHELF_NO_CONTENT := ["delete", "move/delete", "purge", "archive"]

var shelves_window: Window
var _shelves_tree: Tree
var _shelf_files_tree: Tree
var _shelf_detail: TextEdit
var _shelves_heading: Label
var _shelves_filter: OptionButton
var _shelves_number: LineEdit
var _shelf_diff_button: Button
var _shelf_workspace_button: Button
var _shelf_unshelve_button: Button
# The listed shelves (from _shelf_records, without files) and the selected
# one with its files (each file also has `res_path`, "" when unmapped).
var _shelves_list: Array = []
var _shelf: Dictionary = {}
# Bumped by every selection, so a slow load for an older one is dropped.
var _shelf_load_token: int = 0


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

## What unshelving `wanted` (depot paths) did, read from the state afterwards
## rather than from p4's words: `in_target` maps each depot path open in the
## target changelist afterwards to its fstat record (`unresolved` present when
## a resolve is scheduled; haveRev/headRev). p4's output is only read for why
## a file was not opened. `local_of` maps depot paths to local paths, which is
## how p4 names a file it refuses to overwrite. `before` maps each depot path
## checked out before the unshelve to its changelist, and `target` is the
## changelist unshelved into: a file that was in the target already counts
## as unshelved only when p4 says so, and only a file nobody had checked out
## is "behind" because of the shelf. Returns {opened, resolve, behind,
## refused}: depot paths, and refused as [{depot, why}].
static func _unshelve_report(wanted: Array, in_target: Dictionary, output_text: String,
		local_of: Dictionary, before: Dictionary = {}, target: String = "") -> Dictionary:
	var opened: Array = []
	var resolve: Array = []
	var behind: Array = []
	var refused: Array = []
	var lines := output_text.split("\n")
	for depot_any in wanted:
		var depot := String(depot_any)
		var said_unshelved := false
		for raw in lines:
			var line := String(raw).strip_edges()
			if line.begins_with(depot + "#") and line.contains(" - unshelved, opened for "):
				said_unshelved = true
		var already_there := not target.is_empty() and String(before.get(depot, "")) == target
		if in_target.has(depot) and (said_unshelved or not already_there):
			var rec: Dictionary = in_target[depot]
			opened.append(depot)
			if rec.has("unresolved"):
				resolve.append(depot)
			if not before.has(depot) and int(rec.get("haveRev", "0")) < int(rec.get("headRev", "0")):
				behind.append(depot)
			continue
		refused.append({"depot": depot,
				"why": _unshelve_refusal(depot, String(local_of.get(depot, "")), lines)})
	return {"opened": opened, "resolve": resolve, "behind": behind, "refused": refused}


## Why p4 didn't open `depot`, in plain words, from the lines of its unshelve
## output that name the file (by depot path, or by local path for a refused
## overwrite).
static func _unshelve_refusal(depot: String, local: String, lines: PackedStringArray) -> String:
	var said := ""
	var holder := ""
	var local_key := local.replace("\\", "/").to_lower()
	for raw in lines:
		var line := String(raw).strip_edges().trim_prefix("... ")
		var names_it := line.begins_with(depot + " ") or line.begins_with(depot + "#") \
				or (not local_key.is_empty() and line.replace("\\", "/").to_lower().ends_with(local_key))
		if not names_it:
			continue
		if line.contains(" - also opened by "):
			holder = line.get_slice(" - also opened by ", 1).strip_edges()
		elif not line.contains("unshelved, opened for") and said.is_empty():
			said = line
	if said.contains("can't edit exclusive file already opened"):
		return ("Only one person at a time can have this file checked out (it's an exclusive " +
				"+l file), and %s has it now.") % (holder if not holder.is_empty() else "someone else")
	if said.contains("Can't clobber writable file"):
		return ("The file on your computer is writable but isn't checked out, so Perforce won't " +
				"overwrite it - it may hold changes nobody told Perforce about. Check it out or " +
				"reconcile it first, then unshelve again.")
	if said.is_empty():
		return "Perforce didn't open it and didn't say why. Press \"Log\" in the P4G panel to see its output."
	return said



## What can be done with one shelved file: {base, workspace}, each {ok,
## reason}. `base` compares the shelved file with the revision it was made
## from (an added file with nothing); `workspace` with the file on this
## computer, which needs the file mapped here (`local_exists`).
static func _shelf_file_actions(file: Dictionary, mapped: bool, local_exists: bool) -> Dictionary:
	var base := {"ok": true, "reason": ""}
	var workspace := {"ok": true, "reason": ""}
	var file_name := String(file.depot).get_file()
	if SHELF_NO_CONTENT.has(String(file.action)):
		var why := "The shelf deletes '%s' (%s), so there's no shelved file to compare." % [file_name, file.action]
		base = {"ok": false, "reason": why}
		workspace = {"ok": false, "reason": why}
	elif not mapped:
		workspace = {"ok": false, "reason": "'%s' isn't part of your workspace, so there's no file on your computer to compare." % file_name}
	elif not local_exists:
		workspace = {"ok": false, "reason": "'%s' isn't on your computer, so there's nothing to compare. Diff vs Base shows the whole shelved file." % file_name}
	return {"base": base, "workspace": workspace}


# ---------------------------------------------------------------------------
# Reading shelves
# ---------------------------------------------------------------------------

## One shelf, as in _shelf_records, with each file's `res_path` added ("" when
## this workspace doesn't map it). {} when the changelist doesn't exist or p4
## couldn't be asked; a shelf with no files has `files` empty.
func _read_shelf(change: String) -> Dictionary:
	var result := await _p4_exec(["-Mj", "-ztag", "describe", "-S", "-s", change])
	var shelves := _shelf_records("" if result.output.is_empty() else String(result.output[0]))
	if shelves.is_empty():
		return {}
	var shelf: Dictionary = shelves[0]
	var depots: Array = []
	for f: Dictionary in shelf.files:
		depots.append(String(f.depot))
	var local_of := await _where_locals(depots)
	for f: Dictionary in shelf.files:
		var local := String(local_of.get(String(f.depot), ""))
		f["local"] = local
		f["res_path"] = "" if local.is_empty() else _local_to_res(local)
	return shelf


## depot path -> local path for each of `depots` this workspace maps.
func _where_locals(depots: Array) -> Dictionary:
	var out := {}
	if depots.is_empty():
		return out
	var args: PackedStringArray = ["-ztag", "where"]
	for d in depots:
		args.append(String(d))
	for rec in _parse_ztag(await _p4_exec(args)):
		# Exclusionary mappings add records without a `path`; the one that
		# maps the file has it.
		if rec.has("path") and not String(rec.path).is_empty() and not rec.has("unmap"):
			out[String(rec.get("depotFile", ""))] = String(rec.path)
	return out


## The workspace's open files in `change`: depot path -> fstat record with
## clientFile, haveRev, headRev and `unresolved` when a resolve is waiting.
func _opened_in_change(change: String) -> Dictionary:
	var out := {}
	for rec in _parse_ztag(await _p4_exec(["-ztag", "fstat", "-Ro", "-e", change,
			"-T", "depotFile,clientFile,haveRev,headRev,action,unresolved", "//%s/..." % _p4_client])):
		var depot := String(rec.get("depotFile", ""))
		if not depot.is_empty():
			out[depot] = rec
	return out


# ---------------------------------------------------------------------------
# Your own changelists: shelve, update, shelve and revert, unshelve, delete
# ---------------------------------------------------------------------------

## The model's entry for `change` from the last refresh, or {}.
func _changelist_from_model(change: String) -> Dictionary:
	for cl in _last_changelists:
		if String(cl.change) == change:
			return cl
	return {}


## Of `res_paths`, the ones open in a Godot tab (see _open_editor_files).
func _open_in_editor(res_paths: Array) -> Array:
	var open := _open_editor_files()
	var out: Array = []
	for r in res_paths:
		if open.has(String(r)):
			out.append(String(r))
	return out


## Shelve the files open in `change` (making the shelf exactly those files
## when it already has one), and with `revert_after` revert them once the
## shelf is confirmed to hold every one. The default changelist's files move
## to a new numbered changelist first, described by `preset_desc` or by
## asking. Returns the numbered changelist, or "" when nothing was shelved.
func _shelve_changelist(change: String, revert_after: bool, preset_desc: String = "") -> String:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return ""
	var files: Array = await _submit_file_list(change, _changelist_from_model(change).get("files", []))
	if files.is_empty():
		await _show_alert("There's nothing open in this changelist to shelve.")
		return ""
	var existing: Array = []
	if change != "default":
		existing = (await _read_shelves([change])).get(change, [])
	var labels: Array = []
	for f in files:
		labels.append("%s  (%s)" % [f.label, f.action])
	var in_editor := _open_in_editor(files.map(func(f: Dictionary) -> String: return String(f.label)))

	var what := "changelist #%s" % change if change != "default" else "the default changelist"
	var text := ""
	if existing.is_empty():
		text = "Shelve the %d file%s in %s?\n\n%s\nA shelf puts copies of your files on the server " % [
				files.size(), "" if files.size() == 1 else "s", what, _file_listing(labels)] + \
				"without submitting them, so a teammate can review them or you can pick them up later."
	else:
		text = ("Update the shelf of %s?\n\nThe shelf becomes exactly these %d file%s, as they are " +
				"on disk now:\n\n%s\nA shelved file that is no longer open here leaves the shelf.") % [
				what, files.size(), "" if files.size() == 1 else "s", _file_listing(labels)]
	if change == "default":
		text += "\n\nPerforce only shelves numbered changelists, so these files move to a new one first."
	if revert_after:
		text += ("\n\nAfterwards the files are reverted: your workspace goes back to the server's " +
				"versions, and files you added are removed from disk. Unshelve brings everything back.")
	if not in_editor.is_empty():
		text += ("\n\nOpen in Godot:\n%s\nThe shelf takes what is saved on disk, so save first if " +
				"these have changes you want in it.") % _file_listing(in_editor)
		if revert_after:
			text += " Reverting reloads them, and anything unsaved in them is lost."
	var ok_text := "Shelve and Revert" if revert_after else ("Shelve" if existing.is_empty() else "Update Shelf")
	if not await _show_confirm_dialog(text, ok_text, "Cancel"):
		return ""

	var number := change
	if change == "default":
		var desc := preset_desc
		if desc.is_empty():
			var input: Dictionary = await _show_input_dialog("Shelve Default Changelist",
					"Description for the new changelist the shelf goes in:", "", true, "Shelve")
			if not input.ok:
				return ""
			desc = String(input.text).strip_edges()
		if desc.is_empty():
			await _show_alert("A changelist needs a description.")
			return ""
		var spec := "Change: new\n\nDescription:\n" + _indent_spec_text(desc) + "\nFiles:\n"
		for f in files:
			spec += "\t%s\n" % f.depot_path
		number = _created_change_in(await _p4_exec_spec(["change", "-i"], spec))
		if number.is_empty():
			await _show_alert("Perforce couldn't make a changelist for the shelf. Nothing was shelved. Press \"Log\" in the P4G panel to see what it said.")
			_request_refresh()
			return ""

	# -r makes the shelf exactly the open files, with or without a shelf
	# already there (measured), so a stale "no shelf yet" can't turn this
	# into a plain shelve that refuses ("already shelved").
	var result := await _p4_exec(["shelve", "-r", "-c", number])
	if _shutting_down:
		return ""
	var said := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
	# p4's own answer first. A shelve that fails part-way - a file missing
	# from disk, say - says "Shelve aborted", exits 1 and leaves the old
	# shelf as it was (measured): the same files with the same actions, which
	# the membership check below can't tell from a new one.
	if int(result.exit_code) != 0 or not said.contains("files shelved"):
		await _show_alert(("Perforce didn't shelve changelist #%s%s. Perforce said:\n\n%s") % [number,
				"" if existing.is_empty() else "; its shelf is as it was before" + \
				(", and nothing was reverted" if revert_after else ""), said])
		_request_refresh()
		return ""
	# Then the shelf on the server: every file open in the changelist must be
	# in it with the same action.
	var shelved := {}
	for f: Dictionary in (await _read_shelves([number])).get(number, []):
		shelved[String(f.depot)] = f
	var missing: Array = []
	for f in files:
		if String(shelved.get(String(f.depot_path), {}).get("action", "")) != String(f.action):
			missing.append(String(f.label))
	if not missing.is_empty():
		await _show_alert(("Perforce didn't shelve everything in changelist #%s. Not in the shelf:" +
				"\n\n%s\nNothing was reverted. Perforce said:\n\n%s") % [number, _file_listing(missing), said])
		_request_refresh()
		return ""
	# Reverting throws the files on disk away, so before that the shelf has to
	# hold what is on disk now - a file saved again while p4 was shelving.
	if revert_after:
		var stale: Array = await _shelf_differs_from_disk(number, files, shelved)
		if not stale.is_empty():
			await _show_alert(("These files in changelist #%s are different on disk from the shelf, " +
					"so nothing was reverted:\n\n%s\nShelve again to include the changes.") % [number,
					_file_listing(stale)])
			_request_refresh()
			return ""
	_log("Shelved %d file%s in changelist #%s." % [files.size(), "" if files.size() == 1 else "s", number])

	if revert_after:
		var depots: Array = files.map(func(f: Dictionary) -> String: return String(f.depot_path))
		# Local paths from the server, not the dock's labels: a file opened
		# since the last refresh has no res:// label yet, and its open tab
		# must be reloaded too.
		var local_of := await _where_locals(depots)
		var revert_args: PackedStringArray = ["revert", "-w"]
		revert_args.append_array(PackedStringArray(depots))
		await _p4_exec_logged(revert_args)
		var names: Array = []
		for d in depots:
			var res := _local_to_res(String(local_of.get(d, "")))
			if not res.is_empty():
				names.append(res)
				_checked_out_this_session.erase(res)
				_pending_save_checkout.erase(res)
		var reload: Dictionary = await _reload_after_sync({"names": names}, [])
		_rescan_filesystem()
		var still: Array = (await _opened_in_change(number)).keys().filter(func(d: String) -> bool:
			return depots.has(d))
		if not still.is_empty():
			await _show_alert(("The files are shelved in changelist #%s, but %d of them are still " +
					"checked out:\n\n%s\nPress \"Log\" in the P4G panel to see what Perforce said.") \
					% [number, still.size(), _file_listing(still)])
		elif not reload.orphaned.is_empty():
			await _show_alert(("Shelved and reverted. These are still open in Godot but no longer on " +
					"disk - they were added or moved in the changelist. Close them without saving; " +
					"unshelving brings them back:\n\n%s") % _file_listing(reload.orphaned))
		_log("Reverted the shelved files; unshelve changelist #%s to bring them back." % number)
	_request_refresh()
	return number


## Of `files` (from _submit_file_list), the labels of those whose content on
## disk isn't what changelist `number` has shelved (`shelved`: depot path ->
## shelved file, as from _read_shelves). A text file is compared with the
## shelved copy (`print`), line endings aside; a binary file by size, which
## the server keeps byte for byte, rather than downloading it again.
## Not `p4 diff file@=N`: on the new half of a shelved move it compared the
## file with another file's content (measured on 2026.1), and it can't
## compare an added file at all ("file(s) not on client").
func _shelf_differs_from_disk(number: String, files: Array, shelved: Dictionary) -> Array:
	var check: Array = files.filter(func(f: Dictionary) -> bool:
		return not SHELF_NO_CONTENT.has(String(f.action)))
	var local_of := await _where_locals(check.map(func(f: Dictionary) -> String: return String(f.depot_path)))
	var differs: Array = []
	for f in check:
		var local := String(local_of.get(String(f.depot_path), ""))
		var shelf_file: Dictionary = shelved.get(String(f.depot_path), {})
		if not local.is_empty() and FileAccess.file_exists(local) and not shelf_file.is_empty():
			if _revision_diffable(String(shelf_file.type), 0).verdict == "binary":
				if FileAccess.get_file_as_bytes(local).size() == int(shelf_file.size):
					continue
			else:
				var copy := await _p4_exec(["print", "-q", "%s@=%s" % [f.depot_path, number]])
				var theirs := "" if copy.output.is_empty() else String(copy.output[0])
				if copy.exit_code == 0 and theirs.replace("\r\n", "\n") \
						== FileAccess.get_file_as_string(local).replace("\r\n", "\n"):
					continue
		differs.append(String(f.label))
	return differs


## Delete the shelf of `change` (or just `depots` from it). The files open in
## the workspace aren't touched.
func _delete_shelf(change: String, depots: Array = []) -> bool:
	var shelf: Array = (await _read_shelves([change])).get(change, [])
	if shelf.is_empty():
		await _show_alert("Changelist #%s has no shelved files." % change)
		_request_refresh()
		return false
	var names: Array = depots if not depots.is_empty() else shelf.map(func(f: Dictionary) -> String: return String(f.depot))
	var text := ("Delete %s from the shelf of changelist #%s?\n\n%s\nAnyone reviewing it loses " +
			"these files. Your checked-out files aren't touched.") % [
			"this file" if names.size() == 1 else "these %d files" % names.size(), change, _file_listing(names)]
	if not await _show_confirm_dialog(text, "Delete Shelved Files", "Cancel"):
		return false
	var args: PackedStringArray = ["shelve", "-d", "-c", change]
	for d in depots:
		args.append(String(d))
	var result := await _p4_exec(args)
	var left: Array = (await _read_shelves([change])).get(change, [])
	var gone := true
	for f: Dictionary in left:
		if names.has(String(f.depot)):
			gone = false
	if not gone:
		var said := "" if result.output.is_empty() else String(result.output[0]).strip_edges()
		await _show_alert("Perforce didn't delete the shelved files of changelist #%s:\n\n%s" % [change, said])
	_request_refresh()
	return gone


# ---------------------------------------------------------------------------
# Unshelving
# ---------------------------------------------------------------------------

## Unshelve `depots` (all of the shelf when empty) from `shelf` (as from
## _read_shelf) into the workspace. `target` is a pending changelist number,
## "default", or "" to ask which - offering a new changelist named after the
## shelf. Returns the _unshelve_report, plus `change` (where the files went),
## or {} when nothing was attempted.
func _unshelve(shelf: Dictionary, depots: Array = [], target: String = "") -> Dictionary:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return {}
	var source := String(shelf.change)
	var files: Array = []
	for f: Dictionary in shelf.files:
		if depots.is_empty() or depots.has(String(f.depot)):
			files.append(f)
	if files.is_empty():
		await _show_alert("Changelist #%s has no shelved files to unshelve." % source)
		return {}
	var labels: Array = []
	var unmapped: Array = []
	for f in files:
		var label := String(f.res_path) if not String(f.res_path).is_empty() else String(f.depot)
		labels.append("%s  (%s)" % [label, f.action])
		if String(f.get("local", "")).is_empty():
			unmapped.append(String(f.depot))
	if unmapped.size() == files.size():
		await _show_alert(("None of the files shelved in changelist #%s are part of your workspace, " +
				"so there's nowhere to unshelve them:\n\n%s") % [source, _file_listing(unmapped)])
		return {}
	var wanted: Array = []
	var local_of := {}
	var deletes := 0
	for f in files:
		if not String(f.get("local", "")).is_empty():
			wanted.append(String(f.depot))
			local_of[String(f.depot)] = String(f.local)
			if SHELF_NO_CONTENT.has(String(f.action)):
				deletes += 1
	# Which changelist each file is checked out in now. A checked-out file
	# keeps its content (a resolve is scheduled); one checked out in another
	# changelist is moved into the target (measured), which is worth saying;
	# and any other file is overwritten - an open tab of it is reloaded.
	var was_in := {}
	var opened_args: PackedStringArray = ["-ztag", "opened"]
	opened_args.append_array(PackedStringArray(wanted))
	for rec in _parse_ztag(await _p4_exec(opened_args)):
		if rec.has("depotFile") and rec.has("change"):
			was_in[String(rec.depotFile)] = String(rec.change)
	var replaced_open: Array = _open_in_editor(wanted.filter(func(d: String) -> bool:
		return not was_in.has(d)).map(func(d: String) -> String: return _local_to_res(String(local_of[d]))))

	var first_line := String(shelf.desc).get_slice("\n", 0).strip_edges()
	var text := ("Unshelve %d file%s from changelist #%s by %s?\n\n\"%s\"\n\n%s\nFiles you have " +
			"checked out keep your edits, and Perforce asks you to combine them with the shelved " +
			"version. Other files on your computer are replaced with the shelved versions; " +
			"reverting them puts yours back.") % [files.size(), "" if files.size() == 1 else "s",
			source, shelf.user, first_line, _file_listing(labels)]
	if deletes > 0:
		text += "\n\nThe shelf deletes %d of these; they are removed from your computer." % deletes
	if not replaced_open.is_empty():
		text += ("\n\nOpen in Godot and not checked out, so they are replaced and reloaded - " +
				"anything unsaved in them is lost:\n%s") % _file_listing(replaced_open)
	var number := target
	if number.is_empty():
		var choices: Array = [{"change": "__new__", "label": "New changelist: Review of #%s" % source}]
		choices.append_array(await _pending_changelist_choices())
		var picked: Dictionary = await _show_checkout_target_dialog(text, "Unshelve", "Cancel",
				choices, "Unshelve", "Unshelve into:")
		if not picked.ok:
			return {}
		number = String(picked.change)
	elif not await _show_confirm_dialog(text, "Unshelve", "Cancel"):
		return {}
	var made_new := false
	if number == "__new__":
		number = await _create_changelist("Review of #%s by %s: %s" % [source, shelf.user, first_line])
		if number.is_empty():
			await _show_alert("Perforce couldn't make a changelist to unshelve into. Nothing was unshelved. Press \"Log\" in the P4G panel to see what it said.")
			return {}
		made_new = true

	# Always the confirmed files by name: without them p4 takes whatever the
	# shelf holds when it runs, which can have changed while the dialog was up.
	var args: PackedStringArray = ["unshelve", "-s", source, "-c", number]
	args.append_array(PackedStringArray(wanted))
	var result := await _p4_exec(args)
	if _shutting_down:
		return {}
	var said := "" if result.output.is_empty() else String(result.output[0])
	var report := _unshelve_report(wanted, await _opened_in_change(number), said, local_of,
			was_in, number)
	report["change"] = number
	report["moved"] = report.opened.filter(func(d: String) -> bool:
		return was_in.has(d) and String(was_in[d]) != number)
	for d in unmapped:
		report.refused.append({"depot": d, "why": "It isn't part of your workspace."})
	if made_new and report.opened.is_empty():
		await _p4_exec(["change", "-d", number]) # don't leave an empty review changelist behind
		report.change = ""

	# Reload what changed on disk. A file waiting for a resolve kept your
	# version on disk, so there's nothing new to load for it.
	var names: Array = []
	for d in report.opened:
		if report.resolve.has(d):
			continue
		var res := _local_to_res(String(local_of.get(d, "")))
		if not res.is_empty():
			names.append(res)
			_checked_out_this_session[res] = true
	var reload: Dictionary = await _reload_after_sync({"names": names}, [])
	report["orphaned"] = reload.orphaned
	_rescan_filesystem()
	_request_refresh()
	await _show_alert(_unshelve_summary(report, source, local_of))
	var waiting: Array = []
	for d in report.resolve:
		var res := _local_to_res(String(local_of.get(d, "")))
		waiting.append(res if not res.is_empty() else String(local_of.get(d, d)))
	if not waiting.is_empty() and await _show_confirm_dialog(("%d unshelved file%s also had " +
			"your own edits. Combine the two versions now?") % [waiting.size(),
			"" if waiting.size() == 1 else "s"], "Combine Now", "Later"):
		await _resolve_flow(waiting)
	return report


## The message after an unshelve: what opened where, what waits for a resolve,
## what was made against older versions, and what was refused and why.
func _unshelve_summary(report: Dictionary, source: String, local_of: Dictionary) -> String:
	var name_of := func(d: String) -> String:
		var res := _local_to_res(String(local_of.get(d, "")))
		return res if not res.is_empty() else d
	var parts: Array = []
	if report.opened.is_empty():
		parts.append("Nothing from changelist #%s was unshelved." % source)
	else:
		var where := "the default changelist" if report.change == "default" else "changelist #%s" % report.change
		parts.append("Unshelved %d file%s from changelist #%s into %s." % [report.opened.size(),
				"" if report.opened.size() == 1 else "s", source, where])
	if not report.get("moved", []).is_empty():
		parts.append(("These were checked out in another of your changelists, and Perforce moved " +
				"them into this one:\n%s") % _file_listing(report.moved.map(name_of)))
	if not report.get("orphaned", []).is_empty():
		parts.append(("The shelf deletes these, but they are still open in Godot. Close them " +
				"without saving - saving would put the file back:\n%s") % _file_listing(report.orphaned))
	if not report.resolve.is_empty():
		parts.append(("These already had your edits, which are kept. Perforce needs the two " +
				"versions combined before you submit:\n%s") % _file_listing(report.resolve.map(name_of)))
	if not report.behind.is_empty():
		parts.append(("These were shelved against an older version than the latest on the server. " +
				"Submit asks you to combine them with the latest first:\n%s") % _file_listing(report.behind.map(name_of)))
	if not report.refused.is_empty():
		var lines: Array = []
		for r in report.refused:
			lines.append("    %s\n        %s" % [name_of.call(String(r.depot)), r.why])
		parts.append("Not unshelved:\n" + "\n".join(lines))
	return "\n\n".join(parts)


## Have the FileSystem dock notice files unshelving or reverting added or
## removed. Changed files are reloaded by _reload_after_sync.
func _rescan_filesystem() -> void:
	if _shutting_down:
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs and not efs.is_scanning():
		efs.scan()


# ---------------------------------------------------------------------------
# Diffs of a shelved file
# ---------------------------------------------------------------------------

## The two texts and p4's unified diff for a shelved file against the revision
## it was made from: {ok, reason, old, new, unified, left, right}. An added
## file compares with nothing; a moved one with the file it was moved from.
func _shelf_base_diff(change: String, file: Dictionary, files: Array) -> Dictionary:
	var fail := func(reason: String) -> Dictionary: return {"ok": false, "reason": reason}
	var acts := _shelf_file_actions(file, true, true)
	if not acts.base.ok:
		return fail.call(acts.base.reason)
	var check := _revision_diffable(String(file.type), int(file.size))
	var file_name := String(file.depot).get_file()
	if check.verdict == "binary":
		return fail.call("'%s' is stored in Perforce as a binary file (an image, sound or model), so there's nothing to show side by side." % file_name)
	if check.verdict == "too big":
		return fail.call(_diff_too_big_message(file_name, int(check.size)))
	var shelved := "%s@=%s" % [file.depot, change]
	var base := ""
	match String(file.action):
		"edit", "integrate", "import":
			base = "%s#%d" % [file.depot, file.rev]
		"move/add":
			var rec: Array = _parse_ztag(await _p4_exec(["-ztag", "fstat", "-Rs", "-e", change,
					"-T", "depotFile,movedFile", String(file.depot)]))
			var from := "" if rec.is_empty() else String(rec[0].get("movedFile", ""))
			for f: Dictionary in files:
				if String(f.depot) == from:
					base = "%s#%d" % [from, f.rev]
	var b := await _p4_exec(["print", "-q", shelved])
	if _shutting_down:
		return fail.call("")
	if b.exit_code != 0:
		return fail.call("Godot couldn't download the shelved '%s'. Press \"Log\" in the P4G panel to see what Perforce said." % file_name)
	var new_text := "" if b.output.is_empty() else String(b.output[0])
	var right := "%s  (shelved in #%s)" % [file.depot, change]
	if base.is_empty():
		return {"ok": true, "reason": "", "old": "", "new": new_text,
				"unified": _line_diff_unified(PackedStringArray(), _split_lines(new_text)),
				"left": "(new file)", "right": right}
	var d := await _p4_exec(["diff2", "-t", "-dul", base, shelved])
	var text := "" if d.output.is_empty() else String(d.output[0])
	if d.exit_code != 0 or not text.contains("===="):
		return fail.call("Godot couldn't compare %s with %s. Press \"Log\" in the P4G panel to see what Perforce said." % [base, shelved])
	if _diff2_identical(text):
		return fail.call("The shelved '%s' is identical to %s%s." % [file_name, base,
				" - it was moved without being changed" if file.action == "move/add" else ""])
	var a := await _p4_exec(["print", "-q", base])
	if a.exit_code != 0:
		return fail.call("Godot couldn't download %s to compare against. Press \"Log\" in the P4G panel to see what Perforce said." % base)
	return {"ok": true, "reason": "", "old": "" if a.output.is_empty() else String(a.output[0]),
			"new": new_text, "unified": text, "left": base, "right": right}


## The shelved file beside the file on this computer: {ok, reason, old, new,
## unified, left, right}, the shelved version on the left. The lines are
## compared here (_line_diff_unified), not by `p4 diff file@=N`: that one
## can't compare an added file, and on the new half of a shelved move it
## read another file's content (measured on 2026.1).
func _shelf_workspace_diff(change: String, file: Dictionary) -> Dictionary:
	var fail := func(reason: String) -> Dictionary: return {"ok": false, "reason": reason}
	var local := String(file.get("local", ""))
	var acts := _shelf_file_actions(file, not local.is_empty(), not local.is_empty() and FileAccess.file_exists(local))
	if not acts.workspace.ok:
		return fail.call(acts.workspace.reason)
	var file_name := String(file.depot).get_file()
	var check := _revision_diffable(String(file.type), int(file.size))
	if check.verdict == "binary":
		return fail.call("'%s' is stored in Perforce as a binary file (an image, sound or model), so there's nothing to show side by side." % file_name)
	if check.verdict == "too big":
		return fail.call(_diff_too_big_message(file_name, int(check.size)))
	var f := FileAccess.open(local, FileAccess.READ)
	if f == null:
		return fail.call("Godot couldn't read '%s' from your computer. Check it isn't open in another program." % local)
	if f.get_length() > DIFF_MAX_BYTES:
		return fail.call(_diff_too_big_message(file_name, int(f.get_length())))
	var new_text := f.get_as_text()
	f.close()
	var shelved := "%s@=%s" % [file.depot, change]
	var a := await _p4_exec(["print", "-q", shelved])
	if a.exit_code != 0:
		return fail.call("Godot couldn't download the shelved '%s'. Press \"Log\" in the P4G panel to see what Perforce said." % file_name)
	var old_text := "" if a.output.is_empty() else String(a.output[0])
	var old_lines := _split_lines(old_text)
	var new_lines := _split_lines(new_text)
	if old_lines == new_lines:
		return fail.call("'%s' on your computer is identical to the shelved version." % file_name)
	var res := _local_to_res(local)
	return {"ok": true, "reason": "", "old": old_text, "new": new_text,
			"unified": _line_diff_unified(old_lines, new_lines),
			"left": "%s  (shelved in #%s)" % [file.depot, change],
			"right": "%s (workspace)" % (res if not res.is_empty() else local)}


func _show_shelf_diff(data: Dictionary, title: String) -> void:
	if _shutting_down or data.is_empty():
		return
	if not data.ok:
		if not String(data.reason).is_empty():
			await _show_alert(String(data.reason))
		return
	_show_diff(String(data.old), String(data.new), String(data.unified), String(data.left),
			String(data.right), title)


## The dock's shelved-file rows: compare with the base revision or the
## workspace, from the model entry `meta`.
func _diff_shelved_row(meta: Dictionary, vs_workspace: bool) -> void:
	var shelf := await _read_shelf(String(meta.change))
	if _shutting_down:
		return
	var file := {}
	for f: Dictionary in shelf.get("files", []):
		if String(f.depot) == String(meta.depot_path):
			file = f
	if file.is_empty():
		await _show_alert("'%s' is no longer shelved in changelist #%s." % [meta.depot_path, meta.change])
		_request_refresh()
		return
	var data: Dictionary = await _shelf_workspace_diff(String(meta.change), file) if vs_workspace \
			else await _shelf_base_diff(String(meta.change), file, shelf.files)
	await _show_shelf_diff(data, "%s (shelved in #%s)" % [String(meta.depot_path).get_file(), meta.change])


# ---------------------------------------------------------------------------
# The Shelves window: everyone's shelves in this project
# ---------------------------------------------------------------------------

func _build_shelves_window() -> void:
	shelves_window = Window.new()
	shelves_window.title = "P4 Shelves"
	shelves_window.size = Vector2i(1000, 640)
	shelves_window.visible = false
	shelves_window.close_requested.connect(func() -> void: shelves_window.hide())

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	shelves_window.add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)
	_shelves_filter = OptionButton.new()
	_shelves_filter.add_item("Everyone's shelves in this project")
	_shelves_filter.add_item("My shelves")
	_shelves_filter.item_selected.connect(func(_i: int) -> void: _load_shelves_list())
	top.add_child(_shelves_filter)
	_add_toolbar_button(top, "Reload", "Refresh", "List the shelves again.",
			func() -> void: _load_shelves_list(), true)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	var number_label := Label.new()
	number_label.text = "Changelist:"
	top.add_child(number_label)
	_shelves_number = LineEdit.new()
	_shelves_number.placeholder_text = "number"
	_shelves_number.custom_minimum_size = Vector2(90, 0)
	_shelves_number.tooltip_text = "Open any shelved changelist by its number - from a code review or a teammate's message."
	_shelves_number.text_submitted.connect(func(_t: String) -> void: _on_shelves_open_pressed())
	top.add_child(_shelves_number)
	_add_toolbar_button(top, "", "Open", "Show the shelved changelist with this number.",
			_on_shelves_open_pressed)

	_shelves_heading = Label.new()
	_shelves_heading.clip_text = true
	root.add_child(_shelves_heading)

	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	_shelves_tree = Tree.new()
	_shelves_tree.hide_root = true
	_shelves_tree.columns = 5
	_shelves_tree.column_titles_visible = true
	_shelves_tree.select_mode = Tree.SELECT_ROW
	_shelves_tree.custom_minimum_size = Vector2(0, 180)
	var titles := ["Change", "User", "Workspace", "Date", "Description"]
	var widths := [80, 110, 150, 130, 0]
	for c in titles.size():
		_shelves_tree.set_column_title(c, titles[c])
		_shelves_tree.set_column_title_alignment(c, HORIZONTAL_ALIGNMENT_LEFT)
		if widths[c] > 0:
			_shelves_tree.set_column_expand(c, false)
			_shelves_tree.set_column_custom_minimum_width(c, widths[c])
	_shelves_tree.item_selected.connect(func() -> void: _on_shelf_selected())
	split.add_child(_shelves_tree)

	var lower := HSplitContainer.new()
	lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(lower)
	_shelf_files_tree = Tree.new()
	_shelf_files_tree.hide_root = true
	_shelf_files_tree.columns = 2
	_shelf_files_tree.column_titles_visible = true
	_shelf_files_tree.select_mode = Tree.SELECT_MULTI
	_shelf_files_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shelf_files_tree.size_flags_stretch_ratio = 2.0
	_shelf_files_tree.custom_minimum_size = Vector2(0, 160)
	_shelf_files_tree.set_column_title(0, "Shelved file")
	_shelf_files_tree.set_column_title(1, "Action")
	_shelf_files_tree.set_column_expand(1, false)
	_shelf_files_tree.set_column_custom_minimum_width(1, 100)
	_shelf_files_tree.multi_selected.connect(func(_item: TreeItem, _col: int, _sel: bool) -> void:
		_update_shelf_buttons.call_deferred())
	_shelf_files_tree.item_activated.connect(_on_shelf_diff_pressed)
	lower.add_child(_shelf_files_tree)
	_shelf_detail = TextEdit.new()
	_shelf_detail.editable = false
	_shelf_detail.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_shelf_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lower.add_child(_shelf_detail)

	var buttons := HBoxContainer.new()
	root.add_child(buttons)
	_shelf_diff_button = _add_toolbar_button(buttons, "", "Diff vs Base",
			"Show what the shelf changes in the selected file: the shelved version beside the revision it was made from. Double-clicking a file does the same.",
			_on_shelf_diff_pressed)
	_shelf_workspace_button = _add_toolbar_button(buttons, "", "Diff vs Workspace",
			"Compare the shelved version of the selected file with the one on your computer.",
			_on_shelf_workspace_pressed)
	_shelf_unshelve_button = _add_toolbar_button(buttons, "", "Unshelve All...",
			"Copy the shelved files into your workspace, checked out in a changelist you choose. Select files to unshelve only those.",
			_on_shelf_unshelve_pressed)

	dock.add_child(shelves_window)


func _on_shelves_pressed() -> void:
	await _show_shelves()


## Open the Shelves window, listing the newest shelves in this project, and
## with `change` show that shelf.
func _show_shelves(change: String = "") -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	if shelves_window == null or not is_instance_valid(shelves_window):
		_build_shelves_window()
	shelves_window.popup_centered()
	await _load_shelves_list()
	if not change.is_empty():
		await _open_shelf_number(change)


## List the newest shelved changelists with files in this project, everyone's
## or the user's own per the filter.
func _load_shelves_list() -> void:
	var args: PackedStringArray = ["-Mj", "-ztag", "changes", "-s", "shelved", "-l",
			"-m", str(SHELVES_LIST_MAX)]
	if _shelves_filter.selected == 1:
		args.append_array(["-u", _p4_user])
	args.append(_project_scope())
	var result := await _p4_exec(args)
	if _shutting_down or _shelves_tree == null or not is_instance_valid(_shelves_tree):
		return
	_shelves_list = _shelf_records("" if result.output.is_empty() else String(result.output[0]))
	_shelf_load_token += 1 # a row still loading would fill the files of a list that's gone
	var keep := String(_shelf.get("change", ""))
	_populate_shelves_list(keep)


func _populate_shelves_list(select_change: String) -> void:
	_shelves_tree.clear()
	var root := _shelves_tree.create_item()
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var to_select: TreeItem = null
	for s: Dictionary in _shelves_list:
		var item := _shelves_tree.create_item(root)
		item.set_text(0, String(s.change))
		item.set_text(1, String(s.user))
		item.set_text(2, String(s.client))
		item.set_text(3, _history_date(int(s.time), bias))
		item.set_text(4, String(s.desc).get_slice("\n", 0))
		item.set_tooltip_text(4, String(s.desc))
		item.set_metadata(0, String(s.change))
		if String(s.change) == select_change:
			to_select = item
	var who := "your" if _shelves_filter.selected == 1 else "everyone's"
	_shelves_heading.text = "  %d of %s newest shelved changelists with files in this project%s" % [
			_shelves_list.size(), who, "" if _shelves_list.size() < SHELVES_LIST_MAX else " (the limit)"]
	if _shelves_list.is_empty():
		_shelves_heading.text = "  No shelved changelists with files in this project. Enter a number above to open any other."
	if to_select:
		to_select.select(0)
	elif _shelf.is_empty() or not select_change.is_empty():
		_show_shelf_files({})


func _on_shelves_open_pressed() -> void:
	var text := _shelves_number.text.strip_edges().trim_prefix("#")
	if not text.is_valid_int() or int(text) <= 0:
		await _show_alert("Type a changelist number, like 1234.")
		return
	await _open_shelf_number(str(int(text)))


## Show shelf `change`, adding it to the list when the list doesn't have it.
func _open_shelf_number(change: String) -> void:
	# Claimed before the wait, like a row click: whichever was asked for last
	# is what the window ends up showing.
	_shelf_load_token += 1
	var token := _shelf_load_token
	var shelf := await _read_shelf(change)
	if _shutting_down or shelves_window == null or not is_instance_valid(shelves_window) \
			or token != _shelf_load_token:
		return
	if shelf.is_empty():
		await _show_alert("Perforce has no changelist #%s." % change)
		return
	if shelf.files.is_empty():
		await _show_alert("Changelist #%s has no shelved files - it may have been submitted, or its shelf deleted." % change)
		return
	var listed := false
	for s: Dictionary in _shelves_list:
		if String(s.change) == change:
			listed = true
	if not listed:
		var entry := shelf.duplicate()
		entry.erase("files")
		_shelves_list.push_front(entry)
	_show_shelf_files(shelf)
	_populate_shelves_list(change)


func _on_shelf_selected() -> void:
	var item := _shelves_tree.get_selected()
	if item == null:
		return
	var change := String(item.get_metadata(0))
	if String(_shelf.get("change", "")) == change:
		return
	_shelf_load_token += 1
	var token := _shelf_load_token
	_show_shelf_files({})
	_shelf_detail.text = "Loading changelist #%s..." % change
	var shelf := await _read_shelf(change)
	if _shutting_down or token != _shelf_load_token or _shelf_files_tree == null \
			or not is_instance_valid(_shelf_files_tree):
		return
	_show_shelf_files(shelf)


## Show `shelf`'s files and description below the list ({} clears them).
func _show_shelf_files(shelf: Dictionary) -> void:
	_shelf = shelf
	_shelf_files_tree.clear()
	var root := _shelf_files_tree.create_item()
	for i in shelf.get("files", []).size():
		var f: Dictionary = shelf.files[i]
		var item := _shelf_files_tree.create_item(root)
		var shown := String(f.res_path).trim_prefix("res://") if not String(f.res_path).is_empty() \
				else String(f.depot)
		item.set_text(0, shown)
		item.set_tooltip_text(0, String(f.depot) if String(f.get("local", "")).is_empty() \
				else "%s\n%s" % [f.depot, f.local])
		if String(f.get("local", "")).is_empty():
			item.set_custom_color(0, _dim_color())
		item.set_text(1, String(f.action))
		item.set_custom_color(1, _action_color(String(f.action)))
		var icon: Texture2D = _file_icon(String(f.res_path)) if not String(f.res_path).is_empty() else null
		if icon:
			item.set_icon(0, icon)
		item.set_metadata(0, i)
	if shelf.is_empty():
		_shelf_detail.text = ""
	else:
		var bias := int(Time.get_time_zone_from_system().get("bias", 0))
		_shelf_detail.text = "Changelist %s by %s@%s, %s\n\n%s" % [shelf.change, shelf.user,
				shelf.client, _history_date(int(shelf.time), bias), shelf.desc]
	_update_shelf_buttons()


func _shelf_selected_files() -> Array:
	var out: Array = []
	if _shelf_files_tree == null:
		return out
	var item := _shelf_files_tree.get_next_selected(null)
	while item:
		out.append(_shelf.files[int(item.get_metadata(0))])
		item = _shelf_files_tree.get_next_selected(item)
	return out


func _update_shelf_buttons() -> void:
	if _shelf_files_tree == null or not is_instance_valid(_shelf_files_tree):
		return
	var picked := _shelf_selected_files()
	var states: Array = []
	if _shelf.is_empty():
		var why := "Select a shelved changelist first."
		states = [{"ok": false, "reason": why}, {"ok": false, "reason": why}, {"ok": false, "reason": why}]
	else:
		var one := {"ok": false, "reason": "Select one file."}
		var acts := {"base": one, "workspace": one}
		if picked.size() == 1:
			var local := String(picked[0].get("local", ""))
			acts = _shelf_file_actions(picked[0], not local.is_empty(),
					not local.is_empty() and FileAccess.file_exists(local))
		states = [acts.base, acts.workspace, {"ok": true, "reason": ""}]
	_shelf_unshelve_button.text = "Unshelve All..." if picked.is_empty() or picked.size() == _shelf.get("files", []).size() \
			else "Unshelve %d Selected..." % picked.size()
	var buttons := [_shelf_diff_button, _shelf_workspace_button, _shelf_unshelve_button]
	for i in buttons.size():
		var button: Button = buttons[i]
		button.disabled = not bool(states[i].ok)
		if not button.has_meta("p4_tip"):
			button.set_meta("p4_tip", button.tooltip_text)
		button.tooltip_text = String(button.get_meta("p4_tip")) if states[i].ok else String(states[i].reason)


func _on_shelf_diff_pressed() -> void:
	var picked := _shelf_selected_files()
	if picked.size() != 1 or _shelf.is_empty():
		return
	var data := await _shelf_base_diff(String(_shelf.change), picked[0], _shelf.files)
	await _show_shelf_diff(data, "%s (shelved in #%s)" % [String(picked[0].depot).get_file(), _shelf.change])


func _on_shelf_workspace_pressed() -> void:
	var picked := _shelf_selected_files()
	if picked.size() != 1 or _shelf.is_empty():
		return
	var data := await _shelf_workspace_diff(String(_shelf.change), picked[0])
	await _show_shelf_diff(data, "%s (shelved in #%s)" % [String(picked[0].depot).get_file(), _shelf.change])


func _on_shelf_unshelve_pressed() -> void:
	if _shelf.is_empty():
		return
	var picked := _shelf_selected_files()
	var depots: Array = []
	if picked.size() != _shelf.files.size():
		for f: Dictionary in picked:
			depots.append(String(f.depot))
	await _unshelve(_shelf, depots)
