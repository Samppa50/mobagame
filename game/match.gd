extends Node3D
## One match: map, unit spawning, damage, win condition, local input and effects.
## Must be named "Match" under Main on every peer so RPC paths line up.

var units: Node3D
var spawner: MultiplayerSpawner
var camera: Camera3D
var hud: CanvasLayer
const CAM_OFFSET := Vector3(0, 27, 17)
const CAM_SPEED := 45.0   # free cam pan speed, world units per second
const CAM_EDGE := 10.0    # pixels from a screen edge that start a pan

var free_cam := false     # local: camera detached from the hero (toggled with Y)
var cam_focus := Vector3.ZERO  # ground point the camera looks at
var _mouse_inside := true
var show_range := false   # local: ring showing our hero's basic attack range (toggled with R)
var _range_ring: MeshInstance3D

var over := false
var winner := -1
var clock := 0.0          # local: seconds since our hero appeared; shown on the HUD
var vision := PackedVector3Array()  # (x, z, sight) of every allied unit; read by the minimap

const FOG_SHADER := "
shader_type spatial;
render_mode unshaded, shadows_disabled, fog_disabled, depth_draw_never;

uniform vec3 eyes[64];
uniform int eye_count = 0;
uniform float strength = 0.5;
varying vec3 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float lit = 0.0;
	for (int i = 0; i < eye_count; i++) {
		float d = distance(world.xz, eyes[i].xy);
		lit = max(lit, 1.0 - smoothstep(eyes[i].z - 2.5, eyes[i].z, d));
	}
	ALBEDO = vec3(0.01, 0.02, 0.04);
	ALPHA = strength * (1.0 - lit);
}
"

var _fog: ShaderMaterial

var _listener: AudioListener3D
var _wave_left := 3.0
var _camps := []          # host: {pos, size, unit, left} per jungle camp
var _shots := []          # host: active Q projectiles
var _shot_fx := {}        # shot id -> visual node
var _next_shot := 1
var _started := false
var _selftest: RefCounted


func _ready() -> void:
	name = "Match"
	_build_map()
	units = Node3D.new()
	units.name = "Units"
	add_child(units)
	spawner = MultiplayerSpawner.new()
	spawner.name = "Spawner"
	spawner.spawn_function = _spawn_unit
	add_child(spawner)
	spawner.spawn_path = spawner.get_path_to(units)
	camera = Camera3D.new()
	camera.fov = 50.0
	add_child(camera)
	camera.position = CAM_OFFSET
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	hud = preload("res://ui/hud.gd").new()
	hud.match_node = self
	add_child(hud)
	Net.match_node = self
	if multiplayer.is_server():
		Net.all_ready.connect(host_begin, CONNECT_ONE_SHOT)
	elif Net.selftest:
		_selftest = load("res://tests/selftest.gd").new()
		_selftest.run_client(self)


func _exit_tree() -> void:
	if Net.match_node == self:
		Net.match_node = null


# --- Map -------------------------------------------------------------------------

func _build_map() -> void:
	MapBuilder.build(self)
	# A glowing ring marks each team's fountain, where resting heals quickly.
	for team in 2:
		var ring := TorusMesh.new()
		ring.inner_radius = Tune.FOUNTAIN_RADIUS - 0.25
		ring.outer_radius = Tune.FOUNTAIN_RADIUS
		var mi := _glow(ring, Tune.team_color(team).lightened(0.35))
		mi.position = Tune.map()["spawns"][team] + Vector3(0, 0.09, 0)
		mi.scale.y = 0.2
	# An amber ring marks each jungle camp.
	for camp: Dictionary in Tune.map()["camps"]:
		var mark := TorusMesh.new()
		mark.outer_radius = 1.6 * Tune.MONSTERS[camp["size"]]["scale"]
		mark.inner_radius = mark.outer_radius - 0.15
		var ring := _glow(mark, Tune.team_color(Tune.NEUTRAL))
		ring.position = camp["pos"] + Vector3(0, 0.09, 0)
		ring.scale.y = 0.2
	# Fog of war: a dark veil over the ground, cut open around allied units.
	var veil := PlaneMesh.new()
	veil.size = Vector2(420, 420)
	_fog = ShaderMaterial.new()
	_fog.shader = Shader.new()
	_fog.shader.code = FOG_SHADER
	_fog.render_priority = 1
	var fog_plane := MeshInstance3D.new()
	fog_plane.mesh = veil
	fog_plane.material_override = _fog
	fog_plane.position.y = 0.07
	fog_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fog_plane)


## Decides which enemies this player can see. Purely local and visual: the
## host still simulates everything. Enemy heroes and minions are hidden unless
## an allied hero, minion, tower or core has them in sight.
func _update_fog() -> void:
	var mine := Net.my_team()
	vision.clear()
	# Heroes and structures first, so they are never the ones cut by the cap.
	for minions in [false, true]:
		for u in units.get_children():
			if u.team == mine and not u.dead and (u.kind == "minion") == minions and vision.size() < Tune.FOG_MAX_EYES:
				vision.append(Vector3(u.position.x, u.position.z, Tune.SIGHT[u.kind]))
	for u in units.get_children():
		var hidden: bool = u.team != mine and not u.solid and not over
		if hidden:
			for eye in vision:
				if Vector2(eye.x - u.position.x, eye.y - u.position.z).length() <= eye.z + u.radius:
					hidden = false
					break
		u.fogged = hidden
	_fog.set_shader_parameter("eyes", vision)
	_fog.set_shader_parameter("eye_count", 0 if over else vision.size())
	_fog.set_shader_parameter("strength", 0.0 if over else 0.5)


# --- Spawning --------------------------------------------------------------------

## Runs on every peer for each replicated unit.
func _spawn_unit(data: Dictionary) -> Node:
	var u: Unit
	match data["kind"]:
		"hero": u = Hero.new()
		"minion": u = Structures.Minion.new()
		"monster": u = Structures.Monster.new()
		"tower": u = Structures.Tower.new()
		_: u = Structures.Core.new()
	u.setup(data)
	return u


func host_spawn(kind: String, team: int, pos: Vector3, peer := 0, hero := 0, extra := {}) -> Unit:
	var data := {"kind": kind, "team": team, "pos": pos, "peer": peer, "hero": hero}
	data.merge(extra)
	return spawner.spawn(data)


func host_begin() -> void:
	if _started:
		return
	_started = true
	var map := Tune.map()
	for team in 2:
		host_spawn("core", team, map["cores"][team])
	for t: Dictionary in map["towers"]:
		host_spawn("tower", t["team"], t["pos"], 0, 0, {"lane": t["lane"], "tier": t["tier"]})
	for camp: Dictionary in map["camps"]:
		_camps.append({"pos": camp["pos"], "size": camp["size"], "unit": null, "left": 0.0})
	for peer in Net.players:
		var team: int = Net.players[peer]["team"]
		var h := host_spawn("hero", team, Vector3.ZERO, peer, int(Net.players[peer].get("hero", 0)))
		h.position = hero_spawn_point(h)
		h.net_pos = h.position
	if Net.selftest:
		_selftest = load("res://tests/selftest.gd").new()
		_selftest.run(self)


func hero_spawn_point(hero: Unit) -> Vector3:
	var slot := 0
	for u in units.get_children():
		if u == hero:
			break
		if u.kind == "hero" and u.team == hero.team:
			slot += 1
	# Lined up across the base, side by side.
	var ahead := Tune.forward(hero.team)
	var spawn: Vector3 = Tune.map()["spawns"][hero.team]
	return Tune.clamp_to_map(spawn + Vector3(-ahead.z, 0, ahead.x) * (slot - 1) * 3.0)


func hero_for(peer: int) -> Hero:
	if units == null:
		return null
	for u in units.get_children():
		if u.kind == "hero" and u.peer_id == peer:
			return u
	return null


func host_remove_player(peer: int) -> void:
	var h := hero_for(peer)
	if h != null:
		h.queue_free()


# --- Host simulation ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or not _started or over:
		return
	_wave_left -= delta
	if _wave_left <= 0.0:
		_wave_left = Tune.WAVE_INTERVAL
		var map := Tune.map()
		var lanes: Array = map["lanes"]
		for team in 2:
			for lane in lanes.size():
				# A staggered file at this team's end of the lane.
				var pts: Array = lanes[lane]
				var start: Vector3 = pts[0] if team == 0 else pts[-1]
				var ahead: Vector3 = ((pts[1] if team == 0 else pts[-2]) - start).normalized()
				var across := Vector3(-ahead.z, 0, ahead.x)
				for i in Tune.WAVE_SIZE:
					var off := across * (i - 1) * 1.6
					host_spawn("minion", team, Tune.clamp_to_map(start - ahead * i * 1.2 + off), 0, 0, {"lane": lane, "off": off})
	for u in units.get_children():
		if not u.is_queued_for_deletion():
			u.host_tick(delta)
	_tick_shots(delta)
	_tick_camps(delta)


## Fills every jungle camp at the start, and again a while after it is cleared.
func _tick_camps(delta: float) -> void:
	for camp: Dictionary in _camps:
		var monster = camp["unit"]
		if monster != null and is_instance_valid(monster) and not monster.dead:
			continue
		camp["unit"] = null
		camp["left"] -= delta
		if camp["left"] <= 0.0:
			camp["left"] = Tune.MONSTER_RESPAWN
			camp["unit"] = host_spawn("monster", Tune.NEUTRAL, camp["pos"], 0, 0, {"size": camp["size"]})


## The single place damage is applied. Hero damage is scaled by how loud the
## owning player is yelling right now (host-measured).
func deal_damage(source: Unit, target: Unit, base: float) -> float:
	if over or not is_instance_valid(target) or not target.targetable():
		return 0.0
	var mult := 1.0
	if source is Hero:
		mult = Voice.multiplier_for(source.peer_id)
	var amount := base * mult
	target.hp = maxf(0.0, target.hp - amount)
	# Fighting pauses the faster out-of-combat regeneration.
	if source is Hero:
		source.note_combat()
	if target is Hero:
		target.note_combat()
	if target is Structures.Monster and source is Hero:
		target.provoke(source)
	if source is Hero or target is Hero:
		fx_damage.rpc(target.position, amount, mult)
	if target.hp <= 0.0:
		_host_kill(target, source)
	return amount


## Healing is yell-scaled too. Shown as a green "+N".
func heal(source: Hero, target: Unit, base: float) -> void:
	if over or not is_instance_valid(target) or target.dead:
		return
	var mult := Voice.multiplier_for(source.peer_id)
	target.hp = minf(target.max_hp, target.hp + base * mult)
	fx_damage.rpc(target.position, -base * mult, mult)


func _host_kill(target: Unit, source: Unit) -> void:
	# Bounties: the killing blow pays for heroes and minions; a fallen tower
	# pays the whole enemy team, whoever finished it.
	var killer: Hero = source as Hero
	match target.kind:
		"hero":
			_share_xp(target, source, Tune.XP_HERO + Tune.XP_HERO_PER_LEVEL * target.level)
			if killer != null:
				killer.kills += 1
				killer.earn(Tune.GOLD_HERO)
		"minion":
			_share_xp(target, source, Tune.XP_MINION)
			if killer != null:
				killer.cs += 1
				killer.earn(Tune.GOLD_MINION)
		"monster":
			_share_xp(target, source, target.spec["xp"])
			if killer != null:
				killer.earn(target.spec["gold"])
		"tower":
			for u in units.get_children():
				if u is Hero and u.team != target.team:
					u.earn(Tune.GOLD_TOWER)
					u.add_xp(Tune.XP_TOWER)
	match target.kind:
		"hero":
			target.host_die()
		"core":
			target.dead = true
			over = true
			fx_death.rpc(target.position, target.kind, target.team)
			game_over.rpc(1 - target.team)
			get_tree().create_timer(6.0).timeout.connect(Net.end_match)
		_:
			target.dead = true
			fx_death.rpc(target.position, target.kind, target.team)
			target.queue_free()


## Splits a dying unit's xp between the living heroes of the side that killed
## it who are close enough to have been part of the fight. A hero who struck
## the blow from further away still shares.
func _share_xp(target: Unit, source: Unit, amount: float) -> void:
	var sharers := []
	for u in units.get_children():
		if u is Hero and u.team == source.team and not u.dead \
				and (u == source or u.flat_dist(target) <= Tune.XP_RANGE):
			sharers.append(u)
	for hero: Hero in sharers:
		hero.add_xp(amount / sharers.size())


func host_fire_shot(hero: Hero, dir: Vector3, spec: Dictionary) -> void:
	var id := _next_shot
	_next_shot += 1
	var start := hero.position
	_shots.append({"id": id, "pos": start, "dir": dir, "left": spec["range"], "owner": hero, "spec": spec})
	fx_shot.rpc(id, start, dir, hero.team, spec["range"], spec["speed"])


func _tick_shots(delta: float) -> void:
	for shot in _shots.duplicate():
		var spec: Dictionary = shot["spec"]
		var step := minf(spec["speed"] * delta, shot["left"])
		shot["pos"] += shot["dir"] * step
		shot["left"] -= step
		var owner: Hero = shot["owner"] if is_instance_valid(shot["owner"]) else null
		var hit: Unit = null
		if owner != null:
			for u in units.get_children():
				if u.team == owner.team or not u.targetable():
					continue
				var d: float = Vector2(u.position.x - shot["pos"].x, u.position.z - shot["pos"].z).length()
				if d <= spec["radius"] + u.radius:
					hit = u
					break
		if hit != null:
			deal_damage(owner, hit, spec["dmg"] * owner.power)
		if hit != null or owner == null or shot["left"] <= 0.0:
			_shots.erase(shot)
			fx_shot_end.rpc(shot["id"])


@rpc("authority", "call_local", "reliable")
func game_over(winning_team: int) -> void:
	over = true
	winner = winning_team


# --- Local input ---------------------------------------------------------------------

func my_hero() -> Hero:
	return hero_for(multiplayer.get_unique_id())


func mouse_ground() -> Vector3:
	var mouse := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	return hit if hit != null else Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Y:
		free_cam = not free_cam
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		show_range = not show_range
	var hero := my_hero()
	if hero == null or hero.dead or over:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var point := mouse_ground()
		var target := _enemy_near(hero, point)
		if target != null:
			command(hero, "cmd_attack", [String(target.name)])
		else:
			command(hero, "cmd_move", [point])
			_ping(point)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			command(hero, "cmd_cast", [0, mouse_ground()])
		elif event.keycode == KEY_W:
			command(hero, "cmd_cast", [1, mouse_ground()])
		elif event.keycode == KEY_F3:
			Voice.loopback = not Voice.loopback


## Used by the minimap: walk to a world point.
func order_move(point: Vector3) -> void:
	var hero := my_hero()
	if hero != null and not hero.dead and not over:
		command(hero, "cmd_move", [Tune.clamp_to_map(point)])


func _enemy_near(hero: Hero, point: Vector3) -> Unit:
	var best: Unit = null
	var best_d := INF
	for u in units.get_children():
		if u.team == hero.team or not u.targetable() or u.fogged:
			continue
		var d: float = Vector2(u.position.x - point.x, u.position.z - point.z).length() - u.radius
		if d < 1.0 and d < best_d:
			best = u
			best_d = d
	return best


func command(hero: Hero, method: String, args: Array) -> void:
	if multiplayer.is_server():
		hero.callv(method, args)
	else:
		hero.callv("rpc_id", [1, method] + args)


func _process(delta: float) -> void:
	_update_fog()
	var hero := my_hero()
	if hero == null:
		return
	if not over:
		clock += delta
	_move_camera(hero, delta)
	if _range_ring == null:
		var ring := TorusMesh.new()
		ring.outer_radius = hero.def["range"]
		ring.inner_radius = ring.outer_radius - 0.12
		_range_ring = _glow(ring, Color(1, 1, 1))
		_range_ring.scale.y = 0.2
	_range_ring.visible = show_range and not hero.dead
	_range_ring.position = hero.position + Vector3(0, 0.12, 0)
	# Ears on the hero, not the camera, so voice volume follows hero distance.
	if _listener == null or not is_instance_valid(_listener):
		_listener = AudioListener3D.new()
		_listener.position.y = 1.6
		hero.add_child(_listener)
		_listener.make_current()


## The camera follows the hero unless free cam is on (Y). In free cam it pans
## with the arrow keys or by pushing the mouse against a screen edge, and
## holding Space brings it back to the hero.
func _move_camera(hero: Hero, delta: float) -> void:
	if not free_cam or Input.is_key_pressed(KEY_SPACE):
		cam_focus = hero.position
	elif get_window().has_focus():
		var pan := Vector2.ZERO
		if Input.is_key_pressed(KEY_LEFT):
			pan.x -= 1.0
		if Input.is_key_pressed(KEY_RIGHT):
			pan.x += 1.0
		if Input.is_key_pressed(KEY_UP):
			pan.y -= 1.0
		if Input.is_key_pressed(KEY_DOWN):
			pan.y += 1.0
		if _mouse_inside:
			var mouse := get_viewport().get_mouse_position()
			var view := get_viewport().get_visible_rect().size
			if mouse.x <= CAM_EDGE:
				pan.x -= 1.0
			elif mouse.x >= view.x - CAM_EDGE:
				pan.x += 1.0
			if mouse.y <= CAM_EDGE:
				pan.y -= 1.0
			elif mouse.y >= view.y - CAM_EDGE:
				pan.y += 1.0
		look_at_point(cam_focus + Vector3(pan.x, 0.0, pan.y).limit_length(1.0) * CAM_SPEED * delta)
	camera.position = cam_focus + CAM_OFFSET


## Free cam: centre the view on a world point (also used by the minimap).
func look_at_point(point: Vector3) -> void:
	var m := Tune.map()
	cam_focus = Vector3(clampf(point.x, -m["half_len"], m["half_len"]), 0.0, clampf(point.z, -m["half_wid"], m["half_wid"]))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_inside = true
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_inside = false


# --- Effects (visual only, run on every peer) ------------------------------------------

@rpc("authority", "call_local", "unreliable")
func fx_damage(pos: Vector3, amount: float, mult: float) -> void:
	var t := clampf((mult - 1.0) / (Tune.YELL_MULT_MAX - 1.0), 0.0, 1.0)
	var healing := amount < 0.0
	_float_text(pos + Vector3(randf_range(-0.5, 0.5), 3.2, 0),
		("+" if healing else "") + str(int(round(absf(amount)))) + ("!" if t > 0.5 else ""),
		Color(0.5, 1.0, 0.55) if healing else Color(1, 1, 1).lerp(Color(1.0, 0.25, 0.1), t),
		int(lerpf(48.0, 120.0, t)))


## Gold earned; sent only to the player who earned it.
@rpc("authority", "call_local", "reliable")
func fx_gold(pos: Vector3, amount: int) -> void:
	_float_text(pos + Vector3(0, 4.6, 0), "+%d g" % amount, Color(1.0, 0.84, 0.25), 56)


## A hero reached a new level.
@rpc("authority", "call_local", "reliable")
func fx_level(pos: Vector3, level: int) -> void:
	fx_slam(pos, 2.4, Color(1.0, 0.9, 0.4))
	_float_text(pos + Vector3(0, 5.4, 0), "LEVEL %d" % level, Color(1.0, 0.9, 0.4), 72)


func _float_text(pos: Vector3, text: String, color: Color, font_size: int) -> void:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = font_size
	label.pixel_size = 0.012
	label.outline_size = 14
	label.modulate = color
	label.position = pos
	add_child(label)
	var tw := label.create_tween()
	tw.tween_property(label, "position:y", label.position.y + 2.5, 0.9)
	tw.parallel().tween_property(label, "modulate:a", 0.0, 0.9).set_ease(Tween.EASE_IN)
	tw.tween_callback(label.queue_free)


@rpc("authority", "call_local", "unreliable")
func fx_beam(from: Vector3, to: Vector3, team: int) -> void:
	var a := from + Vector3(0, 1.2, 0) if from.y < 1.0 else from
	var b := to + Vector3(0, 1.0, 0)
	if a.distance_to(b) < 0.05:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.12, 0.12, a.distance_to(b))
	var mi := _glow(mesh, Tune.team_color(team).lightened(0.4))
	mi.position = (a + b) * 0.5
	mi.look_at_from_position(mi.position, b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.RIGHT)
	get_tree().create_timer(0.12).timeout.connect(mi.queue_free)


@rpc("authority", "call_local", "reliable")
func fx_shot(id: int, start: Vector3, dir: Vector3, team: int, shot_range: float, speed: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.45
	mesh.height = 0.9
	var mi := _glow(mesh, Tune.team_color(team).lightened(0.5))
	mi.position = start + Vector3(0, 1.1, 0)
	_shot_fx[id] = mi
	var tw := mi.create_tween()
	tw.tween_property(mi, "position", mi.position + dir * shot_range, shot_range / speed)
	tw.tween_callback(func(): fx_shot_end(id))
	var throb := mi.create_tween().set_loops()
	throb.tween_property(mi, "scale", Vector3.ONE * 1.35, 0.07)
	throb.tween_property(mi, "scale", Vector3.ONE, 0.07)


@rpc("authority", "call_local", "reliable")
func fx_shot_end(id: int) -> void:
	if _shot_fx.has(id):
		if is_instance_valid(_shot_fx[id]):
			_shot_fx[id].queue_free()
		_shot_fx.erase(id)


@rpc("authority", "call_local", "unreliable")
func fx_slam(pos: Vector3, slam_radius: float, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = slam_radius
	mesh.bottom_radius = slam_radius
	mesh.height = 0.1
	var mi := _glow(mesh, color)
	mi.position = pos + Vector3(0, 0.15, 0)
	mi.scale = Vector3(0.2, 1, 0.2)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE, 0.18)
	tw.tween_interval(0.12)
	tw.tween_callback(mi.queue_free)


func _ping(point: Vector3) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.4
	mesh.bottom_radius = 0.4
	mesh.height = 0.05
	var mi := _glow(mesh, Color(0.6, 1.0, 0.6))
	mi.position = Vector3(point.x, 0.08, point.z)
	mi.scale = Vector3(1.8, 1.0, 1.8)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3(0.1, 1.0, 0.1), 0.35).set_ease(Tween.EASE_OUT)
	tw.tween_callback(mi.queue_free)


## Debris burst where a minion, tower or core went down. Those units are
## removed the moment they die, so the match plays their death for them.
@rpc("authority", "call_local", "unreliable")
func fx_death(pos: Vector3, unit_kind: String, team: int) -> void:
	var big := unit_kind == "tower" or unit_kind == "core"
	var color := Tune.team_color(team)
	fx_slam(pos, 3.2 if big else 1.1, color.lightened(0.3))
	for i in (16 if big else 7):
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * randf_range(0.18, 0.4) * (2.2 if big else 1.0)
		var mi := _glow(mesh, color if i % 2 == 0 else Color(0.6, 0.6, 0.64))
		var angle := randf() * TAU
		var reach := randf_range(1.0, 2.4) * (2.0 if big else 1.0)
		var land := pos + Vector3(cos(angle) * reach, 0.1, sin(angle) * reach)
		mi.position = pos + Vector3(0, randf_range(0.5, 5.5 if big else 1.4), 0)
		var time := randf_range(0.4, 0.7)
		var tw := mi.create_tween()
		tw.set_parallel()
		tw.tween_property(mi, "position:x", land.x, time)
		tw.tween_property(mi, "position:z", land.z, time)
		tw.tween_property(mi, "position:y", land.y, time).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(mi, "rotation", Vector3(randf() * 6.0, randf() * 6.0, randf() * 6.0), time)
		tw.chain().tween_property(mi, "scale", Vector3.ONE * 0.05, 0.3)
		tw.chain().tween_callback(mi.queue_free)


func _glow(mesh: Mesh, color: Color) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	return mi
