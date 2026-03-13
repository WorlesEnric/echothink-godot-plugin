@tool
class_name EchoThinkBridgeClient
extends Node


signal rpc_response_received(request_id: int, payload: Dictionary)
signal bridge_connection_changed(connected: bool)


const JSONRPC_VERSION := "2.0"
const DEFAULT_TCP_HOST := "127.0.0.1"
const DEFAULT_TCP_PORT := 7061
const MAX_READ_CHUNK_SIZE := 8192
const REQUEST_TIMEOUT_MS := 15000
const RECONNECT_DELAY_SEC := 2.0


var _socket_path: String = ""
var _stream: StreamPeer = null
var _connected: bool = false
var _request_id: int = 0
var _pending_requests: Dictionary = {}
var _event_bus: Object = null
var _reconnect_timer: Timer = null
var _read_buffer: PackedByteArray = PackedByteArray()

var _auth_request_id: int = -1
var _session_nonce: String = ""
var _auth_pending: bool = false


func _ready() -> void:
	set_process(true)
	_ensure_reconnect_timer()


func _process(_delta: float) -> void:
	if not _connected or _stream == null:
		return

	_poll_stream()
	if _auth_pending and _can_exchange_data():
		_begin_authenticated_session()
	_process_incoming()
	if _is_stream_disconnected():
		_set_disconnected(true)


func initialize(socket_path: String, event_bus: Object) -> void:
	_socket_path = socket_path.strip_edges()
	_event_bus = event_bus
	_read_buffer = PackedByteArray()
	_request_id = 0
	_pending_requests.clear()
	_ensure_reconnect_timer()


func connect_to_bridge() -> bool:
	if _connected:
		return true

	_ensure_reconnect_timer()
	_read_buffer = PackedByteArray()
	_stream = null
	_auth_pending = false
	_auth_request_id = -1

	if not _connect_stream():
		_schedule_reconnect()
		_dispatch_event("bridge.connection_failed", {
			"socket_path": _socket_path,
		})
		return false

	_connected = true
	_reconnect_timer.stop()
	_session_nonce = _generate_nonce()
	_auth_pending = true
	emit_signal("bridge_connection_changed", true)
	_dispatch_event("bridge.connected", {
		"socket_path": _socket_path,
		"transport": _describe_transport(),
	})
	if _can_exchange_data():
		_begin_authenticated_session()
	return true


func disconnect_from_bridge() -> void:
	_set_disconnected(false)


func is_connected() -> bool:
	return _connected


func send_request(method: String, params: Dictionary) -> Dictionary:
	var request_id := _send_rpc(method, params)
	if request_id < 0:
		return {
			"error": {
				"code": ERR_CANT_CONNECT,
				"message": "Unable to send request to Local Bridge.",
			},
		}
	return await _await_request(request_id)


func _send_rpc(method: String, params: Variant) -> int:
	var normalized_method := method.strip_edges()
	if normalized_method.is_empty():
		return -1

	if not _connected and not connect_to_bridge():
		return -1

	_request_id += 1
	var request_id := _request_id
	var payload := {
		"jsonrpc": JSONRPC_VERSION,
		"id": request_id,
		"method": normalized_method,
		"params": _clone_variant(params),
	}
	_pending_requests[request_id] = {
		"method": normalized_method,
		"params": _clone_variant(params),
		"created_at_msec": Time.get_ticks_msec(),
		"completed": false,
		"response": {},
	}

	var encoded := (JSON.stringify(payload) + "\n").to_utf8_buffer()
	var write_error := _write_bytes(encoded)
	if write_error != OK:
		_pending_requests.erase(request_id)
		_set_disconnected(true)
		return -1
	return request_id


func _process_incoming() -> void:
	if not _connected or _stream == null:
		return

	var available_bytes := _get_available_bytes()
	while available_bytes > 0:
		var chunk_size := mini(available_bytes, MAX_READ_CHUNK_SIZE)
		var read_result := _read_bytes(chunk_size)
		var read_error: int = read_result.get("error", ERR_CONNECTION_ERROR)
		if read_error != OK:
			_set_disconnected(true)
			return

		var payload: PackedByteArray = read_result.get("data", PackedByteArray())
		if payload.is_empty():
			break

		_read_buffer.append_array(payload)
		available_bytes = _get_available_bytes()

	for message in _extract_messages_from_buffer():
		var parsed: Variant = JSON.parse_string(message)
		if parsed == null:
			_dispatch_event("bridge.protocol_error", {
				"message": "Received invalid JSON from Local Bridge.",
				"payload": message,
			})
			continue

		if parsed is Array:
			for item in parsed:
				_process_message(item)
			continue

		_process_message(parsed)


func _handle_response(data: Dictionary) -> void:
	var request_id := _variant_to_int(data.get("id", -1), -1)
	if request_id < 0:
		return

	var response := data.duplicate(true)
	var pending: Dictionary = _get_pending_request(request_id)
	pending["completed"] = true
	pending["response"] = response
	_pending_requests[request_id] = pending

	if request_id == _auth_request_id:
		_auth_pending = false
		if data.has("error"):
			_dispatch_event("bridge.authentication_failed", {
				"nonce": _session_nonce,
				"error": _extract_error_dictionary(data),
			})
			_set_disconnected(true)
		else:
			_dispatch_event("bridge.authenticated", {
				"nonce": _session_nonce,
				"result": _extract_result_dictionary(data),
			})

	emit_signal("rpc_response_received", request_id, response)


func _handle_notification(data: Dictionary) -> void:
	var method := String(data.get("method", "")).strip_edges()
	if method.is_empty():
		return

	var params: Variant = data.get("params", {})
	var payload := {
		"method": method,
		"params": _clone_variant(params),
		"raw": data.duplicate(true),
	}
	_dispatch_event(method, payload)
	_dispatch_event("bridge.notification", payload)


func _on_reconnect_timeout() -> void:
	if _connected:
		return
	connect_to_bridge()


func _connect_stream() -> bool:
	if not _looks_like_tcp_endpoint(_socket_path) and _try_connect_unix_socket():
		return true
	return _try_connect_tcp_socket()


func _try_connect_unix_socket() -> bool:
	if _socket_path.is_empty() or not ClassDB.class_exists("StreamPeerUnix"):
		return false

	var unix_peer := ClassDB.instantiate("StreamPeerUnix")
	if unix_peer == null:
		return false

	var connect_methods := ["connect_to_path", "connect_to_socket", "connect_to_host"]
	for method_name_variant in connect_methods:
		var method_name := String(method_name_variant)
		if not unix_peer.has_method(method_name):
			continue
		var result := unix_peer.call(method_name, _socket_path)
		if typeof(result) == TYPE_INT and int(result) == OK:
			var peer_variant: Variant = unix_peer
			_stream = peer_variant as StreamPeer
			return _stream != null
	return false


func _try_connect_tcp_socket() -> bool:
	var endpoint := _parse_tcp_endpoint(_socket_path)
	if endpoint.is_empty():
		return false

	var tcp_peer := StreamPeerTCP.new()
	var host := String(endpoint.get("host", DEFAULT_TCP_HOST))
	var port := _variant_to_int(endpoint.get("port", DEFAULT_TCP_PORT), DEFAULT_TCP_PORT)
	var connect_error := tcp_peer.connect_to_host(host, port)
	if connect_error != OK:
		return false

	_stream = tcp_peer
	return true


func _await_request(request_id: int) -> Dictionary:
	if request_id < 0:
		return {
			"error": {
				"code": ERR_INVALID_PARAMETER,
				"message": "Invalid request id.",
			},
		}

	if get_tree() == null:
		return {
			"error": {
				"code": ERR_UNAVAILABLE,
				"message": "Bridge client must be inside the scene tree before awaiting requests.",
			},
		}

	var started_at := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_at <= REQUEST_TIMEOUT_MS:
		var pending: Dictionary = _get_pending_request(request_id)
		if bool(pending.get("completed", false)):
			var response: Dictionary = pending.get("response", {})
			_pending_requests.erase(request_id)
			return response.duplicate(true)
		await get_tree().process_frame

	_pending_requests.erase(request_id)
	return {
		"id": request_id,
		"error": {
			"code": ERR_TIMEOUT,
			"message": "Timed out waiting for Local Bridge response.",
		},
	}


func _begin_authenticated_session() -> void:
	if not _connected or _session_nonce.is_empty():
		return
	_auth_pending = false
	_auth_request_id = _send_rpc("session.authenticate", {
		"nonce": _session_nonce,
		"client": "godot_editor",
		"transport": _describe_transport(),
		"protocol": JSONRPC_VERSION,
	})
	if _auth_request_id < 0:
		_auth_pending = true


func _process_message(message: Variant) -> void:
	if not (message is Dictionary):
		return

	var data: Dictionary = message
	if data.has("id") and (data.has("result") or data.has("error")):
		_handle_response(data)
		return
	if data.has("method"):
		_handle_notification(data)


func _extract_messages_from_buffer() -> Array[String]:
	var messages: Array[String] = []
	while not _read_buffer.is_empty():
		var buffer_text := _read_buffer.get_string_from_utf8()
		if buffer_text.begins_with("Content-Length:"):
			var header_end := buffer_text.find("\r\n\r\n")
			if header_end == -1:
				break

			var header_text := buffer_text.substr(0, header_end)
			var content_length := _parse_content_length(header_text)
			if content_length < 0:
				_read_buffer = PackedByteArray()
				break

			var payload_start := header_end + 4
			var payload_end := payload_start + content_length
			if _read_buffer.size() < payload_end:
				break

			var payload_bytes := _read_buffer.slice(payload_start, payload_end)
			messages.append(payload_bytes.get_string_from_utf8())
			_read_buffer = _read_buffer.slice(payload_end, _read_buffer.size())
			continue

		var newline_index := buffer_text.find("\n")
		if newline_index == -1:
			break

		var line := buffer_text.substr(0, newline_index).strip_edges()
		_read_buffer = _read_buffer.slice(newline_index + 1, _read_buffer.size())
		if not line.is_empty():
			messages.append(line)
	return messages


func _parse_content_length(header_text: String) -> int:
	for header_line in header_text.split("\r\n"):
		var separator_index := header_line.find(":")
		if separator_index == -1:
			continue
		var header_name := header_line.substr(0, separator_index).strip_edges().to_lower()
		if header_name != "content-length":
			continue
		var raw_value := header_line.substr(separator_index + 1).strip_edges()
		if raw_value.is_valid_int():
			return max(raw_value.to_int(), 0)
	return -1


func _read_bytes(byte_count: int) -> Dictionary:
	if _stream == null:
		return {
			"error": ERR_CONNECTION_ERROR,
			"data": PackedByteArray(),
		}

	if _stream.has_method("get_partial_data"):
		var partial_result := _stream.call("get_partial_data", byte_count)
		if partial_result is Array and partial_result.size() >= 2:
			return {
				"error": int(partial_result[0]),
				"data": partial_result[1],
			}

	if _stream.has_method("get_data"):
		var full_result := _stream.call("get_data", byte_count)
		if full_result is Array and full_result.size() >= 2:
			return {
				"error": int(full_result[0]),
				"data": full_result[1],
			}

	return {
		"error": ERR_UNAVAILABLE,
		"data": PackedByteArray(),
	}


func _write_bytes(data: PackedByteArray) -> int:
	if _stream == null:
		return ERR_CONNECTION_ERROR

	if _stream.has_method("put_data"):
		var result := _stream.call("put_data", data)
		if typeof(result) == TYPE_INT:
			return int(result)

	if _stream.has_method("put_partial_data"):
		var partial_result := _stream.call("put_partial_data", data)
		if partial_result is Array and partial_result.size() >= 2:
			var error_code := int(partial_result[0])
			var written_count := int(partial_result[1])
			if error_code == OK and written_count == data.size():
				return OK
			return ERR_CANT_WRITE

	return ERR_UNAVAILABLE


func _get_available_bytes() -> int:
	if _stream == null or not _stream.has_method("get_available_bytes"):
		return 0
	var result := _stream.call("get_available_bytes")
	return max(_variant_to_int(result, 0), 0)


func _poll_stream() -> void:
	if _stream != null and _stream.has_method("poll"):
		_stream.call("poll")


func _is_stream_disconnected() -> bool:
	if _stream == null or not _stream.has_method("get_status"):
		return false
	var status := _variant_to_int(_stream.call("get_status"), -1)
	if _stream is StreamPeerTCP:
		return status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR
	return false


func _can_exchange_data() -> bool:
	if _stream == null:
		return false
	if not _stream.has_method("get_status"):
		return true
	var status := _variant_to_int(_stream.call("get_status"), 0)
	if _stream is StreamPeerTCP:
		return status == StreamPeerTCP.STATUS_CONNECTED
	return status != 0


func _set_disconnected(should_reconnect: bool) -> void:
	if _stream != null and _stream.has_method("disconnect_from_host"):
		_stream.call("disconnect_from_host")

	_stream = null
	_read_buffer = PackedByteArray()
	_connected = false
	_auth_pending = false
	_auth_request_id = -1
	_session_nonce = ""
	if not _pending_requests.is_empty():
		for request_id_variant in _pending_requests.keys():
			var request_id := _variant_to_int(request_id_variant, -1)
			if request_id < 0:
				continue
			var pending: Dictionary = _pending_requests[request_id]
			pending["completed"] = true
			pending["response"] = {
				"id": request_id,
				"error": {
					"code": ERR_CONNECTION_ERROR,
					"message": "Disconnected from Local Bridge.",
				},
			}
			_pending_requests[request_id] = pending
			emit_signal("rpc_response_received", request_id, pending["response"])

	emit_signal("bridge_connection_changed", false)
	_dispatch_event("bridge.disconnected", {
		"socket_path": _socket_path,
		"reconnect_scheduled": should_reconnect,
	})
	if should_reconnect:
		_schedule_reconnect()
	elif _reconnect_timer != null:
		_reconnect_timer.stop()


func _schedule_reconnect() -> void:
	if _reconnect_timer == null or _socket_path.is_empty():
		return
	if _reconnect_timer.is_stopped():
		_reconnect_timer.start(RECONNECT_DELAY_SEC)


func _ensure_reconnect_timer() -> void:
	if _reconnect_timer != null and is_instance_valid(_reconnect_timer):
		return
	_reconnect_timer = Timer.new()
	_reconnect_timer.name = "BridgeReconnectTimer"
	_reconnect_timer.one_shot = true
	_reconnect_timer.wait_time = RECONNECT_DELAY_SEC
	_reconnect_timer.timeout.connect(_on_reconnect_timeout)
	add_child(_reconnect_timer)


func _describe_transport() -> String:
	if _looks_like_tcp_endpoint(_socket_path):
		return "tcp"
	return "unix"


func _looks_like_tcp_endpoint(value: String) -> bool:
	var normalized := value.strip_edges()
	if normalized.begins_with("tcp://"):
		return true
	var separator_index := normalized.rfind(":")
	if separator_index <= 0 or separator_index >= normalized.length() - 1:
		return false
	var candidate_port := normalized.substr(separator_index + 1)
	return candidate_port.is_valid_int()


func _parse_tcp_endpoint(value: String) -> Dictionary:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return {
			"host": DEFAULT_TCP_HOST,
			"port": DEFAULT_TCP_PORT,
		}

	if normalized.begins_with("tcp://"):
		normalized = normalized.substr(6)

	var separator_index := normalized.rfind(":")
	if separator_index == -1:
		return {}

	var host := normalized.substr(0, separator_index).strip_edges()
	var raw_port := normalized.substr(separator_index + 1).strip_edges()
	if host.is_empty() or not raw_port.is_valid_int():
		return {}

	return {
		"host": host,
		"port": max(raw_port.to_int(), 1),
	}


func _extract_result_dictionary(response: Dictionary) -> Dictionary:
	var result: Variant = response.get("result", {})
	if result is Dictionary:
		return result.duplicate(true)
	if result is Array:
		return {"items": result.duplicate(true)}
	return {"value": result}


func _extract_error_dictionary(response: Dictionary) -> Dictionary:
	var error_payload: Variant = response.get("error", {})
	if error_payload is Dictionary:
		return error_payload.duplicate(true)
	return {}


func _get_pending_request(request_id: int) -> Dictionary:
	var pending: Variant = _pending_requests.get(request_id, {})
	if pending is Dictionary:
		return pending.duplicate(true)
	return {}


func _dispatch_event(event_name: String, payload: Dictionary) -> void:
	if _event_bus == null or not is_instance_valid(_event_bus):
		return
	var event_payload := payload.duplicate(true)
	if _event_bus.has_method("publish"):
		_event_bus.call("publish", event_name, event_payload)
		return
	if _event_bus.has_method("dispatch"):
		_event_bus.call("dispatch", event_name, event_payload)
		return
	if _event_bus.has_method("emit_event"):
		_event_bus.call("emit_event", event_name, event_payload)
		return
	if _event_bus.has_signal("event_emitted"):
		_event_bus.emit_signal("event_emitted", event_name, event_payload)


func _generate_nonce() -> String:
	return "nonce_%s_%s_%s" % [
		str(Time.get_unix_time_from_system()),
		str(Time.get_ticks_usec()),
		str(randi()),
	]


func _variant_to_int(value: Variant, default_value: int = 0) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and value.is_valid_int():
		return value.to_int()
	return default_value


func _clone_variant(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return value.duplicate(true)
	if value is PackedStringArray:
		var clone := PackedStringArray()
		for item in value:
			clone.append(item)
		return clone
	return value
