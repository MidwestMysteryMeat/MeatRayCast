--[[
    meatray.render.themes — palettes and atmosphere.

    A theme is a palette plus an atmosphere. Nothing else in the engine reads it:
    the simulation stores a theme *name* on the world and never interprets it, so
    a game can add themes without touching engine code.

    Every theme defined here is reachable by name and every atmosphere preset is
    used by at least one theme. That is a deliberate constraint with a test behind
    it — the project this renderer came from had five atmosphere presets that no
    theme selected and no UI could reach, which is a hundred and seventy lines of
    tuned data that may as well not exist.
]]

local Themes = {}

---------------------------------------------------------------------------
-- Atmosphere presets: distance fog and ambient light.
---------------------------------------------------------------------------

Themes.atmospheres = {
    clear    = { fog = { 0.05, 0.05, 0.08 }, maxView = 32, ambient = 1.00 },
    dim      = { fog = { 0.03, 0.03, 0.05 }, maxView = 20, ambient = 0.75 },
    murky    = { fog = { 0.06, 0.09, 0.07 }, maxView = 12, ambient = 0.60 },
    smoky    = { fog = { 0.14, 0.12, 0.10 }, maxView = 10, ambient = 0.70 },
    void     = { fog = { 0.01, 0.01, 0.02 }, maxView = 8,  ambient = 0.35 },
    sunlit   = { fog = { 0.55, 0.58, 0.62 }, maxView = 40, ambient = 1.00 },
    infernal = { fog = { 0.18, 0.06, 0.03 }, maxView = 16, ambient = 0.85 },
}

---------------------------------------------------------------------------
-- Themes. `walls` maps tile codes 1..9 to base colours; a tile code with no
-- entry falls back to walls[1] rather than erroring, so a map that references
-- texture 7 in a theme defining four still loads.
---------------------------------------------------------------------------

Themes.list = {
    dungeon = {
        atmosphere = 'dim',
        floor = { 0.16, 0.14, 0.13 },
        ceiling = { 0.10, 0.09, 0.09 },
        sky = nil,
        walls = {
            { 0.42, 0.38, 0.34 },  -- 1 mortared stone
            { 0.34, 0.30, 0.28 },  -- 2 dark brick
            { 0.30, 0.26, 0.30 },  -- 3 slate
            { 0.46, 0.40, 0.28 },  -- 4 sandstone
        },
        door = { 0.40, 0.26, 0.14 },
    },

    catacomb = {
        atmosphere = 'void',
        floor = { 0.11, 0.10, 0.12 },
        ceiling = { 0.07, 0.06, 0.08 },
        walls = {
            { 0.30, 0.28, 0.32 },
            { 0.24, 0.22, 0.26 },
            { 0.36, 0.34, 0.30 },
        },
        door = { 0.26, 0.20, 0.22 },
    },

    foundry = {
        atmosphere = 'infernal',
        floor = { 0.20, 0.13, 0.10 },
        ceiling = { 0.13, 0.09, 0.08 },
        walls = {
            { 0.44, 0.26, 0.18 },
            { 0.36, 0.20, 0.14 },
            { 0.30, 0.30, 0.32 },  -- riveted plate
        },
        door = { 0.52, 0.30, 0.12 },
    },

    facility = {
        atmosphere = 'clear',
        floor = { 0.22, 0.24, 0.26 },
        ceiling = { 0.26, 0.28, 0.30 },
        walls = {
            { 0.52, 0.56, 0.60 },  -- painted panel
            { 0.38, 0.42, 0.48 },
            { 0.30, 0.44, 0.42 },
        },
        door = { 0.24, 0.48, 0.56 },
    },

    overgrown = {
        atmosphere = 'murky',
        floor = { 0.14, 0.20, 0.13 },
        ceiling = { 0.12, 0.16, 0.12 },
        walls = {
            { 0.30, 0.42, 0.26 },
            { 0.36, 0.34, 0.24 },
        },
        door = { 0.30, 0.34, 0.18 },
    },

    surface = {
        atmosphere = 'sunlit',
        floor = { 0.44, 0.42, 0.36 },
        ceiling = nil,               -- open sky
        sky = { 0.52, 0.62, 0.78 },
        walls = {
            { 0.62, 0.58, 0.50 },
            { 0.50, 0.46, 0.42 },
            { 0.44, 0.40, 0.34 },
        },
        door = { 0.44, 0.30, 0.16 },
    },

    ashfall = {
        atmosphere = 'smoky',
        floor = { 0.20, 0.19, 0.18 },
        ceiling = nil,
        sky = { 0.28, 0.24, 0.22 },
        walls = {
            { 0.38, 0.35, 0.33 },
            { 0.30, 0.27, 0.26 },
        },
        door = { 0.32, 0.26, 0.20 },
    },
}

Themes.DEFAULT = 'dungeon'

function Themes.get(name)
    return Themes.list[name or Themes.DEFAULT] or Themes.list[Themes.DEFAULT]
end

function Themes.atmosphere(name)
    local theme = Themes.get(name)
    return Themes.atmospheres[theme.atmosphere] or Themes.atmospheres.clear
end

-- A wall colour for a tile code, falling back rather than failing.
function Themes.wallColor(name, tile)
    local theme = Themes.get(name)
    return theme.walls[tile] or theme.walls[1]
end

function Themes.names()
    local out = {}
    for name in pairs(Themes.list) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Themes.atmosphereNames()
    local out = {}
    for name in pairs(Themes.atmospheres) do out[#out + 1] = name end
    table.sort(out)
    return out
end

return Themes
