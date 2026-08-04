# The game.lua API — version 1

The contract between a project's `game.lua` and the engine. The engine
calls your returned `function(api)` once, after your project mounts and
before its first map loads, so archetypes you define exist when map markers
spawn.

**The stability promise:** every name in the STABLE section is covered by
semver — removing or changing one is a MAJOR engine release — and enforced
by `tests/test_project_api.lua`, which asserts each name exists and works
on every push. `api.version` is 1; it only moves when this contract does.

**The escape hatch:** `api.raw.engine` and `api.raw.game` are the full
internal facades. They exist for whatever the curated surface has not named
yet, and they may break on ANY release — code against them knowingly, and
tell us what you needed so it can be promoted. (`api.engine` / `api.game`
are deprecated aliases of the same tables, kept so pre-v1 projects load.)

## STABLE

### Identity & plumbing

```lua
api.version              -- 1
api.project              -- your project: .manifest, :mapIds(), :startMapId()
api.note(text)           -- one line into the console log
api.isAuthority()        -- may this machine's code mutate attributes?
api.onTick(fn)           -- fn(dt) every fixed step; a raising hook is
                         -- retired with a console line, not sixty errors/s
api.rng(seed)            -- the engine LCG (:float() :int(lo,hi) :next()) —
                         -- anything deterministic uses this, never math.random
```

### Entities

```lua
api.archetype(name, function(e) ... end)   -- define a kind; map `entity X name`
                                           -- markers spawn it
api.component(name, def)                   -- define a component
api.components                             -- stock constructors: Billboard,
                                           -- Health, Brain, Player, Weapon, Input...
api.attach(e, { authority = api.isAuthority() })  -- ability/attribute container
api.ai.attach(e, { state = 'patrol', alertRange = n, speed = n })
                                           -- the monster brain; gate on
                                           -- isAuthority like the stock imp does
```

### Data definitions

```lua
api.define.weapon(name, def)     -- hitscan or projectile; see app/content.lua
api.define.item(name, def)       -- inventory items, ammoFor wiring
api.define.effect(name, def)     -- timed modifiers, tags, stacking
api.define.explosion(name, def)  -- radius/damage/gas/light descriptions
```

### Sound

```lua
api.sound.synth(name, presetOrParams, opts)  -- ZERO-MEDIA audio: rendered
                                             -- from synth params, overridden
                                             -- by declaring a real WAV later
api.sound.declare(name, { path = ... })      -- file-backed
api.sound.play(name, opts)
api.sound.playAt(name, x, y, opts)           -- positional vs the listener
```

### Player-facing channels

```lua
api.messages.centerprint(text, opts)   -- the exclusive centre message
api.messages.notify(text)              -- the ticker
```

### Console

```lua
api.console.register(name, { help = ..., cheat = bool }, function(_, args) ... end)
api.console.cvar(name, { default = ..., help = ..., onChange = ... })
```

Registrations queue until the console exists and flush in order — from your
side it is invisible; register and the command is there.

## A complete example

`examples/hunted/game.lua` is written against exactly this surface and
boots on a dedicated server, a listen host and solo alike. The short form:

```lua
return function(api)
    local C = api.components
    api.archetype('stalker', function(e)
        e:add(C.Billboard{ sheet = 'stalker' })
        e:add(C.Health{ hp = 20, max = 20 })
        e:add(C.Brain{ state = 'patrol' })
        e.radius = 0.26
        api.attach(e, { authority = api.isAuthority() })
        if api.isAuthority() then
            api.ai.attach(e, { state = 'patrol', alertRange = 12, speed = 3.0 })
        end
    end)
    api.sound.synth('stalker.hiss', 'hurt')
    api.console.register('stalkers', { help = 'count them' }, function()
        return 'they are always closer than you think'
    end)
end
```

## What is NOT here yet

Candidates for version 2, in the order projects will probably want them:
per-tick queries (nearest player, line of sight) without `api.raw`; a mode/
rules hook (win conditions in the project); campaign definition; HUD
extension points. Ask by building against `api.raw` and reporting what you
touched.
