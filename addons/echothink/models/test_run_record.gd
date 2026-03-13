@tool
class_name TestRunRecord
extends RefCounted


const STATUS_PENDING := "pending"
const STATUS_RUNNING := "running"
const STATUS_PASSED := "passed"
const STATUS_FAILED := "failed"
const STATUS_ERROR := "error"


var record_id: String = ""
var work_item_id: String = ""
var task_run_id: String = ""
var strategy_id: String = ""
var strategy_kind: String = ""
var status: String = STATUS_PENDING
var started_at: String = ""
var completed_at: String = ""
var duration_ms: int = 0
var results: Array[Dictionary] = []
var error_message: String = ""
var artifact_uris: PackedStringArray = PackedStringArray()


func to_dict() -> Dictionary:
	return {
		"record_id": record_id,
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"strategy_id": strategy_id,
		"strategy_kind": strategy_kind,
		"status": status,
		"started_at": started_at,
		"completed_at": completed_at,
		"duration_ms": duration_ms,
		"results": _clone_dictionary_array(results),
		"error_message": error_message,
		"artifact_uris": _clone_string_array(artifact_uris),
	}


static func from_dict(data: Dictionary) -> TestRunRecord:
	var record := TestRunRecord.new()
	record.record_id = _string_value(data.get("record_id", ""))
	record.work_item_id = _string_value(data.get("work_item_id", ""))
	record.task_run_id = _string_value(data.get("task_run_id", ""))
	record.strategy_id = _string_value(data.get("strategy_id", ""))
	record.strategy_kind = _string_value(data.get("strategy_kind", ""))
	record.status = _string_value(data.get("status", STATUS_PENDING), STATUS_PENDING)
	record.started_at = _string_value(data.get("started_at", ""))
	record.completed_at = _string_value(data.get("completed_at", ""))
	record.duration_ms = _int_value(data.get("duration_ms", 0), 0)
	record.results = _sanitize_results(data.get("results", []))
	record.error_message = _string_value(data.get("error_message", ""))
	record.artifact_uris = _sanitize_string_array(data.get("artifact_uris", PackedStringArray()))
	return record


func is_passed() -> bool:
	return status.to_lower() == STATUS_PASSED


func get_failed_tests() -> Array[Dictionary]:
	var failed_tests: Array[Dictionary] = []
	for result in results:
		var result_status := _string_value(result.get("status", "")).to_lower()
		if result_status == STATUS_FAILED or result_status == STATUS_ERROR:
			failed_tests.append(result.duplicate(true))
	return failed_tests


func get_pass_rate() -> float:
	if results.is_empty():
		return 0.0

	var passed_count := 0
	for result in results:
		if _string_value(result.get("status", "")).to_lower() == STATUS_PASSED:
			passed_count += 1

	return float(passed_count) / float(results.size())


static func _sanitize_results(value: Variant) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				normalized.append(_sanitize_result(item))
	return normalized


static func _sanitize_result(result: Dictionary) -> Dictionary:
	return {
		"test_name": _string_value(result.get("test_name", "")),
		"status": _string_value(result.get("status", "")),
		"duration_ms": _int_value(result.get("duration_ms", 0), 0),
		"message": _string_value(result.get("message", "")),
	}


static func _sanitize_string_array(value: Variant) -> PackedStringArray:
	var normalized := PackedStringArray()
	if value is PackedStringArray:
		for item in value:
			normalized.append(_string_value(item))
		return normalized
	if value is Array:
		for item in value:
			normalized.append(_string_value(item))
	return normalized


static func _clone_string_array(values: PackedStringArray) -> PackedStringArray:
	var cloned := PackedStringArray()
	for value in values:
		cloned.append(_string_value(value))
	return cloned


static func _clone_dictionary_array(entries: Array[Dictionary]) -> Array[Dictionary]:
	var cloned: Array[Dictionary] = []
	for entry in entries:
		cloned.append(entry.duplicate(true))
	return cloned


static func _int_value(value: Variant, default_value: int = 0) -> int:
	if value is int:
		return max(value, 0)
	if value is float:
		return max(int(value), 0)
	if value is String:
		var normalized := value.strip_edges()
		if normalized.is_valid_int():
			return max(normalized.to_int(), 0)
	return default_value


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value)
