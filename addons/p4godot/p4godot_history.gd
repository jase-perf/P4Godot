@tool
extends "p4godot_flows.gd"

## File history: every submitted revision of one file, followed back through
## moves and branches, with diffs between revisions and against the workspace,
## and Get This Revision.

# How many revisions of each file the history asks for (`filelog -m`). A
# file with more shows the newest ones and says so.
const HISTORY_MAX_REVS := 300

# Actions that leave no file at a revision: nothing to diff or get.
const HISTORY_NO_CONTENT := ["delete", "move/delete", "purge", "archive"]

var history_window: Window
var _history_tree: Tree
var _history_detail: TextEdit
var _history_heading: Label
var _history_diff_button: Button
var _history_workspace_button: Button
var _history_get_button: Button
# The file the window shows, its depot path, its revisions newest first (see
# _filelog_revisions) and the revision this workspace has (0 = none).
var _history_res_path: String = ""
var _history_depot_path: String = ""
var _history_revs: Array = []
var _history_have_rev: int = 0
# The old depot path when the file's rename isn't submitted yet (its history
# is all under that name), and whether the list may stop short of the file's
# first revision (see _filelog_revisions).
var _history_renamed_from: String = ""
var _history_truncated: bool = false
# The change whose revision _populate_history selects (0: the newest).
var _history_select_change: int = 0
# ---------------------------------------------------------------------------
# File history
#
# `p4 -Mj filelog -l -t -i`: -l for whole descriptions, -t for times, -i to
# follow the file back through moves and branches. JSON (-Mj) rather than
# tagged text because a description holding a blank line ends a tagged record
# early: everything after it - the rest of the description and every older
# revision's fields - is lost or split off (measured on 2026.1). JSON carries
# it intact.
# ---------------------------------------------------------------------------

## The revisions in `p4 -Mj -ztag filelog -l -t -i` output, newest first, each
## {depot, rev, change, action, type, size, time, user, client, desc, from}
## (`from` is the file a move, branch or copy at that revision came from, or
## ""). Returns {revs, depot, untracked, most}: `depot` is the first file p4
## listed (the one asked about); `untracked` is true when p4 said the file has
## never been submitted; `most` is the largest number of revisions p4 returned
## for any one file. `filelog -m N -i` counts N per file and stops following
## the file back at the first one that reaches N (measured), so `most` >= N
## means the list may be cut short.
static func _filelog_revisions(text: String) -> Dictionary:
	var revs: Array = []
	var depot := ""
	var untracked := false
	var most := 0
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if not line.begins_with("{"):
			continue
		var rec: Variant = JSON.parse_string(line)
		if not rec is Dictionary:
			continue
		if not rec.has("depotFile"):
			# p4's messages come as {"data": "...", "severity": ...}.
			var msg := String(rec.get("data", ""))
			if msg.contains("not on client") or msg.contains("no such file"):
				untracked = true
			continue
		var file := String(rec.depotFile)
		if depot.is_empty():
			depot = file
		var i := 0
		while rec.has("rev%d" % i):
			var from := ""
			var j := 0
			while rec.has("how%d,%d" % [i, j]):
				# "moved from", "branch from", "copy from"...; the "... into"
				# records point the other way.
				if String(rec["how%d,%d" % [i, j]]).ends_with(" from"):
					from = String(rec.get("file%d,%d" % [i, j], ""))
					break
				j += 1
			revs.append({
				"depot": file,
				"rev": int(rec["rev%d" % i]),
				"change": int(rec.get("change%d" % i, "0")),
				"action": String(rec.get("action%d" % i, "")),
				"type": String(rec.get("type%d" % i, "")),
				"size": int(rec.get("fileSize%d" % i, "0")),
				"time": int(rec.get("time%d" % i, "0")),
				"user": String(rec.get("user%d" % i, "")),
				"client": String(rec.get("client%d" % i, "")),
				"desc": String(rec.get("desc%d" % i, "")).strip_edges(),
				"from": from,
			})
			i += 1
		most = maxi(most, i)
	revs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.change != b.change:
			return a.change > b.change
		return a.rev > b.rev)
	return {"revs": revs, "depot": depot, "untracked": untracked, "most": most}


## "2026-10-15 17:15" in the editor machine's time zone. The zone's current
## offset is applied to every date, so a revision from the other side of a
## daylight-saving change shows an hour off - Godot exposes no historical
## time zone rules.
static func _history_date(unix: int, bias_minutes: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix + bias_minutes * 60, true).substr(0, 16)


## A revision as people read it: "#3" on the file's current path, or
## "old_name.gd#2" from before a move or branch.
static func _history_rev_name(rev: Dictionary, current_depot: String) -> String:
	if String(rev.depot) == current_depot:
		return "#%d" % int(rev.rev)
	return "%s#%d" % [String(rev.depot).get_file(), int(rev.rev)]


## What the history window can do with the selected revisions (indexes into
## `revs`, newest first). Returns {diff, workspace, get}, each {ok, reason};
## `diff` also has the `older` and `newer` index to compare. One revision
## selected compares it with the one before; two compare each other.
## `have_rev` is the revision of current_depot this workspace has (0: none);
## `truncated` says the list may not reach back to the first revision.
static func _history_actions(revs: Array, selected: Array, current_depot: String,
		local_exists: bool, have_rev: int = 0, truncated: bool = false) -> Dictionary:
	var diff := {"ok": false, "reason": "", "older": -1, "newer": -1}
	var workspace := {"ok": false, "reason": ""}
	var get_rev := {"ok": false, "reason": ""}
	var picked: Array = selected.duplicate()
	picked.sort()
	if picked.size() == 2:
		diff.newer = picked[0]
		diff.older = picked[1]
	elif picked.size() == 1:
		diff.newer = picked[0]
		diff.older = picked[0] + 1
	if picked.is_empty() or picked.size() > 2:
		diff.reason = "Select one revision to compare it with the one before it, or two to compare them with each other."
	elif int(diff.older) >= revs.size():
		if truncated:
			diff.reason = "This is the earliest revision shown - the history stops at %d revisions per file." % HISTORY_MAX_REVS
		else:
			diff.reason = "This is the first revision of the file - there's nothing earlier to compare it with."
	else:
		diff.ok = true
		for idx: int in [int(diff.older), int(diff.newer)]:
			if HISTORY_NO_CONTENT.has(String(revs[idx].action)):
				diff.ok = false
				diff.reason = _no_content_reason(revs[idx], current_depot) + " There's nothing there to compare."
	if picked.size() != 1:
		workspace.reason = "Select one revision."
		get_rev.reason = "Select one revision."
	else:
		var rev: Dictionary = revs[picked[0]]
		var rev_name := _history_rev_name(rev, current_depot)
		if HISTORY_NO_CONTENT.has(String(rev.action)):
			workspace.reason = _no_content_reason(rev, current_depot) + " There's nothing there to compare."
			get_rev.reason = _no_content_reason(rev, current_depot) + " There's nothing there to get."
		elif String(rev.depot) != current_depot:
			var why := "Revision %s is from before the file was moved or branched to its current name" % rev_name
			workspace.reason = why + ". Compare it with another revision instead."
			get_rev.reason = why + ", so getting it would bring back the old file beside this one."
		else:
			if int(rev.rev) == have_rev:
				get_rev.reason = "You already have revision %s." % rev_name
			else:
				get_rev.ok = true
			if local_exists:
				workspace.ok = true
			else:
				workspace.reason = "The file isn't on your computer, so there's nothing to compare."
	return {"diff": diff, "workspace": workspace, "get": get_rev}


## Why a revision whose action is in HISTORY_NO_CONTENT has nothing to show.
static func _no_content_reason(rev: Dictionary, current_depot: String) -> String:
	var rev_name := _history_rev_name(rev, current_depot)
	match String(rev.action):
		"purge":
			return "Revision %s was purged: the server no longer keeps its content (a +S filetype, or an administrator's obliterate)." % rev_name
		"archive":
			return "Revision %s is archived: its content was moved to storage the server has to restore it from first." % rev_name
	return "Revision %s deleted the file." % rev_name


## The change that last touched each line, from `p4 -Mj -ztag annotate -c -i`:
## index 0 is line 1. -i follows the file back through moves and branches, so
## a renamed file's lines name the changes that wrote them rather than the
## rename (measured on 2026.1). The first JSON object describes the file; each
## line after it carries `lower`, the change, and `data`, the text.
static func _annotate_changes(text: String) -> Array:
	var out: Array = []
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if not line.begins_with("{"):
			continue
		var rec: Variant = JSON.parse_string(line)
		if rec is Dictionary and rec.has("data") and rec.has("lower"):
			out.append(int(rec.lower))
	return out


## The line of the have revision that line `local_line` (1-based) of the file
## on disk came from, given the hunks of `p4 diff -du` between them (as from
## _parse_unified_hunks). 0 when the line was added or changed on disk.
static func _have_line_for(local_line: int, hunks: Array) -> int:
	var delta := 0 # have line - local line, past the hunks read so far
	for h: Dictionary in hunks:
		var o := int(h.old_start)
		var n := int(h.new_start)
		# A hunk with no old lines (a pure insertion) names the line before it.
		if not h.ops.has("ctx") and not h.ops.has("del"):
			o += 1
		if local_line < n:
			break
		for op: String in h.ops:
			match op:
				"ctx":
					if n == local_line:
						return o
					o += 1
					n += 1
				"del":
					o += 1
				"add":
					if n == local_line:
						return 0
					n += 1
		delta = o - n
	return local_line + delta


## The server revision the file in this workspace is based on, from its
## fstat record: `depot#have`, or for a file whose rename isn't submitted
## yet (opened for move/add) the file it was moved from at the revision it
## was moved from - the new name has no revision of its own. "" for a file
## never submitted.
static func _base_revision_of(stat: Dictionary) -> String:
	if String(stat.get("action", "")) == "move/add" and String(stat.get("movedFile", "")).begins_with("//"):
		return "%s#%d" % [stat.movedFile, int(stat.get("movedRev", "0"))]
	var depot := String(stat.get("depotFile", ""))
	if depot.is_empty() or int(stat.get("haveRev", "0")) == 0:
		return ""
	return "%s#have" % depot


## Who last changed line `line` (1-based) of res_path: {ok, reason, local,
## change, user, time, desc}. The line is counted in `text` - the code
## editor's, saved or not, so the answer is about the line on screen - or,
## with `use_text` false, in the file on disk. `local` is true when the line
## is one of this computer's own unsubmitted changes.
func _who_changed_line(res_path: String, line: int, text: String = "", use_text: bool = false) -> Dictionary:
	var fail := func(reason: String) -> Dictionary: return {"ok": false, "reason": reason}
	var local_path := ProjectSettings.globalize_path(res_path)
	if not use_text:
		if not FileAccess.file_exists(local_path):
			return fail.call("'%s' isn't on your computer." % res_path)
		text = FileAccess.get_file_as_string(local_path)
	var now_lines := _split_lines(text)
	if line < 1 or line > now_lines.size():
		return fail.call("There's nothing on line %d of '%s'." % [line, res_path])
	var stat := await _fetch_fstat_record(res_path)
	if _shutting_down:
		return fail.call("")
	var base := _base_revision_of(stat)
	if base.is_empty():
		return fail.call("'%s' has never been submitted to Perforce, so every line in it is yours and unsubmitted." % res_path)
	if _revision_diffable(String(stat.get("headType", stat.get("type", "text"))), 0).verdict == "binary":
		return fail.call("'%s' is stored in Perforce as a binary file, so it has no lines to look up." % res_path)
	# The text's line numbers differ from the base revision's once it's
	# edited: map through the differences between them, compared here rather
	# than by `p4 diff`, which only sees the file on disk.
	var printed := await _p4_exec(["print", "-q", base])
	if _shutting_down:
		return fail.call("")
	if printed.exit_code != 0:
		return fail.call("Godot couldn't download %s to compare with. Press \"Log\" in the P4G panel to see what Perforce said." % base)
	var base_lines := _split_lines("" if printed.output.is_empty() else String(printed.output[0]))
	var have_line := _have_line_for(line, _parse_unified_hunks(_line_diff_unified(base_lines, now_lines)))
	if have_line == 0:
		return {"ok": true, "reason": "", "local": true}
	var a := await _p4_exec(["-Mj", "-ztag", "annotate", "-c", "-i", base])
	if _shutting_down:
		return fail.call("")
	var changes := _annotate_changes("" if a.output.is_empty() else String(a.output[0]))
	if have_line > changes.size():
		return fail.call("Godot couldn't find line %d in Perforce's answer for '%s'. Press \"Log\" in the P4G panel to see what it said." % [line, res_path])
	var change: int = changes[have_line - 1]
	var desc := await _p4_exec(["-Mj", "-ztag", "describe", "-s", str(change)])
	var recs := _shelf_records("" if desc.output.is_empty() else String(desc.output[0]))
	if recs.is_empty():
		return fail.call("Line %d was last changed in change %d, but Godot couldn't read that change. Press \"Log\" in the P4G panel to see what Perforce said." % [line, change])
	return {"ok": true, "reason": "", "local": false, "change": change, "user": String(recs[0].user),
			"time": int(recs[0].time), "desc": String(recs[0].desc)}


## The "Who Changed This Line?" answer, with a way into the file's history
## at that change. `text` and `use_text` as for _who_changed_line.
func _show_who_changed_line(res_path: String, line: int, text: String = "", use_text: bool = false) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var who := await _who_changed_line(res_path, line, text, use_text)
	if _shutting_down:
		return
	if not who.ok:
		if not String(who.reason).is_empty():
			await _show_alert(String(who.reason))
		return
	if who.local:
		await _show_alert("Line %d of '%s' is one of your own changes, not submitted yet." % [line, res_path])
		return
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var message := "Line %d of '%s' was last changed in change %d by %s on %s:\n\n%s" % [line, res_path,
			who.change, who.user, _history_date(int(who.time), bias), who.desc]
	if await _show_confirm_dialog(message, "Show in History", "Close"):
		await _show_history(res_path, int(who.change))


## Whether `p4 diff2` found the two revisions' contents identical: its header
## line ends "==== identical" (a move with no edit, for one).
static func _diff2_identical(text: String) -> bool:
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if line.begins_with("===="):
			return line.ends_with("==== identical")
	return false


func _build_history_window() -> void:
	history_window = Window.new()
	history_window.title = "P4Godot - History"
	history_window.size = Vector2i(Vector2(980, 600) * EditorInterface.get_editor_scale())
	history_window.visible = false
	history_window.close_requested.connect(func() -> void: history_window.hide())

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	history_window.add_child(root)

	_history_heading = Label.new()
	_history_heading.clip_text = true
	root.add_child(_history_heading)

	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	_history_tree = Tree.new()
	_history_tree.hide_root = true
	_history_tree.columns = 6
	_history_tree.column_titles_visible = true
	_history_tree.select_mode = Tree.SELECT_MULTI
	_history_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_tree.custom_minimum_size = Vector2(0, 220)
	var titles := ["Revision", "Change", "Date", "User", "Action", "Description"]
	var widths := [130, 70, 150, 110, 90, 0]
	for c in titles.size():
		_history_tree.set_column_title(c, titles[c])
		_history_tree.set_column_title_alignment(c, HORIZONTAL_ALIGNMENT_LEFT)
		if widths[c] > 0:
			_history_tree.set_column_expand(c, false)
			_history_tree.set_column_custom_minimum_width(c, int(widths[c] * EditorInterface.get_editor_scale()))
	_history_tree.multi_selected.connect(func(_item: TreeItem, _col: int, _sel: bool) -> void:
		_update_history_buttons.call_deferred())
	_history_tree.item_activated.connect(_on_history_diff_pressed)
	split.add_child(_history_tree)

	_history_detail = TextEdit.new()
	_history_detail.editable = false
	_history_detail.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_history_detail.custom_minimum_size = Vector2(0, 110)
	split.add_child(_history_detail)

	var buttons := HBoxContainer.new()
	root.add_child(buttons)
	_history_diff_button = _add_toolbar_button(buttons, "", "Diff vs Previous",
			"Compare the selected revision with the one before it, or two selected revisions with each other. Double-clicking a revision does the same.",
			_on_history_diff_pressed)
	_history_workspace_button = _add_toolbar_button(buttons, "", "Diff vs Workspace",
			"Compare the selected revision with the file on your computer.",
			_on_history_workspace_pressed)
	_history_get_button = _add_toolbar_button(buttons, "", "Get This Revision...",
			"Replace the file on your computer with the selected revision. Nothing on the server changes.",
			_on_history_get_pressed)

	dock.add_child(history_window)


## `filelog` of one file (a local path, or a depot path), parsed by
## _filelog_revisions.
func _read_filelog(target: String) -> Dictionary:
	var result := await _p4_exec(["-Mj", "-ztag", "filelog", "-l", "-t", "-i", "-m",
			str(HISTORY_MAX_REVS), target])
	return _filelog_revisions("" if result.output.is_empty() else String(result.output[0]))


## Show the history of res_path in the history window. Everything is asked of
## the server first and the window changes in one step afterwards, so a click
## on the old list while the new one loads can't act on the new file's
## revisions. With `select_change`, that change's revision is selected.
func _show_history(res_path: String, select_change: int = 0) -> void:
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var parsed := await _read_filelog(ProjectSettings.globalize_path(res_path))
	var stat := await _fetch_fstat_record(res_path)
	if _shutting_down:
		return
	var current := String(parsed.depot)
	var renamed_from := ""
	# A rename that isn't submitted yet: the new name has no history, the old
	# one has all of it (filelog of the new name says "not on client").
	if parsed.revs.is_empty() and String(stat.get("action", "")) == "move/add" \
			and String(stat.get("movedFile", "")).begins_with("//"):
		renamed_from = String(stat.movedFile)
		current = String(stat.get("depotFile", ""))
		parsed = await _read_filelog(renamed_from)
		if _shutting_down:
			return
	if parsed.revs.is_empty():
		if parsed.untracked:
			await _show_alert("'%s' has never been submitted to Perforce, so it has no history yet." % res_path)
		else:
			await _show_alert("Godot couldn't read the history of '%s'. Press \"Log\" in the P4G panel to see what Perforce said." % res_path)
		return
	if history_window == null or not is_instance_valid(history_window):
		_build_history_window()
	_history_res_path = res_path
	_history_depot_path = current
	_history_revs = parsed.revs
	_history_renamed_from = renamed_from
	_history_truncated = int(parsed.most) >= HISTORY_MAX_REVS
	_history_have_rev = 0 if not renamed_from.is_empty() else int(stat.get("haveRev", "0"))
	_history_select_change = select_change
	_populate_history()
	history_window.title = "P4Godot - History: %s" % _plain_paths(res_path)
	history_window.popup_centered()


func _populate_history() -> void:
	_history_tree.clear()
	var root := _history_tree.create_item()
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var own := 0
	for i in _history_revs.size():
		var rev: Dictionary = _history_revs[i]
		var item := _history_tree.create_item(root)
		var rev_name := _history_rev_name(rev, _history_depot_path)
		if String(rev.depot) == _history_depot_path:
			own += 1
			if int(rev.rev) == _history_have_rev:
				rev_name += "  (you have)"
		item.set_text(0, rev_name)
		item.set_tooltip_text(0, "%s#%d" % [rev.depot, rev.rev])
		item.set_text(1, str(rev.change))
		item.set_text(2, _history_date(int(rev.time), bias))
		item.set_text(3, String(rev.user))
		item.set_text(4, String(rev.action))
		item.set_text(5, String(rev.desc).get_slice("\n", 0))
		item.set_tooltip_text(5, String(rev.desc))
		item.set_metadata(0, i)
	var heading := "  %s - %d revisions" % [_history_depot_path, own]
	if not _history_renamed_from.is_empty():
		heading = "  %s - renamed from %s, and the rename isn't submitted yet. These are the revisions under the old name." \
				% [_history_depot_path.get_file(), _history_renamed_from]
	elif _history_revs.size() > own:
		heading += ", and %d from before it was moved or branched here" % (_history_revs.size() - own)
	if _history_truncated:
		heading += " (the newest %d per file)" % HISTORY_MAX_REVS
	_history_heading.text = heading
	var first := root.get_first_child()
	for item in root.get_children():
		if _history_select_change > 0 and int(_history_revs[int(item.get_metadata(0))].change) == _history_select_change:
			first = item
			break
	_history_select_change = 0 # asked for once; later refills keep the newest first
	if first:
		first.select(0)
		_history_tree.scroll_to_item(first)
	_update_history_buttons()


func _history_selected() -> Array:
	var picked: Array = []
	var item := _history_tree.get_next_selected(null)
	while item:
		picked.append(int(item.get_metadata(0)))
		item = _history_tree.get_next_selected(item)
	return picked


func _history_current_actions() -> Dictionary:
	return _history_actions(_history_revs, _history_selected(), _history_depot_path,
			FileAccess.file_exists(ProjectSettings.globalize_path(_history_res_path)),
			_history_have_rev, _history_truncated)


## Enable the buttons for what the selection allows (the reason goes in the
## tooltip), and show the selected revision's whole description.
func _update_history_buttons() -> void:
	if _history_tree == null or not is_instance_valid(_history_tree):
		return
	var picked := _history_selected()
	var acts := _history_current_actions()
	_history_diff_button.text = "Diff Selected" if picked.size() == 2 else "Diff vs Previous"
	for pair in [[_history_diff_button, acts.diff], [_history_workspace_button, acts.workspace],
			[_history_get_button, acts.get]]:
		var button: Button = pair[0]
		button.disabled = not bool(pair[1].ok)
		if not button.has_meta("p4_tip"):
			button.set_meta("p4_tip", button.tooltip_text)
		button.tooltip_text = String(button.get_meta("p4_tip")) if pair[1].ok else String(pair[1].reason)
	if picked.size() != 1:
		_history_detail.text = ""
		return
	var rev: Dictionary = _history_revs[picked[0]]
	var lines := ["Change %d by %s@%s on %s - %s" % [rev.change, rev.user, rev.client,
			_history_date(int(rev.time), int(Time.get_time_zone_from_system().get("bias", 0))), rev.action]]
	if not String(rev.from).is_empty():
		lines.append("From %s" % rev.from)
	lines.append("")
	lines.append(String(rev.desc))
	_history_detail.text = "\n".join(lines)


func _history_rev_label(rev: Dictionary) -> String:
	return "%s#%d  (change %d, %s)" % [rev.depot, rev.rev, rev.change, rev.user]


func _on_history_diff_pressed() -> void:
	var acts := _history_current_actions()
	if not acts.diff.ok:
		await _show_alert(String(acts.diff.reason))
		return
	await _diff_revisions(_history_revs[acts.diff.older], _history_revs[acts.diff.newer])


func _on_history_workspace_pressed() -> void:
	var acts := _history_current_actions()
	if not acts.workspace.ok:
		await _show_alert(String(acts.workspace.reason))
		return
	await _diff_revision_vs_workspace(_history_res_path, _history_revs[_history_selected()[0]])


func _on_history_get_pressed() -> void:
	var acts := _history_current_actions()
	if not acts.get.ok:
		await _show_alert(String(acts.get.reason))
		return
	await _get_revision(_history_res_path, _history_revs[_history_selected()[0]])


## Tell the user why a revision can't be shown side by side; "" when it can.
func _revision_not_diffable_text(rev: Dictionary) -> String:
	var check := _revision_diffable(String(rev.type), int(rev.size))
	match String(check.verdict):
		"binary":
			return "Revision #%d of '%s' is stored in Perforce as a binary file (an image, sound or model), so there's nothing to show side by side." \
					% [rev.rev, String(rev.depot).get_file()]
		"too big":
			return _diff_too_big_message("%s#%d" % [String(rev.depot).get_file(), rev.rev], int(check.size))
	return ""


## Two submitted revisions side by side, `older` on the left.
func _diff_revisions(older: Dictionary, newer: Dictionary) -> void:
	for rev: Dictionary in [older, newer]:
		var why := _revision_not_diffable_text(rev)
		if not why.is_empty():
			await _show_alert(why)
			return
	var old_spec := "%s#%d" % [older.depot, older.rev]
	var new_spec := "%s#%d" % [newer.depot, newer.rev]
	# -t compares as text even when the filetype changed between the two
	# (text -> utf8, say). Without it p4 answers only "files differ", and with
	# no hunks every line would be shown as unchanged.
	var d := await _p4_exec(["diff2", "-t", "-dul", old_spec, new_spec])
	if _shutting_down:
		return
	var text := "" if d.output.is_empty() else String(d.output[0])
	if d.exit_code != 0 or not text.contains("===="):
		await _show_alert("Godot couldn't compare %s with %s. Press \"Log\" in the P4G panel to see what Perforce said." % [old_spec, new_spec])
		return
	if _diff2_identical(text):
		var note := "" if older.depot == newer.depot \
				else " - the later one moved or copied the file without changing it"
		await _show_alert("%s and %s have the same content%s." % [old_spec, new_spec, note])
		return
	if not text.contains("@@"):
		await _show_alert("%s and %s are different, but Perforce didn't say which lines changed, so there's nothing to show side by side. Press \"Log\" in the P4G panel to see what it said." % [old_spec, new_spec])
		return
	var a := await _p4_exec(["print", "-q", old_spec])
	var b := await _p4_exec(["print", "-q", new_spec])
	if _shutting_down:
		return
	if a.exit_code != 0 or b.exit_code != 0:
		await _show_alert("Godot couldn't download both revisions to compare them. Press \"Log\" in the P4G panel to see what Perforce said.")
		return
	_show_diff("" if a.output.is_empty() else String(a.output[0]),
			"" if b.output.is_empty() else String(b.output[0]), text,
			_history_rev_label(older), _history_rev_label(newer),
			"%s %s - %s" % [String(newer.depot).get_file(), _history_rev_name(older, String(newer.depot)),
					_history_rev_name(newer, String(newer.depot))])


## A submitted revision of res_path beside the file on disk.
func _diff_revision_vs_workspace(res_path: String, rev: Dictionary) -> void:
	var why := _revision_not_diffable_text(rev)
	if not why.is_empty():
		await _show_alert(why)
		return
	var local_path := ProjectSettings.globalize_path(res_path)
	var f := FileAccess.open(local_path, FileAccess.READ)
	if f == null:
		await _show_alert("Godot couldn't read '%s' from your computer, so it can't compare it. Check the file still exists and isn't open in another program." % res_path)
		return
	if f.get_length() > DIFF_MAX_BYTES:
		await _show_alert(_diff_too_big_message(res_path, int(f.get_length())))
		return
	var new_text := f.get_as_text()
	f.close()
	var spec := "%s#%d" % [rev.depot, rev.rev]
	# -f compares a file that isn't checked out too; -E P4DIFF= keeps an
	# external diff tool from taking over (see _diff_path).
	var d := await _p4_exec(["-E", "P4DIFF=", "diff", "-f", "-dul", spec])
	if _shutting_down:
		return
	var text := "" if d.output.is_empty() else String(d.output[0])
	match _diff_verdict(text, int(d.exit_code)):
		"same":
			await _show_alert("'%s' on your computer is identical to revision #%d." % [res_path, rev.rev])
			return
		"changed":
			pass
		_:
			await _show_alert("Godot couldn't compare '%s' with revision #%d. Press \"Log\" in the P4G panel to see what Perforce said." % [res_path, rev.rev])
			return
	var old := await _p4_exec(["print", "-q", spec])
	if _shutting_down:
		return
	if old.exit_code != 0:
		await _show_alert("Godot couldn't download revision #%d of '%s'. Press \"Log\" in the P4G panel to see what Perforce said." % [rev.rev, res_path])
		return
	_show_diff("" if old.output.is_empty() else String(old.output[0]), new_text, text,
			_history_rev_label(rev), DIFF_WORKSPACE_LABEL, res_path)


## Put revision `rev` of res_path on disk in place of the one there (`p4 sync
## -s file#rev`). Refused for a checked-out file: p4 itself won't do it, and
## answers "is opened at a later revision - not changed" with exit 0.
func _get_revision(res_path: String, rev: Dictionary) -> void:
	var stat := await _fetch_fstat_record(res_path)
	if _shutting_down:
		return
	var action := String(stat.get("action", ""))
	if not action.is_empty():
		await _show_alert(("'%s' is checked out (opened for %s), and Perforce can't put an " +
				"older revision in place of a checked-out file. Submit or revert your change " +
				"first, then try again.") % [res_path, action])
		return
	var ok: bool = await _show_confirm_dialog(("Replace '%s' on your computer with revision " +
			"#%d (change %d by %s)?\n\nNothing on the server changes. Get Latest brings the " +
			"file back up to date later.") % [res_path, rev.rev, rev.change, rev.user],
			"Get Revision #%d" % int(rev.rev), "Cancel")
	if not ok:
		return
	var rewrote: bool = await _sync_path(res_path, "%s#%d" % [rev.depot, rev.rev])
	if _shutting_down:
		return
	# What p4 says this workspace has now is the result, whatever the sync's
	# output looked like.
	var have := int((await _fetch_fstat_record(res_path)).get("haveRev", "0"))
	if _shutting_down:
		return
	if rewrote and have == int(rev.rev):
		_log("Got revision #%d of '%s'." % [rev.rev, res_path])
	elif rewrote:
		await _show_alert("Godot asked Perforce for revision #%d of '%s', but Perforce says you now have #%d. Press \"Log\" in the P4G panel to see what it said." \
				% [rev.rev, res_path, have])
	if history_window != null and is_instance_valid(history_window) and _history_res_path == res_path:
		_history_have_rev = have
		_populate_history()
