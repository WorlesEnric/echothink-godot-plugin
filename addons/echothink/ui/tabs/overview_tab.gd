@tool
class_name EchoThinkOverviewTab
extends VBoxContainer


var event_bus: EchoThinkEventBus = null
var session_manager: EchoThinkSessionManager = null
var task_service: EchoThinkTaskService = null
var log_service: EchoThinkLogService = null

var _workspace_labels: Dictionary = {}
var _connection_indicator: EchoThinkStatusIndicator = null
var _task_summary_label: Label = null
var _recent_activity_list: ItemList = null
var _approvals_list: ItemList = null
var _errors_list: ItemList = null

var _recent_tasks: Array[TaskEnvelope] = []
var _pending_approvals: Dictionary = {}
var _recent_errors: Array[String] = []
var _signals_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		_queue_refresh()


func initialize(events: EchoThinkEventBus, sessions: EchoThinkSessionManager, tasks: EchoThinkTaskService, logs: EchoThinkLogService) -> void:
	event_bus = events
	session_manager = sessions
	task_service = tasks
	log_service = logs
	if is_node_ready():
		_build_ui()
		_connect_signals()
		_queue_refresh()


func refresh() -> void:
	_build_ui()
	_update_workspace_section()
	_update_connection_state()
	await _refresh_task_summary()
	await _refresh_pending_approvals()
	_rebuild_recent_activity_list()
	_rebuild_error_list()


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.task_updated.is_connected(_on_task_updated):
		event_bus.task_updated.disconnect(_on_task_updated)
	if event_bus.approval_pending.is_connected(_on_approval_pending):
		event_bus.approval_pending.disconnect(_on_approval_pending)
	if event_bus.approval_decided.is_connected(_on_approval_decided):
		event_bus.approval_decided.disconnect(_on_approval_decided)
	if event_bus.error_occurred.is_connected(_on_error_occurred):
		event_bus.error_occurred.disconnect(_on_error_occurred)
	if event_bus.connection_state_changed.is_connected(_on_connection_state_changed):
		event_bus.connection_state_changed.disconnect(_on_connection_state_changed)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)

	var workspace_section := _create_section("Workspace")
	var workspace_grid := GridContainer.new()
	workspace_grid.columns = 2
	workspace_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_section.add_child(workspace_grid)
	_add_workspace_row(workspace_grid, "Workspace ID", "workspace_id")
	_add_workspace_row(workspace_grid, "Project Name", "project_name")
	_add_workspace_row(workspace_grid, "GitLab Project", "gitlab_project")
	_add_workspace_row(workspace_grid, "Default Branch", "gitlab_default_branch")
	_add_workspace_row(workspace_grid, "Policy Profile", "policy_profile")
	_add_workspace_row(workspace_grid, "Assets Prefix", "assets_remote_prefix")

	var connection_row := HBoxContainer.new()
	connection_row.add_theme_constant_override("separation", 12)
	workspace_section.add_child(connection_row)
	_connection_indicator = EchoThinkStatusIndicator.new()
	connection_row.add_child(_connection_indicator)
	_task_summary_label = Label.new()
	_task_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_task_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_row.add_child(_task_summary_label)

	var lists_row := HSplitContainer.new()
	lists_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lists_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(lists_row)

	_recent_activity_list = _create_list_panel(lists_row, "Recent Tasks")
	_approvals_list = _create_list_panel(lists_row, "Pending Approvals")
	_errors_list = _create_list_panel(lists_row, "Recent Errors")

	_ui_built = true


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.task_updated.connect(_on_task_updated)
	event_bus.approval_pending.connect(_on_approval_pending)
	event_bus.approval_decided.connect(_on_approval_decided)
	event_bus.error_occurred.connect(_on_error_occurred)
	event_bus.connection_state_changed.connect(_on_connection_state_changed)
	_signals_connected = true


func _queue_refresh() -> void:
	call_deferred("_refresh_deferred")


func _refresh_deferred() -> void:
	await refresh()


func _on_task_updated(task: TaskEnvelope) -> void:
	_recent_tasks = _upsert_task(_recent_tasks, task)
	while _recent_tasks.size() > 10:
		_recent_tasks.remove_at(_recent_tasks.size() - 1)
	_rebuild_recent_activity_list()
	_queue_refresh()


func _on_approval_pending(ticket: ApprovalTicket) -> void:
	_pending_approvals[ticket.approval_id] = ticket
	_rebuild_approvals_list()


func _on_approval_decided(ticket: ApprovalTicket) -> void:
	_pending_approvals.erase(ticket.approval_id)
	_rebuild_approvals_list()


func _on_error_occurred(source: String, msg: String) -> void:
	_recent_errors.insert(0, "%s: %s" % [source.strip_edges(), msg.strip_edges()])
	while _recent_errors.size() > 10:
		_recent_errors.remove_at(_recent_errors.size() - 1)
	_rebuild_error_list()


func _on_connection_state_changed(_state: String) -> void:
	_update_connection_state()


func _refresh_task_summary() -> void:
	if task_service == null:
		_task_summary_label.text = "Task service unavailable."
		return

	var tasks := await task_service.get_task_list()
	if _recent_tasks.is_empty():
		for task in tasks:
			_recent_tasks = _upsert_task(_recent_tasks, task)
		while _recent_tasks.size() > 10:
			_recent_tasks.remove_at(_recent_tasks.size() - 1)

	var actionable := 0
	var approvals_needed := 0
	for task in tasks:
		if task.is_actionable():
			actionable += 1
		if task.requires_approval():
			approvals_needed += 1

	_task_summary_label.text = "Tasks: %d total, %d actionable, %d requiring approval" % [tasks.size(), actionable, approvals_needed]


func _refresh_pending_approvals() -> void:
	if task_service == null:
		_rebuild_approvals_list()
		return

	_pending_approvals.clear()
	for ticket in await task_service.get_pending_approvals():
		_pending_approvals[ticket.approval_id] = ticket
	_rebuild_approvals_list()


func _update_workspace_section() -> void:
	var binding := session_manager.get_workspace_binding() if session_manager != null else WorkspaceBinding.new()
	_set_workspace_value("workspace_id", binding.workspace_id)
	_set_workspace_value("project_name", binding.project_name)
	_set_workspace_value("gitlab_project", binding.gitlab_project)
	_set_workspace_value("gitlab_default_branch", binding.gitlab_default_branch)
	_set_workspace_value("policy_profile", binding.policy_profile)
	_set_workspace_value("assets_remote_prefix", binding.assets_remote_prefix)


func _update_connection_state() -> void:
	var state := "offline"
	if session_manager != null:
		state = session_manager.get_connection_state()
	_connection_indicator.set_state(state)


func _rebuild_recent_activity_list() -> void:
	if _recent_activity_list == null:
		return
	_recent_activity_list.clear()
	if _recent_tasks.is_empty():
		_recent_activity_list.add_item("No recent tasks.")
		return
	for task in _recent_tasks:
		_recent_activity_list.add_item("[%s] %s" % [_fallback_text(task.status, "pending").to_upper(), _trim_text(task.objective, 72)])


func _rebuild_approvals_list() -> void:
	if _approvals_list == null:
		return
	_approvals_list.clear()
	if _pending_approvals.is_empty():
		_approvals_list.add_item("No approvals pending.")
		return
	for approval_id in _pending_approvals.keys():
		var ticket: ApprovalTicket = _pending_approvals[approval_id]
		_approvals_list.add_item("%s • %s • %s" % [approval_id, _fallback_text(ticket.risk_level, "unknown"), _fallback_text(ticket.approval_policy, "manual")])


func _rebuild_error_list() -> void:
	if _errors_list == null:
		return
	_errors_list.clear()
	if _recent_errors.is_empty():
		_errors_list.add_item("No recent errors.")
		return
	for error_text in _recent_errors:
		_errors_list.add_item(error_text)


func _create_section(title_text: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _create_panel_style())
	add_child(panel)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	panel.add_child(container)

	var title_label := Label.new()
	title_label.text = title_text
	title_label.add_theme_color_override("font_color", Color("#D0D7DE"))
	container.add_child(title_label)
	return container


func _create_list_panel(parent: Control, title_text: String) -> ItemList:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _create_panel_style())
	parent.add_child(panel)

	var container := VBoxContainer.new()
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 6)
	panel.add_child(container)

	var label := Label.new()
	label.text = title_text
	container.add_child(label)

	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(list)
	return list


func _add_workspace_row(grid: GridContainer, title_text: String, key: String) -> void:
	var title_label := Label.new()
	title_label.text = "%s:" % title_text
	grid.add_child(title_label)

	var value_label := Label.new()
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.text = "—"
	grid.add_child(value_label)
	_workspace_labels[key] = value_label


func _set_workspace_value(key: String, value: String) -> void:
	if not _workspace_labels.has(key):
		return
	var label: Label = _workspace_labels[key]
	label.text = _fallback_text(value, "—")


func _upsert_task(tasks: Array[TaskEnvelope], task: TaskEnvelope) -> Array[TaskEnvelope]:
	var updated: Array[TaskEnvelope] = []
	updated.append(task)
	for existing in tasks:
		if existing.work_item_id == task.work_item_id:
			continue
		updated.append(existing)
	return updated


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized


func _trim_text(text: String, max_length: int) -> String:
	var normalized := text.strip_edges()
	if normalized.length() <= max_length:
		return normalized
	return "%s…" % normalized.substr(0, max_length - 1)


func _create_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#1E1E1E")
	style.border_color = Color("#31363B")
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	return style
