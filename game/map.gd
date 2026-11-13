class_name MapBuilder
extends RefCounted
## Builds the lane scenery from primitives. Purely visual and deterministic
## (fixed random seed), so every peer builds the same map locally.

static var _root: Node3D
static var _mats := {}


static func build(root: Node3D) -> void:
	_root = root
	_mats = {}
	_sky_and_light()
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
	var half_len := Tune.LANE_HALF_LEN
	var half_wid := Tune.LANE_HALF_WID
	# Forest floor far beyond the lane so the camera never sees a void.
	_plane(Vector3(0, -0.04, 0), Vector2(420, 260), _noise_mat("forest", Color(0.1, 0.2, 0.1), Color(0.17, 0.29, 0.13), 0.02, 14.0))
	# Lane grass.
	_plane(Vector3(0, 0.0, 0), Vector2(half_len * 2.0, half_wid * 2.0), _noise_mat("grass", Color(0.22, 0.4, 0.17), Color(0.36, 0.52, 0.22), 0.03, 6.0))
	# Worn dirt path down the middle, with a slightly ragged edge strip.
	var dirt := _noise_mat("dirt", Color(0.36, 0.28, 0.18), Color(0.52, 0.42, 0.28), 0.05, 8.0)
	_plane(Vector3(0, 0.02, 0), Vector2(half_len * 2.0 - Tune.BASE_DEPTH * 2.0, 5.0), dirt)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 60:
		var x := rng.randf_range(-half_len + Tune.BASE_DEPTH + 1.0, half_len - Tune.BASE_DEPTH - 1.0)
		var z := (2.5 + rng.randf_range(-0.2, 0.5)) * (1.0 if i % 2 == 0 else -1.0)
		var patch := _plane(Vector3(x, 0.025, z), Vector2(rng.randf_range(1.5, 3.5), rng.randf_range(0.6, 1.3)), dirt)
		patch.rotation.y = rng.randf_range(-0.2, 0.2)
	# Flower / tuft dots on the grass.
	var tuft := SphereMesh.new()
	tuft.radius = 0.16
	tuft.height = 0.2
	var colors := [Color(0.95, 0.9, 0.4), Color(0.9, 0.5, 0.6), Color(0.85, 0.85, 0.95), Color(0.3, 0.55, 0.2)]
	for i in 140:
		var x := rng.randf_range(-half_len + Tune.BASE_DEPTH + 1.0, half_len - Tune.BASE_DEPTH - 1.0)
		var z := rng.randf_range(3.6, half_wid - 0.8) * (1.0 if rng.randf() < 0.5 else -1.0)
		if absf(x) < 3.6:
			continue
		_mesh(tuft, Vector3(x, 0.08, z), _flat_mat(colors[i % colors.size()]))


# --- Walls ---------------------------------------------------------------------

static func _walls() -> void:
	var half_len := Tune.LANE_HALF_LEN
	var half_wid := Tune.LANE_HALF_WID
	var stone := _noise_mat("stone", Color(0.3, 0.31, 0.34), Color(0.47, 0.47, 0.5), 0.08, 3.0)
	var cap := _flat_mat(Color(0.55, 0.55, 0.58))
	for z in [-1.0, 1.0]:
		var wz: float = z * (half_wid + 0.6)
		_box(Vector3(0, 0.75, wz), Vector3(half_len * 2.0 + 2.4, 1.5, 1.2), stone)
		_box(Vector3(0, 1.56, wz), Vector3(half_len * 2.0 + 2.6, 0.14, 1.45), cap)
		var x := -half_len
		while x <= half_len + 0.1:
			_box(Vector3(x, 1.2, wz), Vector3(1.5, 2.4, 1.6), stone)
			_box(Vector3(x, 2.48, wz), Vector3(1.8, 0.18, 1.9), cap)
			x += 8.0
	for x in [-1.0, 1.0]:
		var wx: float = x * (half_len + 0.6)
		_box(Vector3(wx, 0.75, 0), Vector3(1.2, 1.5, half_wid * 2.0), stone)
		_box(Vector3(wx, 1.56, 0), Vector3(1.45, 0.14, half_wid * 2.0), cap)


# --- River and bridge ------------------------------------------------------------

static func _river() -> void:
	var half_wid := Tune.LANE_HALF_WID
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.16, 0.42, 0.62, 0.78)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.roughness = 0.08
	water.metallic = 0.35
	# Inside the lane, and continuing out through the forest on both sides.
	_plane(Vector3(0, 0.03, 0), Vector2(6.0, half_wid * 2.0), water)
	for z in [-1.0, 1.0]:
		_plane(Vector3(0, 0.0, z * (half_wid + 1.2 + 55.0)), Vector2(6.0, 110.0), water)
	var bank := _flat_mat(Color(0.55, 0.5, 0.38))
	for x in [-3.3, 3.3]:
		_plane(Vector3(x, 0.035, 0), Vector2(0.7, half_wid * 2.0), bank)
	# Plank bridge carrying the path across.
	var wood := _noise_mat("wood", Color(0.33, 0.21, 0.11), Color(0.5, 0.34, 0.18), 0.12, 2.0)
	var x := -3.4
	while x <= 3.41:
		_box(Vector3(x, 0.06, 0), Vector3(0.78, 0.12, 5.6), wood)
		x += 0.85
	for z in [-2.9, 2.9]:
		_box(Vector3(0, 0.55, z), Vector3(7.4, 0.14, 0.14), wood)
		for px in [-3.6, 0.0, 3.6]:
			_box(Vector3(px, 0.3, z), Vector3(0.2, 0.7, 0.2), wood)


# --- Bases -----------------------------------------------------------------------

static func _bases() -> void:
	var half_len := Tune.LANE_HALF_LEN
	var half_wid := Tune.LANE_HALF_WID
	var paving := _noise_mat("paving", Color(0.38, 0.38, 0.42), Color(0.56, 0.55, 0.58), 0.1, 4.0)
	for team in 2:
		var s := -Tune.side(team)
		var color := Tune.team_color(team)
		var glow := _glow_mat(color, 1.6)
		# Paved base floor with a glowing border line.
		_plane(Vector3(s * (half_len - Tune.BASE_DEPTH * 0.5), 0.03, 0), Vector2(Tune.BASE_DEPTH, half_wid * 2.0), paving)
		_box(Vector3(s * (half_len - Tune.BASE_DEPTH - 0.1), 0.06, 0), Vector3(0.25, 0.1, half_wid * 2.0), glow)
		# Core dais.
		_cyl(Vector3(s * Tune.CORE_X, 0.12, 0), 4.2, 0.24, paving)
		var ring := TorusMesh.new()
		ring.inner_radius = 3.9
		ring.outer_radius = 4.2
		_mesh(ring, Vector3(s * Tune.CORE_X, 0.26, 0), glow)
		# Tower footing.
		_cyl(Vector3(s * Tune.TOWER_X, 0.08, 0), 2.4, 0.16, paving)
		var tring := TorusMesh.new()
		tring.inner_radius = 2.2
		tring.outer_radius = 2.4
		_mesh(tring, Vector3(s * Tune.TOWER_X, 0.18, 0), glow)
		# Banners and braziers in the base corners.
		var pole := _flat_mat(Color(0.25, 0.18, 0.1))
		for z in [-1.0, 1.0]:
			var bx: float = s * (half_len - 1.6)
			var bz: float = z * (half_wid - 1.4)
			_cyl(Vector3(bx, 2.6, bz), 0.1, 5.2, pole)
			_box(Vector3(bx - s * 0.75, 4.2, bz), Vector3(1.4, 1.9, 0.08), _flat_mat(color))
			var fx: float = s * (half_len - Tune.BASE_DEPTH + 1.0)
			_cyl(Vector3(fx, 0.6, bz), 0.35, 1.2, pole)
			var flame := SphereMesh.new()
			flame.radius = 0.35
			flame.height = 0.8
			_mesh(flame, Vector3(fx, 1.5, bz), _glow_mat(color.lightened(0.3), 3.0))
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
		core_light.position = Vector3(s * Tune.CORE_X, 5.0, 0)
		_root.add_child(core_light)


# --- Trees, rocks, bushes --------------------------------------------------------

static func _scenery() -> void:
	var half_len := Tune.LANE_HALF_LEN
	var half_wid := Tune.LANE_HALF_WID
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var trunk_mat := _flat_mat(Color(0.3, 0.2, 0.12))
	var leaf_mats := [_flat_mat(Color(0.13, 0.36, 0.16)), _flat_mat(Color(0.18, 0.43, 0.18)), _flat_mat(Color(0.1, 0.3, 0.2))]
	var rock_mat := _flat_mat(Color(0.42, 0.42, 0.45))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.22
	trunk.bottom_radius = 0.32
	trunk.height = 1.6
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.5
	cone.height = 2.6
	cone.radial_segments = 10
	var blob := SphereMesh.new()
	blob.radius = 1.0
	blob.height = 1.6
	blob.radial_segments = 12
	blob.rings = 6
	# Forest on both sides and behind the bases.
	for i in 170:
		var x := rng.randf_range(-half_len - 22.0, half_len + 22.0)
		var z := rng.randf_range(half_wid + 2.8, half_wid + 30.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		if absf(x) > half_len + 2.5:
			z = rng.randf_range(-half_wid - 30.0, half_wid + 30.0)
		if absf(x) < 4.5:
			continue  # keep the river clear
		var p := Vector3(x, 0, z)
		var size := rng.randf_range(0.8, 1.7)
		if rng.randf() < 0.82:
			var leaf: Material = leaf_mats[rng.randi() % leaf_mats.size()]
			_mesh(trunk, p + Vector3(0, 0.8 * size, 0), trunk_mat).scale = Vector3.ONE * size
			_mesh(cone, p + Vector3(0, 2.4 * size, 0), leaf).scale = Vector3.ONE * size
			_mesh(cone, p + Vector3(0, 3.7 * size, 0), leaf).scale = Vector3.ONE * size * 0.72
		else:
			var rock := _mesh(blob, p + Vector3(0, 0.3 * size, 0), rock_mat)
			rock.scale = Vector3(size * rng.randf_range(0.8, 1.6), size * 0.8, size * rng.randf_range(0.8, 1.4))
			rock.rotation.y = rng.randf() * TAU
	# Bushes and small rocks tucked against the inside of the walls.
	for i in 46:
		var x := rng.randf_range(-half_len + Tune.BASE_DEPTH + 1.0, half_len - Tune.BASE_DEPTH - 1.0)
		if absf(x) < 4.5:
			continue
		var z := (half_wid - rng.randf_range(0.3, 0.9)) * (1.0 if i % 2 == 0 else -1.0)
		var size := rng.randf_range(0.45, 0.85)
		var is_rock := rng.randf() < 0.3
		var prop := _mesh(blob, Vector3(x, 0.35 * size, z), rock_mat if is_rock else leaf_mats[i % leaf_mats.size()])
		prop.scale = Vector3(size * 1.2, size, size)


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
