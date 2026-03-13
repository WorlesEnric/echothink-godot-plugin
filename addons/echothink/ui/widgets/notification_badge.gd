@tool
class_name EchoThinkNotificationBadge
extends PanelContainer


var _label: Label = null


func _ready() -> void:
	_build_ui()
	set_count(0)


func set_count(count: int) -> void:
	_build_ui()
	var normalized_count := maxi(count, 0)
	visible = normalized_count > 0
	_label.text = "99+" if normalized_count > 99 else str(normalized_count)


func _build_ui() -> void:
	if _label != null:
		return

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(22.0, 22.0)
	var style_box := StyleBoxFlat.new()
	style_box.bg_color = Color("#F44336")
	style_box.corner_radius_top_left = 11
	style_box.corner_radius_top_right = 11
	style_box.corner_radius_bottom_right = 11
	style_box.corner_radius_bottom_left = 11
	add_theme_stylebox_override("panel", style_box)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_label)
