--[[
    meatray.render.raycaster — the wall renderer.

    One ray per screen column, walked across the tile grid until it meets
    something solid, drawn as a vertical strip whose height is inversely
    proportional to the distance. That is the whole idea; the value is in the
    details around it — texture coordinates, door offsets, side shading, fog, and
    the z-buffer that lets sprites hide behind walls.

    This module owns no game concepts. It takes a view table and a World and
    returns a z-buffer. Themes and textures are looked up by name, and everything
    optional (ceilings, custom fog, sprite hooks) is injected rather than
    required, so the renderer works against a bare World with nothing else set up.
]]

local Themes = require('meatray.render.themes')
local Textures = require('meatray.render.textures')
local Lighting = require('meatray.render.lighting')
local World = require('meatray.sim.world')

local Raycaster = {}

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local state = {
    screenW = 800,
    screenH = 600,
    theme = Themes.DEFAULT,
    textures = nil,
    fovPlane = 0.66,       -- roughly a 66-degree horizontal field of view
    ceilingZones = {},
    fogOverride = nil,
    lighting = nil,        -- optional meatray.render.lighting grid
}

-- How far back along the ray to sample the light on a wall face. The hit point
-- sits exactly on the boundary, and sampling *on* the boundary is a coin flip
-- between the open tile and the solid one; stepping a fraction of a tile back
-- toward the camera lands reliably in the room the face is being seen from.
local WALL_LIGHT_BACKSTEP = 0.05

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Raycaster.init(opts)
    opts = opts or {}
    state.screenW = opts.width or love.graphics.getWidth()
    state.screenH = opts.height or love.graphics.getHeight()
    state.fovPlane = opts.fovPlane or 0.66
    Raycaster.setTheme(opts.theme or Themes.DEFAULT)

    -- Reused for every wall column; see the draw call in render().
    state.columnQuad = love.graphics.newQuad(0, 0, 1, Textures.SIZE,
                                            Textures.SIZE, Textures.SIZE)
    return Raycaster
end

function Raycaster.setTheme(name)
    state.theme = name or Themes.DEFAULT
    state.textures = Textures.forTheme(state.theme)
    return Raycaster
end

function Raycaster.getTheme()
    return state.theme
end

function Raycaster.resize(w, h)
    state.screenW, state.screenH = w, h
end

-- Ceilings are opt-in per region: an outdoor theme wants open sky, an indoor one
-- wants a ceiling, and a map can want both.
function Raycaster.addCeilingZone(x1, y1, x2, y2)
    state.ceilingZones[#state.ceilingZones + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    return Raycaster
end

function Raycaster.clearCeilingZones()
    state.ceilingZones = {}
end

local function hasCeiling(x, y)
    if #state.ceilingZones == 0 then return true end
    for i = 1, #state.ceilingZones do
        local z = state.ceilingZones[i]
        if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return true end
    end
    return false
end

-- Lets a game drive fog from its own systems (a smoke cloud, a spell) without
-- the renderer knowing what those are.
function Raycaster.setFog(fog)
    state.fogOverride = fog
end

-- Attaches a meatray.render.lighting grid, or nil for none. With no grid every
-- surface samples a flat 1.0 and the renderer behaves exactly as it did before
-- lighting existed — which is what makes this optional rather than a migration.
--
-- The renderer only ever *reads* the grid. Advancing the frame and declaring
-- dynamic lights is the caller's job, because the renderer does not know when a
-- frame began or what is on fire.
function Raycaster.setLighting(lighting)
    state.lighting = lighting
    return Raycaster
end

function Raycaster.getLighting()
    return state.lighting
end

---------------------------------------------------------------------------
-- A camera from a position and a facing angle.
---------------------------------------------------------------------------

-- Builds the view table render() expects. Games with their own camera can build
-- this themselves; this is the common case.
function Raycaster.view(x, y, angle, opts)
    opts = opts or {}
    local plane = opts.fovPlane or state.fovPlane
    local dirX, dirY = math.cos(angle), math.sin(angle)
    return {
        x = x, y = y, angle = angle,
        dirX = dirX, dirY = dirY,
        -- The camera plane is perpendicular to the direction, scaled to the FOV.
        planeX = -dirY * plane, planeY = dirX * plane,
        horizonShift = opts.horizonShift or 0,
    }
end

---------------------------------------------------------------------------
-- Sky, floor and ceiling
---------------------------------------------------------------------------

local function drawBackground(view)
    local theme = Themes.get(state.theme)
    local w, h = state.screenW, state.screenH
    local horizon = floor(h / 2 + (view.horizonShift or 0))

    -- Floor and ceiling take the light where the camera is standing. Without
    -- this a dark room's walls go dark and its floor stays at full theme
    -- brightness, which reads as a rendering fault rather than as darkness.
    -- A sky is lit by the sky, so it is left alone.
    --
    -- Darkening only, deliberately. These are flat bands with no distance
    -- falloff of their own, so a light that brightened them would brighten the
    -- floor all the way to the horizon and put the whole lower half of the frame
    -- above every wall in the scene — a torch lighting the floor a hundred tiles
    -- away as strongly as the tile it is standing on. Darkness has no such
    -- problem: an unlit room is unlit at every distance.
    --
    -- Brightness only, not colour. These bands cover most of the frame, and
    -- tinting that much of the screen from one sample turns a warm torch into an
    -- orange filter over the whole view. The walls carry the colour of the light,
    -- which is where a viewer reads it from anyway.
    local bandLight = 1
    if state.lighting then
        local lr, lg, lb = state.lighting:sample(view.x, view.y)
        bandLight = min(1, (lr + lg + lb) / 3)
    end

    -- Above the horizon: sky if the theme is open, ceiling colour otherwise.
    local upper = theme.sky or theme.ceiling or { 0.08, 0.08, 0.10 }
    local ceilingLight = theme.sky and 1 or bandLight
    love.graphics.setColor(upper[1] * ceilingLight, upper[2] * ceilingLight,
                           upper[3] * ceilingLight)
    love.graphics.rectangle('fill', 0, 0, w, max(0, horizon))

    local lower = theme.floor or { 0.18, 0.18, 0.18 }
    love.graphics.setColor(lower[1] * bandLight, lower[2] * bandLight,
                           lower[3] * bandLight)
    love.graphics.rectangle('fill', 0, horizon, w, h - horizon)

    -- A cheap gradient toward the horizon reads as depth without a per-pixel
    -- floor cast, which would cost far more than it is worth here.
    local atmosphere = Themes.atmosphere(state.theme)
    local fog = state.fogOverride or atmosphere.fog
    local bands = 24
    for i = 1, bands do
        local t = i / bands
        love.graphics.setColor(fog[1], fog[2], fog[3], (1 - t) * 0.55)
        local bandH = (h - horizon) / bands
        love.graphics.rectangle('fill', 0, horizon + (i - 1) * bandH, w, bandH + 1)
        love.graphics.setColor(fog[1], fog[2], fog[3], (1 - t) * 0.45)
        love.graphics.rectangle('fill', 0, horizon - i * bandH, w, bandH + 1)
    end
end

---------------------------------------------------------------------------
-- The wall loop
---------------------------------------------------------------------------

-- Casts one ray per screen column and draws the wall it hits, filling a z-buffer
-- as it goes. Returns that z-buffer: an array of perpendicular wall distance per
-- screen column, which meatray.render.sprites needs in order to clip sprites
-- against walls.
--
-- ATTRIBUTION -----------------------------------------------------------------
-- The digital-differential-analyzer traversal below (the deltaDist/sideDist
-- setup, the step-and-compare loop, the perpendicular-distance calculation and
-- the wallX/texX derivation) is derived from raycaster_textured.cpp by Lode
-- Vandevenne, published with the raycasting tutorial at
-- https://lodev.org/cgtutor/raycasting.html and distributed by its author under
-- the 2-clause BSD license.
--
--     Copyright (c) 2004-2019, Lode Vandevenne
--
-- The full license text is reproduced in the NOTICE file at the repository root
-- and must be retained in redistributions, in source form and in binaries.
--
-- Everything layered around that traversal -- theming, door offsets, ceiling
-- zones, fog, the z-buffer contract, and the injection points -- is this
-- project's own work and is covered by LICENSE (Apache-2.0).
-------------------------------------------------------------------------------
function Raycaster.render(view, world, opts)
    opts = opts or {}
    local w, h = state.screenW, state.screenH
    local textures = state.textures or Textures.forTheme(state.theme)
    local atmosphere = Themes.atmosphere(state.theme)
    local fog = state.fogOverride or atmosphere.fog
    local maxView = opts.maxView or atmosphere.maxView
    local ambient = atmosphere.ambient

    drawBackground(view)

    local posX, posY = view.x, view.y
    local dirX, dirY = view.dirX, view.dirY
    local planeX, planeY = view.planeX, view.planeY
    local horizon = h / 2 + (view.horizonShift or 0)

    local zBuffer = {}
    local texSize = Textures.SIZE

    love.graphics.setColor(1, 1, 1)

    for x = 0, w - 1 do
        -- Ray direction for this column: -1 at the left edge, +1 at the right.
        local cameraX = 2 * x / w - 1
        local rayDirX = dirX + planeX * cameraX
        local rayDirY = dirY + planeY * cameraX

        local mapX, mapY = floor(posX) + 1, floor(posY) + 1

        -- Distance the ray travels to cross one full tile in each axis. A zero
        -- component would divide by zero, so it is parked at a large value that
        -- the comparison below never selects.
        local deltaDistX = (rayDirX == 0) and 1e30 or abs(1 / rayDirX)
        local deltaDistY = (rayDirY == 0) and 1e30 or abs(1 / rayDirY)

        local stepX, stepY
        local sideDistX, sideDistY

        if rayDirX < 0 then
            stepX = -1
            sideDistX = (posX - (mapX - 1)) * deltaDistX
        else
            stepX = 1
            sideDistX = (mapX - posX) * deltaDistX
        end

        if rayDirY < 0 then
            stepY = -1
            sideDistY = (posY - (mapY - 1)) * deltaDistY
        else
            stepY = 1
            sideDistY = (mapY - posY) * deltaDistY
        end

        -- Step tile by tile, always advancing whichever axis is nearer, until
        -- something solid is hit or the ray runs out of range.
        local hit, side = false, 0
        local tile = 0
        local isDoor = false
        local guard = 0

        while not hit and guard < 512 do
            guard = guard + 1

            if sideDistX < sideDistY then
                sideDistX = sideDistX + deltaDistX
                mapX = mapX + stepX
                side = 0
            else
                sideDistY = sideDistY + deltaDistY
                mapY = mapY + stepY
                side = 1
            end

            tile = world:tileAt(mapX, mapY)

            if tile == World.DOOR then
                local door = world:doorAt(mapX, mapY)
                local openness = door and door.openness or 0
                -- A fully open door is walked through; a partly open one still
                -- draws, slid aside by its openness.
                if openness < 0.95 then
                    hit, isDoor = true, true
                end
            elseif tile ~= World.EMPTY
                   and tile ~= World.STAIRS_UP and tile ~= World.STAIRS_DOWN then
                hit = true
            end

            local travelled = (side == 0) and (sideDistX - deltaDistX) or (sideDistY - deltaDistY)
            if travelled > maxView then break end
        end

        if not hit then
            zBuffer[x] = maxView
        else
            -- Perpendicular distance, not euclidean: using the true distance to
            -- the hit point would fisheye the walls.
            local perpWallDist = (side == 0)
                and (sideDistX - deltaDistX)
                or (sideDistY - deltaDistY)
            if perpWallDist < 0.0001 then perpWallDist = 0.0001 end

            zBuffer[x] = perpWallDist

            local lineHeight = floor(h / perpWallDist)
            local drawStart = floor(-lineHeight / 2 + horizon)
            local drawEnd = floor(lineHeight / 2 + horizon)

            -- Where along the wall face the ray landed, which becomes the
            -- texture column.
            local wallX
            if side == 0 then
                wallX = posY + perpWallDist * rayDirY
            else
                wallX = posX + perpWallDist * rayDirX
            end
            wallX = wallX - floor(wallX)

            local texX = floor(wallX * texSize)
            if (side == 0 and rayDirX > 0) or (side == 1 and rayDirY < 0) then
                texX = texSize - texX - 1
            end
            texX = min(texSize - 1, max(0, texX))

            local image = isDoor and textures.door or (textures.walls[tile] or textures.walls[1])

            -- Sliding doors: shift the texture column by how far it has opened,
            -- so an opening door visibly slides rather than fading.
            if isDoor then
                local door = world:doorAt(mapX, mapY)
                local openness = door and door.openness or 0
                texX = floor((wallX + openness) % 1 * texSize)
                texX = min(texSize - 1, max(0, texX))
            end

            -- Faces perpendicular to the view read as a different plane; darkening
            -- one side is what makes corners legible.
            local sideShade = (side == 1) and 0.72 or 1.0

            -- Distance fog, applied as a brightness falloff toward the fog colour.
            local depthShade = 1 - min(0.85, (perpWallDist / maxView) ^ 0.9)
            local base = ambient * sideShade * max(Lighting.MIN_DEPTH_SHADE, depthShade)

            -- The light on this face, sampled just in front of it so the reading
            -- comes from the room the face is being seen from rather than from
            -- inside the wall. Three channels, so a coloured source tints the
            -- surface instead of only brightening it.
            local briR, briG, briB = base, base, base
            if state.lighting then
                local back = max(0, perpWallDist - WALL_LIGHT_BACKSTEP)
                local lr, lg, lb = state.lighting:sample(posX + rayDirX * back,
                                                        posY + rayDirY * back)
                briR, briG, briB = base * lr, base * lg, base * lb
            end

            -- One quad, retargeted per column. Allocating a quad per column per
            -- frame means ~800 allocations every frame at 60 Hz, which is exactly
            -- how a raycaster ends up fighting the garbage collector instead of
            -- drawing walls.
            local quad = state.columnQuad
            quad:setViewport(texX, 0, 1, texSize, texSize, texSize)

            love.graphics.setColor(briR, briG, briB)
            love.graphics.draw(
                image, quad,
                x, drawStart, 0, 1, (drawEnd - drawStart) / texSize
            )

            -- Fog tint over the strip, so distant walls take the atmosphere's
            -- colour rather than merely going dark.
            local fogAlpha = min(0.85, (perpWallDist / maxView) ^ 1.2)
            if fogAlpha > 0.01 then
                love.graphics.setColor(fog[1], fog[2], fog[3], fogAlpha)
                love.graphics.rectangle('fill', x, drawStart, 1, drawEnd - drawStart)
            end

            love.graphics.setColor(1, 1, 1)
        end
    end

    -- Ceilings are drawn as a flat band where the zone says there is one. A full
    -- per-pixel ceiling cast is a later phase; this reads correctly and costs
    -- almost nothing.
    if not hasCeiling(floor(posX) + 1, floor(posY) + 1) then
        local theme = Themes.get(state.theme)
        local sky = theme.sky or { 0.3, 0.35, 0.45 }
        love.graphics.setColor(sky[1], sky[2], sky[3], 0.35)
        love.graphics.rectangle('fill', 0, 0, w, max(0, floor(horizon)))
        love.graphics.setColor(1, 1, 1)
    end

    return zBuffer
end

Raycaster.state = state

return Raycaster
