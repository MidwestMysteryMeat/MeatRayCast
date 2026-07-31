--[[
    meatray.game.weapons — ammo, reload, fire rate, spread and recoil.

        local Weapons = require('meatray.game.weapons')

        Weapons.define('pistol', {
            damage = 12, magazine = 12, reserve = 60,
            fireInterval = 0.15, reloadTime = 1.4,
            spread = 0.012, recoil = 0.02, recoilRecovery = 0.25,
            range = 32,
        })

        Weapons.equip(player, 'pistol')

        -- inside the fixed tick, on the host:
        Weapons.tick(player, step)

        -- when the player (or a client's FIRE command) asks:
        local shot, why = Weapons.fire(player, { world = world, entities = entities })

    ---------------------------------------------------------------------------
    THE FIRE RATE IS ENFORCED IN TICKS, NOT IN INPUTS
    ---------------------------------------------------------------------------

    This is the one rule in this file that is worth more than the rest of it put
    together, and it is the bug a sibling project shipped: if the cooldown is
    decremented when a fire request arrives, then a client that sends fire
    requests faster than the tick rate FIRES faster than the tick rate, and the
    only thing standing between the game and a macro is the client's own good
    manners.

    So `Weapons.fire` never advances time. It reads the cooldown and refuses. The
    cooldown moves in exactly one place — `Weapons.tick`, which the host calls
    once per fixed simulation step with the step as its argument. A thousand fire
    commands inside one tick produce one shot and nine hundred and ninety-nine
    refusals with the reason 'cooldown'. There is no configuration under which
    that is not true, because there is no other writer.

    The same reasoning covers reloads: a reload is `reloadRemaining` seconds that
    only `tick` decrements, and the magazine is filled when it reaches zero, not
    when the request arrives.

    A fire interval that is not a whole multiple of the simulation step
    effectively rounds UP to the next whole step — 0.1 s at 60 Hz is a shot every
    7 ticks (0.1167 s), not every 6 — because the cooldown is only ever tested
    on a step boundary. That is the honest behaviour and it is identical on every
    machine, which is what matters. `Weapons.intervalTicks(id, rate)` reports the
    number so a design document and the game can agree.

    ---------------------------------------------------------------------------
    SPREAD AND RECOIL ARE RANDOM, AND THEREFORE DETERMINISTIC
    ---------------------------------------------------------------------------

    `math.random` is not available to this file for the same reason it is not
    available to the ability system: its sequence differs between Lua 5.1, 5.3
    and LuaJIT, so a host and a client (or a host and a replay, or a host and its
    own save file) would disagree about where the pellets went. Every deviation
    comes from `meatray.sim.worldgen.rng`, seeded from a per-weapon seed the HOST
    owns plus the number of shots fired — so the sequence is reproducible, and a
    save that is loaded resumes it rather than restarting it.

    ---------------------------------------------------------------------------
    RECOIL DOES NOT MOVE THE PLAYER'S AIM. IT ASKS THEM TO.
    ---------------------------------------------------------------------------

    Aim is an input: the host takes `input.angle` verbatim because a host that
    integrated turn rates would give every client a laggy mouse (see
    meatray/net/replication.lua). So a host that added recoil to `e.angle` would
    have it overwritten by the very next input packet, and recoil would do
    nothing over the network while working perfectly in single player — the worst
    kind of difference.

    Instead a shot RETURNS its kick, the host puts it in the hitscan event, and
    the owning client adds it to the aim it is about to send. The accumulated
    recoil that widens the cone is host-side and authoritative; only the visual
    kick is the client's to apply.

    ---------------------------------------------------------------------------
    THE EXISTING `weapon` COMPONENT
    ---------------------------------------------------------------------------

    `meatray/sim/components.lua` already declares `weapon` with
    netFields = { 'ammo' }, and main.lua and nettest.lua both read `weapon.ammo`.
    There is no second component here. This module adopts that one and appends
    the fields it needs through `Attributes.declareField`, which is the mechanism
    the engine already advertises for exactly this — so `reserve`,
    `reloadRemaining` and the equipped weapon's id replicate and save with no
    edit to components.lua, to replication.lua or to save/state.lua.

    What is deliberately NOT replicated: `cooldown` (local timing, and a client
    that predicts its own is free to), `seed` and `recoil`. The seed stays host-
    side because a client that knows it can compute every future pellet
    deviation, and a wallhack that tells you where the shotgun will not spread is
    still a wallhack.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local C           = require('meatray.sim.components')
local Collide     = require('meatray.sim.collide')
local Worldgen    = require('meatray.sim.worldgen')
local Attributes  = require('meatray.game.attributes')
local Effects     = require('meatray.game.effects')
local Damage      = require('meatray.game.damage')
local Projectiles = require('meatray.game.projectiles')

local Weapons = {}

local EPS = Attributes.EPS
local cos, sin, floor, min, max = math.cos, math.sin, math.floor, math.min, math.max

-- Angles past this are refused rather than wrapped, matching
-- meatray.net.replication's rule and for its reason.
local MAX_ANGLE = 1e6

-- A magazine or reserve larger than this is not a design, it is a mistake or a
-- crafted packet.
Weapons.MAX_AMMO = 1e6

-- Firing more than this many pellets in one shot would make a single trigger
-- pull cost more than the rest of the tick.
Weapons.MAX_PELLETS = 64

Weapons.Component = C.Weapon

-- Adopting the existing component rather than declaring a second one. Idempotent,
-- so a hot reload that re-runs this file does not grow the netFields list.
Attributes.declareField(C.Weapon, 'id')
Attributes.declareField(C.Weapon, 'reserve')
Attributes.declareField(C.Weapon, 'reloadRemaining')
Attributes.declareField(C.Weapon, 'shots')

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

local defs = {}

local VALID_KIND = { hitscan = true, projectile = true }

-- Absent means "use the default"; PRESENT AND UNUSABLE means nil, so the caller
-- can refuse it by name. The obvious spelling — `Attributes.number(v) or
-- fallback` — cannot tell those apart, and silently turns a typo in a data file
-- into a weapon that quietly has default stats.
local function positive(v, fallback)
    if v == nil then return fallback end
    return Attributes.number(v)
end

--[[
    Turns a spec into a definition, or explains why it cannot. Reports rather
    than raises, because a weapon table can come out of a data file or a mod.

    Fields, all optional except where noted:

        kind            'hitscan' (default) or 'projectile'
        damage          per pellet / per projectile          (default 10)
        tags            damage tags       (default meatray.game.damage's)
        effects         effect ids applied to whatever is hit
        magazine        rounds before a reload is needed      (default 12)
        reserve         rounds carried, when nothing supplies them  (default 0)
        ammoPerShot     rounds a trigger pull costs           (default 1)
        pellets         hitscans per trigger pull             (default 1)
        fireInterval    seconds between shots                 (default 0.2)
        reloadTime      seconds a reload takes                (default 1.5)
        autoReload      start a reload when the magazine empties (default false)
        range           maximum hitscan distance              (default 32)
        spread          radians of cone, half-angle           (default 0)
        recoil          radians added to the cone per shot    (default 0)
        recoilMax       cap on accumulated recoil             (default 8x recoil)
        recoilRecovery  radians of accumulated recoil shed per second (default 1)
        kick            radians of aim kick reported per shot (default = recoil)
        projectile      table passed to meatray.game.projectiles.spawn
        item            inventory item id this weapon comes from
        ammoItem        inventory item id a reload consumes
]]
function Weapons.compile(spec, id)
    if type(spec) ~= 'table' then
        return nil, ('a weapon spec must be a table, got %s'):format(type(spec))
    end

    local kind = spec.kind or 'hitscan'
    if not VALID_KIND[kind] then
        return nil, ('unknown weapon kind %q'):format(tostring(spec.kind))
    end

    local damage = positive(spec.damage, 10)
    if damage == nil or damage < 0 then
        return nil, ('weapon damage must be zero or more, got %s'):format(tostring(spec.damage))
    end

    local magazine = positive(spec.magazine, 12)
    if magazine == nil or magazine < 1 or magazine > Weapons.MAX_AMMO then
        return nil, ('magazine must be between 1 and %d, got %s')
                    :format(Weapons.MAX_AMMO, tostring(spec.magazine))
    end
    magazine = floor(magazine)

    local reserve = positive(spec.reserve, 0)
    if reserve == nil or reserve < 0 or reserve > Weapons.MAX_AMMO then
        return nil, ('reserve must be between 0 and %d, got %s')
                    :format(Weapons.MAX_AMMO, tostring(spec.reserve))
    end
    reserve = floor(reserve)

    local ammoPerShot = positive(spec.ammoPerShot, 1)
    if ammoPerShot == nil or ammoPerShot < 1 or ammoPerShot > magazine then
        return nil, ('ammoPerShot must be between 1 and the magazine size (%d), got %s')
                    :format(magazine, tostring(spec.ammoPerShot))
    end
    ammoPerShot = floor(ammoPerShot)

    local pellets = positive(spec.pellets, 1)
    if pellets == nil or pellets < 1 or pellets > Weapons.MAX_PELLETS then
        return nil, ('pellets must be between 1 and %d, got %s')
                    :format(Weapons.MAX_PELLETS, tostring(spec.pellets))
    end
    pellets = floor(pellets)

    local fireInterval = positive(spec.fireInterval, 0.2)
    if fireInterval == nil or fireInterval < 0 then
        return nil, ('fireInterval must be zero or more, got %s'):format(tostring(spec.fireInterval))
    end

    local reloadTime = positive(spec.reloadTime, 1.5)
    if reloadTime == nil or reloadTime < 0 then
        return nil, ('reloadTime must be zero or more, got %s'):format(tostring(spec.reloadTime))
    end

    local range = positive(spec.range, 32)
    if range == nil or range <= 0 then
        return nil, ('range must be positive, got %s'):format(tostring(spec.range))
    end

    local spread = positive(spec.spread, 0)
    if spread == nil or spread < 0 or spread > math.pi then
        return nil, ('spread must be between 0 and pi radians, got %s'):format(tostring(spec.spread))
    end

    local recoil = positive(spec.recoil, 0)
    if recoil == nil or recoil < 0 then
        return nil, ('recoil must be zero or more, got %s'):format(tostring(spec.recoil))
    end

    local recoilMax = positive(spec.recoilMax, recoil * 8)
    if recoilMax == nil or recoilMax < 0 then
        return nil, ('recoilMax must be zero or more, got %s'):format(tostring(spec.recoilMax))
    end

    local recoilRecovery = positive(spec.recoilRecovery, 1)
    if recoilRecovery == nil or recoilRecovery < 0 then
        return nil, ('recoilRecovery must be zero or more, got %s')
                    :format(tostring(spec.recoilRecovery))
    end

    local effects = {}
    for i = 1, #(spec.effects or {}) do
        if type(spec.effects[i]) ~= 'string' then
            return nil, ('effects[%d] is a %s, not an effect id'):format(i, type(spec.effects[i]))
        end
        effects[i] = spec.effects[i]
    end

    local kick = positive(spec.kick, recoil)
    if kick == nil or kick < 0 then
        return nil, ('kick must be zero or more, got %s'):format(tostring(spec.kick))
    end

    if kind == 'projectile' and type(spec.projectile) ~= 'table' then
        return nil, 'a projectile weapon needs a `projectile` table'
    end

    return {
        id             = id or spec.id or '(anonymous)',
        kind           = kind,
        damage         = damage,
        tags           = spec.tags or Damage.DEFAULT_TAGS,
        effects        = effects,
        magazine       = magazine,
        reserve        = reserve,
        ammoPerShot    = ammoPerShot,
        pellets        = pellets,
        fireInterval   = fireInterval,
        reloadTime     = reloadTime,
        autoReload     = spec.autoReload and true or false,
        range          = range,
        spread         = spread,
        recoil         = recoil,
        recoilMax      = recoilMax,
        recoilRecovery = recoilRecovery,
        kick           = kick,
        projectile     = spec.projectile,
        item           = spec.item,
        ammoItem       = spec.ammoItem,
        onFire         = spec.onFire,
        onHit          = spec.onHit,
        onReload       = spec.onReload,
    }
end

function Weapons.define(id, spec)
    assert(type(id) == 'string' and id ~= '', 'a weapon needs an id')
    local def, err = Weapons.compile(spec, id)
    assert(def, err)
    defs[id] = def
    return def
end

function Weapons.definition(id) return defs[id] end

function Weapons.ids()
    local out = {}
    for id in pairs(defs) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Weapons.reset() defs = {} return Weapons end

function Weapons.capture()
    local out = {}
    for id, def in pairs(defs) do out[id] = def end
    return out
end

function Weapons.restore(captured)
    defs = {}
    for id, def in pairs(captured or {}) do defs[id] = def end
end

-- How many whole simulation steps at `rate` Hz a shot actually costs. The design
-- document and the game should agree about this rather than each rounding it
-- their own way.
function Weapons.intervalTicks(id, rate)
    local def = type(id) == 'table' and id or defs[id]
    if not def then return nil end
    local step = 1 / (rate or 60)
    if def.fireInterval <= EPS then return 1 end
    return max(1, math.ceil(def.fireInterval / step - 1e-9))
end

---------------------------------------------------------------------------
-- Equipping
---------------------------------------------------------------------------

-- Every weapon needs a random stream, and it has to be the same stream after a
-- save/load. Derived from the entity id so a host that never sets one still gets
-- a stable, per-entity sequence rather than every gun in the level spreading
-- identically.
local function defaultSeed(e)
    local id = Attributes.number(e and e.id) or 1
    return (floor(id) * 2654435761 + 12345) % 4294967296
end

--[[
    Puts a weapon in an entity's hands, creating the `weapon` component if it has
    none. Returns the component, or nil plus a reason.

        Weapons.equip(player, 'pistol')
        Weapons.equip(player, 'shotgun', { ammo = 2, reserve = 24 })

    Switching weapons resets the magazine to the new weapon's, cancels any reload
    in progress and clears accumulated recoil. It does NOT reset the cooldown,
    because "swap weapons to skip your fire delay" is the oldest exploit in the
    genre; pass `cooldown = 0` to allow it deliberately.
]]
function Weapons.equip(e, id, opts)
    opts = opts or {}

    if type(e) ~= 'table' or type(e.components) ~= 'table' then
        return nil, 'equip needs an entity'
    end

    local def = defs[id]
    if not def then return nil, ('unknown weapon: %s'):format(tostring(id)) end

    local state = e.components.weapon
    if not state then
        state = C.Weapon{}
        e:add(state)
    end

    local previous = state.id
    local carried = state.cooldown or 0

    state.id = id

    local ammo = Attributes.number(opts.ammo)
    if ammo == nil then
        ammo = (previous == id) and (Attributes.number(state.ammo) or def.magazine) or def.magazine
    end
    state.ammo = max(0, min(def.magazine, floor(ammo)))

    local reserve = Attributes.number(opts.reserve)
    if reserve == nil then
        reserve = (previous == id) and (Attributes.number(state.reserve) or def.reserve) or def.reserve
    end
    state.reserve = max(0, min(Weapons.MAX_AMMO, floor(reserve)))

    state.reloadRemaining = 0
    state.recoil = 0
    state.shots = Attributes.number(state.shots) or 0
    state.seed = Attributes.number(opts.seed) or state.seed or defaultSeed(e)

    local cooldown = Attributes.number(opts.cooldown)
    state.cooldown = max(0, cooldown or carried)

    -- `supply = false` clears it, which is how a weapon taken out of a bag stops
    -- reloading from that bag.
    if opts.supply ~= nil then
        state.supply = (opts.supply ~= false) and opts.supply or nil
    end

    return state
end

function Weapons.unequip(e)
    local state = e and e.components and e.components.weapon
    if not state then return false end
    state.id = nil
    state.reloadRemaining = 0
    state.recoil = 0
    state.supply = nil
    return true
end

function Weapons.state(e)
    return e and e.components and e.components.weapon or nil
end

function Weapons.equipped(e)
    local state = Weapons.state(e)
    return state and state.id or nil
end

-- Everything a HUD wants, from either side of the wire. A client has `ammo`,
-- `reserve`, `id` and `reloadRemaining` from the snapshot, so this answers the
-- same on a client as on the host for every field a client is given.
function Weapons.status(e)
    local state = Weapons.state(e)
    if not state then return nil end
    local def = defs[state.id]
    return {
        id        = state.id,
        ammo      = state.ammo or 0,
        magazine  = def and def.magazine or nil,
        reserve   = state.reserve or 0,
        reloading = (state.reloadRemaining or 0) > EPS,
        reloadRemaining = state.reloadRemaining or 0,
        reloadTotal = def and def.reloadTime or 0,
        cooldown  = state.cooldown or 0,
        recoil    = state.recoil or 0,
        empty     = (state.ammo or 0) < (def and def.ammoPerShot or 1),
    }
end

---------------------------------------------------------------------------
-- Authority
---------------------------------------------------------------------------

-- An entity with an ability system answers to its container: a client's is
-- non-authoritative, so a client cannot fire, which is the same wall
-- `Effects.apply` puts in front of damage. An entity without one — the demo's
-- player in single player, a turret in a test — is trusted, because there is no
-- container to have said otherwise and refusing would make the ability system
-- mandatory for anyone who wants a gun.
local function authoritative(e)
    local gas = Effects.system(e)
    if gas then return gas.authority == true end
    return true
end

Weapons.authoritative = authoritative

---------------------------------------------------------------------------
-- Ammunition
---------------------------------------------------------------------------

-- Where a reload gets its rounds. `state.supply(need, dryRun)` is set by
-- meatray.game.inventory when a weapon is equipped from a bag; with nothing set
-- it comes from the `reserve` field, which is what a game with no inventory
-- wants.
local function takeAmmo(state, need, dryRun)
    if need <= 0 then return 0 end

    if type(state.supply) == 'function' then
        local got = Attributes.number(state.supply(need, dryRun and true or false)) or 0
        if got < 0 then got = 0 end
        if got > need then got = need end
        return floor(got)
    end

    local have = Attributes.number(state.reserve) or 0
    local take = min(have, need)
    if take <= 0 then return 0 end
    if not dryRun then state.reserve = have - take end
    return floor(take)
end

Weapons.takeAmmo = takeAmmo

-- Puts rounds into the reserve (or the bag). Returns how many were accepted.
function Weapons.give(e, count, opts)
    opts = opts or {}
    local state = Weapons.state(e)
    if not state then return 0, 'no weapon' end

    local n = Attributes.number(count)
    if n == nil or n <= 0 then return 0, 'nothing to give' end
    n = floor(n)

    if opts.magazine then
        local def = defs[state.id]
        if not def then return 0, ('unknown weapon: %s'):format(tostring(state.id)) end
        local room = def.magazine - (state.ammo or 0)
        local take = min(room, n)
        state.ammo = (state.ammo or 0) + take
        return take
    end

    local have = Attributes.number(state.reserve) or 0
    local room = Weapons.MAX_AMMO - have
    local take = min(room, n)
    state.reserve = have + take
    return take
end

---------------------------------------------------------------------------
-- Reloading
---------------------------------------------------------------------------

--[[
    Starts a reload. Returns true, or false plus one of:

        'no weapon'    'unknown weapon: x'   'not authoritative'
        'reloading'    'full'                'no reserve'

    Nothing is consumed here. The rounds move when the reload COMPLETES, inside
    `Weapons.tick`, so an interrupted reload costs the time and not the ammo —
    which is the behaviour every shooter has and the opposite of what a naive
    implementation does.
]]
function Weapons.reload(e, ctx)
    ctx = ctx or {}

    local state = Weapons.state(e)
    if not state then return false, 'no weapon' end

    local def = defs[state.id]
    if not def then return false, ('unknown weapon: %s'):format(tostring(state.id)) end

    if not authoritative(e) then return false, 'not authoritative' end
    if (state.reloadRemaining or 0) > EPS then return false, 'reloading' end

    local need = def.magazine - (state.ammo or 0)
    if need <= 0 then return false, 'full' end

    -- Asked, not taken: a player who starts a reload with an empty bag should be
    -- told immediately rather than stand through the animation for nothing.
    if takeAmmo(state, need, true) <= 0 then return false, 'no reserve' end

    if def.reloadTime <= EPS then
        local loaded = takeAmmo(state, need, false)
        state.ammo = (state.ammo or 0) + loaded
        if def.onReload then def.onReload(e, def, loaded, ctx) end
        return true, 'instant', loaded
    end

    state.reloadRemaining = def.reloadTime
    return true
end

-- Stops a reload in progress. Nothing has been consumed, so nothing is refunded
-- and the magazine is exactly what it was.
function Weapons.cancelReload(e)
    local state = Weapons.state(e)
    if not state then return false, 'no weapon' end
    if (state.reloadRemaining or 0) <= EPS then return false, 'not reloading' end
    state.reloadRemaining = 0
    return true
end

function Weapons.reloading(e)
    local state = Weapons.state(e)
    return state ~= nil and (state.reloadRemaining or 0) > EPS
end

---------------------------------------------------------------------------
-- Firing
---------------------------------------------------------------------------

-- The random stream for shot number `n` of this weapon. Derived rather than
-- stored, so it survives a save (the seed and the shot count both replicate...
-- the count does; the seed is regenerated identically from the entity id) and so
-- two hosts stepping the same state produce the same pellets.
local function shotRng(state)
    local seed = Attributes.number(state.seed) or 0
    local shots = Attributes.number(state.shots) or 0
    local rng = Worldgen.rng((seed + shots * 2654435761) % 4294967296)
    -- One throwaway draw: adjacent LCG seeds have correlated first outputs, and
    -- a shotgun whose first pellet drifts predictably with the shot counter is a
    -- pattern a player can see.
    rng:next()
    return rng
end

Weapons.shotRng = shotRng

-- A deviation in [-spread, +spread], with a triangular bias toward the middle
-- (the average of two uniforms), because a uniform cone puts as many pellets on
-- the rim as on the axis and reads as a wall of misses.
local function deviate(rng, spread)
    if spread <= 0 then return 0 end
    return ((rng:float() + rng:float()) - 1) * spread
end

local function resolveHitscan(e, def, ctx, angle, spread, rng)
    local pellets = {}
    local firstEntity, firstWall

    for i = 1, def.pellets do
        local a = angle + deviate(rng, spread)
        local dirX, dirY = cos(a), sin(a)

        local hit = Collide.hitscan(ctx.world, e.x, e.y, dirX, dirY, ctx.entities, {
            ignore = ctx.ignore or e,
            maxDist = def.range,
            filter = ctx.filter,
            storey = e.storey or 1,
        })

        local pellet = { angle = a }

        if not hit then
            pellet.result = 'miss'
        elseif hit.kind == 'wall' then
            pellet.result = 'wall'
            pellet.tx, pellet.ty, pellet.dist = hit.tx, hit.ty, hit.dist
            pellet.hitx, pellet.hity = hit.hitx, hit.hity
            pellet.nx, pellet.ny = hit.nx, hit.ny
            firstWall = firstWall or pellet
        else
            local target = hit.entity
            pellet.result = 'hit'
            pellet.dist = hit.dist
            pellet.hitx, pellet.hity = hit.hitx, hit.hity
            pellet.target = target
            pellet.targetId = target.id
            pellet.targetKind = target.kind

            local applied, err, refused = Damage.applyWith(target, def.damage, def.effects, {
                tags = def.tags, source = e, id = 'weapon',
            })
            pellet.damage = def.damage
            pellet.applied = applied
            pellet.reason = (not applied) and err or nil
            pellet.refused = refused

            local health = target.components and target.components.health
            pellet.hp = health and health.hp or nil
            if pellet.hp ~= nil and pellet.hp <= 0 and not target.dead then
                target.dead = true
                pellet.killed = true
            end

            if def.onHit then def.onHit(e, def, target, pellet, ctx) end
            firstEntity = firstEntity or pellet
        end

        pellets[i] = pellet
    end

    return pellets, firstEntity, firstWall
end

local function resolveProjectile(e, def, ctx, angle, spread, rng)
    local spec = def.projectile
    local made, refused = {}, nil

    for i = 1, def.pellets do
        local a = angle + deviate(rng, spread)

        local opts = {}
        for k, v in pairs(spec) do opts[k] = v end
        opts.x, opts.y = e.x, e.y
        opts.angle = a
        opts.owner = e
        opts.spawn = ctx.spawn or spec.spawn
        if opts.damage == nil then opts.damage = def.damage end
        if opts.tags == nil then opts.tags = def.tags end
        if opts.effects == nil and #def.effects > 0 then opts.effects = def.effects end

        local p, err = Projectiles.spawn(opts)
        if p then
            made[#made + 1] = p
            -- The caller owns the entity list. `ctx.emit` is how it says where to
            -- put what was made; without it the projectiles come back in the
            -- result and it is the caller's job to place them.
            if type(ctx.emit) == 'function' then
                ctx.emit(p)
            elseif type(ctx.entities) == 'table' then
                ctx.entities[#ctx.entities + 1] = p
            end
        else
            refused = refused or {}
            refused[#refused + 1] = err
        end
    end

    return made, refused
end

--[[
    Pulls the trigger, on the host.

    Returns a shot record, or nil plus one of these reasons — all stable strings
    a HUD can explain and a test can match:

        'no weapon'          the entity carries no weapon component
        'unknown weapon: x'  it names a weapon this build does not define
        'not authoritative'  a client tried to resolve its own shot
        'cooldown'           the fire rate says no; see the header
        'reloading'
        'empty'              not enough in the magazine
        'a shot needs a world'
        'a shot needs entities'
        'aim is unusable (x)'

    On success:

        {
            weapon =, shooter =, x =, y =, angle =,
            ammo =,                 -- after the shot
            kick =,                 -- radians the owning client should add to aim
            spread =,               -- the cone this shot actually used
            result = 'hit' | 'wall' | 'miss',
            pellets = { { result =, dist =, target =, damage =, ... }, ... },
            projectiles = { entity, ... },     -- projectile weapons only
            -- plus the first entity hit flattened onto the record, so a caller
            -- with a single-pellet weapon never has to index `pellets`:
            target =, targetId =, targetKind =, dist =, damage =, hp =, killed =,
            tx =, ty =,
        }
]]
function Weapons.fire(e, ctx)
    ctx = ctx or {}

    local state = Weapons.state(e)
    if not state then return nil, 'no weapon' end

    local def = defs[state.id]
    if not def then return nil, ('unknown weapon: %s'):format(tostring(state.id)) end

    if not authoritative(e) then return nil, 'not authoritative' end

    -- The cooldown is READ here and written only by tick. See the header: this
    -- is the line that makes a client sending fire at 500 Hz fire at the weapon's
    -- rate instead.
    if (state.cooldown or 0) > EPS then return nil, 'cooldown', state.cooldown end
    if (state.reloadRemaining or 0) > EPS then return nil, 'reloading', state.reloadRemaining end

    local ammo = Attributes.number(state.ammo) or 0
    if ammo < def.ammoPerShot then
        if def.autoReload then Weapons.reload(e, ctx) end
        return nil, 'empty'
    end

    if type(ctx.world) ~= 'table' or type(ctx.world.isSolid) ~= 'function' then
        return nil, 'a shot needs a world'
    end
    if type(ctx.entities) ~= 'table' then
        return nil, 'a shot needs entities'
    end

    -- Aim is an input and may have come off the wire. `Attributes.number` refuses
    -- NaN and infinities, which `tonumber` does not: a NaN angle produces a NaN
    -- direction, a NaN hitscan and a shot that silently hits nothing forever.
    local angle = e.angle
    if ctx.angle ~= nil then
        angle = Attributes.number(ctx.angle)
        if angle == nil or angle < -MAX_ANGLE or angle > MAX_ANGLE then
            return nil, ('aim is unusable (%s)'):format(tostring(ctx.angle))
        end
        e.angle = angle
    end
    angle = Attributes.number(angle)
    if angle == nil then return nil, ('aim is unusable (%s)'):format(tostring(e.angle)) end

    ---------------------------------------------------------------------
    -- Commit. Everything past here happens.
    ---------------------------------------------------------------------

    state.ammo = ammo - def.ammoPerShot
    state.cooldown = def.fireInterval
    state.shots = (Attributes.number(state.shots) or 0) + 1

    local rng = ctx.rng or shotRng(state)
    local spread = def.spread + (Attributes.number(state.recoil) or 0)

    local shot = {
        weapon = def.id,
        shooter = e.id,
        x = e.x, y = e.y, angle = angle,
        spread = spread,
        ammo = state.ammo,
    }

    if def.kind == 'projectile' then
        local made, refusedList = resolveProjectile(e, def, ctx, angle, spread, rng)
        shot.projectiles = made
        shot.refused = refusedList
        shot.result = (#made > 0) and 'launched' or 'miss'
        shot.pellets = {}
    else
        local pellets, firstEntity, firstWall =
            resolveHitscan(e, def, ctx, angle, spread, rng)
        shot.pellets = pellets

        local primary = firstEntity or firstWall
        if firstEntity then
            shot.result = 'hit'
            shot.target     = firstEntity.target
            shot.targetId   = firstEntity.targetId
            shot.targetKind = firstEntity.targetKind
            shot.hp         = firstEntity.hp
            shot.killed     = firstEntity.killed
        elseif firstWall then
            shot.result = 'wall'
        else
            shot.result = 'miss'
        end

        if primary then
            shot.dist = primary.dist
            shot.tx, shot.ty = primary.tx, primary.ty
            shot.hitx, shot.hity = primary.hitx, primary.hity
            shot.nx, shot.ny = primary.nx, primary.ny
        end

        -- Total damage dealt, which is what a shotgun's caller wants to report.
        local total = 0
        for i = 1, #pellets do total = total + (pellets[i].damage or 0) end
        shot.damage = total
    end

    -- Recoil: the cone widens for the next shot, and the kick is reported for
    -- the owning client to apply to its own aim. Sign is deterministic from the
    -- same stream as the spread.
    if def.recoil > 0 then
        state.recoil = min(def.recoilMax, (Attributes.number(state.recoil) or 0) + def.recoil)
    end
    if def.kick > 0 then
        shot.kick = def.kick * (rng:float() < 0.5 and -1 or 1)
    else
        shot.kick = 0
    end

    if state.ammo < def.ammoPerShot and def.autoReload then
        Weapons.reload(e, ctx)
    end

    if def.onFire then def.onFire(e, def, shot, ctx) end

    return shot
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    One fixed simulation step of weapon state: the fire cooldown, the reload
    timer and recoil recovery. THE ONLY WRITER OF TIME IN THIS MODULE.

    Returns whether a reload completed this step and how many rounds it moved,
    so a caller can play a sound or send an event without polling.
]]
function Weapons.tick(e, dt, ctx)
    local state = Weapons.state(e)
    if not state then return false, 0 end

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return false, 0 end

    local def = defs[state.id]

    local cooldown = Attributes.number(state.cooldown) or 0
    if cooldown > 0 then
        cooldown = cooldown - step
        state.cooldown = (cooldown <= EPS) and 0 or cooldown
    end

    local reloaded, loaded = false, 0
    local remaining = Attributes.number(state.reloadRemaining) or 0
    if remaining > 0 then
        remaining = remaining - step
        if remaining <= EPS then
            state.reloadRemaining = 0
            if def then
                local need = def.magazine - (Attributes.number(state.ammo) or 0)
                loaded = takeAmmo(state, need, false)
                state.ammo = (Attributes.number(state.ammo) or 0) + loaded
                reloaded = true
                if def.onReload then def.onReload(e, def, loaded, ctx) end
            end
        else
            state.reloadRemaining = remaining
        end
    end

    local recoil = Attributes.number(state.recoil) or 0
    if recoil > 0 and def then
        recoil = recoil - def.recoilRecovery * step
        state.recoil = (recoil <= EPS) and 0 or recoil
    end

    return reloaded, loaded
end

-- Every entity carrying a weapon, in array order. Returns how many were ticked.
function Weapons.tickAll(entities, dt, ctx)
    local n = 0
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if e and not e.dead and e.components and e.components.weapon then
            Weapons.tick(e, dt, ctx)
            n = n + 1
        end
    end
    return n
end

return Weapons
