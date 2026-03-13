@tool
class_name WorkspaceBinding
extends RefCounted


var workspace_id: String = ""
var project_name: String = ""
var godot_engine_major: int = 0
var gitlab_project: String = ""
var gitlab_default_branch: String = ""
var outline_primary_doc_id: String = ""
var outline_task_queue_doc_id: String = ""
var assets_remote_prefix: String = ""
var policy_profile: String = ""


static func from_yaml(data: Dictionary) -> WorkspaceBinding:
	var binding := WorkspaceBinding.new()
	binding.workspace_id = _get_string(data, "workspace_id")
	binding.project_name = _get_string(data, "project_name")
	binding.godot_engine_major = _get_int(data, "godot_engine_major")
	binding.gitlab_project = _get_string(data, "gitlab_project")
	binding.gitlab_default_branch = _get_string(data, "gitlab_default_branch")
	binding.outline_primary_doc_id = _get_string(data, "outline_primary_doc_id")
	binding.outline_task_queue_doc_id = _get_string(data, "outline_task_queue_doc_id")
	binding.assets_remote_prefix = _get_string(data, "assets_remote_prefix")
	binding.policy_profile = _get_string(data, "policy_profile")
	return binding


func to_dict() -> Dictionary:
	return {
		"workspace_id": workspace_id,
		"project_name": project_name,
		"godot_engine_major": godot_engine_major,
		"gitlab_project": gitlab_project,
		"gitlab_default_branch": gitlab_default_branch,
		"outline_primary_doc_id": outline_primary_doc_id,
		"outline_task_queue_doc_id": outline_task_queue_doc_id,
		"assets_remote_prefix": assets_remote_prefix,
		"policy_profile": policy_profile,
	}


func is_valid() -> bool:
	return not workspace_id.strip_edges().is_empty() and not project_name.strip_edges().is_empty()


static func _get_string(data: Dictionary, key: String, default_value: String = "") -> String:
	var value: Variant = data.get(key, default_value)
	if value == null:
		return default_value.strip_edges()
	return String(value).strip_edges()


static func _get_int(data: Dictionary, key: String, default_value: int = 0) -> int:
	return int(data.get(key, default_value))
