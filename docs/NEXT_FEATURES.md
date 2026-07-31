# Next features (most → least important)

> **Active schedule + full status board:** [`BACKLOG_SCHEDULE.md`](BACKLOG_SCHEDULE.md)  
> Includes all pending IDs, Wave F (10 researched features), and automation notes.

Prioritized for **MeatRayCast as a shippable multiplayer raycast engine**, not as a
render toy. Ordering weights: *what blocks a real game*, *what OSS/commercial
peers solved decades ago*, *what still fits the headless + netFields + Apache-2.0
constraints*.

**Status baseline (already strong):** textured walls, floor/ceiling cast, pitch,
sprites/billboards, lighting, thin walls, variable height/slabs, walkable
elevation, in-world multi-storey + multi-map links, destruction, gas, weapons,
projectiles, AI pathfind (incl. stairs), triggers, MeatGraphRay, dirty net
snapshots, lag compensation, Steam/LAN/relay/punch, save, editor, music + SFX,
asset LRU, BSP + Delaunay/MST worldgen.

---

## Field scan (what peers actually ship)

| Product / lineage | Kind | Features that define “complete enough” |
|---|---|---|
| **Wolfenstein 3D / wolf4sdl / ports** | Classic raycaster | Secret push-walls, doors with anim, static + animated sprites, enemy AI states, weapons, HUD, level progression, sound cues |
| **Lode’s tutorials + hobby engines** (e.g. RayCast.js, andrew-lim/sdl2-raycast) | Teaching / tech demos | Floors/ceilings, free-look y-shear, variable wall height, slopes, diagonal collision, minimap, skybox, alpha walls |
| **Build / EDuke32 / Raze** | Sector “2.5D” (not pure tile DDA) | Sectors with independent floor/ceil, slopes, sprites as map objects, TROR (true room-over-room), CON/scripting, multiplayer, modern GL path |
| **Doom / GZDoom / ZDoom** | BSP + portals | Linedefs, 3D floors, portals, ACS/ZScript, ACS inventory, netcode (Zandronum etc.), deep mod pipeline |
| **id Tech 1→5 / modern FPS** | Full 3D | Not feature targets — only *product* lessons: load screens, options, input remapping, accessibility, anti-cheat boundaries |
| **MeatRayCast (this repo)** | Tile DDA + layers | Sits between Wolf and Build: multi-storey layers ≈ cheap ROR; slabs/elevation ≈ partial Build; **net stack is ahead of most hobby raycasters** |

**Negative result (unchanged):** open tile-grid **mirrors / recursive portals** still have no clean public implementation. Build/Doom solve “rooms over rooms” and portals with *different* geometry models, not by bolting portals onto Wolf DDA.

**Takeaway:** the next wins for this engine are mostly **game product + authoring +
content pipeline**, not another render experiment—unless the goal is to become
Build-class geometry (a multi-year architectural bet).

---

## Priority list

### P0 — Must have to ship a *game* (not a demo)

These are what Wolf, Duke, and every shipped FPS treat as non-optional.

| # | Feature | Why (field + MeatRay gap) | Fit |
|---:|---|---|---|
| 1 | **Campaign / mission flow** | Levels → win/lose → next map → credits. Wolf map progression; Doom WAD episodes; Duke level exit. Engine has maps + mode template; no first-class campaign graph, checkpoint, or end-condition package. | High value, mostly sim/mode glue |
| 2 | **Game rules modes (beyond template)** | Deathmatch / co-op / single-player objectives as *data*, not main.lua. Zandronum/EDuke modes; your `mode.lua` is a start. Need scoring, respawn policy, round timer, team, spectator as reusable modes. | High; uses existing host authority |
| 3 | **Input remapping + options menu** | Every commercial port (EDuke32, GZDoom, Raze). Missing = unshippable for anyone who isn’t you. Mouse sens, invert, keybind file, volume buses (SFX/music already exist). | High; UI + save |
| 4 | **HUD / crosshair / feedback package** | Wolf status bar, Doom HUD, damage flash, ammo/health/armor widgets as engine kit (not one-off main.lua). | High; render/UI |
| 5 | **Death, respawn, invuln window** | Multiplayer FPS baseline. Lag-comp hits already exist; need authoritative die/respawn/spawn-protect + client feedback. | High; net + mode |
| 6 | **Push-walls / secrets / interactive props** | Wolf signature; Build `HITAG`/`LOTAG` style activators. Triggers exist—need canonical “secret found”, score, map stats. | Medium-high; map + triggers |
| 7 | **Serializable keybinds + graphics options** | Resolution scale, look sens, FOV/pitch clamp, quality presets—Raze/GZDoom all do this. | Medium-high |
| 8 | **In-game pause + host migration policy** | Single-player pause; multiplayer: pause denied or host-only; disconnect rules. | Medium |

### P1 — Authoring & content (what makes engines *used*)

Build and Doom ecosystems win on **tools**, not pixel shaders.

| # | Feature | Why | Fit |
|---:|---|---|---|
| 9 | **Entity / spawn palette in editor** | Place imps, items, lights, triggers without hand-editing map text. Build Mapster; Doom UDB. You have map panel—needs entity browser + properties. | High |
| 10 | **Trigger / MeatGraph authoring UX** | Volumes on plan view; graph pickers; validate graphs on save. ACS/ZScript/CON exist because designers can’t ship on raw C. | High |
| 11 | **Prefab rooms / prefab entities** | Copy-paste rooms, stamp kits (armory, stairwell). Speeds campaigns more than worldgen cleverness. | Medium-high |
| 12 | **Map validation linter** | Unreachable rooms, missing spawn, door without open path, storey stairs unpaired, orphan links. CI-friendly (`luajit` check). | Medium-high |
| 13 | **Asset pack format** | Zip/dir pack: maps + sounds + sprites + `pack.json` manifest; load one pack = one game. | Medium |
| 14 | **Hot-reload maps in running host** | Editor → play loop. Indispensable for level design velocity. | Medium |
| 15 | **Localization strings table** | UI + notes + mode text. Cheap; required for any non-English ship. | Medium |

### P2 — Gameplay systems peers take for granted

| # | Feature | Why | Fit |
|---:|---|---|---|
| 16 | **Inventory UX + use/pickup feedback** | Model exists; player-facing bag UI incomplete per older roadmap notes. | High for RPG/loot FPS |
| 17 | **Doors: keys, locked states, auto-close** | Wolf/Build staples. Doors open; key-gated + timed close less complete as a kit. | High |
| 18 | **Elevators / moving platforms (scripted)** | Build movers; Doom lifts. You have elevation *static*; need timed/triggered floor motion + net sync. | Medium-high; careful netFields |
| 19 | **Better AI kit** | Search last-known position, investigate sound, squad roles, idle anim. EDuke/GZDoom monsters. Pathfind+chase exist. | Medium |
| 20 | **Dialogue / cutscene / camera rails** | Even short boomer shooters use message + freeze. Optional for pure DM. | Medium-low for arena; high for campaign |
| 21 | **Scripted events library** | “On all dead → open door”, “timer → spawn wave”. MeatGraphRay partial; need stock nodes. | Medium |
| 22 | **Bot players for offline / fill lobbies** | Source ports and modern FPS. Uses AI + player component spoof. | Medium |
| 23 | **Persistent progression (unlocks, meta)** | Between campaigns; save already exists. | Medium-low |

### P3 — Presentation (looks “finished”)

RayCast.js and modern ports emphasize these; pure Wolf is thinner.

| # | Feature | Why | Fit |
|---:|---|---|---|
| 24 | **Skybox / sky floor outdoor** | RayCast.js parallax sky; Build parallax. Outdoor maps feel empty without it. | Medium |
| 25 | **Transparent / masked walls** | Fences, grates, windows. Common in Build; careful with DDA + sorting. | Medium; render complexity |
| 26 | **Animated wall textures / switches** | Build wall animation; Doom switch textures. | Medium |
| 27 | **Particle / impact VFX kit** | Beyond decals: tracers, sparks, smoke puffs as billboards. | Medium |
| 28 | **Screen effects library** | Damage red, underwater, undercrouch, pickup flash—consistent API. | Medium |
| 29 | **Minimap (fog of war optional)** | Almost every hobby raycaster + Build automap. | Medium |
| 30 | **Footsteps / surface materials** | Audio richness; surface tags on tiles. | Medium-low |
| 31 | **Ambient sound zones** | Room tones; Build reverb rooms (simplified). | Medium-low |

### P4 — Multiplayer productization

Net *tech* is ahead of most raycasters; **product** multiplayer still matters.

| # | Feature | Why | Fit |
|---:|---|---|---|
| 32 | **Server browser polish** | Filters, ping, game mode, map, dedicated vs listen. Partial exists. | High for multiplayer games |
| 33 | **Dedicated server console / RCON** | Kick, map change, say, status—EDuke/Zandronum. | High for ops |
| 34 | **Anti-cheat *boundaries* (not ML)** | Already clamp lag-comp; add rate limits, invalid input reject metrics, admin tools. | Medium-high |
| 35 | **Spectator mode + killcam (simple)** | Modern expectation in MP; optional. | Medium |
| 36 | **Voice chat** | Usually external (Steam/Discord); engine hook optional. | Low unless required |
| 37 | **Field validation completion** | NAT punch, public master/relay, Steam 2-account—see `FIELD_QA.md`. | Ops, not code |

### P5 — Geometry / research (expensive, optional identity)

Only if the engine’s *identity* is “Build-class in Lua”, not “networked Wolf+”.

| # | Feature | Why | Fit |
|---:|---|---|---|
| 38 | **True slopes (walk + render)** | RayCast.js slopes; Build slopes. Partial elevation ≠ continuous slope mesh. | Hard; collision + floor cast |
| 39 | **Non-orthogonal thin walls everywhere** | Segments exist; gameplay/AI/doors must treat them as first-class. | Medium-hard |
| 40 | **Build-style sectors** | Independent floor/ceil per region, not tile grid. **Different engine.** | Architectural rewrite |
| 41 | **TROR / portal rendering** | EDuke TROR; Doom portals. Your **layers** solve many gameplay cases cheaper. | Prefer layers; portals research |
| 42 | **Mirrors / recursive portals** | Still no good OSS tile-DDA reference (`RESEARCH.md`). | Defer indefinitely |
| 43 | **GPU DDA / compute path** | melchor629-style; performance headroom, not features. | Optional later |
| 44 | **Software soft-skin / MD2-like** | Rare in raycasters; full 3D engines own this. | Out of scope |

### P6 — Nice-to-have / ecosystem

| # | Feature | Why | Fit |
|---:|---|---|---|
| 45 | **Mod / workshop pipeline** | Load user packs safely; sandbox MeatGraph. | Later |
| 46 | **Replay / demo recording** | Debug net + content marketing. | Medium-low |
| 47 | **Benchmark suite as product** | You have benches; ship as `--bench` report for contributors. | Low |
| 48 | **Mobile / touch controls** | LÖVE can; different product. | Low |
| 49 | **Web export** | love.js path; large effort. | Low |
| 50 | **Path-traced / RT GI** | Wrong problem domain (Godot/Wicked). | Skip |

---

## Recommended execution batches

### Batch A — “Ship a vertical slice game” (do first)

1. Campaign flow + map exits  
2. Death / respawn / spawn protect  
3. Options + key rebind  
4. HUD kit  
5. Locked doors + keys + secrets  
6. One stock mode: co-op campaign **or** DM  

**Exit criterion:** a stranger can finish a 3-map campaign with keyboard they chose, without reading source.

### Batch B — “Designers can build without you”

7. Editor entity palette + properties  
8. Trigger/MeatGraph plan tools  
9. Map linter in CI  
10. Asset pack load  

**Exit criterion:** a second person authors a map+graph and it runs on dedicated server unchanged.

### Batch C — “Feels like a 90s FPS product” · **in progress (core landed)**

11. Sky gradient + yaw parallax — **done** (`raycaster` outdoor bands)  
12. Masked walls + wall anim cycles — **done** (`world:setMasked` / `setWallAnim`)  
13. Elevators (synced) — **done** (`meatray.sim.movers`)  
14. Minimap — **done** (`meatray.render.minimap`, `M` in demo)  
15. AI investigate / last-known — **done** (`investigate` state)  

Still open in C: animated *switch* entities as map kit, denser sky textures.

### Batch D — “Multiplayer as a service”

16. RCON / server console  
17. Browser filters  
18. Spectator  
19. Complete `FIELD_QA.md` on real hardware  

### Batch E — Geometry · **partial**

20. Continuous slopes — **done** (`smoothFloors` bilinear vertex-max)  
21. Deeper sector model — open  
22. Portal research prototype — open / deferred  


---

## Explicit non-goals (for now)

| Non-goal | Reason |
|---|---|
| Competing with Godot/Unity full 3D | Different product |
| Perfect Build/Doom compatibility | Different world models; layers + maps are enough for most FPS layouts |
| Mirrors as a near-term milestone | No public algorithm path worth the risk |
| More worldgen algorithms | MST+BSP is enough; content tools beat generators |
| Voice chat in-engine | Prefer Steam/Discord |

---

## Mapping: peer feature → MeatRay status

| Peer staple | MeatRay today | Next action |
|---|---|---|
| Textured walls / sprites | Done | — |
| Floor/ceiling | Done | Sky outdoor |
| Multiplayer host authority | Done (strong) | Modes, RCON, field QA |
| Room over room | Layers + multi-map | Prefer polish over portals |
| Scripting | MeatGraphRay | Stock nodes + editor UX |
| Level editor | Present | Entities + validation |
| Slopes | Partial (steps/elev) | Full slopes later |
| Campaign | Maps only | Mission graph |
| Options/remapping | Minimal | P0 batch |
| Secrets / keys | Partial | First-class kit |

---

## One-line strategy

> **Stop expanding the renderer until a complete game loop, options, HUD, and
> designer tools exist.** MeatRayCast’s differentiator is already *networked +
> headless + multi-storey tile FPS*; the field shows that **ports win on tools
> and product chrome**, and **Build/Doom win on geometry**—chase product first,
> geometry only if the game design requires it.

---

*Written against the OSS/commercial survey above and repo state as of the
music/streaming/worldgen closeout. Revisit after Batch A ships.*
