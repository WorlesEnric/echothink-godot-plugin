@tool
class_name EchoThinkEditorContext
extends RefCounted


const _UNSAVED_SCENE_LABEL := "[unsaved scene]"
const _SCRIPT_FILE_EXTENSIONS := ["gd", "cs", "gdshader", "shader"]


var _editor_interface: EditorInterface = null


func set_editor_interface(ei: EditorInterface) -> void:
	_editor_interface = ei


func capture_snapshot() -> ProjectContextSnapshot:
	var snapshot := ProjectContextSnapshot.new()
	snapshot.snapshot_id = _generate_snapshot_id()
	snapshot.timestamp = Time.get_datetime_string_from_system()
	snapshot.current_scene_path = get_current_scene_path()
	snapshot.open_scripts = get_open_scripts()
	snapshot.selected_nodes = get_selected_node_paths()
	snapshot.modified_files = _get_modified_or_unsaved_files(snapshot.current_scene_path, snapshot.open_scripts)
	snapshot.godot_version = _get_godot_version_string()
	snapshot.platform = OS.get_name()
	return snapshot


func get_current_scene_path() -> String:
	if _editor_interface == null:
		return ""

	var scene_root_variant: Variant = _call_if_available(_editor_interface, "get_edited_scene_root")
	if scene_root_variant is Node:
		var scene_root: Node = scene_root_variant
		var scene_path := ""
		var scene_path_value: Variant = _get_object_property(scene_root, "scene_file_path")
		if scene_path_value is String:
			scene_path = String(scene_path_value).strip_edges()
		if not scene_path.is_empty():
			return scene_path
		var getter_path: Variant = _call_if_available(scene_root, "get_scene_file_path")
		if getter_path is String and not String(getter_path).strip_edges().is_empty():
			return String(getter_path).strip_edges()

	var open_scenes: PackedStringArray = _variant_to_string_array(_call_if_available(_editor_interface, "get_open_scenes"))
	if open_scenes.size() == 1:
		return open_scenes[0]

	return ""


func get_open_scripts() -> PackedStringArray:
	var script_paths := PackedStringArray()
	if _editor_interface == null:
		return script_paths

	var script_editor_variant: Variant = _call_if_available(_editor_interface, "get_script_editor")
	if not (script_editor_variant is Object):
		return script_paths

	var script_editor: Object = script_editor_variant
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_open_scripts"), script_paths)
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_open_script_editors"), script_paths)
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_scripts"), script_paths)
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_edited_scripts"), script_paths)
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_current_script"), script_paths)
	return script_paths


func get_selected_node_paths() -> PackedStringArray:
	var selected_paths := PackedStringArray()
	if _editor_interface == null:
		return selected_paths

	var selection_variant: Variant = _call_if_available(_editor_interface, "get_selection")
	if not (selection_variant is Object):
		return selected_paths

	var selection: Object = selection_variant
	var selected_nodes_variant: Variant = _call_if_available(selection, "get_selected_nodes")
	if not (selected_nodes_variant is Array):
		return selected_paths

	for node_variant in selected_nodes_variant:
		if node_variant is Node:
			var selected_node: Node = node_variant
			_append_unique_string(selected_paths, String(selected_node.get_path()))

	return selected_paths


func _get_modified_or_unsaved_files(current_scene_path: String, open_script_paths: PackedStringArray) -> PackedStringArray:
	var modified_files := PackedStringArray()
	_collect_modified_scene_paths(current_scene_path, modified_files)
	_collect_modified_script_paths(open_script_paths, modified_files)
	return modified_files


func _collect_modified_scene_paths(current_scene_path: String, target: PackedStringArray) -> void:
	if _editor_interface == null:
		return

	_collect_string_paths(_call_if_available(_editor_interface, "get_unsaved_scenes"), target)
	_collect_string_paths(_call_if_available(_editor_interface, "get_modified_scenes"), target)

	var open_scenes := _variant_to_string_array(_call_if_available(_editor_interface, "get_open_scenes"))
	for index in range(open_scenes.size()):
		var scene_path := open_scenes[index]
		if scene_path.is_empty():
			continue
		if _call_bool_with_argument(_editor_interface, "is_scene_modified", scene_path):
			_append_unique_string(target, scene_path)
			continue
		if _call_bool_with_argument(_editor_interface, "is_scene_unsaved", scene_path):
			_append_unique_string(target, scene_path)
			continue
		if _call_bool_with_argument(_editor_interface, "is_scene_modified", index):
			_append_unique_string(target, scene_path)
			continue
		if _call_bool_with_argument(_editor_interface, "is_scene_unsaved", index):
			_append_unique_string(target, scene_path)

	if current_scene_path.is_empty() and _call_bool_if_available(_editor_interface, "is_current_scene_modified"):
		_append_unique_string(target, _UNSAVED_SCENE_LABEL)
	elif current_scene_path.is_empty() and _call_bool_if_available(_editor_interface, "is_current_scene_unsaved"):
		_append_unique_string(target, _UNSAVED_SCENE_LABEL)


func _collect_modified_script_paths(open_script_paths: PackedStringArray, target: PackedStringArray) -> void:
	if _editor_interface == null:
		return

	var script_editor_variant: Variant = _call_if_available(_editor_interface, "get_script_editor")
	if not (script_editor_variant is Object):
		return

	var script_editor: Object = script_editor_variant
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_unsaved_scripts"), target)
	_collect_script_paths_from_variant(_call_if_available(script_editor, "get_modified_scripts"), target)

	var editor_tabs_variant: Variant = _call_if_available(script_editor, "get_open_script_editors")
	if editor_tabs_variant is Array:
		for editor_tab_variant in editor_tabs_variant:
			if _variant_is_unsaved(editor_tab_variant):
				_collect_script_paths_from_variant(editor_tab_variant, target)

	if _call_bool_if_available(script_editor, "is_current_script_unsaved"):
		_collect_script_paths_from_variant(_call_if_available(script_editor, "get_current_script"), target)

	for script_path in open_script_paths:
		if _call_bool_with_argument(script_editor, "is_script_unsaved", script_path):
			_append_unique_string(target, script_path)
		elif _call_bool_with_argument(script_editor, "is_script_modified", script_path):
			_append_unique_string(target, script_path)


func _collect_script_paths_from_variant(value: Variant, target: PackedStringArray) -> void:
	if value == null:
		return

	if value is PackedStringArray or value is Array:
		for entry in value:
			_collect_script_paths_from_variant(entry, target)
		return

	if value is String or value is StringName:
		_append_if_script_path(target, String(value).strip_edges())
		return

	var path := _extract_resource_path(value)
	if not path.is_empty():
		_append_if_script_path(target, path)
		return

	if value is Object:
		var object_value: Object = value
		_collect_script_paths_from_variant(_call_if_available(object_value, "get_edited_resource"), target)
		_collect_script_paths_from_variant(_call_if_available(object_value, "get_script"), target)
		_collect_script_paths_from_variant(_call_if_available(object_value, "get_resource"), target)


func _collect_string_paths(value: Variant, target: PackedStringArray) -> void:
	for path in _variant_to_string_array(value):
		_append_unique_string(target, path)


func _variant_to_string_array(value: Variant) -> PackedStringArray:
	var values := PackedStringArray()
	if value is PackedStringArray or value is Array:
		for entry in value:
			var text := String(entry).strip_edges()
			if not text.is_empty():
				values.append(text)
	elif value != null:
		var single_value := String(value).strip_edges()
		if not single_value.is_empty():
			values.append(single_value)
	return values


func _variant_is_unsaved(value: Variant) -> bool:
	if not (value is Object):
		return false

	var object_value: Object = value
	if _call_bool_if_available(object_value, "is_unsaved"):
		return true
	if _call_bool_if_available(object_value, "is_modified"):
		return true
	if _call_bool_if_available(object_value, "has_unsaved_changes"):
		return true

	var dirty_flag: Variant = _get_object_property(object_value, "dirty")
	if dirty_flag is bool and dirty_flag:
		return true

	var modified_flag: Variant = _get_object_property(object_value, "modified")
	if modified_flag is bool and modified_flag:
		return true

	var unsaved_flag: Variant = _get_object_property(object_value, "unsaved")
	if unsaved_flag is bool and unsaved_flag:
		return true

	return false


func _extract_resource_path(value: Variant) -> String:
	if value == null:
		return ""

	if value is Resource:
		var resource_value: Resource = value
		return resource_value.resource_path.strip_edges()

	if value is Object:
		var object_value: Object = value
		var resource_path: Variant = _get_object_property(object_value, "resource_path")
		if resource_path is String and not String(resource_path).strip_edges().is_empty():
			return String(resource_path).strip_edges()

		var maybe_path: Variant = _call_if_available(object_value, "get_path")
		if maybe_path is String and not String(maybe_path).strip_edges().is_empty():
			return String(maybe_path).strip_edges()

	return ""


func _append_if_script_path(target: PackedStringArray, path: String) -> void:
	var normalized_path := path.strip_edges()
	if normalized_path.is_empty():
		return

	var extension := normalized_path.get_extension().to_lower()
	if _SCRIPT_FILE_EXTENSIONS.has(extension):
		_append_unique_string(target, normalized_path)


func _append_unique_string(target: PackedStringArray, value: String) -> void:
	var normalized_value := value.strip_edges()
	if normalized_value.is_empty() or target.has(normalized_value):
		return
	target.append(normalized_value)


func _get_godot_version_string() -> String:
	var version_info := Engine.get_version_info()
	var explicit_version := String(version_info.get("string", "")).strip_edges()
	if not explicit_version.is_empty():
		return explicit_version

	var version := "%d.%d.%d" % [
		int(version_info.get("major", 0)),
		int(version_info.get("minor", 0)),
		int(version_info.get("patch", 0)),
	]
	var status := String(version_info.get("status", "")).strip_edges()
	if not status.is_empty() and status.to_lower() != "stable":
		version += ".%s" % status
	return version


func _get_object_property(target: Object, property_name: String) -> Variant:
	if target == null or property_name.strip_edges().is_empty():
		return null
	for property_variant in target.get_property_list():
		if not (property_variant is Dictionary):
			continue
		var property_info: Dictionary = property_variant
		if String(property_info.get("name", "")) == property_name:
			return target.get(property_name)
	return null


func _call_bool_if_available(target: Object, method_name: String) -> bool:
	var result: Variant = _call_if_available(target, method_name)
	return result is bool and result


func _call_bool_with_argument(target: Object, method_name: String, argument: Variant) -> bool:
	var result: Variant = _call_if_available(target, method_name, [argument])
	return result is bool and result


func _call_if_available(target: Object, method_name: String, arguments: Array = []) -> Variant:
	if target == null or not target.has_method(method_name):
		return null

	match arguments.size():
		0:
			return target.call(method_name)
		1:
			return target.call(method_name, arguments[0])
		2:
			return target.call(method_name, arguments[0], arguments[1])
		_:
			return null


static func _generate_snapshot_id() -> String:
	var bytes := PackedByteArray()
	var crypto := Crypto.new()
	bytes = crypto.generate_random_bytes(16)
	if bytes.size() < 16:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for _index in range(16 - bytes.size()):
			bytes.append(rng.randi_range(0, 255))

	var hex := bytes.hex_encode()
	if hex.length() < 32:
		hex = hex.rpad(32, "0")

	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]
