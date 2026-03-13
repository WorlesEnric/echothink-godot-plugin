@tool
class_name EchoThinkPlugin
extends EditorPlugin


const TOOL_MENU_ITEM_NAME := "EchoThink Quick Actions"
const DEFAULT_BRIDGE_SOCKET_PATH := "/tmp/echothink-bridge.sock"
const DEFAULT_BRIDGE_HEALTH_PORT := 19821

const QUICK_ACTION_RECONNECT := 1001
const QUICK_ACTION_CAPTURE := 1002
const QUICK_ACTION_REQUEST_PLAN := 1003
const QUICK_ACTION_REQUEST_PATCH := 1004
const QUICK_ACTION_COLLECT_LOGS := 1005
const QUICK_ACTION_OPEN_JOURNAL := 1006

const SCENE_MENU_CAPTURE := 2001
const SCENE_MENU_REQUEST_PATCH := 2002
const FILESYSTEM_MENU_CAPTURE := 2101
const FILESYSTEM_MENU_PUSH_ASSETS := 2102
const SCRIPT_MENU_REQUEST_PLAN := 2201
const SCRIPT_MENU_REQUEST_PATCH := 2202

const CONTEXT_KIND_SCENE := "scene_tree"
const CONTEXT_KIND_FILESYSTEM := "filesystem"
const CONTEXT_KIND_SCRIPT := "script_editor"


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

var dock: EchoThinkDock = null
var quick_actions_popup: PopupMenu = null
var scene_tree_context_popup: PopupMenu = null
var filesystem_context_popup: PopupMenu = null
var script_editor_context_popup: PopupMenu = null

var _bridge_health_probe: HTTPRequest = null
var _context_popup_connections: Array[Dictionary] = []
var _bridge_socket_path: String = DEFAULT_BRIDGE_SOCKET_PATH
var _gateway_url: String = ""
var _gateway_token: String = ""
var _bridge_health_port: int = DEFAULT_BRIDGE_HEALTH_PORT


func _enter_tree() -> void:
	var project_path := _get_project_path()
	_bridge_socket_path = _resolve_string_setting("ECHOTHINK_SOCKET_PATH", "echothink/bridge/socket_path", DEFAULT_BRIDGE_SOCKET_PATH)
	_gateway_url = _resolve_string_setting("ECHOTHINK_GATEWAY_URL", "echothink/gateway/url", "")
	_gateway_token = _resolve_string_setting("ECHOTHINK_GATEWAY_TOKEN", "echothink/gateway/token", "")
	_bridge_health_port = _resolve_int_setting("ECHOTHINK_HEALTH_PORT", "echothink/bridge/health_port", DEFAULT_BRIDGE_HEALTH_PORT)

	event_bus = EchoThinkEventBus.new()
	event_bus.name = "EchoThinkEventBus"
	add_child(event_bus)

	session_manager = EchoThinkSessionManager.new()
	session_manager.initialize(event_bus)

	editor_context = EchoThinkEditorContext.new()
	editor_context.set_editor_interface(get_editor_interface())

	change_set_manager = EchoThinkChangeSetManager.new()
	change_set_manager.initialize(_get_journal_dir(), event_bus)

	policy_guard = EchoThinkPolicyGuard.new()
	policy_guard.initialize(_resolve_string_setting("ECHOTHINK_POLICY_PROFILE", "echothink/policy/profile", "studio-default"))
	policy_guard.load_test_strategies(project_path)

	bridge_client = EchoThinkBridgeClient.new()
	bridge_client.name = "EchoThinkBridgeClient"
	add_child(bridge_client)
	bridge_client.initialize(_bridge_socket_path, event_bus)

	gateway_client = EchoThinkGatewayClient.new()
	gateway_client.name = "EchoThinkGatewayClient"
	add_child(gateway_client)
	gateway_client.initialize(_gateway_url, _gateway_token, event_bus)

	patch_service = EchoThinkPatchService.new()
	patch_service.initialize(bridge_client, change_set_manager, policy_guard, event_bus)

	asset_service = EchoThinkAssetService.new()
	asset_service.initialize(bridge_client, gateway_client, change_set_manager, event_bus)

	task_service = EchoThinkTaskService.new()
	task_service.initialize(gateway_client, event_bus)

	log_service = EchoThinkLogService.new()
	log_service.initialize(bridge_client, gateway_client, event_bus)

	_bridge_health_probe = HTTPRequest.new()
	_bridge_health_probe.name = "EchoThinkBridgeHealthProbe"
	add_child(_bridge_health_probe)

	quick_actions_popup = PopupMenu.new()
	quick_actions_popup.name = "EchoThinkQuickActionsPopup"
	quick_actions_popup.id_pressed.connect(_on_quick_action_selected)
	get_editor_interface().get_base_control().add_child(quick_actions_popup)

	dock = EchoThinkDock.new()
	dock.name = "EchoThinkDock"
	dock.initialize(
		event_bus,
		session_manager,
		editor_context,
		change_set_manager,
		policy_guard,
		bridge_client,
		gateway_client,
		patch_service,
		asset_service,
		task_service,
		log_service
	)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)

	add_tool_menu_item(TOOL_MENU_ITEM_NAME, Callable(self, "_on_toolbar_menu_pressed"))
	_connect_editor_signals()
	_setup_context_menu_integrations()

	if session_manager.load_workspace_binding(project_path):
		var binding := session_manager.get_workspace_binding()
		var policy_profile := binding.policy_profile
		if policy_profile.is_empty():
			policy_profile = _resolve_string_setting("ECHOTHINK_POLICY_PROFILE", "echothink/policy/profile", "studio-default")
		policy_guard.initialize(policy_profile)
		policy_guard.load_test_strategies(project_path)

	if dock != null:
		dock.refresh()
	_attempt_bridge_connection()


func _exit_tree() -> void:
	_disconnect_editor_signals()
	remove_tool_menu_item(TOOL_MENU_ITEM_NAME)

	if dock != null and is_instance_valid(dock):
		remove_control_from_docks(dock)
		dock.cleanup()
		dock.queue_free()
	dock = null

	if quick_actions_popup != null and is_instance_valid(quick_actions_popup):
		quick_actions_popup.queue_free()
	quick_actions_popup = null

	if gateway_client != null and is_instance_valid(gateway_client):
		gateway_client.disconnect_event_stream()
	if bridge_client != null and is_instance_valid(bridge_client):
		bridge_client.disconnect_from_bridge()
	if session_manager != null:
		session_manager.set_disconnected()
	if event_bus != null and is_instance_valid(event_bus):
		event_bus.reset()

	for node in [_bridge_health_probe, gateway_client, bridge_client, event_bus]:
		if node != null and is_instance_valid(node):
			node.queue_free()

	scene_tree_context_popup = null
	filesystem_context_popup = null
	script_editor_context_popup = null
	_context_popup_connections.clear()
	_bridge_health_probe = null
	bridge_client = null
	gateway_client = null
	patch_service = null
	asset_service = null
	task_service = null
	log_service = null
	policy_guard = null
	change_set_manager = null
	editor_context = null
	session_manager = null
	event_bus = null


func _get_plugin_name() -> String:
	return "EchoThink"


func _get_plugin_icon() -> Texture2D:
	var base_control := get_editor_interface().get_base_control()
	if base_control == null:
		return null
	return base_control.get_theme_icon("Node", "EditorIcons")


func _on_scene_tree_context_menu(popup: PopupMenu) -> void:
	_clear_echo_items(popup)
	var selected_nodes := editor_context.get_selected_node_paths() if editor_context != null else PackedStringArray()
	if selected_nodes.is_empty():
		return
	if popup.get_item_count() > 0:
		popup.add_separator("EchoThink")
	popup.add_item("EchoThink: Capture Selection Context", SCENE_MENU_CAPTURE)
	popup.add_item("EchoThink: Request Patch for Selection", SCENE_MENU_REQUEST_PATCH)


func _on_filesystem_context_menu(popup: PopupMenu) -> void:
	_clear_echo_items(popup)
	var selected_paths := _get_selected_filesystem_paths()
	if selected_paths.is_empty():
		return
	if popup.get_item_count() > 0:
		popup.add_separator("EchoThink")
	popup.add_item("EchoThink: Capture File Context", FILESYSTEM_MENU_CAPTURE)
	popup.add_item("EchoThink: Push Selected Assets", FILESYSTEM_MENU_PUSH_ASSETS)


func _on_script_editor_context_menu(popup: PopupMenu) -> void:
	_clear_echo_items(popup)
	var current_script_path := _get_current_script_path()
	if current_script_path.is_empty():
		return
	if popup.get_item_count() > 0:
		popup.add_separator("EchoThink")
	popup.add_item("EchoThink: Request Plan for Script", SCRIPT_MENU_REQUEST_PLAN)
	popup.add_item("EchoThink: Request Patch for Script", SCRIPT_MENU_REQUEST_PATCH)


func _on_toolbar_menu_pressed() -> void:
	if quick_actions_popup == null or not is_instance_valid(quick_actions_popup):
		return
	quick_actions_popup.clear()
	quick_actions_popup.add_item("Reconnect Local Bridge", QUICK_ACTION_RECONNECT)
	quick_actions_popup.add_item("Capture Editor Snapshot", QUICK_ACTION_CAPTURE)
	quick_actions_popup.add_item("Request Cloud Plan", QUICK_ACTION_REQUEST_PLAN)
	quick_actions_popup.add_item("Request Patch Proposal", QUICK_ACTION_REQUEST_PATCH)
	quick_actions_popup.add_item("Collect Editor Logs", QUICK_ACTION_COLLECT_LOGS)
	quick_actions_popup.add_separator()
	quick_actions_popup.add_item("Open Journal Folder", QUICK_ACTION_OPEN_JOURNAL)
	quick_actions_popup.popup_centered(Vector2i(360, 0))


func _get_project_path() -> String:
	var resource_filesystem: Object = get_editor_interface().get_resource_filesystem()
	if resource_filesystem != null and resource_filesystem.has_method("get_filesystem_path"):
		var project_path := String(resource_filesystem.call("get_filesystem_path")).strip_edges()
		if not project_path.is_empty():
			if project_path.begins_with("res://") or project_path.begins_with("user://"):
				var normalized_path := ProjectSettings.globalize_path(project_path)
				return normalized_path if DirAccess.dir_exists_absolute(normalized_path) else normalized_path.get_base_dir()
			return project_path
	return ProjectSettings.globalize_path("res://").get_base_dir()


func _get_journal_dir() -> String:
	var project_path := _get_project_path()
	if project_path.is_empty():
		return "user://echothink"
	var journal_dir := project_path.path_join(".echothink").path_join("journal")
	DirAccess.make_dir_recursive_absolute(journal_dir)
	return journal_dir


func _connect_editor_signals() -> void:
	_connect_object_signal(event_bus, "error_occurred", Callable(self, "_on_event_bus_error"))
	_connect_object_signal(event_bus, "connection_state_changed", Callable(self, "_on_connection_state_changed"))
	_connect_object_signal(bridge_client, "bridge_connection_changed", Callable(self, "_on_bridge_connection_changed"))
	_connect_object_signal(bridge_client, "rpc_response_received", Callable(self, "_on_bridge_rpc_response_received"))
	_connect_object_signal(gateway_client, "ws_event_received", Callable(self, "_on_gateway_ws_event_received"))
	_connect_object_signal(get_editor_interface().get_selection(), "selection_changed", Callable(self, "_on_editor_selection_changed"))
	_connect_object_signal(get_editor_interface().get_resource_filesystem(), "filesystem_changed", Callable(self, "_on_editor_filesystem_changed"))


func _disconnect_editor_signals() -> void:
	_disconnect_object_signal(event_bus, "error_occurred", Callable(self, "_on_event_bus_error"))
	_disconnect_object_signal(event_bus, "connection_state_changed", Callable(self, "_on_connection_state_changed"))
	_disconnect_object_signal(bridge_client, "bridge_connection_changed", Callable(self, "_on_bridge_connection_changed"))
	_disconnect_object_signal(bridge_client, "rpc_response_received", Callable(self, "_on_bridge_rpc_response_received"))
	_disconnect_object_signal(gateway_client, "ws_event_received", Callable(self, "_on_gateway_ws_event_received"))
	_disconnect_object_signal(get_editor_interface().get_selection(), "selection_changed", Callable(self, "_on_editor_selection_changed"))
	_disconnect_object_signal(get_editor_interface().get_resource_filesystem(), "filesystem_changed", Callable(self, "_on_editor_filesystem_changed"))
	for connection in _context_popup_connections:
		var popup: PopupMenu = connection.get("popup", null)
		var about_callable: Callable = connection.get("about", Callable())
		var id_callable: Callable = connection.get("id", Callable())
		if popup == null or not is_instance_valid(popup):
			continue
		if popup.about_to_popup.is_connected(about_callable):
			popup.about_to_popup.disconnect(about_callable)
		if popup.id_pressed.is_connected(id_callable):
			popup.id_pressed.disconnect(id_callable)
	_context_popup_connections.clear()


func _attempt_bridge_connection() -> void:
	if event_bus != null:
		event_bus.connection_state_changed.emit("connecting")
	if gateway_client != null and not _gateway_url.is_empty():
		gateway_client.connect_event_stream()
	if bridge_client == null or not bridge_client.connect_to_bridge():
		if event_bus != null:
			event_bus.connection_state_changed.emit("offline")
		if session_manager != null:
			session_manager.set_disconnected()
		return


func _on_bridge_connected() -> void:
	var bridge_health := await _request_bridge_health()
	if bridge_client == null or not bridge_client.is_connected():
		return
	var session_id := String(bridge_health.get("session_id", "")).strip_edges()
	if session_id.is_empty():
		session_id = "editor_%s" % str(Time.get_ticks_usec())
	var session_nonce := "%s:%s" % [session_id, str(Time.get_unix_time_from_system())]
	if session_manager != null:
		session_manager.set_connected(session_id, session_nonce)
	if dock != null:
		dock.refresh()


func _on_bridge_disconnected() -> void:
	if session_manager != null:
		session_manager.set_disconnected()
	if event_bus != null:
		event_bus.connection_state_changed.emit("offline")
	if dock != null:
		dock.refresh()


func _on_quick_action_selected(id: int) -> void:
	match id:
		QUICK_ACTION_RECONNECT:
			if bridge_client != null:
				bridge_client.disconnect_from_bridge()
			_attempt_bridge_connection()
		QUICK_ACTION_CAPTURE:
			_capture_snapshot({"source": "quick_actions"})
		QUICK_ACTION_REQUEST_PLAN:
			await _request_plan({"source": "quick_actions"})
		QUICK_ACTION_REQUEST_PATCH:
			await _request_patch({"source": "quick_actions"})
		QUICK_ACTION_COLLECT_LOGS:
			await _collect_logs()
		QUICK_ACTION_OPEN_JOURNAL:
			OS.shell_open(_get_journal_dir())


func _on_context_popup_about_to_popup(context_kind: String, popup: PopupMenu) -> void:
	match context_kind:
		CONTEXT_KIND_SCENE:
			_on_scene_tree_context_menu(popup)
		CONTEXT_KIND_FILESYSTEM:
			_on_filesystem_context_menu(popup)
		CONTEXT_KIND_SCRIPT:
			_on_script_editor_context_menu(popup)


func _on_context_popup_id_pressed(id: int, context_kind: String, _popup: PopupMenu) -> void:
	match context_kind:
		CONTEXT_KIND_SCENE:
			if id == SCENE_MENU_CAPTURE:
				_capture_snapshot({
					"source": CONTEXT_KIND_SCENE,
					"selected_nodes": _packed_to_array(editor_context.get_selected_node_paths()),
				})
			elif id == SCENE_MENU_REQUEST_PATCH:
				await _request_patch({
					"source": CONTEXT_KIND_SCENE,
					"selected_nodes": _packed_to_array(editor_context.get_selected_node_paths()),
				})
		CONTEXT_KIND_FILESYSTEM:
			if id == FILESYSTEM_MENU_CAPTURE:
				_capture_snapshot({
					"source": CONTEXT_KIND_FILESYSTEM,
					"selected_paths": _packed_to_array(_get_selected_filesystem_paths()),
				})
			elif id == FILESYSTEM_MENU_PUSH_ASSETS:
				await _push_selected_assets(_get_selected_filesystem_paths())
		CONTEXT_KIND_SCRIPT:
			if id == SCRIPT_MENU_REQUEST_PLAN:
				await _request_plan({
					"source": CONTEXT_KIND_SCRIPT,
					"script_path": _get_current_script_path(),
				})
			elif id == SCRIPT_MENU_REQUEST_PATCH:
				await _request_patch({
					"source": CONTEXT_KIND_SCRIPT,
					"script_path": _get_current_script_path(),
				})


func _on_event_bus_error(source: String, message: String) -> void:
	push_warning("[EchoThink] %s: %s" % [source, message])
	if dock != null:
		dock.refresh()


func _on_connection_state_changed(_state: String) -> void:
	if dock != null:
		dock.refresh()


func _on_bridge_connection_changed(connected: bool) -> void:
	if connected:
		if event_bus != null:
			event_bus.connection_state_changed.emit("connecting")
		return
	_on_bridge_disconnected()


func _on_bridge_rpc_response_received(_request_id: int, payload: Dictionary) -> void:
	var result: Variant = payload.get("result", {})
	if result is Dictionary and bool(result.get("authenticated", false)):
		call_deferred("_on_bridge_connected")


func _on_gateway_ws_event_received(event_name: String, payload: Dictionary) -> void:
	if event_bus == null:
		return
	match event_name:
		"task.updated":
			event_bus.task_updated.emit(TaskEnvelope.from_dict(_extract_dictionary(payload, ["task", "payload", "data"])))
		"approval.pending":
			event_bus.approval_pending.emit(ApprovalTicket.from_dict(_extract_dictionary(payload, ["approval", "ticket", "payload"])))
		"approval.decided":
			event_bus.approval_decided.emit(ApprovalTicket.from_dict(_extract_dictionary(payload, ["approval", "ticket", "payload"])))
		"plan.ready":
			event_bus.plan_ready.emit(PlanRevision.from_dict(_extract_dictionary(payload, ["plan", "revision", "payload"])))
		"patch.ready":
			event_bus.patch_ready.emit(PatchProposal.from_dict(_extract_dictionary(payload, ["patch", "proposal", "payload"])))
		"asset_bundle.ready":
			event_bus.asset_bundle_ready.emit(AssetBundle.from_dict(_extract_dictionary(payload, ["bundle", "asset_bundle", "payload"])))
		"diagnostics.ready":
			event_bus.log_analysis_ready.emit(_extract_dictionary(payload, ["diagnostics", "results", "payload"]))
		"bridge.health_changed":
			var state := String(payload.get("state", payload.get("status", "degraded"))).strip_edges()
			event_bus.connection_state_changed.emit(state if not state.is_empty() else "degraded")
		"publish.failed":
			event_bus.emit_error("gateway", String(payload.get("message", "Publish failed.")))
	if dock != null:
		dock.refresh()


func _on_editor_selection_changed() -> void:
	if dock != null:
		dock.refresh()
	if scene_tree_context_popup == null or script_editor_context_popup == null:
		_setup_context_menu_integrations()


func _on_editor_filesystem_changed() -> void:
	if dock != null:
		dock.refresh()
	if filesystem_context_popup == null:
		_setup_context_menu_integrations()


func _setup_context_menu_integrations() -> void:
	if scene_tree_context_popup == null:
		scene_tree_context_popup = _find_context_popup(["scene", "tree", "node"], [_get_scene_tree_dock(), get_editor_interface().get_base_control()])
		_register_context_popup(CONTEXT_KIND_SCENE, scene_tree_context_popup)
	if filesystem_context_popup == null:
		filesystem_context_popup = _find_context_popup(["file", "filesystem", "fs"], [_get_filesystem_dock(), get_editor_interface().get_base_control()])
		_register_context_popup(CONTEXT_KIND_FILESYSTEM, filesystem_context_popup)
	if script_editor_context_popup == null:
		script_editor_context_popup = _find_context_popup(["script", "code", "editor"], [_get_script_editor(), get_editor_interface().get_base_control()])
		_register_context_popup(CONTEXT_KIND_SCRIPT, script_editor_context_popup)


func _register_context_popup(context_kind: String, popup: PopupMenu) -> void:
	if popup == null or not is_instance_valid(popup):
		return
	for connection in _context_popup_connections:
		if connection.get("popup", null) == popup:
			return
	var about_callable := Callable(self, "_on_context_popup_about_to_popup").bind(context_kind, popup)
	var id_callable := Callable(self, "_on_context_popup_id_pressed").bind(context_kind, popup)
	if not popup.about_to_popup.is_connected(about_callable):
		popup.about_to_popup.connect(about_callable)
	if not popup.id_pressed.is_connected(id_callable):
		popup.id_pressed.connect(id_callable)
	_context_popup_connections.append({
		"popup": popup,
		"about": about_callable,
		"id": id_callable,
	})


func _find_context_popup(name_hints: Array[String], roots: Array) -> PopupMenu:
	var seen: Dictionary = {}
	var best_popup: PopupMenu = null
	var best_score := -1
	for root_candidate in roots:
		if not (root_candidate is Node):
			continue
		var root: Node = root_candidate
		var candidates: Array = root.find_children("*", "PopupMenu", true, false)
		for candidate in candidates:
			if not (candidate is PopupMenu):
				continue
			var popup: PopupMenu = candidate
			if seen.has(popup.get_instance_id()):
				continue
			seen[popup.get_instance_id()] = true
			var score := _score_popup_candidate(popup, name_hints)
			if score > best_score:
				best_score = score
				best_popup = popup
	if best_score <= 0:
		return null
	return best_popup


func _score_popup_candidate(popup: PopupMenu, name_hints: Array[String]) -> int:
	var score := 0
	var node: Node = popup
	while node != null:
		var node_name := node.name.to_lower()
		for hint in name_hints:
			if node_name.contains(String(hint).to_lower()):
				score += 2
		node = node.get_parent()
	return score


func _capture_snapshot(context_data: Dictionary) -> ProjectContextSnapshot:
	var snapshot := ProjectContextSnapshot.new()
	if editor_context != null:
		snapshot = editor_context.capture_snapshot()
	if event_bus != null:
		event_bus.context_snapshot_sent.emit(snapshot.snapshot_id)
	if log_service != null:
		log_service.add_log_entry("editor", "info", "Captured editor context snapshot.", context_data)
	if dock != null:
		dock.refresh()
	return snapshot


func _request_plan(context_data: Dictionary) -> void:
	if task_service == null:
		if event_bus != null:
			event_bus.emit_error("plugin", "Task service is unavailable.")
		return
	var snapshot := _capture_snapshot(context_data)
	var plan_id := await task_service.request_plan(snapshot)
	if plan_id.is_empty() and event_bus != null:
		event_bus.emit_error("plugin", "Plan request failed.")


func _request_patch(context_data: Dictionary) -> void:
	if patch_service == null:
		if event_bus != null:
			event_bus.emit_error("plugin", "Patch service is unavailable.")
		return
	var snapshot := _capture_snapshot(context_data)
	var request_context := snapshot.to_dict()
	for key in context_data.keys():
		request_context[key] = context_data[key]
	var request_id := await patch_service.request_new_patch(request_context)
	if request_id.is_empty() and event_bus != null:
		event_bus.emit_error("plugin", "Patch request failed.")


func _push_selected_assets(paths: PackedStringArray) -> void:
	if asset_service == null or paths.is_empty():
		return
	var result := await asset_service.push_assets(paths)
	if result.has("error") and event_bus != null:
		event_bus.emit_error("plugin", String(result.get("error", {})))


func _collect_logs() -> void:
	if log_service == null:
		return
	await log_service.collect_logs(PackedStringArray(["editor", "bridge", "gateway"]))
	if dock != null:
		dock.refresh()


func _request_bridge_health() -> Dictionary:
	if _bridge_health_probe == null or not is_instance_valid(_bridge_health_probe) or get_tree() == null:
		return {}
	var url := "http://127.0.0.1:%d/health" % _bridge_health_port
	var request_error := _bridge_health_probe.request(url)
	if request_error != OK:
		return {}
	var completed: Array = await _bridge_health_probe.request_completed
	var result := int(completed[0])
	var status_code := int(completed[1])
	var body: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS or status_code < 200 or status_code >= 300:
		return {}
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary:
		return parsed.duplicate(true)
	return {}


func _get_scene_tree_dock() -> Object:
	return _first_available_editor_object(["get_scene_tree_dock", "get_scene_tree_editor"])


func _get_filesystem_dock() -> Object:
	return _first_available_editor_object(["get_file_system_dock", "get_filesystem_dock"])


func _get_script_editor() -> Object:
	return _first_available_editor_object(["get_script_editor"])


func _first_available_editor_object(method_names: Array[String]) -> Object:
	var editor_interface := get_editor_interface()
	for method_name in method_names:
		var result := _call_if_available(editor_interface, method_name)
		if result is Object:
			return result
	return null


func _get_selected_filesystem_paths() -> PackedStringArray:
	var selected_paths := PackedStringArray()
	var filesystem_dock := _get_filesystem_dock()
	for method_name in ["get_selected_paths", "get_selected_files", "get_selected_items"]:
		_append_paths_from_variant(selected_paths, _call_if_available(filesystem_dock, method_name))
	if selected_paths.is_empty():
		var current_path := String(_call_if_available(filesystem_dock, "get_current_path")).strip_edges()
		if not current_path.is_empty():
			selected_paths.append(current_path)
	return selected_paths


func _get_current_script_path() -> String:
	var script_editor := _get_script_editor()
	for method_name in ["get_current_script", "get_edited_script"]:
		var path := _extract_resource_path(_call_if_available(script_editor, method_name))
		if not path.is_empty():
			return path
	if editor_context == null:
		return ""
	var open_scripts := editor_context.get_open_scripts()
	return open_scripts[0] if not open_scripts.is_empty() else ""


func _append_paths_from_variant(target: PackedStringArray, value: Variant) -> void:
	if value is Array or value is PackedStringArray:
		for item in value:
			var path := _extract_resource_path(item)
			if not path.is_empty() and not target.has(path):
				target.append(path)
		return
	var single_path := _extract_resource_path(value)
	if not single_path.is_empty() and not target.has(single_path):
		target.append(single_path)


func _extract_resource_path(value: Variant) -> String:
	if value == null:
		return ""
	if value is String:
		return String(value).strip_edges()
	if value is Resource:
		return value.resource_path.strip_edges()
	if value is Object:
		var object_value: Object = value
		var resource_path := String(object_value.get("resource_path", "")).strip_edges()
		if not resource_path.is_empty():
			return resource_path
		if object_value.has_method("get_path"):
			return String(object_value.call("get_path")).strip_edges()
	return ""


func _extract_dictionary(payload: Dictionary, keys: Array[String]) -> Dictionary:
	for key in keys:
		var candidate: Variant = payload.get(key, null)
		if candidate is Dictionary:
			return candidate.duplicate(true)
	return payload.duplicate(true)


func _clear_echo_items(popup: PopupMenu) -> void:
	for index in range(popup.get_item_count() - 1, -1, -1):
		var item_id := popup.get_item_id(index)
		var item_text := popup.get_item_text(index)
		if item_text == "EchoThink" or item_text.begins_with("EchoThink:") or (item_id >= 1000 and item_id < 3000):
			popup.remove_item(index)


func _connect_object_signal(target: Object, signal_name: String, callable: Callable) -> void:
	if target == null or not target.has_signal(signal_name):
		return
	if target.is_connected(signal_name, callable):
		return
	target.connect(signal_name, callable)


func _disconnect_object_signal(target: Object, signal_name: String, callable: Callable) -> void:
	if target == null or not target.has_signal(signal_name):
		return
	if target.is_connected(signal_name, callable):
		target.disconnect(signal_name, callable)


func _resolve_string_setting(environment_key: String, project_key: String, default_value: String) -> String:
	if OS.has_environment(environment_key):
		var env_value := OS.get_environment(environment_key).strip_edges()
		if not env_value.is_empty():
			return env_value
	var project_value := String(ProjectSettings.get_setting(project_key, default_value)).strip_edges()
	return project_value if not project_value.is_empty() else default_value.strip_edges()


func _resolve_int_setting(environment_key: String, project_key: String, default_value: int) -> int:
	if OS.has_environment(environment_key):
		var env_value := OS.get_environment(environment_key).strip_edges()
		if env_value.is_valid_int():
			return env_value.to_int()
	var project_value: Variant = ProjectSettings.get_setting(project_key, default_value)
	if project_value is int:
		return project_value
	if project_value is String and String(project_value).is_valid_int():
		return String(project_value).to_int()
	return default_value


func _call_if_available(target: Object, method_name: String, arguments: Array = []) -> Variant:
	if target == null or not target.has_method(method_name):
		return null
	match arguments.size():
		0:
			return target.call(method_name)
		1:
			return target.call(method_name, arguments[0])
		2:
			return target.call(method_name, arguments[0], arguments[1])
		_:
			return null


func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var array: Array[String] = []
	for value in values:
		array.append(value)
	return array
