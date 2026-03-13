@tool
class_name EchoThinkChangeSetManager
extends RefCounted


const _JOURNAL_FILE_NAME := "journal.json"
const _JOURNAL_VERSION := 1
const _SOURCE_NAME := "change_set_manager"
const _PATH_KEYS := ["path", "target_path", "file_path", "resource_path", "scene_path", "asset_path"]


var _changesets: Dictionary = {}
var _journal_path: String = ""
var _event_bus: EchoThinkEventBus = null


func initialize(journal_dir: String, event_bus: EchoThinkEventBus) -> void:
	_changesets.clear()
	_event_bus = event_bus
	var normalized_dir := journal_dir.strip_edges()
	if normalized_dir.is_empty():
		normalized_dir = "user://echothink"
	_journal_path = normalized_dir.path_join(_JOURNAL_FILE_NAME)
	_ensure_directory_exists(_journal_path.get_base_dir())
	load_journal()


func load_journal() -> void:
	_changesets.clear()
	if _journal_path.is_empty():
		return

	if not FileAccess.file_exists(_journal_path):
		save_journal()
		return

	var journal_file := FileAccess.open(_journal_path, FileAccess.READ)
	if journal_file == null:
		_emit_error("Unable to open journal file %s: %s" % [_journal_path, error_string(FileAccess.get_open_error())])
		return

	var contents := journal_file.get_as_text().strip_edges()
	if contents.is_empty():
		return

	var parsed: Variant = JSON.parse_string(contents)
	if not (parsed is Dictionary):
		_emit_error("Journal file %s does not contain a JSON object." % _journal_path)
		return

	var data: Dictionary = parsed
	var entries_variant: Variant = data.get("changesets", data.get("entries", []))
	if not (entries_variant is Array):
		_emit_error("Journal file %s is missing a changeset list." % _journal_path)
		return

	for entry_variant in entries_variant:
		if not (entry_variant is Dictionary):
			continue

		var normalized_entry := _normalize_loaded_changeset(entry_variant)
		var change_set := ChangeSet.from_dict(normalized_entry)
		if change_set.changeset_id.strip_edges().is_empty():
			continue
		_changesets[change_set.changeset_id] = change_set


func save_journal() -> void:
	if _journal_path.is_empty():
		return

	_ensure_directory_exists(_journal_path.get_base_dir())

	var serialized_entries: Array[Dictionary] = []
	for change_set in _get_sorted_changesets():
		serialized_entries.append(change_set.to_dict())

	var payload := {
		"version": _JOURNAL_VERSION,
		"changesets": serialized_entries,
	}
	var tmp_path := "%s.tmp" % _journal_path
	var tmp_file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if tmp_file == null:
		_emit_error("Unable to open temporary journal file %s: %s" % [tmp_path, error_string(FileAccess.get_open_error())])
		return

	tmp_file.store_string(JSON.stringify(payload) + "\n")
	tmp_file.flush()
	tmp_file.close()

	var tmp_fs_path := _to_filesystem_path(tmp_path)
	var journal_fs_path := _to_filesystem_path(_journal_path)
	var rename_result := DirAccess.rename_absolute(tmp_fs_path, journal_fs_path)
	if rename_result != OK and FileAccess.file_exists(_journal_path):
		var remove_result := DirAccess.remove_absolute(journal_fs_path)
		if remove_result != OK:
			DirAccess.remove_absolute(tmp_fs_path)
			_emit_error("Unable to replace existing journal file %s: %s" % [_journal_path, error_string(remove_result)])
			return
		rename_result = DirAccess.rename_absolute(tmp_fs_path, journal_fs_path)

	if rename_result != OK:
		DirAccess.remove_absolute(tmp_fs_path)
		_emit_error("Unable to finalize journal write for %s: %s" % [_journal_path, error_string(rename_result)])


func begin_changeset(work_item_id: String, task_run_id: String) -> ChangeSet:
	var change_set := ChangeSet.new()
	change_set.changeset_id = _generate_identifier()
	change_set.work_item_id = work_item_id.strip_edges()
	change_set.task_run_id = task_run_id.strip_edges()
	change_set.timestamp = Time.get_datetime_string_from_system()
	change_set.status = ChangeSet.STATUS_PENDING
	change_set.error_message = ""
	_changesets[change_set.changeset_id] = change_set
	save_journal()
	return change_set


func add_operation(changeset_id: String, op: Dictionary) -> bool:
	var change_set := get_changeset(changeset_id)
	if change_set == null:
		return false
	if change_set.status != ChangeSet.STATUS_PENDING:
		return false

	var normalized_operation := _normalize_operation(op)
	if String(normalized_operation.get("type", "")).strip_edges().is_empty():
		return false

	change_set.operations.append(normalized_operation)
	save_journal()
	return true


func set_preimage(changeset_id: String, path: String, hash: String) -> void:
	_set_image(changeset_id, path, hash, true)


func set_postimage(changeset_id: String, path: String, hash: String) -> void:
	_set_image(changeset_id, path, hash, false)


func complete_changeset(changeset_id: String) -> void:
	var change_set := get_changeset(changeset_id)
	if change_set == null:
		return

	change_set.status = ChangeSet.STATUS_APPLIED
	change_set.error_message = ""
	save_journal()
	if _event_bus != null:
		_event_bus.patch_applied.emit(change_set)


func fail_changeset(changeset_id: String, error: String) -> void:
	var change_set := get_changeset(changeset_id)
	if change_set == null:
		return

	change_set.status = ChangeSet.STATUS_FAILED
	change_set.error_message = error.strip_edges()
	save_journal()
	_emit_error("ChangeSet %s failed: %s" % [changeset_id, change_set.error_message])


func mark_rolled_back(changeset_id: String) -> void:
	var change_set := get_changeset(changeset_id)
	if change_set == null:
		return

	change_set.status = ChangeSet.STATUS_ROLLED_BACK
	change_set.error_message = ""
	save_journal()
	if _event_bus != null:
		_event_bus.patch_rolled_back.emit(changeset_id)


func get_pending_changesets() -> Array[ChangeSet]:
	var pending_changesets: Array[ChangeSet] = []
	for change_set in _get_sorted_changesets():
		if change_set.status != ChangeSet.STATUS_APPLIED and change_set.status != ChangeSet.STATUS_ROLLED_BACK:
			pending_changesets.append(change_set)
	return pending_changesets


func get_changeset(id: String) -> ChangeSet:
	if not _changesets.has(id):
		return null
	return _changesets[id]


func get_all_changesets() -> Array[ChangeSet]:
	return _get_sorted_changesets()


func get_last_applied() -> ChangeSet:
	var last_applied: ChangeSet = null
	for change_set in _get_sorted_changesets():
		if change_set.status == ChangeSet.STATUS_APPLIED:
			last_applied = change_set
	return last_applied


func _set_image(changeset_id: String, path: String, hash: String, is_preimage: bool) -> void:
	var change_set := get_changeset(changeset_id)
	if change_set == null:
		return

	var normalized_path := path.strip_edges()
	var normalized_hash := hash.strip_edges()
	if normalized_path.is_empty() or normalized_hash.is_empty():
		return

	if is_preimage:
		change_set.preimages[normalized_path] = normalized_hash
	else:
		change_set.postimages[normalized_path] = normalized_hash
	save_journal()


func _get_sorted_changesets() -> Array[ChangeSet]:
	var sorted_changesets: Array[ChangeSet] = []
	for change_set_variant in _changesets.values():
		if not (change_set_variant is ChangeSet):
			continue

		var change_set: ChangeSet = change_set_variant
		var insert_index := sorted_changesets.size()
		for index in range(sorted_changesets.size()):
			if _compare_changesets(change_set, sorted_changesets[index]) < 0:
				insert_index = index
				break
		sorted_changesets.insert(insert_index, change_set)

	return sorted_changesets


func _compare_changesets(left: ChangeSet, right: ChangeSet) -> int:
	if left.timestamp < right.timestamp:
		return -1
	if left.timestamp > right.timestamp:
		return 1
	if left.changeset_id < right.changeset_id:
		return -1
	if left.changeset_id > right.changeset_id:
		return 1
	return 0


func _normalize_loaded_changeset(entry: Dictionary) -> Dictionary:
	var normalized := entry.duplicate(true)
	if not normalized.has("changeset_id"):
		normalized["changeset_id"] = _string_value(normalized.get("id", ""))

	var raw_status := _string_value(normalized.get("status", ChangeSet.STATUS_PENDING)).to_lower()
	if raw_status == "in_progress":
		normalized["status"] = ChangeSet.STATUS_PENDING
	elif raw_status == "completed":
		normalized["status"] = ChangeSet.STATUS_APPLIED
	elif raw_status == ChangeSet.STATUS_PENDING or raw_status == ChangeSet.STATUS_APPLIED or raw_status == ChangeSet.STATUS_ROLLED_BACK or raw_status == ChangeSet.STATUS_FAILED:
		normalized["status"] = raw_status
	else:
		normalized["status"] = ChangeSet.STATUS_PENDING

	return normalized


func _normalize_operation(operation: Dictionary) -> Dictionary:
	var normalized := operation.duplicate(true)
	var operation_type := _extract_operation_string(normalized, ["type", "operation_type", "kind"])
	if operation_type.is_empty():
		return {}
	normalized["type"] = operation_type

	var path := _extract_operation_string(normalized, _PATH_KEYS)
	if not path.is_empty():
		normalized["path"] = path

	var action := _extract_operation_string(normalized, ["action", "op", "operation", "mode"])
	if _string_value(normalized.get("description", "")).is_empty():
		normalized["description"] = _build_operation_description(operation_type, action, path)

	if not normalized.has("reversible"):
		var destructive := action == "delete" or action == "remove" or action == "overwrite" or action == "replace"
		normalized["reversible"] = not destructive

	return normalized


func _extract_operation_string(operation: Dictionary, keys: Array) -> String:
	for key_variant in keys:
		var key := String(key_variant)
		if not operation.has(key):
			continue
		var value := _string_value(operation.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return ""


func _build_operation_description(operation_type: String, action: String, path: String) -> String:
	var description := operation_type
	if not action.is_empty():
		description += ":%s" % action
	if not path.is_empty():
		description += " %s" % path
	return description


func _ensure_directory_exists(directory_path: String) -> void:
	var normalized_path := directory_path.strip_edges()
	if normalized_path.is_empty():
		return
	var result := DirAccess.make_dir_recursive_absolute(_to_filesystem_path(normalized_path))
	if result != OK:
		_emit_error("Unable to create journal directory %s: %s" % [directory_path, error_string(result)])


func _to_filesystem_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


func _emit_error(message: String) -> void:
	if _event_bus != null:
		_event_bus.emit_error(_SOURCE_NAME, message)


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value).strip_edges()


static func _generate_identifier() -> String:
	var bytes := PackedByteArray()
	var crypto := Crypto.new()
	bytes = crypto.generate_random_bytes(16)
	if bytes.size() < 16:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for _index in range(16 - bytes.size()):
			bytes.append(rng.randi_range(0, 255))
	return bytes.hex_encode()
