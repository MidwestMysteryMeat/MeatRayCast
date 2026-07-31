# MeatGraphRay

Host-side **node graphs** for MeatRayCast.

MeatEngine’s visual scripting is **MeatGraph**. This module is the raycast
engine’s counterpart: **MeatGraphRay** — same idea (event → action chains as
JSON), host-only interpretation. We do **not** call them “blueprints” (Unreal’s
product name).

## Family

| | MeatEngine | MeatRayCast |
|---|---|---|
| Name | **MeatGraph** | **MeatGraphRay** |
| Authoring | ImGui + imnodes | Hand-edited JSON / Lua tables (editor later) |
| Runtime | Compiles graph → sandboxed Lua | **Interprets** the graph in pure Lua |
| Source of truth | Graph JSON | Same shape: `version`, `nodes`, `links`, `volumes` |
| Kind names | `EventOnInit`, `ActionLog`, `Branch`, … | Shared names for the common subset |
| Authority | Server / host only | Host only |
| Capability | `game.*` sol2 table | Injected `api` table (`MeatGraphRay.apiFor`) |

## Quick start

```
love . --meatgraph
love . --meatgraph meatgraphs/demo.graph.json --map arena
love . --meatgraph meatgraphs/triggers.graph.json --map arena
```

```lua
local MG = MeatRay.game.meatgraphRay
local g = MG.load(jsonText)   -- or MG.example()
local mode = MeatRay.game.mode.new{ name = g.name }
MG.bindMode(mode, g, {
    log = print,
    world = world,
    Entity = MeatRay.entity,
    entities = entities,
    triggers = true,   -- install g.volumes into sim.triggers
})
mode:start(world, entities)
mode:tick(dt, world, entities)
```

## Node kinds

### Shared with MeatGraph (by name)

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
| `ActionLogOnce` | log first time only |
| `EventOnTrigger` / `Exit` / `Stay` | volume enter/leave/stay; optional `strA` name |

## Volumes

Optional `volumes` array. With `bindMode(..., { triggers = true })` these
become `meatray.sim.triggers` volumes.

```json
"volumes": [
  { "name": "exit", "tx1": 10, "ty1": 8, "tx2": 12, "ty2": 10,
    "filter": "player", "once": false }
]
```

## Files

| Path | Role |
|---|---|
| `meatray/game/meatgraph_ray.lua` | Load, interpret, `apiFor`, `bindMode` |
| `meatgraphs/*.graph.json` | Sample graphs |
| `tests/test_meatgraph_ray.lua` | Headless coverage |
| MeatEngine MeatGraph / `NodeGraph.*` | Visual editor + Lua emit (upstream) |

## Open follow-ups

- Editor panel for MeatGraphRay JSON (or import MeatEngine MeatGraph exports)
- Emit-to-Lua path for sandbox-budget parity
- More actions: gas, explosion, weapon grant, inventory give
