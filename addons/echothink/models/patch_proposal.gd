@tool
class_name PatchProposal
extends RefCounted


const OPERATION_TEXT_PATCH := "text_patch"
const OPERATION_SCENE_OP := "scene_op"
const OPERATION_RESOURCE_OP := "resource_op"
const OPERATION_ASSET_IMPORT := "asset_import"
const OPERATION_PROJECT_SETTING_SET := "project_setting_set"

const _SINGULAR_PATH_KEYS := [
	"path",
	"target_path",
	"file",
	"file_path",
	"scene_path",
	"resource_path",
	"asset_path",
	"source_path",
]
const _COLLECTION_PATH_KEYS := [
	"paths",
	"target_paths",
	"files",
	"file_paths",
	"affected_files",
	"resource_paths",
]
const _TYPE_KEYS := ["type", "operation_type", "kind"]
const _ACTION_KEYS := ["action", "op", "operation", "mode"]


var patch_id: String = ""
var work_item_id: String = ""
var task_run_id: String = ""
var base_project: String = ""
var base_branch: String = ""
var base_commit: String = ""
var operations: Array[Dictionary] = []
var validation_plan: PackedStringArray = PackedStringArray()
var publish_intent: String = ""
var risk_summary: String = ""
var created_at: String = ""


func to_dict() -> Dictionary:
	return {
		"patch_id": patch_id,
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"base_project": base_project,
		"base_branch": base_branch,
		"base_commit": base_commit,
		"operations": _duplicate_dictionary_array(operations),
		"validation_plan": _packed_to_array(validation_plan),
		"publish_intent": publish_intent,
		"risk_summary": risk_summary,
		"created_at": created_at,
	}


static func from_dict(data: Dictionary) -> PatchProposal:
	var proposal := PatchProposal.new()
	proposal.patch_id = _get_string(data, "patch_id")
	proposal.work_item_id = _get_string(data, "work_item_id")
	proposal.task_run_id = _get_string(data, "task_run_id")
	proposal.base_project = _get_string(data, "base_project")
	proposal.base_branch = _get_string(data, "base_branch")
	proposal.base_commit = _get_string(data, "base_commit")
	proposal.operations = _get_dictionary_array(data, "operations")
	proposal.validation_plan = _variant_to_string_array(data.get("validation_plan", PackedStringArray()))
	proposal.publish_intent = _get_string(data, "publish_intent")
	proposal.risk_summary = _get_string(data, "risk_summary")
	proposal.created_at = _get_string(data, "created_at")
	return proposal


func get_operation_count() -> int:
	return operations.size()


func get_affected_files() -> PackedStringArray:
	var affected_files := PackedStringArray()
	for operation in operations:
		for key in _SINGULAR_PATH_KEYS:
			if not operation.has(key):
				continue
			var path := String(operation.get(key, "")).strip_edges()
			if not path.is_empty() and not affected_files.has(path):
				affected_files.append(path)

		for key in _COLLECTION_PATH_KEYS:
			if not operation.has(key):
				continue
			for path in _variant_to_string_array(operation.get(key, [])):
				if not affected_files.has(path):
					affected_files.append(path)
	return affected_files


func has_high_risk_operations() -> bool:
	for operation in operations:
		var operation_type := _extract_operation_value(operation, _TYPE_KEYS)
		if operation_type == OPERATION_PROJECT_SETTING_SET:
			return true
		if operation_type != OPERATION_SCENE_OP:
			continue
		var action := _extract_operation_value(operation, _ACTION_KEYS)
		if action == "delete" or action == "remove":
			return true
	return false


static func _get_string(data: Dictionary, key: String, default_value: String = "") -> String:
	var value: Variant = data.get(key, default_value)
	if value == null:
		return default_value.strip_edges()
	return String(value).strip_edges()


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


func _extract_operation_value(operation: Dictionary, keys: Array) -> String:
	for key_variant in keys:
		var key := String(key_variant)
		if not operation.has(key):
			continue
		return String(operation.get(key, "")).strip_edges().to_lower()
	return ""


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
