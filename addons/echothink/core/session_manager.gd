@tool
class_name EchoThinkSessionManager
extends RefCounted


const _STATE_DISCONNECTED := "disconnected"
const _STATE_CONNECTING := "connecting"
const _STATE_CONNECTED := "connected"
const _STATE_DEGRADED := "degraded"
const _STATE_OFFLINE := "offline"

const _BINDING_FILE_NAME := "project.yaml"
const _CONFIG_DIR_NAME := ".echothink"
const _SOURCE_NAME := "session_manager"


var _workspace_binding: WorkspaceBinding = WorkspaceBinding.new()
var _session_id: String = ""
var _session_nonce: String = ""
var _connected: bool = false
var _connection_state: String = _STATE_DISCONNECTED
var _event_bus: EchoThinkEventBus = null


func initialize(event_bus: EchoThinkEventBus) -> void:
	_event_bus = event_bus
	_workspace_binding = WorkspaceBinding.new()
	_session_id = ""
	_session_nonce = ""
	_connected = false
	_connection_state = _STATE_DISCONNECTED


func load_workspace_binding(project_path: String) -> bool:
	var normalized_project_path := project_path.strip_edges()
	if normalized_project_path.is_empty():
		_workspace_binding = WorkspaceBinding.new()
		_emit_error("Project path is required to load workspace binding.")
		return false

	var binding_path := normalized_project_path.path_join(_CONFIG_DIR_NAME).path_join(_BINDING_FILE_NAME)
	if not FileAccess.file_exists(binding_path):
		_workspace_binding = WorkspaceBinding.new()
		_emit_error("Workspace binding file not found at %s." % binding_path)
		return false

	var binding_file := FileAccess.open(binding_path, FileAccess.READ)
	if binding_file == null:
		_workspace_binding = WorkspaceBinding.new()
		_emit_error("Unable to open workspace binding file %s: %s" % [binding_path, error_string(FileAccess.get_open_error())])
		return false

	var parsed_config := _parse_nested_yaml_mapping(binding_file.get_as_text())
	if parsed_config.is_empty():
		_workspace_binding = WorkspaceBinding.new()
		_emit_error("Workspace binding file %s is empty or invalid." % binding_path)
		return false

	var flattened_config := _flatten_workspace_binding_config(parsed_config)
	var binding := WorkspaceBinding.from_yaml(flattened_config)
	_workspace_binding = binding
	if not binding.is_valid():
		_emit_error("Workspace binding at %s is missing required fields." % binding_path)
		return false

	return true


func get_workspace_binding() -> WorkspaceBinding:
	return _workspace_binding


func set_connected(session_id: String, nonce: String) -> void:
	var normalized_session_id := session_id.strip_edges()
	var normalized_nonce := nonce.strip_edges()
	if normalized_session_id.is_empty() or normalized_nonce.is_empty():
		_emit_error("Cannot mark session as connected without both session ID and nonce.")
		set_disconnected()
		return

	var had_connection := _connected
	var ids_changed := _session_id != normalized_session_id or _session_nonce != normalized_nonce

	_session_id = normalized_session_id
	_session_nonce = normalized_nonce
	_connected = true
	var state_changed := _set_connection_state(_STATE_CONNECTED)

	if not had_connection or ids_changed:
		_emit_session_connected()
	elif state_changed:
		_emit_connection_state_changed()


func set_disconnected() -> void:
	var had_connection := _connected or not _session_id.is_empty() or not _session_nonce.is_empty()
	var state_changed := _set_connection_state(_STATE_DISCONNECTED)

	_session_id = ""
	_session_nonce = ""
	_connected = false

	if had_connection and _event_bus != null:
		_event_bus.session_disconnected.emit()
	if state_changed:
		_emit_connection_state_changed()


func get_session_id() -> String:
	return _session_id


func get_session_nonce() -> String:
	return _session_nonce


func is_connected() -> bool:
	return _connected


func get_connection_state() -> String:
	return _connection_state


func _emit_session_connected() -> void:
	if _event_bus == null:
		return
	_event_bus.session_connected.emit()
	_emit_connection_state_changed()


func _emit_connection_state_changed() -> void:
	if _event_bus == null:
		return
	_event_bus.connection_state_changed.emit(_connection_state)


func _set_connection_state(next_state: String) -> bool:
	var normalized_state := next_state.strip_edges().to_lower()
	if normalized_state.is_empty():
		normalized_state = _STATE_DISCONNECTED
	if normalized_state != _STATE_DISCONNECTED and normalized_state != _STATE_CONNECTING and normalized_state != _STATE_CONNECTED and normalized_state != _STATE_DEGRADED and normalized_state != _STATE_OFFLINE:
		normalized_state = _STATE_DISCONNECTED

	if normalized_state == _connection_state:
		return false

	_connection_state = normalized_state
	return true


func _flatten_workspace_binding_config(config: Dictionary) -> Dictionary:
	var godot_config := _dictionary_value(config.get("godot", {}))
	var gitlab_config := _dictionary_value(config.get("gitlab", {}))
	var outline_config := _dictionary_value(config.get("outline", {}))
	var assets_config := _dictionary_value(config.get("assets", {}))

	return {
		"workspace_id": _string_value(config.get("workspace_id", "")),
		"project_name": _string_value(config.get("project_name", "")),
		"godot_engine_major": _int_value(godot_config.get("engine_major", config.get("godot_engine_major", 0))),
		"gitlab_project": _string_value(gitlab_config.get("project", config.get("gitlab_project", ""))),
		"gitlab_default_branch": _string_value(gitlab_config.get("default_branch", config.get("gitlab_default_branch", ""))),
		"outline_primary_doc_id": _string_value(outline_config.get("primary_doc_id", config.get("outline_primary_doc_id", ""))),
		"outline_task_queue_doc_id": _string_value(outline_config.get("task_queue_doc_id", config.get("outline_task_queue_doc_id", ""))),
		"assets_remote_prefix": _string_value(assets_config.get("remote_prefix", config.get("assets_remote_prefix", ""))),
		"policy_profile": _string_value(config.get("policy_profile", "")),
	}


func _parse_nested_yaml_mapping(contents: String) -> Dictionary:
	var root: Dictionary = {}
	var stack: Array[Dictionary] = [{"indent": -1, "data": root}]

	for raw_line in contents.split("\n", false):
		var cleaned_line := _strip_yaml_comment(String(raw_line).replace("\r", ""))
		if cleaned_line.strip_edges().is_empty():
			continue

		var indent := _count_indent(cleaned_line)
		var text := cleaned_line.strip_edges()
		if text.begins_with("-"):
			continue

		var separator_index := text.find(":")
		if separator_index < 0:
			continue

		var key := text.substr(0, separator_index).strip_edges()
		if key.is_empty():
			continue

		var value_text := text.substr(separator_index + 1).strip_edges()
		while stack.size() > 1 and indent <= int(stack[stack.size() - 1].get("indent", -1)):
			stack.pop_back()

		var current_context: Dictionary = stack[stack.size() - 1]
		var current_dict: Dictionary = current_context.get("data", {})
		if value_text.is_empty():
			var child_dict: Dictionary = {}
			current_dict[key] = child_dict
			stack.append({"indent": indent, "data": child_dict})
		else:
			current_dict[key] = _parse_yaml_scalar(value_text)

	return root


func _emit_error(message: String) -> void:
	if _event_bus != null:
		_event_bus.emit_error(_SOURCE_NAME, message)


static func _strip_yaml_comment(line: String) -> String:
	var in_single_quote := false
	var in_double_quote := false
	var escaped := false

	for index in range(line.length()):
		var character := line.substr(index, 1)
		if character == "\\" and in_double_quote and not escaped:
			escaped = true
			continue
		if character == "\"" and not in_single_quote and not escaped:
			in_double_quote = not in_double_quote
		elif character == "'" and not in_double_quote:
			in_single_quote = not in_single_quote
		elif character == "#" and not in_single_quote and not in_double_quote:
			return line.substr(0, index)
		escaped = false

	return line


static func _count_indent(line: String) -> int:
	var indent := 0
	for index in range(line.length()):
		var character := line.substr(index, 1)
		if character == " ":
			indent += 1
		elif character == "\t":
			indent += 2
		else:
			break
	return indent


static func _parse_yaml_scalar(value: String) -> Variant:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return ""

	if (normalized.begins_with("\"") and normalized.ends_with("\"")) or (normalized.begins_with("'") and normalized.ends_with("'")):
		return normalized.substr(1, normalized.length() - 2)

	var lowered := normalized.to_lower()
	if lowered == "true":
		return true
	if lowered == "false":
		return false
	if lowered == "null" or lowered == "~":
		return null
	if normalized.is_valid_int():
		return normalized.to_int()
	if normalized.is_valid_float():
		return normalized.to_float()
	return normalized


static func _dictionary_value(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


static func _int_value(value: Variant, default_value: int = 0) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String:
		var normalized := value.strip_edges()
		if normalized.is_valid_int():
			return normalized.to_int()
	return default_value


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value).strip_edges()
