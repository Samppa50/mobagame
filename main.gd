extends Node
## Root scene: swaps between main menu, lobby and match.

const MainMenu := preload("res://ui/main_menu.gd")
const Lobby := preload("res://ui/lobby.gd")
const Match := preload("res://game/match.gd")

var screen: Node = null


func _ready() -> void:
	Net.session_started.connect(func(): _show(Lobby.new()))
	Net.session_ended.connect(_on_session_ended)
	Net.match_starting.connect(_on_match_starting)
	Net.returned_to_lobby.connect(func(): _show(Lobby.new()))
	_show(MainMenu.new())
	_handle_args()


func _show(node: Node) -> void:
	if screen != null:
		remove_child(screen)
		screen.queue_free()
	screen = node
	add_child(screen)


func _on_session_ended(reason: String) -> void:
	var menu := MainMenu.new()
	_show(menu)
	menu.set_status(reason)
	if Net.selftest:
		print("SELFTEST client: session ended (%s)" % reason)
		get_tree().quit()


func _on_match_starting() -> void:
	_show(Match.new())
	Net.report_ready()


## Dev flags, passed after "--":  --dev-host  --dev-join  --autostart=N  --selftest  --hero=N  --map=N
## Steam passes "+connect_lobby <id>" when the game is launched from an invite.
func _handle_args() -> void:
	var user := OS.get_cmdline_user_args()
	for arg in user:
		if arg == "--selftest":
			Net.selftest = true
		elif arg.begins_with("--autostart="):
			Net.autostart = int(arg.get_slice("=", 1))
	if "--dev-host" in user:
		Net.host_dev()
	elif "--dev-join" in user:
		Net.join_dev("127.0.0.1")
	for arg in user:
		if arg.begins_with("--hero=") and Net.online():
			Net.choose_hero(int(arg.get_slice("=", 1)))
		elif arg.begins_with("--map=") and Net.online():
			Net.choose_map(int(arg.get_slice("=", 1)))
	var all := OS.get_cmdline_args()
	var i := all.find("+connect_lobby")
	if i != -1 and i + 1 < all.size():
		Net.join_steam(int(all[i + 1]))
	if "--steam-host" in user:
		Net.host_steam(false)
	if "--diag" in user:
		Net.status.connect(func(text: String): print("DIAG status: ", text))
		var timer := Timer.new()
		timer.wait_time = 1.0
		timer.autostart = true
		timer.timeout.connect(func(): print("DIAG steam=%s online=%s lobby=%s players=%d voice_result=%d my_db=%.1f" % [
			SteamManager.ok, Net.online(), Net.lobby_id != 0, Net.players.size(), Voice.last_result, Voice.my_db]))
		add_child(timer)
