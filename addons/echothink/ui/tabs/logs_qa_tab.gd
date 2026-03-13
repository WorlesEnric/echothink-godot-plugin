@tool
class_name EchoThinkLogsQATab
extends VBoxContainer


var event_bus: EchoThinkEventBus = null
var log_service: EchoThinkLogService = null
var policy_guard: EchoThinkPolicyGuard = null

var _source_filter: OptionButton = null
var _level_filter: OptionButton = null
var _log_view: RichTextLabel = null
var _strategy_list: OptionButton = null
var _analysis_view: RichTextLabel = null
var _test_results_view: RichTextLabel = null
var _status_label: Label = null

var _current_bundle: LogBundle = null
var _strategy_ids: Array[String] = []
var _signals_connected: bool = false
var _ui_built: bool = false


func _ready() -> void:
	_build_ui()
	if event_bus != null:
		_connect_signals()
		_populate_test_strategies()


func initialize(events: EchoThinkEventBus, logs: EchoThinkLogService, policy: EchoThinkPolicyGuard) -> void:
	event_bus = events
	log_service = logs
	policy_guard = policy
	if is_node_ready():
		_build_ui()
		_connect_signals()
		_populate_test_strategies()


func cleanup() -> void:
	if not _signals_connected or event_bus == null:
		return
	if event_bus.test_completed.is_connected(_on_test_completed):
		event_bus.test_completed.disconnect(_on_test_completed)
	if event_bus.log_analysis_ready.is_connected(_on_log_analysis_ready):
		event_bus.log_analysis_ready.disconnect(_on_log_analysis_ready)
	if event_bus.error_occurred.is_connected(_on_error_occurred):
		event_bus.error_occurred.disconnect(_on_error_occurred)
	_signals_connected = false


func _build_ui() -> void:
	if _ui_built:
		return

	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 8)
	add_child(filter_row)

	filter_row.add_child(_label_for("Source"))
	_source_filter = OptionButton.new()
	_source_filter.item_selected.connect(_on_filter_changed)
	filter_row.add_child(_source_filter)

	filter_row.add_child(_label_for("Level"))
	_level_filter = OptionButton.new()
	_level_filter.item_selected.connect(_on_filter_changed)
	filter_row.add_child(_level_filter)
	_level_filter.add_item("All")
	_level_filter.add_item("Debug")
	_level_filter.add_item("Info")
	_level_filter.add_item("Warning")
	_level_filter.add_item("Error")

	var collect_button := Button.new()
	collect_button.text = "Collect Logs"
	collect_button.pressed.connect(_on_collect_logs_pressed)
	filter_row.add_child(collect_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "Collect editor logs and run approved test strategies from this panel."
	add_child(_status_label)

	var main_split := VSplitContainer.new()
	main_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_split)

	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_active = true
	_log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_split.add_child(_log_view)

	var bottom_panel := VBoxContainer.new()
	bottom_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_panel.add_theme_constant_override("separation", 8)
	main_split.add_child(bottom_panel)

	var test_row := HBoxContainer.new()
	test_row.add_theme_constant_override("separation", 8)
	bottom_panel.add_child(test_row)

	test_row.add_child(_label_for("Strategy"))
	_strategy_list = OptionButton.new()
	test_row.add_child(_strategy_list)

	var run_button := Button.new()
	run_button.text = "Run Test"
	run_button.pressed.connect(_on_run_test_pressed)
	test_row.add_child(run_button)

	_analysis_view = RichTextLabel.new()
	_analysis_view.fit_content = true
	_analysis_view.custom_minimum_size = Vector2(320.0, 120.0)
	bottom_panel.add_child(_analysis_view)

	_test_results_view = RichTextLabel.new()
	_test_results_view.fit_content = true
	_test_results_view.custom_minimum_size = Vector2(320.0, 140.0)
	bottom_panel.add_child(_test_results_view)

	_ui_built = true
	_refresh_source_filter(PackedStringArray())


func _connect_signals() -> void:
	if _signals_connected or event_bus == null:
		return
	event_bus.test_completed.connect(_on_test_completed)
	event_bus.log_analysis_ready.connect(_on_log_analysis_ready)
	event_bus.error_occurred.connect(_on_error_occurred)
	_signals_connected = true


func _on_collect_logs_pressed() -> void:
	if log_service == null:
		return
	var sources := PackedStringArray()
	var selected_source := _selected_source()
	if selected_source != "all":
		sources.append(selected_source)
	_current_bundle = await log_service.collect_logs(sources)
	_refresh_source_filter(_available_sources())
	_render_logs()
	if _current_bundle != null and _current_bundle.get_entry_count() > 0:
		var request_id := await log_service.submit_for_analysis(_current_bundle)
		_analysis_view.clear()
		if request_id.is_empty():
			_analysis_view.append_text("Analysis request not available.")
		else:
			_analysis_view.append_text("Analysis requested: %s" % request_id)
	_status_label.text = "Collected %d log entries." % [_current_bundle.get_entry_count() if _current_bundle != null else 0]


func _on_run_test_pressed() -> void:
	if log_service == null or _strategy_ids.is_empty():
		return
	var selected_index := _strategy_list.selected
	if selected_index < 0 or selected_index >= _strategy_ids.size():
		return
	var strategy_id := _strategy_ids[selected_index]
	_status_label.text = "Running strategy %s..." % strategy_id
	var record := await log_service.submit_test_run(strategy_id)
	if not record.record_id.is_empty() and (record.status == TestRunRecord.STATUS_PENDING or record.status == TestRunRecord.STATUS_RUNNING):
		record = await _poll_test_results(record.record_id)
	_on_test_completed(record)


func _on_test_completed(record: TestRunRecord) -> void:
	_test_results_view.clear()
	if record == null:
		_test_results_view.append_text("No test results available.")
		return

	var lines := PackedStringArray()
	lines.append("Strategy: %s" % _fallback_text(record.strategy_id, "—"))
	lines.append("Status: %s" % _fallback_text(record.status, TestRunRecord.STATUS_PENDING))
	lines.append("Duration: %d ms" % record.duration_ms)
	lines.append("Pass Rate: %.0f%%" % (record.get_pass_rate() * 100.0))
	if not record.error_message.is_empty():
		lines.append("Error: %s" % record.error_message)
	if not record.results.is_empty():
		lines.append("")
		for result in record.results:
			lines.append("• %s — %s (%d ms)" % [
				_fallback_text(String(result.get("test_name", "")), "unnamed"),
				_fallback_text(String(result.get("status", "")), "unknown"),
				int(result.get("duration_ms", 0))
			])
	_test_results_view.append_text(_join_lines(lines))
	_status_label.text = "Test run %s." % (_fallback_text(record.status, "completed"))


func _on_log_analysis_ready(results: Dictionary) -> void:
	_analysis_view.clear()
	_analysis_view.append_text(JSON.stringify(results, "\t"))
	_status_label.text = "Log analysis results received."


func _on_error_occurred(source: String, msg: String) -> void:
	if _current_bundle == null:
		_current_bundle = LogBundle.new()
	_current_bundle.add_entry({
		"timestamp": str(Time.get_unix_time_from_system()),
		"source": source,
		"level": "error",
		"message": msg,
	})
	_refresh_source_filter(_available_sources())
	_render_logs()


func _populate_test_strategies() -> void:
	if _strategy_list == null:
		return
	_strategy_list.clear()
	_strategy_ids.clear()
	if policy_guard == null:
		_strategy_list.add_item("No strategies available")
		return
	for strategy_id in policy_guard.get_allowed_test_strategies():
		_strategy_ids.append(strategy_id)
		var details := policy_guard.get_strategy_by_id(strategy_id)
		var label := strategy_id
		if not details.is_empty() and not String(details.get("description", "")).strip_edges().is_empty():
			label = "%s — %s" % [strategy_id, details.get("description", "")]
		_strategy_list.add_item(label)
	if _strategy_ids.is_empty():
		_strategy_list.add_item("No strategies available")


func _poll_test_results(record_id: String) -> TestRunRecord:
	var record := TestRunRecord.new()
	for _attempt in range(3):
		await get_tree().create_timer(1.0).timeout
		record = await log_service.get_test_results(record_id)
		if record.status != TestRunRecord.STATUS_PENDING and record.status != TestRunRecord.STATUS_RUNNING:
			return record
	return record


func _render_logs() -> void:
	if _log_view == null:
		return
	_log_view.clear()
	if _current_bundle == null or _current_bundle.entries.is_empty():
		_log_view.append_text("No log entries collected.")
		return

	var source_filter := _selected_source()
	var level_filter := _selected_level()
	var output := ""
	for entry in _current_bundle.entries:
		var entry_source := String(entry.get("source", "")).strip_edges().to_lower()
		var entry_level := String(entry.get("level", "")).strip_edges().to_lower()
		if source_filter != "all" and entry_source != source_filter:
			continue
		if level_filter != "all" and entry_level != level_filter:
			continue
		output += "[color=%s][%s][/color] %s %s\n" % [
			_level_color(entry_level),
			entry_level.to_upper(),
			_escape_bbcode(String(entry.get("source", "editor"))),
			_escape_bbcode(String(entry.get("message", "")))
		]
	if output.is_empty():
		output = "No entries match the active filter."
	_log_view.append_text(output)


func _refresh_source_filter(sources: PackedStringArray) -> void:
	if _source_filter == null:
		return
	var selected_text := _selected_source()
	_source_filter.clear()
	_source_filter.add_item("All")
	for source in sources:
		_source_filter.add_item(source)
	for index in range(_source_filter.get_item_count()):
		if _source_filter.get_item_text(index).to_lower() == selected_text:
			_source_filter.select(index)
			return
	_source_filter.select(0)


func _available_sources() -> PackedStringArray:
	var sources := PackedStringArray()
	if _current_bundle == null:
		return sources
	for entry in _current_bundle.entries:
		var source := String(entry.get("source", "")).strip_edges()
		if not source.is_empty() and not sources.has(source):
			sources.append(source)
	return sources


func _selected_source() -> String:
	if _source_filter == null or _source_filter.get_item_count() == 0:
		return "all"
	return _source_filter.get_item_text(_source_filter.selected).strip_edges().to_lower()


func _selected_level() -> String:
	if _level_filter == null or _level_filter.get_item_count() == 0:
		return "all"
	return _level_filter.get_item_text(_level_filter.selected).strip_edges().to_lower()


func _on_filter_changed(_index: int) -> void:
	_render_logs()


func _label_for(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _level_color(level: String) -> String:
	match level:
		"error", "critical":
			return "#F44336"
		"warning", "warn":
			return "#FFC107"
		"info":
			return "#4FC3F7"
		_:
			return "#B0BEC5"


func _join_lines(lines: PackedStringArray) -> String:
	var output := ""
	for index in range(lines.size()):
		output += lines[index]
		if index < lines.size() - 1:
			output += "\n"
	return output


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "\\[").replace("]", "\\]")


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized
