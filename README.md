# MeatRayCast

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A raycasting game engine for [LÖVE](https://love2d.org). DDA wall renderer,
directional sprite billboards, entity-component simulation, grid collision,
fixed-timestep loop, and levels from either a procedural generator or
hand-authored text maps.

**No assets. No dependencies.** Every texture and sprite is generated at runtime,
so a fresh clone runs with nothing missing.

| facing you | facing away |
|---|---|
| ![](docs/media/facing_front.png) | ![](docs/media/facing_away.png) |

Same entity, same sheet, different angle bucket. The placeholder sprites are drawn
so that a facing bug is *visible* — two eyes toward the viewer, one in profile,
none from behind — because an enemy charging you while showing its back is a bug
you want to see immediately rather than ship.

| torch lit | torch out |
|---|---|
| ![](docs/media/light_demo_torch.png) | ![](docs/media/light_demo_notorch.png) |

The same frame of the same map with a carried light and without one. Dropping the
torch is meant to cost you something — and to leave a level you can still walk
through, which is what `Lighting.MIN_VISIBILITY` is for.

| a coloured source tints the wall | light stops at the wall / the same light told not to |
|---|---|
| ![](docs/media/light_colour.png) | ![](docs/media/light_blocked.png) ![](docs/media/light_through_wall.png) |

| a sprite under a light | the same sprite in the dark |
|---|---|
| ![](docs/media/light_sprite_lit.png) | ![](docs/media/light_sprite_shadow.png) |

Sprites take the light where they stand, on the same curve and with the same floor
the wall loop uses, so an entity sits *in* the scene rather than on it.

| an explosion lights the room | and leaves fire behind |
|---|---|
| ![](docs/media/explosion_flash.png) | ![](docs/media/gas_fire.png) |

The blast is resolved by `meatray/game/explosion.lua`, which has never heard of
the renderer: it *describes* its flash and hands it out, and whoever holds a light
grid pushes it. A dedicated server runs the identical explosion and pushes
nothing. The fire is a gas field — one scalar diffusing across open tiles — with
one dynamic light per burning tile.

## Quickstart

```
love .                  # procedural world
love . --map arena      # the hand-authored map in maps/arena.map
love . --selftest       # deterministic gate; prints PASS and exits 0
```

`WASD` move · mouse or `Q`/`E` turn · `F` open a door · click to fire ·
`1`/`2` pistol or grenade launcher · `TAB` switch procedural/authored ·
`R` reseed · `T` cycle theme · `L` torch · `F1` help

The cursor is captured for mouselook. `Escape` releases it, clicking recaptures,
and a second `Escape` quits — so getting your pointer back never costs you the
session.

```
love . --host                   listen server: play and host at once
love . --server --port 6789     headless dedicated server, no window, no GPU
love . --connect 10.0.0.5:6789  join a server
love . --registry URL           announce to / join through a registry (repeatable)
love . --browse                 list servers on the LAN and exit
love . --netcheck               is UDP usable on this machine at all?
love . --netfrag --connect A    measure the snapshot stream on a real socket
love . --netproxy --port P      a UDP relay that drops a fraction of the traffic
love . --punchcheck --connect A --registry URL
                                join through a registry, report what the punch did
love . --bench                  wall renderer benchmark, fixed camera
```

Tests: `luajit tests/run_all.lua` — 4922 assertions, no LÖVE required.
Network acceptance: `powershell -File scripts/nettest.ps1` — a dedicated server
and two clients as separate processes, asserting over real UDP.
Snapshot stream: `powershell -File scripts/netfrag.ps1` — a server, a relay that
destroys a fifth of the datagrams, and a probe that counts what survives. It is
how the claim "the snapshot stream is unreliable" stopped being a claim.

## Two ways to use it

**As a library, where you own the loop:**

```lua
local MeatRay = require('meatray')

local world = MeatRay.worldgen.generate{ width = 48, height = 48, seed = 7 }
MeatRay.raycaster.init{ theme = 'dungeon' }
MeatRay.sprites.define('imp', { angles = 8, frames = 4, fps = 8 })

function love.draw()
    local view = MeatRay.raycaster.view(px, py, angle)
    local zbuf = MeatRay.raycaster.render(view, world)
    MeatRay.sprites.draw(entities, zbuf, view)
end
```

**Or hand the loop over** — `meatray.engine` wires up the common case. It may only
call the public API, so anything it can do you can do yourself, and dropping down
to the library is never a rewrite.

The demo in `main.lua` is written against the library path deliberately, as proof
that path is sufficient on its own.

Full reference: [`docs/API.md`](docs/API.md).

## Design

**Entities compose, they do not inherit.** An archetype names a kind and attaches
components; behaviour is whatever components an entity carries. So a flying
undead imp is two more components, not a new branch in a class hierarchy.

```lua
local Imp = MeatRay.archetype('imp', function(e)
    e:add(Billboard{ sheet = 'imp' })
    e:add(Health{ hp = 30, max = 30 })
    e.radius = 0.28
end)
```

**Components declare what replicates.** Each component type lists its own
`netFields`, and snapshots are derived from that list. Adding synced state is one
edit, and there is no hand-written serialiser per type to forget to update. The
same mechanism carries networking today and will carry save files.

**The dev picks the topology, in one line.** The engine does not choose, because a
co-op crawler, a LAN shooter and a persistent server want different answers:

```lua
MeatRay.net.host{ mode = 'listen', discovery = 'lan' }       -- play and serve
MeatRay.net.host{ mode = 'dedicated', port = 6789 }          -- headless
MeatRay.net.join('203.0.113.5:6789')                         -- or a browser entry
```

Mode, transport and discovery are three independent choices and none of them leaks
into gameplay code. A game that says nothing about networking is in `single` mode
and runs exactly as it did before. See
[`docs/NETWORKING.md`](docs/NETWORKING.md).

**The simulation never touches `love.graphics`.** Everything under `meatray/sim/`
is pure Lua, enforced by a test that loads each module with no `love` global and
scans the sources. That is what makes a headless dedicated server a configuration
choice rather than a rewrite, and it is why the simulation can be unit-tested
without a graphics stub standing in for a window — a suite that mocks the renderer
and never enters a draw path reports green while the untested half rots.

**Fixed 60 Hz simulation, interpolated rendering.** Networking requires it, and it
structurally prevents the per-frame-versus-per-tick class of bug.

**Procedural and hand-authored are equals.** Both produce the same `World`, so
nothing downstream knows which was used. Maps are readable text — a level diffs in
git and can be edited without the tool:

```
name  Test Arena
theme facility
spawn 3.5 9.5 0
entity i imp
---
##########
#........#
#..222D..#
#....i...#
##########
```

## What this is not, yet

Honest scope. These are phases in [`docs/ROADMAP.md`](docs/ROADMAP.md), not
oversights:

- **Assets are optional, and that is the point.** PNG sheets and WAV audio import,
  with positional playback. Every lookup that misses falls back to a generated
  placeholder rather than erroring, so a project with no assets runs and one with
  half its assets shows which half. The repo itself still ships no media.
- **The editor is built.** `love . --editor [map]` opens a docked workspace with
  four panels — map editor with a live first-person preview, asset browser, code
  browser with hot reload, and sprite painter — see
  [`docs/EDITOR.md`](docs/EDITOR.md). Still missing: a server *browser*. LAN
  discovery works and `love . --browse` prints the list, but drawing it in the
  shell is still to come.
- **Networking works, with two named gaps.** Listen and dedicated hosting, real
  UDP over `lua-enet`, host-authoritative snapshots, local-player prediction, LAN
  discovery, master-server discovery with a registry you host yourself, UDP hole
  punching, passwords, kick and ban are all implemented and tested. **Not
  implemented:** a relay for the hosts hole punching cannot reach, and the Steam
  transport. Those are designed for rather than stubbed — a transport or a
  discovery backend can be added without touching gameplay code or the browser, and
  `docs/NETWORKING.md` says exactly where each one plugs in. There is also no auth
  service: the engine calls `onAuthenticate` and the game decides.
- **Hole punching is implemented and its success rate is not claimed.** The
  registry introduces both peers and each punches from its own game socket; that
  the packets leave the right socket was watched happening, and NAT traversal
  itself cannot be tested on one machine and is not asserted anywhere. Measured
  real-world success for direct connections is 55–80%, not the 90% usually
  quoted, and there is no relay yet — so a host that cannot be punched through
  still needs a forwarded port or a dedicated server, and is told so.
- **Lighting is off by default.** Per-tile coloured light with falloff, baked
  static sources and per-frame dynamic ones, is implemented in
  `meatray/render/lighting.lua` — but a renderer with no light grid attached
  behaves exactly as it did without one. Attaching it is a call, not a migration:

      local Lighting = require('meatray.render.lighting')
      local lights = Lighting.new{ world = world, baseLevel = 0.34 }
      lights:addStatic{ x = 8.5, y = 3.5, radius = 6, color = { 1, 0.6, 0.24 } }
      MeatRay.raycaster.setLighting(lights)

      -- per frame
      lights:beginFrame()
      lights:addDynamic{ x = px, y = py, radius = 6.5, color = { 1, .86, .62 } }

  Sampling costs `O(samples × dynamic lights)` and nothing per world tile: static
  light is baked once, `lights:invalidateTile(tx, ty)` relights only the
  footprints of the sources that could see the change, and an unchanged world
  does no work. `Lighting.MIN_VISIBILITY` is the floor below which nothing
  renders, so an unlit room is dark rather than unreadable.
- **Weapons, inventory, explosions and gas** (`meatray/game/`), built on the
  ability system rather than beside it, and headless like the rest of it:

  ```lua
  Weapons.define('pistol', { damage = 12, magazine = 12, fireInterval = 0.15 })
  Weapons.equip(player, 'pistol')
  Weapons.fire(player, { world = world, entities = entities })   -- on the host
  ```

  Three things worth knowing before you use any of it:

  **A weapon does not subtract hit points**; it applies a damage *effect*. That is
  what makes armour, resistances, immunities and damage-over-time compose with a
  rifle round, an explosion and a burning floor tile without any of the four
  knowing about the others.

  **The fire rate is enforced in ticks, not in inputs.** `Weapons.fire` reads the
  cooldown and refuses; only `Weapons.tick` — one call per fixed simulation step —
  moves it. A client that sends fire requests faster than the tick rate does not
  fire faster than the tick rate, and there is no configuration in which that is
  untrue, because there is no other writer.

  **The gas field costs what its activity costs.** Cells wake on change and
  settled cells sleep, so `field:step()` on a settled field visits nothing at all,
  and the same disturbance in a 20×20 and a 40×40 world costs the same. With
  `decay = 0` it conserves mass exactly; with decay, the rate is exact and
  everything removed is booked to `field.lost`. Gas does not cross a shut door.

- **No destruction system.** The roadmap orders the rest by dependency.

## Layout

```
meatray/sim/      headless: entities, world, collision, tick, billboard maths,
                  worldgen, map format          <- no love, unit-tested
meatray/net/      headless: wire format, transports (loopback + enet), replication,
                  host and client sessions, discovery, access control, diagnostics
meatray/game/     headless: attributes, effects, tags, abilities, damage, weapons,
                  projectiles, inventory, explosions, gas   <- rules, no love
meatray/render/   raycaster, sprites, textures, themes, lighting
                  (lighting.lua is love-free and unit-tested like the sim)
meatray/ui/       immediate-mode widgets with a real clip stack; rect.lua,
                  server_row.lua and inventory_view.lua are love-free, so the
                  clip/dock/hit maths and every "what does this row say"
                  decision are unit-tested rather than trapped in a panel
meatray/init.lua  public API (render modules load lazily so headless still works;
                  so does meatray.net, which needs no love at all)
tests/            4922 assertions under plain LuaJIT
selftest.lua      graphics-context gate: renders, reads pixels back, writes
                  reference images
nettest.lua       headless networked client that asserts across the wire
netcheck.lua      `--netcheck`: can this machine do UDP at all
netfrag.lua       `--netfrag`: measures the snapshot stream on a real socket —
                  size, delivery under loss, and float32 fidelity
netproxy.lua      `--netproxy`: a UDP relay that drops a configurable fraction,
                  so loss happens to ENet rather than inside our transport
browse.lua        `--browse`: LAN server list, printed
punchcheck.lua    `--punchcheck`: joins through a registry and reports the hole
                  punch with numbers - whether the introduction round trip
                  happened, and that the connect did not wait for it
masterserver/     the reference registry: `love masterserver --port 8110`
bench.lua         `--bench`: fixed camera, wall renderer only, reports draw
                  calls and frame time
scripts/          nettest.ps1 and netfrag.ps1, the multi-process network runners
maps/arena.map    hand-authored sample
```

## License

Licensed under the **[Apache License 2.0](LICENSE)** — free to use, modify, fork
and build on, commercially or not.

**Credit is required.** Apache-2.0 §4(c)–(d) obliges you to keep the copyright
notice and to reproduce [`NOTICE`](NOTICE) in anything you distribute, including
binaries and hosted builds. Credit it as `MeatRayCast by MysteryMeat`
(https://github.com/MidwestMysteryMeat/MeatRayCast) in your credits screen, About
box, or docs.

The DDA wall loop additionally carries **BSD-2-Clause** from its upstream — it is
derived from `raycaster_textured.cpp` by Lode Vandevenne, published with the
[raycasting tutorial](https://lodev.org/cgtutor/raycasting.html) and licensed
BSD-2-Clause by its author. Its notice is reproduced in [`NOTICE`](NOTICE) and the
loop carries an attribution comment. Both licences are permissive and compatible;
ship `NOTICE` alongside `LICENSE` and both attribution requirements are met.
