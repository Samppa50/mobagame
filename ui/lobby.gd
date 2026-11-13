extends Control
## Pre-match lobby: roster, team pick, map and hero pick, mic check, start.

const Style := preload("res://ui/style.gd")

var _rows := []       # per team: the VBoxContainer holding its player rows
var _counts := []     # per team: "3 / 5" label
var _joins := []      # "Join" buttons
var _bot_adds := []   # host only: "+ Bot" buttons
var _mic: ProgressBar
var _mic_note: Label
var _start: Button
var _hero_buttons := []
var _map_buttons := []
var _hover := -1      # hero card under the mouse; its details are previewed

# Hero detail panel.
var _face: Control
var _hero_name: Label
var _hero_role: Label
var _stat_bars := []
var _stat_values := []
var _ability_names := []
var _ability_notes := []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = Style.theme()
	add_child(Style.Backdrop.new())
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(1160, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	_build_header(box)
	var teams := HBoxContainer.new()
	teams.add_theme_constant_override("separation", 12)
	box.add_child(teams)
	for team in 2:
		_build_team(teams, team)
	var heroes := HBoxContainer.new()
	heroes.add_theme_constant_override("separation", 12)
	box.add_child(heroes)
	_build_hero_grid(heroes)
	_build_hero_detail(heroes)
	_build_footer(box)

	Net.roster_changed.connect(_refresh)
	_refresh()


func _build_header(box: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(Style.label("LOBBY", 34, Style.ACCENT))
	if Net.dev_mode:
		var note := Style.label("local test", 14, Style.DIM)
		note.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(note)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	var caption := Style.heading("Map")
	row.add_child(caption)
	for i in Tune.maps.size():
		var pick := Button.new()
		pick.text = Tune.maps[i]["name"]
		pick.toggle_mode = true
		pick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pick.pressed.connect(Net.choose_map.bind(i))
		row.add_child(pick)
		_map_buttons.append(pick)


func _build_team(parent: Node, team: int) -> void:
	var color := Tune.team_color(team)
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := Style.box(Style.PANEL.lerp(Color(color, Style.PANEL.a), 0.1), color.darkened(0.25), 10, 14.0)
	style.border_width_top = 4
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	col.add_child(head)
	head.add_child(Style.label("%s team" % Tune.team_name(team), 20, color.lightened(0.35)))
	var count := Style.label("", 14, Style.DIM)
	head.add_child(count)
	_counts.append(count)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	if multiplayer.is_server():
		var add := Button.new()
		add.text = "+ Bot"
		add.tooltip_text = "Add a bot to this team."
		add.pressed.connect(Net.add_bot.bind(team))
		head.add_child(add)
		_bot_adds.append(add)
		var remove := Button.new()
		remove.text = "- Bot"
		remove.tooltip_text = "Remove the bot added last."
		remove.pressed.connect(Net.remove_bot.bind(team))
		head.add_child(remove)
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(Net.choose_team.bind(team))
	head.add_child(join)
	_joins.append(join)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	col.add_child(rows)
	_rows.append(rows)


func _build_hero_grid(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	col.add_child(Style.heading("Choose your hero"))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)
	for i in Tune.HEROES.size():
		var d: Dictionary = Tune.HEROES[i]
		var card := Button.new()
		card.toggle_mode = true
		card.custom_minimum_size = Vector2(0, 88)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.pressed.connect(Net.choose_hero.bind(i))
		card.mouse_entered.connect(_set_hover.bind(i))
		card.mouse_exited.connect(_clear_hover.bind(i))
		grid.add_child(card)
		_hero_buttons.append(card)
		var inner := VBoxContainer.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		inner.add_theme_constant_override("separation", 0)
		card.add_child(inner)
		inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var face := Style.Portrait.new(i, 46.0)
		inner.add_child(face)
		var name_label := Style.label(d["name"], 14)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inner.add_child(name_label)
		var role := Style.label(d["role"], 11, Style.DIM)
		role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inner.add_child(role)


func _build_hero_detail(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 0)
	parent.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	col.add_child(top)
	_face = Style.Portrait.new(0, 76.0)
	top.add_child(_face)
	var who := VBoxContainer.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_theme_constant_override("separation", 0)
	top.add_child(who)
	_hero_name = Style.label("", 24)
	who.add_child(_hero_name)
	_hero_role = Style.label("", 14, Style.DIM)
	who.add_child(_hero_role)

	var stats := GridContainer.new()
	stats.columns = 3
	stats.add_theme_constant_override("h_separation", 8)
	stats.add_theme_constant_override("v_separation", 3)
	stats.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(stats)
	for caption: String in ["Health", "Attack", "Range", "Speed"]:
		stats.add_child(Style.label(caption, 12, Style.DIM))
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = 1.0
		bar.step = 0.001
		bar.custom_minimum_size = Vector2(130, 8)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats.add_child(bar)
		_stat_bars.append(bar)
		var value := Style.label("", 12)
		value.custom_minimum_size = Vector2(34, 0)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stats.add_child(value)
		_stat_values.append(value)

	col.add_child(HSeparator.new())
	for slot: String in Tune.SLOTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		col.add_child(row)
		var key := Style.label(slot.to_upper(), 13, Style.ACCENT)
		key.custom_minimum_size = Vector2(24, 22)
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		key.add_theme_stylebox_override("normal", Style.box(Style.INSET, Style.EDGE, 4, 0.0))
		row.add_child(key)
		var title := Style.label("", 14)
		title.custom_minimum_size = Vector2(120, 0)
		row.add_child(title)
		_ability_names.append(title)
		var note := Style.label("", 12, Style.DIM)
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		note.clip_text = true
		row.add_child(note)
		_ability_notes.append(note)


func _build_footer(box: Node) -> void:
	var panel := PanelContainer.new()
	box.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var mic := VBoxContainer.new()
	mic.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mic.add_theme_constant_override("separation", 4)
	row.add_child(mic)
	mic.add_child(Style.heading("Mic check"))
	_mic = ProgressBar.new()
	_mic.min_value = 1.0
	_mic.max_value = Tune.YELL_MULT_MAX
	_mic.step = 0.01
	_mic.show_percentage = false
	_mic.custom_minimum_size = Vector2(0, 14)
	mic.add_child(_mic)
	_mic_note = Style.label("", 13, Style.DIM)
	mic.add_child(_mic_note)

	var leave := Button.new()
	leave.text = "Leave"
	leave.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	leave.pressed.connect(Net.quit_session)
	row.add_child(leave)
	if Net.lobby_id != 0:
		var invite := Button.new()
		invite.text = "Invite friends"
		invite.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		invite.pressed.connect(Net.invite_friends)
		row.add_child(invite)
	_start = Button.new()
	_start.text = "Start match"
	_start.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_start.add_theme_font_size_override("font_size", 18)
	Style.primary(_start)
	_start.pressed.connect(Net.start_match)
	row.add_child(_start)


func _set_hover(index: int) -> void:
	_hover = index
	_show_hero()


func _clear_hover(index: int) -> void:
	if _hover == index:
		_hover = -1
		_show_hero()


func _my_hero() -> int:
	return int(Net.players.get(Net.my_id(), {}).get("hero", 0))


func _refresh() -> void:
	var mine_team := Net.my_team()
	for team in 2:
		var rows: VBoxContainer = _rows[team]
		for old in rows.get_children():
			rows.remove_child(old)
			old.queue_free()
		var shown := 0
		for id: int in Net.players:
			if Net.players[id]["team"] == team:
				rows.add_child(_player_row(id, Net.players[id], team))
				shown += 1
		for i in range(shown, Tune.TEAM_SIZE):
			rows.add_child(_player_row(0, {}, team))
		var full := Net.team_count(team) >= Tune.TEAM_SIZE
		_counts[team].text = "%d / %d" % [Net.team_count(team), Tune.TEAM_SIZE]
		_joins[team].text = "Your team" if team == mine_team else "Join"
		_joins[team].disabled = full or team == mine_team
		if team < _bot_adds.size():
			_bot_adds[team].disabled = full
	_start.visible = multiplayer.is_server()
	# Only the host can change the map; everyone sees which one is picked.
	for i in _map_buttons.size():
		_map_buttons[i].set_pressed_no_signal(i == Net.map_id)
		_map_buttons[i].disabled = not multiplayer.is_server()
	var mine := _my_hero()
	for i in _hero_buttons.size():
		_hero_buttons[i].set_pressed_no_signal(i == mine)
	_show_hero()


## One line of a team's roster; an empty Dictionary draws an open slot.
func _player_row(id: int, p: Dictionary, team: int) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 24)
	row.add_theme_constant_override("separation", 8)
	if p.is_empty():
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(24, 0)
		row.add_child(gap)
		row.add_child(Style.label("Open slot", 13, Color(Style.DIM, 0.45)))
		return row
	var hero := int(p.get("hero", 0))
	var face := Style.Portrait.new(hero, 24.0)
	face.body = Tune.team_color(team).lightened(0.2)
	row.add_child(face)
	var me := id == Net.my_id()
	var who := Style.label(p["name"], 15, Style.ACCENT.lightened(0.3) if me else Style.TEXT)
	who.custom_minimum_size = Vector2(190, 0)
	who.clip_text = true
	row.add_child(who)
	var plays := Style.label(Tune.hero_def(hero)["name"], 13, Style.DIM)
	plays.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(plays)
	var tags := PackedStringArray()
	if id == 1:
		tags.append("HOST")
	if p.get("bot", false):
		tags.append("BOT")
	if me:
		tags.append("YOU")
	row.add_child(Style.label("  ".join(tags), 11, Style.ACCENT if me else Style.DIM))
	return row


## Fills the detail panel for the hovered card, or else the hero picked.
func _show_hero() -> void:
	var index := _hover if _hover >= 0 else _my_hero()
	var d := Tune.hero_def(index)
	var accent: Color = d["accent"]
	_face.hero = index
	_face.body = Tune.team_color(Net.my_team()).lightened(0.2)
	_hero_name.text = d["name"]
	_hero_name.add_theme_color_override("font_color", accent.lightened(0.2))
	_hero_role.text = d["role"]
	# Bars compare this hero with the best of the roster in each stat.
	var mine := [d["hp"], d["dmg"] / d["atk_cd"], d["range"], d["speed"]]
	var best := [0.0, 0.0, 0.0, 0.0]
	for other: Dictionary in Tune.HEROES:
		var theirs := [other["hp"], other["dmg"] / other["atk_cd"], other["range"], other["speed"]]
		for i in best.size():
			best[i] = maxf(best[i], theirs[i])
	for i in _stat_bars.size():
		_stat_bars[i].value = mine[i] / best[i]
		_stat_bars[i].add_theme_stylebox_override("fill", Style.box(accent, Color.TRANSPARENT, 4, 0.0, 0))
		_stat_values[i].text = ("%.1f" if i >= 2 else "%d") % mine[i]
	for slot in Tune.SLOTS.size():
		var spec: Dictionary = d[Tune.SLOTS[slot]]
		_ability_names[slot].text = spec["name"]
		_ability_notes[slot].text = _ability_note(spec)


## A one-line summary of an ability at level 1, before the yell multiplier.
func _ability_note(spec: Dictionary) -> String:
	var text := ""
	match spec["type"]:
		"shot":
			text = "%s skillshot, %d damage" % ["Piercing" if spec.get("pierce", false) else "Line", spec["dmg"]]
		"volley":
			text = "Fan of %d shots, %d damage each" % [spec["count"], spec["dmg"]]
		"slam":
			text = "%d damage around you" % spec["dmg"]
		"dash":
			text = "Leap, %d damage where you land" % spec["dmg"]
		"blink":
			text = "Teleport a short distance"
		"heal":
			text = "Heals you and nearby allies for %d" % spec["amount"]
		"blast":
			text = "%d damage in an area at range" % spec["dmg"]
		"drain":
			text = "%d damage around you, heals you for %d%% of it" % [spec["dmg"], roundi(spec["leech"] * 100.0)]
		"buff":
			var gains := PackedStringArray()
			var stats: Dictionary = spec["stats"]
			for key: String in stats:
				match key:
					"speed": gains.append("+%.1f speed" % stats[key])
					"haste": gains.append("+%d%% attack speed" % roundi(stats[key] * 100.0))
					"power": gains.append("+%d%% ability power" % roundi(stats[key] * 100.0))
					"armor": gains.append("-%d%% damage taken" % roundi(stats[key] * 100.0))
			text = "%s for %ds%s" % [", ".join(gains), spec["time"], ", allies too" if spec.has("radius") else ""]
	if spec.has("level"):
		text += "  (level %d)" % spec["level"]
	return text


func _process(_delta: float) -> void:
	_mic.value = Voice.my_multiplier()
	if not SteamManager.ok:
		_mic_note.text = "Voice needs Steam running."
	elif Voice.my_db > -79.0:
		_mic_note.text = "Hearing you: damage x%.1f. Everyone in the lobby can hear you." % Voice.my_multiplier()
	else:
		_mic_note.text = "Say something. Voice is always on; shouting as a hit lands multiplies its damage up to x%.0f." % Tune.YELL_MULT_MAX
