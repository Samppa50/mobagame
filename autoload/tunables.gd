extends Node
## Every balance and yell constant lives here.

const MAX_PLAYERS := 6
const DEV_PORT := 24565
const LOBBY_TAG := "yellmoba"

# --- Yell damage -----------------------------------------------------------
const YELL_DB_MIN := -40.0   # at or below this loudness: 1.0x
const YELL_DB_MAX := -6.0    # at or above this loudness: YELL_MULT_MAX
const YELL_MULT_MAX := 3.0
const YELL_WINDOW_MS := 300  # "moment of hit" = loudest voice in this window
const HEAR_RANGE := 24.0     # proximity voice cut-off, world units

# --- Map (single lane along X) ---------------------------------------------
const LANE_HALF_LEN := 44.0
const LANE_HALF_WID := 10.0
const CORE_X := 36.0
const BASE_DEPTH := 13.0  # paved base strip at each end of the lane
const TOWER_X := 22.0
const SPAWN_X := 42.0

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


func yell_multiplier(db: float) -> float:
	var t := clampf(inverse_lerp(YELL_DB_MIN, YELL_DB_MAX, db), 0.0, 1.0)
	return lerpf(1.0, YELL_MULT_MAX, t)


func clamp_to_lane(p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, -LANE_HALF_LEN, LANE_HALF_LEN), 0.0, clampf(p.z, -LANE_HALF_WID, LANE_HALF_WID))


## +1 for team 0 (attacks toward +X), -1 for team 1.
func side(team: int) -> float:
	return 1.0 if team == 0 else -1.0


func team_color(team: int) -> Color:
	return Color(0.25, 0.55, 1.0) if team == 0 else Color(1.0, 0.32, 0.25)


func team_name(team: int) -> String:
	return "Blue" if team == 0 else "Red"
