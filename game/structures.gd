## Minion, Monster, Tower and Core live in one file as inner classes of this script.
## (Kept together because each is only a few lines of host AI.)
class_name Structures
extends RefCounted


class Minion extends Unit:
	var _route := []           # lane waypoints still ahead; the last is the enemy core
	var _offset := Vector3.ZERO  # sideways place in the wave's formation
	var _path := []
	var _repath := 0.0

	func _configure() -> void:
		max_hp = Tune.MINION_HP
		radius = 0.45
		mobile = true
		hop = 0.3
		_plan_route()
		bar_height = 1.7
		var color := Tune.team_color(team).darkened(0.2)
		var box := BoxMesh.new()
		box.size = Vector3(0.7, 0.75, 0.7)
		add_body(box, 0.4, color)
		var head := SphereMesh.new()
		head.radius = 0.28
		head.height = 0.56
		add_body(head, 1.0, color.lightened(0.3))
		var spike := CylinderMesh.new()
		spike.top_radius = 0.0
		spike.bottom_radius = 0.14
		spike.height = 0.4
		add_body(spike, 1.42, Color(0.85, 0.85, 0.8))

	## The rest of this minion's lane from where it stands, then the enemy core.
	func _plan_route() -> void:
		var m := Tune.map()
		if lane < 0:
			lane = Tune.nearest_lane(position)
		var pts: Array = m["lanes"][lane].duplicate()
		if team == 1:
			pts.reverse()
		var first := 1
		for i in range(1, pts.size()):
			if Tune.path_dist(position, [pts[i - 1], pts[i]]) < Tune.path_dist(position, [pts[first - 1], pts[first]]):
				first = i
		_route = pts.slice(first)
		_route.append(m["cores"][1 - team])
		_offset = spawn_data.get("off", Vector3.ZERO)

	func host_tick(delta: float) -> void:
		_atk_cd = maxf(0.0, _atk_cd - delta)
		var foe := nearest_enemy(Tune.MINION_AGGRO)
		if foe != null:
			_repath = 0.0
			if flat_dist(foe) <= Tune.MINION_RANGE + foe.radius:
				if _atk_cd <= 0.0:
					_atk_cd = Tune.MINION_CD
					play_anim.rpc("attack", foe.position)
					match_node().deal_damage(self, foe, Tune.MINION_DMG)
			else:
				step_toward(foe.position, Tune.MINION_SPEED, delta)
		else:
			_march(delta)
		net_pos = position

	## March down the lane, waypoint by waypoint, then close in on the core.
	func _march(delta: float) -> void:
		var last := _route.size() == 1
		var goal: Vector3 = _route[0] if last else Tune.clamp_to_map(_route[0] + _offset)
		var left := Vector2(goal.x - position.x, goal.z - position.z).length()
		if last:
			if left <= 3.4:
				return
		elif left <= 1.5:
			_route.pop_front()
			_repath = 0.0
			return
		# Usually a straight walk; after chasing someone off the lane this
		# finds the way back around the trees.
		_repath -= delta
		if _repath <= 0.0 or _path.is_empty():
			_repath = 0.5
			_path = Tune.route(position, goal)
		if step_toward(_path[0], Tune.MINION_SPEED, delta) and _path.size() > 1:
			_path.pop_front()


## Neutral jungle monster: idle at its camp until a hero provokes it.
class Monster extends Unit:
	var spec := {}
	var _home := Vector3.ZERO
	var _foe: Unit = null

	func _configure() -> void:
		spec = Tune.MONSTERS[spawn_data.get("size", "small")]
		var s: float = spec["scale"]
		max_hp = spec["hp"]
		radius = 0.75 * s
		mobile = true
		hop = 0.25
		bar_height = 2.3 * s
		_home = position
		var hide := Color(0.5, 0.36, 0.62) if s > 1.2 else Color(0.42, 0.5, 0.3)
		var body := SphereMesh.new()
		body.radius = 0.8 * s
		body.height = 1.5 * s
		add_body(body, 0.75 * s, hide)
		var head := SphereMesh.new()
		head.radius = 0.45 * s
		head.height = 0.8 * s
		add_body(head, 1.5 * s, hide.lightened(0.15)).position.z = -0.35 * s
		var horn := CylinderMesh.new()
		horn.top_radius = 0.0
		horn.bottom_radius = 0.13 * s
		horn.height = 0.6 * s
		var eye := SphereMesh.new()
		eye.radius = 0.09 * s
		eye.height = 0.18 * s
		for x in [-1.0, 1.0]:
			var h := add_body(horn, 2.0 * s, Color(0.9, 0.87, 0.75))
			h.position.x = x * 0.3 * s
			h.position.z = -0.3 * s
			h.rotation_degrees.z = -x * 25.0
			var e := add_body(eye, 1.58 * s, Tune.team_color(team), 2.5)
			e.position.x = x * 0.18 * s
			e.position.z = -0.75 * s

	## Called by the match when a hero damages this monster.
	func provoke(by: Unit) -> void:
		if _foe == null or not is_instance_valid(_foe):
			_foe = by

	func host_tick(delta: float) -> void:
		_atk_cd = maxf(0.0, _atk_cd - delta)
		if _foe != null and (not is_instance_valid(_foe) or not _foe.targetable() \
				or Vector2(_foe.position.x - _home.x, _foe.position.z - _home.z).length() > Tune.MONSTER_LEASH):
			_foe = null
		if _foe == null:
			# Given up (or never bothered): walk home and recover.
			hp = minf(max_hp, hp + max_hp * Tune.MONSTER_REGEN * delta)
			if position.distance_to(_home) > 0.05:
				step_toward(Tune.route(position, _home)[0], Tune.MONSTER_SPEED, delta)
		elif flat_dist(_foe) <= Tune.MONSTER_RANGE + radius + _foe.radius:
			if _atk_cd <= 0.0:
				_atk_cd = spec["cd"]
				play_anim.rpc("attack", _foe.position)
				match_node().deal_damage(self, _foe, spec["dmg"])
		else:
			step_toward(Tune.route(position, _foe.position)[0], Tune.MONSTER_SPEED, delta)
		net_pos = position


class Tower extends Unit:
	var aim := ""              # replicated: name of the unit the beam is on ("" = idle)
	var heat := 0.0            # replicated: 0..1, how far the beam has ramped up
	var _crystal: MeshInstance3D
	var _beam: MeshInstance3D
	var _beam_mat: StandardMaterial3D
	var _foe: Unit = null      # host: current beam target
	var _held := 0.0           # host: seconds the beam has been on it
	var _tick := 0.0

	func _process(delta: float) -> void:
		super(delta)
		_crystal.rotation.y += delta * (0.9 + heat * 6.0)
		_draw_beam()

	## The beam is drawn on every peer from the replicated aim and heat: it
	## thickens and turns from the team colour to white-hot as it ramps up.
	func _draw_beam() -> void:
		var target: Unit = (get_parent().get_node_or_null(aim) as Unit) if aim != "" else null
		if target == null or dead or target.dead or target.fogged:
			if _beam != null:
				_beam.visible = false
			return
		if _beam == null:
			_beam_mat = StandardMaterial3D.new()
			_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_beam = MeshInstance3D.new()
			_beam.mesh = BoxMesh.new()
			_beam.material_override = _beam_mat
			_beam.top_level = true
			_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(_beam)
		var from := position + Vector3(0, 6.2, 0)
		var to := target.position + Vector3(0, 1.0, 0)
		var width := lerpf(0.1, 0.45, heat) * (1.0 + 0.15 * sin(Time.get_ticks_msec() / 40.0))
		var color := Tune.team_color(team).lightened(0.3).lerp(Color(1.0, 0.95, 0.8), heat)
		_beam_mat.albedo_color = Color(color.r, color.g, color.b, 0.9)
		_beam.visible = true
		_beam.look_at_from_position((from + to) * 0.5, to)
		_beam.scale = Vector3(width, width, from.distance_to(to))

	## An inner tower cannot be hit while a tower further out in its lane stands.
	func targetable() -> bool:
		if dead:
			return false
		for u in get_parent().get_children():
			if u.kind == "tower" and u.team == team and u.lane == lane and u.tier < tier and not u.dead:
				return false
		return true

	func _configure() -> void:
		max_hp = Tune.TOWER_HP
		radius = 1.3
		solid = true
		bar_height = 7.6
		var color := Tune.team_color(team)
		var stone := Color(0.5, 0.5, 0.54)
		var foot := CylinderMesh.new()
		foot.top_radius = 1.3
		foot.bottom_radius = 1.6
		foot.height = 1.0
		add_body(foot, 0.5, stone.darkened(0.15))
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.8
		shaft.bottom_radius = 1.1
		shaft.height = 3.6
		add_body(shaft, 2.8, stone)
		var band := TorusMesh.new()
		band.inner_radius = 0.85
		band.outer_radius = 1.15
		add_body(band, 2.2, color)
		var top := CylinderMesh.new()
		top.top_radius = 1.25
		top.bottom_radius = 0.9
		top.height = 0.6
		add_body(top, 4.9, stone.darkened(0.1))
		var crystal := SphereMesh.new()
		crystal.radius = 0.6
		crystal.height = 1.7
		crystal.radial_segments = 6
		crystal.rings = 2
		_crystal = add_body(crystal, 6.2, color.lightened(0.2), 2.5)
		var lamp := OmniLight3D.new()
		lamp.light_color = color
		lamp.light_energy = 2.5
		lamp.omni_range = 10.0
		lamp.position.y = 6.2
		add_child(lamp)

	## Keeps the beam on its target for as long as that target stays in range,
	## hitting harder the longer it has been held. A new target (minions before
	## heroes) is only picked once the old one is gone, and starts cold.
	func host_tick(delta: float) -> void:
		if _foe != null and (not is_instance_valid(_foe) or not _foe.targetable() \
				or flat_dist(_foe) - _foe.radius > Tune.TOWER_RANGE):
			_foe = null
		if _foe == null:
			_foe = nearest_enemy(Tune.TOWER_RANGE, "minion")
			if _foe == null:
				_foe = nearest_enemy(Tune.TOWER_RANGE, "hero")
			_held = 0.0
			_tick = 0.0
		if _foe == null:
			aim = ""
			heat = 0.0
			return
		aim = String(_foe.name)
		_held += delta
		heat = clampf(_held / Tune.TOWER_RAMP, 0.0, 1.0)
		_tick += delta
		if _tick >= Tune.TOWER_TICK:
			_tick -= Tune.TOWER_TICK
			match_node().deal_damage(self, _foe, lerpf(Tune.TOWER_DPS, Tune.TOWER_DPS_MAX, heat) * Tune.TOWER_TICK)

	func _sync_props() -> Array:
		return ["net_pos", "hp", "dead", "aim", "heat"]


class Core extends Unit:
	var _orb: MeshInstance3D
	var _ring: MeshInstance3D

	func _configure() -> void:
		max_hp = Tune.CORE_HP
		radius = 2.0
		solid = true
		bar_height = 6.2
		var color := Tune.team_color(team)
		var plinth := CylinderMesh.new()
		plinth.top_radius = 1.5
		plinth.bottom_radius = 2.1
		plinth.height = 1.4
		add_body(plinth, 0.7, Color(0.45, 0.45, 0.5))
		var orb := SphereMesh.new()
		orb.radius = 1.5
		orb.height = 3.0
		_orb = add_body(orb, 3.2, color.lightened(0.15), 1.8)
		var ring := TorusMesh.new()
		ring.inner_radius = 1.9
		ring.outer_radius = 2.1
		_ring = add_body(ring, 3.2, Color(0.85, 0.8, 0.55))
		_ring.rotation_degrees.x = 25.0

	func _process(delta: float) -> void:
		super(delta)
		_orb.position.y = 3.2 + sin(Time.get_ticks_msec() / 600.0) * 0.2
		_ring.rotate_y(delta * 0.7)

	## The core can only be hit once every tower in one of its lanes is down.
	func targetable() -> bool:
		if dead:
			return false
		var standing := {}
		for u in get_parent().get_children():
			if u.kind == "tower" and u.team == team and not u.dead:
				standing[u.lane] = true
		return standing.size() < Tune.map()["lanes"].size()
