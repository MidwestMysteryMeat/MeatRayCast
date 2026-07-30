# The editor shell

`love . --editor` opens one workspace, not four separate tools. Panels dock and
tab inside it, so the map editor, code browser, asset browser, sprite painter and
console share a shell — and every tool added later gets a home for free instead of
another launch flag.

```
+----------+---------------------------+-----------+
| files    | [map] [code] [sprite]     | inspector |
| assets   |                           |           |
|          |     (active panel)        | tile: 2   |
|          |                           | door: no  |
+----------+---------------------------+-----------+
| console: reloaded game/archetypes.lua (3 archetypes)
+---------------------------------------------------+
```

The shell is built on the GUI toolkit (roadmap phase 3), which is deliberately
built *before* its first consumer. Four tools need panels, buttons, scroll regions
and text fields; a toolkit extracted after the first one is written ends up shaped
by that one caller and fits the rest badly.

It must be strippable from a release build. An engine that ships its editor inside
every game is fine for a jam and wrong for a product, so the editor lives behind
one entry point that a shipped `main.lua` simply never calls.

---

## Code browser

**Browse, view, quick-edit, hot-reload on save — and hand off to a real editor for
real work.**

- File tree over the project, with the engine's own source readable too. Reading
  `entity.lua` to check a signature should not require alt-tabbing.
- Syntax-highlighted viewer.
- Editing for the small stuff: change a number, save, watch it apply.
- **`Open in external editor`** for anything serious. VS Code exists and is better
  at this than an in-engine editor will ever be; the honest design is to make the
  handoff one click rather than to lose months reimplementing find-and-replace,
  an undo stack, multi-cursor and clipboard semantics badly.
- Modified files marked, unsaved changes never silently discarded.

## Hot reload: data and definitions, not modules

This is the boundary that keeps reload trustworthy.

**Reloads live:**

- archetypes (`Entity.archetype` registrations)
- sprite definitions
- themes and atmosphere presets
- maps
- tuning tables and constants

**Requires a restart:** the `meatray/sim/*` and `meatray/render/*` modules
themselves.

Live entities keep running and keep their state. Re-spawning picks up the new
definition. That covers the loop that actually matters — tweak a number, feel the
difference — without pretending to solve the hard version.

The hard version is full module reload with state migration, and it is refused on
purpose. `package.loaded[m] = nil; require(m)` leaves closures holding upvalues
captured over the *old* module, metatable identity comparisons failing against
instances built by the previous version, and stale references from anything that
cached a function. The result is a class of bug that only exists after a reload and
cannot be reproduced from a clean boot, which is close to the worst debugging
experience a tool can hand you. Boot is fast because the engine loads no assets, so
a restart costs a couple of seconds — a much better trade than phantom bugs.

Practically: reload rebuilds registries rather than mutating them. Archetype and
sprite registries already support this (`Entity.clearArchetypes`,
`Sprites.clear`), so a reload re-runs the game's definition file against a cleared
registry. Anything holding a direct reference to a definition table must look it up
by name instead, which is why the registries are keyed by name in the first place.

## Asset browser

**Browse, preview, import.**

- Thumbnail grid by category: sprites, maps, sounds, themes.
- Live preview that tells you something: step a sprite sheet through its angle
  buckets and play its animation, audition a WAV, open a map.
- **Import** wires a file into the registry with its grid, angle-bucket and frame
  counts — the settings that are easy to get wrong by hand and immediately obvious
  when you can see bucket 3 of 8 rendered.
- `Reveal in folder` for the filesystem.

Asset import itself is roadmap phase 4, and the browser is its front end. The
registry's procedural fallback stays in force: a project with no assets keeps
running, and one with half its assets shows exactly which half is missing rather
than crashing on the first lookup.

## Sprite painter

**Draw the sheet in the engine that has to draw it back.**

The reason this exists is narrower than "the editor should have a paint tool". A
sheet is `angles` **rows** of angle buckets by `frames` **columns** of animation
frames. Author an eight-bucket directional sheet in an external editor, get the
bucket order wrong, and it looks perfect in the art tool and renders as an enemy
walking toward you showing its back. Nothing catches it until it is in the game.

So the grid is the subject, not the background:

- **Canvas** with zoom, pan, a pixel grid, and cell boundaries drawn heavier than
  the pixel grid, with `b0..b7` and `f0..f3` labels in the margin.
- **Brush, eraser, flood fill, colour picker and rectangle**, all confined to the
  active cell by default. Clicking anywhere makes that cell active first, so a
  stroke can never straddle a boundary by accident, and a fill in one frame cannot
  flood every bucket in the sheet.
- **Onion skin** of the previous frame under the current one while animating.
- **Live preview** running `meatray.sim.billboard` — the same module
  `meatray.render.sprites` calls, not a lookalike — with sliders for where the
  entity is turned and where the camera is standing. `Edit this cell` jumps the
  canvas to whatever the preview is showing, so a wrong-looking bucket is one
  click from being the one you are painting.
- **Regrid** reinterprets the same pixels under a different grid without moving
  one. Flip `8 x 4` to `4 x 8` and look, rather than exporting to find out.
- **Export + register** writes `assets/sprites/name_a8_f4.png` and imports it, so
  the sheet you just painted is the sprite the renderer is now drawing. The
  filename carries the grid, which is what `meatray.asset.names` parses back out.

Export verifies its own round trip: it writes the PNG, reads it straight back, and
compares every byte. The painter's palette is stored as integer RGBA rather than
floats precisely so that comparison can pass — a float palette quantises on the
way out and comes back different, and "the file does not hold what I drew" is the
one failure a painter must not have.

**Undo stores diffs, not canvases**, bounded by both a step count and a total
pixel count. Snapshotting the canvas per edit is the version everyone writes
first; on a 256x256 eight-bucket sheet that is 65,536 pixels a step, and memory
then grows with how long you have been drawing rather than with what you drew. A
diff costs the pixels the edit touched, and its worst case — a fill over the whole
sheet — costs exactly what a snapshot would have. One deliberate exception: a
single step larger than the whole budget is kept anyway, because an undo button
that declines to undo the last thing you did is worse than a bound that stretches
once.

## Inspector

Context panel for the current selection: the tile under the cursor and its
texture, a door and its initial state, an entity marker and its archetype, the
map's own metadata. Editing happens here rather than in modal dialogs, which
keeps the map visible while you change what is on it.

## Console

Reload results, import warnings, map parse errors with line and column, and
network diagnostics. Errors belong somewhere persistent and scrollable — a message
that flashes for two seconds over the viewport is a message you will miss.

---

## Build order

1. GUI toolkit: panels, docking, tabs, buttons, sliders, scroll regions, text
   fields, a nested clip stack (`love.graphics.setScissor` has none, and nested
   panels need one).
2. Editor shell: layout, docking, tab switching, console.
3. Map editor panel: tile paint, doors, spawn, entity markers, theme, plus the
   live first-person preview.
4. Asset browser panel (needs phase 4 import).
5. Code browser panel with data/definition hot reload.
6. Sprite painter panel (needs the toolkit and the asset pipeline).

Phases 1-6 are built. The painter's pixel model, cell arithmetic, flood fill,
palette, undo bound and byte-level round trip are asserted headlessly in
`tests/test_paint_sheet.lua` and `tests/test_paint_history.lua`; everything that
needs a real ImageData or a real PNG encoder is in `selftest.lua`.
