extends Node
## Session layer. One player hosts and is the authority (peer 1).
## Transport is either a Steam lobby + SteamMultiplayerPeer, or ENet on
## localhost for testing two instances on one PC.

signal roster_changed
signal status(text: String)
signal session_started          # we are now in a lobby (host or client)
signal session_ended(reason: String)
signal match_starting
signal all_ready
signal returned_to_lobby
signal lobby_list(lobbies: Array)

# Steam enum values (ints so a renamed constant can't break parsing).
const LOBBY_TYPE_FRIENDS_ONLY := 1
const LOBBY_TYPE_PUBLIC := 2
const LOBBY_COMPARISON_EQUAL := 0
const LOBBY_DISTANCE_WORLDWIDE := 3
const CHAT_ROOM_ENTER_SUCCESS := 1

var players := {}        # peer_id -> { "name": String, "team": int, "ready": bool }
var dev_mode := false    # ENet localhost session
var selftest := false
var autostart := 0       # host auto-starts once this many players are present
var lobby_id := 0
var in_match := false
var map_id := 0           # index into Tune.maps, chosen by the host in the lobby
var match_node: Node = null
var _joining_steam := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _end("Could not connect to host."))
	multiplayer.server_disconnected.connect(func(): _end("Host left the game."))
	if SteamManager.ok:
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
		Steam.join_requested.connect(func(lobby: int, _friend: int): join_steam(lobby))


func online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func my_id() -> int:
	return multiplayer.get_unique_id()


func my_team() -> int:
	return int(players.get(my_id(), {}).get("team", 0))


func local_name() -> String:
	return SteamManager.persona


# --- Hosting / joining -------------------------------------------------------

func host_dev() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(Tune.DEV_PORT, Tune.MAX_PLAYERS - 1)
	if err != OK:
		status.emit("Could not open port %d (error %d)." % [Tune.DEV_PORT, err])
		return
	dev_mode = true
	_become_host(peer)


func join_dev(address: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address if address != "" else "127.0.0.1", Tune.DEV_PORT)
	if err != OK:
		status.emit("Could not start client (error %d)." % err)
		return
	dev_mode = true
	multiplayer.multiplayer_peer = peer
	status.emit("Connecting...")


func host_steam(public: bool) -> void:
	if not SteamManager.ok:
		status.emit("Steam is not available: %s" % SteamManager.error)
		return
	status.emit("Creating Steam lobby...")
	Steam.createLobby(LOBBY_TYPE_PUBLIC if public else LOBBY_TYPE_FRIENDS_ONLY, Tune.MAX_PLAYERS)


func join_steam(lobby: int) -> void:
	if not SteamManager.ok:
		status.emit("Steam is not available: %s" % SteamManager.error)
		return
	if online():
		leave()
	_joining_steam = true
	status.emit("Joining Steam lobby...")
	Steam.joinLobby(lobby)


func request_lobbies() -> void:
	if not SteamManager.ok:
		status.emit("Steam is not available: %s" % SteamManager.error)
		return
	Steam.addRequestLobbyListStringFilter("game", Tune.LOBBY_TAG, LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListDistanceFilter(LOBBY_DISTANCE_WORLDWIDE)
	Steam.requestLobbyList()


func invite_friends() -> void:
	if lobby_id != 0:
		Steam.activateGameOverlayInviteDialog(lobby_id)


func leave() -> void:
	if lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	lobby_id = 0
	_joining_steam = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	in_match = false
	dev_mode = false


func quit_session() -> void:
	_end("")


func _end(reason: String) -> void:
	leave()
	session_ended.emit(reason)


func _become_host(peer: MultiplayerPeer) -> void:
	multiplayer.multiplayer_peer = peer
	players = {1: {"name": local_name(), "team": 0, "hero": 0, "ready": false}}
	in_match = false
	session_started.emit()
	roster_changed.emit()
	if autostart == 1:
		start_match.call_deferred()


func _on_lobby_created(result: int, new_lobby: int) -> void:
	if result != 1:
		status.emit("Steam lobby creation failed (code %d)." % result)
		return
	lobby_id = new_lobby
	Steam.setLobbyData(lobby_id, "game", Tune.LOBBY_TAG)
	Steam.setLobbyData(lobby_id, "name", "%s's game" % local_name())
	var peer = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.host_with_lobby(lobby_id)
	if err != OK:
		status.emit("Could not host on Steam lobby (error %d)." % err)
		Steam.leaveLobby(lobby_id)
		lobby_id = 0
		return
	_become_host(peer)


func _on_lobby_joined(lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if not _joining_steam:
		return  # this also fires for the host's own lobby
	_joining_steam = false
	if response != CHAT_ROOM_ENTER_SUCCESS:
		status.emit("Could not join lobby (code %d)." % response)
		return
	lobby_id = lobby
	var peer = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.connect_to_lobby(lobby)
	if err != OK:
		status.emit("Could not connect to host (error %d)." % err)
		Steam.leaveLobby(lobby)
		lobby_id = 0
		return
	multiplayer.multiplayer_peer = peer
	status.emit("Connecting to host...")


func _on_lobby_match_list(lobbies: Array) -> void:
	var out := []
	for id in lobbies:
		out.append({
			"id": id,
			"name": Steam.getLobbyData(id, "name"),
			"count": Steam.getNumLobbyMembers(id),
		})
	lobby_list.emit(out)


# --- Roster ------------------------------------------------------------------

func _on_connected() -> void:
	register.rpc_id(1, local_name())


func _on_peer_connected(_id: int) -> void:
	pass  # clients announce themselves with register()


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server() or not players.has(id):
		return
	players.erase(id)
	set_roster.rpc(players)
	if in_match and is_instance_valid(match_node):
		match_node.host_remove_player(id)
	_check_all_ready()


@rpc("any_peer", "call_remote", "reliable")
func register(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if in_match or players.size() >= Tune.MAX_PLAYERS:
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	var counts := [0, 0]
	for p in players.values():
		counts[p["team"]] += 1
	var clean := player_name.strip_edges().left(24)
	if clean == "":
		clean = "Player"
	if dev_mode:
		clean = "%s #%d" % [clean, players.size() + 1]
	players[id] = {"name": clean, "team": 0 if counts[0] <= counts[1] else 1, "hero": 0, "ready": false}
	set_map.rpc_id(id, map_id)
	set_roster.rpc(players)
	if autostart > 0 and players.size() >= autostart:
		start_match()


@rpc("any_peer", "call_remote", "reliable")
func request_team(team: int) -> void:
	if not multiplayer.is_server() or in_match:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	if players.has(id) and (team == 0 or team == 1):
		players[id]["team"] = team
		set_roster.rpc(players)


func choose_team(team: int) -> void:
	if multiplayer.is_server():
		request_team(team)
	else:
		request_team.rpc_id(1, team)


@rpc("any_peer", "call_remote", "reliable")
func request_hero(index: int) -> void:
	if not multiplayer.is_server() or in_match:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	if players.has(id) and index >= 0 and index < Tune.HEROES.size():
		players[id]["hero"] = index
		set_roster.rpc(players)


func choose_hero(index: int) -> void:
	if multiplayer.is_server():
		request_hero(index)
	else:
		request_hero.rpc_id(1, index)


## Host only: pick the map for the next match.
func choose_map(index: int) -> void:
	if multiplayer.is_server() and not in_match and index >= 0 and index < Tune.maps.size():
		set_map.rpc(index)


@rpc("authority", "call_local", "reliable")
func set_map(index: int) -> void:
	map_id = clampi(index, 0, Tune.maps.size() - 1)
	roster_changed.emit()


@rpc("authority", "call_local", "reliable")
func set_roster(new_players: Dictionary) -> void:
	var first := players.is_empty()
	players = new_players
	if first and not multiplayer.is_server():
		session_started.emit()
	roster_changed.emit()


# --- Match flow --------------------------------------------------------------

func start_match() -> void:
	if not multiplayer.is_server() or in_match:
		return
	for p in players.values():
		p["ready"] = false
	if lobby_id != 0:
		Steam.setLobbyJoinable(lobby_id, false)
	multiplayer.multiplayer_peer.refuse_new_connections = true
	begin_match.rpc(map_id)
	# Don't wait forever for a client that never reports ready.
	get_tree().create_timer(5.0).timeout.connect(func():
		if in_match:
			for p in players.values():
				p["ready"] = true
			_check_all_ready())


@rpc("authority", "call_local", "reliable")
func begin_match(map: int) -> void:
	map_id = clampi(map, 0, Tune.maps.size() - 1)
	Tune.map_index = map_id
	in_match = true
	match_starting.emit()


## Called by Main once the local Match scene exists.
func report_ready() -> void:
	if multiplayer.is_server():
		_mark_ready(1)
	else:
		client_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func client_ready() -> void:
	if multiplayer.is_server():
		_mark_ready(multiplayer.get_remote_sender_id())


func _mark_ready(id: int) -> void:
	if players.has(id):
		players[id]["ready"] = true
	_check_all_ready()


var _ready_fired := false

func _check_all_ready() -> void:
	if not in_match or _ready_fired:
		return
	for p in players.values():
		if not p["ready"]:
			return
	_ready_fired = true
	all_ready.emit()


func end_match() -> void:
	if multiplayer.is_server():
		return_to_lobby.rpc()


@rpc("authority", "call_local", "reliable")
func return_to_lobby() -> void:
	in_match = false
	_ready_fired = false
	if multiplayer.is_server():
		multiplayer.multiplayer_peer.refuse_new_connections = false
		if lobby_id != 0:
			Steam.setLobbyJoinable(lobby_id, true)
	returned_to_lobby.emit()
