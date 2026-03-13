@tool
class_name EchoThinkPatchService
extends RefCounted


const PATCH_PREFLIGHT_METHOD := "patch.preflight"
const PATCH_APPLY_METHOD := "patch.apply"
const PATCH_GET_METHOD := "patch.get"
const PATCH_REQUEST_METHOD := "patch.request"
const CHANGESET_ROLLBACK_METHOD := "changeset.rollback"


var _bridge_client: EchoThinkBridgeClient = null
var _changeset_manager: Object = null
var _policy_guard: Object = null
var _event_bus: Object = null


func initialize(bridge: EchoThinkBridgeClient, changeset_mgr: Object, policy: Object, events: Object) -> void:
	_bridge_client = bridge
	_changeset_manager = changeset_mgr
	_policy_guard = policy
	_event_bus = events


func preflight_patch(patch: PatchProposal) -> Dictionary:
	var affected_files := _packed_to_array(patch.get_affected_files())
	var preflight := {
		"ok": true,
		"patch_id": patch.patch_id,
		"base_commit": patch.base_commit,
		"current_commit": "",
		"base_commit_matches": true,
		"dirty_files": [],
		"conflicting_files": [],
		"affected_files": affected_files,
		"policy": _evaluate_patch_policy(patch),
		"warnings": [],
		"errors": [],
	}

	if not bool(preflight["policy"].get("allowed", true)):
		preflight["ok"] = false
		var policy_reason := String(preflight["policy"].get("reason", "Patch blocked by policy guard."))
		var policy_errors: Array = preflight["errors"]
		policy_errors.append(policy_reason)
		preflight["errors"] = policy_errors

	if _bridge_client == null:
		var warnings: Array = preflight["warnings"]
		warnings.append("Bridge client is unavailable, remote preflight checks were skipped.")
		preflight["warnings"] = warnings
		return preflight

	var response := await _bridge_client.send_request(PATCH_PREFLIGHT_METHOD, {
		"patch": patch.to_dict(),
		"patch_id": patch.patch_id,
		"base_commit": patch.base_commit,
		"affected_files": affected_files,
	})
	if response.has("error"):
		preflight["ok"] = false
		var remote_errors: Array = preflight["errors"]
		remote_errors.append(_extract_error_message(response))
		preflight["errors"] = remote_errors
		return preflight

	var result := _extract_result_dictionary(response)
	preflight["current_commit"] = String(result.get("current_commit", result.get("head_commit", ""))).strip_edges()
	preflight["dirty_files"] = _variant_to_string_array(result.get("dirty_files", []))
	preflight["conflicting_files"] = _variant_to_string_array(result.get("conflicting_files", result.get("conflicts", [])))
	preflight["warnings"] = _variant_to_string_array(result.get("warnings", preflight["warnings"]))
	preflight["errors"] = _variant_to_string_array(result.get("errors", preflight["errors"]))

	if not patch.base_commit.is_empty() and not String(preflight["current_commit"]).is_empty():
		preflight["base_commit_matches"] = String(preflight["current_commit"]) == patch.base_commit

	var dirty_files: Array[String] = preflight.get("dirty_files", [])
	var conflicting_files: Array[String] = preflight.get("conflicting_files", [])
	var errors: Array[String] = preflight.get("errors", [])
	var policy_result: Dictionary = preflight.get("policy", {})
	preflight["ok"] = bool(preflight["policy"].get("allowed", true)) \
		and bool(preflight.get("base_commit_matches", true)) \
		and dirty_files.is_empty() \
		and conflicting_files.is_empty() \
		and errors.is_empty() \
		and bool(policy_result.get("allowed", true))
	return preflight


func apply_patch(patch: PatchProposal, selected_ops: Array[int]) -> ChangeSet:
	var change_set := _build_changeset_from_patch(patch, selected_ops)
	_track_changeset(change_set)

	var preflight := await preflight_patch(patch)
	if not bool(preflight.get("ok", false)):
		change_set.status = ChangeSet.STATUS_FAILED
		change_set.error_message = "; ".join(_variant_to_string_array(preflight.get("errors", [])))
		_track_changeset(change_set)
		_dispatch_event("patch.apply_failed", {
			"patch_id": patch.patch_id,
			"changeset_id": change_set.changeset_id,
			"preflight": preflight,
		})
		return change_set

	if _bridge_client == null:
		change_set.status = ChangeSet.STATUS_FAILED
		change_set.error_message = "Bridge client is unavailable."
		_track_changeset(change_set)
		return change_set

	var response := await _bridge_client.send_request(PATCH_APPLY_METHOD, {
		"patch_id": patch.patch_id,
		"changeset_id": change_set.changeset_id,
		"work_item_id": patch.work_item_id,
		"task_run_id": patch.task_run_id,
		"base_commit": patch.base_commit,
		"selected_ops": selected_ops.duplicate(),
		"operations": _clone_dictionary_array(change_set.operations),
	})
	if response.has("error"):
		change_set.status = ChangeSet.STATUS_FAILED
		change_set.error_message = _extract_error_message(response)
		_track_changeset(change_set)
		_dispatch_event("patch.apply_failed", {
			"patch_id": patch.patch_id,
			"changeset_id": change_set.changeset_id,
			"error": _extract_error_dictionary(response),
		})
		return change_set

	var result := _extract_result_dictionary(response)
	if result.has("changeset") and result["changeset"] is Dictionary:
		change_set = ChangeSet.from_dict(result["changeset"])
	else:
		if result.has("changeset_id"):
			change_set.changeset_id = String(result.get("changeset_id", change_set.changeset_id))
		if result.has("preimages") and result["preimages"] is Dictionary:
			change_set.preimages = result["preimages"].duplicate(true)
		if result.has("postimages") and result["postimages"] is Dictionary:
			change_set.postimages = result["postimages"].duplicate(true)
		if result.has("operations") and result["operations"] is Array:
			change_set.operations = _clone_dictionary_array(result["operations"])
		change_set.status = String(result.get("status", ChangeSet.STATUS_APPLIED)).strip_edges()
		change_set.error_message = String(result.get("error_message", "")).strip_edges()

	if change_set.status.is_empty():
		change_set.status = ChangeSet.STATUS_APPLIED
	_track_changeset(change_set)
	_dispatch_event("patch.applied", {
		"patch_id": patch.patch_id,
		"changeset_id": change_set.changeset_id,
		"changeset": change_set.to_dict(),
	})
	return change_set


func rollback_changeset(changeset_id: String) -> bool:
	if changeset_id.strip_edges().is_empty() or _bridge_client == null:
		return false

	var response := await _bridge_client.send_request(CHANGESET_ROLLBACK_METHOD, {
		"changeset_id": changeset_id,
	})
	if response.has("error"):
		_dispatch_event("changeset.rollback_failed", {
			"changeset_id": changeset_id,
			"error": _extract_error_dictionary(response),
		})
		return false

	var result := _extract_result_dictionary(response)
	var rolled_back := bool(result.get("success", true))
	if rolled_back:
		_update_changeset_status(changeset_id, ChangeSet.STATUS_ROLLED_BACK, "")
		_dispatch_event("changeset.rolled_back", {
			"changeset_id": changeset_id,
			"result": result,
		})
	else:
		_dispatch_event("changeset.rollback_failed", {
			"changeset_id": changeset_id,
			"result": result,
		})
	return rolled_back


func get_patch_details(patch_id: String) -> PatchProposal:
	if patch_id.strip_edges().is_empty() or _bridge_client == null:
		return PatchProposal.new()

	var response := await _bridge_client.send_request(PATCH_GET_METHOD, {
		"patch_id": patch_id,
	})
	if response.has("error"):
		return PatchProposal.new()

	var result := _extract_result_dictionary(response)
	if result.has("patch") and result["patch"] is Dictionary:
		return PatchProposal.from_dict(result["patch"])
	return PatchProposal.from_dict(result)


func request_new_patch(context: Dictionary) -> String:
	if _bridge_client == null:
		return ""
	var request_id := _bridge_client._send_rpc(PATCH_REQUEST_METHOD, context.duplicate(true))
	if request_id > 0:
		_dispatch_event("patch.requested", {
			"request_id": request_id,
			"context": context.duplicate(true),
		})
	if request_id > 0:
		return str(request_id)
	return ""


func _build_changeset_from_patch(patch: PatchProposal, selected_ops: Array[int]) -> ChangeSet:
	var change_set := ChangeSet.new()
	change_set.changeset_id = _generate_id("changeset")
	change_set.work_item_id = patch.work_item_id
	change_set.task_run_id = patch.task_run_id
	change_set.timestamp = str(Time.get_unix_time_from_system())
	change_set.operations = _select_patch_operations(patch, selected_ops)
	change_set.status = ChangeSet.STATUS_PENDING
	return change_set


func _select_patch_operations(patch: PatchProposal, selected_ops: Array[int]) -> Array[Dictionary]:
	if selected_ops.is_empty():
		return _clone_dictionary_array(patch.operations)

	var operations: Array[Dictionary] = []
	for index in selected_ops:
		if index < 0 or index >= patch.operations.size():
			continue
		operations.append(patch.operations[index].duplicate(true))
	return operations


func _evaluate_patch_policy(patch: PatchProposal) -> Dictionary:
	if _policy_guard == null or not is_instance_valid(_policy_guard):
		return {"allowed": true, "reason": ""}

	if _policy_guard.has_method("evaluate_patch"):
		var evaluation := _policy_guard.call("evaluate_patch", patch)
		if evaluation is Dictionary:
			return evaluation.duplicate(true)
		if evaluation is bool:
			return {"allowed": evaluation, "reason": ""}

	if _policy_guard.has_method("can_apply_patch"):
		var allowed := _policy_guard.call("can_apply_patch", patch)
		var denial_reason := ""
		if not bool(allowed):
			denial_reason = "Patch rejected by policy guard."
		return {
			"allowed": bool(allowed),
			"reason": denial_reason,
		}

	return {"allowed": true, "reason": ""}


func _track_changeset(change_set: ChangeSet) -> void:
	if _changeset_manager == null or not is_instance_valid(_changeset_manager):
		return
	if _changeset_manager.has_method("register_changeset"):
		_changeset_manager.call("register_changeset", change_set)
		return
	if _changeset_manager.has_method("store_changeset"):
		_changeset_manager.call("store_changeset", change_set)
		return
	if _changeset_manager.has_method("track_changeset"):
		_changeset_manager.call("track_changeset", change_set)


func _update_changeset_status(changeset_id: String, status: String, error_message: String) -> void:
	if _changeset_manager == null or not is_instance_valid(_changeset_manager):
		return
	if _changeset_manager.has_method("update_changeset_status"):
		_changeset_manager.call("update_changeset_status", changeset_id, status, error_message)


func _extract_result_dictionary(response: Dictionary) -> Dictionary:
	var result: Variant = response.get("result", {})
	if result is Dictionary:
		return result.duplicate(true)
	if result is Array:
		return {"items": result.duplicate(true)}
	return {}


func _extract_error_message(response: Dictionary) -> String:
	var error_payload: Dictionary = _extract_error_dictionary(response)
	if not error_payload.is_empty():
		return String(error_payload.get("message", "Unknown bridge error.")).strip_edges()
	return "Unknown bridge error."


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


func _variant_to_string_array(value: Variant) -> Array[String]:
	var strings: Array[String] = []
	if value is PackedStringArray or value is Array:
		for item in value:
			var text := String(item).strip_edges()
			if not text.is_empty():
				strings.append(text)
	elif value != null:
		var single_value := String(value).strip_edges()
		if not single_value.is_empty():
			strings.append(single_value)
	return strings


func _clone_dictionary_array(value: Variant) -> Array[Dictionary]:
	var cloned: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				cloned.append(item.duplicate(true))
	return cloned


func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result


func _generate_id(prefix: String) -> String:
	return "%s_%s_%s" % [prefix, str(Time.get_unix_time_from_system()), str(Time.get_ticks_usec())]
