@tool
class_name LogBundle
extends RefCounted


const ERROR_LEVELS := {
	"error": true,
	"critical": true,
}


var bundle_id: String = ""
var work_item_id: String = ""
var task_run_id: String = ""
var entries: Array[Dictionary] = []
var context: Dictionary = {}
var created_at: String = ""


func to_dict() -> Dictionary:
	return {
		"bundle_id": bundle_id,
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"entries": _clone_dictionary_array(entries),
		"context": context.duplicate(true),
		"created_at": created_at,
	}


static func from_dict(data: Dictionary) -> LogBundle:
	var bundle := LogBundle.new()
	bundle.bundle_id = _string_value(data.get("bundle_id", ""))
	bundle.work_item_id = _string_value(data.get("work_item_id", ""))
	bundle.task_run_id = _string_value(data.get("task_run_id", ""))
	bundle.entries = _sanitize_entries(data.get("entries", []))
	bundle.context = _sanitize_context(data.get("context", {}))
	bundle.created_at = _string_value(data.get("created_at", ""))
	return bundle


func get_errors() -> Array[Dictionary]:
	var error_entries: Array[Dictionary] = []
	for entry in entries:
		var level := _string_value(entry.get("level", "")).to_lower()
		if ERROR_LEVELS.has(level):
			error_entries.append(entry.duplicate(true))
	return error_entries


func get_entries_by_source(source: String) -> Array[Dictionary]:
	var matching_entries: Array[Dictionary] = []
	var normalized_source := source.strip_edges().to_lower()

	for entry in entries:
		if _string_value(entry.get("source", "")).to_lower() == normalized_source:
			matching_entries.append(entry.duplicate(true))

	return matching_entries


func add_entry(entry: Dictionary) -> void:
	entries.append(_sanitize_entry(entry))


func get_entry_count() -> int:
	return entries.size()


static func _sanitize_entries(value: Variant) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				normalized.append(_sanitize_entry(item))
	return normalized


static func _sanitize_entry(entry: Dictionary) -> Dictionary:
	return {
		"timestamp": _string_value(entry.get("timestamp", "")),
		"source": _string_value(entry.get("source", "")),
		"level": _string_value(entry.get("level", "")),
		"file_context": _string_value(entry.get("file_context", "")),
		"scene_context": _string_value(entry.get("scene_context", "")),
		"node_context": _string_value(entry.get("node_context", "")),
		"message": _string_value(entry.get("message", "")),
		"stack_trace": _string_value(entry.get("stack_trace", "")),
	}


static func _sanitize_context(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value.duplicate(true)
	return {}


static func _clone_dictionary_array(entries_to_clone: Array[Dictionary]) -> Array[Dictionary]:
	var cloned: Array[Dictionary] = []
	for entry in entries_to_clone:
		cloned.append(entry.duplicate(true))
	return cloned


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value)
