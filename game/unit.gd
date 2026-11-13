class_name Unit
extends Node3D
## Base for everything with a team and hit points. The host simulates;
## clients receive net_pos / hp / dead through the Sync child.

var kind := ""
var team := 0
var peer_id := 0          # owning player for heroes, 0 otherwise
var max_hp := 100.0
var hp := 100.0
var dead := false
var radius := 0.6
var net_pos := Vector3.ZERO
var spawn_data := {}
var bar_height := 2.6

var _bar: MeshInstance3D
var _atk_cd := 0.0


func setup(data: Dictionary) -> void:
	spawn_data = data
	kind = data["kind"]
	team = data["team"]
	peer_id = data.get("peer", 0)
	position = data["pos"]
	net_pos = position
	_configure()
	hp = max_hp
	_add_bar()
	_add_sync()


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
	add_child(body)
	return body


## Moves toward a point on the ground; returns true on arrival.
func step_toward(target: Vector3, speed: float, delta: float) -> bool:
	var to := Vector3(target.x - position.x, 0.0, target.z - position.z)
	var dist := to.length()
	var step := speed * delta
	if dist <= step:
		position = Tune.clamp_to_lane(target)
		return true
	position = Tune.clamp_to_lane(position + to / dist * step)
	return false


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
	visible = not dead
	if not multiplayer.is_server():
		# Smooth toward the replicated position; snap on teleports (respawn).
		if position.distance_to(net_pos) > 12.0:
			position = net_pos
		else:
			position = position.lerp(net_pos, 1.0 - exp(-18.0 * delta))
	if _bar != null:
		_bar.scale.x = clampf(hp / max_hp, 0.001, 1.0)


func _add_bar() -> void:
	var back := _bar_quad(Color(0.05, 0.05, 0.05), 0)
	back.scale = Vector3(1.06, 1.3, 1.0)
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
