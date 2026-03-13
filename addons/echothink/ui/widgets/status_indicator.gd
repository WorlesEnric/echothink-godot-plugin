@tool
class_name EchoThinkStatusIndicator
extends HBoxContainer


var _dot: PanelContainer = null
var _label: Label = null
var _state: String = "offline"


func _ready() -> void:
	_build_ui()
	set_state(_state)


func set_state(state: String) -> void:
	_state = state.strip_edges().to_lower()
	if _state.is_empty():
		_state = "offline"

	if _dot == null or _label == null:
		return

	_label.text = _state.replace("_", " ").capitalize()
	var style_box := StyleBoxFlat.new()
	style_box.bg_color = _color_for_state(_state)
	style_box.corner_radius_top_left = 5
	style_box.corner_radius_top_right = 5
	style_box.corner_radius_bottom_right = 5
	style_box.corner_radius_bottom_left = 5
	_dot.add_theme_stylebox_override("panel", style_box)


func _build_ui() -> void:
	if _label != null:
		return

	add_theme_constant_override("separation", 8)

	_dot = PanelContainer.new()
	_dot.custom_minimum_size = Vector2(10.0, 10.0)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(_dot)

	_label = Label.new()
	_label.text = "Offline"
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_label)


func _color_for_state(state: String) -> Color:
	match state:
		"connected":
			return Color("#4CAF50")
		"degraded":
			return Color("#FFC107")
		"connecting":
			return Color("#2196F3")
		"disconnected":
			return Color("#F44336")
		_:
			return Color("#9E9E9E")
