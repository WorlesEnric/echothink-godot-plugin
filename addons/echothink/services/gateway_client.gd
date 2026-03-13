@tool
class_name EchoThinkGatewayClient
extends Node


signal api_request_completed(endpoint: String, response: Dictionary)
signal ws_event_received(event_name: String, payload: Dictionary)


const EVENT_STREAM_SUFFIX := "/events"
const ALLOWED_EVENTS := {
	"task.updated": true,
	"approval.pending": true,
	"approval.decided": true,
	"plan.ready": true,
	"patch.ready": true,
	"asset_bundle.ready": true,
	"publish.completed": true,
	"publish.failed": true,
	"diagnostics.ready": true,
	"bridge.health_changed": true,
}


var _gateway_url: String = ""
var _session_token: String = ""
var _ws: WebSocketPeer = null
var _http: HTTPRequest = null
var _event_bus: Object = null
var _ws_connected: bool = false

var _api_request_active: bool = false


func _ready() -> void:
	set_process(true)
	_ensure_http_client()


func initialize(gateway_url: String, session_token: String, event_bus: Object) -> void:
	_gateway_url = gateway_url.strip_edges()
	_session_token = session_token.strip_edges()
	_event_bus = event_bus
	_ensure_http_client()
	if _ws == null:
		_ws = WebSocketPeer.new()


func connect_event_stream() -> void:
	if _ws == null:
		_ws = WebSocketPeer.new()
	if _ws_connected:
		return

	var ws_url := _build_ws_url()
	if ws_url.is_empty():
		_dispatch_event("gateway.ws_connection_failed", {
			"message": "Gateway URL is empty.",
		})
		return

	var headers := _build_auth_headers()
	var connect_error := _ws.connect_to_url(ws_url, headers)
	if connect_error != OK:
		_dispatch_event("gateway.ws_connection_failed", {
			"url": ws_url,
			"error_code": connect_error,
		})


func disconnect_event_stream() -> void:
	if _ws != null:
		_ws.disconnect_from_host(1000, "client_disconnect")
	_ws_connected = false
	_dispatch_event("gateway.ws_disconnected", {
		"url": _build_ws_url(),
	})


func api_request(endpoint: String, method: int, body: Dictionary) -> Dictionary:
	_ensure_http_client()
	if _http == null:
		return {
			"ok": false,
			"error": {
				"code": ERR_UNAVAILABLE,
				"message": "HTTPRequest client is unavailable.",
			},
		}

	if get_tree() == null:
		return {
			"ok": false,
			"error": {
				"code": ERR_UNAVAILABLE,
				"message": "Gateway client must be inside the scene tree before awaiting requests.",
			},
		}

	while _api_request_active:
		await get_tree().process_frame

	_api_request_active = true
	var request_url := _build_api_url(endpoint)
	var headers := _build_auth_headers()
	headers.append("Accept: application/json")
	var request_body := ""
	if method != HTTPClient.METHOD_GET and method != HTTPClient.METHOD_HEAD:
		headers.append("Content-Type: application/json")
		request_body = JSON.stringify(body)

	var request_error := _http.request(request_url, headers, method, request_body)
	if request_error != OK:
		_api_request_active = false
		return {
			"ok": false,
			"status_code": 0,
			"endpoint": endpoint,
			"error": {
				"code": request_error,
				"message": "Failed to start HTTP request.",
			},
		}

	var completed: Array = await _http.request_completed
	_api_request_active = false

	var request_result := int(completed[0])
	var response_code := int(completed[1])
	var response_body: PackedByteArray = completed[3]
	var response_text := response_body.get_string_from_utf8()
	var parsed: Variant = {}
	if not response_text.strip_edges().is_empty():
		parsed = JSON.parse_string(response_text)

	var response: Dictionary = {}
	if parsed is Dictionary:
		response = parsed.duplicate(true)
	elif parsed is Array:
		response = {"items": parsed.duplicate(true)}
	else:
		response = {}
		if not response_text.strip_edges().is_empty():
			response["raw_body"] = response_text

	response["ok"] = request_result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300 and not response.has("error")
	response["status_code"] = response_code
	response["endpoint"] = endpoint
	emit_signal("api_request_completed", endpoint, response)
	return response


func _process(_delta: float) -> void:
	if _ws == null:
		return

	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _ws_connected:
				_ws_connected = true
				_dispatch_event("gateway.ws_connected", {
					"url": _build_ws_url(),
				})
			while _ws.get_available_packet_count() > 0:
				var packet := _ws.get_packet()
				var message := packet.get_string_from_utf8()
				_handle_ws_message(message)
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			if _ws_connected:
				_ws_connected = false
				_dispatch_event("gateway.ws_disconnected", {
					"code": _ws.get_close_code(),
					"reason": _ws.get_close_reason(),
				})


func _handle_ws_message(data: String) -> void:
	var parsed: Variant = JSON.parse_string(data)
	if not (parsed is Dictionary):
		_dispatch_event("gateway.ws_protocol_error", {
			"message": "Received malformed WebSocket payload.",
			"payload": data,
		})
		return

	var envelope: Dictionary = parsed
	var event_name := String(envelope.get("event", envelope.get("type", envelope.get("method", "")))).strip_edges()
	if event_name.is_empty():
		_dispatch_event("gateway.ws_protocol_error", {
			"message": "WebSocket event payload did not include an event name.",
			"payload": envelope.duplicate(true),
		})
		return

	var payload: Dictionary = {}
	var candidate_payload: Variant = envelope.get("payload", envelope.get("data", envelope.get("params", {})))
	if candidate_payload is Dictionary:
		payload = candidate_payload.duplicate(true)
	else:
		payload = {"value": candidate_payload}
	payload["event"] = event_name
	payload["raw"] = envelope.duplicate(true)

	if ALLOWED_EVENTS.has(event_name):
		_dispatch_event(event_name, payload)
	emit_signal("ws_event_received", event_name, payload)


func _ensure_http_client() -> void:
	if _http != null and is_instance_valid(_http):
		if _http.get_parent() == null and is_inside_tree():
			add_child(_http)
		return
	_http = HTTPRequest.new()
	_http.name = "GatewayHttpRequest"
	if is_inside_tree():
		add_child(_http)
	else:
		call_deferred("add_child", _http)


func _build_api_url(endpoint: String) -> String:
	var normalized_endpoint := endpoint.strip_edges()
	if normalized_endpoint.begins_with("http://") or normalized_endpoint.begins_with("https://"):
		return normalized_endpoint
	var base_url := _gateway_url.strip_edges()
	if base_url.begins_with("ws://"):
		base_url = "http://" + base_url.substr(5)
	elif base_url.begins_with("wss://"):
		base_url = "https://" + base_url.substr(6)
	base_url = _trim_trailing_slash(base_url)
	if normalized_endpoint.is_empty():
		return base_url
	if not normalized_endpoint.begins_with("/"):
		normalized_endpoint = "/" + normalized_endpoint
	return base_url + normalized_endpoint


func _build_ws_url() -> String:
	var base_url := _gateway_url.strip_edges()
	if base_url.is_empty():
		return ""

	if base_url.begins_with("http://"):
		base_url = "ws://" + base_url.substr(7)
	elif base_url.begins_with("https://"):
		base_url = "wss://" + base_url.substr(8)

	base_url = _trim_trailing_slash(base_url)
	if base_url.ends_with(EVENT_STREAM_SUFFIX):
		return base_url
	return base_url + EVENT_STREAM_SUFFIX


func _build_auth_headers() -> PackedStringArray:
	var headers := PackedStringArray()
	if not _session_token.is_empty():
		headers.append("Authorization: Bearer %s" % _session_token)
	return headers


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


func _trim_trailing_slash(value: String) -> String:
	var normalized := value
	while normalized.ends_with("/"):
		normalized = normalized.left(normalized.length() - 1)
	return normalized
