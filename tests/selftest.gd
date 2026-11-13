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
	var dummy: Unit = m.host_spawn("minion", 1 - hero.team, hero.position + Vector3(Tune.side(hero.team) * 4.0, 0, 0))
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
	check("structures spawned", kinds.get("tower", 0) == 2 and kinds.get("core", 0) == 2, str(kinds))

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

	# Core is protected by its tower, and killing the core ends the match.
	var core: Unit = null
	var tower: Unit = null
	for u in m.units.get_children():
		if u.team == b.team and u.kind == "core":
			core = u
		if u.team == b.team and u.kind == "tower":
			tower = u
	check("core untargetable while tower stands", not core.targetable())
	m.deal_damage(a, tower, 99999.0)
	await tree.process_frame
	await tree.process_frame
	check("core targetable after tower falls", core.targetable())
	m.deal_damage(a, core, 99999.0)
	check("match over, host team wins", m.over and m.winner == a.team)
	await _finish(tree)


func _finish(tree: SceneTree) -> void:
	print("SELFTEST RESULT: %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	await tree.create_timer(2.5).timeout
	tree.quit(0 if _fails == 0 else 1)
