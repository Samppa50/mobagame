extends Node
## Sound effects. There are no audio files: every sound is synthesised once at
## startup into an AudioStreamWAV. Match sounds are positional (heard from the
## local hero, see Match._listener); menu and reward sounds are not.
## Everything plays on its own "SFX" bus, so it can be turned down or muted
## without touching the voice chat.

const RATE := 22050
const VOLUME_DB := -6.0      # level of the SFX bus
const POOL_3D := 20          # most positional sounds playing at once
const POOL_UI := 6
const REPEAT_GAP_MS := 45    # the same sound is not started twice within this
const HEAR_RANGE := 45.0     # positional sounds fade out over this distance

var _streams := {}           # name -> AudioStreamWAV
var _last := {}              # name -> msec it was last started
var _world := []             # AudioStreamPlayer3D pool
var _flat := []              # AudioStreamPlayer pool


func _ready() -> void:
	if AudioServer.get_bus_index("SFX") == -1:
		AudioServer.add_bus()
		var bus := AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, "SFX")
		AudioServer.set_bus_volume_db(bus, VOLUME_DB)
	_build()
	# Every button in the game clicks, wherever it is created.
	get_tree().node_added.connect(_on_node_added)
	Net.match_starting.connect(play.bind("start"))


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		node.pressed.connect(play.bind("click"))
		node.mouse_entered.connect(_on_hover.bind(node))


func _on_hover(button: BaseButton) -> void:
	if not button.disabled:
		play("hover")


## Plays a sound at full volume wherever the camera is (menus, rewards).
func play(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	if not _due(sound):
		return
	var player: AudioStreamPlayer = null
	for p: AudioStreamPlayer in _flat:
		if not p.playing:
			player = p
			break
	if player == null:
		if _flat.size() >= POOL_UI:
			return
		player = AudioStreamPlayer.new()
		player.bus = "SFX"
		add_child(player)
		_flat.append(player)
	player.stream = _streams[sound]
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


## Plays a sound at a point in the match, slightly detuned so repeats do not
## sound mechanical. Dropped when every voice of the pool is busy.
func play_at(sound: String, pos: Vector3, volume_db := 0.0, pitch := 1.0) -> void:
	if not _due(sound):
		return
	var player: AudioStreamPlayer3D = null
	for p: AudioStreamPlayer3D in _world:
		if not p.playing:
			player = p
			break
	if player == null:
		if _world.size() >= POOL_3D:
			return
		player = AudioStreamPlayer3D.new()
		player.bus = "SFX"
		player.max_distance = HEAR_RANGE
		player.unit_size = 14.0
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(player)
		_world.append(player)
	player.stream = _streams[sound]
	player.position = pos + Vector3(0, 1.0, 0)
	player.volume_db = volume_db
	player.pitch_scale = pitch * randf_range(0.94, 1.06)
	player.play()


func _due(sound: String) -> bool:
	if not _streams.has(sound):
		push_warning("Sfx: unknown sound '%s'" % sound)
		return false
	var now := Time.get_ticks_msec()
	if now - int(_last.get(sound, -1000)) < REPEAT_GAP_MS:
		return false
	_last[sound] = now
	return true


# --- Synthesis -------------------------------------------------------------------

## One voice lasting "length" seconds whose pitch glides from f0 to f1 Hz
## (f0 = 0 for noise only). Options:
##   wave     "sine" (default), "square" or "saw"
##   vol      peak level, 0..1 (default 0.5)
##   attack   seconds to reach full level (default 0.004)
##   decay    how fast it dies away; the level falls by e^-decay over the length (default 4)
##   noise    share of noise mixed in, 0..1
##   lp       noise low-pass, 1 = white hiss, small = rumble (default 1)
##   vibrato  pitch wobble in Hz
func _tone(length: float, f0: float, f1: float, opts := {}) -> PackedFloat32Array:
	var count := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(count)
	var wave: String = opts.get("wave", "sine")
	var vol: float = opts.get("vol", 0.5)
	var attack: float = opts.get("attack", 0.004)
	var decay: float = opts.get("decay", 4.0)
	var noise: float = 1.0 if f0 <= 0.0 else opts.get("noise", 0.0)
	var lp: float = opts.get("lp", 1.0)
	var vibrato: float = opts.get("vibrato", 0.0)
	var phase := 0.0
	var hiss := 0.0
	for i in count:
		var t := float(i) / RATE
		var k := float(i) / count
		var v := 0.0
		if f0 > 0.0:
			var f := f0 * pow(f1 / f0, k)
			if vibrato > 0.0:
				f *= 1.0 + 0.06 * sin(TAU * vibrato * t)
			phase += f / RATE
			var p := fposmod(phase, 1.0)
			match wave:
				"square": v = 0.6 if p < 0.5 else -0.6
				"saw": v = (2.0 * p - 1.0) * 0.7
				_: v = sin(TAU * p)
		if noise > 0.0:
			hiss = lerpf(hiss, randf_range(-1.0, 1.0), lp)
			v = lerpf(v, hiss / sqrt(lp), noise)
		# Short fades at both ends keep the sound from clicking.
		var env := minf(1.0, t / attack) * exp(-decay * k) * minf(1.0, (length - t) / 0.01)
		out[i] = v * vol * env
	return out


## Layers voices: each entry is [start in seconds, samples].
func _mix(parts: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for part: Array in parts:
		var at := int(part[0] * RATE)
		var samples: PackedFloat32Array = part[1]
		if out.size() < at + samples.size():
			out.resize(at + samples.size())
		for i in samples.size():
			out[at + i] += samples[i]
	return out


## A run of notes, "step" seconds apart, each ringing for "ring" seconds.
func _notes(freqs: Array, step: float, ring: float, opts := {}) -> PackedFloat32Array:
	var parts := []
	for i in freqs.size():
		parts.append([i * step, _tone(ring, freqs[i], freqs[i], opts)])
	return _mix(parts)


func _add(sound: String, samples: PackedFloat32Array) -> void:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	_streams[sound] = stream


func _build() -> void:
	# Menus.
	_add("click", _tone(0.05, 1000.0, 650.0, {"vol": 0.3, "decay": 5.0}))
	_add("hover", _tone(0.03, 1500.0, 1500.0, {"vol": 0.1, "decay": 4.0}))
	_add("deny", _tone(0.13, 150.0, 120.0, {"wave": "square", "vol": 0.25, "decay": 2.0}))
	_add("start", _mix([
		[0.0, _tone(0.3, 294.0, 294.0, {"wave": "saw", "vol": 0.3, "attack": 0.03, "decay": 1.5})],
		[0.22, _tone(0.7, 440.0, 440.0, {"wave": "saw", "vol": 0.3, "attack": 0.03, "decay": 2.5, "vibrato": 5.0})],
	]))
	_add("win", _notes([523.0, 659.0, 784.0, 1047.0, 1319.0], 0.13, 0.7, {"vol": 0.3, "decay": 3.5}))
	_add("lose", _notes([392.0, 330.0, 262.0, 196.0], 0.2, 0.8, {"wave": "saw", "vol": 0.22, "decay": 3.0}))

	# Rewards.
	_add("coin", _notes([1319.0, 1760.0], 0.07, 0.2, {"vol": 0.3, "decay": 5.0}))
	_add("level", _notes([523.0, 659.0, 784.0, 1047.0], 0.085, 0.35, {"vol": 0.35, "decay": 4.0}))

	# Fighting.
	_add("zap", _tone(0.09, 900.0, 260.0, {"wave": "square", "vol": 0.28, "decay": 4.0}))
	_add("crit", _mix([
		[0.0, _tone(0.16, 240.0, 90.0, {"wave": "square", "vol": 0.45, "decay": 3.5})],
		[0.0, _tone(0.07, 0.0, 0.0, {"vol": 0.4, "decay": 5.0})],
	]))
	_add("shot", _tone(0.24, 1400.0, 330.0, {"vol": 0.4, "decay": 3.5, "noise": 0.15}))
	_add("slam", _mix([
		[0.0, _tone(0.42, 140.0, 40.0, {"vol": 0.9, "decay": 4.0})],
		[0.0, _tone(0.16, 0.0, 0.0, {"vol": 0.5, "decay": 6.0, "lp": 0.25})],
	]))
	_add("blast", _mix([
		[0.0, _tone(0.55, 190.0, 34.0, {"vol": 0.8, "decay": 3.5})],
		[0.0, _tone(0.5, 0.0, 0.0, {"vol": 0.6, "decay": 5.0, "lp": 0.15})],
	]))
	_add("dash", _mix([
		[0.0, _tone(0.26, 0.0, 0.0, {"vol": 0.4, "attack": 0.08, "decay": 2.5, "lp": 0.35})],
		[0.0, _tone(0.26, 280.0, 720.0, {"vol": 0.2, "attack": 0.05, "decay": 3.0})],
	]))
	_add("blink", _tone(0.2, 480.0, 2300.0, {"vol": 0.35, "decay": 2.5}))
	_add("heal", _notes([523.0, 659.0, 784.0], 0.08, 0.32, {"vol": 0.33, "decay": 4.0, "attack": 0.01}))
	_add("buff", _notes([392.0, 494.0, 587.0, 784.0], 0.05, 0.3, {"wave": "saw", "vol": 0.18, "decay": 3.5, "attack": 0.01}))
	_add("drain", _tone(0.48, 520.0, 110.0, {"wave": "saw", "vol": 0.3, "decay": 2.5, "vibrato": 17.0}))

	# Deaths.
	_add("pop", _tone(0.09, 520.0, 150.0, {"vol": 0.25, "decay": 5.0, "noise": 0.3}))
	_add("death", _tone(0.65, 440.0, 85.0, {"wave": "saw", "vol": 0.35, "decay": 2.5, "vibrato": 9.0}))
	_add("crumble", _mix([
		[0.0, _tone(1.3, 0.0, 0.0, {"vol": 0.8, "decay": 3.0, "lp": 0.08})],
		[0.0, _tone(0.7, 95.0, 28.0, {"vol": 0.8, "decay": 3.0})],
	]))
