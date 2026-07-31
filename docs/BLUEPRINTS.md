# Blueprints (node graphs)

Host-side **node graphs** for MeatRayCast, designed as a sibling to
MeatEngine's C6 visual scripting (`F:\MeatEngine\docs\BLUEPRINTS.md`).

## Relationship to MeatEngine

| | MeatEngine | MeatRayCast |
|---|---|---|
| Authoring | ImGui + imnodes in Room Designer | Hand-edited JSON / Lua tables (editor panel later) |
| Runtime | Compiles graph → sandboxed Lua (`zz_blueprint.lua`) | **Interprets** the graph in pure Lua |
| Source of truth | Graph JSON | Same idea: JSON with `version`, `nodes`, `links` |
| Kind names | `EventOnInit`, `ActionLog`, `Branch`, … | Shared names for the common subset |
| Authority | Server / host only | Host only (never on clients) |
| Capability | `game.*` sol2 table | Injected `api` table (`Blueprint.apiFor`) |

We deliberately **do not** load MeatEngine's C++ or imnodes. What we re-use is
the *contract*: exec chains, data pins resolved backward, literals on nodes,
events as the only entry points. Raycast-specific actions (doors, floor height,
entity spawn, score) live beside the shared kinds.

## Quick start

```
love . --blueprint
love . --blueprint blueprints/demo.graph.json --map arena
```

```lua
local BP = MeatRay.game.blueprint
local g = BP.load(jsonText)   -- or BP.example()
local mode = MeatRay.game.mode.new{ name = g.name }
BP.bindMode(mode, g, {
    log = print,
    world = world,
    Entity = MeatRay.entity,
    entities = entities,
})
mode:start(world, entities)
-- each host tick:
mode:tick(dt, world, entities)
```

## Node kinds

### Shared with MeatEngine (by name)

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
| `ActionAttachAI` | attach brain; `strA` state, `floatA` speed, `intA` alert; entity from pin or trigger env |
| `ActionLogOnce` | log first time only (`strA` = key/message) |
| `EventOnTrigger` | enter; optional `strA` = volume name |
| `EventOnTriggerExit` | leave/dead; same filter |
| `EventOnTriggerStay` | each step while inside |

## Volumes (graph-side trigger defs)

Optional `volumes` array on the graph JSON. With `bindMode(..., { triggers = true })`
these become `meatray.sim.triggers` volumes that fire the events above.

```json
"volumes": [
  { "name": "exit", "tx1": 10, "ty1": 8, "tx2": 12, "ty2": 10,
    "filter": "player", "once": false }
]
```

Tile fields are 1-based inclusive (same as `Triggers:addTiles`). World AABB
fields `x1,y1,x2,y2` work too. `filter`: `"player"` or omit for anyone.

Demo: `love . --blueprint blueprints/triggers.graph.json --map arena`

## JSON shape

Compatible with MeatEngine's `saveGraphJson` fields:

```json
{
  "version": 1,
  "name": "demo",
  "nextNodeId": 10,
  "nextLinkId": 10,
  "nodes": [
    { "id": 1, "kind": "EventOnInit", "x": 40, "y": 40,
      "strA": "", "intA": 0, "intB": 0, "intC": 0, "intD": 0, "floatA": 0 }
  ],
  "links": [
    { "id": 1, "fromNode": 1, "fromPin": 0, "toNode": 2, "toPin": 0 }
  ]
}
```

## Files

| Path | Role |
|---|---|
| `meatray/game/blueprint.lua` | Load, interpret, `apiFor`, `bindMode` |
| `blueprints/demo.graph.json` | Sample graph |
| `tests/test_blueprint.lua` | Headless coverage |
| MeatEngine `src/engine/script/NodeGraph.*` | Visual editor + Lua emit (upstream) |

## Open follow-ups

- ImGui/imnodes panel in `love . --editor` (or share MeatEngine's graph JSON on disk)
- Emit-to-Lua path for parity with MeatEngine sandbox budgets
- More actions: gas, explosion, weapon grant, inventory give
- Subgraphs / multi-graph tabs
