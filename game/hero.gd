class_name Hero
extends Unit
## Player hero. The owning player sends commands; the host executes them.
## A bot's hero (negative peer_id) is ordered about by a BotBrain on the host instead.
## Stats and the Q/W kit come from Tune.HEROES (picked in the lobby).

var def := {}
var cd_q := 0.0
var cd_w := 0.0
var respawn_left := 0.0
var gold := 0
var kills := 0
var deaths := 0
var cs := 0               # minions killed
var xp := 0.0             # progress toward the next level
var level := 1:           # replicated; raises health, attack damage and ability power
	set(value):
		if value == level:
			return
		level = value
		_apply_items()
		if _tag != null:
			_tag.text = "%s  [%d]" % [_title, level]
var items: Array = []:    # indices into Tune.ITEMS; replicated, so every peer derives the stats
	set(value):
		items = value
		_apply_items()

# Stats after items (see _apply_items).
var atk_dmg := 0.0
var atk_interval := 1.0
var move_speed := 0.0
var power := 1.0          # ability damage / healing multiplier
var cdr := 0.0
var regen_bonus := 0.0
var lifesteal := 0.0

# Host-only state.
var _path := []           # waypoints still to walk
var _repath := 0.0
var _part: Node3D         # signature gear that animates on attack / cast
var _fists := []
var _punch := 0
var _calm := 0.0          # host: seconds since this hero last dealt or took damage
var _target: Unit = null
var _voice: AudioStreamPlayer3D
var _tag: Label3D         # name and level above the hero
var _title := ""
var _brain: BotBrain      # host: the AI playing this hero, when its player is a bot
var _gold_frac := 0.0   # host: passive income not yet paid out as whole gold


func _configure() -> void:
	def = Tune.hero_def(int(spawn_data.get("hero", 0)))
	gold = Tune.START_GOLD
	_apply_items()
	radius = 0.7
	mobile = true
	bar_height = 3.3
	_build_look()
	var label := Label3D.new()
	_title = str(Net.players.get(peer_id, {}).get("name", "Player"))
	label.text = "%s  [%d]" % [_title, level]
	_tag = label
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
				var f := add_body(fist, 0.95, accent)
				f.position.x = x
				_fists.append(f)
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
			gun.rotation_degrees.x = -90.0
			gun.position.x = 0.4
			gun.position.z = -0.7
			_part = gun
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
			_part = add_body(halo, 3.05, accent, 2.0)
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
			_part = megaphone
			var ring := TorusMesh.new()
			ring.inner_radius = 0.62
			ring.outer_radius = 0.78
			add_body(ring, 1.3, accent)


## Each shape moves its own gear: the Bruiser punches, the Longshot's barrel
## recoils, the Roarer's megaphone and the Chanter's halo pulse.
func _anim(anim: String) -> void:
	var cast := anim == "cast"
	if cast:
		pulse(self, "_jump", 0.7, 0.14, 0.2)
	match def["shape"]:
		"tank":
			pulse(self, "_lunge", 0.2 if cast else 0.45, 0.07, 0.16)
			if cast:
				for f in _fists:
					pulse(f, "position:y", 2.4, 0.12, 0.2)
			else:
				_punch += 1
				pulse(_fists[_punch % 2], "position:z", -1.2, 0.06, 0.16)
		"sniper":
			pulse(self, "_lunge", -0.2, 0.05, 0.2)
			pulse(_part, "position:z", -0.25, 0.04, 0.22)
		"healer":
			pulse(_part, "scale", Vector3.ONE * (1.9 if cast else 1.4), 0.12, 0.3)
			if cast:
				pulse(_part, "position:y", 3.9, 0.15, 0.3)
		_:
			pulse(_part, "scale", Vector3.ONE * (1.7 if cast else 1.35), 0.07, 0.2)
			pulse(self, "_lunge", -0.12, 0.05, 0.15)


func _sync_props() -> Array:
	return ["net_pos", "hp", "dead", "cd_q", "cd_w", "respawn_left", "gold", "items", "kills", "deaths", "cs", "xp", "level"]


# --- Items ---------------------------------------------------------------------

## Rebuilds every stat from the hero definition, the level and the items held.
func _apply_items() -> void:
	if def.is_empty():
		return
	var grown := level - 1
	var sum := {}
	for index: int in items:
		var stats: Dictionary = Tune.ITEMS[index]["stats"]
		for key: String in stats:
			sum[key] = sum.get(key, 0.0) + stats[key]
	max_hp = def["hp"] * (1.0 + Tune.LEVEL_HP * grown) + sum.get("hp", 0.0)
	atk_dmg = def["dmg"] * (1.0 + Tune.LEVEL_DMG * grown) + sum.get("dmg", 0.0)
	atk_interval = def["atk_cd"] / (1.0 + sum.get("haste", 0.0))
	move_speed = def["speed"] + sum.get("speed", 0.0)
	power = 1.0 + Tune.LEVEL_POWER * grown + sum.get("power", 0.0)
	cdr = minf(Tune.CDR_MAX, sum.get("cdr", 0.0))
	regen_bonus = sum.get("regen", 0.0)
	lifesteal = sum.get("lifesteal", 0.0)


## Full cooldown of Q (slot 0) or W (slot 1) after cooldown reduction.
func cooldown(slot: int) -> float:
	return def["q" if slot == 0 else "w"]["cd"] * (1.0 - cdr)


## The shop is open at the team fountain and while waiting to respawn.
func can_shop() -> bool:
	if dead:
		return true
	var fountain: Vector3 = Tune.map()["spawns"][team]
	return Vector2(position.x - fountain.x, position.z - fountain.z).length() <= Tune.FOUNTAIN_RADIUS


## Host: grant experience, levelling up as many times as it covers. Each level
## also restores the health it adds.
func add_xp(amount: float) -> void:
	if level >= Tune.MAX_LEVEL:
		return
	xp += amount
	while level < Tune.MAX_LEVEL and xp >= Tune.xp_needed(level):
		xp -= Tune.xp_needed(level)
		var before := max_hp
		level += 1
		if not dead:
			hp += max_hp - before
		match_node().fx_level.rpc(position, level)
	if level >= Tune.MAX_LEVEL:
		xp = 0.0


## Host: pay this hero, with a floating "+N" only its player sees.
func earn(amount: int) -> void:
	gold += amount
	if peer_id > 0:  # bots have no screen to show it on
		match_node().fx_gold.rpc_id(peer_id, position, amount)


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

func _from_owner() -> bool:
	if not multiplayer.is_server():
		return false
	var sender := multiplayer.get_remote_sender_id()
	return sender == peer_id or (sender == 0 and peer_id == 1)


func _authorized() -> bool:
	return _from_owner() and not dead


@rpc("any_peer", "call_remote", "reliable")
func cmd_buy(index: int) -> void:
	if _from_owner():
		host_buy(index)


func host_buy(index: int) -> void:
	if index < 0 or index >= Tune.ITEMS.size():
		return
	var cost: int = Tune.ITEMS[index]["cost"]
	if not can_shop() or gold < cost or items.size() >= Tune.ITEM_SLOTS:
		return
	gold -= cost
	var before := max_hp
	items = items + [index]
	if not dead:
		hp += maxf(0.0, max_hp - before)


@rpc("any_peer", "call_remote", "reliable")
func cmd_sell(slot: int) -> void:
	if not _from_owner() or slot < 0 or slot >= items.size() or not can_shop():
		return
	gold += int(Tune.ITEMS[items[slot]]["cost"] * Tune.SELL_REFUND)
	var left := items.duplicate()
	left.remove_at(slot)
	items = left
	hp = minf(hp, max_hp)


@rpc("any_peer", "call_remote", "reliable")
func cmd_move(point: Vector3) -> void:
	if _authorized():
		host_move(point)


@rpc("any_peer", "call_remote", "reliable")
func cmd_attack(unit_name: String) -> void:
	if _authorized():
		host_attack(get_parent().get_node_or_null(unit_name))


@rpc("any_peer", "call_remote", "reliable")
func cmd_cast(slot: int, point: Vector3) -> void:
	if _authorized():
		host_cast(slot, point)


# --- Orders (host side; reached through the commands above, or directly by a bot) ---

func host_move(point: Vector3) -> void:
	_target = null
	_path = Tune.route(position, free_point(Tune.clamp_to_map(point)))


func host_attack(u: Node) -> void:
	if u is Unit and u.team != team and u.targetable() and u != _target:
		_target = u
		_path = []


## Nothing left to do: not walking anywhere and not attacking anything.
func idle() -> bool:
	return _path.is_empty() and _target == null


func host_cast(slot: int, point: Vector3) -> void:
	if dead or slot < 0 or slot > 1:
		return
	if (cd_q if slot == 0 else cd_w) > 0.0:
		return
	var spec: Dictionary = def["q"] if slot == 0 else def["w"]
	if slot == 0:
		cd_q = cooldown(0)
	else:
		cd_w = cooldown(1)
	var m := match_node()
	var to := Vector3(point.x - position.x, 0.0, point.z - position.z)
	var dir := to.normalized() if to.length() > 0.01 else Tune.forward(team)
	var tint := Tune.team_color(team).lightened(0.3)
	play_anim.rpc("cast", position + dir)
	match spec["type"]:
		"shot":
			m.host_fire_shot(self, dir, spec)
		"slam":
			m.fx_slam.rpc(position, spec["radius"], tint)
			_hit_around(spec["radius"], spec["dmg"] * power)
		"dash":
			position = Tune.clamp_to_map(free_point(Tune.clamp_to_map(position + dir * minf(to.length(), spec["range"]))))
			_path = []
			m.fx_slam.rpc(position, spec["radius"], tint)
			_hit_around(spec["radius"], spec["dmg"] * power)
		"blink":
			m.fx_slam.rpc(position, 1.2, Color(1, 1, 1))
			position = Tune.clamp_to_map(free_point(Tune.clamp_to_map(position + dir * minf(to.length(), spec["range"]))))
			_path = []
			_target = null
			m.fx_slam.rpc(position, 1.2, Color(1, 1, 1))
		"heal":
			m.fx_slam.rpc(position, spec["radius"], Color(0.4, 1.0, 0.5))
			for u in get_parent().get_children():
				if u.kind == "hero" and u.team == team and not u.dead and flat_dist(u) <= spec["radius"]:
					m.heal(self, u, spec["amount"] * power)


func _hit_around(hit_radius: float, dmg: float) -> void:
	var m := match_node()
	for u in get_parent().get_children():
		if u.team != team and u.targetable() and flat_dist(u) <= hit_radius + u.radius:
			m.deal_damage(self, u, dmg)


# --- Host simulation -----------------------------------------------------------

func host_tick(delta: float) -> void:
	_gold_frac += Tune.GOLD_PER_SEC * delta
	if _gold_frac >= 1.0:
		gold += int(_gold_frac)
		_gold_frac -= int(_gold_frac)
	if peer_id < 0:
		if _brain == null:
			_brain = BotBrain.new()
		_brain.tick(self, delta)
	if dead:
		respawn_left -= delta
		if respawn_left <= 0.0:
			_respawn()
		net_pos = position
		return
	_regenerate(delta)
	cd_q = maxf(0.0, cd_q - delta)
	cd_w = maxf(0.0, cd_w - delta)
	_atk_cd = maxf(0.0, _atk_cd - delta)
	if _target != null and (not is_instance_valid(_target) or not _target.targetable()):
		_target = null
	if _target != null:
		if flat_dist(_target) <= def["range"] + _target.radius:
			if _atk_cd <= 0.0:
				_atk_cd = atk_interval
				var m := match_node()
				play_anim.rpc("attack", _target.position)
				m.fx_beam.rpc(position, _target.position, team)
				var dealt: float = m.deal_damage(self, _target, atk_dmg)
				if lifesteal > 0.0 and not dead:
					hp = minf(max_hp, hp + dealt * lifesteal)
		else:
			# Chase, re-planning the way around walls a few times a second.
			_repath -= delta
			if _repath <= 0.0 or _path.is_empty():
				_repath = 0.25
				_path = Tune.route(position, _target.position)
			if step_toward(_path[0], move_speed, delta):
				_path.pop_front()
	elif not _path.is_empty():
		if step_toward(_path[0], move_speed, delta):
			_path.pop_front()
	net_pos = position


func host_die() -> void:
	dead = true
	deaths += 1
	respawn_left = Tune.HERO_RESPAWN + Tune.RESPAWN_PER_LEVEL * (level - 1)
	_target = null
	_path = []


func _respawn() -> void:
	dead = false
	_calm = Tune.CALM_AFTER
	hp = max_hp
	position = match_node().hero_spawn_point(self)


## Called by the match whenever this hero deals or takes damage.
func note_combat() -> void:
	_calm = 0.0


## A trickle at all times, a faster recovery once out of combat for a while,
## and a rapid top-up when resting at the team's fountain (spawn point).
func _regenerate(delta: float) -> void:
	_calm += delta
	var rate := Tune.HERO_REGEN + regen_bonus
	if _calm >= Tune.CALM_AFTER:
		rate += max_hp * Tune.CALM_REGEN
		var fountain: Vector3 = Tune.map()["spawns"][team]
		if Vector2(position.x - fountain.x, position.z - fountain.z).length() <= Tune.FOUNTAIN_RADIUS:
			rate += max_hp * Tune.FOUNTAIN_REGEN
	hp = minf(max_hp, hp + rate * delta)
