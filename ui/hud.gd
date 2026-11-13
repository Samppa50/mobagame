extends CanvasLayer
## In-match HUD: health, cooldowns, yell meter, respawn and result messages.

var match_node: Node

var _hp: ProgressBar
var _hp_text: Label
var _q: Label
var _w: Label
var _yell: ProgressBar
var _yell_text: Label
var _center: Label


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bottom := VBoxContainer.new()
	bottom.custom_minimum_size = Vector2(460, 0)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	bottom.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 16)
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var yell_row := HBoxContainer.new()
	bottom.add_child(yell_row)
	var yl := Label.new()
	yl.text = "YELL "
	yell_row.add_child(yl)
	_yell = _bar(Color(1.0, 0.45, 0.1))
	_yell.min_value = 1.0
	_yell.max_value = Tune.YELL_MULT_MAX
	yell_row.add_child(_yell)
	_yell_text = Label.new()
	_yell_text.custom_minimum_size = Vector2(60, 0)
	yell_row.add_child(_yell_text)

	var hp_row := HBoxContainer.new()
	bottom.add_child(hp_row)
	var hl := Label.new()
	hl.text = "HP   "
	hp_row.add_child(hl)
	_hp = _bar(Color(0.3, 0.85, 0.35))
	hp_row.add_child(_hp)
	_hp_text = Label.new()
	_hp_text.custom_minimum_size = Vector2(60, 0)
	hp_row.add_child(_hp_text)

	var cd_row := HBoxContainer.new()
	cd_row.alignment = BoxContainer.ALIGNMENT_CENTER
	cd_row.add_theme_constant_override("separation", 30)
	bottom.add_child(cd_row)
	_q = Label.new()
	cd_row.add_child(_q)
	_w = Label.new()
	cd_row.add_child(_w)

	_center = Label.new()
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.add_theme_font_size_override("font_size", 48)
	_center.add_theme_constant_override("outline_size", 12)
	_center.add_theme_color_override("font_outline_color", Color.BLACK)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_center)
	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_center.grow_vertical = Control.GROW_DIRECTION_BOTH

	var minimap := preload("res://ui/minimap.gd").new()
	minimap.match_node = match_node
	root.add_child(minimap)
	minimap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	minimap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	minimap.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var help := Label.new()
	help.text = "Right-click: move / attack    Q, W: abilities (aim with mouse)    F3: hear yourself" \
		+ ("    V: fake yell (local test)" if Net.dev_mode else "")
	help.modulate = Color(1, 1, 1, 0.55)
	help.position = Vector2(12, 8)
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(help)


func _bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.step = 0.01
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, 20)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	return bar


func _process(_delta: float) -> void:
	var mult := Voice.my_multiplier()
	_yell.value = mult
	_yell_text.text = " x%.1f" % mult
	var hero = match_node.my_hero()
	if match_node.over:
		_center.text = "VICTORY" if match_node.winner == Net.my_team() else "DEFEAT"
	elif hero == null:
		_center.text = "Waiting for players..."
	elif hero.dead:
		_center.text = "Respawning in %d" % ceili(hero.respawn_left)
	else:
		_center.text = ""
	if hero != null:
		_hp.max_value = hero.max_hp
		_hp.value = hero.hp
		_hp_text.text = " %d" % ceili(hero.hp)
		_q.text = "Q  %s  %s" % [hero.def["q"]["name"], "ready" if hero.cd_q <= 0.0 else "%.1f" % hero.cd_q]
		_w.text = "W  %s  %s" % [hero.def["w"]["name"], "ready" if hero.cd_w <= 0.0 else "%.1f" % hero.cd_w]
