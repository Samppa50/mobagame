class_name SquareMap
extends RefCounted
## Scenery for the square three-lane map: corner bases, lanes drawn from the
## map's walkable paths, a river on the diagonal and forest everywhere else.
## Uses MapBuilder's primitive helpers and shares its determinism rule.


static func build() -> void:
	var m := Tune.map()
	var half: float = m["half_len"]
	var grass := MapBuilder._noise_mat("grass", Color(0.22, 0.4, 0.17), Color(0.36, 0.52, 0.22), 0.03, 6.0)
	var glade := MapBuilder._noise_mat("glade", Color(0.16, 0.31, 0.15), Color(0.27, 0.42, 0.19), 0.03, 6.0)
	var dirt := MapBuilder._noise_mat("dirt", Color(0.36, 0.28, 0.18), Color(0.52, 0.42, 0.28), 0.05, 8.0)
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.16, 0.42, 0.62, 0.78)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.roughness = 0.08
	water.metallic = 0.35
	# Forest floor far beyond the map so the camera never sees a void.
	MapBuilder._plane(Vector3(0, -0.04, 0), Vector2(420, 420), MapBuilder._noise_mat("forest", Color(0.1, 0.2, 0.1), Color(0.17, 0.29, 0.13), 0.02, 14.0))
	# Walkable ground: lit grass on the lanes, darker glades on jungle paths,
	# then the worn dirt of each lane and the shallow river over the top.
	for path: Dictionary in m["paths"]:
		if path["kind"] == "jungle":
			_strip(path["pts"], path["half"], 0.0, glade, true)
		elif path["kind"] == "lane":
			_strip(path["pts"], path["half"], 0.004, grass, true)
	for lane: Array in m["lanes"]:
		_strip(lane, 2.3, 0.02, dirt, true)
	var river: Dictionary = m["river"]
	_strip(river["pts"], river["half"], 0.03, water, false)
	_strip(river["pts"], river["half"] + 0.5, 0.012, MapBuilder._flat_mat(Color(0.55, 0.5, 0.38)), false)

	_walls(half)
	_bases(m)
	_forest(half)
	_tufts(m, half)


## A flat ribbon along a polyline, with a disc at every point so that corners
## and ends come out round, like the walkable area itself.
static func _strip(pts: Array, half: float, y: float, mat: Material, caps: bool) -> void:
	for i in pts.size():
		var a: Vector3 = pts[i]
		if caps:
			var disc := MapBuilder._cyl(Vector3(a.x, y - 0.005, a.z), half, 0.01, mat)
			disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if i == 0:
			continue
		var b: Vector3 = pts[i - 1]
		var piece := MapBuilder._plane(Vector3((a.x + b.x) * 0.5, y, (a.z + b.z) * 0.5), Vector2(a.distance_to(b), half * 2.0), mat)
		piece.rotation.y = atan2(-(a.z - b.z), a.x - b.x)


static func _walls(half: float) -> void:
	for s in [-1.0, 1.0]:
		MapBuilder._wall_x(-half - 1.2, half + 1.2, s * (half + 0.6), 1.5, true)
		MapBuilder._wall_z(-half, half, s * (half + 0.6), 1.5)


static func _bases(m: Dictionary) -> void:
	var paving := MapBuilder._noise_mat("paving", Color(0.38, 0.38, 0.42), Color(0.56, 0.55, 0.58), 0.1, 4.0)
	var pole := MapBuilder._flat_mat(Color(0.25, 0.18, 0.1))
	for team in 2:
		var base: Rect2 = m["bases"][team]
		var centre := base.get_center()
		var core: Vector3 = m["cores"][team]
		var color := Tune.team_color(team)
		var glow := MapBuilder._glow_mat(color, 1.6)
		var inward := Tune.forward(team)  # toward the middle of the map
		# Paved floor, with a glowing line along the two edges that face the map.
		MapBuilder._plane(Vector3(centre.x, 0.03, centre.y), base.size, paving)
		var edge_x := base.end.x if inward.x > 0.0 else base.position.x
		var edge_z := base.end.y if inward.z > 0.0 else base.position.y
		MapBuilder._box(Vector3(edge_x, 0.06, centre.y), Vector3(0.25, 0.1, base.size.y), glow)
		MapBuilder._box(Vector3(centre.x, 0.06, edge_z), Vector3(base.size.x, 0.1, 0.25), glow)
		# Core dais.
		MapBuilder._cyl(Vector3(core.x, 0.12, core.z), 4.2, 0.24, paving)
		var ring := TorusMesh.new()
		ring.inner_radius = 3.9
		ring.outer_radius = 4.2
		MapBuilder._mesh(ring, Vector3(core.x, 0.26, core.z), glow)
		var core_light := OmniLight3D.new()
		core_light.light_color = color
		core_light.light_energy = 3.0
		core_light.omni_range = 12.0
		core_light.position = core + Vector3(0, 5.0, 0)
		MapBuilder._root.add_child(core_light)
		# Banners in the three outer corners, braziers where the lanes leave.
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var p := Vector3(centre.x + corner.x * (base.size.x * 0.5 - 1.6), 0, centre.y + corner.y * (base.size.y * 0.5 - 1.6))
			if Vector3(corner.x, 0, corner.y).dot(inward) > 0.5:
				continue  # the corner that opens onto the middle lane
			MapBuilder._cyl(p + Vector3(0, 2.6, 0), 0.1, 5.2, pole)
			var banner := MapBuilder._box(p + Vector3(0.75, 4.2, 0), Vector3(1.4, 1.9, 0.08), MapBuilder._flat_mat(color))
			MapBuilder._sway(banner, "rotation:x", 0.14, 1.1 + 0.1 * corner.x)
		for start: Array in m["lanes"]:
			var gate: Vector3 = start[0] if team == 0 else start[-1]
			var next: Vector3 = start[1] if team == 0 else start[-2]
			var ahead := (next - gate).normalized()
			var across := Vector3(-ahead.z, 0, ahead.x)
			for side in [-1.0, 1.0]:
				var f: Vector3 = gate + across * side * 4.2
				MapBuilder._cyl(f + Vector3(0, 0.6, 0), 0.35, 1.2, pole)
				var flame_mesh := SphereMesh.new()
				flame_mesh.radius = 0.35
				flame_mesh.height = 0.8
				var flame := MapBuilder._mesh(flame_mesh, f + Vector3(0, 1.5, 0), MapBuilder._glow_mat(color.lightened(0.3), 3.0))
				MapBuilder._sway(flame, "scale:y", 0.3, 0.16 + 0.03 * side, 1.15)
	# A footing under every tower, in its team's colour.
	for t: Dictionary in m["towers"]:
		var p: Vector3 = t["pos"]
		MapBuilder._cyl(Vector3(p.x, 0.08, p.z), 2.4, 0.16, paving)
		var tring := TorusMesh.new()
		tring.inner_radius = 2.2
		tring.outer_radius = 2.4
		MapBuilder._mesh(tring, Vector3(p.x, 0.18, p.z), MapBuilder._glow_mat(Tune.team_color(t["team"]), 1.6))


## Trees and rocks on all the ground nobody can walk on, inside and out.
static func _forest(half: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4321
	var reach := half + 24.0
	for i in 1500:
		var p := Vector3(rng.randf_range(-reach, reach), 0, rng.randf_range(-reach, reach))
		var size := rng.randf_range(0.7, 1.5)
		var inside := absf(p.x) < half and absf(p.z) < half
		if inside:
			# Jungle: packed close, but never leaning over a path.
			if Tune.clearance(p) < 2.4 or absf(p.x) > half - 1.5 or absf(p.z) > half - 1.5:
				continue
		elif absf(p.x) < half + 2.8 and absf(p.z) < half + 2.8:
			continue  # clear of the outer wall
		elif i % 3 != 0:
			continue  # thinner outside, where it is only backdrop
		MapBuilder._tree_or_rock(p, size, rng)


## Flower / tuft dots on the lane grass, clear of the dirt, river and bases.
static func _tufts(m: Dictionary, half: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var tuft := SphereMesh.new()
	tuft.radius = 0.16
	tuft.height = 0.2
	var colors := [Color(0.95, 0.9, 0.4), Color(0.9, 0.5, 0.6), Color(0.85, 0.85, 0.95), Color(0.3, 0.55, 0.2)]
	for i in 2600:
		var p := Vector3(rng.randf_range(-half, half), 0.08, rng.randf_range(-half, half))
		if not Tune.walkable(p, -0.8) or Tune.path_dist(p, m["river"]["pts"]) < m["river"]["half"] + 1.0:
			continue
		var skip := false
		for lane: Array in m["lanes"]:
			skip = skip or Tune.path_dist(p, lane) < 3.0
		for base: Rect2 in m["bases"]:
			skip = skip or base.has_point(Vector2(p.x, p.z))
		if not skip:
			MapBuilder._mesh(tuft, p, MapBuilder._flat_mat(colors[i % colors.size()]))
