extends Control
## Host / join screen.

const Style := preload("res://ui/style.gd")

var _status: Label
var _lobbies: ItemList
var _lobby_ids := []
var _public: CheckBox
var _address: LineEdit
var _pending_status := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = Style.theme()
	add_child(Style.Backdrop.new())
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(880, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	var title := Style.label("YELL MOBA", 76, Style.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_constant_override("outline_size", 14)
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.12, 0.02))
	box.add_child(title)
	var sub := Style.label("The louder you yell, the harder you hit.", 18, Style.DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	# The roster, as a row of portraits under the title.
	var cast := HBoxContainer.new()
	cast.alignment = BoxContainer.ALIGNMENT_CENTER
	cast.add_theme_constant_override("separation", 10)
	box.add_child(cast)
	for i in Tune.HEROES.size():
		var face := Style.Portrait.new(i, 44.0)
		face.body = Tune.team_color(i % 2).lightened(0.2)
		cast.add_child(face)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	box.add_child(cols)

	# Left: play over Steam.
	var steam := _card(cols, "Play online")
	var host := _button(steam, "Host game", func(): Net.host_steam(_public.button_pressed))
	Style.primary(host)
	host.add_theme_font_size_override("font_size", 18)
	_public = CheckBox.new()
	_public.text = "Public lobby (otherwise friends only)"
	steam.add_child(_public)
	steam.add_child(HSeparator.new())
	steam.add_child(Style.heading("Local testing (no Steam networking)"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	steam.add_child(row)
	_button(row, "Host local", Net.host_dev)
	_address = LineEdit.new()
	_address.placeholder_text = "127.0.0.1"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_address)
	_button(row, "Join", func(): Net.join_dev(_address.text.strip_edges()))

	# Right: the public game browser.
	var browse := _card(cols, "Public games")
	_lobbies = ItemList.new()
	_lobbies.custom_minimum_size = Vector2(0, 130)
	_lobbies.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lobbies.item_activated.connect(func(i: int): Net.join_steam(_lobby_ids[i]))
	browse.add_child(_lobbies)
	_button(browse, "Refresh list", Net.request_lobbies)
	browse.add_child(Style.label("Double-click a game to join, or accept a Steam invite.", 13, Style.DIM))

	_status = Style.label("", 15, Style.DIM)
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


## A titled panel filling half the row; returns the column to add controls to.
func _card(parent: Node, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)
	col.add_child(Style.label(title, 20))
	return col


func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)
	return b
