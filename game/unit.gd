class_name Unit
extends Node3D
## Base for everything with a team and hit points. The host simulates;
## clients receive net_pos / hp / dead through the Sync child.
## Animation is procedural and purely local: every peer derives it from the
## replicated position / hp / dead, plus the play_anim one-shots.

var kind := ""
var team := 0
var peer_id := 0          # owning player for heroes, 0 otherwise
var lane := -1            # lane index for towers and minions
var tier := 0             # towers: 0 = outer, higher = closer to the core
var solid := false        # towers and cores: other units cannot walk through
var fogged := false       # local only: an enemy outside our team's sight
var max_hp := 100.0
var hp := 100.0
var dead := false
var radius := 0.6
var net_pos := Vector3.ZERO
var spawn_data := {}
var bar_height := 2.6
var mobile := false       # walks around: gets facing, walk bob and a death topple
var hop := 0.18           # walk bob height

var _bar: MeshInstance3D
var _bar_back: MeshInstance3D
var _atk_cd := 0.0

# Animation state (visual only).
var _model: Node3D        # every body mesh hangs off this pivot
var _tints := []          # [material, base colour] pairs, for the hit flash
var _grow := 0.0          # 0 = gone, 1 = full size (spawn pop-in, death)
var _lunge := 0.0         # forward offset from attack one-shots
var _jump := 0.0          # upward offset from cast one-shots
var _flash := 0.0         # 1 right after taking damage, decays to 0
var _yaw := 0.0
var _speed := 0.0
var _walk_t := 0.0
var _last_pos := Vector3.ZERO
var _last_hp := 0.0
var _was_dead := false
var _grow_tween: Tween
var _rests := {}          # resting values of pulsed properties


func setup(data: Dictionary) -> void:
	spawn_data = data
	kind = data["kind"]
	team = data["team"]
	peer_id = data.get("peer", 0)
	lane = data.get("lane", -1)
	tier = data.get("tier", 0)
	position = data["pos"]
	net_pos = position
	_model = Node3D.new()
	add_child(_model)
	_configure()
	hp = max_hp
	_last_hp = hp
	_last_pos = position
	var ahead := Tune.forward(team)  # face the enemy base
	_yaw = atan2(-ahead.x, -ahead.z)
	_model.rotation.y = _yaw if mobile else 0.0
	_model.scale = Vector3.ONE * 0.01
	_add_bar()
	_add_sync()


func _ready() -> void:
	_was_dead = dead
	if not dead:
		_tween_grow(1.0, 0.3)


## Subclasses set stats and build their mesh here.
func _configure() -> void:
	pass


## Host-side simulation step.
func host_tick(_delta: float) -> void:
	pass


func targetable() -> bool:
	return not dead


func match_node() -> Node:
	return get_parent().get_parent()


func flat_dist(other: Unit) -> float:
	return Vector2(position.x - other.position.x, position.z - other.position.z).length()


func add_body(mesh: Mesh, y: float, color: Color, glow := 0.0) -> MeshInstance3D:
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.position.y = y
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	if glow > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = glow
	body.material_override = mat
	_model.add_child(body)
	_tints.append([mat, color])
	return body


## Moves toward a point on the ground; returns true on arrival.
func step_toward(target: Vector3, speed: float, delta: float) -> bool:
	var to := Vector3(target.x - position.x, 0.0, target.z - position.z)
	var dist := to.length()
	var step := speed * delta
	if dist <= step:
		position = Tune.clamp_to_map(free_point(target))
		return true
	var heading := to / dist
	position = Tune.clamp_to_map(free_point(position + heading * step, heading, step))
	return false


## Pushes a ground point out of any tower or core it overlaps. When walking
## (heading given) it also slips sideways, so units go around instead of
## stalling against the stonework.
func free_point(p: Vector3, heading := Vector3.ZERO, slide := 0.0) -> Vector3:
	for u in get_parent().get_children():
		if u == self or not u.solid or u.dead:
			continue
		var away := Vector3(p.x - u.position.x, 0.0, p.z - u.position.z)
		var gap: float = u.radius + radius
		var d := away.length()
		if d >= gap:
			continue
		away = away / d if d > 0.001 else -Tune.forward(team)
		p = Vector3(u.position.x, 0.0, u.position.z) + away * gap
		if slide > 0.0:
			var tangent := Vector3(-away.z, 0.0, away.x)
			var along := tangent.dot(heading)
			p += tangent * (slide if along >= -0.05 else -slide)
	return p


func nearest_enemy(max_range: float, only_kind := "") -> Unit:
	var best: Unit = null
	var best_d := INF
	for u in get_parent().get_children():
		if u.team == team or not u.targetable():
			continue
		if only_kind != "" and u.kind != only_kind:
			continue
		var d: float = flat_dist(u) - u.radius
		if d <= max_range and d < best_d:
			best = u
			best_d = d
	return best


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		# Smooth toward the replicated position; snap on teleports (respawn).
		if position.distance_to(net_pos) > 12.0:
			position = net_pos
		else:
			position = position.lerp(net_pos, 1.0 - exp(-18.0 * delta))
	if _bar != null:
		_bar.scale.x = clampf(hp / max_hp, 0.001, 1.0)
		_bar.visible = not dead
		_bar_back.visible = not dead
	_animate(delta)


# --- Animation -------------------------------------------------------------------

## One-shot animation, sent by the host when a unit attacks or casts.
@rpc("authority", "call_local", "unreliable")
func play_anim(anim: String, toward: Vector3) -> void:
	var to := Vector3(toward.x - position.x, 0.0, toward.z - position.z)
	if to.length() > 0.05:
		_yaw = atan2(-to.x, -to.z)
	_anim(anim)


## Subclasses override to move their own parts; the default is a body lunge
## for attacks and a hop for casts.
func _anim(anim: String) -> void:
	if anim == "attack":
		pulse(self, "_lunge", 0.5, 0.07, 0.16)
	else:
		pulse(self, "_jump", 0.7, 0.14, 0.2)


## Tweens a property out to a peak and back to where it started.
func pulse(node: Object, prop: String, peak: Variant, up: float, down: float) -> void:
	var key := "%d:%s" % [node.get_instance_id(), prop]
	if not _rests.has(key):
		_rests[key] = node.get_indexed(prop)
	var rest: Variant = _rests[key]
	var tw := create_tween()
	tw.tween_property(node, prop, peak, up).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(node, prop, rest, down).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_QUAD)


func _tween_grow(to: float, time: float) -> void:
	if _grow_tween != null:
		_grow_tween.kill()
	_grow_tween = create_tween()
	_grow_tween.tween_property(self, "_grow", to, time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK if to > 0.5 else Tween.TRANS_QUAD)


func _animate(delta: float) -> void:
	# Death and respawn.
	if dead != _was_dead:
		_was_dead = dead
		_tween_grow(0.0 if dead else 1.0, 0.4 if dead else 0.3)
	visible = _grow > 0.02 and not fogged

	# Damage flash.
	if hp < _last_hp - 0.5 and not dead:
		_flash = 1.0
	_last_hp = hp
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 5.0)
		for pair in _tints:
			pair[0].albedo_color = pair[1].lerp(Color.WHITE, _flash * 0.75)

	# Movement, measured from what actually happened on this peer.
	var moved := Vector3(position.x - _last_pos.x, 0.0, position.z - _last_pos.z)
	_last_pos = position
	var dist := moved.length()
	var now := 0.0
	if dist < 3.0 and delta > 0.0:  # larger jumps are teleports
		now = dist / delta
		if mobile and dist > 0.004:
			_yaw = atan2(-moved.x, -moved.z)
	_speed = lerpf(_speed, now, 1.0 - exp(-10.0 * delta))
	var walk := clampf(_speed / 3.0, 0.0, 1.0) if mobile else 0.0
	_walk_t += delta * (5.0 + _speed * 1.1)

	var squash := _flash * (0.14 if mobile else 0.03)
	var breathe := sin(Time.get_ticks_msec() / 520.0 + get_instance_id() % 7) * 0.015 * (1.0 - walk) if mobile else 0.0
	_model.scale = Vector3(1.0 + squash, 1.0 - squash + breathe, 1.0 + squash) * maxf(_grow, 0.01)
	if mobile:
		_model.rotation.y = lerp_angle(_model.rotation.y, _yaw, 1.0 - exp(-14.0 * delta))
		_model.rotation.x = -0.16 * walk
		_model.rotation.z = (1.0 - clampf(_grow, 0.0, 1.0)) * 1.3 if dead else sin(_walk_t) * 0.05 * walk
	var forward := Vector3(-sin(_model.rotation.y), 0.0, -cos(_model.rotation.y))
	_model.position = forward * _lunge + Vector3(0.0, absf(sin(_walk_t)) * hop * walk + _jump, 0.0)


func _add_bar() -> void:
	_bar_back = _bar_quad(Color(0.05, 0.05, 0.05), 0)
	_bar_back.scale = Vector3(1.06, 1.3, 1.0)
	_bar = _bar_quad(Tune.team_color(team).lightened(0.2), 1)


func _bar_quad(color: Color, priority: int) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.8, 0.2)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.no_depth_test = true
	mat.render_priority = priority
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.position.y = bar_height
	add_child(mi)
	return mi


func _sync_props() -> Array:
	return ["net_pos", "hp", "dead"]


func _add_sync() -> void:
	var cfg := SceneReplicationConfig.new()
	for prop in _sync_props():
		var path := NodePath(".:" + prop)
		cfg.add_property(path)
		cfg.property_set_spawn(path, true)
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	sync.replication_config = cfg
	sync.replication_interval = 0.05
	add_child(sync)
