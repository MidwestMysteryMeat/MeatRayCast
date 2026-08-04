# Hunted — the example project

The smallest complete demonstration of the project seam: a map, a manifest,
and a `game.lua` that defines an entity kind the engine has never heard of.

```
love . --project examples/hunted              play it
love . --editor --project examples/hunted     edit it
powershell -File scripts/package.ps1 -Project examples/hunted    ship it
```

What to look at:

- `game.lua` defines the **stalker** archetype (`entity s stalker` in the
  map). Delete game.lua and the map still loads — the engine logs the
  unknown archetype and plays on. That degradation is the contract.
- `maps/warren.map` is plain text; open it in anything. Saving a new map
  into `maps/` adds it to the project — no manifest editing.
- Zero media: every sprite and texture is procedural, so this folder is
  three text files and runs anyway. Add WAVs with the editor's Audio panel
  or `scripts/sfx.lua`; add a trained brain with `scripts/evolve.lua` and
  meet it in-game via the console (`neurobot 1 <file>`).
