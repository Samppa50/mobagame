## Minion, Tower and Core live in one file as inner classes of this script.
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


class Tower extends Unit:
	var _crystal: MeshInstance3D

	func _process(delta: float) -> void:
		super(delta)
		_crystal.rotation.y += delta * 0.9

	func _anim(_name: String) -> void:
		pulse(_crystal, "scale", Vector3.ONE * 1.6, 0.06, 0.3)

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

	func host_tick(delta: float) -> void:
		_atk_cd = maxf(0.0, _atk_cd - delta)
		if _atk_cd > 0.0:
			return
		var foe := nearest_enemy(Tune.TOWER_RANGE, "minion")
		if foe == null:
			foe = nearest_enemy(Tune.TOWER_RANGE, "hero")
		if foe != null:
			_atk_cd = Tune.TOWER_CD
			var m := match_node()
			play_anim.rpc("attack", foe.position)
			m.fx_beam.rpc(position + Vector3(0, 6.2, 0), foe.position, team)
			m.deal_damage(self, foe, Tune.TOWER_DMG)


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
