@tool
class_name EchoThinkLogService
extends RefCounted


const LOGS_COLLECT_METHOD := "logs.collect"
const LOG_ANALYSIS_ENDPOINT := "/logs/analysis"
const TEST_RUNS_ENDPOINT := "/tests/runs"


var _bridge_client: EchoThinkBridgeClient = null
var _gateway_client: EchoThinkGatewayClient = null
var _event_bus: Object = null
var _current_bundle: LogBundle = null


func initialize(bridge: EchoThinkBridgeClient, gateway: EchoThinkGatewayClient, events: Object) -> void:
	_bridge_client = bridge
	_gateway_client = gateway
	_event_bus = events
	if _current_bundle == null:
		_current_bundle = _create_bundle()


func collect_logs(sources: PackedStringArray) -> LogBundle:
	_ensure_bundle()
	if _bridge_client == null:
		return _build_local_bundle_from_sources(sources)

	var response := await _bridge_client.send_request(LOGS_COLLECT_METHOD, {
		"sources": _packed_to_array(sources),
	})
	if response.has("error"):
		return _build_local_bundle_from_sources(sources)

	var result := _extract_result_dictionary(response)
	if result.has("bundle") and result["bundle"] is Dictionary:
		_current_bundle = LogBundle.from_dict(result["bundle"])
	elif not result.is_empty():
		_current_bundle = LogBundle.from_dict(result)
	_dispatch_event("logs.collected", {
		"bundle_id": _current_bundle.bundle_id,
		"sources": _packed_to_array(sources),
	})
	return _current_bundle


func submit_for_analysis(bundle: LogBundle) -> String:
	if _gateway_client == null:
		return ""
	var response := await _gateway_client.api_request(LOG_ANALYSIS_ENDPOINT, HTTPClient.METHOD_POST, {
		"bundle": bundle.to_dict(),
	})
	var request_id := String(response.get("request_id", response.get("analysis_id", ""))).strip_edges()
	if not request_id.is_empty():
		_dispatch_event("logs.analysis_requested", {
			"bundle_id": bundle.bundle_id,
			"request_id": request_id,
		})
	return request_id


func get_analysis_results(request_id: String) -> Dictionary:
	if request_id.strip_edges().is_empty() or _gateway_client == null:
		return {}
	return await _gateway_client.api_request("%s/%s" % [LOG_ANALYSIS_ENDPOINT, request_id], HTTPClient.METHOD_GET, {})


func submit_test_run(strategy_id: String) -> TestRunRecord:
	_ensure_bundle()
	if strategy_id.strip_edges().is_empty() or _gateway_client == null:
		return TestRunRecord.new()
	var response := await _gateway_client.api_request(TEST_RUNS_ENDPOINT, HTTPClient.METHOD_POST, {
		"strategy_id": strategy_id,
		"bundle_id": _current_bundle.bundle_id,
	})
	if response.has("test_run") and response["test_run"] is Dictionary:
		return TestRunRecord.from_dict(response["test_run"])
	return TestRunRecord.from_dict(response)


func get_test_results(record_id: String) -> TestRunRecord:
	if record_id.strip_edges().is_empty() or _gateway_client == null:
		return TestRunRecord.new()
	var response := await _gateway_client.api_request("%s/%s" % [TEST_RUNS_ENDPOINT, record_id], HTTPClient.METHOD_GET, {})
	if response.has("test_run") and response["test_run"] is Dictionary:
		return TestRunRecord.from_dict(response["test_run"])
	return TestRunRecord.from_dict(response)


func add_log_entry(source: String, level: String, message: String, context: Dictionary) -> void:
	_ensure_bundle()
	_current_bundle.add_entry({
		"timestamp": str(Time.get_unix_time_from_system()),
		"source": source.strip_edges(),
		"level": level.strip_edges(),
		"file_context": String(context.get("file_context", context.get("file", ""))).strip_edges(),
		"scene_context": String(context.get("scene_context", context.get("scene", ""))).strip_edges(),
		"node_context": String(context.get("node_context", context.get("node", ""))).strip_edges(),
		"message": message,
		"stack_trace": String(context.get("stack_trace", context.get("stack", ""))).strip_edges(),
	})
	_dispatch_event("logs.entry_added", {
		"bundle_id": _current_bundle.bundle_id,
		"source": source.strip_edges(),
		"level": level.strip_edges(),
	})


func _ensure_bundle() -> void:
	if _current_bundle == null:
		_current_bundle = _create_bundle()


func _create_bundle() -> LogBundle:
	var bundle := LogBundle.new()
	bundle.bundle_id = _generate_id("logbundle")
	bundle.created_at = str(Time.get_unix_time_from_system())
	return bundle


func _build_local_bundle_from_sources(sources: PackedStringArray) -> LogBundle:
	_ensure_bundle()
	if sources.is_empty():
		return _current_bundle

	var filtered_bundle := LogBundle.new()
	filtered_bundle.bundle_id = _generate_id("logbundle")
	filtered_bundle.created_at = str(Time.get_unix_time_from_system())
	filtered_bundle.context = _current_bundle.context.duplicate(true)
	for source in sources:
		for entry in _current_bundle.get_entries_by_source(source):
			filtered_bundle.add_entry(entry)
	_current_bundle = filtered_bundle
	return _current_bundle


func _extract_result_dictionary(response: Dictionary) -> Dictionary:
	var result: Variant = response.get("result", {})
	if result is Dictionary:
		return result.duplicate(true)
	if result is Array:
		return {"items": result.duplicate(true)}
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


func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result


func _generate_id(prefix: String) -> String:
	return "%s_%s_%s" % [prefix, str(Time.get_unix_time_from_system()), str(Time.get_ticks_usec())]
