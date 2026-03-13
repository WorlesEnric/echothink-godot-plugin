@tool
class_name EchoThinkRiskBadge
extends PanelContainer


var _label: Label = null


func _ready() -> void:
	_build_ui()
	set_risk(EchoThinkPolicyGuard.RiskLevel.LOW)


func set_risk(level: EchoThinkPolicyGuard.RiskLevel) -> void:
	_build_ui()
	var text := "LOW"
	var color := Color("#4CAF50")
	match level:
		EchoThinkPolicyGuard.RiskLevel.MEDIUM:
			text = "MEDIUM"
			color = Color("#FF9800")
		EchoThinkPolicyGuard.RiskLevel.HIGH:
			text = "HIGH"
			color = Color("#F44336")
		EchoThinkPolicyGuard.RiskLevel.CRITICAL:
			text = "CRITICAL"
			color = Color("#9C27B0")

	_label.text = text
	var style_box := StyleBoxFlat.new()
	style_box.bg_color = color
	style_box.corner_radius_top_left = 10
	style_box.corner_radius_top_right = 10
	style_box.corner_radius_bottom_right = 10
	style_box.corner_radius_bottom_left = 10
	add_theme_stylebox_override("panel", style_box)


func _build_ui() -> void:
	if _label != null:
		return

	custom_minimum_size = Vector2(96.0, 24.0)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_label)
