@tool
class_name EchoThinkConfirmationDialog
extends ConfirmationDialog


signal cancelled


var _risk_badge: EchoThinkRiskBadge = null
var _summary_label: Label = null
var _detail_view: RichTextLabel = null


func _ready() -> void:
	_build_ui()
	if not is_connected("confirmed", Callable(self, "_on_builtin_confirmed")):
		connect("confirmed", Callable(self, "_on_builtin_confirmed"))
	if has_signal("canceled") and not is_connected("canceled", Callable(self, "_on_builtin_canceled")):
		connect("canceled", Callable(self, "_on_builtin_canceled"))


func show_for_patch(patch: PatchProposal, risk: EchoThinkPolicyGuard.RiskLevel) -> void:
	var details := PackedStringArray()
	details.append("Patch ID: %s" % _fallback_text(patch.patch_id, "unspecified"))
	details.append("Work Item: %s" % _fallback_text(patch.work_item_id, "unspecified"))
	details.append("Operations: %d" % patch.get_operation_count())
	details.append("Affected Files: %d" % patch.get_affected_files().size())
	if not patch.base_branch.is_empty():
		details.append("Base Branch: %s" % patch.base_branch)
	if not patch.base_commit.is_empty():
		details.append("Base Commit: %s" % patch.base_commit)
	if not patch.publish_intent.is_empty():
		details.append("Publish Intent: %s" % patch.publish_intent)
	if not patch.risk_summary.is_empty():
		details.append("Risk Summary: %s" % patch.risk_summary)
	if not patch.validation_plan.is_empty():
		details.append("")
		details.append("Validation Plan:")
		for entry in patch.validation_plan:
			details.append("  • %s" % entry)
	_set_content(
		"Confirm Patch",
		"Apply the selected patch proposal to the current workspace?",
		details,
		risk
	)


func show_for_rollback(changeset: ChangeSet) -> void:
	var details := PackedStringArray()
	details.append("ChangeSet ID: %s" % _fallback_text(changeset.changeset_id, "unspecified"))
	details.append("Status: %s" % _fallback_text(changeset.status, ChangeSet.STATUS_APPLIED))
	details.append("Operations: %d" % changeset.operations.size())
	details.append("Affected Paths: %d" % changeset.get_affected_paths().size())
	if not changeset.error_message.is_empty():
		details.append("Last Error: %s" % changeset.error_message)
	_set_content(
		"Confirm Rollback",
		"Rollback the selected changeset and restore tracked preimages where available?",
		details,
		EchoThinkPolicyGuard.RiskLevel.HIGH
	)


func show_for_asset_pull(bundle: AssetBundle) -> void:
	var details := PackedStringArray()
	details.append("Bundle ID: %s" % _fallback_text(bundle.bundle_id, "unspecified"))
	details.append("Workspace: %s" % _fallback_text(bundle.workspace_id, "unspecified"))
	details.append("Assets: %d" % bundle.get_asset_count())
	details.append("Dependencies: %d" % bundle.dependencies.size())
	if not bundle.license_type.is_empty():
		details.append("License: %s" % bundle.license_type)
	if bundle.license_attribution_required:
		details.append("Attribution: required")
	for target_path in bundle.get_total_target_paths():
		details.append("  • %s" % target_path)
	_set_content(
		"Confirm Asset Pull",
		"Import the selected asset bundle into the local project?",
		details,
		EchoThinkPolicyGuard.RiskLevel.MEDIUM
	)


func _set_content(dialog_title: String, summary: String, details: PackedStringArray, risk: EchoThinkPolicyGuard.RiskLevel) -> void:
	_build_ui()
	title = dialog_title
	_risk_badge.set_risk(risk)
	_summary_label.text = summary
	_detail_view.clear()
	_detail_view.append_text(_join_lines(details))
	popup_centered_ratio(0.42)


func _build_ui() -> void:
	if _summary_label != null:
		return

	min_size = Vector2i(480, 320)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	add_child(content)

	_risk_badge = EchoThinkRiskBadge.new()
	content.add_child(_risk_badge)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_summary_label)

	_detail_view = RichTextLabel.new()
	_detail_view.fit_content = true
	_detail_view.scroll_active = true
	_detail_view.custom_minimum_size = Vector2(440.0, 180.0)
	_detail_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_detail_view)


func _join_lines(lines: PackedStringArray) -> String:
	var output := ""
	for index in range(lines.size()):
		output += lines[index]
		if index < lines.size() - 1:
			output += "\n"
	return output


func _fallback_text(value: String, fallback: String) -> String:
	var normalized := value.strip_edges()
	return fallback if normalized.is_empty() else normalized


func _on_builtin_confirmed() -> void:
	pass


func _on_builtin_canceled() -> void:
	cancelled.emit()
