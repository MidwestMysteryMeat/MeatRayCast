# MeatRayCast — genre templates

MeatRayCast is a networked tile-raycast engine, and the game layer on top of it
is all data — modes, weapons, hazards, abilities, stats. A **template** is a
table that says which of those to assemble and how, so the demo can become a
different genre without new code. This is the same idea MeatEngine and Meat2D
ship as per-genre starters, done the way this engine's data-driven layer wants.

Templates live in `meatray.game.template` (the registry, resolution, and
validation) and are launched in the demo with the console:

```
`                       open the console
template                list every genre and its status
template tdm            switch the running demo to Team Deathmatch
```

Each template resolves through its **base chain** — a subset inherits everything
its parent sets and overrides only what differs. `Template.isSubsetOf('tdm',
'fps')` is `true` because that relationship is a fact in the data, not a comment.

## The genres

Every template is honest about how finished it is. **Playable** means the
existing engine systems assemble into a game you can start right now.
**Scaffold** means the config is set but the genre needs a system this engine
does not yet ship — listed under *needs* — because a raycaster claiming to be a
visual-novel engine would waste the time a template exists to save.

| Template | Base | Status | What it is |
|---|---|---|---|
| **fps** | — | ✅ playable | Free-for-all deathmatch. Free-look, real-time combat, respawns. The engine's home genre. |
| **tdm** | fps | ✅ playable | Team Deathmatch: FPS with two teams and a shared frag limit. |
| **coop** | fps | ✅ playable | Co-op Clear: players against the map, clear every enemy to win. |
| **crawler** | rpg | ✅ playable | Dungeon Crawler: grid-step, 90°-turn movement (Eye of the Beholder) with RPG stats and real-time combat. |
| **rpg** | — | 🔶 scaffold | First-person RPG: single-player exploration with character stats. *Needs: dialogue, quests.* |
| **turnrpg** | rpg | 🔶 scaffold | Turn-based RPG: grid movement, turn combat. *Needs: turn engine, dialogue.* |
| **mmo** | rpg | 🔶 scaffold | Persistent MMO on the full net stack. *Needs: account backend, world persistence.* |
| **vn** | — | 🔶 scaffold | Visual Novel: fixed scenes, no combat, no movement; the raycaster renders the backdrop. *Needs: dialogue, scene script, portraits.* |

## The subset tree

```
fps ──┬── tdm         (adds teams)
      └── coop        (win by clearing the map)

rpg ──┬── crawler     (grid movement)
      ├── turnrpg     (grid movement + turn combat)
      └── mmo         (persistent + many players)

vn                    (its own root: dialogue-first, no combat)
```

## What a template controls

A resolved config carries: `mode` (deathmatch / teamDeathmatch / coop / sp /
persistent), `movement` (fps free-look / grid tile-step / static none), `combat`
(realtime / turn / none), the starting `loadout`, `moveSpeed` / `turnSpeed`,
`teams`, `respawn`, `rpgStats`, `persistence`, and the `ready` / `needs` honesty
fields. The demo reads these: applying a template re-equips the player to its
loadout, sets the movement speeds, switches to grid or static movement where the
genre calls for it, grants RPG attributes when `rpgStats` is set, and disables
firing when `combat` is `none`.

## Building on a scaffold

A scaffold template is a real starting point, not a placeholder. `template rpg`
gives you a stat-carrying player exploring in first person — the combat, the
world and the inventory all work; what is left is the genre's own layer:

- **dialogue / quests** (rpg, turnrpg, vn) — a conversation tree and a quest
  log. The MeatGraphRay node system is a natural host for branching dialogue.
- **turn engine** (turnrpg) — initiative, a turn queue, and action points over
  the existing ability/effect system.
- **account backend + world persistence** (mmo) — the save system persists a
  world already; an MMO adds accounts and a shared, always-on store.
- **scene script + portraits** (vn) — a scene format and character art; the
  raycaster draws the backdrop, the story engine drives the beats.

Each is bounded, and each builds on systems that already exist and are tested.
