class_name Hero
extends Unit
## Player hero. The owning player sends commands; the host executes them.
## Stats and the Q/W kit come from Tune.HEROES (picked in the lobby).

var def := {}
var cd_q := 0.0
var cd_w := 0.0
var respawn_left := 0.0

# Host-only state.
var _move_to = null
var _target: Unit = null
var _voice: AudioStreamPlayer3D


func _configure() -> void:
	def = Tune.hero_def(int(spawn_data.get("hero", 0)))
	max_hp = def["hp"]
	radius = 0.7
	bar_height = 3.3
	_build_look()
	var label := Label3D.new()
	label.text = str(Net.players.get(peer_id, {}).get("name", "Player"))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 40
	label.pixel_size = 0.012
	label.outline_size = 10
	label.position.y = 3.9
	add_child(label)


## Each hero gets a distinct silhouette: team-coloured body, accent-coloured gear.
func _build_look() -> void:
	var body_color := Tune.team_color(team)
	var accent: Color = def["accent"]
	var capsule := CapsuleMesh.new()
	var head := SphereMesh.new()
	head.radius = 0.38
	head.height = 0.76
	match def["shape"]:
		"tank":
			radius = 0.9
			capsule.radius = 0.85
			capsule.height = 2.1
			add_body(capsule, 1.05, body_color)
			add_body(head, 2.35, body_color.lightened(0.25))
			var plate := BoxMesh.new()
			plate.size = Vector3(2.3, 0.45, 1.0)
			add_body(plate, 1.75, accent)
			var fist := SphereMesh.new()
			fist.radius = 0.42
			fist.height = 0.84
			for x in [-1.15, 1.15]:
				add_body(fist, 0.95, accent).position.x = x
		"sniper":
			capsule.radius = 0.42
			capsule.height = 2.5
			add_body(capsule, 1.25, body_color)
			add_body(head, 2.75, body_color.lightened(0.25))
			var barrel := CylinderMesh.new()
			barrel.top_radius = 0.09
			barrel.bottom_radius = 0.13
			barrel.height = 2.4
			var gun := add_body(barrel, 1.7, accent)
			gun.rotation_degrees.z = 90.0
			gun.position.z = 0.5
			var hood := CylinderMesh.new()
			hood.top_radius = 0.0
			hood.bottom_radius = 0.55
			hood.height = 0.7
			add_body(hood, 3.2, accent)
		"healer":
			capsule.radius = 0.55
			capsule.height = 2.1
			add_body(capsule, 1.05, body_color)
			add_body(head, 2.4, body_color.lightened(0.25))
			var halo := TorusMesh.new()
			halo.inner_radius = 0.42
			halo.outer_radius = 0.56
			add_body(halo, 3.05, accent, 2.0)
			var robe := CylinderMesh.new()
			robe.top_radius = 0.55
			robe.bottom_radius = 0.95
			robe.height = 1.0
			add_body(robe, 0.5, accent.darkened(0.2))
		_:
			capsule.radius = 0.6
			capsule.height = 2.2
			add_body(capsule, 1.1, body_color)
			add_body(head, 2.5, body_color.lightened(0.25))
			var horn := CylinderMesh.new()
			horn.top_radius = 0.55
			horn.bottom_radius = 0.12
			horn.height = 1.0
			var megaphone := add_body(horn, 1.6, accent)
			megaphone.rotation_degrees.x = -90.0
			megaphone.position.z = -0.85
			var ring := TorusMesh.new()
			ring.inner_radius = 0.62
			ring.outer_radius = 0.78
			add_body(ring, 1.3, accent)


func _sync_props() -> Array:
	return ["net_pos", "hp", "dead", "cd_q", "cd_w", "respawn_left"]


## 3D audio source for this player's voice (created on first use).
func voice_player() -> AudioStreamPlayer3D:
	if _voice == null:
		_voice = AudioStreamPlayer3D.new()
		_voice.stream = Voice.make_stream()
		_voice.max_distance = Tune.HEAR_RANGE
		_voice.unit_size = 8.0
		_voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_voice.position.y = 1.6
		add_child(_voice)
		_voice.play()
	return _voice


# --- Commands (owner -> host) --------------------------------------------------

func _authorized() -> bool:
	if not multiplayer.is_server() or dead:
		return false
	var sender := multiplayer.get_remote_sender_id()
	return sender == peer_id or (sender == 0 and peer_id == 1)


@rpc("any_peer", "call_remote", "reliable")
func cmd_move(point: Vector3) -> void:
	if not _authorized():
		return
	_target = null
	_move_to = Tune.clamp_to_lane(point)


@rpc("any_peer", "call_remote", "reliable")
func cmd_attack(unit_name: String) -> void:
	if not _authorized():
		return
	var u = get_parent().get_node_or_null(unit_name)
	if u is Unit and u.team != team and u.targetable():
		_target = u
		_move_to = null


@rpc("any_peer", "call_remote", "reliable")
func cmd_cast(slot: int, point: Vector3) -> void:
	if not _authorized() or slot < 0 or slot > 1:
		return
	if (cd_q if slot == 0 else cd_w) > 0.0:
		return
	var spec: Dictionary = def["q"] if slot == 0 else def["w"]
	if slot == 0:
		cd_q = spec["cd"]
	else:
		cd_w = spec["cd"]
	var m := match_node()
	var to := Vector3(point.x - position.x, 0.0, point.z - position.z)
	var dir := to.normalized() if to.length() > 0.01 else Vector3(Tune.side(team), 0.0, 0.0)
	var tint := Tune.team_color(team).lightened(0.3)
	match spec["type"]:
		"shot":
			m.host_fire_shot(self, dir, spec)
		"slam":
			m.fx_slam.rpc(position, spec["radius"], tint)
			_hit_around(spec["radius"], spec["dmg"])
		"dash":
			position = Tune.clamp_to_lane(position + dir * minf(to.length(), spec["range"]))
			_move_to = null
			m.fx_slam.rpc(position, spec["radius"], tint)
			_hit_around(spec["radius"], spec["dmg"])
		"blink":
			m.fx_slam.rpc(position, 1.2, Color(1, 1, 1))
			position = Tune.clamp_to_lane(position + dir * minf(to.length(), spec["range"]))
			_move_to = null
			_target = null
			m.fx_slam.rpc(position, 1.2, Color(1, 1, 1))
		"heal":
			m.fx_slam.rpc(position, spec["radius"], Color(0.4, 1.0, 0.5))
			for u in get_parent().get_children():
				if u.kind == "hero" and u.team == team and not u.dead and flat_dist(u) <= spec["radius"]:
					m.heal(self, u, spec["amount"])


func _hit_around(hit_radius: float, dmg: float) -> void:
	var m := match_node()
	for u in get_parent().get_children():
		if u.team != team and u.targetable() and flat_dist(u) <= hit_radius + u.radius:
			m.deal_damage(self, u, dmg)


# --- Host simulation -----------------------------------------------------------

func host_tick(delta: float) -> void:
	if dead:
		respawn_left -= delta
		if respawn_left <= 0.0:
			_respawn()
		net_pos = position
		return
	hp = minf(max_hp, hp + Tune.HERO_REGEN * delta)
	cd_q = maxf(0.0, cd_q - delta)
	cd_w = maxf(0.0, cd_w - delta)
	_atk_cd = maxf(0.0, _atk_cd - delta)
	if _target != null and (not is_instance_valid(_target) or not _target.targetable()):
		_target = null
	if _target != null:
		if flat_dist(_target) <= def["range"] + _target.radius:
			if _atk_cd <= 0.0:
				_atk_cd = def["atk_cd"]
				var m := match_node()
				m.fx_beam.rpc(position, _target.position, team)
				m.deal_damage(self, _target, def["dmg"])
		else:
			step_toward(_target.position, def["speed"], delta)
	elif _move_to != null:
		if step_toward(_move_to, def["speed"], delta):
			_move_to = null
	net_pos = position


func host_die() -> void:
	dead = true
	respawn_left = Tune.HERO_RESPAWN
	_target = null
	_move_to = null


func _respawn() -> void:
	dead = false
	hp = max_hp
	position = match_node().hero_spawn_point(self)
