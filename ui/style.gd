extends RefCounted
## Shared look of the menu screens (main menu and lobby): one Theme built in
## code, the animated backdrop and the drawn hero portraits. The in-match HUD
## keeps its own compact styling.
## Used through preload, so no class_name (and no re-import) is needed.

const BG_TOP := Color(0.04, 0.05, 0.1)
const BG_BOTTOM := Color(0.12, 0.07, 0.17)
const PANEL := Color(0.07, 0.08, 0.13, 0.9)
const INSET := Color(0.04, 0.05, 0.08, 0.9)
const EDGE := Color(0.24, 0.27, 0.37)
const ACCENT := Color(1.0, 0.75, 0.2)
const TEXT := Color(0.93, 0.94, 0.98)
const DIM := Color(0.62, 0.66, 0.77)


static func box(bg: Color, border: Color, radius := 8, margin := 10.0, border_width := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	return s


## The theme set on the root Control of each menu screen.
static func theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 15
	t.set_color("font_color", "Label", TEXT)

	var normal := box(Color(0.14, 0.16, 0.23), EDGE, 6, 8.0)
	normal.content_margin_left = 16.0
	normal.content_margin_right = 16.0
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.2, 0.23, 0.33)
	hover.border_color = ACCENT.darkened(0.25)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.3, 0.24, 0.1)
	pressed.border_color = ACCENT
	pressed.set_border_width_all(2)
	var disabled: StyleBoxFlat = normal.duplicate()
	disabled.bg_color = Color(0.1, 0.11, 0.15, 0.7)
	disabled.border_color = Color(0.18, 0.2, 0.26)
	for kind in ["Button", "CheckBox"]:
		t.set_color("font_color", kind, TEXT)
		t.set_color("font_hover_color", kind, Color.WHITE)
		t.set_color("font_pressed_color", kind, ACCENT.lightened(0.3))
		t.set_color("font_hover_pressed_color", kind, ACCENT.lightened(0.4))
		t.set_color("font_disabled_color", kind, Color(0.45, 0.48, 0.56))
		t.set_stylebox("focus", kind, StyleBoxEmpty.new())
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)

	t.set_stylebox("panel", "PanelContainer", box(PANEL, EDGE, 10, 16.0))

	var field := box(INSET, EDGE, 6, 8.0)
	var field_focus: StyleBoxFlat = field.duplicate()
	field_focus.border_color = ACCENT.darkened(0.2)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", field_focus)
	t.set_color("font_placeholder_color", "LineEdit", Color(0.4, 0.43, 0.52))
	t.set_stylebox("panel", "ItemList", field)
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("hovered", "ItemList", box(Color(0.16, 0.18, 0.26), Color.TRANSPARENT, 4, 2.0, 0))
	t.set_stylebox("selected", "ItemList", box(Color(0.3, 0.24, 0.1), Color.TRANSPARENT, 4, 2.0, 0))
	t.set_stylebox("selected_focus", "ItemList", box(Color(0.3, 0.24, 0.1), Color.TRANSPARENT, 4, 2.0, 0))

	t.set_stylebox("background", "ProgressBar", box(INSET, EDGE, 4, 0.0))
	t.set_stylebox("fill", "ProgressBar", box(ACCENT, Color.TRANSPARENT, 4, 0.0, 0))

	var line := StyleBoxLine.new()
	line.color = EDGE
	t.set_stylebox("separator", "HSeparator", line)
	return t


static func label(text: String, font_size := 15, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A small all-caps caption above a group of controls.
static func heading(text: String) -> Label:
	return label(text.to_upper(), 12, DIM)


## The button a screen wants pressed: filled with the accent colour.
static func primary(button: Button, color := ACCENT) -> void:
	var normal := box(color.darkened(0.25), color, 6, 10.0)
	normal.content_margin_left = 24.0
	normal.content_margin_right = 24.0
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = color.darkened(0.05)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = color.darkened(0.4)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	for key in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(key, Color(0.08, 0.06, 0.02))


## Full-screen background: a dusk gradient with a slow equaliser along the
## bottom edge. Its bars jump with the player's own voice.
class Backdrop extends Control:
	const BARS := 56
	var _t := 0.0
	var _loud := 0.0

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_t += delta
		var heard := clampf((Voice.my_multiplier() - 1.0) / (Tune.YELL_MULT_MAX - 1.0), 0.0, 1.0)
		_loud = lerpf(_loud, heard, minf(1.0, delta * 8.0))
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_polygon(
			PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
			PackedColorArray([BG_TOP, BG_TOP, BG_BOTTOM, BG_BOTTOM]))
		# A faint glow of each team's colour in the lower corners.
		for team in 2:
			var c := Tune.team_color(team)
			var x := 0.0 if team == 0 else w
			var inner := w * (0.42 if team == 0 else 0.58)
			draw_polygon(
				PackedVector2Array([Vector2(x, h * 0.25), Vector2(inner, h), Vector2(x, h)]),
				PackedColorArray([Color(c, 0.0), Color(c, 0.0), Color(c, 0.2)]))
		var step := w / BARS
		for i in BARS:
			var wave := 0.5 + 0.5 * sin(_t * 1.3 + i * 0.45) * sin(_t * 0.7 + i * 0.17)
			var tall := h * (0.03 + 0.1 * wave + 0.2 * _loud * (0.4 + 0.6 * absf(sin(_t * 9.0 + i * 1.9))))
			var mix := float(i) / (BARS - 1)
			var c := Tune.team_color(0).lerp(Tune.team_color(1), mix).lerp(ACCENT, _loud * 0.6)
			draw_rect(Rect2(i * step + step * 0.2, h - tall, step * 0.6, tall), Color(c, 0.22 + 0.3 * _loud))


## A hero drawn from flat shapes, echoing its 3D silhouette: body in a team
## (or neutral) colour, gear in the hero's accent colour.
class Portrait extends Control:
	var hero := 0:
		set(value):
			hero = value
			queue_redraw()
	var body := Color(0.72, 0.76, 0.86):
		set(value):
			body = value
			queue_redraw()

	func _init(index := 0, side := 48.0) -> void:
		hero = index
		custom_minimum_size = Vector2(side, side)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## Everything below is drawn in a 0..1 square, scaled to the control.
	func _p(x: float, y: float) -> Vector2:
		var s := minf(size.x, size.y)
		return (size - Vector2(s, s)) * 0.5 + Vector2(x, y) * s

	func _poly(points: Array, color: Color) -> void:
		var pts := PackedVector2Array()
		for p: Vector2 in points:
			pts.append(_p(p.x, p.y))
		draw_colored_polygon(pts, color)

	func _draw() -> void:
		var s := minf(size.x, size.y)
		var d := Tune.hero_def(hero)
		var accent: Color = d["accent"]
		var head := body.lightened(0.25)
		draw_circle(_p(0.5, 0.5), s * 0.5, Color(accent, 0.16))
		draw_arc(_p(0.5, 0.5), s * 0.48, 0.0, TAU, 40, Color(accent, 0.7), maxf(1.0, s * 0.03), true)
		match d["shape"]:
			"tank":
				_poly([Vector2(0.3, 0.42), Vector2(0.7, 0.42), Vector2(0.74, 0.88), Vector2(0.26, 0.88)], body)
				draw_circle(_p(0.5, 0.3), s * 0.11, head)
				_poly([Vector2(0.16, 0.42), Vector2(0.84, 0.42), Vector2(0.84, 0.53), Vector2(0.16, 0.53)], accent)
				draw_circle(_p(0.17, 0.68), s * 0.1, accent)
				draw_circle(_p(0.83, 0.68), s * 0.1, accent)
			"sniper":
				_poly([Vector2(0.4, 0.4), Vector2(0.58, 0.4), Vector2(0.6, 0.9), Vector2(0.38, 0.9)], body)
				draw_circle(_p(0.49, 0.3), s * 0.1, head)
				_poly([Vector2(0.49, 0.08), Vector2(0.63, 0.27), Vector2(0.35, 0.27)], accent)
				draw_line(_p(0.3, 0.62), _p(0.9, 0.44), accent, s * 0.06, true)
			"healer":
				_poly([Vector2(0.38, 0.42), Vector2(0.62, 0.42), Vector2(0.76, 0.9), Vector2(0.24, 0.9)], body)
				_poly([Vector2(0.33, 0.68), Vector2(0.67, 0.68), Vector2(0.76, 0.9), Vector2(0.24, 0.9)], accent.darkened(0.2))
				draw_circle(_p(0.5, 0.34), s * 0.11, head)
				draw_arc(_p(0.5, 0.15), s * 0.13, 0.0, TAU, 24, accent, s * 0.045, true)
			"skirmisher":
				_poly([Vector2(0.38, 0.46), Vector2(0.62, 0.46), Vector2(0.66, 0.9), Vector2(0.34, 0.9)], body)
				draw_circle(_p(0.5, 0.36), s * 0.11, head)
				_poly([Vector2(0.38, 0.3), Vector2(0.4, 0.12), Vector2(0.48, 0.26)], accent)
				_poly([Vector2(0.62, 0.3), Vector2(0.6, 0.12), Vector2(0.52, 0.26)], accent)
				for side: float in [-1.0, 1.0]:
					for k in 3:
						var x := 0.5 + side * (0.26 + k * 0.06)
						draw_line(_p(x, 0.5), _p(x + side * 0.05, 0.76), accent, s * 0.035, true)
			"drummer":
				_poly([Vector2(0.38, 0.4), Vector2(0.62, 0.4), Vector2(0.66, 0.9), Vector2(0.34, 0.9)], body)
				draw_circle(_p(0.5, 0.28), s * 0.11, head)
				draw_circle(_p(0.5, 0.66), s * 0.2, accent)
				draw_circle(_p(0.5, 0.66), s * 0.14, Color(0.95, 0.92, 0.8))
				draw_line(_p(0.2, 0.36), _p(0.42, 0.6), accent.lightened(0.4), s * 0.04, true)
				draw_line(_p(0.8, 0.36), _p(0.58, 0.6), accent.lightened(0.4), s * 0.04, true)
			"warden":
				_poly([Vector2(0.34, 0.4), Vector2(0.66, 0.4), Vector2(0.7, 0.9), Vector2(0.3, 0.9)], body)
				draw_circle(_p(0.5, 0.28), s * 0.11, head)
				_poly([Vector2(0.47, 0.08), Vector2(0.53, 0.08), Vector2(0.53, 0.2), Vector2(0.47, 0.2)], accent)
				_poly([Vector2(0.3, 0.46), Vector2(0.7, 0.46), Vector2(0.7, 0.72), Vector2(0.5, 0.9), Vector2(0.3, 0.72)], accent)
				draw_circle(_p(0.5, 0.63), s * 0.06, accent.lightened(0.5))
			"wraith":
				_poly([Vector2(0.38, 0.44), Vector2(0.62, 0.44), Vector2(0.5, 0.94)], body)
				draw_circle(_p(0.5, 0.36), s * 0.1, head)
				_poly([Vector2(0.22, 0.42), Vector2(0.78, 0.42), Vector2(0.6, 0.54), Vector2(0.4, 0.54)], accent)
				draw_circle(_p(0.5, 0.13), s * 0.07, accent.lightened(0.3))
				draw_arc(_p(0.5, 0.13), s * 0.11, 0.0, TAU, 20, Color(accent, 0.5), s * 0.02, true)
			_:
				_poly([Vector2(0.36, 0.4), Vector2(0.6, 0.4), Vector2(0.64, 0.9), Vector2(0.32, 0.9)], body)
				draw_circle(_p(0.48, 0.28), s * 0.11, head)
				_poly([Vector2(0.56, 0.5), Vector2(0.86, 0.32), Vector2(0.86, 0.76), Vector2(0.56, 0.6)], accent)
				draw_line(_p(0.32, 0.66), _p(0.64, 0.66), accent, s * 0.04, true)
