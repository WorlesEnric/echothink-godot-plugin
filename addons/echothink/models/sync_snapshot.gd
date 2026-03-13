@tool
class_name SyncSnapshot
extends RefCounted


const MANIFEST_METADATA_FIELDS := [
	"kind",
	"source_bundle",
	"import_preset_hash",
	"last_modified_by",
	"last_modified_at",
]


var snapshot_id: String = ""
var workspace_id: String = ""
var manifest: Array[Dictionary] = []
var created_at: String = ""
var source: String = ""


func to_dict() -> Dictionary:
	return {
		"snapshot_id": snapshot_id,
		"workspace_id": workspace_id,
		"manifest": _clone_dictionary_array(manifest),
		"created_at": created_at,
		"source": source,
	}


static func from_dict(data: Dictionary) -> SyncSnapshot:
	var snapshot := SyncSnapshot.new()
	snapshot.snapshot_id = _string_value(data.get("snapshot_id", ""))
	snapshot.workspace_id = _string_value(data.get("workspace_id", ""))
	snapshot.manifest = _sanitize_manifest(data.get("manifest", []))
	snapshot.created_at = _string_value(data.get("created_at", ""))
	snapshot.source = _string_value(data.get("source", ""))
	return snapshot


func diff_with(other: SyncSnapshot) -> Dictionary:
	var added: Array[Dictionary] = []
	var modified: Array[Dictionary] = []
	var deleted: Array[Dictionary] = []
	var renamed: Array[Dictionary] = []
	var metadata_changed: Array[Dictionary] = []

	if other == null:
		for entry in manifest:
			deleted.append(entry.duplicate(true))
		return {
			"added": added,
			"modified": modified,
			"deleted": deleted,
			"renamed": renamed,
			"metadata_changed": metadata_changed,
		}

	var current_by_path := _build_manifest_map(manifest)
	var other_by_path := _build_manifest_map(other.manifest)
	var removed_entries: Array[Dictionary] = []
	var added_entries: Array[Dictionary] = []

	for entry in manifest:
		var path := _string_value(entry.get("path", ""))
		if path.is_empty():
			continue

		if other_by_path.has(path):
			var before_entry: Dictionary = current_by_path[path]
			var after_entry: Dictionary = other_by_path[path]
			if _string_value(before_entry.get("content_hash", "")) != _string_value(after_entry.get("content_hash", "")):
				modified.append({
					"path": path,
					"before": before_entry.duplicate(true),
					"after": after_entry.duplicate(true),
				})
			else:
				var changed_fields := _get_changed_metadata_fields(before_entry, after_entry)
				if changed_fields.size() > 0:
					metadata_changed.append({
						"path": path,
						"changed_fields": changed_fields,
						"before": before_entry.duplicate(true),
						"after": after_entry.duplicate(true),
					})
		else:
			removed_entries.append(entry.duplicate(true))

	for entry in other.manifest:
		var path := _string_value(entry.get("path", ""))
		if path.is_empty():
			continue
		if not current_by_path.has(path):
			added_entries.append(entry.duplicate(true))

	var deleted_candidates: Dictionary = {}
	for removed_entry in removed_entries:
		var signature := _rename_signature(removed_entry)
		if signature.is_empty():
			deleted.append(removed_entry.duplicate(true))
			continue

		if not deleted_candidates.has(signature):
			deleted_candidates[signature] = []

		var bucket: Array = deleted_candidates[signature]
		bucket.append(removed_entry)
		deleted_candidates[signature] = bucket

	for incoming_entry in added_entries:
		var signature := _rename_signature(incoming_entry)
		if signature.is_empty() or not deleted_candidates.has(signature):
			added.append(incoming_entry.duplicate(true))
			continue

		var bucket: Array = deleted_candidates[signature]
		if bucket.is_empty():
			added.append(incoming_entry.duplicate(true))
			continue

		var previous_entry: Dictionary = bucket.pop_front()
		deleted_candidates[signature] = bucket

		var rename_payload := {
			"from_path": _string_value(previous_entry.get("path", "")),
			"to_path": _string_value(incoming_entry.get("path", "")),
			"before": previous_entry.duplicate(true),
			"after": incoming_entry.duplicate(true),
		}
		var changed_fields := _get_changed_metadata_fields(previous_entry, incoming_entry)
		if changed_fields.size() > 0:
			rename_payload["changed_fields"] = changed_fields
		renamed.append(rename_payload)

	for signature in deleted_candidates.keys():
		var bucket: Array = deleted_candidates[signature]
		for remaining_entry in bucket:
			deleted.append(remaining_entry.duplicate(true))

	return {
		"added": added,
		"modified": modified,
		"deleted": deleted,
		"renamed": renamed,
		"metadata_changed": metadata_changed,
	}


func get_entry_by_path(path: String) -> Dictionary:
	for entry in manifest:
		if _string_value(entry.get("path", "")) == path:
			return entry.duplicate(true)
	return {}


static func _sanitize_manifest(value: Variant) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				normalized.append(_sanitize_manifest_entry(item))
	return normalized


static func _sanitize_manifest_entry(entry: Dictionary) -> Dictionary:
	return {
		"path": _string_value(entry.get("path", "")),
		"content_hash": _string_value(entry.get("content_hash", "")),
		"kind": _string_value(entry.get("kind", "")),
		"source_bundle": _string_value(entry.get("source_bundle", "")),
		"import_preset_hash": _string_value(entry.get("import_preset_hash", "")),
		"last_modified_by": _string_value(entry.get("last_modified_by", "")),
		"last_modified_at": _string_value(entry.get("last_modified_at", "")),
	}


static func _build_manifest_map(entries: Array[Dictionary]) -> Dictionary:
	var by_path: Dictionary = {}
	for entry in entries:
		var path := _string_value(entry.get("path", ""))
		if not path.is_empty():
			by_path[path] = entry
	return by_path


static func _get_changed_metadata_fields(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var changed := PackedStringArray()
	for field in MANIFEST_METADATA_FIELDS:
		if _string_value(before.get(field, "")) != _string_value(after.get(field, "")):
			changed.append(field)
	return changed


static func _rename_signature(entry: Dictionary) -> String:
	var content_hash := _string_value(entry.get("content_hash", ""))
	if content_hash.is_empty():
		return ""

	return "%s|%s" % [
		content_hash,
		_string_value(entry.get("kind", "")),
	]


static func _clone_dictionary_array(entries: Array[Dictionary]) -> Array[Dictionary]:
	var cloned: Array[Dictionary] = []
	for entry in entries:
		cloned.append(entry.duplicate(true))
	return cloned


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value)
