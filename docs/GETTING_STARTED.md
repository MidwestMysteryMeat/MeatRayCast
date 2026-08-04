# Getting started: your game, not the demo

MeatRayCast is the runtime; your game is a **project** — a folder of maps,
graphs and assets the engine points at, the same split Godot or LÖVE makes.
This walkthrough goes from nothing to a fused, double-clickable exe. Every
step below is also executed mechanically by `scripts/walkthrough.lua`, so if
the doc and the engine ever disagree, the walkthrough fails in CI-adjacent
use before it fails you.

You need: this repo, LÖVE 11.x (`love.exe`/`lovec.exe`, default `F:\LOVE`),
and on Windows, PowerShell for the packaging step.

## 1. Create a project

Either in-game — `love .` → **Projects** → type a name → Enter — or from a
script (what the walkthrough does):

```
luajit scripts/walkthrough.lua projects/mygame     # creates + authors + lints
```

Both produce the same skeleton:

```
projects/mygame/
  project.json      identity: id, name, version, startMap
  maps/level1.map   a small starter level (spawn, an imp, a crystal)
  meatgraphs/       trigger graphs, scanned by filename
  assets/sounds/    art and audio
  README.md         the two commands that matter
```

**Files are the truth.** Saving a new `.map` into `maps/` adds a level; no
manifest editing. `project.json` only carries what a scan cannot know —
the name, the version, and which map boots (`startMap`).

## 2. Play it

```
love . --project projects/mygame
```

The title menu takes the project's name; Continue drops you into its start
map. Everything the demo can do — campaign, hosting, a dedicated server —
works on a project: `love . --server --project projects/mygame` hosts your
game headless.

## 3. Edit it

```
love . --editor --project projects/mygame
```

The whole workspace follows the project: the **Map** panel opens the start
map and **saves back to the project folder** (lint runs on every save), the
trigger tool's graph picker scans the project's `meatgraphs/`, the **Assets**
panel walks the project tree, and the **Audio** panel writes synthesized
WAVs into `assets/sounds/`.

Audio deserves a sentence: the engine ships a parametric SFX synth
(`meatray.asset.sfx` — sfxr lineage). Pick a preset, scrub the variation
seed until it sounds right, Save. A variation is `(preset, seed)` — a number,
reproducible forever, so sounds can live in notes and scripts, not just as
binaries. The same synth is scriptable:

```
luajit scripts/sfx.lua explosion projects/mygame/assets/sounds/boom.wav 99
```

## 4. Ship it

From the editor: the Map panel's **Export game** button. From a terminal:

```
powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Project projects/mygame
```

That stages the engine plus your project (at `project/` inside the archive,
where the runtime auto-mounts it), strips the editor/tests/dev tooling,
fuses a `MyGame.exe` named and versioned from *your* `project.json`, and
boots the result for five seconds to prove a stranger's double-click reaches
the game. Output lands in `build/`.

## What a project carries

- **Content:** maps, trigger graphs (hardened through the F9 sandbox at
  load), sounds/music, sprites and art, name/version/start map.
- **Gameplay code (H5):** `game.lua` in the project root, scaffolded with
  every new project. It returns a `function(api)` the engine calls once
  after the mount — before the first map loads, so archetypes it defines
  exist when markers spawn. The api carries the engine surface
  (`api.engine`, `api.game`), `api.archetype` for entity kinds,
  `api.onTick(fn)` for per-step hooks, and `api.note`. Full trust, like a
  Godot script — the sandboxed lane for *third-party* content remains
  MeatGraphRay. A broken `game.lua` is a console line and a playable stock
  game, never a dead boot; a tick hook that raises is retired with a
  message instead of erroring sixty times a second.

## The three commands, one more time

```
love . --project projects/mygame              play
love . --editor --project projects/mygame     edit
powershell -File scripts/package.ps1 -Project projects/mygame    ship
```
