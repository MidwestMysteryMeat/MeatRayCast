# Node graphs

Host-side **node graphs** for MeatRayCast — visual-scripting data (events,
actions, branches) stored as JSON and run only on the host.

We do **not** call these “blueprints.” That is Unreal Engine’s product name for
their visual scripting system. The idea is similar (event → action chains); the
name is not.

## Relationship to MeatEngine

MeatEngine’s C6 work (imnodes editor → sandboxed Lua) is a sibling. Shared
ideas only — not a shared trademarked name:

| | MeatEngine C6 | MeatRayCast |
|---|---|---|
| Authoring | ImGui + imnodes | Hand-edited JSON / Lua tables (editor panel later) |
| Runtime | Compiles graph → sandboxed Lua | **Interprets** the graph in pure Lua |
| Source of truth | Graph JSON | Same shape: `version`, `nodes`, `links`, `volumes` |
| Kind names | `EventOnInit`, `ActionLog`, `Branch`, … | Shared names for the common subset |
| Authority | Server / host only | Host only (never on clients) |
| Capability | `game.*` sol2 table | Injected `api` table (`NodeGraph.apiFor`) |

## Quick start

```
love . --graph
love . --graph graphs/demo.graph.json --map arena
love . --graph graphs/triggers.graph.json --map arena
```

```lua
local NG = MeatRay.game.nodegraph
local g = NG.load(jsonText)   -- or NG.example()
local mode = MeatRay.game.mode.new{ name = g.name }
NG.bindMode(mode, g, {
    log = print,
    world = world,
    Entity = MeatRay.entity,
    entities = entities,
    triggers = true,   -- install g.volumes into sim.triggers
})
mode:start(world, entities)
-- each host tick:
mode:tick(dt, world, entities)
```

## Node kinds

### Shared subset (by name)

| Kind | Role |
|---|---|
| `EventOnInit` / `EventOnTick` / `EventOnPlayerJoin` / `EventOnPlayerDeath` | Entry points |
| `ActionLog` | Print / note |
| `ActionSetBlock` / `ActionSpawnPickup` | Mapped to destroy/spawn when api allows |
| `Branch` | Flow |
| `MathAdd` / `MathGreater` | Pure |
| `ConstInt` / `ConstFloat` / `ConstString` / `Randi` / `GetPlayerCount` | Data |

### Raycast extensions

| Kind | Role |
|---|---|
| `ActionOpenDoor` / `ActionToggleDoor` | `intA,intB` = tile |
| `ActionSpawnEntity` | `strA` kind, `floatA` x, `intA` y |
| `ActionSetFloor` / `ActionSetCeiling` | tile + height |
| `ActionAddScore` | peer + delta (via Mode) |
| `ActionAttachAI` | attach brain; entity from pin or trigger env |
| `ActionLogOnce` | log first time only (`strA` = key/message) |
| `EventOnTrigger` | enter; optional `strA` = volume name |
| `EventOnTriggerExit` | leave/dead; same filter |
| `EventOnTriggerStay` | each step while inside |

## Volumes (graph-side trigger defs)

Optional `volumes` array. With `bindMode(..., { triggers = true })` these
become `meatray.sim.triggers` volumes that fire the events above.

```json
"volumes": [
  { "name": "exit", "tx1": 10, "ty1": 8, "tx2": 12, "ty2": 10,
    "filter": "player", "once": false }
]
```

## JSON shape

```json
{
  "version": 1,
  "name": "demo",
  "nodes": [
    { "id": 1, "kind": "EventOnInit", "x": 40, "y": 40,
      "strA": "", "intA": 0, "intB": 0, "intC": 0, "intD": 0, "floatA": 0 }
  ],
  "links": [
    { "id": 1, "fromNode": 1, "fromPin": 0, "toNode": 2, "toPin": 0 }
  ],
  "volumes": []
}
```

## Files

| Path | Role |
|---|---|
| `meatray/game/nodegraph.lua` | Load, interpret, `apiFor`, `bindMode` |
| `graphs/*.graph.json` | Sample graphs |
| `tests/test_nodegraph.lua` | Headless coverage |
| MeatEngine `src/engine/script/NodeGraph.*` | Visual editor + Lua emit (upstream) |

## Open follow-ups

- ImGui/imnodes panel in `love . --editor` (or import MeatEngine `.graph.json`)
- Emit-to-Lua path for sandbox-budget parity
- More actions: gas, explosion, weapon grant, inventory give
- Subgraphs / multi-graph tabs
