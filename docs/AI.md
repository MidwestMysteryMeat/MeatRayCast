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

## Imitation learning (`scripts/imitate.lua`)

The F1 demo recorder makes every play session a labelled dataset: each tick
pairs "what could be sensed" with "what the player did". The script replays
a demo's input stream against its map, harvests (senses → intents) pairs,
and backprop-trains a brain:

```
luajit scripts/imitate.lua mysession.dem build/me.txt   # then: neurobot 1 build/me.txt
luajit scripts/imitate.lua --selfcheck                   # proof without a human
```

The selfcheck has a rules-bot record a session, then trains on the capture —
error collapses 2.32 → 0.06 (97%). Two honest notes: a demo may carry
`goal` events to make navigation intent observable to the goal senses (the
selfcheck's teacher records its wander goals; without them a policy is
partially unlearnable *in principle*, not just in practice), and v1
reconstructs movement only, so the trained style is locomotion, not
duelling.

## RL environment server (`meatray.sim.env` + `scripts/env_server.lua`)

The ML-Agents split: the engine owns a deterministic episodic environment,
the trainer lives anywhere. Gym semantics — `reset() → obs`,
`step(action) → obs, reward, done, info` — with the neurobot's senses as
observations and its intents as actions, applied through the real input
path. Reward is walking-distance progress with continuous sub-tile shaping
(integer tile distance alone gives no signal inside a tile). Over the wire:

```
luajit scripts/env_server.lua maps/arena.map
```

speaks JSON-lines on stdio (`info` / `reset` / `step` / `quit`). A minimal
Python trainer:

```python
import json, subprocess
p = subprocess.Popen(["luajit", "scripts/env_server.lua", "maps/arena.map"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(msg):
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
spec = rpc({"cmd": "info"})                    # {'obs_size': 11, 'action_size': 4}
obs = rpc({"cmd": "reset"})["obs"]
r = rpc({"cmd": "step", "action": [1, 0, 0, 0]})   # obs / reward / done / info
```

Train with anything (PyTorch on the R720), export the policy's weights as
`neural1` text, and `neurobot 1 <file>` runs it in the game — the
observation and action spaces match by construction.

## Heavier ML (not in-engine, on purpose)

The engine will not link native ML libraries — pure Lua and dual-interpreter
determinism are load-bearing. For heavyweight offline training, use anything
(mlpack, PyTorch, a GPU box) and export weights into the `neural1` text
format `Neural.deserialize` reads; the engine only ever needs the forward
pass, and it already has one.
