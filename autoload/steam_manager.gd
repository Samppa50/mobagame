extends Node
## Initialises Steam (dev app ID 480) and exposes the local identity.

const APP_ID := 480

var ok := false
var steam_id := 0
var persona := "Player"
var error := ""


func _ready() -> void:
	var r: Dictionary = Steam.steamInitEx(APP_ID, true)
	ok = int(r.get("status", 1)) == 0
	if ok:
		steam_id = Steam.getSteamID()
		persona = Steam.getPersonaName()
	else:
		error = str(r.get("verbal", "Steam is not running"))
		push_warning("Steam init failed: %s" % error)
