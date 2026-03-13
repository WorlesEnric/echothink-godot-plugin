@tool
class_name EchoThinkSettingsTab
extends VBoxContainer


var bridge_client: EchoThinkBridgeClient = null
var gateway_client: EchoThinkGatewayClient = null

var event_bus: EchoThinkEventBus = null
var session_manager: EchoThinkSessionManager = null
var policy_guard: EchoThinkPolicyGuard = null

var _workspace_fields: Dictionary = {}
var _connection_fields: Dictionary = {}
var _policy_profile_label: Label = null
var _connection_state_label: Label = null
var _strategy_list: ItemList = null
var _save_status_label: Label = null
var _ui_built: bool = false
var _signals_connected: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		_load_current_settings()


func initialize(events: EchoThinkEventBus, sessions: EchoThinkSessionManager, policy: EchoThinkPolicyGuard) -> void:
	event_bus = events
	session_manager = sessions
	policy_guard = policy
	if is_node_ready():
		_build_ui()
		_connect_signals()
		_load_current_settings()


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.connection_state_changed.is_connected(_on_connection_state_changed):
		event_bus.connection_state_changed.disconnect(_on_connection_state_changed)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	var workspace_section := _create_section(content, "Workspace")
	var workspace_grid := GridContainer.new()
	workspace_grid.columns = 2
	workspace_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace_section.add_child(workspace_grid)
	_add_line_field(workspace_grid, "Workspace ID", "workspace_id", _workspace_fields)
	_add_line_field(workspace_grid, "Project Name", "project_name", _workspace_fields)
	_add_line_field(workspace_grid, "GitLab Project", "gitlab_project", _workspace_fields)
	_add_line_field(workspace_grid, "Default Branch", "gitlab_default_branch", _workspace_fields)
	_add_line_field(workspace_grid, "Outline Primary Doc", "outline_primary_doc_id", _workspace_fields)
	_add_line_field(workspace_grid, "Outline Task Queue", "outline_task_queue_doc_id", _workspace_fields)
	_add_line_field(workspace_grid, "Assets Prefix", "assets_remote_prefix", _workspace_fields)
	_add_line_field(workspace_grid, "Policy Profile", "policy_profile", _workspace_fields)

	var connection_section := _create_section(content, "Connection")
	var connection_grid := GridContainer.new()
	connection_grid.columns = 2
	connection_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_section.add_child(connection_grid)
	_add_line_field(connection_grid, "Bridge Socket Path", "bridge_socket_path", _connection_fields)
	_add_line_field(connection_grid, "Gateway URL", "gateway_url", _connection_fields)

	_connection_state_label = Label.new()
	connection_section.add_child(_connection_state_label)

	var policy_section := _create_section(content, "Policy")
	_policy_profile_label = Label.new()
	policy_section.add_child(_policy_profile_label)

	_strategy_list = ItemList.new()
	_strategy_list.custom_minimum_size = Vector2(320.0, 180.0)
	policy_section.add_child(_strategy_list)

	var save_button := Button.new()
	save_button.text = "Save"
	save_button.pressed.connect(_on_save_pressed)
	content.add_child(save_button)

	_save_status_label = Label.new()
	_save_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_save_status_label)

	_ui_built = true


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.connection_state_changed.connect(_on_connection_state_changed)
	_signals_connected = true


func _load_current_settings() -> void:
	if session_manager != null:
		var binding := session_manager.get_workspace_binding()
		_set_field_value(_workspace_fields, "workspace_id", binding.workspace_id)
		_set_field_value(_workspace_fields, "project_name", binding.project_name)
		_set_field_value(_workspace_fields, "gitlab_project", binding.gitlab_project)
		_set_field_value(_workspace_fields, "gitlab_default_branch", binding.gitlab_default_branch)
		_set_field_value(_workspace_fields, "outline_primary_doc_id", binding.outline_primary_doc_id)
		_set_field_value(_workspace_fields, "outline_task_queue_doc_id", binding.outline_task_queue_doc_id)
		_set_field_value(_workspace_fields, "assets_remote_prefix", binding.assets_remote_prefix)
		_set_field_value(_workspace_fields, "policy_profile", binding.policy_profile)

	if bridge_client != null:
		_set_field_value(_connection_fields, "bridge_socket_path", String(bridge_client.get("_socket_path")))
	if gateway_client != null:
		_set_field_value(_connection_fields, "gateway_url", String(gateway_client.get("_gateway_url")))

	_on_connection_state_changed(session_manager.get_connection_state() if session_manager != null else "offline")
	_refresh_policy_display()
	_save_status_label.text = ""


func _on_save_pressed() -> void:
	if session_manager != null:
		var binding := session_manager.get_workspace_binding()
		binding.workspace_id = _field_value(_workspace_fields, "workspace_id")
		binding.project_name = _field_value(_workspace_fields, "project_name")
		binding.gitlab_project = _field_value(_workspace_fields, "gitlab_project")
		binding.gitlab_default_branch = _field_value(_workspace_fields, "gitlab_default_branch")
		binding.outline_primary_doc_id = _field_value(_workspace_fields, "outline_primary_doc_id")
		binding.outline_task_queue_doc_id = _field_value(_workspace_fields, "outline_task_queue_doc_id")
		binding.assets_remote_prefix = _field_value(_workspace_fields, "assets_remote_prefix")
		binding.policy_profile = _field_value(_workspace_fields, "policy_profile")

	if bridge_client != null:
		bridge_client.set("_socket_path", _field_value(_connection_fields, "bridge_socket_path"))
	if gateway_client != null:
		gateway_client.set("_gateway_url", _field_value(_connection_fields, "gateway_url"))

	if policy_guard != null:
		policy_guard.initialize(_field_value(_workspace_fields, "policy_profile"))
		policy_guard.load_test_strategies(ProjectSettings.globalize_path("res://"))
	_refresh_policy_display()
	_save_status_label.text = "Settings updated in memory. Persisting to `.echothink/project.yaml` is still pending."


func _on_connection_state_changed(state: String) -> void:
	if _connection_state_label == null:
		return
	_connection_state_label.text = "Connection State: %s" % _fallback_text(state.replace("_", " "), "offline")


func _refresh_policy_display() -> void:
	if _policy_profile_label == null or _strategy_list == null:
		return
	var profile := _field_value(_workspace_fields, "policy_profile")
	_policy_profile_label.text = "Current Policy Profile: %s" % _fallback_text(profile, "studio-default")
	_strategy_list.clear()
	if policy_guard == null:
		_strategy_list.add_item("Policy guard unavailable.")
		return
	var strategies := policy_guard.get_allowed_test_strategies()
	if strategies.is_empty():
		_strategy_list.add_item("No test strategies allowed for this profile.")
		return
	for strategy_id in strategies:
		var details := policy_guard.get_strategy_by_id(strategy_id)
		var label := strategy_id
		if not details.is_empty() and not String(details.get("kind", "")).strip_edges().is_empty():
			label = "%s • %s" % [strategy_id, details.get("kind", "")]
		_strategy_list.add_item(label)


func _create_section(parent: VBoxContainer, title_text: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style())
	parent.add_child(panel)

	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	panel.add_child(container)

	var title_label := Label.new()
	title_label.text = title_text
	container.add_child(title_label)
	return container


func _add_line_field(grid: GridContainer, title_text: String, key: String, target: Dictionary) -> void:
	var label := Label.new()
	label.text = "%s:" % title_text
	grid.add_child(label)

	var field := LineEdit.new()
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(field)
	target[key] = field


func _set_field_value(fields: Dictionary, key: String, value: String) -> void:
	if not fields.has(key):
		return
	var field: LineEdit = fields[key]
	field.text = value


func _field_value(fields: Dictionary, key: String) -> String:
	if not fields.has(key):
		return ""
	var field: LineEdit = fields[key]
	return field.text.strip_edges()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#1E1E1E")
	style.border_color = Color("#31363B")
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	return style


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized
