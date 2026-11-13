class_name MapBuilder
extends RefCounted
## Builds the scenery for the current map (Tune.map()) from primitives.
## Purely visual and deterministic (fixed random seeds), so every peer builds
## the same map locally. Walkability lives in Tune, not here.

static var _root: Node3D
static var _mats := {}
static var _props := {}  # shared tree / rock meshes and materials


static func build(root: Node3D) -> void:
	_root = root
	_mats = {}
	_props = {}
	_sky_and_light()
	_init_props()
	if Tune.map()["style"] == "square":
		SquareMap.build()
		_root = null
		return
	_ground()
	_walls()
	_river()
	_bases()
	_scenery()
	_root = null


# --- Lighting ------------------------------------------------------------------

static func _sky_and_light() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.2, 0.36, 0.62)
	sky_mat.sky_horizon_color = Color(0.72, 0.68, 0.6)
	sky_mat.ground_bottom_color = Color(0.1, 0.13, 0.1)
	sky_mat.ground_horizon_color = Color(0.72, 0.68, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.glow_intensity = 0.6
	e.glow_bloom = 0.08
	e.ssao_enabled = true
	e.fog_enabled = true
	e.fog_light_color = Color(0.62, 0.68, 0.72)
	e.fog_density = 0.0025
	var env := WorldEnvironment.new()
	env.environment = e
	_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	_root.add_child(sun)


# --- Ground --------------------------------------------------------------------

static func _ground() -> void:
	var m := Tune.map()
	var half_len: float = m["half_len"]
	var half_wid: float = m["half_wid"]
	var lanes := [0.0]  # this builder is for the one straight lane
	var inner := half_len - Tune.BASE_DEPTH  # x of the base line
	# Forest floor far beyond the map so the camera never sees a void.
	var forest := _noise_mat("forest", Color(0.1, 0.2, 0.1), Color(0.17, 0.29, 0.13), 0.02, 14.0)
	_plane(Vector3(0, -0.04, 0), Vector2(420, 260), forest)
	# Lane grass.
	_plane(Vector3(0, 0.0, 0), Vector2(half_len * 2.0, half_wid * 2.0), _noise_mat("grass", Color(0.22, 0.4, 0.17), Color(0.36, 0.52, 0.22), 0.03, 6.0))
	# Worn dirt path down each lane, with a slightly ragged edge strip.
	var dirt := _noise_mat("dirt", Color(0.36, 0.28, 0.18), Color(0.52, 0.42, 0.28), 0.05, 8.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for lane_z: float in lanes:
		_plane(Vector3(0, 0.02, lane_z), Vector2(inner * 2.0, 5.0), dirt)
		for i in 60:
			var x := rng.randf_range(-inner + 1.0, inner - 1.0)
			var z := lane_z + (2.5 + rng.randf_range(-0.2, 0.5)) * (1.0 if i % 2 == 0 else -1.0)
			var patch := _plane(Vector3(x, 0.025, z), Vector2(rng.randf_range(1.5, 3.5), rng.randf_range(0.6, 1.3)), dirt)
			patch.rotation.y = rng.randf_range(-0.2, 0.2)
	# Flower / tuft dots on the grass, clear of the paths, river and forest.
	var tuft := SphereMesh.new()
	tuft.radius = 0.16
	tuft.height = 0.2
	var colors := [Color(0.95, 0.9, 0.4), Color(0.9, 0.5, 0.6), Color(0.85, 0.85, 0.95), Color(0.3, 0.55, 0.2)]
	for i in 140 * lanes.size():
		var p := Vector3(rng.randf_range(-inner + 1.0, inner - 1.0), 0.08, rng.randf_range(-half_wid + 0.8, half_wid - 0.8))
		if absf(p.x) < 3.6 or not Tune.walkable(p, -0.8):
			continue
		var on_path := false
		for lane_z: float in lanes:
			on_path = on_path or absf(p.z - lane_z) < 3.6
		if not on_path:
			_mesh(tuft, p, _flat_mat(colors[i % colors.size()]))


# --- Walls ---------------------------------------------------------------------

static func _walls() -> void:
	var m := Tune.map()
	var half_len: float = m["half_len"]
	var half_wid: float = m["half_wid"]
	# Outer wall around the whole map.
	for z in [-1.0, 1.0]:
		_wall_x(-half_len - 1.2, half_len + 1.2, z * (half_wid + 0.6), 1.5, true)
	for x in [-1.0, 1.0]:
		_wall_z(-half_wid, half_wid, x * (half_len + 0.6), 1.5)


## Stone wall running along X, optionally with a pillar every 8 units.
static func _wall_x(x0: float, x1: float, z: float, height: float, pillars: bool) -> void:
	var stone := _noise_mat("stone", Color(0.3, 0.31, 0.34), Color(0.47, 0.47, 0.5), 0.08, 3.0)
	var cap := _flat_mat(Color(0.55, 0.55, 0.58))
	var mid := (x0 + x1) * 0.5
	_box(Vector3(mid, height * 0.5, z), Vector3(x1 - x0, height, 1.2), stone)
	_box(Vector3(mid, height + 0.06, z), Vector3(x1 - x0 + 0.2, 0.14, 1.45), cap)
	if not pillars:
		return
	var x := x0 + 1.2
	while x <= x1 - 1.1:
		_box(Vector3(x, (height + 0.9) * 0.5, z), Vector3(1.5, height + 0.9, 1.6), stone)
		_box(Vector3(x, height + 0.98, z), Vector3(1.8, 0.18, 1.9), cap)
		x += 8.0


## Stone wall running along Z.
static func _wall_z(z0: float, z1: float, x: float, height: float) -> void:
	var stone := _noise_mat("stone", Color(0.3, 0.31, 0.34), Color(0.47, 0.47, 0.5), 0.08, 3.0)
	var cap := _flat_mat(Color(0.55, 0.55, 0.58))
	var mid := (z0 + z1) * 0.5
	_box(Vector3(x, height * 0.5, mid), Vector3(1.2, height, z1 - z0), stone)
	_box(Vector3(x, height + 0.06, mid), Vector3(1.45, 0.14, z1 - z0), cap)


# --- River and bridges -------------------------------------------------------------

static func _river() -> void:
	var m := Tune.map()
	var half_wid: float = m["half_wid"]
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.16, 0.42, 0.62, 0.78)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.roughness = 0.08
	water.metallic = 0.35
	# Inside the map, and continuing out through the forest on both sides.
	_plane(Vector3(0, 0.03, 0), Vector2(6.0, half_wid * 2.0), water)
	for z in [-1.0, 1.0]:
		_plane(Vector3(0, 0.0, z * (half_wid + 1.2 + 55.0)), Vector2(6.0, 110.0), water)
	var bank := _flat_mat(Color(0.55, 0.5, 0.38))
	for x in [-3.3, 3.3]:
		_plane(Vector3(x, 0.035, 0), Vector2(0.7, half_wid * 2.0), bank)
	# A plank bridge carrying each lane's path across.
	var wood := _noise_mat("wood", Color(0.33, 0.21, 0.11), Color(0.5, 0.34, 0.18), 0.12, 2.0)
	for lane_z: float in [0.0]:
		var x := -3.4
		while x <= 3.41:
			_box(Vector3(x, 0.06, lane_z), Vector3(0.78, 0.12, 5.6), wood)
			x += 0.85
		for z in [-2.9, 2.9]:
			_box(Vector3(0, 0.55, lane_z + z), Vector3(7.4, 0.14, 0.14), wood)
			for px in [-3.6, 0.0, 3.6]:
				_box(Vector3(px, 0.3, lane_z + z), Vector3(0.2, 0.7, 0.2), wood)


# --- Bases -----------------------------------------------------------------------

static func _bases() -> void:
	var m := Tune.map()
	var half_len: float = m["half_len"]
	var half_wid: float = m["half_wid"]
	var core_x: float = m["cores"][1].x
	var tower_x: float = m["towers"][1]["pos"].x
	var paving := _noise_mat("paving", Color(0.38, 0.38, 0.42), Color(0.56, 0.55, 0.58), 0.1, 4.0)
	for team in 2:
		var s := -1.0 if team == 0 else 1.0
		var color := Tune.team_color(team)
		var glow := _glow_mat(color, 1.6)
		# Paved base floor with a glowing border line.
		_plane(Vector3(s * (half_len - Tune.BASE_DEPTH * 0.5), 0.03, 0), Vector2(Tune.BASE_DEPTH, half_wid * 2.0), paving)
		_box(Vector3(s * (half_len - Tune.BASE_DEPTH - 0.1), 0.06, 0), Vector3(0.25, 0.1, half_wid * 2.0), glow)
		# Core dais.
		_cyl(Vector3(s * core_x, 0.12, 0), 4.2, 0.24, paving)
		var ring := TorusMesh.new()
		ring.inner_radius = 3.9
		ring.outer_radius = 4.2
		_mesh(ring, Vector3(s * core_x, 0.26, 0), glow)
		# One tower footing per lane.
		for lane_z: float in [0.0]:
			_cyl(Vector3(s * tower_x, 0.08, lane_z), 2.4, 0.16, paving)
			var tring := TorusMesh.new()
			tring.inner_radius = 2.2
			tring.outer_radius = 2.4
			_mesh(tring, Vector3(s * tower_x, 0.18, lane_z), glow)
		# Banners and braziers in the base corners.
		var pole := _flat_mat(Color(0.25, 0.18, 0.1))
		for z in [-1.0, 1.0]:
			var bx: float = s * (half_len - 1.6)
			var bz: float = z * (half_wid - 1.4)
			_cyl(Vector3(bx, 2.6, bz), 0.1, 5.2, pole)
			var banner := _box(Vector3(bx - s * 0.75, 4.2, bz), Vector3(1.4, 1.9, 0.08), _flat_mat(color))
			_sway(banner, "rotation:x", 0.14, 1.1 + 0.2 * z)
			var fx: float = s * (half_len - Tune.BASE_DEPTH + 1.0)
			_cyl(Vector3(fx, 0.6, bz), 0.35, 1.2, pole)
			var flame_mesh := SphereMesh.new()
			flame_mesh.radius = 0.35
			flame_mesh.height = 0.8
			var flame := _mesh(flame_mesh, Vector3(fx, 1.5, bz), _glow_mat(color.lightened(0.3), 3.0))
			_sway(flame, "scale:y", 0.3, 0.16 + 0.03 * z, 1.15)
			var lamp := OmniLight3D.new()
			lamp.light_color = color.lightened(0.3)
			lamp.light_energy = 2.0
			lamp.omni_range = 9.0
			lamp.position = Vector3(fx, 2.2, bz)
			_root.add_child(lamp)
		var core_light := OmniLight3D.new()
		core_light.light_color = color
		core_light.light_energy = 3.0
		core_light.omni_range = 12.0
		core_light.position = Vector3(s * core_x, 5.0, 0)
		_root.add_child(core_light)


## Endless back-and-forth on one property (banner sway, flame flicker).
static func _sway(node: Node3D, prop: String, amount: float, half_period: float, centre := 0.0) -> void:
	var tw := node.create_tween().set_loops()
	tw.tween_property(node, prop, centre + amount, half_period).set_trans(Tween.TRANS_SINE)
	tw.tween_property(node, prop, centre - amount, half_period).set_trans(Tween.TRANS_SINE)


# --- Trees, rocks, bushes --------------------------------------------------------

static func _scenery() -> void:
	var m := Tune.map()
	var half_len: float = m["half_len"]
	var half_wid: float = m["half_wid"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var blob: Mesh = _props["blob"]
	# Forest on both sides and behind the bases.
	for i in 170:
		var x := rng.randf_range(-half_len - 22.0, half_len + 22.0)
		var z := rng.randf_range(half_wid + 2.8, half_wid + 30.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		if absf(x) > half_len + 2.5:
			z = rng.randf_range(-half_wid - 30.0, half_wid + 30.0)
		if absf(x) < 4.5:
			continue  # keep the river clear
		_tree_or_rock(Vector3(x, 0, z), rng.randf_range(0.8, 1.7), rng)
	# Bushes and small rocks tucked against the inside of the outer walls.
	var leaf_mats: Array = _props["leaf_mats"]
	for i in 46:
		var x := rng.randf_range(-half_len + Tune.BASE_DEPTH + 1.0, half_len - Tune.BASE_DEPTH - 1.0)
		if absf(x) < 4.5:
			continue
		var z := (half_wid - rng.randf_range(0.3, 0.9)) * (1.0 if i % 2 == 0 else -1.0)
		var size := rng.randf_range(0.45, 0.85)
		var is_rock := rng.randf() < 0.3
		var prop := _mesh(blob, Vector3(x, 0.35 * size, z), _props["rock_mat"] if is_rock else leaf_mats[i % leaf_mats.size()])
		prop.scale = Vector3(size * 1.2, size, size)


## Shared tree / rock meshes and materials.
static func _init_props() -> void:
	_props["trunk_mat"] = _flat_mat(Color(0.3, 0.2, 0.12))
	_props["leaf_mats"] = [_flat_mat(Color(0.13, 0.36, 0.16)), _flat_mat(Color(0.18, 0.43, 0.18)), _flat_mat(Color(0.1, 0.3, 0.2))]
	_props["rock_mat"] = _flat_mat(Color(0.42, 0.42, 0.45))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.22
	trunk.bottom_radius = 0.32
	trunk.height = 1.6
	_props["trunk"] = trunk
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.5
	cone.height = 2.6
	cone.radial_segments = 10
	_props["cone"] = cone
	var blob := SphereMesh.new()
	blob.radius = 1.0
	blob.height = 1.6
	blob.radial_segments = 12
	blob.rings = 6
	_props["blob"] = blob


static func _tree_or_rock(p: Vector3, size: float, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.82:
		var leaf_mats: Array = _props["leaf_mats"]
		var leaf: Material = leaf_mats[rng.randi() % leaf_mats.size()]
		_mesh(_props["trunk"], p + Vector3(0, 0.8 * size, 0), _props["trunk_mat"]).scale = Vector3.ONE * size
		_mesh(_props["cone"], p + Vector3(0, 2.4 * size, 0), leaf).scale = Vector3.ONE * size
		_mesh(_props["cone"], p + Vector3(0, 3.7 * size, 0), leaf).scale = Vector3.ONE * size * 0.72
	else:
		var rock := _mesh(_props["blob"], p + Vector3(0, 0.3 * size, 0), _props["rock_mat"])
		rock.scale = Vector3(size * rng.randf_range(0.8, 1.6), size * 0.8, size * rng.randf_range(0.8, 1.4))
		rock.rotation.y = rng.randf() * TAU


# --- Helpers -----------------------------------------------------------------------

static func _mesh(mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	_root.add_child(mi)
	return mi


static func _box(pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh(mesh, pos, mat)


static func _plane(pos: Vector3, size: Vector2, mat: Material) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = size
	var mi := _mesh(mesh, pos, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _cyl(pos: Vector3, radius: float, height: float, mat: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	return _mesh(mesh, pos, mat)


static func _flat_mat(color: Color) -> StandardMaterial3D:
	var key := "flat:" + color.to_html()
	if not _mats.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_mats[key] = mat
	return _mats[key]


static func _glow_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat


## Mottled two-tone surface from tiling noise, in world space so that
## differently sized pieces share the same texture scale.
static func _noise_mat(key: String, dark: Color, light: Color, frequency: float, world_tile: float) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var noise := FastNoiseLite.new()
	noise.seed = hash(key)
	noise.frequency = frequency
	noise.fractal_octaves = 4
	var ramp := Gradient.new()
	ramp.set_color(0, dark)
	ramp.set_color(1, light)
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = 0.9
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE / world_tile
	_mats[key] = mat
	return mat
