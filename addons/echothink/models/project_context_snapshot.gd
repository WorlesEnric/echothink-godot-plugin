@tool
class_name ProjectContextSnapshot
extends RefCounted


var snapshot_id: String = ""
var timestamp: String = ""
var current_scene_path: String = ""
var open_scripts: PackedStringArray = PackedStringArray()
var modified_files: PackedStringArray = PackedStringArray()
var selected_nodes: PackedStringArray = PackedStringArray()
var current_branch: String = ""
var head_commit: String = ""
var editor_errors: Array[Dictionary] = []
var godot_version: String = ""
var platform: String = ""


func to_dict() -> Dictionary:
	return {
		"snapshot_id": snapshot_id,
		"timestamp": timestamp,
		"current_scene_path": current_scene_path,
		"open_scripts": _packed_to_array(open_scripts),
		"modified_files": _packed_to_array(modified_files),
		"selected_nodes": _packed_to_array(selected_nodes),
		"current_branch": current_branch,
		"head_commit": head_commit,
		"editor_errors": _duplicate_dictionary_array(editor_errors),
		"godot_version": godot_version,
		"platform": platform,
	}


static func create_empty() -> ProjectContextSnapshot:
	return ProjectContextSnapshot.new()


static func _packed_to_array(values: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result


static func _duplicate_dictionary_array(values: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in values:
		result.append(value.duplicate(true))
	return result
