extends Node
## Every balance and yell constant lives here, plus the map definitions and
## the walkability / routing helpers that read them.

const MAX_PLAYERS := 6
const DEV_PORT := 24565
const LOBBY_TAG := "yellmoba"

# --- Yell damage -----------------------------------------------------------
const YELL_DB_MIN := -40.0   # at or below this loudness: 1.0x
const YELL_DB_MAX := -6.0    # at or above this loudness: YELL_MULT_MAX
const YELL_MULT_MAX := 2.0
const YELL_WINDOW_MS := 300  # "moment of hit" = loudest voice in this window
const HEAR_RANGE := 24.0     # proximity voice cut-off, world units

# --- Maps --------------------------------------------------------------------
const BASE_DEPTH := 13.0     # paved base strip at each end of the single lane

## Built in _init. Each map is a Dictionary:
##   rects   walkable Rect2s in (x, z)
##   paths   walkable thick polylines: {pts, half, kind = lane | jungle | river}
##   bases   one Rect2 per team (drawn in team colours)
##   lanes   minion routes, each a polyline from team 0's side to team 1's
##   river   {pts, half} for drawing
##   cores / spawns   one position per team
##   towers  {team, lane, tier, pos}; tier 0 is the outer tower
##   nodes   junctions used to route around blocked ground
##   blocked sample points that must not be walkable (for the selftest)
var maps := []
var map_index := 0:          # set by Net.begin_match on every peer
	set(value):
		map_index = clampi(value, 0, maxi(maps.size() - 1, 0))
		_cache_map()

var _rects := []             # Rect2
var _segs := []              # [Vector2 a, Vector2 b, float half width]
var _nodes := []             # Vector3
var _links := []             # per node: [[other node index, distance], ...]

# --- Heroes ------------------------------------------------------------------
const HERO_REGEN := 4.0
const HERO_RESPAWN := 8.0

## Ability types: shot (line projectile), slam (damage around self),
## dash (leap to a point, damage on landing), blink (teleport),
## heal (restore allies around self). All damage and healing is yell-scaled.
const HEROES := [
	{
		"name": "Roarer", "role": "Ranged all-rounder", "shape": "caster",
		"hp": 600.0, "speed": 7.0, "range": 6.5, "atk_cd": 0.8, "dmg": 50.0,
		"accent": Color(1.0, 0.75, 0.2),
		"q": {"name": "Sonic Bolt", "type": "shot", "cd": 5.0, "dmg": 110.0, "range": 14.0, "speed": 26.0, "radius": 0.9},
		"w": {"name": "Shockwave", "type": "slam", "cd": 8.0, "dmg": 90.0, "radius": 4.0},
	},
	{
		"name": "Bruiser", "role": "Melee tank", "shape": "tank",
		"hp": 900.0, "speed": 7.5, "range": 2.2, "atk_cd": 0.7, "dmg": 60.0,
		"accent": Color(0.75, 0.75, 0.8),
		"q": {"name": "Leap", "type": "dash", "cd": 7.0, "dmg": 80.0, "range": 9.0, "radius": 2.8},
		"w": {"name": "Ground Pound", "type": "slam", "cd": 6.0, "dmg": 110.0, "radius": 4.5},
	},
	{
		"name": "Longshot", "role": "Fragile sniper", "shape": "sniper",
		"hp": 450.0, "speed": 6.5, "range": 9.5, "atk_cd": 1.1, "dmg": 65.0,
		"accent": Color(0.6, 1.0, 0.5),
		"q": {"name": "Piercing Cry", "type": "shot", "cd": 7.0, "dmg": 160.0, "range": 24.0, "speed": 42.0, "radius": 0.7},
		"w": {"name": "Blink", "type": "blink", "cd": 9.0, "range": 8.0},
	},
	{
		"name": "Chanter", "role": "Healer", "shape": "healer",
		"hp": 550.0, "speed": 7.0, "range": 6.0, "atk_cd": 0.9, "dmg": 40.0,
		"accent": Color(0.5, 1.0, 0.9),
		"q": {"name": "Hymn Bolt", "type": "shot", "cd": 5.0, "dmg": 90.0, "range": 13.0, "speed": 24.0, "radius": 0.9},
		"w": {"name": "Mending Chorus", "type": "heal", "cd": 10.0, "amount": 120.0, "radius": 5.5},
	},
]


func hero_def(index: int) -> Dictionary:
	return HEROES[clampi(index, 0, HEROES.size() - 1)]

# --- Minions / structures ------------------------------------------------------
const WAVE_INTERVAL := 20.0
const WAVE_SIZE := 3
const MINION_HP := 150.0
const MINION_SPEED := 3.5
const MINION_DMG := 12.0
const MINION_CD := 1.0
const MINION_RANGE := 1.6
const MINION_AGGRO := 7.0
const TOWER_HP := 800.0
const TOWER_RANGE := 9.0
const TOWER_DMG := 45.0
const TOWER_CD := 1.0
const CORE_HP := 1500.0


func _init() -> void:
	maps = [_single_lane(), _three_lanes()]
	_cache_map()


func yell_multiplier(db: float) -> float:
	var t := clampf(inverse_lerp(YELL_DB_MIN, YELL_DB_MAX, db), 0.0, 1.0)
	return lerpf(1.0, YELL_MULT_MAX, t)


# --- Map definitions ------------------------------------------------------------

static func _v(x: float, z: float) -> Vector3:
	return Vector3(x, 0.0, z)


## One straight lane along X with a base at each end.
func _single_lane() -> Dictionary:
	return {
		"name": "Single Lane", "style": "straight", "half_len": 44.0, "half_wid": 10.0,
		"rects": [Rect2(-44, -10, 88, 20)],
		"paths": [],
		"bases": [Rect2(-44, -10, BASE_DEPTH, 20), Rect2(44 - BASE_DEPTH, -10, BASE_DEPTH, 20)],
		"lanes": [[_v(-25, 0), _v(25, 0)]],
		"river": {"pts": [_v(0, -10), _v(0, 10)], "half": 3.0},
		"cores": [_v(-36, 0), _v(36, 0)],
		"spawns": [_v(-42, 0), _v(42, 0)],
		"towers": [
			{"team": 0, "lane": 0, "tier": 0, "pos": _v(-22, 0)},
			{"team": 1, "lane": 0, "tier": 0, "pos": _v(22, 0)},
		],
		"nodes": [],
		"blocked": [],
	}


## Square map with the bases in opposite corners (team 0 bottom-left, team 1
## top-right). Two side lanes hug the edges, the middle lane runs corner to
## corner, a river crosses on the other diagonal and jungle paths link the
## lanes in between. The layout is point-symmetric about the centre.
func _three_lanes() -> Dictionary:
	var top := [_v(-40, 26), _v(-40, -40), _v(26, -40)]
	var mid := [_v(-28, 28), _v(28, -28)]
	var bot := [_v(-26, 40), _v(40, 40), _v(40, -26)]
	var river := [_v(-40, -40), _v(40, 40)]
	var paths := [
		{"pts": top, "half": 5.0, "kind": "lane"},
		{"pts": mid, "half": 5.0, "kind": "lane"},
		{"pts": bot, "half": 5.0, "kind": "lane"},
		{"pts": river, "half": 4.0, "kind": "river"},
	]
	# Jungle paths from the middle of each side-lane leg to the middle lane.
	var jungle := [[_v(-40, -8), _v(-14, 14)], [_v(8, 40), _v(-14, 14)]]
	var nodes := [_v(0, 0), _v(-40, -40), _v(40, 40)]
	for team_sign in [1.0, -1.0]:
		for j in jungle:
			paths.append({"pts": [j[0] * team_sign, j[1] * team_sign], "half": 3.0, "kind": "jungle"})
			nodes.append(j[0] * team_sign)
		nodes.append(jungle[0][1] * team_sign)
		for start in [top[0], mid[0], bot[0]]:
			nodes.append(start * team_sign)
	# Team 0's towers, set just off the centre of each lane; team 1 mirrors them.
	var towers := []
	var blue := [
		[0, 1, _v(-42.5, 12)], [0, 0, _v(-42.5, -16)],
		[1, 1, _v(-17.2, 20.8)], [1, 0, _v(-7.2, 10.8)],
		[2, 1, _v(-12, 42.5)], [2, 0, _v(16, 42.5)],
	]
	for t in blue:
		towers.append({"team": 0, "lane": t[0], "tier": t[1], "pos": t[2]})
		towers.append({"team": 1, "lane": 2 - t[0], "tier": t[1], "pos": -t[2]})
	var bases := [Rect2(-50, 24, 26, 26), Rect2(24, -50, 26, 26)]
	return {
		"name": "Three Lanes", "style": "square", "half_len": 50.0, "half_wid": 50.0,
		"rects": bases,
		"paths": paths,
		"bases": bases,
		"lanes": [top, mid, bot],
		"river": {"pts": river, "half": 4.0},
		"cores": [_v(-40, 40), _v(40, -40)],
		"spawns": [_v(-46, 46), _v(46, -46)],
		"towers": towers,
		"nodes": nodes,
		"blocked": [_v(-25, -12), _v(25, 12), _v(-5, -25)],
	}


# --- Map geometry -------------------------------------------------------------

func map() -> Dictionary:
	return maps[map_index]


func _cache_map() -> void:
	if maps.is_empty():
		return
	var m := map()
	_rects = m["rects"]
	_segs = []
	for path: Dictionary in m["paths"]:
		var pts: Array = path["pts"]
		for i in pts.size() - 1:
			_segs.append([Vector2(pts[i].x, pts[i].z), Vector2(pts[i + 1].x, pts[i + 1].z), path["half"]])
	_nodes = m["nodes"]
	_links = []
	for i in _nodes.size():
		var links := []
		for j in _nodes.size():
			if i != j and line_clear(_nodes[i], _nodes[j]):
				links.append([j, _nodes[i].distance_to(_nodes[j])])
		_links.append(links)


## Unit direction from a team's core toward the enemy core.
func forward(team: int) -> Vector3:
	var cores: Array = map()["cores"]
	return (cores[1 - team] - cores[team]).normalized()


func walkable(p: Vector3, eps := 0.02) -> bool:
	var q := Vector2(p.x, p.z)
	for r: Rect2 in _rects:
		if q.x >= r.position.x - eps and q.x <= r.end.x + eps and q.y >= r.position.y - eps and q.y <= r.end.y + eps:
			return true
	for s: Array in _segs:
		if Geometry2D.get_closest_point_to_segment(q, s[0], s[1]).distance_to(q) <= s[2] + eps:
			return true
	return false


## Nearest walkable point on the ground.
func clamp_to_map(p: Vector3) -> Vector3:
	if walkable(p, 0.0):
		return Vector3(p.x, 0.0, p.z)
	var q := Vector2(p.x, p.z)
	var best := q
	var best_d := INF
	for r: Rect2 in _rects:
		var c := Vector2(clampf(q.x, r.position.x, r.end.x), clampf(q.y, r.position.y, r.end.y))
		if c.distance_squared_to(q) < best_d:
			best = c
			best_d = c.distance_squared_to(q)
	for s: Array in _segs:
		var on: Vector2 = Geometry2D.get_closest_point_to_segment(q, s[0], s[1])
		var c: Vector2 = on + (q - on).normalized() * s[2]
		if c.distance_squared_to(q) < best_d:
			best = c
			best_d = c.distance_squared_to(q)
	return Vector3(best.x, 0.0, best.y)


## Distance from a point to the nearest walkable ground (0 when on it).
func clearance(p: Vector3) -> float:
	return Vector2(p.x, p.z).distance_to(Vector2(clamp_to_map(p).x, clamp_to_map(p).z))


## Distance on the ground from a point to a polyline.
func path_dist(p: Vector3, pts: Array) -> float:
	var q := Vector2(p.x, p.z)
	var best := INF
	for i in pts.size() - 1:
		var on := Geometry2D.get_closest_point_to_segment(q, Vector2(pts[i].x, pts[i].z), Vector2(pts[i + 1].x, pts[i + 1].z))
		best = minf(best, on.distance_to(q))
	return best


func nearest_lane(p: Vector3) -> int:
	var lanes: Array = map()["lanes"]
	var best := 0
	for i in lanes.size():
		if path_dist(p, lanes[i]) < path_dist(p, lanes[best]):
			best = i
	return best


func line_clear(a: Vector3, b: Vector3) -> bool:
	var steps := int(ceil(a.distance_to(b)))
	for i in range(1, steps):
		if not walkable(a.lerp(b, float(i) / steps), 0.1):
			return false
	return true


## Waypoints for walking from one walkable point to another: straight there
## when nothing is in the way, otherwise the shortest way through the map's
## junction nodes, with any corner that can be cut removed.
func route(from: Vector3, to: Vector3) -> Array:
	to = clamp_to_map(to)
	from = Vector3(from.x, 0.0, from.z)
	if _nodes.is_empty() or line_clear(from, to):
		return [to]
	var count := _nodes.size()
	var dist := []
	var prev := []
	var done := []
	var exit_cost := []
	for i in count:
		var node: Vector3 = _nodes[i]
		dist.append(from.distance_to(node) if line_clear(from, node) else INF)
		exit_cost.append(node.distance_to(to) if line_clear(node, to) else INF)
		prev.append(-1)
		done.append(false)
	var last := -1
	var best_total := INF
	while true:
		var cur := -1
		var cur_d := INF
		for i in count:
			if not done[i] and dist[i] < cur_d:
				cur = i
				cur_d = dist[i]
		if cur == -1:
			break
		done[cur] = true
		if cur_d + exit_cost[cur] < best_total:
			best_total = cur_d + exit_cost[cur]
			last = cur
		for link: Array in _links[cur]:
			if cur_d + link[1] < dist[link[0]]:
				dist[link[0]] = cur_d + link[1]
				prev[link[0]] = cur
	if last == -1:
		return [to]
	var pts := [to]
	while last != -1:
		pts.push_front(_nodes[last])
		last = prev[last]
	pts.push_front(from)
	var k := 0
	while k + 2 < pts.size():
		if line_clear(pts[k], pts[k + 2]):
			pts.remove_at(k + 1)
		else:
			k += 1
	return pts.slice(1)


func team_color(team: int) -> Color:
	return Color(0.25, 0.55, 1.0) if team == 0 else Color(1.0, 0.32, 0.25)


func team_name(team: int) -> String:
	return "Blue" if team == 0 else "Red"
