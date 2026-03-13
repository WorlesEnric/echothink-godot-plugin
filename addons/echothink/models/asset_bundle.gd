@tool
class_name AssetBundle
extends RefCounted


var bundle_id: String = ""
var workspace_id: String = ""
var source_type: String = ""
var source_task_run_id: String = ""
var source_outline_doc_id: String = ""
var assets: Array[Dictionary] = []
var dependencies: PackedStringArray = PackedStringArray()
var license_type: String = ""
var license_attribution_required: bool = false
var created_at: String = ""


func to_dict() -> Dictionary:
	return {
		"bundle_id": bundle_id,
		"workspace_id": workspace_id,
		"source_type": source_type,
		"source_task_run_id": source_task_run_id,
		"source_outline_doc_id": source_outline_doc_id,
		"assets": _duplicate_dictionary_array(assets),
		"dependencies": _packed_to_array(dependencies),
		"license_type": license_type,
		"license_attribution_required": license_attribution_required,
		"created_at": created_at,
	}


static func from_dict(data: Dictionary) -> AssetBundle:
	var bundle := AssetBundle.new()
	bundle.bundle_id = _get_string(data, "bundle_id")
	bundle.workspace_id = _get_string(data, "workspace_id")
	bundle.source_type = _get_string(data, "source_type")
	bundle.source_task_run_id = _get_string(data, "source_task_run_id")
	bundle.source_outline_doc_id = _get_string(data, "source_outline_doc_id")
	bundle.assets = _get_asset_array(data, "assets")
	bundle.dependencies = _variant_to_string_array(data.get("dependencies", PackedStringArray()))
	bundle.license_type = _get_string(data, "license_type")
	bundle.license_attribution_required = _get_bool(data, "license_attribution_required")
	bundle.created_at = _get_string(data, "created_at")
	return bundle


func get_asset_count() -> int:
	return assets.size()


func get_total_target_paths() -> PackedStringArray:
	var target_paths := PackedStringArray()
	for asset in assets:
		var target_path := String(asset.get("target_path", "")).strip_edges()
		if not target_path.is_empty() and not target_paths.has(target_path):
			target_paths.append(target_path)
	return target_paths


func has_conflicts_with(local_files: PackedStringArray) -> PackedStringArray:
	var normalized_local_files := PackedStringArray()
	for local_file in local_files:
		var normalized := String(local_file).strip_edges()
		if not normalized.is_empty() and not normalized_local_files.has(normalized):
			normalized_local_files.append(normalized)

	var conflicts := PackedStringArray()
	for target_path in get_total_target_paths():
		if normalized_local_files.has(target_path) and not conflicts.has(target_path):
			conflicts.append(target_path)
	return conflicts


static func _get_string(data: Dictionary, key: String, default_value: String = "") -> String:
	var value: Variant = data.get(key, default_value)
	if value == null:
		return default_value.strip_edges()
	return String(value).strip_edges()


static func _get_bool(data: Dictionary, key: String, default_value: bool = false) -> bool:
	var value: Variant = data.get(key, default_value)
	if value is bool:
		return value
	if value is String:
		var normalized := String(value).strip_edges().to_lower()
		if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on":
			return true
		if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" or normalized.is_empty():
			return false
	return bool(value)


static func _get_asset_array(data: Dictionary, key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var value: Variant = data.get(key, [])
	if value is Array:
		for entry in value:
			if entry is Dictionary:
				var asset_entry: Dictionary = entry
				result.append(_sanitize_asset(asset_entry))
	return result


static func _sanitize_asset(asset: Dictionary) -> Dictionary:
	var sanitized := asset.duplicate(true)
	sanitized["path"] = String(asset.get("path", "")).strip_edges()
	sanitized["sha256"] = String(asset.get("sha256", "")).strip_edges()
	sanitized["kind"] = String(asset.get("kind", "")).strip_edges()
	sanitized["target_path"] = String(asset.get("target_path", "")).strip_edges()
	sanitized["import_preset"] = String(asset.get("import_preset", "")).strip_edges()
	return sanitized


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
