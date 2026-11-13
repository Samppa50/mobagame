# Yell MOBA

Godot 4.7 MOBA prototype (GDScript, GodotSteam). Hero damage and healing are multiplied by how loud the player is yelling into their mic, up to x2.

## Running

Godot lives at `S:\Godot\Godot_v4.7.2-stable_win64_console.exe` (use the `_console` build to see output).

Dev flags go after `--`:

| Flag | Effect |
|---|---|
| `--dev-host` / `--dev-join` | ENet session on localhost instead of a Steam lobby |
| `--autostart=N` | Host starts the match once N players (bots included) are present |
| `--bots=N` | Host adds N bots, alternating teams, enemy team first |
| `--hero=N`, `--map=N` | Pick hero / map (map 0 = Single Lane, 1 = Three Lanes) |
| `--selftest` | Run `tests/selftest.gd` and quit with exit code 0 / 1 |

```sh
# Play solo against bots
godot --path . -- --dev-host --autostart=1 --bots=9 --map=1
```

## Testing

There is no unit-test framework; `tests/selftest.gd` runs inside a real match and prints `SELFTEST ok/FAIL` lines, ending with `SELFTEST RESULT: PASS` or `FAIL (n)`. Run it after any gameplay change, on both maps.

```sh
# Two-instance networked test (start the host, then the client ~2 s later)
godot --headless --path . -- --dev-host --autostart=2 --selftest [--map=1]
godot --headless --path . -- --dev-join --selftest

# Solo: casts both abilities of the picked hero
godot --headless --path . -- --dev-host --autostart=1 --selftest --hero=N

# Bot-only match, sped up 8x; prints a table per stage and checks the bots finish
godot --headless --path . -- --dev-host --autostart=1 --bots=9 --map=1 --selftest
```

- After adding a script with `class_name`, run `godot --headless --path . --import` once so the class is registered.
- The networked selftest is timing-sensitive: the client script waits fixed delays for host steps. If you add waits on the host side, re-check the client's timeline.
- To look at the UI without a window, render frames: `godot --path . --write-movie <dir>/f.png --fixed-fps 20 --quit-after 60 -- <dev flags>` and read the last PNG.

## Architecture

The host (peer 1) is authoritative and simulates everything; clients send commands and receive state.

- `autoload/tunables.gd` (`Tune`) — every balance number, hero / item / monster definitions, both map definitions, and walkability / routing helpers. Change numbers here, not in game code.
- `autoload/net.gd` (`Net`) — session, lobby roster, match flow. `Net.players` maps peer id to `{name, team, hero, ready}`; bots are entries with negative ids and `"bot": true`.
- `autoload/voice.gd` (`Voice`) — Steam voice capture, proximity relay, and the loudness that drives the yell multiplier.
- `game/match.gd` — one match: spawning, `deal_damage` (the single place damage is applied), kills / gold / xp, jungle camps, fog of war, camera, local input, visual effect RPCs. Must be named `Match` under `Main` on every peer.
- `game/unit.gd` — base `Unit`: team, hp, replication (`_sync_props`), procedural animation.
- `game/hero.gd` — `Hero`: `cmd_*` RPCs from the owner call `host_*` methods; stats are rebuilt from definition + level + items in `_apply_items`.
- `game/structures.gd` — `Minion`, `Monster`, `Tower`, `Core` as inner classes.
- `game/bot.gd` — `BotBrain`, host-side AI that orders a bot's hero through the same `host_*` methods.
- `ui/hud.gd`, `ui/minimap.gd`, `ui/lobby.gd`, `ui/main_menu.gd` — all UI is built in code; there are no scene files besides `main.tscn`.

## Conventions

- Tabs for indentation, typed GDScript, `##` doc comments explaining why.
- Teams: 0 = Blue, 1 = Red, `Tune.NEUTRAL` (2) = jungle monsters. Code that indexes by team (`spawns[team]`, `cores[team]`) must not be reached with the neutral team.
- New replicated hero state goes in `Hero._sync_props`; derived stats are recomputed on every peer from replicated inputs (use a setter, as `items` and `level` do) rather than replicated themselves.
- Gameplay changes happen on the host only. Visual one-shots are `fx_*` RPCs on the match.
- Fog of war and the scoreboard's hidden enemy gold are display-only; all state is still replicated to every client.
- Files are CRLF in the repo; Git's LF-to-CRLF warnings on commit are expected.
- Godot writes `~*.dll` temp copies in `addons/godotsteam/win64/` while running; they are git-ignored and must not be committed.
