@tool
extends "p4godot_shelves.gd"

## The P4G dock: toolbar, changelist tree, the actions on its rows, and the
## FileSystem dock menu and tooltips.

# A light P4 brand accent over Godot's native theme (from the Perforce Force UI
# palette). The dock otherwise uses editor theme colors/icons so it reads native.
const P4_ACCENT := Color("00cfff") # cyan - tints the changelist icons

# How long a hovered file's cached p4 status stays fresh before the next hover
# triggers a background refresh (see _prefetch_fstat).
const FSTAT_CACHE_TTL_SEC := 5.0


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
var log_window: Window
var tree: Tree
var context_menu: PopupMenu
var move_submenu: PopupMenu
var new_changelist_button: Button
var get_latest_button: Button
var reconcile_button: Button
var revert_unchanged_button: Button
var shelves_button: Button
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

# Native FileSystem-dock hooks (Godot's EditorContextMenuPlugin /
# EditorResourceTooltipPlugin), registered in _enter_tree. GDScript-reachable -
# no GDExtension required.
var _fs_context_menu: P4FileSystemContextMenu
var _fs_tooltip: P4FileSystemTooltip

# Metadata dict of the row a context-menu action targets (captured at right-click
# so the action still knows its subject after the menu closes the selection).
var _context_target: Dictionary = {}
# Parallel to the move submenu's items: index -> target change key ("default", a
# number, or "__new__"). Rebuilt each time the submenu is populated.
var _move_targets: Array = []

# Guards for the changelist-tree refresh coroutine. It awaits several p4 calls,
# during which another mutation or a visibility event can fire - _refresh_inflight
# coalesces those into a single in-flight refresh plus at most one re-run
# (_refresh_pending), so the tree can't end stale and clicks can't stack.
var _refresh_inflight: bool = false
var _refresh_pending: bool = false
var _fstat_prefetch_inflight: Dictionary = {}
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
	shelves_button = _add_toolbar_button(_toolbar_actions, "", "Shelves...",
			"Browse shelved changelists - yours and your team's - to review them side by side or unshelve them into your workspace.",
			_on_shelves_pressed)

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
	auto_checkout_checkbox.text = "Check out on edit"
	auto_checkout_checkbox.tooltip_text = "Offer to check out a file the moment it is first modified in the editor."
	auto_checkout_checkbox.button_pressed = true
	auto_checkout_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(auto_checkout_checkbox)

	checkout_on_save_checkbox = CheckBox.new()
	checkout_on_save_checkbox.text = "Check out on save"
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
	auto_open_checkbox.text = "Check out, delete and move without asking"
	auto_open_checkbox.tooltip_text = "When on, edits, deletes, and moves/renames are opened in Perforce automatically, with no confirmation dialog. When off, deletes and moves prompt first (and edits follow 'Checkout on edit')."
	auto_open_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(auto_open_checkbox)

	detect_external_checkbox = CheckBox.new()
	detect_external_checkbox.text = "Watch the workspace for changes"
	detect_external_checkbox.tooltip_text = WATCH_TOOLTIP
	detect_external_checkbox.button_pressed = true
	detect_external_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(detect_external_checkbox)

	auto_checkout_detected_checkbox = CheckBox.new()
	auto_checkout_detected_checkbox.text = "Check out changed files automatically"
	auto_checkout_detected_checkbox.tooltip_text = AUTO_CHECKOUT_DETECTED_TOOLTIP
	auto_checkout_detected_checkbox.button_pressed = true
	auto_checkout_detected_checkbox.toggled.connect(_on_setting_toggled)
	settings_row.add_child(auto_checkout_detected_checkbox)

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


## Menu id of the one settings-menu item that isn't a checkbox (ids 0-5 are).
const SETTINGS_MENU_CONNECTION := 10
const SETTINGS_MENU_CHECKBOXES := 6

const WATCH_TOOLTIP := "Look for files changed by any program (Photoshop, Blender, a text editor) anywhere in the workspace - when Godot regains focus, and every half minute or so."
const AUTO_CHECKOUT_DETECTED_TOOLTIP := "Open what the watcher finds in Perforce without asking: edits, new files, deleted files and renames. When off, they are listed in the P4G panel under \"Changed, not checked out\", to open one by one."


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
	# Grouped by where the change happens, under headings, so a setting's
	# neighbours explain it.
	popup.add_separator("Editing in Godot")
	popup.add_check_item("Check out on edit", 0)
	popup.add_check_item("Check out on save", 1)
	popup.add_check_item("Check out, delete and move without asking", 2)
	popup.add_separator("Other programs")
	popup.add_check_item("Watch the workspace for changes", 3)
	popup.add_check_item("Check out changed files automatically", 5)
	popup.add_separator("Workspace")
	_add_workspace_settings(popup)
	popup.add_item("Connection Settings...", SETTINGS_MENU_CONNECTION)
	popup.add_separator("Troubleshooting")
	popup.add_check_item("Verbose log", 4)
	for pair in [[0, "Offer to check out a file the moment it is first modified in the editor."],
			[1, "Check out edited files right before the editor writes them."],
			[2, "Check out, mark for delete and record moves of files you change in Godot without asking first."],
			[3, WATCH_TOOLTIP],
			[5, AUTO_CHECKOUT_DETECTED_TOOLTIP],
			[4, "Log read-only status queries too, not just commands that change something."],
			[SETTINGS_MENU_CONNECTION, "Change the Perforce server, user, or workspace this project uses."]]:
		popup.set_item_tooltip(popup.get_item_index(int(pair[0])), String(pair[1]))
	popup.about_to_popup.connect(_sync_settings_menu)
	popup.id_pressed.connect(_on_settings_menu_id_pressed)
	parent.add_child(settings_menu)


## Settings about the workspace itself, above Connection Settings. The watch
## layer adds its allwrite switch here.
func _add_workspace_settings(_popup: PopupMenu) -> void:
	pass


func _settings_menu_checkbox(id: int) -> CheckBox:
	match id:
		0: return auto_checkout_checkbox
		1: return checkout_on_save_checkbox
		2: return auto_open_checkbox
		3: return detect_external_checkbox
		4: return verbose_log_checkbox
		5: return auto_checkout_detected_checkbox
	return null


func _sync_settings_menu() -> void:
	var popup := settings_menu.get_popup()
	for id in SETTINGS_MENU_CHECKBOXES:
		var cb := _settings_menu_checkbox(id)
		popup.set_item_checked(popup.get_item_index(id), cb != null and cb.button_pressed)
	# Checking out what the watcher finds means nothing while it isn't watching.
	popup.set_item_disabled(popup.get_item_index(5), not detect_external_checkbox.button_pressed)


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


func _on_clear_log_pressed() -> void:
	log_box.text = ""


## Builds the log window (a Window child of the dock, hidden by default) hosting
## log_box plus a Clear button. A Window - not an AcceptDialog - because the log
## is a non-modal, resizable, leave-it-open panel; AcceptDialog would drag in
## modal semantics and the _dialog_busy serialization used for real prompts.
func _build_log_window() -> void:
	log_window = Window.new()
	log_window.title = "P4Godot - Log"
	log_window.size = Vector2i(Vector2(900, 480) * EditorInterface.get_editor_scale())
	log_window.visible = false
	# Closing HIDES (never frees) so log_box survives to keep receiving _log().
	log_window.close_requested.connect(_on_log_window_close_requested)

	var log_root := VBoxContainer.new()
	log_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	log_window.add_child(log_root)

	var log_tools := HBoxContainer.new()
	log_root.add_child(log_tools)
	_add_toolbar_button(log_tools, "ActionCopy", "Copy All",
			"Copy the whole log, to paste into a bug report or a message to whoever runs your server.",
			_on_copy_log_pressed)
	_add_toolbar_button(log_tools, "", "Clear Log", "Empty the P4 activity log.", _on_clear_log_pressed)

	log_box = TextEdit.new()
	log_box.editable = false
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Commands and paths are long: wrap them rather than cut them off.
	log_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	var mono := EditorInterface.get_base_control().get_theme_font("source", "EditorFonts")
	if mono:
		log_box.add_theme_font_override("font", mono)
	log_root.add_child(log_box)

	# Child of dock, so dock.queue_free() in _exit_tree() cascades to it.
	dock.add_child(log_window)


func _on_copy_log_pressed() -> void:
	DisplayServer.clipboard_set(log_box.text)


func _on_toggle_log_pressed() -> void:
	if log_window.visible:
		log_window.hide()
	else:
		log_window.popup_centered()


func _on_log_window_close_requested() -> void:
	log_window.hide()


# ---------------------------------------------------------------------------
# Changelist tree
# ---------------------------------------------------------------------------

func _build_tree() -> void:
	tree = Tree.new()
	tree.hide_root = true
	tree.columns = 2
	# No header row: the rows say what they are, and the bottom panel is short.
	tree.set_column_titles_visible(false)
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, int(90 * EditorInterface.get_editor_scale()))
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
	_build_empty_state()

	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	dock.add_child(context_menu)

	# Submenu of "Move to Changelist". Items fire the submenu's own id_pressed
	# (not the parent's), so route it through the same handler.
	move_submenu = PopupMenu.new()
	move_submenu.id_pressed.connect(_on_context_menu_id_pressed)
	context_menu.add_child(move_submenu)


## Shown over the tree when Perforce isn't reachable: what's wrong and the one
## button that fixes it, instead of a row to double-click.
var _empty_state: CenterContainer


func _build_empty_state() -> void:
	_empty_state = CenterContainer.new()
	_empty_state.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_state.visible = false
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = "P4Godot isn't connected to Perforce."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(label)
	var button := Button.new()
	button.text = "Set Up Connection..."
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.pressed.connect(_offer_connection_setup)
	column.add_child(button)
	_empty_state.add_child(column)
	tree.add_child(_empty_state)


## Rebuild the whole tree from a model snapshot (see _query_pending_model). Cheap
## enough to clear-and-rebuild - the opened set is small and this only runs on
## refresh, not per frame.
func _rebuild_tree(model: Dictionary) -> void:
	if tree == null:
		return
	_last_changelists = model.get("changelists", [])
	tree.clear()
	var root := tree.create_item()
	if _empty_state:
		_empty_state.visible = not model.get("available", false)
	if not model.get("available", false):
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
		var shelved: Array = cl.get("shelved", [])
		cl_item.set_metadata(0, {"type": "cl", "change": cl.change, "desc": cl.desc,
				"file_count": cl.files.size(), "shelved_count": shelved.size()})
		if folder_icon:
			cl_item.set_icon(0, folder_icon)
			cl_item.set_icon_modulate(0, P4_ACCENT) # the P4 brand touch
		for f in cl.files:
			var f_item := tree.create_item(cl_item)
			f_item.set_text(0, _tree_label(String(f.res_path)))
			f_item.set_tooltip_text(0, "%s\n%s" % [f.res_path, f.depot_path])
			if bool(f.get("unresolved", false)):
				# Another version - a teammate's newer one, or a shelf
				# unshelved onto this one - is waiting to be combined with
				# it; the server refuses the submit until it is.
				f_item.set_text(0, "%s  (needs resolve)" % _tree_label(String(f.res_path)))
				f_item.set_custom_color(0, _action_color("delete"))
				f_item.set_tooltip_text(0, ("%s\n%s\nAnother version of this file - a teammate's, " +
						"or a shelf you unshelved - is waiting to be combined with yours. Right-click " +
						"and choose \"Resolve...\" to combine the two versions.") % [f.res_path, f.depot_path])
			f_item.set_text(1, f.action)
			f_item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
			f_item.set_custom_color(1, _action_color(f.action))
			f_item.set_selectable(1, false)
			var icon := _file_icon(f.res_path)
			if icon:
				f_item.set_icon(0, icon)
			f_item.set_metadata(0, {"type": "file", "res_path": f.res_path,
					"depot_path": f.depot_path, "action": f.action, "change": f.change,
					"unresolved": bool(f.get("unresolved", false))})
		if not shelved.is_empty():
			# The shelf: copies of files on the server, not open here. A row
			# of its own, so its files never read as checked out.
			var shelf_item := tree.create_item(cl_item)
			shelf_item.set_text(0, "Shelved")
			shelf_item.set_text(1, "%d file%s" % [shelved.size(), "" if shelved.size() == 1 else "s"])
			shelf_item.set_custom_color(0, dim)
			shelf_item.set_custom_color(1, dim)
			shelf_item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
			shelf_item.set_selectable(1, false)
			shelf_item.set_tooltip_text(0, ("Copies of these files are shelved on the server in " +
					"changelist #%s, for review or to pick up later. Right-click for what you can do " +
					"with them.") % cl.change)
			var shelf_icon := _theme_icon("Load")
			if shelf_icon:
				shelf_item.set_icon(0, shelf_icon)
				shelf_item.set_icon_modulate(0, dim)
			shelf_item.set_metadata(0, {"type": "shelf", "change": cl.change})
			for s in shelved:
				var s_item := tree.create_item(shelf_item)
				var shown := String(s.res_path).trim_prefix("res://") if not String(s.res_path).is_empty() \
						else String(s.depot_path)
				s_item.set_text(0, shown)
				s_item.set_tooltip_text(0, "%s\nshelved in changelist #%s" % [s.depot_path, cl.change])
				s_item.set_custom_color(0, dim)
				s_item.set_text(1, s.action)
				s_item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
				s_item.set_custom_color(1, _action_color(s.action))
				s_item.set_selectable(1, false)
				var s_icon := _file_icon(shown)
				if s_icon:
					s_item.set_icon(0, s_icon)
					s_item.set_icon_modulate(0, Color(1, 1, 1, 0.6))
				s_item.set_metadata(0, {"type": "shelved_file", "res_path": s.res_path,
						"depot_path": s.depot_path, "action": s.action, "change": cl.change})


## A file's name in the tree. res:// is implied for project files; dropping
## it leaves more room for the paths themselves. A file elsewhere in the
## workspace is shown relative to the project folder ("../art/hero.psd"), so
## it reads as the neighbour it is. The tooltip keeps the full story.
func _tree_label(key: String) -> String:
	if key.begins_with("res://"):
		return key.trim_prefix("res://")
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


func _editor_bold_font() -> Font:
	var base := EditorInterface.get_base_control()
	if base and base.has_theme_font("bold", "EditorFonts"):
		return base.get_theme_font("bold", "EditorFonts")
	return null


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
	if meta.get("type") == "shelved_file":
		_diff_shelved_row(meta, false)
		return
	if meta.get("type") != "file":
		return
	_open_res_path(meta.res_path)


func _open_res_path(res_path: String) -> void:
	if not res_path.begins_with("res://"):
		# Outside the project Godot can't edit it. Shown in the file manager,
		# not opened: opening a .bat, .js or .exe would run it.
		OS.shell_show_in_file_manager(res_path)
		return
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
	CTX_RESOLVE,
	CTX_HISTORY,
	CTX_SHELVE,
	CTX_SHELVE_REVERT,
	CTX_UNSHELVE,
	CTX_DELETE_SHELF,
	CTX_SHELF_DIFF,
	CTX_SHELF_DIFF_WORKSPACE,
	CTX_SHELF_WINDOW,
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
	var m := context_menu
	# Grouped: look, then organise, then change the file on disk, with the
	# one that throws work away last and apart. Icons are the editor's own.
	if kind == "file":
		if bool(meta.get("unresolved", false)):
			_menu_add(m, "StatusWarning", "Resolve...", CTX_RESOLVE)
			m.add_separator()
		_menu_add(m, "Load", "Open", CTX_OPEN)
		_menu_add(m, "Search", "Diff vs Depot", CTX_DIFF)
		_menu_add(m, "History", "History...", CTX_HISTORY)
		m.add_separator()
		_populate_move_submenu(String(meta.get("change", "")))
		m.add_submenu_node_item("Move to Changelist", move_submenu)
		m.add_separator()
		_menu_add(m, "ArrowDown", "Get Latest Version", CTX_SYNC)
		_menu_add(m, "Reload", "Reload From Disk", CTX_RELOAD)
		m.add_separator()
		_menu_add(m, "UndoRedo", "Revert...", CTX_REVERT)
		m.add_separator()
	elif kind == "cl":
		var fc := int(meta.get("file_count", -1)) # -1 (unknown) is treated non-empty
		var shelved := int(meta.get("shelved_count", 0))
		if fc != 0:
			_menu_add(m, "ArrowUp", "Submit Changelist...", CTX_SUBMIT)
		# Editing the default changelist's description promotes it to a numbered one.
		_menu_add(m, "Edit", "Edit Description...", CTX_EDIT_DESC)
		if fc != 0 or shelved > 0:
			m.add_separator()
		if fc != 0:
			_menu_add(m, "Save", "Update Shelf..." if shelved > 0 else "Shelve Files...", CTX_SHELVE)
			_menu_add(m, "", "Shelve and Revert...", CTX_SHELVE_REVERT)
		if shelved > 0:
			_menu_add(m, "Load", "Unshelve Files...", CTX_UNSHELVE)
			_menu_add(m, "Remove", "Delete Shelved Files...", CTX_DELETE_SHELF)
		# Perforce won't delete a changelist that still has a shelf.
		if String(meta.get("change", "")) != "default" and fc == 0 and shelved == 0:
			m.add_separator()
			_menu_add(m, "Remove", "Delete Changelist", CTX_DELETE_CL)
		m.add_separator()
	elif kind == "shelf":
		_menu_add(m, "Load", "Unshelve Files...", CTX_UNSHELVE)
		_menu_add(m, "", "Show in Shelves Window", CTX_SHELF_WINDOW)
		m.add_separator()
		_menu_add(m, "Remove", "Delete Shelved Files...", CTX_DELETE_SHELF)
		m.add_separator()
	elif kind == "shelved_file":
		_menu_add(m, "Search", "Diff vs Base", CTX_SHELF_DIFF)
		_menu_add(m, "", "Diff vs Workspace", CTX_SHELF_DIFF_WORKSPACE)
		m.add_separator()
		_menu_add(m, "Load", "Unshelve This File...", CTX_UNSHELVE)
		_menu_add(m, "Remove", "Delete From Shelf...", CTX_DELETE_SHELF)
		m.add_separator()
	_menu_add(m, "Reload", "Refresh", CTX_REFRESH)


## A menu item with an editor-theme icon when the theme has one by that name.
func _menu_add(menu: PopupMenu, icon_name: String, label: String, id: int) -> void:
	var icon: Texture2D = null if icon_name.is_empty() else _theme_icon(icon_name)
	if icon:
		menu.add_icon_item(icon, label, id)
	else:
		menu.add_item(label, id)


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
		CTX_HISTORY:
			if meta.has("res_path"):
				await _show_history(meta.res_path)
		CTX_RESOLVE:
			if meta.has("res_path"):
				await _resolve_flow([meta.res_path])
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
		CTX_SHELVE, CTX_SHELVE_REVERT:
			if meta.get("type") == "cl":
				await _shelve_changelist(String(meta.change), id == CTX_SHELVE_REVERT)
		CTX_UNSHELVE:
			if meta.has("change"):
				var shelf := await _read_shelf(String(meta.change))
				if shelf.get("files", []).is_empty():
					await _show_alert("Changelist #%s has no shelved files any more." % meta.change)
					_request_refresh()
				else:
					var only: Array = [String(meta.depot_path)] if meta.get("type") == "shelved_file" else []
					await _unshelve(shelf, only, String(meta.change))
		CTX_DELETE_SHELF:
			if meta.has("change"):
				var only: Array = [String(meta.depot_path)] if meta.get("type") == "shelved_file" else []
				await _delete_shelf(String(meta.change), only)
		CTX_SHELF_DIFF, CTX_SHELF_DIFF_WORKSPACE:
			if meta.get("type") == "shelved_file":
				await _diff_shelved_row(meta, id == CTX_SHELF_DIFF_WORKSPACE)
		CTX_SHELF_WINDOW:
			if meta.has("change"):
				await _show_shelves(String(meta.change))
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
			revert_unchanged_button, shelves_button]:
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
	# A moved file is two records, the old path (move/delete) and the new one
	# (move/add). p4 undoes both when asked to revert the new path, and refuses
	# the old one alone with "has been moved, not reverted" and exit 0. So a
	# move is always reverted through its new path.
	if not await _ensure_identity():
		await _show_alert(NOT_CONNECTED_MESSAGE)
		return
	var looked: Dictionary = await _p4_exec(["-ztag", "fstat", ProjectSettings.globalize_path(res_path)])
	var looked_recs := _parse_ztag(looked)
	var rec: Dictionary = looked_recs[0] if not looked_recs.is_empty() else {}
	if not rec.has("depotFile") and (int(looked.exit_code) != 0 or _server_unreachable()):
		# No answer is not "this file isn't in Perforce".
		await _show_alert(("Godot couldn't ask Perforce about '%s', so nothing was reverted. " +
				"Press \"Log\" in the P4G panel to see what went wrong.") % res_path)
		return
	var action := String(rec.get("action", ""))
	if action.is_empty():
		await _revert_unopened(res_path, rec)
		return
	# A moved .import / .uid row: undo the move of the file it belongs to,
	# which takes this one with it. Alone, it would leave the pair split.
	if action.begins_with("move/"):
		for suffix: String in [".import", ".uid"]:
			if res_path.ends_with(suffix):
				var owner_res := res_path.trim_suffix(suffix)
				var owner_action := String((await _fetch_fstat_record(owner_res)).get("action", ""))
				if owner_action == action:
					await _revert_path(owner_res)
					return
	var targets := PackedStringArray([ProjectSettings.globalize_path(res_path)])
	var old_res := ""
	var new_res := ""
	if action == "move/delete" or action == "move/add":
		var other := await _other_half_of_move(rec)
		if other.is_empty():
			await _show_alert(("'%s' is half of a move, and Godot couldn't find the other " +
					"half, so it left both alone. Press \"Log\" in the P4G panel to see what " +
					"Perforce said.") % res_path)
			return
		if action == "move/delete":
			old_res = res_path
			new_res = String(other.res_path)
			targets[0] = String(other.depot_path)
		else:
			old_res = String(other.res_path)
			new_res = res_path
	# The .import / .uid Godot keeps beside a file goes back with it. Left
	# behind after an undone move, it would sit at the new path with nothing
	# to describe, and Godot would write a fresh one at the old path.
	var companions: Array = []
	for sidecar: String in _sidecars_of(res_path):
		var side_rec := await _fetch_fstat_record(sidecar)
		var side_action := String(side_rec.get("action", ""))
		if side_action.is_empty():
			continue
		if side_action == "move/delete":
			var side_other := await _other_half_of_move(side_rec)
			if side_other.is_empty():
				continue
			targets.append(String(side_other.depot_path))
		else:
			targets.append(ProjectSettings.globalize_path(sidecar))
		companions.append(sidecar.get_file())
	var question := ("Throw away your changes to '%s'?\n\nPerforce puts this file back to the " +
			"version on the server. Everything you changed is lost - what you saved as " +
			"well as anything unsaved in the editor - and this can't be undone.") % res_path
	if not new_res.is_empty():
		question = ("Undo the move of '%s' to '%s'?\n\nPerforce puts the file back at its " +
				"old place with the version on the server, and removes it from the new " +
				"place. Everything you changed in it is lost - what you saved as well as " +
				"anything unsaved in the editor - and this can't be undone.") % [old_res, new_res]
	if not companions.is_empty():
		question += "\n\nThe same goes for %s, which Godot keeps beside it." % " and ".join(companions)
	if not old_res.is_empty() and FileAccess.file_exists(ProjectSettings.globalize_path(old_res)):
		# Measured: p4 writes the old file back over whatever is there, without
		# its usual refusal to overwrite a writable file.
		await _show_alert(("There is a file at '%s' now, where the moved file used to be. " +
				"Undoing the move would overwrite it, so nothing was changed. Move or delete " +
				"that file first, then revert again.") % old_res)
		return
	var proceed: bool = await _show_confirm_dialog(question,
			"Undo Move" if not new_res.is_empty() else "Throw Away My Changes", "Cancel")
	if not proceed:
		_log("Revert of '%s' cancelled." % res_path)
		return
	var result := await _p4_exec_logged(PackedStringArray(["revert"]) + targets)
	var text := "" if result.output.is_empty() else String(result.output[0])
	if not _revert_did_something(text, int(result.exit_code)):
		_request_refresh()
		await _show_alert(("Perforce didn't revert '%s'. Nothing was changed. Press \"Log\" in " +
				"the P4G panel to see what it said.") % res_path)
		return
	_forget_path(res_path)
	for sidecar: String in _sidecars_of(res_path):
		_forget_path(sidecar)
	if new_res.is_empty():
		await _reload_path(res_path)
		return
	_forget_path(old_res)
	_forget_path(new_res)
	EditorInterface.get_resource_filesystem().scan()
	_request_refresh()


## "Revert" on a file that isn't checked out. There is nothing for p4 revert
## to do, but the user may still have something to throw away: a file changed
## or deleted on disk without a checkout (a save outside Godot, or with
## checkout on save turned off). `p4 sync -f <file>#have` puts back the version
## that was downloaded.
func _revert_unopened(res_path: String, rec: Dictionary) -> void:
	var depot := String(rec.get("depotFile", ""))
	if depot.is_empty() or not String(rec.get("haveRev", "")).is_valid_int():
		await _show_alert(("'%s' isn't on the Perforce server, so there's no earlier version " +
				"to go back to.") % res_path)
		return
	var global_path := ProjectSettings.globalize_path(res_path)
	var missing := not FileAccess.file_exists(global_path)
	if not missing:
		var diff := await _p4_exec(["-E", "P4DIFF=", "diff", "-f", "-dul", global_path])
		var verdict := _diff_verdict("" if diff.output.is_empty() else String(diff.output[0]),
				int(diff.exit_code))
		if verdict == "same":
			await _show_alert(("'%s' isn't checked out and matches the version you downloaded, " +
					"so there's nothing to throw away.") % res_path)
			return
		if verdict != "changed":
			await _show_alert(("'%s' isn't checked out, and Godot couldn't tell whether it " +
					"differs from the version you downloaded. Press \"Log\" in the P4G panel " +
					"to see what Perforce said.") % res_path)
			return
	var proceed: bool = await _show_confirm_dialog(
			(("'%s' was deleted from your computer." if missing
			else "'%s' was changed on your computer without being checked out.") +
			"\n\nPut back the version you downloaded from the server? " +
			"Your changes to it are lost, and this can't be undone.") % res_path,
			"Put It Back", "Cancel")
	if not proceed:
		_log("Revert of '%s' cancelled." % res_path)
		return
	var result := await _p4_exec_logged(["sync", "-f", depot + "#have"])
	var text := "" if result.output.is_empty() else String(result.output[0])
	if int(result.exit_code) != 0 or not (text.contains(" - refreshing ") or text.contains(" - added as ")):
		await _show_alert(("Perforce didn't put '%s' back. Press \"Log\" in the P4G panel to " +
				"see what it said.") % res_path)
		return
	_forget_path(res_path)
	EditorInterface.get_resource_filesystem().scan()
	await _reload_path(res_path)


## The other record of a move, from one half's fstat record: {res_path,
## depot_path}, or {} when it can't be found. `movedFile` is a depot path.
func _other_half_of_move(rec: Dictionary) -> Dictionary:
	var depot := String(rec.get("movedFile", ""))
	if depot.is_empty():
		return {}
	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", depot]))
	if recs.is_empty():
		return {}
	var local := String(recs[0].get("clientFile", ""))
	if local.is_empty():
		return {}
	var res := _local_to_res(local)
	return {"res_path": res if not res.is_empty() else local, "depot_path": depot}


## Whether `p4 revert`'s answer shows a file actually reverted. p4 exits 0 when
## it refuses ("has been moved, not reverted", "file(s) not opened on this
## client"), so the exit code alone proves nothing.
func _revert_did_something(text: String, exit_code: int) -> bool:
	# Every file p4 reverts gets a "<file> - was <action>, <what happened>" line.
	return exit_code == 0 and not text.contains("not reverted") and text.contains(" - was ")


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
	for sub in _fs_submenus:
		if is_instance_valid(sub):
			sub.queue_free()
	_fs_submenus.clear()
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
		{"label": "Check Out", "method": "_ctx_checkout", "icon": "Edit"},
		{"label": "Mark for Add", "method": "_ctx_add", "icon": "Add"},
		{"label": "Diff vs Depot", "method": "_ctx_diff", "icon": "Search"},
		{"label": "History...", "method": "_ctx_history", "icon": "History"},
		{"label": "Get Latest Version", "method": "_ctx_sync", "icon": "ArrowDown"},
		{"label": "Revert...", "method": "_ctx_revert", "icon": "UndoRedo"},
		{"label": "Show Status in Log", "method": "_ctx_status", "icon": ""},
	]


# The FileSystem dock's P4 submenus, newest last, and the files the newest
# acts on. The dock has two popups (tree and file list) that each keep the
# submenu they were last given, so the two newest stay alive.
var _fs_submenus: Array[PopupMenu] = []
var _fs_submenu_paths: PackedStringArray


## Called by P4FileSystemContextMenu._popup_menu: add the Perforce actions to the
## dock's right-click menu when the selection contains at least one file. Silent
## when Perforce is known-unavailable this session.
func _populate_fs_context_menu(menu: EditorContextMenuPlugin, paths: PackedStringArray) -> void:
	if _identity_checked and not _p4_available:
		return
	if _fs_files_only(paths).is_empty():
		return
	# One "P4" submenu, as on script tabs, scene tabs, the code editor and the
	# scene tree, rather than seven items crowding Godot's own menu. A new one
	# each time: Godot clears its menu before asking plugins.
	# Each popup is cleared and refilled before it is shown again, so a third
	# submenu means the oldest belongs to a popup that has since moved on.
	while _fs_submenus.size() >= 2:
		var old: PopupMenu = _fs_submenus.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var sub := PopupMenu.new()
	_fs_submenus.append(sub)
	_fs_submenu_paths = paths
	var actions := _fs_context_actions()
	for i in actions.size():
		_menu_add(sub, String(actions[i].icon), String(actions[i].label), i)
	sub.id_pressed.connect(_on_fs_submenu_id)
	menu.add_context_submenu_item("P4", sub)


func _on_fs_submenu_id(id: int) -> void:
	var actions := _fs_context_actions()
	if id >= 0 and id < actions.size():
		call(String(actions[id].method), _fs_submenu_paths)


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
	var files := _fs_files_only(paths)
	if files.size() == 1:
		await _add_path(files[0])
		return
	# Several files: one summary at the end, not a dialog per file.
	var by_outcome := {"added": [], "ignored": [], "tracked": [], "failed": []}
	for res in files:
		var outcome := await _add_path(res, false)
		if outcome.is_empty():
			return # not connected; already said so
		by_outcome[outcome].append(res)
	var summary := _add_summary_text(by_outcome)
	if not summary.is_empty():
		await _show_alert(summary)


## What to tell the user after Mark for Add on several files, or "" when
## every one of them was added and there is nothing to explain.
func _add_summary_text(by_outcome: Dictionary) -> String:
	var added: Array = by_outcome.get("added", [])
	var parts: Array = []
	var notes := {
		"ignored": "Left out by your ignore rules",
		"tracked": "Already in Perforce, so there was nothing to add",
		"failed": "Refused by Perforce (press \"Log\" in the P4G panel to see why)",
	}
	for key: String in ["ignored", "tracked", "failed"]:
		var names: Array = by_outcome.get(key, [])
		if names.is_empty():
			continue
		var shown: Array = names.slice(0, 8)
		var lines := "\n".join(shown.map(func(n: Variant) -> String: return "    " + String(n)))
		if names.size() > shown.size():
			lines += "\n    ...and %d more" % (names.size() - shown.size())
		parts.append("%s (%d):\n%s" % [notes[key], names.size(), lines])
	if parts.is_empty():
		return ""
	return "Marked %d of %d files for add.\n\n%s" % [added.size(),
			added.size() + int(by_outcome.get("ignored", []).size())
			+ int(by_outcome.get("tracked", []).size()) + int(by_outcome.get("failed", []).size()),
			"\n\n".join(parts)]


## History opens for the first file selected: it is a window per file.
func _ctx_history(paths: PackedStringArray) -> void:
	var files := _fs_files_only(paths)
	if not files.is_empty():
		await _show_history(files[0])


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
		_add_tooltip_label(base, "head is #%s - out of date" % head, _action_color("delete"))
	if rec.has("action"):
		_add_tooltip_label(base, "opened for %s" % rec.get("action"), _action_color(String(rec.get("action"))))
	if rec.has("ourLock"):
		_add_tooltip_label(base, "locked by you", _action_color("edit"))
	var others := _fstat_other_openers(rec)
	if not others.is_empty():
		_add_tooltip_label(base, "also open by %s" % ", ".join(others), _action_color("delete"))


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


