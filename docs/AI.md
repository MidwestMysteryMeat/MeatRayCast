# The AI substrate: crowds, learning agents, and MCP

Wave I adds three kinds of intelligence to the engine, each honouring the
same laws as everything else — headless, pure Lua, deterministic off the
engine LCG, tested on both interpreters.

## Crowds (`meatray.sim.crowd`)

Monsters think one at a time; a crowd shares one brain. That brain is a
**flow field** — a BFS from the goal leaving every walkable tile a "step
this way" arrow — so pathing cost is paid once per goal, not per agent.
Per-agent steering (separation via a spatial hash, seeded wander when idle)
keeps it looking like a crowd; integration goes through `Collide.move`, so
agents slide along real walls, open real doors, and steer at tile centres
so a one-wide doorway doesn't become a grinder.

Crowd members are ordinary entities: they replicate, take damage, and die
like anything else. In the demo:

```
crowd 12        ` console: twelve agents flock to you and follow
```

## Machine-learning agents (`meatray.sim.neural` + `meatray.game.neurobot`)

A small MLP library with the two training paths games actually use:

- **Backprop** (`net:train`) — supervised; the natural pairing is the F1
  demo recorder, whose input streams are labelled examples of how a human
  plays (imitation learning).
- **Neuroevolution** (`mutate` / `crossover` / `evolvePool`) — no gradients,
  just a fitness number and selection pressure.

Everything is deterministic: same seed, same brain; serialization is
`%.17g` text, so a brain is a few KB a project commits.

The **neurobot** puts a net behind the same contract as C22 bots: whisker
raycasts, goal/target bearings in, `{forward, strafe, turn, fire}` out —
fed through the identical `Rep.applyInput` a keyboard feeds. It learned to
drive the actual game or it learned nothing.

```
luajit scripts/evolve.lua maps/arena.map 40 build/brain.txt
```

evolves navigation brains against walking-distance fitness (Euclidean is
deceptive around walls — that plateau is real and the script's comment
explains it). The shipped run climbs from 10 to ~45 fitness: the winning
brain crosses a 35-tile course and arrives. Then:

```
neurobot 2 build/brain.txt      ` console: two trained players join
neurobot 3                      ` three fresh random brains (chaos)
```

## MCP server (`meatray.net.mcp` + `scripts/mcp_server.lua`)

The engine as a **tool an AI agent uses** — Model Context Protocol over
stdio. Register with Claude Code:

```
claude mcp add meatraycast -- luajit scripts/mcp_server.lua
```

and the agent can drive the authoring surface directly: `project_create`,
`project_info`, `map_read`, `map_info`, `map_lint`, `map_write` (refuses
unparseable text, lints on every write), `graph_validate` (the same F9
sandbox the runtime enforces), `sfx_render`. Protocol dispatch is
transport-free and headless-tested; tool failures come back as `isError`
results an agent can read, never a dead session.

## Heavier ML (not in-engine, on purpose)

The engine will not link native ML libraries — pure Lua and dual-interpreter
determinism are load-bearing. For heavyweight offline training, use anything
(mlpack, PyTorch, a GPU box) and export weights into the `neural1` text
format `Neural.deserialize` reads; the engine only ever needs the forward
pass, and it already has one.
