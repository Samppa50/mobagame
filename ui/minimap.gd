extends Control
## Top-right minimap of the lane. Right- or left-click it to walk there.

const SCALE := 3.6     # pixels per world unit
const PAD := 6.0

var match_node: Node


func _ready() -> void:
	custom_minimum_size = Vector2(
		Tune.LANE_HALF_LEN * 2.0 * SCALE + PAD * 2.0,
		Tune.LANE_HALF_WID * 2.0 * SCALE + PAD * 2.0)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(_delta: float) -> void:
	queue_redraw()


func to_map(world: Vector3) -> Vector2:
	return Vector2(
		PAD + (world.x + Tune.LANE_HALF_LEN) * SCALE,
		PAD + (world.z + Tune.LANE_HALF_WID) * SCALE)


func to_world(point: Vector2) -> Vector3:
	return Vector3(
		(point.x - PAD) / SCALE - Tune.LANE_HALF_LEN, 0.0,
		(point.y - PAD) / SCALE - Tune.LANE_HALF_WID)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_LEFT):
		match_node.order_move(to_world(event.position))
		accept_event()


func _draw() -> void:
	var lane := Rect2(Vector2(PAD, PAD), size - Vector2(PAD, PAD) * 2.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08, 0.85))
	draw_rect(lane, Color(0.2, 0.3, 0.2))
	# Team bases, river and the path.
	var base_w := Tune.BASE_DEPTH * SCALE
	draw_rect(Rect2(lane.position, Vector2(base_w, lane.size.y)), Tune.team_color(0).darkened(0.55))
	draw_rect(Rect2(lane.position + Vector2(lane.size.x - base_w, 0), Vector2(base_w, lane.size.y)), Tune.team_color(1).darkened(0.55))
	var mid := lane.get_center()
	draw_rect(Rect2(lane.position.x, mid.y - 2.5 * SCALE, lane.size.x, 5.0 * SCALE), Color(0.42, 0.36, 0.26, 0.6))
	draw_rect(Rect2(mid.x - 3.0 * SCALE, lane.position.y, 6.0 * SCALE, lane.size.y), Color(0.2, 0.45, 0.7, 0.7))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.75, 0.8, 0.9), false, 2.0)

	if match_node == null or match_node.units == null:
		return
	var me = match_node.my_hero()
	# Draw small things first so heroes stay on top.
	for pass_kind in ["minion", "tower", "core", "hero"]:
		for u in match_node.units.get_children():
			if u.kind != pass_kind or u.dead:
				continue
			var p := to_map(u.position)
			var c := Tune.team_color(u.team)
			match pass_kind:
				"minion":
					draw_circle(p, 2.5, c)
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
		var view := Vector2(56.0, 30.0) * SCALE
		var centre := to_map(me.position)
		draw_rect(Rect2(centre - view * 0.5, view).intersection(Rect2(Vector2.ZERO, size)), Color(1, 1, 1, 0.5), false, 1.0)
