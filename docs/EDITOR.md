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
