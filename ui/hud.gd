extends CanvasLayer
## In-match HUD: score bar, the hero panel (health, yell meter, abilities,
## stats, items, gold), the shop, the minimap, and respawn / result messages.

const GOLD_COLOR := Color(1.0, 0.84, 0.25)


## A small drawn box: an ability with its cooldown, or an item slot.
class Tile extends Control:
	signal clicked(button: int)

	var key := ""                          # corner label ("Q")
	var title := ""                        # centred text
	var title_size := 12
	var fill := Color(0.13, 0.14, 0.18)
	var cover := 0.0                       # 0..1 of the tile darkened (cooldown left)
	var big := ""                          # large centred text (seconds left)

	func _draw() -> void:
		var box := Rect2(Vector2.ZERO, size)
		var font := get_theme_default_font()
		draw_rect(box, fill)
		if key != "":
			draw_string(font, Vector2(6, 16), key, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.84, 0.25))
		if title != "":
			var y := size.y * 0.5 + title_size * (0.9 if key != "" else 0.4)
			draw_string(font, Vector2(2, y), title, HORIZONTAL_ALIGNMENT_CENTER, size.x - 4, title_size, Color(1, 1, 1, 0.92))
		if cover > 0.0:
			draw_rect(Rect2(0, 0, size.x, size.y * clampf(cover, 0.0, 1.0)), Color(0, 0, 0, 0.68))
		if big != "":
			draw_string(font, Vector2(0, size.y * 0.5 + 8), big, HORIZONTAL_ALIGNMENT_CENTER, size.x, 22)
		draw_rect(box, Color(0.42, 0.45, 0.52), false, 1.5)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			clicked.emit(event.button_index)
			accept_event()


var match_node: Node

var _hp: ProgressBar
var _hp_text: Label
var _yell: ProgressBar
var _yell_text: Label
var _center: Label
var _fps: Label
var _score := []          # one Label per team
var _clock: Label
var _kda: Label
var _name: Label
var _role: Label
var _stats: Label
var _abilities := []      # Tile for Q and W
var _slots := []          # Tile per item slot
var _gold: Label
var _shop: PanelContainer
var _shop_note: Label
var _buy := []            # Button per Tune.ITEMS entry


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_top(root)
	_build_panel(root)
	_build_shop(root)

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

	var help := _label("Right-click: move / attack    Q, W: abilities (aim with mouse)    B: shop    F3: hear yourself" \
		+ ("    V: fake yell (local test)" if Net.dev_mode else ""), 13, Color(1, 1, 1, 0.5))
	help.position = Vector2(12, 8)
	root.add_child(help)

	_fps = _label("", 13, Color(0.6, 1.0, 0.6, 0.8))
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_fps)
	_fps.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 8)
	_fps.grow_horizontal = Control.GROW_DIRECTION_BEGIN


# --- Construction ----------------------------------------------------------------

## Top centre: team kills either side of the match clock, own K / D / CS below.
func _build_top(root: Control) -> void:
	var top := _panel()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 30)
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	top.add_child(col)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	col.add_child(row)
	for team in 2:
		var score := _label("0", 26, Tune.team_color(team).lightened(0.25))
		score.custom_minimum_size = Vector2(44, 0)
		score.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if team == 0 else HORIZONTAL_ALIGNMENT_LEFT
		_score.append(score)
	_clock = _label("0:00", 20)
	_clock.custom_minimum_size = Vector2(64, 0)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_score[0])
	row.add_child(_clock)
	row.add_child(_score[1])
	_kda = _label("", 13, Color(1, 1, 1, 0.75))
	_kda.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_kda)


## Bottom centre: who you are, bars and abilities, items and gold.
func _build_panel(root: Control) -> void:
	var panel := _panel()
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 10)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	# Left: hero name, role and current stats.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(136, 0)
	left.add_theme_constant_override("separation", 0)
	row.add_child(left)
	_name = _label("", 18)
	left.add_child(_name)
	_role = _label("", 12, Color(1, 1, 1, 0.6))
	left.add_child(_role)
	_stats = _label("", 12, Color(0.85, 0.88, 0.95))
	left.add_child(_stats)

	# Middle: yell meter, health, abilities.
	var mid := VBoxContainer.new()
	mid.custom_minimum_size = Vector2(260, 0)
	mid.add_theme_constant_override("separation", 5)
	row.add_child(mid)
	_yell = _bar(Color(1.0, 0.45, 0.1), 14)
	_yell.min_value = 1.0
	_yell.max_value = Tune.YELL_MULT_MAX
	_yell_text = _bar_text(_yell, 11)
	mid.add_child(_yell)
	_hp = _bar(Color(0.25, 0.75, 0.3), 24)
	_hp_text = _bar_text(_hp, 14)
	mid.add_child(_hp)
	var cast := HBoxContainer.new()
	cast.add_theme_constant_override("separation", 6)
	mid.add_child(cast)
	for key in ["Q", "W"]:
		var tile := Tile.new()
		tile.key = key
		tile.custom_minimum_size = Vector2(0, 50)
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cast.add_child(tile)
		_abilities.append(tile)

	# Right: item slots, gold, shop button.
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 5)
	row.add_child(right)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	right.add_child(grid)
	for i in Tune.ITEM_SLOTS:
		var slot := Tile.new()
		slot.title_size = 15
		slot.custom_minimum_size = Vector2(42, 34)
		slot.clicked.connect(_slot_clicked.bind(i))
		grid.add_child(slot)
		_slots.append(slot)
	var purse := HBoxContainer.new()
	purse.add_theme_constant_override("separation", 6)
	right.add_child(purse)
	_gold = _label("0 g", 18, GOLD_COLOR)
	_gold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	purse.add_child(_gold)
	var open := Button.new()
	open.text = "Shop [B]"
	open.focus_mode = Control.FOCUS_NONE
	open.add_theme_font_size_override("font_size", 13)
	open.pressed.connect(_toggle_shop)
	purse.add_child(open)


## Left side, hidden until opened with B or the Shop button.
func _build_shop(root: Control) -> void:
	_shop = _panel()
	_shop.visible = false
	root.add_child(_shop)
	_shop.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	_shop.grow_vertical = Control.GROW_DIRECTION_BOTH
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(350, 0)
	col.add_theme_constant_override("separation", 5)
	_shop.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	var title := _label("SHOP", 20, GOLD_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = " X "
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_toggle_shop)
	head.add_child(close)
	_shop_note = _label("", 12)
	col.add_child(_shop_note)
	for i in Tune.ITEMS.size():
		var item: Dictionary = Tune.ITEMS[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		col.add_child(row)
		var swatch := ColorRect.new()
		swatch.color = item["color"]
		swatch.custom_minimum_size = Vector2(6, 0)
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(swatch)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", -2)
		row.add_child(text)
		text.add_child(_label(item["name"], 15))
		text.add_child(_label(Tune.item_text(i), 12, Color(1, 1, 1, 0.65)))
		var buy := Button.new()
		buy.text = "%d g" % item["cost"]
		buy.custom_minimum_size = Vector2(72, 0)
		buy.focus_mode = Control.FOCUS_NONE
		buy.pressed.connect(_buy_item.bind(i))
		row.add_child(buy)
		_buy.append(buy)


func _panel() -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.88)
	style.border_color = Color(0.36, 0.39, 0.47)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _label(text: String, font_size: int, color := Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _bar(color: Color, height: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.step = 0.01
	bar.custom_minimum_size = Vector2(0, height)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.1, 0.11, 0.14)
	bar.add_theme_stylebox_override("background", back)
	return bar


## A centred caption drawn over a bar.
func _bar_text(bar: ProgressBar, font_size: int) -> Label:
	var label := _label("", font_size)
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return label


# --- Shop actions ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_toggle_shop()
		elif event.keycode == KEY_ESCAPE and _shop.visible:
			_shop.visible = false


func _toggle_shop() -> void:
	_shop.visible = not _shop.visible


func _buy_item(index: int) -> void:
	var hero: Hero = match_node.my_hero()
	if hero != null and not match_node.over:
		match_node.command(hero, "cmd_buy", [index])


## Right-click an item slot to sell it.
func _slot_clicked(button: int, slot: int) -> void:
	var hero: Hero = match_node.my_hero()
	if button == MOUSE_BUTTON_RIGHT and hero != null and not match_node.over:
		match_node.command(hero, "cmd_sell", [slot])


# --- Per-frame refresh ---------------------------------------------------------------

func _process(_delta: float) -> void:
	var mult := Voice.my_multiplier()
	_yell.value = mult
	_yell_text.text = "YELL  x%.1f" % mult
	_fps.text = "%d FPS" % Engine.get_frames_per_second()
	var score := [0, 0]
	if match_node.units != null:
		for u in match_node.units.get_children():
			if u is Hero:
				score[u.team] += u.kills
	for team in 2:
		_score[team].text = str(score[team])
	var seconds := int(match_node.clock)
	_clock.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]

	var hero: Hero = match_node.my_hero()
	if match_node.over:
		_center.text = "VICTORY" if match_node.winner == Net.my_team() else "DEFEAT"
	elif hero == null:
		_center.text = "Waiting for players..."
	elif hero.dead:
		_center.text = "Respawning in %d" % ceili(hero.respawn_left)
	else:
		_center.text = ""
	if hero == null:
		return

	_kda.text = "%d kills    %d deaths    %d minions" % [hero.kills, hero.deaths, hero.cs]
	_name.text = hero.def["name"]
	_role.text = hero.def["role"]
	_stats.text = "Attack  %d   (%.2f/s)\nPower  %d%%   CDR  %d%%\nSpeed  %.1f   Range  %.1f" % [
		hero.atk_dmg, 1.0 / hero.atk_interval, roundi(hero.power * 100.0), roundi(hero.cdr * 100.0),
		hero.move_speed, hero.def["range"]]
	_hp.max_value = hero.max_hp
	_hp.value = hero.hp
	_hp_text.text = "%d / %d" % [ceili(hero.hp), hero.max_hp]
	_gold.text = "%d g" % hero.gold

	for slot in 2:
		var tile: Tile = _abilities[slot]
		var spec: Dictionary = hero.def["q" if slot == 0 else "w"]
		var left: float = hero.cd_q if slot == 0 else hero.cd_w
		tile.title = spec["name"]
		tile.cover = left / hero.cooldown(slot)
		tile.big = "%.1f" % left if left > 0.0 else ""
		_tip(tile, _ability_text(hero, spec, slot))
		tile.queue_redraw()

	var open := hero.can_shop()
	for i in _slots.size():
		var tile: Tile = _slots[i]
		if i < hero.items.size():
			var item: Dictionary = Tune.ITEMS[hero.items[i]]
			tile.title = _initials(item["name"])
			tile.fill = item["color"].darkened(0.55)
			_tip(tile, "%s\n%s\nRight-click to sell for %d g (at the fountain)." % [
				item["name"], Tune.item_text(hero.items[i]), int(item["cost"] * Tune.SELL_REFUND)])
		else:
			tile.title = ""
			tile.fill = Color(0.1, 0.11, 0.14)
			_tip(tile, "Empty item slot")
		tile.queue_redraw()

	if _shop.visible:
		var full: bool = hero.items.size() >= Tune.ITEM_SLOTS
		if not open:
			_shop_note.text = "Return to your fountain to buy or sell."
			_shop_note.modulate = Color(1.0, 0.6, 0.35)
		elif full:
			_shop_note.text = "All %d item slots are full. Right-click a slot to sell." % Tune.ITEM_SLOTS
			_shop_note.modulate = Color(1.0, 0.6, 0.35)
		else:
			_shop_note.text = "Right-click one of your item slots to sell it for %d%%." % roundi(Tune.SELL_REFUND * 100.0)
			_shop_note.modulate = Color(1, 1, 1, 0.65)
		for i in _buy.size():
			_buy[i].disabled = not open or full or hero.gold < Tune.ITEMS[i]["cost"]


func _tip(control: Control, text: String) -> void:
	if control.tooltip_text != text:
		control.tooltip_text = text


func _initials(text: String) -> String:
	var out := ""
	for word in text.split(" ", false):
		out += word[0]
	return out


func _ability_text(hero: Hero, spec: Dictionary, slot: int) -> String:
	var what := ""
	var scaled := true
	match spec["type"]:
		"shot": what = "Fires a bolt toward the cursor for %d damage." % roundi(spec["dmg"] * hero.power)
		"slam": what = "Hits every enemy around you for %d damage." % roundi(spec["dmg"] * hero.power)
		"dash": what = "Leap toward the cursor and hit every enemy where you land for %d damage." % roundi(spec["dmg"] * hero.power)
		"heal": what = "Heals allied heroes around you for %d." % roundi(spec["amount"] * hero.power)
		_:
			what = "Teleport toward the cursor."
			scaled = false
	return "%s\n%s\nCooldown %.1f s.%s" % [spec["name"], what, hero.cooldown(slot),
		" Yelling multiplies it." if scaled else ""]
