@tool
class_name EchoThinkPatchesTab
extends VBoxContainer


var event_bus: EchoThinkEventBus = null
var patch_service: EchoThinkPatchService = null
var change_set_manager: EchoThinkChangeSetManager = null
var policy_guard: EchoThinkPolicyGuard = null

var _patch_tree: Tree = null
var _risk_badge: EchoThinkRiskBadge = null
var _summary_label: Label = null
var _file_tree: Tree = null
var _operation_tree: Tree = null
var _diff_view: RichTextLabel = null
var _history_list: ItemList = null
var _status_label: Label = null
var _apply_button: Button = null
var _rollback_button: Button = null
var _confirmation_dialog: EchoThinkConfirmationDialog = null

var _patch_queue: Array[PatchProposal] = []
var _history_cache: Array[ChangeSet] = []
var _current_patch: PatchProposal = null
var _current_changeset: ChangeSet = null
var _pending_action: String = ""
var _signals_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		_display_changeset_history()


func initialize(events: EchoThinkEventBus, patches: EchoThinkPatchService, changesets: EchoThinkChangeSetManager, policy: EchoThinkPolicyGuard) -> void:
	event_bus = events
	patch_service = patches
	change_set_manager = changesets
	policy_guard = policy
	if is_node_ready():
		_build_ui()
		_connect_signals()
		_display_changeset_history()


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.patch_ready.is_connected(_on_patch_ready):
		event_bus.patch_ready.disconnect(_on_patch_ready)
	if event_bus.patch_applied.is_connected(_on_patch_applied):
		event_bus.patch_applied.disconnect(_on_patch_applied)
	if event_bus.patch_rolled_back.is_connected(_on_patch_rolled_back):
		event_bus.patch_rolled_back.disconnect(_on_patch_rolled_back)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	var main_split := VSplitContainer.new()
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_split)

	var upper_split := HSplitContainer.new()
	upper_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upper_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_split.add_child(upper_split)

	var queue_panel := VBoxContainer.new()
	queue_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	queue_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	queue_panel.add_theme_constant_override("separation", 6)
	upper_split.add_child(queue_panel)

	var queue_label := Label.new()
	queue_label.text = "Patch Queue"
	queue_panel.add_child(queue_label)

	_patch_tree = Tree.new()
	_patch_tree.columns = 3
	_patch_tree.hide_root = true
	_patch_tree.set_column_titles_visible(true)
	_patch_tree.set_column_title(0, "Patch")
	_patch_tree.set_column_title(1, "Ops")
	_patch_tree.set_column_title(2, "Risk")
	_patch_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_patch_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_patch_tree.item_selected.connect(_on_patch_selected)
	queue_panel.add_child(_patch_tree)

	var detail_panel := VBoxContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_constant_override("separation", 8)
	upper_split.add_child(detail_panel)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "Awaiting patch proposals."
	detail_panel.add_child(_status_label)

	_risk_badge = EchoThinkRiskBadge.new()
	detail_panel.add_child(_risk_badge)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.text = "Select a patch proposal to inspect its operations and affected files."
	detail_panel.add_child(_summary_label)

	_file_tree = Tree.new()
	_file_tree.columns = 1
	_file_tree.hide_root = true
	_file_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_file_tree.custom_minimum_size = Vector2(320.0, 120.0)
	detail_panel.add_child(_file_tree)

	_operation_tree = Tree.new()
	_operation_tree.columns = 3
	_operation_tree.hide_root = true
	_operation_tree.set_column_titles_visible(true)
	_operation_tree.set_column_title(0, "Operation")
	_operation_tree.set_column_title(1, "Path")
	_operation_tree.set_column_title(2, "Risk")
	_operation_tree.custom_minimum_size = Vector2(320.0, 160.0)
	_operation_tree.item_selected.connect(_on_operation_selected)
	detail_panel.add_child(_operation_tree)

	_diff_view = RichTextLabel.new()
	_diff_view.fit_content = true
	_diff_view.scroll_active = true
	_diff_view.custom_minimum_size = Vector2(320.0, 180.0)
	_diff_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_child(_diff_view)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	detail_panel.add_child(action_row)

	_apply_button = Button.new()
	_apply_button.text = "Apply Patch"
	_apply_button.disabled = true
	_apply_button.pressed.connect(_on_apply_pressed)
	action_row.add_child(_apply_button)

	_rollback_button = Button.new()
	_rollback_button.text = "Rollback ChangeSet"
	_rollback_button.disabled = true
	_rollback_button.pressed.connect(_on_rollback_pressed)
	action_row.add_child(_rollback_button)

	var history_panel := VBoxContainer.new()
	history_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_panel.add_theme_constant_override("separation", 6)
	main_split.add_child(history_panel)

	var history_label := Label.new()
	history_label.text = "ChangeSet History"
	history_panel.add_child(history_label)

	_history_list = ItemList.new()
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.item_selected.connect(_on_history_selected)
	history_panel.add_child(_history_list)

	_confirmation_dialog = EchoThinkConfirmationDialog.new()
	_confirmation_dialog.confirmed.connect(_on_confirmation_confirmed)
	_confirmation_dialog.cancelled.connect(_on_confirmation_cancelled)
	add_child(_confirmation_dialog)

	_ui_built = true


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.patch_ready.connect(_on_patch_ready)
	event_bus.patch_applied.connect(_on_patch_applied)
	event_bus.patch_rolled_back.connect(_on_patch_rolled_back)
	_signals_connected = true


func _on_patch_ready(patch: PatchProposal) -> void:
	var replaced := false
	for index in range(_patch_queue.size()):
		if _patch_queue[index].patch_id == patch.patch_id:
			_patch_queue[index] = patch
			replaced = true
			break
	if not replaced:
		_patch_queue.append(patch)
	_rebuild_patch_queue(patch.patch_id)
	_status_label.text = "Received patch proposal %s." % _fallback_text(patch.patch_id, "(unspecified)")


func _on_apply_pressed() -> void:
	if _current_patch == null:
		return
	if not _is_patch_allowed(_current_patch):
		_status_label.text = "Patch contains operations that are blocked by the active policy profile."
		return

	var overall_risk := _assess_patch_risk(_current_patch)
	if policy_guard != null and policy_guard.requires_confirmation(overall_risk):
		_pending_action = "apply"
		_confirmation_dialog.show_for_patch(_current_patch, overall_risk)
		return
	call_deferred("_perform_apply")


func _on_rollback_pressed() -> void:
	if _current_changeset == null:
		_current_changeset = change_set_manager.get_last_applied() if change_set_manager != null else null
	if _current_changeset == null:
		_status_label.text = "No applied changeset is available for rollback."
		return
	_pending_action = "rollback"
	_confirmation_dialog.show_for_rollback(_current_changeset)


func _perform_apply() -> void:
	if _current_patch == null or patch_service == null:
		return
	_apply_button.disabled = true
	_status_label.text = "Applying patch %s..." % _fallback_text(_current_patch.patch_id, "(unspecified)")
	var applied_changeset := await patch_service.apply_patch(_current_patch, [])
	_apply_button.disabled = false
	if applied_changeset.status == ChangeSet.STATUS_FAILED:
		_status_label.text = "Patch apply failed: %s" % _fallback_text(applied_changeset.error_message, "Unknown error")
		return
	_status_label.text = "Patch applied as ChangeSet %s." % _fallback_text(applied_changeset.changeset_id, "(unspecified)")


func _perform_rollback() -> void:
	if _current_changeset == null or patch_service == null:
		return
	_rollback_button.disabled = true
	var rolled_back := await patch_service.rollback_changeset(_current_changeset.changeset_id)
	_rollback_button.disabled = false
	_status_label.text = "Rollback completed." if rolled_back else "Rollback failed."


func _display_patch_details(patch: PatchProposal) -> void:
	_current_patch = patch
	var risk := _assess_patch_risk(patch)
	_risk_badge.set_risk(risk)
	_summary_label.text = "Patch %s • %d operations • %d files • base %s" % [
		_fallback_text(patch.patch_id, "(unspecified)"),
		patch.get_operation_count(),
		patch.get_affected_files().size(),
		_fallback_text(patch.base_branch, patch.base_commit)
	]
	_apply_button.disabled = false

	_file_tree.clear()
	var file_root := _file_tree.create_item()
	for path in patch.get_affected_files():
		var file_item := _file_tree.create_item(file_root)
		file_item.set_text(0, path)

	_operation_tree.clear()
	var operation_root := _operation_tree.create_item()
	for index in range(patch.operations.size()):
		var operation := patch.operations[index]
		var item := _operation_tree.create_item(operation_root)
		item.set_text(0, _operation_title(operation))
		item.set_text(1, _operation_path(operation))
		item.set_text(2, _risk_to_text(_assess_operation_risk(operation)))
		item.set_metadata(0, index)

	if not patch.operations.is_empty():
		_render_operation_diff(patch.operations[0])
	else:
		_diff_view.clear()


func _display_changeset_history() -> void:
	if _history_list == null:
		return
	_history_list.clear()
	_history_cache.clear()
	if change_set_manager == null:
		_history_list.add_item("ChangeSet manager unavailable.")
		return

	for changeset in change_set_manager.get_all_changesets():
		_history_cache.append(changeset)
		_history_list.add_item("[%s] %s • %d ops • %s" % [
			changeset.status.to_upper(),
			changeset.changeset_id,
			changeset.operations.size(),
			_fallback_text(changeset.timestamp, "n/a")
		])

	if _history_cache.is_empty():
		_history_list.add_item("No changesets recorded yet.")
		_current_changeset = null
		_rollback_button.disabled = true
		return

	var last_index := _history_cache.size() - 1
	_history_list.select(last_index)
	_current_changeset = _history_cache[last_index]
	_rollback_button.disabled = not _current_changeset.is_rollbackable()


func _on_patch_applied(changeset: ChangeSet) -> void:
	if _current_patch != null:
		_remove_current_patch_from_queue()
	_display_changeset_history()
	_current_changeset = changeset
	_rollback_button.disabled = not changeset.is_rollbackable()
	_status_label.text = "Patch applied successfully: %s" % _fallback_text(changeset.changeset_id, "(unspecified)")


func _on_patch_rolled_back(changeset_id: String) -> void:
	_display_changeset_history()
	_status_label.text = "ChangeSet rolled back: %s" % _fallback_text(changeset_id, "(unspecified)")


func _on_patch_selected() -> void:
	var item := _patch_tree.get_selected()
	if item == null:
		return
	var patch_index := int(item.get_metadata(0))
	if patch_index < 0 or patch_index >= _patch_queue.size():
		return
	_display_patch_details(_patch_queue[patch_index])


func _on_operation_selected() -> void:
	if _current_patch == null:
		return
	var item := _operation_tree.get_selected()
	if item == null:
		return
	var operation_index := int(item.get_metadata(0))
	if operation_index < 0 or operation_index >= _current_patch.operations.size():
		return
	_render_operation_diff(_current_patch.operations[operation_index])


func _on_history_selected(index: int) -> void:
	if index < 0 or index >= _history_cache.size():
		return
	_current_changeset = _history_cache[index]
	_rollback_button.disabled = not _current_changeset.is_rollbackable()
	_diff_view.clear()
	_diff_view.append_text(JSON.stringify(_current_changeset.to_dict(), "\t"))


func _on_confirmation_confirmed() -> void:
	match _pending_action:
		"apply":
			call_deferred("_perform_apply")
		"rollback":
			call_deferred("_perform_rollback")
	_pending_action = ""


func _on_confirmation_cancelled() -> void:
	_pending_action = ""
	_status_label.text = "Operation cancelled."


func _rebuild_patch_queue(selected_patch_id: String = "") -> void:
	if _patch_tree == null:
		return
	_patch_tree.clear()
	var root := _patch_tree.create_item()
	var first_item: TreeItem = null
	var target_item: TreeItem = null
	for index in range(_patch_queue.size()):
		var patch := _patch_queue[index]
		var item := _patch_tree.create_item(root)
		item.set_text(0, _fallback_text(patch.patch_id, "(unspecified)"))
		item.set_text(1, str(patch.get_operation_count()))
		item.set_text(2, _risk_to_text(_assess_patch_risk(patch)))
		item.set_metadata(0, index)
		if first_item == null:
			first_item = item
		if patch.patch_id == selected_patch_id:
			target_item = item

	if target_item != null:
		target_item.select(0)
		_on_patch_selected()
	elif first_item != null:
		first_item.select(0)
		_on_patch_selected()
	else:
		_current_patch = null
		_apply_button.disabled = true


func _render_operation_diff(operation: Dictionary) -> void:
	if _diff_view == null:
		return
	_diff_view.clear()
	for key in ["patch", "diff", "unified_diff", "content", "preview"]:
		if operation.has(key):
			_diff_view.append_text(String(operation.get(key, "")))
			return
	_diff_view.append_text(JSON.stringify(operation, "\t"))


func _remove_current_patch_from_queue() -> void:
	if _current_patch == null:
		return
	for index in range(_patch_queue.size()):
		if _patch_queue[index].patch_id == _current_patch.patch_id:
			_patch_queue.remove_at(index)
			break
	_rebuild_patch_queue()


func _is_patch_allowed(patch: PatchProposal) -> bool:
	if policy_guard == null:
		return true
	for operation in patch.operations:
		if not policy_guard.is_operation_allowed(operation):
			return false
	return true


func _assess_patch_risk(patch: PatchProposal) -> EchoThinkPolicyGuard.RiskLevel:
	var highest := EchoThinkPolicyGuard.RiskLevel.LOW
	for operation in patch.operations:
		highest = _max_risk(highest, _assess_operation_risk(operation))
	if patch.has_high_risk_operations():
		highest = _max_risk(highest, EchoThinkPolicyGuard.RiskLevel.HIGH)
	return highest


func _assess_operation_risk(operation: Dictionary) -> EchoThinkPolicyGuard.RiskLevel:
	if policy_guard == null:
		return EchoThinkPolicyGuard.RiskLevel.MEDIUM
	return policy_guard.assess_risk(operation)


func _max_risk(left: EchoThinkPolicyGuard.RiskLevel, right: EchoThinkPolicyGuard.RiskLevel) -> EchoThinkPolicyGuard.RiskLevel:
	return right if int(right) > int(left) else left


func _operation_title(operation: Dictionary) -> String:
	var action := String(operation.get("action", operation.get("op", operation.get("operation", "")))).strip_edges()
	var operation_type := String(operation.get("type", operation.get("operation_type", operation.get("kind", "operation")))).strip_edges()
	if action.is_empty():
		return _fallback_text(operation_type, "operation")
	return "%s (%s)" % [action, _fallback_text(operation_type, "operation")]


func _operation_path(operation: Dictionary) -> String:
	for key in ["path", "target_path", "file_path", "resource_path", "scene_path", "asset_path"]:
		var value := String(operation.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return "—"


func _risk_to_text(risk: EchoThinkPolicyGuard.RiskLevel) -> String:
	match risk:
		EchoThinkPolicyGuard.RiskLevel.LOW:
			return "LOW"
		EchoThinkPolicyGuard.RiskLevel.MEDIUM:
			return "MEDIUM"
		EchoThinkPolicyGuard.RiskLevel.HIGH:
			return "HIGH"
		_:
			return "CRITICAL"


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized
