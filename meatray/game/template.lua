--[[
    meatray.game.template — genre starting points, as data (Templates).

    MeatEngine and Meat2D ship per-genre starters so a new project is a working
    game on the first run, not a blank engine. This is that for MeatRayCast, and
    because the whole game layer here is already data (modes, weapons, hazards,
    abilities), a template is just a table that says which of those to assemble
    and how — no code generation, no separate project tree. Pick one and the
    demo becomes that genre.

        local Template = require('meatray.game.template')
        Template.list()                 -- { 'coop', 'crawler', 'fps', ... }
        local cfg = Template.resolve('tdm')   -- the fully merged config
        cfg.mode                        -- 'teamDeathmatch'
        cfg.movement                    -- 'fps'
        cfg.loadout                     -- { { item='pistol', count=1 }, ... }

    Subsets are the load-bearing idea. TDM is FPS with teams; a dungeon crawler
    is an RPG that moves on a grid; MMO is an RPG that persists. So a template
    names a `base` and inherits everything it does not override, walking the
    chain to the root. That is what makes "TDM is a subset of FPS" a fact in the
    data rather than a comment — change FPS's loadout and TDM's changes with it,
    unless TDM said otherwise.

    Each template is honest about how finished it is. `ready = 'playable'` means
    the existing engine systems assemble into a game you can start right now;
    `ready = 'scaffold'` means the config is set but the genre needs a system
    this engine does not ship yet (a dialogue tree, a turn engine, a persistence
    backend), listed in `needs`. A raycaster is not pretending to be a visual
    novel engine — but it can be CONFIGURED toward one, and the template says
    exactly what is left to build. That honesty is the point: a template that
    lied about being playable would waste the time it exists to save.

    Fields a template may set (all optional; inherited from base otherwise):
      name, description                 human text
      base                              parent template name, or nil for a root
      mode        'deathmatch' | 'teamDeathmatch' | 'coop' | 'sp' | 'persistent'
      movement    'fps' | 'grid' | 'static'   free-look, tile-step, or none
      combat      'realtime' | 'turn' | 'none'
      loadout     { { item=, count= }, ... }  what a player starts holding
      moveSpeed, turnSpeed              movement tuning
      teams       { 'red', 'blue' }     team modes only
      respawn     true | false | seconds
      rpgStats    bool                  grant health/stamina/mana attributes
      persistence bool                  world/character saved across sessions
      ready       'playable' | 'scaffold'
      needs       { 'dialogue', ... }   systems a scaffold still requires

    HEADLESS: pure Lua.
]]

local Template = {}

---------------------------------------------------------------------------
-- The registry
---------------------------------------------------------------------------

-- Roots first, subsets after — but the resolver does not care about order,
-- only about the `base` links.
Template.KINDS = {

    -- ─── FPS family ──────────────────────────────────────────────────
    fps = {
        name = 'Arena FPS',
        description = 'Free-for-all deathmatch: free-look movement, real-time '
            .. 'combat, respawns. The engine\'s home genre.',
        mode = 'deathmatch', movement = 'fps', combat = 'realtime',
        moveSpeed = 3.2, turnSpeed = 2.6,
        loadout = {
            { item = 'pistol', count = 1 },
            { item = 'launcher', count = 1 },
            { item = 'ammo.pistol', count = 96 },
            { item = 'ammo.grenade', count = 6 },
        },
        respawn = 3, rpgStats = false, persistence = false,
        ready = 'playable',
    },
    tdm = {
        name = 'Team Deathmatch',
        base = 'fps',
        description = 'FPS with two teams and a shared frag limit. Everything '
            .. 'else is inherited from the FPS template.',
        mode = 'teamDeathmatch', teams = { 'red', 'blue' },
        ready = 'playable',
    },
    coop = {
        name = 'Co-op Clear',
        base = 'fps',
        description = 'Players against the map: clear every enemy to win. '
            .. 'FPS movement and combat, shared objective.',
        mode = 'coop',
        ready = 'playable',
    },

    -- ─── RPG family ──────────────────────────────────────────────────
    rpg = {
        name = 'First-person RPG',
        description = 'Single-player exploration with character stats and '
            .. 'real-time combat. Dialogue and quests are the author\'s to add.',
        mode = 'sp', movement = 'fps', combat = 'realtime',
        moveSpeed = 2.8, turnSpeed = 2.4,
        loadout = { { item = 'pistol', count = 1 }, { item = 'ammo.pistol', count = 40 } },
        respawn = false, rpgStats = true, persistence = false,
        ready = 'scaffold', needs = { 'dialogue', 'quests' },
    },
    crawler = {
        name = 'Dungeon Crawler',
        base = 'rpg',
        description = 'A grid-step, 90-degree-turn dungeon crawl (Eye of the '
            .. 'Beholder). RPG stats, real-time combat, tile movement.',
        movement = 'grid', mode = 'coop',
        ready = 'playable',
    },
    turnrpg = {
        name = 'Turn-based RPG',
        base = 'rpg',
        description = 'Grid movement and turn-based combat. The turn engine '
            .. 'itself is the author\'s to build on top of the stat system.',
        movement = 'grid', combat = 'turn',
        ready = 'scaffold', needs = { 'turn engine', 'dialogue' },
    },
    mmo = {
        name = 'Persistent MMO',
        base = 'rpg',
        description = 'Many players in a persistent world with saved '
            .. 'characters. Uses the full net stack; the persistence backend '
            .. 'and account layer are the author\'s to supply.',
        mode = 'persistent', persistence = true,
        ready = 'scaffold', needs = { 'account backend', 'world persistence' },
    },

    -- ─── Dialogue-first ──────────────────────────────────────────────
    vn = {
        name = 'Visual Novel',
        description = 'A dialogue-driven story with fixed scenes and no combat. '
            .. 'The raycaster renders the backdrop; the story engine is the '
            .. 'author\'s to build.',
        mode = 'sp', movement = 'static', combat = 'none',
        loadout = {},
        respawn = false, rpgStats = false, persistence = false,
        ready = 'scaffold', needs = { 'dialogue', 'scene script', 'portraits' },
    },
}

---------------------------------------------------------------------------
-- Listing and lookup
---------------------------------------------------------------------------

function Template.list()
    local names = {}
    for name in pairs(Template.KINDS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function Template.get(name)
    return Template.KINDS[tostring(name)]
end

function Template.exists(name)
    return Template.KINDS[tostring(name)] ~= nil
end

---------------------------------------------------------------------------
-- Resolution: merge a template with its base chain
---------------------------------------------------------------------------

-- The fields that inherit as SCALARS (child value replaces parent). Tables
-- (loadout, teams, needs) also replace wholesale rather than deep-merge — a
-- template that sets a loadout means THAT loadout, not the parent's plus its.
local INHERITED = {
    'name', 'description', 'mode', 'movement', 'combat',
    'moveSpeed', 'turnSpeed', 'loadout', 'teams', 'respawn',
    'rpgStats', 'persistence', 'ready', 'needs',
}

-- Returns the fully merged config for `name`, walking base → ... → root and
-- letting the child override. Returns nil plus a reason on an unknown name or
-- a base cycle.
function Template.resolve(name)
    name = tostring(name)
    if not Template.KINDS[name] then
        return nil, 'unknown template: ' .. name
    end

    -- Build the chain root-first, guarding against a cycle.
    local chain, seen = {}, {}
    local cur = name
    while cur do
        if seen[cur] then
            return nil, 'template base cycle at ' .. cur
        end
        seen[cur] = true
        local t = Template.KINDS[cur]
        if not t then return nil, 'template base missing: ' .. cur end
        table.insert(chain, 1, t)     -- prepend: root ends up first
        cur = t.base
    end

    local out = { chainNames = {} }
    for _, t in ipairs(chain) do
        out.chainNames[#out.chainNames + 1] = t.name or '?'
        for _, field in ipairs(INHERITED) do
            if t[field] ~= nil then out[field] = t[field] end
        end
    end
    out.id = name
    return out
end

-- Is `name` a subset (descendant) of `of`? True when `of` is anywhere up
-- `name`'s base chain. This is the "TDM is a subset of FPS" query.
function Template.isSubsetOf(name, of)
    local cur = tostring(name)
    local seen = {}
    while cur do
        if seen[cur] then return false end     -- cycle guard
        seen[cur] = true
        local t = Template.KINDS[cur]
        if not t then return false end
        if t.base == of then return true end
        cur = t.base
    end
    return false
end

---------------------------------------------------------------------------
-- Validation: catch a malformed or dangling template
---------------------------------------------------------------------------

local VALID_MODE = { deathmatch = true, teamDeathmatch = true, coop = true,
                     sp = true, persistent = true }
local VALID_MOVE = { fps = true, grid = true, static = true }
local VALID_COMBAT = { realtime = true, turn = true, none = true }

-- Checks one resolved config. Returns true, or false plus a list of problems.
function Template.validate(name)
    local cfg, why = Template.resolve(name)
    if not cfg then return false, { why } end

    local errs = {}
    if not VALID_MODE[cfg.mode] then
        errs[#errs + 1] = ('mode %q is not a known mode'):format(tostring(cfg.mode))
    end
    if not VALID_MOVE[cfg.movement] then
        errs[#errs + 1] = ('movement %q is not fps/grid/static'):format(tostring(cfg.movement))
    end
    if not VALID_COMBAT[cfg.combat] then
        errs[#errs + 1] = ('combat %q is not realtime/turn/none'):format(tostring(cfg.combat))
    end
    if cfg.mode == 'teamDeathmatch' and not (cfg.teams and #cfg.teams >= 2) then
        errs[#errs + 1] = 'a team mode needs at least two teams'
    end
    if cfg.combat == 'none' and cfg.loadout and #cfg.loadout > 0 then
        errs[#errs + 1] = 'combat is none but a loadout was given'
    end
    if cfg.ready ~= 'playable' and cfg.ready ~= 'scaffold' then
        errs[#errs + 1] = 'ready must be "playable" or "scaffold"'
    end
    return #errs == 0, errs
end

-- Validates every registered template — the anti-rot gate a test calls.
function Template.validateAll()
    local bad = {}
    for _, name in ipairs(Template.list()) do
        local ok, errs = Template.validate(name)
        if not ok then bad[name] = errs end
    end
    return next(bad) == nil, bad
end

---------------------------------------------------------------------------
-- A one-line summary per template, for a menu or the console
---------------------------------------------------------------------------

function Template.summary(name)
    local cfg = Template.resolve(name)
    if not cfg then return name .. ' (unknown)' end
    local tag = cfg.ready == 'playable' and 'playable' or 'scaffold'
    return ('%-9s %-18s %s%s'):format(
        name, cfg.name or '?', tag,
        (cfg.needs and #cfg.needs > 0)
            and ('  (needs: ' .. table.concat(cfg.needs, ', ') .. ')') or '')
end

return Template
