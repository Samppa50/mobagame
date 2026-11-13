extends RefCounted
## End-to-end check, run inside a real two-instance networked match:
##   godot --path . -- --dev-host --autostart=2 --selftest
##   godot --path . -- --dev-join --selftest
## The host verifies yell scaling through the real damage path, then quits.
## The client moves its hero and reports what it received from the host.

var _fails := 0


func check(label: String, ok: bool, detail := "") -> void:
	print("SELFTEST %s: %s %s" % ["ok  " if ok else "FAIL", label, detail])
	if not ok:
		_fails += 1


func run_client(m: Node) -> void:
	var tree := m.get_tree()
	await tree.create_timer(1.6).timeout
	var me: Hero = m.my_hero()
	print("SELFTEST client: own hero replicated=%s units=%d" % [me != null, m.units.get_child_count()])
	if me != null:
		me.cmd_move.rpc_id(1, Vector3(0, 0, 5))
	await tree.create_timer(1.6).timeout
	if me != null:
		print("SELFTEST client: hero hp=%.0f/%.0f pos=%s" % [me.hp, me.max_hp, me.position])
	await tree.create_timer(1.5).timeout
	print("SELFTEST client: over=%s winner=%d my_team=%d" % [m.over, m.winner, Net.my_team()])


## Solo host (--autostart=1): cast both abilities of the picked hero.
func run_kit(m: Node) -> void:
	var tree := m.get_tree()
	await tree.create_timer(1.0).timeout
	var hero: Hero = m.my_hero()
	var dummy: Unit = m.host_spawn("minion", 1 - hero.team, hero.position + Tune.forward(hero.team) * 4.0)
	dummy.max_hp = 5000.0
	dummy.hp = 5000.0
	hero.hp = 100.0
	var start := hero.position
	for slot in 2:
		var spec: Dictionary = hero.def["q" if slot == 0 else "w"]
		var hp_before := hero.hp
		var dummy_before := dummy.hp
		var pos_before := hero.position
		hero.cmd_cast(slot, dummy.position)
		await tree.create_timer(0.7).timeout
		var worked := false
		match spec["type"]:
			"heal": worked = hero.hp > hp_before + 50.0
			"blink": worked = hero.position.distance_to(pos_before) > 2.0
			_: worked = dummy.hp < dummy_before - 30.0
		check("%s %s (%s)" % [hero.def["name"], spec["name"], spec["type"]], worked,
			"dummy %.0f, hero hp %.0f, moved %.1f" % [dummy.hp, hero.hp, hero.position.distance_to(start)])
		check("cooldown started", (hero.cd_q if slot == 0 else hero.cd_w) > 0.0)
		hero.position = start
	await _finish(tree)


func run(m: Node) -> void:
	var tree := m.get_tree()
	if Net.players.size() == 1:
		await run_kit(m)
		return
	await tree.create_timer(1.0).timeout
	var a: Hero = m.hero_for(1)
	var b: Hero = null
	for u in m.units.get_children():
		if u.kind == "hero" and u.team != a.team:
			b = u
	check("both heroes spawned on opposite teams", a != null and b != null)
	if b == null:
		await _finish(tree)
		return
	var kinds := {}
	for u in m.units.get_children():
		kinds[u.kind] = kinds.get(u.kind, 0) + 1
	var lanes: Array = Tune.map()["lanes"]
	check("structures spawned", kinds.get("tower", 0) == Tune.map()["towers"].size() and kinds.get("core", 0) == 2, str(kinds))
	check_geometry()

	# Fog of war (local to this peer) and regeneration, while both heroes
	# still stand at their own fountains on opposite sides of the map.
	check("distant enemy hero is hidden by fog", b.fogged and not a.fogged)
	a.hp = 100.0
	a._calm = Tune.CALM_AFTER
	await tree.create_timer(0.5).timeout
	check("resting at the fountain heals quickly", a.hp > 100.0 + a.max_hp * Tune.FOUNTAIN_REGEN * 0.3, "hp %.0f" % a.hp)
	a.note_combat()
	var fought: float = a.hp
	await tree.create_timer(0.3).timeout
	check("in combat only the trickle remains", a.hp - fought < Tune.HERO_REGEN * 0.5, "+%.1f" % (a.hp - fought))
	a.hp = a.max_hp

	# Multiplier mapping.
	check("silent = x1", is_equal_approx(Tune.yell_multiplier(-80.0), 1.0))
	check("threshold = x1", is_equal_approx(Tune.yell_multiplier(Tune.YELL_DB_MIN), 1.0))
	check("screaming = max", is_equal_approx(Tune.yell_multiplier(0.0), Tune.YELL_MULT_MAX))
	var prev := 0.0
	var mono := true
	for db in range(-60, 1):
		var v := Tune.yell_multiplier(db)
		mono = mono and v >= prev
		prev = v
	check("monotonic", mono)

	# Real damage path, quiet vs yelling.
	var b_start := b.position
	Voice.clear_loudness(1)
	var quiet: float = m.deal_damage(a, b, 50.0)
	check("quiet hero hit deals base damage", is_equal_approx(quiet, 50.0), "got %.1f" % quiet)
	Voice._note(1, Tune.YELL_DB_MAX)
	var loud: float = m.deal_damage(a, b, 50.0)
	check("yelling hero hit deals x%.0f" % Tune.YELL_MULT_MAX, is_equal_approx(loud, 50.0 * Tune.YELL_MULT_MAX), "got %.1f" % loud)
	Voice.clear_loudness(1)
	Voice._note(1, -23.0)
	var mid: float = m.deal_damage(a, b, 50.0)
	check("mid loudness is in between", mid > 50.0 and mid < 50.0 * Tune.YELL_MULT_MAX, "got %.1f" % mid)

	# Minions are never yell-scaled.
	var minion: Unit = m.host_spawn("minion", a.team, a.position)
	Voice._note(1, Tune.YELL_DB_MAX)
	var md: float = m.deal_damage(minion, b, 10.0)
	check("minion damage is not scaled", is_equal_approx(md, 10.0), "got %.1f" % md)
	minion.queue_free()

	# Loudness expires after the window.
	await tree.create_timer(Tune.YELL_WINDOW_MS / 1000.0 + 0.15).timeout
	# (A live microphone on the host can legitimately keep this above x1.)
	check("yell expires after window", is_equal_approx(Voice.multiplier_for(1), 1.0), "peak %.1f dB, mic result %d" % [Voice.peak_db(1), Voice.last_result])

	# By now the client has sent a move command over the network.
	await tree.create_timer(1.0).timeout
	check("client move command moved its hero", b.position.distance_to(b_start) > 1.0, str(b.position))

	# Command path: host hero attacks via the same call the input code uses.
	a.position = b.position + Vector3(3, 0, 0)
	b.hp = b.max_hp
	a.cmd_attack(String(b.name))
	await tree.create_timer(1.2).timeout
	check("attack command damages target", b.hp < b.max_hp - a.def["dmg"] * 0.7, "hp %.0f" % b.hp)
	check("enemy hero in sight is revealed", not b.fogged)

	# The first wave is out by now: every lane has minions from both teams.
	var seen := {}
	for u in m.units.get_children():
		if u.kind == "minion":
			seen[Vector2i(u.lane, u.team)] = true
	check("minions in every lane for both teams", seen.size() == lanes.size() * 2, "%d of %d" % [seen.size(), lanes.size() * 2])

	# Towers are solid: a hero ordered straight through one walks around it.
	var core: Unit = null
	var lane_towers := []  # the enemy's towers in lane 0, outermost first
	for u in m.units.get_children():
		if u.team == b.team and u.kind == "core":
			core = u
		if u.team == b.team and u.kind == "tower" and u.lane == 0:
			lane_towers.append(u)
	lane_towers.sort_custom(func(x: Unit, y: Unit) -> bool: return x.tier < y.tier)
	var gate: Unit = lane_towers[0]
	var far_side := gate.position + Vector3(4, 0, 0)
	a.position = gate.position - Vector3(4, 0, 0)
	a.cmd_move(far_side)
	var closest := INF
	for i in 110:
		await tree.physics_frame
		a.hp = a.max_hp
		closest = minf(closest, a.flat_dist(gate))
	check("hero cannot walk through a tower", closest >= gate.radius + a.radius - 0.05, "closest %.2f, needs %.2f" % [closest, gate.radius + a.radius])
	check("hero gets around the tower", a.position.distance_to(far_side) < 0.5, "%.1f away" % a.position.distance_to(far_side))

	# Inner towers wait for the outer one; the core waits for a whole lane.
	check("core untargetable while towers stand", not core.targetable())
	if lane_towers.size() > 1:
		check("inner tower untargetable while outer stands", not lane_towers[1].targetable())
	for t: Unit in lane_towers:
		m.deal_damage(a, t, 99999.0)
		await tree.process_frame
		await tree.process_frame
	check("core targetable after a lane's towers fall", core.targetable())
	m.deal_damage(a, core, 99999.0)
	check("match over, host team wins", m.over and m.winner == a.team)
	await _finish(tree)


## Walkability and routing on every map (pure functions, so the active map is
## swapped for the duration of the check and then restored).
func check_geometry() -> void:
	var active: int = Tune.map_index
	for index in Tune.maps.size():
		Tune.map_index = index
		var m: Dictionary = Tune.map()
		var title: String = m["name"]
		var half := Vector2(m["half_len"], m["half_wid"])
		# Everything the match places must stand on walkable ground.
		var placed: Array = m["cores"] + m["spawns"] + m["nodes"]
		for t: Dictionary in m["towers"]:
			placed.append(t["pos"])
		for lane: Array in m["lanes"]:
			placed.append_array(lane)
		var grounded := true
		for p: Vector3 in placed:
			grounded = grounded and Tune.walkable(p)
		check("%s: cores, spawns, towers and lanes are on walkable ground" % title, grounded)
		check("%s: outside is clamped back in" % title, Tune.walkable(Tune.clamp_to_map(Vector3(half.x + 30.0, 0, half.y + 30.0))))
		for p: Vector3 in m["blocked"]:
			check("%s: forest is blocked and clamps to walkable" % title, not Tune.walkable(p) and Tune.walkable(Tune.clamp_to_map(p)), str(p))
		# Routes between scattered points must stay on walkable ground and arrive.
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		var spots: Array = m["cores"] + m["spawns"]
		for i in 14:
			spots.append(Tune.clamp_to_map(Vector3(rng.randf_range(-half.x, half.x), 0, rng.randf_range(-half.y, half.y))))
		var ok := true
		var legs := 0
		for from: Vector3 in spots:
			for to: Vector3 in spots:
				var at := from
				var path: Array = Tune.route(from, to)
				for p: Vector3 in path:
					ok = ok and Tune.line_clear(at, p) and Tune.walkable(p)
					at = p
				ok = ok and at.distance_to(to) < 0.01
				legs = maxi(legs, path.size())
		check("%s: routes stay walkable and arrive" % title, ok, "longest route %d legs" % legs)
	Tune.map_index = active


func _finish(tree: SceneTree) -> void:
	print("SELFTEST RESULT: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	await tree.create_timer(2.5).timeout
	tree.quit(0 if _fails == 0 else 1)
