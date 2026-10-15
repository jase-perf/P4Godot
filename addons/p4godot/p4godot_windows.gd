@tool
extends "p4godot_files.gd"

## The transfer progress window and the side-by-side diff viewer.

var dock: VBoxContainer
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
# Largest file shown side by side, either side. Past this the panes slow the
# editor down and a line-by-line view stops being readable; P4V handles it.
const DIFF_MAX_BYTES := 1024 * 1024
# Base filetypes p4 treats as text (old names included); anything else is
# shown as "not text" without downloading it.
const P4_TEXT_TYPES := ["text", "xtext", "ktext", "kxtext", "ctext", "cxtext", "ltext",
		"xltext", "unicode", "xunicode", "utf8", "xutf8", "utf16", "xutf16", "symlink"]


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
	# -f: compare files that aren't checked out too. Without it p4 answers
	# "file(s) not opened on this client" for a file changed on disk but not
	# checked out - the files Reconcile finds - and that read as "identical".
	if not FileAccess.file_exists(local_path):
		# p4 prints the file's header and no difference for a file that is
		# gone from disk (deleted, opened for delete, the old half of a move).
		await _show_alert("'%s' isn't on your computer any more - it was deleted or moved - so there's nothing to compare." % res_path)
		return
	var local_file := FileAccess.open(local_path, FileAccess.READ)
	var local_size := -1 if local_file == null else int(local_file.get_length())
	local_file = null
	if local_size > DIFF_MAX_BYTES:
		await _show_alert(_diff_too_big_message(res_path, local_size))
		return
	# -E P4DIFF=: with an external diff tool configured, p4 hands the files to
	# that tool and prints only the header, which reads as "no difference".
	var result := await _p4_exec(["-E", "P4DIFF=", "diff", "-f", "-dul", local_path])
	var text := "" if result.output.is_empty() else String(result.output[0])
	var verdict := _diff_verdict(text, int(result.exit_code))
	if verdict == "unknown" and (text.contains("Usage:") or text.contains("Invalid option")):
		# A p4 too old for -E: ask the plain way.
		result = await _p4_exec(["diff", "-f", "-dul", local_path])
		text = "" if result.output.is_empty() else String(result.output[0])
		verdict = _diff_verdict(text, int(result.exit_code))
	if verdict == "new":
		await _show_alert("'%s' isn't on the Perforce server yet, so there's no earlier version to compare it with." % res_path)
		return
	if verdict == "unknown":
		await _show_alert("Godot couldn't compare '%s' with the server's version. Press \"Log\" in the P4G panel to see what Perforce said." % res_path)
		return
	if verdict == "same":
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
	# Size and filetype of the downloaded revision, before downloading it again.
	var have_stat := await _p4_exec(["-ztag", "fstat", "-Ol", depot_path + "#have"])
	var have_check := _diff_have_check(_parse_ztag(have_stat))
	match String(have_check.verdict):
		"binary":
			await _show_alert("'%s' is stored in Perforce as a binary file, so there's nothing to show side by side." % res_path)
			return
		"too big":
			await _show_alert(_diff_too_big_message(res_path, int(have_check.size)))
			return
		"unknown":
			await _show_alert("Godot couldn't look up the server's copy of '%s' to compare against. Press \"Log\" in the P4G panel to see what Perforce said." % res_path)
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
	_show_diff(old_text, new_text, text, "%s#have" % _diff_depot_path(text, res_path),
			"%s (workspace)" % res_path, res_path)


## Show two texts side by side, aligned by `unified` (p4's -du output for the
## same pair), and pop the diff window up.
func _show_diff(old_text: String, new_text: String, unified: String,
		left_label: String, right_label: String, title: String) -> void:
	_diff_rows = _align_diff(_split_lines(old_text), _split_lines(new_text),
			_parse_unified_hunks(unified))
	diff_left_label.text = "  " + left_label
	diff_right_label.text = "  " + right_label
	_render_diff()
	diff_window.title = "P4 Diff: %s" % title
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


## What `p4 diff -f -dul <one file>` found: "changed", "same" (p4 printed the
## file's header and no hunk), "new" (the file was never downloaded from the
## server - untracked, or opened for add), or "unknown" for anything else.
## "same" needs the header as proof: p4 exits 0 on its refusals, so an answer
## this doesn't recognise must not be read as "no difference".
func _diff_verdict(text: String, exit_code: int) -> String:
	if _diff_has_changes(text):
		return "changed"
	if text.contains("file(s) not on client"):
		return "new"
	if exit_code == 0 and _diff_depot_path(text, "").begins_with("//"):
		return "same"
	return "unknown"


## Whether the revision `-ztag fstat -Ol <depot>#have` describes can be shown
## side by side, as {verdict, size}: "ok", "binary" (its filetype isn't text),
## "too big" (over DIFF_MAX_BYTES), or "unknown" (no record: p4 answers
## "file(s) not on client" with exit 0). Decided before the revision is
## downloaded.
func _diff_have_check(records: Array) -> Dictionary:
	for rec in records:
		if rec is Dictionary and rec.has("headType"):
			return _revision_diffable(String(rec.headType), int(rec.get("fileSize", "0")))
	return {"verdict": "unknown", "size": 0}


## Whether a revision of this Perforce filetype and size can be shown side by
## side: {verdict: "ok" | "binary" | "too big", size}.
func _revision_diffable(p4_type: String, size: int) -> Dictionary:
	if not P4_TEXT_TYPES.has(p4_type.get_slice("+", 0)):
		return {"verdict": "binary", "size": size}
	if size > DIFF_MAX_BYTES:
		return {"verdict": "too big", "size": size}
	return {"verdict": "ok", "size": size}


func _diff_too_big_message(res_path: String, size: int) -> String:
	return ("'%s' is %s - too large to show side by side here (the limit is %s). " +
			"Use Diff in P4V for a file this size.") \
			% [res_path, String.humanize_size(size), String.humanize_size(DIFF_MAX_BYTES)]


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


# Past this many differences the line diff below stops looking for the
# shortest edit and shows the changed middle as removed, then added.
const LINE_DIFF_MAX_EDITS := 1500


## A unified diff of two texts' lines, as one hunk covering both, for the
## diff window when p4 can't make one: a file that exists on only one side
## (a shelved add), or a comparison p4 gets wrong (`p4 diff file@=N` on the
## new half of a shelved move read another file's content, measured on
## 2026.1). Only the hunk's operations are read (_parse_unified_hunks); the
## text shown always comes from the files. "" when both are empty.
static func _line_diff_unified(old_lines: PackedStringArray, new_lines: PackedStringArray) -> String:
	if old_lines.is_empty() and new_lines.is_empty():
		return ""
	var ops := _line_diff_ops(old_lines, new_lines)
	var out := "@@ -%d,%d +%d,%d @@\n" % [mini(1, old_lines.size()), old_lines.size(),
			mini(1, new_lines.size()), new_lines.size()]
	var i := 0
	var j := 0
	for op: String in ops:
		match op:
			"ctx":
				out += " " + old_lines[i] + "\n"
				i += 1
				j += 1
			"del":
				out += "-" + old_lines[i] + "\n"
				i += 1
			"add":
				out += "+" + new_lines[j] + "\n"
				j += 1
	return out


## The shortest list of "ctx" / "del" / "add" steps turning `a` into `b`
## (Myers' algorithm), after setting aside the lines both start and end with.
## Past `max_edits` differences it stops looking and calls the middle
## removed, then added: the work grows with the differences times the length.
static func _line_diff_ops(a: PackedStringArray, b: PackedStringArray,
		max_edits: int = LINE_DIFF_MAX_EDITS) -> Array:
	var pre := 0
	while pre < a.size() and pre < b.size() and a[pre] == b[pre]:
		pre += 1
	var suf := 0
	while suf < a.size() - pre and suf < b.size() - pre \
			and a[a.size() - 1 - suf] == b[b.size() - 1 - suf]:
		suf += 1
	var ops: Array = []
	for _i in pre:
		ops.append("ctx")
	ops.append_array(_myers_ops(a.slice(pre, a.size() - suf), b.slice(pre, b.size() - suf), max_edits))
	for _i in suf:
		ops.append("ctx")
	return ops


static func _myers_ops(a: PackedStringArray, b: PackedStringArray, max_edits: int) -> Array:
	var n := a.size()
	var m := b.size()
	var ops: Array = []
	if n == 0 or m == 0:
		for _i in n:
			ops.append("del")
		for _i in m:
			ops.append("add")
		return ops
	var max_d := mini(n + m, max_edits)
	var off := max_d + 1
	# v[k + off]: the furthest x reached on diagonal k. trace[d] is v as it
	# stood before step d, which the walk back needs.
	var v := PackedInt32Array()
	v.resize(2 * off + 1)
	var trace: Array = []
	var found := -1
	for d in max_d + 1:
		trace.append(v.duplicate())
		var k := -d
		while k <= d:
			var x: int
			if k == -d or (k != d and v[k - 1 + off] < v[k + 1 + off]):
				x = v[k + 1 + off]
			else:
				x = v[k - 1 + off] + 1
			var y := x - k
			while x < n and y < m and a[x] == b[y]:
				x += 1
				y += 1
			v[k + off] = x
			if x >= n and y >= m:
				found = d
				break
			k += 2
		if found >= 0:
			break
	if found < 0:
		for _i in n:
			ops.append("del")
		for _i in m:
			ops.append("add")
		return ops
	var x := n
	var y := m
	for d in range(found, 0, -1):
		var vd: PackedInt32Array = trace[d]
		var k := x - y
		var prev_k := k + 1 if (k == -d or (k != d and vd[k - 1 + off] < vd[k + 1 + off])) else k - 1
		var prev_x := vd[prev_k + off]
		var prev_y := prev_x - prev_k
		while x > prev_x and y > prev_y:
			ops.append("ctx")
			x -= 1
			y -= 1
		ops.append("add" if x == prev_x else "del")
		x = prev_x
		y = prev_y
	while x > 0 and y > 0:
		ops.append("ctx")
		x -= 1
		y -= 1
	ops.reverse()
	return ops


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


