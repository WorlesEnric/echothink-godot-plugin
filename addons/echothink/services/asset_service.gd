@tool
class_name EchoThinkAssetService
extends RefCounted


const ASSET_SEARCH_ENDPOINT := "/assets/search"
const ASSET_PUSH_METHOD := "asset.push"
const ASSET_PULL_METHOD := "asset.pull"
const ASSET_DIFF_METHOD := "asset.preview_diff"
const ASSET_VALIDATE_IMPORT_METHOD := "asset.validate_import"
const ASSET_LOCK_UPDATE_METHOD := "asset.lock.update"


var _bridge_client: EchoThinkBridgeClient = null
var _gateway_client: EchoThinkGatewayClient = null
var _changeset_manager: Object = null
var _event_bus: Object = null


func initialize(bridge: EchoThinkBridgeClient, gateway: EchoThinkGatewayClient, changeset_mgr: Object, events: Object) -> void:
	_bridge_client = bridge
	_gateway_client = gateway
	_changeset_manager = changeset_mgr
	_event_bus = events


func search_assets(query: Dictionary) -> Array[AssetBundle]:
	if _gateway_client == null:
		return []
	var response := await _gateway_client.api_request(ASSET_SEARCH_ENDPOINT, HTTPClient.METHOD_POST, query)
	var payload: Variant = response.get("bundles", response.get("items", []))
	return _asset_bundles_from_variant(payload)


func get_asset_details(asset_id: String) -> Dictionary:
	if asset_id.strip_edges().is_empty() or _gateway_client == null:
		return {}
	var response := await _gateway_client.api_request("/assets/%s" % asset_id, HTTPClient.METHOD_GET, {})
	if response.has("asset") and response["asset"] is Dictionary:
		return response["asset"].duplicate(true)
	return response.duplicate(true)


func preview_diff(asset_id: String) -> Dictionary:
	if asset_id.strip_edges().is_empty():
		return {}

	if _bridge_client != null:
		var bridge_response := await _bridge_client.send_request(ASSET_DIFF_METHOD, {
			"asset_id": asset_id,
		})
		if not bridge_response.has("error"):
			return _extract_result_dictionary(bridge_response)

	if _gateway_client == null:
		return {}
	var response := await _gateway_client.api_request("/assets/%s/diff" % asset_id, HTTPClient.METHOD_GET, {})
	if response.has("diff") and response["diff"] is Dictionary:
		return response["diff"].duplicate(true)
	return response.duplicate(true)


func pull_asset(asset_id: String, ref: String) -> Dictionary:
	if asset_id.strip_edges().is_empty() or _bridge_client == null:
		return {
			"ok": false,
			"error": {
				"message": "Bridge client is unavailable.",
			},
		}

	var response := await _bridge_client.send_request(ASSET_PULL_METHOD, {
		"asset_id": asset_id,
		"ref": ref.strip_edges(),
	})
	if response.has("error"):
		_dispatch_event("asset.pull_failed", {
			"asset_id": asset_id,
			"error": _extract_error_dictionary(response),
		})
		return response

	var result := _extract_result_dictionary(response)
	_track_changeset(result)
	_dispatch_event("asset.pulled", {
		"asset_id": asset_id,
		"result": result,
	})
	return result


func push_assets(paths: PackedStringArray) -> Dictionary:
	if _bridge_client == null:
		return {
			"ok": false,
			"error": {
				"message": "Bridge client is unavailable.",
			},
		}

	var response := await _bridge_client.send_request(ASSET_PUSH_METHOD, {
		"paths": _packed_to_array(paths),
	})
	if response.has("error"):
		_dispatch_event("asset.push_failed", {
			"paths": _packed_to_array(paths),
			"error": _extract_error_dictionary(response),
		})
		return response

	var result := _extract_result_dictionary(response)
	_dispatch_event("asset.pushed", {
		"paths": _packed_to_array(paths),
		"result": result,
	})
	return result


func validate_import(bundle_id: String) -> Dictionary:
	if bundle_id.strip_edges().is_empty() or _bridge_client == null:
		return {}
	var response := await _bridge_client.send_request(ASSET_VALIDATE_IMPORT_METHOD, {
		"bundle_id": bundle_id,
	})
	if response.has("error"):
		return response
	return _extract_result_dictionary(response)


func request_regenerate(asset_id: String, feedback: Dictionary) -> String:
	if asset_id.strip_edges().is_empty() or _gateway_client == null:
		return ""
	var response := await _gateway_client.api_request("/assets/%s/regenerate" % asset_id, HTTPClient.METHOD_POST, {
		"feedback": feedback.duplicate(true),
	})
	var request_id := String(response.get("request_id", response.get("job_id", ""))).strip_edges()
	if not request_id.is_empty():
		_dispatch_event("asset.regeneration_requested", {
			"asset_id": asset_id,
			"request_id": request_id,
		})
	return request_id


func request_promote(asset_id: String) -> String:
	if asset_id.strip_edges().is_empty() or _gateway_client == null:
		return ""
	var response := await _gateway_client.api_request("/assets/%s/promote" % asset_id, HTTPClient.METHOD_POST, {})
	var request_id := String(response.get("request_id", response.get("promotion_id", ""))).strip_edges()
	if not request_id.is_empty():
		_dispatch_event("asset.promotion_requested", {
			"asset_id": asset_id,
			"request_id": request_id,
		})
	return request_id


func update_lock_file(assets: Dictionary) -> bool:
	if _bridge_client == null:
		return false
	var response := await _bridge_client.send_request(ASSET_LOCK_UPDATE_METHOD, {
		"assets": assets.duplicate(true),
	})
	if response.has("error"):
		return false
	var result := _extract_result_dictionary(response)
	return bool(result.get("success", true))


func _track_changeset(result: Dictionary) -> void:
	if _changeset_manager == null or not is_instance_valid(_changeset_manager):
		return
	if not result.has("changeset") or not (result["changeset"] is Dictionary):
		return
	var change_set := ChangeSet.from_dict(result["changeset"])
	if _changeset_manager.has_method("register_changeset"):
		_changeset_manager.call("register_changeset", change_set)
	elif _changeset_manager.has_method("store_changeset"):
		_changeset_manager.call("store_changeset", change_set)


func _asset_bundles_from_variant(value: Variant) -> Array[AssetBundle]:
	var bundles: Array[AssetBundle] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				bundles.append(AssetBundle.from_dict(item))
	return bundles


func _extract_result_dictionary(response: Dictionary) -> Dictionary:
	var result: Variant = response.get("result", {})
	if result is Dictionary:
		return result.duplicate(true)
	if result is Array:
		return {"items": result.duplicate(true)}
	return {}


func _extract_error_dictionary(response: Dictionary) -> Dictionary:
	var error_payload: Variant = response.get("error", {})
	if error_payload is Dictionary:
		return error_payload.duplicate(true)
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
