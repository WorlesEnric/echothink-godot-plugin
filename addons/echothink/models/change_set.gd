@tool
class_name ChangeSet
extends RefCounted


const STATUS_PENDING := "pending"
const STATUS_APPLIED := "applied"
const STATUS_ROLLED_BACK := "rolled_back"
const STATUS_FAILED := "failed"


var changeset_id: String = ""
var work_item_id: String = ""
var task_run_id: String = ""
var timestamp: String = ""
var operations: Array[Dictionary] = []
var preimages: Dictionary = {}
var postimages: Dictionary = {}
var status: String = STATUS_PENDING
var error_message: String = ""


func to_dict() -> Dictionary:
	return {
		"changeset_id": changeset_id,
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"timestamp": timestamp,
		"operations": _clone_dictionary_array(operations),
		"preimages": preimages.duplicate(true),
		"postimages": postimages.duplicate(true),
		"status": status,
		"error_message": error_message,
	}


static func from_dict(data: Dictionary) -> ChangeSet:
	var change_set := ChangeSet.new()
	change_set.changeset_id = _string_value(data.get("changeset_id", ""))
	change_set.work_item_id = _string_value(data.get("work_item_id", ""))
	change_set.task_run_id = _string_value(data.get("task_run_id", ""))
	change_set.timestamp = _string_value(data.get("timestamp", ""))
	change_set.operations = _sanitize_operations(data.get("operations", []))
	change_set.preimages = _sanitize_string_dictionary(data.get("preimages", {}))
	change_set.postimages = _sanitize_string_dictionary(data.get("postimages", {}))
	change_set.status = _string_value(data.get("status", STATUS_PENDING), STATUS_PENDING)
	change_set.error_message = _string_value(data.get("error_message", ""))
	return change_set


func is_rollbackable() -> bool:
	if status.to_lower() != STATUS_APPLIED:
		return false

	for operation in operations:
		if not _bool_value(operation.get("reversible", false)):
			return false

	return true


func get_affected_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var seen: Dictionary = {}

	for operation in operations:
		var path := _string_value(operation.get("path", ""))
		if path.is_empty() or seen.has(path):
			continue

		seen[path] = true
		paths.append(path)

	return paths


static func _sanitize_operations(value: Variant) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				normalized.append(_sanitize_operation(item))
	return normalized


static func _sanitize_operation(operation: Dictionary) -> Dictionary:
	return {
		"type": _string_value(operation.get("type", "")),
		"path": _string_value(operation.get("path", "")),
		"description": _string_value(operation.get("description", "")),
		"reversible": _bool_value(operation.get("reversible", false)),
	}


static func _sanitize_string_dictionary(value: Variant) -> Dictionary:
	var normalized: Dictionary = {}
	if value is Dictionary:
		for key in value.keys():
			normalized[_string_value(key)] = _string_value(value[key])
	return normalized


static func _clone_dictionary_array(entries: Array[Dictionary]) -> Array[Dictionary]:
	var cloned: Array[Dictionary] = []
	for entry in entries:
		cloned.append(entry.duplicate(true))
	return cloned


static func _bool_value(value: Variant, default_value: bool = false) -> bool:
	if value is bool:
		return value
	if value is int:
		return value != 0
	if value is float:
		return not is_zero_approx(value)
	if value is String:
		var normalized := value.strip_edges().to_lower()
		if normalized in ["true", "1", "yes", "y", "on"]:
			return true
		if normalized in ["false", "0", "no", "n", "off", ""]:
			return false
	return default_value


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value)
