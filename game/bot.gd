class_name BotBrain
extends RefCounted
## Host-side AI for a bot's hero. A few times a second it decides what the
## hero should be doing and gives it the same orders a player would:
##   - shop whenever the shop is open (it follows the hero's "build")
##   - go home when badly hurt, or when it can afford its next item
##   - back off from an enemy tower that has no allied minions to shoot at
##   - otherwise fight what is nearby, or walk its lane with the minion wave
## Bots only react to what is within AWARE of them, never to the whole map.

const THINK := 0.25       # seconds between decisions
const AWARE := 12.0       # how far a bot notices enemies
const HURT := 0.3         # health share that sends it home
const HEALED := 0.85      # health share that lets it leave again

var _wait := randf() * THINK
var _lane := -1
var _home := false        # heading back to the fountain
var _goal := Vector3.INF  # last point it was told to walk to


func tick(hero: Hero, delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = THINK
	_shop(hero)
	if hero.dead:
		_home = false
		_goal = Vector3.INF
		return
	var units: Array = hero.get_parent().get_children()
	if _lane < 0:
		_lane = _pick_lane(hero, units)

	# What is around.
	var foes := []            # enemies worth reacting to, within AWARE
	var danger := []          # enemy towers that would shoot this hero
	for u: Unit in units:
		if u.dead or u.team == hero.team or u.is_queued_for_deletion():
			continue
		if u.kind == "tower" and not _has_minions_near(u, hero.team, units):
			danger.append(u)
		if hero.flat_dist(u) > AWARE + u.radius or not u.targetable():
			continue
		# A monster only matters once it has picked a fight with this hero.
		if u.kind != "monster" or u._foe == hero:
			foes.append(u)

	_support(hero, units)
	var health := hero.hp / hero.max_hp
	if not _home and (health < HURT or (hero.gold >= _next_cost(hero) + 200 and not _any_hero(foes))):
		_home = true
	if _home:
		if health >= HEALED and hero.gold < _next_cost(hero):
			_home = false
		else:
			_go_home(hero, foes)
			return

	var pts := _lane_points(hero)
	if _in_danger(hero.position, hero, danger):
		_walk(hero, _point_at(pts, _progress(pts, hero.position) - 7.0))
		return

	var target := _pick_target(hero, foes, danger, health)
	if target != null:
		_attack_with_abilities(hero, target, foes, danger, health)
		hero.host_attack(target)
		_goal = Vector3.INF
		return
	_walk(hero, _lane_goal(hero, pts, units, danger))


# --- Shopping ----------------------------------------------------------------------

func _next_cost(hero: Hero) -> float:
	var build: Array = hero.def["build"]
	if hero.items.size() >= mini(build.size(), Tune.ITEM_SLOTS):
		return INF
	return Tune.ITEMS[build[hero.items.size()]]["cost"]


func _shop(hero: Hero) -> void:
	while hero.can_shop() and hero.gold >= _next_cost(hero):
		hero.host_buy(hero.def["build"][hero.items.size()])


# --- Fighting ----------------------------------------------------------------------

func _any_hero(list: Array) -> bool:
	for u: Unit in list:
		if u.kind == "hero":
			return true
	return false


func _has_minions_near(tower: Unit, team: int, units: Array) -> bool:
	for u: Unit in units:
		if u.kind == "minion" and u.team == team and not u.dead and tower.flat_dist(u) <= Tune.TOWER_RANGE:
			return true
	return false


func _in_danger(point: Vector3, hero: Hero, danger: Array, slack := 1.0) -> bool:
	for tower: Unit in danger:
		if Vector2(point.x - tower.position.x, point.z - tower.position.z).length() <= Tune.TOWER_RANGE + hero.radius + slack:
			return true
	return false


## The most attractive enemy nearby that can be attacked without standing
## under a tower: heroes first, then minions about to die, then structures.
func _pick_target(hero: Hero, foes: Array, danger: Array, health: float) -> Unit:
	# A long-range hero can hit things a little way inside a tower's reach.
	var reach: float = maxf(0.0, hero.def["range"] - 3.0) * 0.5
	var best: Unit = null
	var best_score := -INF
	for u: Unit in foes:
		if danger.has(u) or _in_danger(u.position, hero, danger, 0.5 - reach):
			continue
		var score := -hero.flat_dist(u)
		match u.kind:
			"hero":
				if health < 0.4 and u.hp / u.max_hp > health:
					continue  # losing: leave it
				score += 6.0 + (4.0 if u.hp / u.max_hp < 0.4 else 0.0)
			"minion":
				score += 2.0 + (8.0 if u.hp <= hero.atk_dmg * 1.1 else 0.0)
			"monster":
				score += 3.0
			_:
				score += 5.0
		if score > best_score:
			best = u
			best_score = score
	return best


func _attack_with_abilities(hero: Hero, target: Unit, foes: Array, danger: Array, health: float) -> void:
	var dist := hero.flat_dist(target)
	for slot in Tune.SLOTS.size():
		if not hero.can_cast(slot):
			continue
		var spec := hero.ability(slot)
		match spec["type"]:
			"shot", "volley":
				if dist <= spec["range"] * 0.85 + target.radius:
					hero.host_cast(slot, target.position)
					return
			"slam":
				var caught := 0
				for u: Unit in foes:
					if hero.flat_dist(u) <= spec["radius"] + u.radius:
						caught += 2 if u.kind == "hero" else 1
				if caught >= 2:
					hero.host_cast(slot, hero.position)
					return
			"drain":
				# Worth it against a hero, or to recover in the middle of a wave.
				var near := 0
				for u: Unit in foes:
					if hero.flat_dist(u) <= spec["radius"] + u.radius:
						near += 3 if u.kind == "hero" else 1
				if near >= 3 and health < 0.75:
					hero.host_cast(slot, hero.position)
					return
			"blast":
				if dist <= spec["range"] + spec["radius"] * 0.5:
					hero.host_cast(slot, target.position)
					return
			"buff":
				# Saved for real fights: an enemy hero, or a structure being pushed.
				if (target.kind == "hero" or target.solid) and dist <= hero.def["range"] + 4.0:
					hero.host_cast(slot, hero.position)
					return
			"dash":
				if target.solid or dist < 3.0 or dist > spec["range"] or _in_danger(target.position, hero, danger):
					continue
				if target.kind != "hero" or health > 0.5:
					hero.host_cast(slot, target.position)
					return


## Heal when an allied hero in reach (or the bot itself) needs it.
func _support(hero: Hero, units: Array) -> void:
	for slot in Tune.SLOTS.size():
		var spec := hero.ability(slot)
		if spec["type"] != "heal" or not hero.can_cast(slot):
			continue
		for u: Unit in units:
			if u.kind == "hero" and u.team == hero.team and not u.dead \
					and hero.flat_dist(u) <= spec["radius"] and u.hp / u.max_hp < (0.65 if spec["amount"] < 200.0 else 0.45):
				hero.host_cast(slot, hero.position)
				return


## Walk to the fountain, jumping away first if an enemy hero is on top of us.
func _go_home(hero: Hero, foes: Array) -> void:
	var fountain: Vector3 = Tune.map()["spawns"][hero.team]
	if _any_hero(foes):
		for slot in Tune.SLOTS.size():
			var spec := hero.ability(slot)
			if spec["type"] in ["blink", "dash"] and hero.can_cast(slot):
				var way: Array = Tune.route(hero.position, fountain)
				hero.host_cast(slot, hero.position + (way[0] - hero.position).normalized() * spec["range"])
				_goal = Vector3.INF
				break
	_walk(hero, fountain)


# --- Laning ------------------------------------------------------------------------

## Bots on a team spread over the lanes, middle first.
func _pick_lane(hero: Hero, units: Array) -> int:
	var slot := 0
	for u: Unit in units:
		if u == hero:
			break
		if u.kind == "hero" and u.team == hero.team and u.peer_id < 0:
			slot += 1
	var count: int = Tune.map()["lanes"].size()
	var order := [1, 0, 2] if count == 3 else range(count)
	return order[slot % count]


## The bot's lane from its own end to the enemy core.
func _lane_points(hero: Hero) -> Array:
	var m := Tune.map()
	var pts: Array = m["lanes"][_lane].duplicate()
	if hero.team == 1:
		pts.reverse()
	pts.append(m["cores"][1 - hero.team])
	return pts


## How far along a polyline (from its start) the nearest point to pos is.
func _progress(pts: Array, pos: Vector3) -> float:
	var q := Vector2(pos.x, pos.z)
	var best := INF
	var out := 0.0
	var run := 0.0
	for i in pts.size() - 1:
		var a := Vector2(pts[i].x, pts[i].z)
		var b := Vector2(pts[i + 1].x, pts[i + 1].z)
		var on := Geometry2D.get_closest_point_to_segment(q, a, b)
		if on.distance_to(q) < best:
			best = on.distance_to(q)
			out = run + a.distance_to(on)
		run += a.distance_to(b)
	return out


func _point_at(pts: Array, progress: float) -> Vector3:
	var left := maxf(progress, 0.0)
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var length := a.distance_to(b)
		if left <= length:
			return a.lerp(b, left / length)
		left -= length
	return pts[-1]


## Where to stand when there is nothing to fight: just behind the front of
## the allied wave, and never further back than just outside the reach of the
## next enemy tower (or the enemy core, once the lane's towers are gone).
func _lane_goal(hero: Hero, pts: Array, units: Array, danger: Array) -> Vector3:
	var front := -INF
	var next_tower := INF
	for u: Unit in units:
		if u.dead or u.lane != _lane:
			continue
		if u.kind == "minion" and u.team == hero.team:
			front = maxf(front, _progress(pts, u.position))
		elif u.kind == "tower" and u.team != hero.team:
			next_tower = minf(next_tower, _progress(pts, u.position))
	var total := _progress(pts, pts[-1])
	var wait := total - 5.0 if next_tower == INF else next_tower - Tune.TOWER_RANGE - 3.0
	var want := maxf(wait, front - minf(hero.def["range"] * 0.6, 4.0))
	# Never plan to stand under a tower that would shoot.
	for i in 12:
		if not _in_danger(_point_at(pts, want), hero, danger, 1.5):
			break
		want -= 2.0
	return _point_at(pts, want)


func _walk(hero: Hero, point: Vector3) -> void:
	if Vector2(hero.position.x - point.x, hero.position.z - point.z).length() < 1.5:
		return
	if _goal.distance_to(point) > 1.0 or hero.idle():
		_goal = point
		hero.host_move(point)
