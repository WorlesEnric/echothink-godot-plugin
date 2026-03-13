@tool
class_name PlanRevision
extends RefCounted


var plan_id: String = ""
var work_item_id: String = ""
var revision: int = 0
var tasks: Array[Dictionary] = []
var dependencies: Array[Dictionary] = []
var risks: Array[Dictionary] = []
var acceptance_criteria: PackedStringArray = PackedStringArray()
var estimated_cost: float = 0.0
var suggested_priority: int = 0
var status: String = ""
var created_at: String = ""


func to_dict() -> Dictionary:
	return {
		"plan_id": plan_id,
		"work_item_id": work_item_id,
		"revision": revision,
		"tasks": _duplicate_dictionary_array(tasks),
		"dependencies": _duplicate_dictionary_array(dependencies),
		"risks": _duplicate_dictionary_array(risks),
		"acceptance_criteria": _packed_to_array(acceptance_criteria),
		"estimated_cost": estimated_cost,
		"suggested_priority": suggested_priority,
		"status": status,
		"created_at": created_at,
	}


static func from_dict(data: Dictionary) -> PlanRevision:
	var revision_model := PlanRevision.new()
	revision_model.plan_id = _get_string(data, "plan_id")
	revision_model.work_item_id = _get_string(data, "work_item_id")
	revision_model.revision = _get_int(data, "revision")
	revision_model.tasks = _get_dictionary_array(data, "tasks")
	revision_model.dependencies = _get_dictionary_array(data, "dependencies")
	revision_model.risks = _get_dictionary_array(data, "risks")
	revision_model.acceptance_criteria = _variant_to_string_array(data.get("acceptance_criteria", PackedStringArray()))
	revision_model.estimated_cost = _get_float(data, "estimated_cost")
	revision_model.suggested_priority = _get_int(data, "suggested_priority")
	revision_model.status = _get_string(data, "status")
	revision_model.created_at = _get_string(data, "created_at")
	return revision_model


func get_task_count() -> int:
	return tasks.size()


func get_pending_tasks() -> Array[Dictionary]:
	var pending_tasks: Array[Dictionary] = []
	for task in tasks:
		var task_status := String(task.get("status", "pending")).strip_edges().to_lower()
		if task_status.is_empty() or task_status == "pending":
			pending_tasks.append(task.duplicate(true))
	return pending_tasks


static func _get_string(data: Dictionary, key: String, default_value: String = "") -> String:
	var value: Variant = data.get(key, default_value)
	if value == null:
		return default_value.strip_edges()
	return String(value).strip_edges()


static func _get_int(data: Dictionary, key: String, default_value: int = 0) -> int:
	return int(data.get(key, default_value))


static func _get_float(data: Dictionary, key: String, default_value: float = 0.0) -> float:
	return float(data.get(key, default_value))


static func _get_dictionary_array(data: Dictionary, key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var value: Variant = data.get(key, [])
	if value is Array:
		for entry in value:
			if entry is Dictionary:
				var dictionary_entry: Dictionary = entry
				result.append(dictionary_entry.duplicate(true))
	return result


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


static func _duplicate_dictionary_array(values: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in values:
		result.append(value.duplicate(true))
	return result


static func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result
