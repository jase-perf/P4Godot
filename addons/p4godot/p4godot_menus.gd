@tool
extends "p4godot_dock.gd"

## Perforce in Godot's other right-click menus: a P4 submenu on scene tabs,
## script tabs and the code editor (which adds "Who Changed This Line?"), and
## on a scene tree node, one for each file it comes from - its instanced
## scene and its script. The actions are the FileSystem dock's.
##
## What each slot hands over, read from Godot 4.7-stable's source: scene tabs
## pass [the scene's path] ("" for a scene never saved); script tabs [the
## script's path]; the code editor the CodeEdit's node path, not a file; the
## scene tree the selected nodes' paths relative to the scene root.
## The actions sit in a submenu of our own, whose id_pressed comes to us, so
## nothing depends on what Godot passes to an item's callback.


class P4SlotMenu extends EditorContextMenuPlugin:
	var plugin # the main P4 EditorPlugin (untyped to avoid a cyclic self-type)
	var slot: String

	func _popup_menu(paths: PackedStringArray) -> void:
		if plugin != null:
			plugin._populate_slot_menu(self, slot, paths)


# Id of "Who Changed This Line?" in a submenu; the other ids index
# _fs_context_actions().
const SLOT_WHO_CHANGED_ID := 100

var _slot_menus: Array = []
# Per submenu key: the PopupMenu made for the latest right-click, and what it
# acts on ({res, line}).
var _slot_submenus: Dictionary = {}
var _slot_targets: Dictionary = {}


func _register_editor_menus() -> void:
	if not ClassDB.class_exists("EditorContextMenuPlugin"):
		return
	for pair in [["scene_tabs", EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TABS],
			["script_tabs", EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR],
			["code", EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE],
			["scene_tree", EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE]]:
		var menu := P4SlotMenu.new()
		menu.plugin = self
		menu.slot = String(pair[0])
		add_context_menu_plugin(int(pair[1]), menu)
		_slot_menus.append(menu)
	var ed := EditorInterface.get_script_editor()
	if ed and ed.get_current_script():
		_gutter_activate.call_deferred(ed.get_current_script())


func _unregister_editor_menus() -> void:
	for menu in _slot_menus:
		remove_context_menu_plugin(menu)
	_slot_menus.clear()
	for sub in _slot_submenus.values():
		if is_instance_valid(sub):
			sub.queue_free()
	_slot_submenus.clear()
	_slot_targets.clear()
	_unregister_gutters()


## A file this plugin can act on: a saved res:// file, not a resource built
## into a scene ("scene.tscn::GDScript_x") or a scene never saved ("").
static func _is_project_file(path: String) -> bool:
	return path.begins_with("res://") and not path.contains("::") and not path.ends_with("/")


## The files a scene tree node comes from, other than the open scene itself:
## the scene it is an instance of, and its script.
static func _node_source_files(node: Node, scene_root: Node) -> Array:
	var out: Array = []
	if node == null:
		return out
	if node != scene_root and _is_project_file(node.scene_file_path):
		out.append(node.scene_file_path)
	var scr: Variant = node.get_script()
	if scr is Script and _is_project_file(scr.resource_path) and not out.has(scr.resource_path):
		out.append(scr.resource_path)
	return out


## Called by P4SlotMenu._popup_menu: add the P4 submenus this right-click
## gets. Silent when Perforce is known to be unavailable this session.
func _populate_slot_menu(menu: EditorContextMenuPlugin, slot: String, paths: PackedStringArray) -> void:
	if _identity_checked and not _p4_available:
		return
	match slot:
		"scene_tabs", "script_tabs":
			if paths.size() == 1 and _is_project_file(paths[0]):
				_add_file_submenu(menu, slot, "P4", paths[0], 0)
		"code":
			var ed := EditorInterface.get_script_editor()
			var scr: Script = ed.get_current_script() if ed else null
			if scr == null or not _is_project_file(scr.resource_path):
				return
			var line := 0
			var current := ed.get_current_editor()
			var code := current.get_base_editor() if current else null
			if code is TextEdit:
				line = (code as TextEdit).get_caret_line() + 1
			# One submenu per code editor: each script tab has its own menu,
			# and freeing a submenu another tab's menu still lists is unsafe.
			var key := "code:%s" % (paths[0] if paths.size() == 1 else "")
			_add_file_submenu(menu, key, "P4", scr.resource_path, line, code as TextEdit)
		"scene_tree":
			# Last time's submenus go first: this node may have fewer files.
			for key: String in _slot_submenus.keys():
				if key.begins_with("scene_tree_"):
					var stale: Variant = _slot_submenus[key]
					if stale != null and is_instance_valid(stale):
						(stale as PopupMenu).queue_free()
					_slot_submenus.erase(key)
					_slot_targets.erase(key)
			var root := EditorInterface.get_edited_scene_root()
			if root == null or paths.size() != 1:
				return
			var files := _node_source_files(root.get_node_or_null(NodePath(paths[0])), root)
			for i in files.size():
				_add_file_submenu(menu, "%s_%d" % [slot, i], "P4: %s" % String(files[i]).get_file(), files[i], 0)


## Add a submenu named `title` holding the file actions for res_path, plus
## "Who Changed This Line?" for line `line` (> 0) of the text in `code`.
## A new PopupMenu each time, keyed by the menu it hangs off (a submenu must
## be a child of that menu): Godot clears its menu before asking plugins, so
## the previous one for the same key is no longer referenced and can go.
func _add_file_submenu(menu: EditorContextMenuPlugin, key: String, title: String, res_path: String,
		line: int, code: TextEdit = null) -> void:
	var old: Variant = _slot_submenus.get(key)
	if old != null and is_instance_valid(old):
		(old as PopupMenu).queue_free()
	var sub := PopupMenu.new()
	sub.id_pressed.connect(_on_slot_submenu_id.bind(key))
	if line > 0:
		sub.add_item("Who Changed This Line?", SLOT_WHO_CHANGED_ID)
		sub.add_separator()
	var actions := _fs_context_actions()
	for i in actions.size():
		sub.add_item(String(actions[i].label).trim_prefix("P4: "), i)
	_slot_submenus[key] = sub
	_slot_targets[key] = {"res": res_path, "line": line,
			"code": weakref(code) if code != null else null}
	menu.add_context_submenu_item(title, sub)


func _on_slot_submenu_id(id: int, key: String) -> void:
	var target: Dictionary = _slot_targets.get(key, {})
	if target.is_empty():
		return
	if id == SLOT_WHO_CHANGED_ID:
		# The editor's text, saved or not: the line number is counted in it.
		var ref: Variant = target.get("code")
		var code: Variant = ref.get_ref() if ref is WeakRef else null
		if code is TextEdit:
			await _show_who_changed_line(String(target.res), int(target.line), (code as TextEdit).text, true)
		else:
			await _show_who_changed_line(String(target.res), int(target.line))
		return
	var actions := _fs_context_actions()
	if id >= 0 and id < actions.size():
		call(String(actions[id].method), PackedStringArray([String(target.res)]))


# ---------------------------------------------------------------------------
# Changed-line marks in the code editor
#
# A thin bar beside each line added (green) or changed (blue) since the
# revision this workspace has, and a red tick where lines were removed - the
# editor's text as it is now, saved or not, against `print #have`. The have
# copy is fetched when a script becomes active and after each dock refresh
# (a sync or submit changes it); the comparison runs a moment after typing
# stops (_line_diff_ops).
# ---------------------------------------------------------------------------

const GUTTER_DEBOUNCE_SEC := 0.4
const GUTTER_WIDTH := 4
# The marks are worked out on the editor's own thread after each pause in
# typing, so they give up sooner than a one-off diff: past this many
# differences everything between the unchanged first and last lines is
# marked changed.
const GUTTER_MAX_EDITS := 300

var _gutter_timer: Timer
var _gutter_code: CodeEdit # the code editor being marked
var _gutter_path: String = ""
var _gutter_codes: Array = [] # weakrefs to every CodeEdit given a gutter
var _gutter_fetch_token: int = 0


## Which lines of `now` to mark, against `have` (the revision this workspace
## has): {0-based line: "added" | "changed" | "deleted" | "deleted_end"}.
## A run of removed lines followed by added ones marks as many "changed" as
## it can pair, the rest "added"; removed lines left over put "deleted" on the
## line after them, or "deleted_end" on the last line when nothing follows.
static func _gutter_marks_for(have: PackedStringArray, now: PackedStringArray) -> Dictionary:
	var marks := {}
	var n := 0
	var dels := 0
	var adds: Array = []
	for op: String in _line_diff_ops(have, now, GUTTER_MAX_EDITS):
		match op:
			"ctx":
				_gutter_flush(marks, dels, adds, n, now.size())
				dels = 0
				adds = []
				n += 1
			"del":
				if not adds.is_empty():
					_gutter_flush(marks, dels, adds, n, now.size())
					adds = []
					dels = 0
				dels += 1
			"add":
				adds.append(n)
				n += 1
	_gutter_flush(marks, dels, adds, n, now.size())
	return marks


## Mark one run of `dels` removed lines and the added lines `adds` (0-based
## lines of the new text), ending before line `n` of `line_count`.
static func _gutter_flush(marks: Dictionary, dels: int, adds: Array, n: int, line_count: int) -> void:
	for i in adds.size():
		# A line where an earlier run's removal was marked also stands for it.
		var was_deleted := String(marks.get(adds[i], "")) == "deleted"
		marks[adds[i]] = "changed" if i < dels or was_deleted else "added"
	if dels > adds.size():
		if n < line_count:
			if not marks.has(n):
				marks[n] = "deleted"
		elif line_count > 0 and not marks.has(line_count - 1):
			marks[line_count - 1] = "deleted_end"


func _on_active_script_changed(script: Script) -> void:
	super(script)
	await _gutter_activate(script)


## Mark the script on screen: also run when the plugin starts, since a script
## already open then doesn't announce itself.
func _gutter_activate(script: Script) -> void:
	_gutter_code = null
	_gutter_path = ""
	if script == null or not _is_project_file(script.resource_path):
		return
	var current := EditorInterface.get_script_editor().get_current_editor()
	var code := current.get_base_editor() if current else null
	if not code is CodeEdit:
		return
	_gutter_code = code
	_gutter_path = script.resource_path
	_gutter_attach(_gutter_code)
	await _gutter_fetch_have(_gutter_code, _gutter_path)


## Give `code` the marks gutter (once) and have its edits recompute them.
func _gutter_attach(code: CodeEdit) -> void:
	if _gutter_index(code) >= 0:
		return
	var g := code.get_gutter_count()
	code.add_gutter()
	code.set_gutter_name(g, "p4_changes")
	code.set_gutter_type(g, TextEdit.GUTTER_TYPE_CUSTOM)
	code.set_gutter_width(g, GUTTER_WIDTH)
	code.set_gutter_draw(g, true)
	code.set_gutter_clickable(g, false)
	code.set_gutter_custom_draw(g, _draw_gutter_line.bind(code))
	code.text_changed.connect(_gutter_schedule.bind(code))
	_gutter_codes.append(weakref(code))


## Fetch the revision this workspace has of res_path into `code`'s meta, then
## mark. A file never submitted, or stored as binary, gets no marks.
func _gutter_fetch_have(code: CodeEdit, res_path: String) -> void:
	_gutter_fetch_token += 1
	var token := _gutter_fetch_token
	if _identity_checked and not _p4_available:
		return
	var stat := await _fetch_fstat_record(res_path)
	if _shutting_down or token != _gutter_fetch_token or not is_instance_valid(code):
		return
	# Downloaded again only when the revision it's based on changed: a
	# refresh follows every save and checkout.
	var base := _base_revision_of(stat)
	var key := "%s@%s" % [base, stat.get("haveRev", "")]
	if base.is_empty() or _revision_diffable(String(stat.get("headType", stat.get("type", ""))), 0).verdict == "binary":
		for meta in ["p4_have_lines", "p4_have_key"]:
			if code.has_meta(meta):
				code.remove_meta(meta)
	elif String(code.get_meta("p4_have_key", "")) != key:
		var printed := await _p4_exec(["print", "-q", base])
		if _shutting_down or token != _gutter_fetch_token or not is_instance_valid(code):
			return
		if printed.exit_code != 0:
			return
		code.set_meta("p4_have_lines", _split_lines("" if printed.output.is_empty() else String(printed.output[0])))
		code.set_meta("p4_have_key", key)
	_gutter_update(code)


func _gutter_schedule(code: CodeEdit) -> void:
	if _gutter_timer == null or not is_instance_valid(_gutter_timer):
		_gutter_timer = Timer.new()
		_gutter_timer.one_shot = true
		_gutter_timer.timeout.connect(func() -> void:
			if _gutter_code != null and is_instance_valid(_gutter_code):
				_gutter_update(_gutter_code))
		add_child(_gutter_timer)
	if code == _gutter_code:
		_gutter_timer.start(GUTTER_DEBOUNCE_SEC)


func _gutter_update(code: CodeEdit) -> void:
	var marks := {}
	if code.has_meta("p4_have_lines"):
		marks = _gutter_marks_for(code.get_meta("p4_have_lines"), _split_lines(code.text))
	code.set_meta("p4_gutter_marks", marks)
	code.queue_redraw()


func _draw_gutter_line(line: int, _gutter: int, area: Rect2, code: CodeEdit) -> void:
	var marks: Dictionary = code.get_meta("p4_gutter_marks", {})
	match String(marks.get(line, "")):
		"added":
			code.draw_rect(Rect2(area.position.x, area.position.y, GUTTER_WIDTH - 1, area.size.y), ACTION_ADD_COLOR)
		"changed":
			code.draw_rect(Rect2(area.position.x, area.position.y, GUTTER_WIDTH - 1, area.size.y), ACTION_EDIT_COLOR)
		"deleted":
			code.draw_rect(Rect2(area.position.x, area.position.y - 1, area.size.x, 2), ACTION_DELETE_COLOR)
		"deleted_end":
			code.draw_rect(Rect2(area.position.x, area.end.y - 1, area.size.x, 2), ACTION_DELETE_COLOR)


## A refresh follows syncs, submits and reverts, any of which can change the
## revision this workspace has of the script on screen.
func _rebuild_tree(model: Dictionary) -> void:
	super(model)
	if _gutter_code != null and is_instance_valid(_gutter_code) and not _gutter_path.is_empty():
		_gutter_fetch_have(_gutter_code, _gutter_path)


## The marks gutter's index in `code`, by name: other plugins can add and
## remove gutters before it. -1 when it has none.
static func _gutter_index(code: TextEdit) -> int:
	for i in code.get_gutter_count():
		if code.get_gutter_name(i) == "p4_changes":
			return i
	return -1


func _unregister_gutters() -> void:
	for ref in _gutter_codes:
		var code: CodeEdit = ref.get_ref()
		if code == null:
			continue
		var g := _gutter_index(code)
		if g >= 0:
			code.remove_gutter(g)
		for key in ["p4_have_lines", "p4_have_key", "p4_gutter_marks"]:
			if code.has_meta(key):
				code.remove_meta(key)
		# Only the marks' own handler: the files layer listens here too.
		for c in code.text_changed.get_connections():
			var cb := Callable(c.callable)
			if cb.get_object() == self and cb.get_method() == &"_gutter_schedule":
				code.text_changed.disconnect(cb)
	_gutter_codes.clear()
	_gutter_code = null
