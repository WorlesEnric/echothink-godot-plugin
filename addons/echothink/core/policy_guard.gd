@tool
class_name EchoThinkPolicyGuard
extends RefCounted


enum RiskLevel {
	LOW,
	MEDIUM,
	HIGH,
	CRITICAL,
}


const _CONFIG_DIR_NAME := ".echothink"
const _TEST_STRATEGY_FILE_NAME := "test_strategies.yaml"

const _KNOWN_OPERATION_TYPES = {
	"read": true,
	"read_only": true,
	"inspect": true,
	"query": true,
	"analyze": true,
	"diff": true,
	"preview": true,
	"list": true,
	"git.status": true,
	"context_snapshot": true,
	PatchProposal.OPERATION_TEXT_PATCH: true,
	PatchProposal.OPERATION_SCENE_OP: true,
	PatchProposal.OPERATION_RESOURCE_OP: true,
	PatchProposal.OPERATION_ASSET_IMPORT: true,
	PatchProposal.OPERATION_PROJECT_SETTING_SET: true,
	"publish": true,
	"remote_publish": true,
	"branch_switch": true,
	"checkout": true,
	"workspace_rewrite": true,
}

const _KNOWN_ACTIONS = {
	"read": true,
	"inspect": true,
	"query": true,
	"analyze": true,
	"diff": true,
	"preview": true,
	"list": true,
	"create": true,
	"new": true,
	"add": true,
	"patch": true,
	"update": true,
	"modify": true,
	"set": true,
	"import": true,
	"reimport": true,
	"delete": true,
	"remove": true,
	"overwrite": true,
	"replace": true,
	"rename": true,
	"batch_rename": true,
	"publish": true,
	"push": true,
	"upload": true,
	"deploy": true,
	"checkout": true,
	"switch_branch": true,
	"reset_hard": true,
}

const _READ_ONLY_TAGS = {
	"read": true,
	"read_only": true,
	"inspect": true,
	"query": true,
	"analyze": true,
	"diff": true,
	"preview": true,
	"list": true,
	"git.status": true,
	"context_snapshot": true,
}


var _policy_profile: String = "studio-default"
var _allowed_test_strategies: Array[String] = []
var _strategies_by_id: Dictionary = {}


func initialize(policy_profile: String) -> void:
	_policy_profile = _normalize_policy_profile(policy_profile)
	_allowed_test_strategies.clear()
	_strategies_by_id.clear()


func load_test_strategies(project_path: String) -> void:
	_allowed_test_strategies.clear()
	_strategies_by_id.clear()

	var normalized_project_path := project_path.strip_edges()
	if normalized_project_path.is_empty():
		return

	var strategies_path := normalized_project_path.path_join(_CONFIG_DIR_NAME).path_join(_TEST_STRATEGY_FILE_NAME)
	if not FileAccess.file_exists(strategies_path):
		return

	var strategy_file := FileAccess.open(strategies_path, FileAccess.READ)
	if strategy_file == null:
		return

	for raw_strategy in _parse_test_strategies_yaml(strategy_file.get_as_text()):
		var strategy := _normalize_strategy(raw_strategy)
		var strategy_id := _string_value(strategy.get("id", ""))
		if strategy_id.is_empty():
			continue

		_strategies_by_id[strategy_id] = strategy
		if _is_strategy_allowed_for_profile(strategy) and not _allowed_test_strategies.has(strategy_id):
			_allowed_test_strategies.append(strategy_id)


func assess_risk(operation: Dictionary) -> RiskLevel:
	var operation_type := _extract_tag(operation, ["type", "operation_type", "kind"])
	var action := _extract_tag(operation, ["action", "op", "operation", "mode"])

	if _is_remote_publish(operation_type, action, operation) or _is_batch_resource_replace(operation_type, action, operation):
		return RiskLevel.CRITICAL

	if _is_project_settings_change(operation_type, action, operation) or _is_destructive(operation_type, action, operation) or _is_batch_rename(action, operation):
		return RiskLevel.HIGH

	if _is_read_only(operation_type, action, operation):
		return RiskLevel.LOW

	return RiskLevel.MEDIUM


func requires_confirmation(risk: RiskLevel) -> bool:
	return int(risk) >= int(RiskLevel.MEDIUM)


func requires_double_confirmation(risk: RiskLevel) -> bool:
	return int(risk) >= int(RiskLevel.HIGH)


func is_operation_allowed(operation: Dictionary) -> bool:
	var operation_type := _extract_tag(operation, ["type", "operation_type", "kind"])
	var action := _extract_tag(operation, ["action", "op", "operation", "mode"])
	if operation_type.is_empty() and action.is_empty():
		return false

	if not operation_type.is_empty() and not _KNOWN_OPERATION_TYPES.has(operation_type):
		return false
	if not action.is_empty() and not _KNOWN_ACTIONS.has(action):
		return false

	return int(assess_risk(operation)) <= int(_maximum_allowed_operation_risk())


func get_allowed_test_strategies() -> Array[String]:
	var strategies: Array[String] = []
	for strategy_id in _allowed_test_strategies:
		strategies.append(strategy_id)
	return strategies


func get_strategy_by_id(id: String) -> Dictionary:
	var strategy_id := id.strip_edges()
	if strategy_id.is_empty() or not _strategies_by_id.has(strategy_id):
		return {}
	return _dictionary_value(_strategies_by_id[strategy_id]).duplicate(true)


func _is_read_only(operation_type: String, action: String, operation: Dictionary) -> bool:
	if _READ_ONLY_TAGS.has(operation_type) or _READ_ONLY_TAGS.has(action):
		return true
	return not operation.has("patch") and not operation.has("value") and _operation_path_count(operation) <= 1 and action.is_empty() and not operation_type.is_empty() and _READ_ONLY_TAGS.has(operation_type)


func _is_project_settings_change(operation_type: String, action: String, operation: Dictionary) -> bool:
	if operation_type == PatchProposal.OPERATION_PROJECT_SETTING_SET:
		return true
	if action == "set":
		var property_name := _string_value(operation.get("property", "")).to_lower()
		return property_name.begins_with("application/") or property_name.begins_with("display/") or property_name.begins_with("autoload/") or property_name.begins_with("rendering/")
	return false


func _is_destructive(operation_type: String, action: String, operation: Dictionary) -> bool:
	if action == "delete" or action == "remove" or action == "overwrite":
		return true
	if action == "replace" and _operation_path_count(operation) <= 1:
		return true
	if operation_type == PatchProposal.OPERATION_SCENE_OP and (action == "delete" or action == "remove"):
		return true
	if operation_type == PatchProposal.OPERATION_RESOURCE_OP and (action == "overwrite" or action == "replace"):
		return true
	if _bool_value(operation.get("overwrite", false)):
		return true
	return false


func _is_batch_rename(action: String, operation: Dictionary) -> bool:
	if action != "rename" and action != "batch_rename":
		return false
	return _operation_path_count(operation) > 1 or _bool_value(operation.get("batch", false))


func _is_remote_publish(operation_type: String, action: String, operation: Dictionary) -> bool:
	if operation_type == "publish" or operation_type == "remote_publish" or operation_type == "branch_switch" or operation_type == "workspace_rewrite":
		return true
	if action == "publish" or action == "push" or action == "upload" or action == "deploy" or action == "checkout" or action == "switch_branch" or action == "reset_hard":
		return true
	if _bool_value(operation.get("remote", false)) or _bool_value(operation.get("publish", false)):
		return true
	return not _string_value(operation.get("remote_target", "")).is_empty()


func _is_batch_resource_replace(operation_type: String, action: String, operation: Dictionary) -> bool:
	if operation_type != PatchProposal.OPERATION_RESOURCE_OP:
		return false
	if action != "replace" and action != "overwrite":
		return false
	return _operation_path_count(operation) > 1 or _bool_value(operation.get("batch", false))


func _operation_path_count(operation: Dictionary) -> int:
	var count := 0
	for key in ["path", "target_path", "file_path", "resource_path", "scene_path", "asset_path"]:
		if not _string_value(operation.get(key, "")).is_empty():
			count += 1
	for key in ["paths", "target_paths", "file_paths", "resource_paths", "scene_paths", "asset_paths"]:
		var values := _variant_to_string_list(operation.get(key, []))
		count += values.size()
	return count


func _maximum_allowed_operation_risk() -> RiskLevel:
	if _policy_profile == "readonly":
		return RiskLevel.LOW
	if _policy_profile == "safe" or _policy_profile == "strict":
		return RiskLevel.MEDIUM
	if _policy_profile == "permissive" or _policy_profile == "full" or _policy_profile == "unrestricted" or _policy_profile == "release":
		return RiskLevel.CRITICAL
	return RiskLevel.HIGH


func _maximum_allowed_strategy_level() -> RiskLevel:
	if _policy_profile == "readonly" or _policy_profile == "safe":
		return RiskLevel.LOW
	if _policy_profile == "permissive" or _policy_profile == "full" or _policy_profile == "unrestricted" or _policy_profile == "release":
		return RiskLevel.CRITICAL
	if _policy_profile == "high":
		return RiskLevel.HIGH
	return RiskLevel.MEDIUM


func _normalize_strategy(strategy: Dictionary) -> Dictionary:
	var normalized := strategy.duplicate(true)
	var strategy_id := _string_value(normalized.get("id", normalized.get("strategy_id", "")))
	normalized["id"] = strategy_id
	normalized["kind"] = _string_value(normalized.get("kind", ""))
	normalized["description"] = _string_value(normalized.get("description", ""))
	normalized["framework"] = _string_value(normalized.get("framework", ""))
	normalized["profile"] = _string_value(normalized.get("profile", normalized.get("risk_level", "medium"))).to_lower()
	normalized["profiles"] = _variant_to_string_list(normalized.get("profiles", []))
	normalized["policy_profiles"] = _variant_to_string_list(normalized.get("policy_profiles", []))
	normalized["enabled"] = _bool_value(normalized.get("enabled", normalized.get("allowed", true)), true)
	return normalized


func _is_strategy_allowed_for_profile(strategy: Dictionary) -> bool:
	if not _bool_value(strategy.get("enabled", true), true):
		return false

	var explicit_policy_profiles := _variant_to_string_list(strategy.get("policy_profiles", []))
	if not explicit_policy_profiles.is_empty() and not explicit_policy_profiles.has(_policy_profile):
		return false

	var explicit_profiles := _variant_to_string_list(strategy.get("profiles", []))
	if not explicit_profiles.is_empty() and explicit_profiles.has(_policy_profile):
		return true

	var strategy_level := _risk_level_from_string(_string_value(strategy.get("profile", "medium")))
	return int(strategy_level) <= int(_maximum_allowed_strategy_level())


func _parse_test_strategies_yaml(contents: String) -> Array[Dictionary]:
	var strategies: Array[Dictionary] = []
	var current_strategy: Dictionary = {}
	var current_indent := -1
	var active_array_key := ""
	var active_array_indent := -1
	var in_strategy_list := false

	for raw_line in contents.split("\n", false):
		var cleaned_line := _strip_yaml_comment(String(raw_line).replace("\r", ""))
		if cleaned_line.strip_edges().is_empty():
			continue

		var indent := _count_indent(cleaned_line)
		var text := cleaned_line.strip_edges()

		if active_array_key != "" and indent <= active_array_indent:
			active_array_key = ""
			active_array_indent = -1

		if not in_strategy_list:
			if text == "strategies:":
				in_strategy_list = true
				continue
			if not text.begins_with("-"):
				continue
			in_strategy_list = true
		elif indent == 0 and text != "strategies:" and not text.begins_with("-"):
			break

		if active_array_key != "" and indent > active_array_indent and text.begins_with("-"):
			var array_values := _variant_to_array(current_strategy.get(active_array_key, []))
			array_values.append(_parse_yaml_scalar(text.substr(1).strip_edges()))
			current_strategy[active_array_key] = array_values
			continue

		if text.begins_with("-"):
			if not current_strategy.is_empty():
				strategies.append(current_strategy.duplicate(true))
			current_strategy = {}
			current_indent = indent
			active_array_key = ""
			active_array_indent = -1

			var remainder := text.substr(1).strip_edges()
			if remainder.is_empty():
				continue

			var separator_index := remainder.find(":")
			if separator_index < 0:
				current_strategy["value"] = _parse_yaml_scalar(remainder)
				continue

			var inline_key := remainder.substr(0, separator_index).strip_edges()
			var inline_value := remainder.substr(separator_index + 1).strip_edges()
			if inline_value.is_empty():
				current_strategy[inline_key] = []
				active_array_key = inline_key
				active_array_indent = indent
			else:
				current_strategy[inline_key] = _parse_yaml_scalar(inline_value)
			continue

		if current_strategy.is_empty() or indent <= current_indent:
			continue

		var separator_index := text.find(":")
		if separator_index < 0:
			continue

		var key := text.substr(0, separator_index).strip_edges()
		var value_text := text.substr(separator_index + 1).strip_edges()
		if value_text.is_empty():
			current_strategy[key] = []
			active_array_key = key
			active_array_indent = indent
		else:
			current_strategy[key] = _parse_yaml_scalar(value_text)

	if not current_strategy.is_empty():
		strategies.append(current_strategy.duplicate(true))

	return strategies


func _extract_tag(operation: Dictionary, keys: Array) -> String:
	for key_variant in keys:
		var key := String(key_variant)
		if not operation.has(key):
			continue
		var value := _string_value(operation.get(key, "")).to_lower()
		if not value.is_empty():
			return value
	return ""


func _risk_level_from_string(label: String) -> RiskLevel:
	var normalized := label.strip_edges().to_lower()
	if normalized == "low" or normalized == "safe":
		return RiskLevel.LOW
	if normalized == "medium" or normalized == "default" or normalized == "balanced":
		return RiskLevel.MEDIUM
	if normalized == "high":
		return RiskLevel.HIGH
	if normalized == "critical":
		return RiskLevel.CRITICAL
	return RiskLevel.MEDIUM


func _normalize_policy_profile(profile: String) -> String:
	var normalized := profile.strip_edges().to_lower()
	if normalized.is_empty():
		return "studio-default"
	return normalized


static func _strip_yaml_comment(line: String) -> String:
	var in_single_quote := false
	var in_double_quote := false
	var escaped := false

	for index in range(line.length()):
		var character := line.substr(index, 1)
		if character == "\\" and in_double_quote and not escaped:
			escaped = true
			continue
		if character == "\"" and not in_single_quote and not escaped:
			in_double_quote = not in_double_quote
		elif character == "'" and not in_double_quote:
			in_single_quote = not in_single_quote
		elif character == "#" and not in_single_quote and not in_double_quote:
			return line.substr(0, index)
		escaped = false

	return line


static func _count_indent(line: String) -> int:
	var indent := 0
	for index in range(line.length()):
		var character := line.substr(index, 1)
		if character == " ":
			indent += 1
		elif character == "\t":
			indent += 2
		else:
			break
	return indent


static func _parse_yaml_scalar(value: String) -> Variant:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return ""

	if (normalized.begins_with("\"") and normalized.ends_with("\"")) or (normalized.begins_with("'") and normalized.ends_with("'")):
		return normalized.substr(1, normalized.length() - 2)

	var lowered := normalized.to_lower()
	if lowered == "true":
		return true
	if lowered == "false":
		return false
	if lowered == "null" or lowered == "~":
		return null
	if normalized.is_valid_int():
		return normalized.to_int()
	if normalized.is_valid_float():
		return normalized.to_float()
	return normalized


static func _variant_to_array(value: Variant) -> Array:
	if value is Array:
		return value.duplicate(true)
	return []


static func _variant_to_string_list(value: Variant) -> Array[String]:
	var values: Array[String] = []
	if value is PackedStringArray or value is Array:
		for entry in value:
			var text := _string_value(entry)
			if not text.is_empty() and not values.has(text):
				values.append(text)
	elif value != null:
		var single_value := _string_value(value)
		if not single_value.is_empty():
			values.append(single_value)
	return values


static func _bool_value(value: Variant, default_value: bool = false) -> bool:
	if value is bool:
		return value
	if value is int:
		return value != 0
	if value is float:
		return not is_zero_approx(value)
	if value is String:
		var normalized := value.strip_edges().to_lower()
		if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on":
			return true
		if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" or normalized.is_empty():
			return false
	return default_value


static func _dictionary_value(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value).strip_edges()
