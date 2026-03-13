@tool
class_name EchoThinkTasksTab
extends VBoxContainer


var editor_context: EchoThinkEditorContext = null

var event_bus: EchoThinkEventBus = null
var task_service: EchoThinkTaskService = null
var session_manager: EchoThinkSessionManager = null

var _task_list: ItemList = null
var _task_detail_view: RichTextLabel = null
var _plan_tree: Tree = null
var _plan_status_label: Label = null
var _request_plan_button: Button = null
var _accept_plan_button: Button = null
var _filter_group: ButtonGroup = null

var _all_tasks: Array[TaskEnvelope] = []
var _visible_tasks: Array[TaskEnvelope] = []
var _current_task: TaskEnvelope = null
var _current_plan: PlanRevision = null
var _filter_mode: String = "all"
var _signals_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		_queue_refresh()


func initialize(events: EchoThinkEventBus, tasks: EchoThinkTaskService, sessions: EchoThinkSessionManager) -> void:
	event_bus = events
	task_service = tasks
	session_manager = sessions
	if is_node_ready():
		_build_ui()
		_connect_signals()
		_queue_refresh()


func refresh() -> void:
	if task_service == null:
		return

	var selected_work_item_id := _current_task.work_item_id if _current_task != null else ""
	_all_tasks = await task_service.get_task_list()
	_sort_tasks_by_priority()
	_rebuild_task_list(selected_work_item_id)


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.task_updated.is_connected(_on_task_updated):
		event_bus.task_updated.disconnect(_on_task_updated)
	if event_bus.plan_ready.is_connected(_on_plan_ready):
		event_bus.plan_ready.disconnect(_on_plan_ready)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	add_child(toolbar)

	_filter_group = ButtonGroup.new()
	toolbar.add_child(_create_filter_button("All", "all"))
	toolbar.add_child(_create_filter_button("Actionable", "actionable"))
	toolbar.add_child(_create_filter_button("Pending Approval", "pending_approval"))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_queue_refresh)
	toolbar.add_child(refresh_button)

	var main_split := HSplitContainer.new()
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_split)

	var left_panel := VBoxContainer.new()
	left_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_panel.add_theme_constant_override("separation", 6)
	main_split.add_child(left_panel)

	var queue_label := Label.new()
	queue_label.text = "Task Queue"
	left_panel.add_child(queue_label)

	_task_list = ItemList.new()
	_task_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_task_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_task_list.item_selected.connect(_on_task_selected)
	left_panel.add_child(_task_list)

	var right_panel := VBoxContainer.new()
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_theme_constant_override("separation", 8)
	main_split.add_child(right_panel)

	_task_detail_view = RichTextLabel.new()
	_task_detail_view.bbcode_enabled = true
	_task_detail_view.fit_content = true
	_task_detail_view.custom_minimum_size = Vector2(320.0, 180.0)
	_task_detail_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.add_child(_task_detail_view)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	right_panel.add_child(action_row)

	_request_plan_button = Button.new()
	_request_plan_button.text = "Request Plan"
	_request_plan_button.pressed.connect(_on_request_plan_pressed)
	action_row.add_child(_request_plan_button)

	_accept_plan_button = Button.new()
	_accept_plan_button.text = "Accept Plan"
	_accept_plan_button.disabled = true
	_accept_plan_button.pressed.connect(_on_accept_plan_pressed)
	action_row.add_child(_accept_plan_button)

	_plan_status_label = Label.new()
	_plan_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plan_status_label.text = "No plan selected."
	right_panel.add_child(_plan_status_label)

	_plan_tree = Tree.new()
	_plan_tree.columns = 2
	_plan_tree.hide_root = true
	_plan_tree.set_column_titles_visible(true)
	_plan_tree.set_column_title(0, "Plan Element")
	_plan_tree.set_column_title(1, "Details")
	_plan_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(_plan_tree)

	_ui_built = true
	_filter_mode = "all"


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.task_updated.connect(_on_task_updated)
	event_bus.plan_ready.connect(_on_plan_ready)
	_signals_connected = true


func _queue_refresh() -> void:
	call_deferred("_refresh_deferred")


func _refresh_deferred() -> void:
	await refresh()


func _on_task_selected(index: int) -> void:
	if index < 0 or index >= _visible_tasks.size():
		return
	_current_task = _visible_tasks[index]
	call_deferred("_load_selected_task_details")


func _load_selected_task_details() -> void:
	if _current_task == null or task_service == null:
		return
	var detailed_task := await task_service.get_task_details(_current_task.work_item_id)
	if not detailed_task.work_item_id.is_empty():
		_current_task = detailed_task
	_render_task_details(_current_task)
	if _current_plan != null and _current_plan.work_item_id == _current_task.work_item_id:
		_display_plan(_current_plan)


func _on_request_plan_pressed() -> void:
	if task_service == null:
		return

	var snapshot := ProjectContextSnapshot.create_empty()
	if editor_context != null:
		snapshot = editor_context.capture_snapshot()

	_request_plan_button.disabled = true
	_plan_status_label.text = "Requesting plan revision from the gateway..."
	var plan_request_id := await task_service.request_plan(snapshot)
	_request_plan_button.disabled = false
	if plan_request_id.is_empty():
		_plan_status_label.text = "Plan request failed."
		return
	_plan_status_label.text = "Plan request submitted: %s" % plan_request_id


func _on_accept_plan_pressed() -> void:
	if _current_plan == null or task_service == null:
		return

	_accept_plan_button.disabled = true
	var selected_tasks: Array[int] = []
	for index in range(_current_plan.tasks.size()):
		selected_tasks.append(index)
	var accepted := await task_service.accept_plan(_current_plan.plan_id, selected_tasks)
	_accept_plan_button.disabled = false
	_plan_status_label.text = "Plan accepted." if accepted else "Plan acceptance failed."


func _on_task_updated(task: TaskEnvelope) -> void:
	var replaced := false
	for index in range(_all_tasks.size()):
		if _all_tasks[index].work_item_id == task.work_item_id:
			_all_tasks[index] = task
			replaced = true
			break
	if not replaced:
		_all_tasks.append(task)
	_sort_tasks_by_priority()
	_rebuild_task_list(task.work_item_id)


func _on_plan_ready(plan: PlanRevision) -> void:
	if _current_task != null and not plan.work_item_id.is_empty() and plan.work_item_id != _current_task.work_item_id and _current_plan != null and _current_plan.plan_id != plan.plan_id:
		return
	_current_plan = plan
	_display_plan(plan)


func _create_filter_button(title_text: String, mode: String) -> Button:
	var button := Button.new()
	button.text = title_text
	button.toggle_mode = true
	button.button_group = _filter_group
	button.set_meta("filter_mode", mode)
	button.toggled.connect(_on_filter_toggled.bind(button))
	if mode == "all":
		button.button_pressed = true
	return button


func _on_filter_toggled(pressed: bool, button: Button) -> void:
	if not pressed:
		return
	_filter_mode = String(button.get_meta("filter_mode", "all"))
	_rebuild_task_list(_current_task.work_item_id if _current_task != null else "")


func _rebuild_task_list(selected_work_item_id: String) -> void:
	if _task_list == null:
		return

	_visible_tasks.clear()
	_task_list.clear()
	for task in _all_tasks:
		if not _matches_filter(task):
			continue
		_visible_tasks.append(task)
		_task_list.add_item(_format_task_row(task))

	if _visible_tasks.is_empty():
		_current_task = null
		_render_task_details(null)
		return

	var selected_index := 0
	for index in range(_visible_tasks.size()):
		if _visible_tasks[index].work_item_id == selected_work_item_id:
			selected_index = index
			break

	_task_list.select(selected_index)
	_current_task = _visible_tasks[selected_index]
	_render_task_details(_current_task)


func _matches_filter(task: TaskEnvelope) -> bool:
	match _filter_mode:
		"actionable":
			return task.is_actionable()
		"pending_approval":
			return task.requires_approval()
		_:
			return true


func _format_task_row(task: TaskEnvelope) -> String:
	return "[%s] P%d • %s" % [
		_fallback_text(task.status, "pending").to_upper(),
		task.priority,
		_trim_text(task.objective, 72)
	]


func _render_task_details(task: TaskEnvelope) -> void:
	if _task_detail_view == null:
		return
	_task_detail_view.clear()
	if task == null:
		_task_detail_view.append_text("[b]No task selected.[/b]")
		return

	var lines := PackedStringArray()
	lines.append("[b]Objective[/b]")
	lines.append(_escape_bbcode(_fallback_text(task.objective, "No objective provided.")))
	lines.append("")
	lines.append("[b]Metadata[/b]")
	lines.append("Work Item: %s" % _escape_bbcode(_fallback_text(task.work_item_id, "—")))
	lines.append("Task Run: %s" % _escape_bbcode(_fallback_text(task.task_run_id, "—")))
	lines.append("Kind: %s" % _escape_bbcode(_fallback_text(task.kind, "—")))
	lines.append("Status: %s" % _escape_bbcode(_fallback_text(task.status, "pending")))
	lines.append("Risk: %s" % _escape_bbcode(_fallback_text(task.risk_level, "unspecified")))
	lines.append("Approval Policy: %s" % _escape_bbcode(_fallback_text(task.approval_policy, "automatic")))
	lines.append("Assigned Worker: %s" % _escape_bbcode(_fallback_text(task.assigned_worker, "unassigned")))
	lines.append("")
	lines.append("[b]Acceptance Criteria[/b]")
	if task.acceptance_criteria.is_empty():
		lines.append("• None specified")
	else:
		for criterion in task.acceptance_criteria:
			lines.append("• %s" % _escape_bbcode(criterion))

	_task_detail_view.append_text(_join_lines(lines))


func _display_plan(plan: PlanRevision) -> void:
	if _plan_tree == null:
		return
	_plan_tree.clear()
	var root := _plan_tree.create_item()
	var tasks_root := _plan_tree.create_item(root)
	tasks_root.set_text(0, "Tasks")
	tasks_root.set_text(1, "%d items" % plan.tasks.size())
	for task in plan.tasks:
		var task_item := _plan_tree.create_item(tasks_root)
		task_item.set_text(0, _plan_task_title(task))
		task_item.set_text(1, _plan_task_status(task))

	var dependencies_root := _plan_tree.create_item(root)
	dependencies_root.set_text(0, "Dependencies")
	dependencies_root.set_text(1, "%d links" % plan.dependencies.size())
	for dependency in plan.dependencies:
		var dependency_item := _plan_tree.create_item(dependencies_root)
		dependency_item.set_text(0, _fallback_text(String(dependency.get("from", dependency.get("task_id", "dependency"))), "dependency"))
		dependency_item.set_text(1, _fallback_text(String(dependency.get("to", dependency.get("depends_on", ""))), "—"))

	var criteria_root := _plan_tree.create_item(root)
	criteria_root.set_text(0, "Acceptance Criteria")
	criteria_root.set_text(1, "%d checks" % plan.acceptance_criteria.size())
	for criterion in plan.acceptance_criteria:
		var criterion_item := _plan_tree.create_item(criteria_root)
		criterion_item.set_text(0, criterion)

	var risks_root := _plan_tree.create_item(root)
	risks_root.set_text(0, "Risks")
	risks_root.set_text(1, "%d items" % plan.risks.size())
	for risk in plan.risks:
		var risk_item := _plan_tree.create_item(risks_root)
		risk_item.set_text(0, _fallback_text(String(risk.get("title", risk.get("risk", "Risk"))), "Risk"))
		risk_item.set_text(1, _fallback_text(String(risk.get("level", risk.get("severity", ""))), "unspecified"))

	_plan_status_label.text = "Plan %s • revision %d • %d tasks • status: %s" % [
		_fallback_text(plan.plan_id, "(unspecified)"),
		plan.revision,
		plan.get_task_count(),
		_fallback_text(plan.status, "draft")
	]
	_accept_plan_button.disabled = plan.plan_id.strip_edges().is_empty()


func _plan_task_title(task: Dictionary) -> String:
	for key in ["title", "name", "objective", "summary", "task_id"]:
		var value := String(task.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return "Task"


func _plan_task_status(task: Dictionary) -> String:
	var status := String(task.get("status", "pending")).strip_edges()
	var owner := String(task.get("owner", task.get("assigned_to", ""))).strip_edges()
	if owner.is_empty():
		return _fallback_text(status, "pending")
	return "%s • %s" % [_fallback_text(status, "pending"), owner]


func _sort_tasks_by_priority() -> void:
	var sorted: Array[TaskEnvelope] = []
	for task in _all_tasks:
		var insert_index := sorted.size()
		for index in range(sorted.size()):
			if task.priority > sorted[index].priority:
				insert_index = index
				break
			if task.priority == sorted[index].priority and task.updated_at > sorted[index].updated_at:
				insert_index = index
				break
		sorted.insert(insert_index, task)
	_all_tasks = sorted


func _join_lines(lines: PackedStringArray) -> String:
	var output := ""
	for index in range(lines.size()):
		output += lines[index]
		if index < lines.size() - 1:
			output += "\n"
	return output


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "\\[").replace("]", "\\]")


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized


func _trim_text(text: String, max_length: int) -> String:
	var normalized := text.strip_edges()
	if normalized.length() <= max_length:
		return normalized
	return "%s…" % normalized.substr(0, max_length - 1)
