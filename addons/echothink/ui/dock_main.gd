@tool
class_name EchoThinkDock
extends Control


var event_bus: EchoThinkEventBus = null
var session_manager: EchoThinkSessionManager = null
var editor_context: EchoThinkEditorContext = null
var change_set_manager: EchoThinkChangeSetManager = null
var policy_guard: EchoThinkPolicyGuard = null
var bridge_client: EchoThinkBridgeClient = null
var gateway_client: EchoThinkGatewayClient = null
var patch_service: EchoThinkPatchService = null
var asset_service: EchoThinkAssetService = null
var task_service: EchoThinkTaskService = null
var log_service: EchoThinkLogService = null

var _connection_indicator: ColorRect = null
var _status_label: Label = null
var _task_count_label: Label = null
var _notification_badge: EchoThinkNotificationBadge = null
var _tab_container: TabContainer = null
var _status_timer: Timer = null

var _overview_tab: EchoThinkOverviewTab = null
var _tasks_tab: EchoThinkTasksTab = null
var _patches_tab: EchoThinkPatchesTab = null
var _assets_tab: EchoThinkAssetsTab = null
var _logs_qa_tab: EchoThinkLogsQATab = null
var _settings_tab: EchoThinkSettingsTab = null

var _signals_connected: bool = false
var _tabs_initialized: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	_try_initialize()


func initialize(
	events: EchoThinkEventBus,
	sessions: EchoThinkSessionManager,
	context: EchoThinkEditorContext,
	changesets: EchoThinkChangeSetManager,
	policy: EchoThinkPolicyGuard,
	bridge: EchoThinkBridgeClient,
	gateway: EchoThinkGatewayClient,
	patches: EchoThinkPatchService,
	assets: EchoThinkAssetService,
	tasks: EchoThinkTaskService,
	logs: EchoThinkLogService
) -> void:
	event_bus = events
	session_manager = sessions
	editor_context = context
	change_set_manager = changesets
	policy_guard = policy
	bridge_client = bridge
	gateway_client = gateway
	patch_service = patches
	asset_service = assets
	task_service = tasks
	log_service = logs
	_try_initialize()


func refresh() -> void:
	for tab in [_overview_tab, _tasks_tab, _patches_tab, _assets_tab, _logs_qa_tab, _settings_tab]:
		if tab != null and tab.has_method("refresh"):
			tab.refresh()
	_queue_task_count_update()


func cleanup() -> void:
	_disconnect_signals()
	for tab in [_overview_tab, _tasks_tab, _patches_tab, _assets_tab, _logs_qa_tab, _settings_tab]:
		if tab != null:
			tab.cleanup()
	_tabs_initialized = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var status_bar := HBoxContainer.new()
	status_bar.add_theme_constant_override("separation", 8)
	root.add_child(status_bar)

	_connection_indicator = ColorRect.new()
	_connection_indicator.custom_minimum_size = Vector2(12.0, 12.0)
	_connection_indicator.color = Color("#9E9E9E")
	status_bar.add_child(_connection_indicator)

	_status_label = Label.new()
	_status_label.text = "Connection: offline"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_bar.add_child(_status_label)

	_task_count_label = Label.new()
	_task_count_label.text = "Tasks: 0"
	status_bar.add_child(_task_count_label)

	_notification_badge = EchoThinkNotificationBadge.new()
	status_bar.add_child(_notification_badge)

	_tab_container = TabContainer.new()
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_container)

	_overview_tab = EchoThinkOverviewTab.new()
	_overview_tab.name = "Overview"
	_tab_container.add_child(_overview_tab)

	_tasks_tab = EchoThinkTasksTab.new()
	_tasks_tab.name = "Tasks"
	_tab_container.add_child(_tasks_tab)

	_patches_tab = EchoThinkPatchesTab.new()
	_patches_tab.name = "Patches"
	_tab_container.add_child(_patches_tab)

	_assets_tab = EchoThinkAssetsTab.new()
	_assets_tab.name = "Assets"
	_tab_container.add_child(_assets_tab)

	_logs_qa_tab = EchoThinkLogsQATab.new()
	_logs_qa_tab.name = "Logs & QA"
	_tab_container.add_child(_logs_qa_tab)

	_settings_tab = EchoThinkSettingsTab.new()
	_settings_tab.name = "Settings"
	_tab_container.add_child(_settings_tab)

	_status_timer = Timer.new()
	_status_timer.one_shot = true
	_status_timer.timeout.connect(_restore_connection_status)
	add_child(_status_timer)

	_ui_built = true


func _try_initialize() -> void:
	if not _ui_built or event_bus == null:
		return
	if not _tabs_initialized:
		_tasks_tab.editor_context = editor_context
		_settings_tab.bridge_client = bridge_client
		_settings_tab.gateway_client = gateway_client
		_overview_tab.initialize(event_bus, session_manager, task_service, log_service)
		_tasks_tab.initialize(event_bus, task_service, session_manager)
		_patches_tab.initialize(event_bus, patch_service, change_set_manager, policy_guard)
		_assets_tab.initialize(event_bus, asset_service, session_manager)
		_logs_qa_tab.initialize(event_bus, log_service, policy_guard)
		_settings_tab.initialize(event_bus, session_manager, policy_guard)
		_tabs_initialized = true
	_connect_signals()
	_on_connection_state_changed(session_manager.get_connection_state() if session_manager != null else "offline")
	_queue_task_count_update()


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.session_connected.connect(_on_session_connected)
	event_bus.session_disconnected.connect(_on_session_disconnected)
	event_bus.connection_state_changed.connect(_on_connection_state_changed)
	event_bus.task_updated.connect(_on_task_updated)
	event_bus.approval_pending.connect(_on_approval_pending)
	event_bus.approval_decided.connect(_on_approval_decided)
	event_bus.error_occurred.connect(_on_error_occurred)
	_signals_connected = true


func _disconnect_signals() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.session_connected.is_connected(_on_session_connected):
		event_bus.session_connected.disconnect(_on_session_connected)
	if event_bus.session_disconnected.is_connected(_on_session_disconnected):
		event_bus.session_disconnected.disconnect(_on_session_disconnected)
	if event_bus.connection_state_changed.is_connected(_on_connection_state_changed):
		event_bus.connection_state_changed.disconnect(_on_connection_state_changed)
	if event_bus.task_updated.is_connected(_on_task_updated):
		event_bus.task_updated.disconnect(_on_task_updated)
	if event_bus.approval_pending.is_connected(_on_approval_pending):
		event_bus.approval_pending.disconnect(_on_approval_pending)
	if event_bus.approval_decided.is_connected(_on_approval_decided):
		event_bus.approval_decided.disconnect(_on_approval_decided)
	if event_bus.error_occurred.is_connected(_on_error_occurred):
		event_bus.error_occurred.disconnect(_on_error_occurred)
	_signals_connected = false


func _on_session_connected() -> void:
	_on_connection_state_changed(session_manager.get_connection_state() if session_manager != null else "connected")


func _on_session_disconnected() -> void:
	_on_connection_state_changed(session_manager.get_connection_state() if session_manager != null else "disconnected")


func _on_connection_state_changed(state: String) -> void:
	if _connection_indicator == null or _status_label == null:
		return
	var normalized_state := state.strip_edges().to_lower()
	match normalized_state:
		"connected":
			_connection_indicator.color = Color("#4CAF50")
		"degraded":
			_connection_indicator.color = Color("#FFC107")
		"connecting":
			_connection_indicator.color = Color("#2196F3")
		"disconnected":
			_connection_indicator.color = Color("#F44336")
		_:
			_connection_indicator.color = Color("#9E9E9E")
	if _status_timer == null or _status_timer.is_stopped():
		_status_label.text = "Connection: %s" % _humanize_state(normalized_state)


func _on_error_occurred(source: String, msg: String) -> void:
	if _status_label == null:
		return
	_status_label.text = "%s: %s" % [_fallback_text(source, "error"), _fallback_text(msg, "Unknown error")]
	if _status_timer != null:
		_status_timer.start(4.0)


func _on_task_updated(_task: TaskEnvelope) -> void:
	_queue_task_count_update()


func _on_approval_pending(_ticket: ApprovalTicket) -> void:
	_queue_task_count_update()


func _on_approval_decided(_ticket: ApprovalTicket) -> void:
	_queue_task_count_update()


func _queue_task_count_update() -> void:
	call_deferred("_update_task_count")


func _update_task_count() -> void:
	if task_service == null:
		_task_count_label.text = "Tasks: 0"
		_notification_badge.set_count(0)
		return

	var tasks := await task_service.get_task_list()
	var actionable := 0
	for task in tasks:
		if task.is_actionable():
			actionable += 1
	_task_count_label.text = "Tasks: %d (%d actionable)" % [tasks.size(), actionable]

	var approvals := await task_service.get_pending_approvals()
	_notification_badge.set_count(approvals.size())


func _restore_connection_status() -> void:
	_on_connection_state_changed(session_manager.get_connection_state() if session_manager != null else "offline")


func _humanize_state(state: String) -> String:
	return _fallback_text(state.replace("_", " "), "offline")


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized
