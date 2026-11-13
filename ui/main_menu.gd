extends Control
## Host / join screen.

var _status: Label
var _lobbies: ItemList
var _lobby_ids := []
var _public: CheckBox
var _address: LineEdit
var _pending_status := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "YELL MOBA"
	title.add_theme_font_size_override("font_size", 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = "The louder you yell, the harder you hit."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	box.add_child(HSeparator.new())

	_public = CheckBox.new()
	_public.text = "Public lobby (otherwise friends only)"
	box.add_child(_public)
	_button(box, "Host game (Steam)", func(): Net.host_steam(_public.button_pressed))
	_button(box, "Find public games", Net.request_lobbies)
	_lobbies = ItemList.new()
	_lobbies.custom_minimum_size = Vector2(0, 120)
	_lobbies.item_activated.connect(func(i: int): Net.join_steam(_lobby_ids[i]))
	box.add_child(_lobbies)
	var hint := Label.new()
	hint.text = "Double-click a game to join, or accept a Steam invite."
	hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(hint)
	box.add_child(HSeparator.new())

	var dev := Label.new()
	dev.text = "Local testing (no Steam networking)"
	dev.modulate = Color(1, 1, 1, 0.6)
	box.add_child(dev)
	var row := HBoxContainer.new()
	box.add_child(row)
	_button(row, "Host local", Net.host_dev)
	_address = LineEdit.new()
	_address.placeholder_text = "127.0.0.1"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_address)
	_button(row, "Join", func(): Net.join_dev(_address.text.strip_edges()))

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)
	if _pending_status != "":
		_status.text = _pending_status
	elif not SteamManager.ok:
		_status.text = "Steam is not available (%s). Only local testing will work." % SteamManager.error
	else:
		_status.text = "Signed in as %s" % SteamManager.persona
	Net.status.connect(set_status)
	Net.lobby_list.connect(_on_lobby_list)


func set_status(text: String) -> void:
	_pending_status = text
	if _status != null and text != "":
		_status.text = text


func _on_lobby_list(lobbies: Array) -> void:
	_lobbies.clear()
	_lobby_ids.clear()
	for l in lobbies:
		_lobbies.add_item("%s  (%d/%d)" % [l["name"], l["count"], Tune.MAX_PLAYERS])
		_lobby_ids.append(l["id"])
	set_status("No public games found." if lobbies.is_empty() else "Found %d game(s)." % lobbies.size())


func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)
	return b
