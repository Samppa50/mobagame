extends Node
## Proximity voice over the Steam Voice codec, plus the loudness tracking that
## drives yell damage.
##
## Flow: capture -> send compressed chunk to host -> host measures loudness
## and forwards the chunk only to players whose hero is within HEAR_RANGE ->
## receivers play it on a 3D audio player attached to the speaker's hero.
## In the lobby (no heroes) everyone hears everyone, non-positional.

const RATE := 24000
const MAX_CHUNK := 16384
const VOICE_OK := 0

var my_db := -80.0       # local loudness for the HUD meter (decays)
var last_result := -1    # last Steam capture result (0 = data, 3 = recording but silent)
var loopback := false    # hear your own voice (debug)

var _recording := false
var _loud := {}          # host: peer_id -> Array of [msec, db]
var _flat := {}          # speaker peer_id -> AudioStreamPlayer (non-positional)


func _ready() -> void:
	if SteamManager.ok:
		Steam.startVoiceRecording()
		_recording = true
	multiplayer.peer_disconnected.connect(_forget)


func _exit_tree() -> void:
	if _recording:
		Steam.stopVoiceRecording()


func _process(delta: float) -> void:
	my_db = maxf(-80.0, my_db - 80.0 * delta)
	if Net.dev_mode and Input.is_key_pressed(KEY_V):
		_fake_yell()
	if not _recording:
		return
	var avail: Dictionary = Steam.getAvailableVoice()
	last_result = int(avail.get("result", -1))
	if last_result != VOICE_OK or int(avail.get("size", 0)) <= 0:
		return
	var got: Dictionary = Steam.getVoice(int(avail["size"]))
	if int(got.get("result", -1)) != VOICE_OK or int(got.get("size", 0)) <= 0:
		return
	var chunk: PackedByteArray = got["buffer"]
	var pcm := _decode(chunk)
	var db := _rms_db(pcm)
	my_db = maxf(my_db, db)
	if loopback:
		_push(_flat_player(0), pcm)
	if not Net.online():
		return
	if multiplayer.is_server():
		_note(1, db)
		_relay(1, chunk)
	else:
		submit.rpc_id(1, chunk)


# --- Loudness (host authoritative) ---------------------------------------------

## Loudest level this player reached in the last YELL_WINDOW_MS, in dBFS.
func peak_db(peer: int) -> float:
	var entries: Array = _loud.get(peer, [])
	var cutoff := Time.get_ticks_msec() - Tune.YELL_WINDOW_MS
	while not entries.is_empty() and entries[0][0] < cutoff:
		entries.pop_front()
	var best := -80.0
	for e in entries:
		best = maxf(best, e[1])
	return best


func multiplier_for(peer: int) -> float:
	return Tune.yell_multiplier(peak_db(peer))


func my_multiplier() -> float:
	return Tune.yell_multiplier(my_db)


func _note(peer: int, db: float) -> void:
	if not _loud.has(peer):
		_loud[peer] = []
	_loud[peer].append([Time.get_ticks_msec(), db])


func clear_loudness(peer: int) -> void:
	_loud.erase(peer)


func _forget(peer: int) -> void:
	_loud.erase(peer)
	if _flat.has(peer):
		_flat[peer].queue_free()
		_flat.erase(peer)


## Dev sessions only: hold V to count as screaming, for testing without a mic.
func _fake_yell() -> void:
	my_db = Tune.YELL_DB_MAX
	if not Net.online():
		return
	if multiplayer.is_server():
		_note(1, Tune.YELL_DB_MAX)
	else:
		dev_fake_yell.rpc_id(1)


@rpc("any_peer", "call_remote", "unreliable")
func dev_fake_yell() -> void:
	if multiplayer.is_server() and Net.dev_mode:
		_note(multiplayer.get_remote_sender_id(), Tune.YELL_DB_MAX)


# --- Transport -----------------------------------------------------------------

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func submit(chunk: PackedByteArray) -> void:
	if not multiplayer.is_server() or chunk.size() > MAX_CHUNK:
		return
	var speaker := multiplayer.get_remote_sender_id()
	if not Net.players.has(speaker):
		return
	_note(speaker, _rms_db(_decode(chunk)))
	_relay(speaker, chunk)


func _relay(speaker: int, chunk: PackedByteArray) -> void:
	var m = Net.match_node if Net.in_match and is_instance_valid(Net.match_node) else null
	var from_hero = m.hero_for(speaker) if m != null else null
	for peer in Net.players:
		if peer == speaker:
			continue
		if m != null:
			var to_hero = m.hero_for(peer)
			if from_hero == null or to_hero == null:
				continue
			if from_hero.position.distance_to(to_hero.position) > Tune.HEAR_RANGE:
				continue
		if peer == 1:
			_play(speaker, chunk)
		else:
			hear.rpc_id(peer, speaker, chunk)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func hear(speaker: int, chunk: PackedByteArray) -> void:
	_play(speaker, chunk)


# --- Playback ------------------------------------------------------------------

func _play(speaker: int, chunk: PackedByteArray) -> void:
	var pcm := _decode(chunk)
	if pcm.is_empty():
		return
	var m = Net.match_node if Net.in_match and is_instance_valid(Net.match_node) else null
	var hero = m.hero_for(speaker) if m != null else null
	if hero != null:
		_push(hero.voice_player(), pcm)
	else:
		_push(_flat_player(speaker), pcm)


func make_stream() -> AudioStreamGenerator:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.5
	return gen


func _flat_player(speaker: int) -> AudioStreamPlayer:
	if not _flat.has(speaker):
		var p := AudioStreamPlayer.new()
		p.stream = make_stream()
		add_child(p)
		p.play()
		_flat[speaker] = p
	return _flat[speaker]


func _push(player: Node, pcm: PackedByteArray) -> void:
	if not player.playing:
		player.play()
	var playback = player.get_stream_playback()
	if playback == null:
		return
	var count := pcm.size() >> 1
	if count == 0 or not playback.can_push_buffer(count):
		return
	var frames := PackedVector2Array()
	frames.resize(count)
	for i in count:
		var s := pcm.decode_s16(i * 2) / 32768.0
		frames[i] = Vector2(s, s)
	playback.push_buffer(frames)


## Steam voice chunk -> 16-bit mono PCM bytes at RATE.
func _decode(chunk: PackedByteArray) -> PackedByteArray:
	if chunk.is_empty() or not SteamManager.ok:
		return PackedByteArray()
	var d: Dictionary = Steam.decompressVoice(chunk, RATE, RATE * 2)
	if int(d.get("result", -1)) != VOICE_OK:
		return PackedByteArray()
	return (d["uncompressed"] as PackedByteArray).slice(0, int(d["size"]) & ~1)


func _rms_db(pcm: PackedByteArray) -> float:
	var count := pcm.size() >> 1
	if count == 0:
		return -80.0
	var sum := 0.0
	for i in count:
		var s := float(pcm.decode_s16(i * 2))
		sum += s * s
	var rms := sqrt(sum / count) / 32768.0
	return maxf(-80.0, 20.0 * log(maxf(rms, 0.000001)) / log(10.0))
