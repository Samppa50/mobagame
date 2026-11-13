extends Control
## Bottom-right minimap of the current map. Right- or left-click it to walk there.

const MAX_SIZE := Vector2(320, 230)  # pixels; the scale shrinks to fit bigger maps
const PAD := 6.0

var match_node: Node

var _scale := 3.6          # pixels per world unit
var _half := Vector2.ZERO  # map half extents (x, z)


func _ready() -> void:
	var m := Tune.map()
	_half = Vector2(m["half_len"], m["half_wid"])
	_scale = minf(3.6, minf(MAX_SIZE.x / (_half.x * 2.0), MAX_SIZE.y / (_half.y * 2.0)))
	custom_minimum_size = _half * 2.0 * _scale + Vector2(PAD, PAD) * 2.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func _process(_delta: float) -> void:
	queue_redraw()


func to_map(world: Vector3) -> Vector2:
	return Vector2(PAD, PAD) + (Vector2(world.x, world.z) + _half) * _scale


func to_world(point: Vector2) -> Vector3:
	var p := (point - Vector2(PAD, PAD)) / _scale - _half
	return Vector3(p.x, 0.0, p.y)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_LEFT):
		match_node.order_move(to_world(event.position))
		accept_event()


## A world-space (x, z) rectangle in minimap pixels.
func _px(r: Rect2) -> Rect2:
	return Rect2(Vector2(PAD, PAD) + (r.position + _half) * _scale, r.size * _scale)


## A thick world-space polyline with rounded joints.
func _strip(pts: Array, half: float, color: Color) -> void:
	for i in pts.size():
		draw_circle(to_map(pts[i]), half * _scale, color)
		if i > 0:
			draw_line(to_map(pts[i - 1]), to_map(pts[i]), color, half * 2.0 * _scale)


func _draw() -> void:
	var m := Tune.map()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08, 0.85))
	# Forest (blocked) underneath, walkable grass on top.
	draw_rect(_px(Rect2(-_half, _half * 2.0)), Color(0.07, 0.13, 0.08))
	var grass := Color(0.2, 0.3, 0.2)
	for r: Rect2 in m["rects"]:
		draw_rect(_px(r), grass)
	for path: Dictionary in m["paths"]:
		_strip(path["pts"], path["half"], grass)
	# The lane paths, the river and the team bases.
	for lane: Array in m["lanes"]:
		_strip(lane, 2.2, Color(0.42, 0.36, 0.26))
	var river: Dictionary = m["river"]
	draw_line(to_map(river["pts"][0]), to_map(river["pts"][1]), Color(0.2, 0.45, 0.7, 0.75), river["half"] * 2.0 * _scale)
	for team in 2:
		draw_rect(_px(m["bases"][team]), Tune.team_color(team).darkened(0.55))
	# Fog of war: everything dimmed, then lifted where the team can see.
	if match_node != null and not match_node.over:
		draw_rect(_px(Rect2(-_half, _half * 2.0)), Color(0, 0, 0, 0.4))
		for eye in match_node.vision:
			draw_circle(to_map(Vector3(eye.x, 0, eye.y)), eye.z * _scale, Color(1, 1, 1, 0.06))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.75, 0.8, 0.9), false, 2.0)

	if match_node == null or match_node.units == null:
		return
	var me = match_node.my_hero()
	# Draw small things first so heroes stay on top.
	for pass_kind in ["minion", "monster", "tower", "core", "hero"]:
		for u in match_node.units.get_children():
			if u.kind != pass_kind or u.dead or u.fogged:
				continue
			var p := to_map(u.position)
			var c := Tune.team_color(u.team)
			match pass_kind:
				"minion":
					draw_circle(p, 2.5, c)
				"monster":
					draw_circle(p, 2.2 + u.radius * 2.0, Color.BLACK)
					draw_circle(p, 1.2 + u.radius * 2.0, c)
				"tower":
					draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), c)
					draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), Color.BLACK, false, 1.5)
				"core":
					draw_circle(p, 9.0, Color.BLACK)
					draw_circle(p, 7.5, c.lightened(0.2))
				"hero":
					draw_circle(p, 6.5, Color.WHITE if u == me else Color.BLACK)
					draw_circle(p, 5.0, c.lightened(0.15))
	# Where the main camera is looking.
	if me != null:
		var view := Vector2(56.0, 30.0) * _scale
		var centre := to_map(me.position)
		draw_rect(Rect2(centre - view * 0.5, view).intersection(Rect2(Vector2.ZERO, size)), Color(1, 1, 1, 0.5), false, 1.0)
