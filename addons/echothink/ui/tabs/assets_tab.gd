@tool
class_name EchoThinkAssetsTab
extends VBoxContainer


var event_bus: EchoThinkEventBus = null
var asset_service: EchoThinkAssetService = null
var session_manager: EchoThinkSessionManager = null

var _search_edit: LineEdit = null
var _asset_tree: Tree = null
var _detail_view: RichTextLabel = null
var _status_label: Label = null
var _pull_button: Button = null
var _diff_button: Button = null
var _validate_button: Button = null
var _confirmation_dialog: EchoThinkConfirmationDialog = null

var _bundles: Array[AssetBundle] = []
var _asset_rows: Array[Dictionary] = []
var _import_status: Dictionary = {}
var _pending_action: String = ""
var _selected_row_index: int = -1
var _signals_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		call_deferred("refresh")


func initialize(events: EchoThinkEventBus, assets: EchoThinkAssetService, sessions: EchoThinkSessionManager) -> void:
	event_bus = events
	asset_service = assets
	session_manager = sessions
	if is_node_ready():
		_build_ui()
		_connect_signals()
		call_deferred("refresh")


func refresh() -> void:
	if asset_service == null:
		return
	await _search_assets(_search_edit.text.strip_edges())


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.asset_bundle_ready.is_connected(_on_asset_bundle_ready):
		event_bus.asset_bundle_ready.disconnect(_on_asset_bundle_ready)
	if event_bus.asset_imported.is_connected(_on_asset_imported):
		event_bus.asset_imported.disconnect(_on_asset_imported)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 6)
	add_child(search_row)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search remote asset bundles"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.text_submitted.connect(_on_search_submitted)
	search_row.add_child(_search_edit)

	var search_button := Button.new()
	search_button.text = "Search"
	search_button.pressed.connect(_on_search_pressed)
	search_row.add_child(search_button)

	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(refresh)
	search_row.add_child(refresh_button)

	var main_split := HSplitContainer.new()
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_split)

	_asset_tree = Tree.new()
	_asset_tree.columns = 4
	_asset_tree.hide_root = true
	_asset_tree.set_column_titles_visible(true)
	_asset_tree.set_column_title(0, "Name")
	_asset_tree.set_column_title(1, "Local Version")
	_asset_tree.set_column_title(2, "Remote Version")
	_asset_tree.set_column_title(3, "Status")
	_asset_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_asset_tree.item_selected.connect(_on_asset_selected)
	main_split.add_child(_asset_tree)

	var detail_panel := VBoxContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_constant_override("separation", 8)
	main_split.add_child(detail_panel)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "Search for remote asset bundles to inspect details and import options."
	detail_panel.add_child(_status_label)

	_detail_view = RichTextLabel.new()
	_detail_view.fit_content = true
	_detail_view.scroll_active = true
	_detail_view.custom_minimum_size = Vector2(320.0, 360.0)
	_detail_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_child(_detail_view)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	detail_panel.add_child(action_row)

	_pull_button = Button.new()
	_pull_button.text = "Pull"
	_pull_button.disabled = true
	_pull_button.pressed.connect(_on_pull_pressed)
	action_row.add_child(_pull_button)

	_diff_button = Button.new()
	_diff_button.text = "Diff"
	_diff_button.disabled = true
	_diff_button.pressed.connect(_on_diff_pressed)
	action_row.add_child(_diff_button)

	_validate_button = Button.new()
	_validate_button.text = "Validate"
	_validate_button.disabled = true
	_validate_button.pressed.connect(_on_validate_pressed)
	action_row.add_child(_validate_button)

	_confirmation_dialog = EchoThinkConfirmationDialog.new()
	_confirmation_dialog.confirmed.connect(_on_confirmation_confirmed)
	_confirmation_dialog.cancelled.connect(_on_confirmation_cancelled)
	add_child(_confirmation_dialog)

	_ui_built = true


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.asset_bundle_ready.connect(_on_asset_bundle_ready)
	event_bus.asset_imported.connect(_on_asset_imported)
	_signals_connected = true


func _on_search_submitted(_text: String) -> void:
	call_deferred("_on_search_pressed")


func _on_search_pressed() -> void:
	await _search_assets(_search_edit.text.strip_edges())


func _search_assets(query_text: String) -> void:
	if asset_service == null:
		return

	_status_label.text = "Searching remote assets..."
	var query := {
		"query": query_text,
	}
	if session_manager != null:
		var binding := session_manager.get_workspace_binding()
		if binding != null and not binding.workspace_id.is_empty():
			query["workspace_id"] = binding.workspace_id

	_bundles = await asset_service.search_assets(query)
	_flatten_asset_rows()
	_rebuild_asset_tree()
	_status_label.text = "Found %d asset entries across %d bundles." % [_asset_rows.size(), _bundles.size()]


func _on_asset_selected() -> void:
	var item := _asset_tree.get_selected()
	if item == null:
		return
	_selected_row_index = int(item.get_metadata(0))
	_render_selected_asset()


func _on_diff_pressed() -> void:
	if asset_service == null:
		return
	var row := _selected_row()
	if row.is_empty():
		return
	var asset_id := _asset_identifier(row)
	var diff := await asset_service.preview_diff(asset_id)
	_detail_view.clear()
	_detail_view.append_text(JSON.stringify(diff, "\t"))
	_status_label.text = "Diff loaded for %s." % _fallback_text(asset_id, "selected asset")


func _on_pull_pressed() -> void:
	var row := _selected_row()
	if row.is_empty():
		return
	_pending_action = "pull"
	var bundle: AssetBundle = row["bundle"]
	_confirmation_dialog.show_for_asset_pull(bundle)


func _on_validate_pressed() -> void:
	if asset_service == null:
		return
	var row := _selected_row()
	if row.is_empty():
		return
	var bundle: AssetBundle = row["bundle"]
	var results := await asset_service.validate_import(bundle.bundle_id)
	_detail_view.clear()
	_detail_view.append_text(JSON.stringify(results, "\t"))
	_status_label.text = "Validation complete for bundle %s." % _fallback_text(bundle.bundle_id, "(unspecified)")


func _perform_pull() -> void:
	if asset_service == null:
		return
	var row := _selected_row()
	if row.is_empty():
		return

	var asset_id := _asset_identifier(row)
	var asset_ref := _asset_reference(row)
	_pull_button.disabled = true
	_status_label.text = "Pulling asset %s..." % _fallback_text(asset_id, "selected asset")
	var result := await asset_service.pull_asset(asset_id, asset_ref)
	_pull_button.disabled = false
	_detail_view.clear()
	_detail_view.append_text(JSON.stringify(result, "\t"))
	if result.has("error"):
		_status_label.text = "Asset pull failed."
	else:
		_import_status[asset_id] = "pulled"
		_status_label.text = "Asset pull completed for %s." % _fallback_text(asset_id, "selected asset")
		_rebuild_asset_tree()


func _on_asset_bundle_ready(bundle: AssetBundle) -> void:
	var updated := false
	for index in range(_bundles.size()):
		if _bundles[index].bundle_id == bundle.bundle_id:
			_bundles[index] = bundle
			updated = true
			break
	if not updated:
		_bundles.append(bundle)
	_flatten_asset_rows()
	_rebuild_asset_tree()
	_status_label.text = "Asset bundle available: %s" % _fallback_text(bundle.bundle_id, "(unspecified)")


func _on_asset_imported(id: String, success: bool) -> void:
	_import_status[id] = "imported" if success else "import_failed"
	_rebuild_asset_tree()
	_status_label.text = "Asset import %s for %s." % ["succeeded" if success else "failed", _fallback_text(id, "(unspecified)")]


func _on_confirmation_confirmed() -> void:
	if _pending_action == "pull":
		call_deferred("_perform_pull")
	_pending_action = ""


func _on_confirmation_cancelled() -> void:
	_pending_action = ""
	_status_label.text = "Asset operation cancelled."


func _flatten_asset_rows() -> void:
	_asset_rows.clear()
	for bundle in _bundles:
		if bundle.assets.is_empty():
			_asset_rows.append({
				"bundle": bundle,
				"asset": {},
			})
			continue
		for asset in bundle.assets:
			_asset_rows.append({
				"bundle": bundle,
				"asset": asset.duplicate(true),
			})


func _rebuild_asset_tree() -> void:
	if _asset_tree == null:
		return
	_asset_tree.clear()
	var root := _asset_tree.create_item()
	var first_item: TreeItem = null
	var selected_item: TreeItem = null
	for index in range(_asset_rows.size()):
		var row := _asset_rows[index]
		var item := _asset_tree.create_item(root)
		item.set_text(0, _row_name(row))
		item.set_text(1, _row_local_version(row))
		item.set_text(2, _row_remote_version(row))
		item.set_text(3, _row_status(row))
		item.set_metadata(0, index)
		if first_item == null:
			first_item = item
		if index == _selected_row_index:
			selected_item = item

	if selected_item != null:
		selected_item.select(0)
		_render_selected_asset()
	elif first_item != null:
		_selected_row_index = 0
		first_item.select(0)
		_render_selected_asset()
	else:
		_selected_row_index = -1
		_detail_view.clear()
		_pull_button.disabled = true
		_diff_button.disabled = true
		_validate_button.disabled = true


func _render_selected_asset() -> void:
	var row := _selected_row()
	_detail_view.clear()
	if row.is_empty():
		_pull_button.disabled = true
		_diff_button.disabled = true
		_validate_button.disabled = true
		_detail_view.append_text("No asset selected.")
		return

	_pull_button.disabled = false
	_diff_button.disabled = false
	_validate_button.disabled = false

	var bundle: AssetBundle = row["bundle"]
	var asset: Dictionary = row["asset"]
	var lines := PackedStringArray()
	lines.append("Bundle ID: %s" % _fallback_text(bundle.bundle_id, "—"))
	lines.append("Workspace: %s" % _fallback_text(bundle.workspace_id, "—"))
	lines.append("Source Type: %s" % _fallback_text(bundle.source_type, "—"))
	lines.append("License: %s" % _fallback_text(bundle.license_type, "—"))
	lines.append("Attribution Required: %s" % ["yes" if bundle.license_attribution_required else "no"])
	if not asset.is_empty():
		lines.append("")
		lines.append("Asset Path: %s" % _fallback_text(String(asset.get("path", "")), "—"))
		lines.append("Target Path: %s" % _fallback_text(String(asset.get("target_path", "")), "—"))
		lines.append("Kind: %s" % _fallback_text(String(asset.get("kind", "")), "—"))
		lines.append("Import Preset: %s" % _fallback_text(String(asset.get("import_preset", "")), "—"))
		lines.append("Remote Ref: %s" % _fallback_text(_asset_reference(row), "—"))
	_detail_view.append_text(_join_lines(lines))


func _selected_row() -> Dictionary:
	if _selected_row_index < 0 or _selected_row_index >= _asset_rows.size():
		return {}
	return _asset_rows[_selected_row_index]


func _asset_identifier(row: Dictionary) -> String:
	var asset: Dictionary = row.get("asset", {})
	for key in ["asset_id", "id", "path", "target_path"]:
		var value := String(asset.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	var bundle: AssetBundle = row.get("bundle", AssetBundle.new())
	return bundle.bundle_id


func _asset_reference(row: Dictionary) -> String:
	var asset: Dictionary = row.get("asset", {})
	for key in ["ref", "version", "sha256", "remote_version"]:
		var value := String(asset.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return ""


func _row_name(row: Dictionary) -> String:
	var asset: Dictionary = row.get("asset", {})
	var target_path := String(asset.get("target_path", "")).strip_edges()
	if not target_path.is_empty():
		return target_path.get_file()
	var path := String(asset.get("path", "")).strip_edges()
	if not path.is_empty():
		return path.get_file()
	var bundle: AssetBundle = row.get("bundle", AssetBundle.new())
	return _fallback_text(bundle.bundle_id, "Untitled Bundle")


func _row_local_version(row: Dictionary) -> String:
	var asset: Dictionary = row.get("asset", {})
	for key in ["local_version", "local_sha256", "installed_ref"]:
		var value := String(asset.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return "—"


func _row_remote_version(row: Dictionary) -> String:
	var reference := _asset_reference(row)
	return "—" if reference.is_empty() else reference


func _row_status(row: Dictionary) -> String:
	var asset_id := _asset_identifier(row)
	if _import_status.has(asset_id):
		return String(_import_status[asset_id])
	var bundle: AssetBundle = row.get("bundle", AssetBundle.new())
	if _import_status.has(bundle.bundle_id):
		return String(_import_status[bundle.bundle_id])
	var asset: Dictionary = row.get("asset", {})
	return _fallback_text(String(asset.get("status", "available")), "available")


func _join_lines(lines: PackedStringArray) -> String:
	var output := ""
	for index in range(lines.size()):
		output += lines[index]
		if index < lines.size() - 1:
			output += "\n"
	return output


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized
