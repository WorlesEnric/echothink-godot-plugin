class_name EchoThinkProbe
extends Node


var _bridge_socket_path: String = ""
var _enabled: bool = true
var _buffer: Array[Dictionary] = []
var _flush_interval: float = 2.0
var _timer: Timer

var _peer = null
var _bridge_tcp_host: String = "127.0.0.1"
var _bridge_tcp_port: int = 9876
var _session_context: Dictionary = {}


func _ready() -> void:
	randomize()
	_enabled = _resolve_bool_setting(
		"ECHOTHINK_RUNTIME_PROBE_ENABLED",
		"echothink/runtime_probe/enabled",
		true
	)
	_bridge_socket_path = _resolve_string_setting(
		"ECHOTHINK_BRIDGE_SOCKET",
		"echothink/runtime_probe/bridge_socket_path",
		"/tmp/echothink-bridge.sock"
	)
	_bridge_tcp_host = _resolve_string_setting(
		"ECHOTHINK_BRIDGE_HOST",
		"echothink/runtime_probe/bridge_host",
		"127.0.0.1"
	)
	_bridge_tcp_port = _resolve_int_setting(
		"ECHOTHINK_BRIDGE_PORT",
		"echothink/runtime_probe/bridge_port",
		9876
	)
	_session_context = _build_session_context()

	_timer = Timer.new()
	_timer.wait_time = _flush_interval
	_timer.one_shot = false
	_timer.autostart = false
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)

	if not _enabled:
		return

	_connect_to_bridge()
	_timer.start()


func _exit_tree() -> void:
	if is_instance_valid(_timer):
		_timer.stop()
	_flush_buffer()
	_disconnect_peer()


func report_error(message: String, stack: String) -> void:
	if not _enabled:
		return

	var event := _new_event("runtime_error")
	event["message"] = message
	event["stack_trace"] = stack
	_buffer.append(event)


func report_scene_state(scene_path: String, node_count: int, metadata: Dictionary) -> void:
	if not _enabled:
		return

	var event := _new_event("scene_state")
	event["scene_path"] = scene_path
	event["node_count"] = node_count
	event["metadata"] = metadata.duplicate(true)
	_buffer.append(event)


func report_game_event(event_name: String, data: Dictionary) -> void:
	if not _enabled:
		return

	var event := _new_event("game_event")
	event["event_name"] = event_name
	event["data"] = data.duplicate(true)
	_buffer.append(event)


func report_performance(fps: float, memory_mb: float, draw_calls: int) -> void:
	if not _enabled:
		return

	var event := _new_event("performance")
	event["fps"] = fps
	event["memory_mb"] = memory_mb
	event["draw_calls"] = draw_calls
	_buffer.append(event)


func _flush_buffer() -> void:
	if not _enabled or _buffer.is_empty():
		return

	if not _is_peer_ready() and not _connect_to_bridge():
		return

	var payload := {
		"kind": "playtest_telemetry",
		"sent_at": _timestamp_now(),
		"session": _session_context.duplicate(true),
		"events": _buffer.duplicate(true)
	}
	var serialized := JSON.stringify(payload)
	if serialized.is_empty():
		return

	if _peer == null or not _peer.has_method("put_data"):
		_disconnect_peer()
		return

	var write_error = _peer.put_data((serialized + "\n").to_utf8_buffer())
	if write_error == OK:
		_buffer.clear()
		return

	_disconnect_peer()


func _on_timer_timeout() -> void:
	_flush_buffer()


func _connect_to_bridge() -> bool:
	_disconnect_peer()

	var unix_peer = _connect_unix_socket()
	if unix_peer != null:
		_peer = unix_peer
		return true

	var tcp_peer := StreamPeerTCP.new()
	var connect_error := tcp_peer.connect_to_host(_bridge_tcp_host, _bridge_tcp_port)
	if connect_error == OK or connect_error == ERR_BUSY:
		_peer = tcp_peer
		return true

	return false


func _connect_unix_socket():
	if OS.get_name() == "Windows":
		return null
	if _bridge_socket_path.is_empty():
		return null
	if not ClassDB.class_exists("StreamPeerUnix"):
		return null

	var unix_peer = ClassDB.instantiate("StreamPeerUnix")
	if unix_peer == null:
		return null

	var connect_error := FAILED
	if unix_peer.has_method("connect_to_socket"):
		connect_error = int(unix_peer.call("connect_to_socket", _bridge_socket_path))
	elif unix_peer.has_method("open"):
		connect_error = int(unix_peer.call("open", _bridge_socket_path))
	else:
		return null

	if connect_error == OK:
		return unix_peer

	return null


func _disconnect_peer() -> void:
	if _peer == null:
		return

	if _peer.has_method("disconnect_from_host"):
		_peer.call("disconnect_from_host")
	elif _peer.has_method("close"):
		_peer.call("close")

	_peer = null


func _is_peer_ready() -> bool:
	if _peer == null:
		return false

	if _peer.has_method("poll"):
		_peer.call("poll")

	if _peer is StreamPeerTCP:
		return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

	if _peer.has_method("get_status"):
		return int(_peer.call("get_status")) == StreamPeerTCP.STATUS_CONNECTED

	return true


func _new_event(event_type: String) -> Dictionary:
	return {
		"event_type": event_type,
		"timestamp": _timestamp_now(),
		"session": _session_context.duplicate(true),
		"current_scene_path": _current_scene_path()
	}


func _build_session_context() -> Dictionary:
	var version_info: Dictionary = Engine.get_version_info()
	return {
		"session_id": _generate_session_id(),
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"platform": OS.get_name(),
		"godot_version": str(version_info.get("string", "")),
		"process_id": OS.get_process_id()
	}


func _generate_session_id() -> String:
	return "probe_%s_%s_%s" % [
		str(Time.get_unix_time_from_system()),
		str(OS.get_process_id()),
		str(randi())
	]


func _timestamp_now() -> String:
	return "%sZ" % Time.get_datetime_string_from_system(true, false)


func _current_scene_path() -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return ""
	return str(tree.current_scene.scene_file_path)


func _resolve_string_setting(env_name: String, setting_name: String, default_value: String) -> String:
	var env_value := OS.get_environment(env_name)
	if not env_value.is_empty():
		return env_value
	return str(ProjectSettings.get_setting(setting_name, default_value))


func _resolve_int_setting(env_name: String, setting_name: String, default_value: int) -> int:
	var env_value := OS.get_environment(env_name)
	if not env_value.is_empty():
		return int(env_value)
	return int(ProjectSettings.get_setting(setting_name, default_value))


func _resolve_bool_setting(env_name: String, setting_name: String, default_value: bool) -> bool:
	var env_value := OS.get_environment(env_name).to_lower()
	if not env_value.is_empty():
		return env_value in ["1", "true", "yes", "on"]
	return bool(ProjectSettings.get_setting(setting_name, default_value))
