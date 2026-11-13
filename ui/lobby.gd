extends Control
## Pre-match lobby: roster, team pick, mic check, start.

var _teams := []      # two Labels
var _mic: ProgressBar
var _mic_note: Label
var _start: Button
var _hero_buttons := []
var _map_buttons := []
var _hero_note: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "Lobby" + ("  (local test)" if Net.dev_mode else "")
	title.add_theme_font_size_override("font_size", 36)
	box.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	box.add_child(cols)
	for team in 2:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cols.add_child(col)
		var join := Button.new()
		join.text = "Join %s" % Tune.team_name(team)
		join.modulate = Tune.team_color(team).lightened(0.4)
		join.pressed.connect(Net.choose_team.bind(team))
		col.add_child(join)
		var list := Label.new()
		list.custom_minimum_size = Vector2(0, 150)
		col.add_child(list)
		_teams.append(list)

	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 8)
	box.add_child(map_row)
	var map_label := Label.new()
	map_label.text = "Map  "
	map_row.add_child(map_label)
	for i in Tune.maps.size():
		var pick := Button.new()
		pick.text = Tune.maps[i]["name"]
		pick.toggle_mode = true
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.pressed.connect(Net.choose_map.bind(i))
		map_row.add_child(pick)
		_map_buttons.append(pick)

	var hero_row := HBoxContainer.new()
	hero_row.add_theme_constant_override("separation", 8)
	box.add_child(hero_row)
	for i in Tune.HEROES.size():
		var pick := Button.new()
		pick.text = Tune.HEROES[i]["name"]
		pick.toggle_mode = true
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.pressed.connect(Net.choose_hero.bind(i))
		hero_row.add_child(pick)
		_hero_buttons.append(pick)
	_hero_note = Label.new()
	_hero_note.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_hero_note)

	var mic_row := HBoxContainer.new()
	box.add_child(mic_row)
	var mic_label := Label.new()
	mic_label.text = "Mic check  "
	mic_row.add_child(mic_label)
	_mic = ProgressBar.new()
	_mic.min_value = 1.0
	_mic.max_value = Tune.YELL_MULT_MAX
	_mic.step = 0.01
	_mic.show_percentage = false
	_mic.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mic.custom_minimum_size = Vector2(0, 22)
	mic_row.add_child(_mic)
	_mic_note = Label.new()
	_mic_note.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_mic_note)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	_start = Button.new()
	_start.text = "Start match"
	_start.pressed.connect(Net.start_match)
	buttons.add_child(_start)
	if Net.lobby_id != 0:
		var invite := Button.new()
		invite.text = "Invite friends"
		invite.pressed.connect(Net.invite_friends)
		buttons.add_child(invite)
	var leave := Button.new()
	leave.text = "Leave"
	leave.pressed.connect(Net.quit_session)
	buttons.add_child(leave)

	Net.roster_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var names := ["", ""]
	for id in Net.players:
		var p: Dictionary = Net.players[id]
		names[p["team"]] += "%s - %s%s%s\n" % [p["name"], Tune.hero_def(p.get("hero", 0))["name"], "  (host)" if id == 1 else "", "  <- you" if id == Net.my_id() else ""]
	for team in 2:
		_teams[team].text = names[team]
	_start.visible = multiplayer.is_server()
	# Only the host can change the map; everyone sees which one is picked.
	for i in _map_buttons.size():
		_map_buttons[i].set_pressed_no_signal(i == Net.map_id)
		_map_buttons[i].disabled = not multiplayer.is_server()
	var mine := int(Net.players.get(Net.my_id(), {}).get("hero", 0))
	for i in _hero_buttons.size():
		_hero_buttons[i].set_pressed_no_signal(i == mine)
	var d := Tune.hero_def(mine)
	_hero_note.text = "%s: %s.  HP %d, range %.1f.  Q %s, W %s." % [d["name"], d["role"], d["hp"], d["range"], d["q"]["name"], d["w"]["name"]]


func _process(_delta: float) -> void:
	_mic.value = Voice.my_multiplier()
	if not SteamManager.ok:
		_mic_note.text = "Voice needs Steam running."
	elif Voice.my_db > -79.0:
		_mic_note.text = "Hearing you: damage x%.1f. Everyone in the lobby can hear you." % Voice.my_multiplier()
	else:
		_mic_note.text = "Say something. Voice is always on; shouting as a hit lands multiplies its damage up to x%.0f." % Tune.YELL_MULT_MAX
