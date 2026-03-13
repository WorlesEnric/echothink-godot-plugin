@tool
class_name TaskEnvelope
extends RefCounted


var work_item_id: String = ""
var task_run_id: String = ""
var kind: String = ""
var objective: String = ""
var acceptance_criteria: PackedStringArray = PackedStringArray()
var status: String = ""
var risk_level: String = ""
var approval_policy: String = ""
var priority: int = 0
var assigned_worker: String = ""
var created_at: String = ""
var updated_at: String = ""
var evidence_json: Dictionary = {}
var constraints_json: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"kind": kind,
		"objective": objective,
		"acceptance_criteria": _packed_to_array(acceptance_criteria),
		"status": status,
		"risk_level": risk_level,
		"approval_policy": approval_policy,
		"priority": priority,
		"assigned_worker": assigned_worker,
		"created_at": created_at,
		"updated_at": updated_at,
		"evidence_json": evidence_json.duplicate(true),
		"constraints_json": constraints_json.duplicate(true),
	}


static func from_dict(data: Dictionary) -> TaskEnvelope:
	var envelope := TaskEnvelope.new()
	envelope.work_item_id = _get_string(data, "work_item_id")
	envelope.task_run_id = _get_string(data, "task_run_id")
	envelope.kind = _get_string(data, "kind")
	envelope.objective = _get_string(data, "objective")
	envelope.acceptance_criteria = _variant_to_string_array(data.get("acceptance_criteria", PackedStringArray()))
	envelope.status = _get_string(data, "status")
	envelope.risk_level = _get_string(data, "risk_level")
	envelope.approval_policy = _get_string(data, "approval_policy")
	envelope.priority = _get_int(data, "priority")
	envelope.assigned_worker = _get_string(data, "assigned_worker")
	envelope.created_at = _get_string(data, "created_at")
	envelope.updated_at = _get_string(data, "updated_at")
	envelope.evidence_json = _get_dictionary(data, "evidence_json")
	envelope.constraints_json = _get_dictionary(data, "constraints_json")
	return envelope


func is_actionable() -> bool:
	var normalized_status := status.strip_edges().to_lower()
	return normalized_status == "pending" or normalized_status == "in_progress"


func requires_approval() -> bool:
	var normalized_policy := approval_policy.strip_edges().to_lower()
	if normalized_policy.is_empty():
		return false
	return normalized_policy != "never" and normalized_policy != "none" and normalized_policy != "auto" and normalized_policy != "automatic"


static func _get_string(data: Dictionary, key: String, default_value: String = "") -> String:
	var value: Variant = data.get(key, default_value)
	if value == null:
		return default_value.strip_edges()
	return String(value).strip_edges()


static func _get_int(data: Dictionary, key: String, default_value: int = 0) -> int:
	return int(data.get(key, default_value))


static func _get_dictionary(data: Dictionary, key: String) -> Dictionary:
	var value: Variant = data.get(key, {})
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		return dictionary_value.duplicate(true)
	return {}


static func _variant_to_string_array(value: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if value is PackedStringArray or value is Array:
		for entry in value:
			var text := String(entry).strip_edges()
			if not text.is_empty():
				result.append(text)
	elif value != null:
		var single_value := String(value).strip_edges()
		if not single_value.is_empty():
			result.append(single_value)
	return result


static func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result
