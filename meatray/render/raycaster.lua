--[[
    meatray.render.raycaster — the wall, floor and ceiling renderer.

    One ray per screen column, walked across the tile grid until it meets
    something solid, drawn as a vertical strip whose height is inversely
    proportional to the distance. That is the whole idea; the value is in the
    details around it — texture coordinates, door offsets, side shading, fog, and
    the z-buffer that lets sprites hide behind walls.

    The floor and ceiling are cast too, per pixel, from the same camera. That
    half runs on the host's GPU rather than in this file: it is the one part of
    the frame whose cost is per *pixel* instead of per column, and the arithmetic
    that is 960 iterations for the walls is 576,000 for the background. A host
    with no shaders falls back to flat colour bands and keeps running, which is
    why `Raycaster.floorCastAvailable()` exists and why nothing here assumes it.

    This module owns no game concepts. It takes a view table and a World and
    returns a z-buffer. Themes and textures are looked up by name, and everything
    optional (ceilings, custom fog, sprite hooks) is injected rather than
    required, so the renderer works against a bare World with nothing else set up.
]]

local Platform = require('meatray.platform')
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
    floorCast = true,      -- textured floor/ceiling; false falls back to bands
}

-- How far back along the ray to sample the light on a wall face. The hit point
-- sits exactly on the boundary, and sampling *on* the boundary is a coin flip
-- between the open tile and the solid one; stepping a fraction of a tile back
-- toward the camera lands reliably in the room the face is being seen from.
local WALL_LIGHT_BACKSTEP = 0.05

-- Deferred fog strips, flat and reused for the life of the process: x, top,
-- height, alpha, repeating. `fogN` is how much of it this frame filled.
--
-- Drawing the fog inside the wall loop alternated a textured draw with an
-- untextured rectangle once per screen column, and a host can only batch
-- consecutive draws that share a texture, so every single column broke the
-- batch. Collecting the strips and replaying them in one pass afterwards costs
-- four numbers per column and turns ~1900 draw calls into a handful.
--
-- A table per frame — or worse, per column — would trade those draw calls for
-- garbage, which is not a trade worth making in the one loop that runs eight
-- hundred times a frame. This array only ever grows, and stops growing once the
-- widest frame yet has been drawn.
local fogStrips = {}
local fogN = 0

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Raycaster.init(opts)
    opts = opts or {}
    local gfx = Platform.gfx
    state.screenW = opts.width or gfx.getWidth()
    state.screenH = opts.height or gfx.getHeight()
    state.fovPlane = opts.fovPlane or 0.66
    Raycaster.setTheme(opts.theme or Themes.DEFAULT)

    -- Reused for every wall column; see the draw call in render(). Its viewport
    -- is retargeted per column into the wall atlas, so the source dimensions
    -- given here are only a starting shape.
    state.columnQuad = gfx.newQuad(0, 0, 1, Textures.SIZE,
                                   Textures.ATLAS_WIDTH, Textures.SIZE)
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

-- ATTRIBUTION -----------------------------------------------------------------
-- The floor and ceiling cast in the shader below (the row-distance derivation
-- from the distance to the horizon, the camera-height term, and the ray-per-
-- column interpolation that turns a screen pixel into a world coordinate) is
-- derived from `raycaster_floor.cpp` by Lode Vandevenne -- the same author, the
-- same tutorial and the same 2-clause BSD grant as `raycaster_textured.cpp`,
-- which the wall loop below already derives from.
--
--     Copyright (c) 2004-2019, Lode Vandevenne
--
-- The full license text is in the NOTICE file at the repository root, which
-- names both source files.
--
-- The original is a per-pixel loop in C++ writing into a framebuffer. What is
-- reproduced here is the algorithm, not the code: the loop is gone entirely,
-- because the same arithmetic evaluated per fragment on the GPU is the only
-- version of it that fits inside this renderer's frame budget. The shading,
-- fogging and theme integration around it are this project's own and match the
-- wall loop's formulas so that a floor and the wall standing on it agree about
-- how far away they are.
-------------------------------------------------------------------------------
--
-- Why a shader and not a Lua loop, recorded because the alternative looks
-- plausible until it is costed. At 960x600 the lower half of the frame is
-- 288,000 pixels. A Lua floor cast has to touch every one of them and then hand
-- the result to the host as a new image, sixty times a second. The wall loop
-- runs 960 times a frame and takes 0.58 ms; the same work per pixel is three
-- hundred times as many iterations. There is no arrangement of that loop that
-- lands inside a frame.
--
-- The batched alternative -- one textured quad per screen row, since floor
-- texture coordinates are linear along a row -- is correct and costs 600 draw
-- calls a frame. The wall loop was taken from 1920 draw calls to 2 on purpose;
-- adding 600 back for the background would undo it.
Raycaster.FLOOR_SHADER = [[
    extern vec2  camPos;      // camera position, in world tiles
    extern vec2  camDir;      // unit facing
    extern vec2  camPlane;    // camera plane, perpendicular to camDir
    extern vec2  quadOrigin;  // where this quad sits on screen, in pixels
    extern vec2  quadSize;    // and how big it is
    extern float screenW;
    extern float horizon;     // screen row the horizon falls on
    extern float posZ;        // eye height above the floor, in screen pixels
    extern float maxView;
    extern float ambient;
    extern float bandLight;   // the light where the camera stands
    extern float minShade;
    extern vec3  fogColor;
    extern Image floorTex;
    extern Image ceilTex;

    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
    {
        // Screen position from the quad's own texture coordinates rather than
        // from screen_coords: the renderer draws into an offscreen canvas in
        // the selftest and into the window everywhere else, and a quad's uv is
        // the one of the two that means the same thing in both.
        vec2 px = quadOrigin + uv * quadSize;

        // Distance from the horizon, in pixels. Above it we are looking at the
        // ceiling, below it at the floor, and the two are mirror images.
        float p = px.y - horizon;
        float up = step(p, 0.0);
        // Half a pixel, not an epsilon: the horizon row itself is infinitely
        // far away, and clamping it to a large finite distance puts it fully
        // into the fog, which is where it belongs.
        p = max(abs(p), 0.5);

        // The whole cast, in one line. A surface one eye-height away vertically
        // that appears p pixels from the horizon is posZ/p tiles away, which is
        // the same relation the wall loop inverts when it draws a wall h/dist
        // pixels tall.
        float rowDistance = posZ / p;

        float cameraX = 2.0 * px.x / screenW - 1.0;
        vec2 world = camPos + (camDir + camPlane * cameraX) * rowDistance;

        // One texture per world tile, so the tile edge is the seam.
        vec2 cell = fract(world);
        vec4 texel = mix(Texel(floorTex, cell), Texel(ceilTex, cell), up);

        // Deliberately the wall loop's own falloff, term for term. A floor that
        // fogged on a different curve from the wall standing on it reads as two
        // surfaces at two distances.
        float t = min(rowDistance / maxView, 8.0);
        float depthShade = 1.0 - min(0.85, pow(t, 0.9));
        float lit = ambient * max(minShade, depthShade) * bandLight;

        // Capped at 1.0 where the walls cap at 0.85: a wall past the view
        // distance simply is not drawn, but the floor runs all the way to the
        // horizon and has to actually arrive at the fog colour there, or the
        // horizon is a visible seam.
        float fogA = min(1.0, pow(t, 1.2));

        return vec4(mix(texel.rgb * lit, fogColor, fogA), 1.0) * color;
    }
]]

-- Compiled once per process. `init` may be called many times -- the selftest
-- calls it for every scene it renders -- and a shader recompiled per call would
-- be the most expensive thing in the frame.
local floorShader, floorShaderReason
local floorShaderTried = false
local castQuad          -- a 1x1 white image, stretched to carry the shader

local function getFloorShader()
    if floorShaderTried then return floorShader end
    floorShaderTried = true
    floorShader, floorShaderReason = Platform.gfx.newShader(Raycaster.FLOOR_SHADER)
    if floorShader then castQuad = Textures.solid({ 1, 1, 1 }) end
    return floorShader
end

-- Whether textured floors are actually available here, and if not, why. A host
-- with no shaders is a supported host; it gets the flat bands.
function Raycaster.floorCastAvailable()
    return getFloorShader() ~= nil, floorShaderReason
end

-- Switches textured floor casting off, which is what the benchmark uses to
-- measure both paths out of one build rather than out of two commits.
function Raycaster.setFloorCasting(on)
    state.floorCast = on and true or false
    return Raycaster
end

function Raycaster.floorCasting()
    return state.floorCast
end

-- Reused across frames. Six tables a frame is nothing next to the wall loop,
-- but the file's own rule is that the render path does not allocate, and an
-- exception with no reason behind it is how a rule stops being one.
local uCamPos, uCamDir, uCamPlane = { 0, 0 }, { 0, 0 }, { 0, 0 }
local uQuadOrigin, uQuadSize, uFog = { 0, 0 }, { 0, 0 }, { 0, 0, 0 }

local function drawBackground(view)
    local setColor, rectangle = Platform.gfx.setColor, Platform.gfx.rectangle
    local theme = Themes.get(state.theme)
    local w, h = state.screenW, state.screenH
    local horizon = floor(h / 2 + (view.horizonShift or 0))

    -- Floor and ceiling take the light where the camera is standing. Without
    -- this a dark room's walls go dark and its floor stays at full theme
    -- brightness, which reads as a rendering fault rather than as darkness.
    -- A sky is lit by the sky, so it is left alone.
    --
    -- Darkening only, deliberately. One sample stands in for the whole surface,
    -- so a light that brightened it would brighten the floor all the way to the
    -- horizon and put the whole lower half of the frame above every wall in the
    -- scene — a torch lighting the floor a hundred tiles away as strongly as the
    -- tile it is standing on. Darkness has no such problem: an unlit room is
    -- unlit at every distance.
    --
    -- Still one sample even with the cast running, and that is the honest
    -- limit of this phase rather than an oversight. The cast gives the floor a
    -- real per-pixel *distance*, which is what fixes the fog; it does not give
    -- it a per-pixel position in the light grid, because that needs the grid
    -- uploaded to the host as a texture. Until then a torch lights the walls
    -- around it and merely fails to pool on the floor.
    --
    -- Brightness only, not colour. This covers most of the frame, and tinting
    -- that much of the screen from one sample turns a warm torch into an orange
    -- filter over the whole view. The walls carry the colour of the light, which
    -- is where a viewer reads it from anyway.
    local bandLight = 1
    if state.lighting then
        local lr, lg, lb = state.lighting:sample(view.x, view.y)
        bandLight = min(1, (lr + lg + lb) / 3)
    end

    local atmosphere = Themes.atmosphere(state.theme)
    local fog = state.fogOverride or atmosphere.fog

    -- Which halves the cast covers.
    --
    -- The floor is cast whenever there is a shader; the ceiling only where the
    -- theme has one *and* the camera stands in a zone that has one. Outside a
    -- zone the old flat band still runs, because the sky wash at the end of
    -- render() paints over the top half in exactly that case and casting a
    -- ceiling underneath it would be work nobody sees.
    local textures = state.textures or Textures.forTheme(state.theme)
    local shader = state.floorCast and getFloorShader() or nil
    local castFloor = shader ~= nil and textures.floor ~= nil
    local castCeiling = castFloor and textures.ceiling ~= nil
                        and hasCeiling(floor(view.x) + 1, floor(view.y) + 1)

    if castFloor then
        local gfx = Platform.gfx
        local send = gfx.sendShader
        local top = castCeiling and 0 or horizon

        uCamPos[1], uCamPos[2] = view.x, view.y
        uCamDir[1], uCamDir[2] = view.dirX, view.dirY
        uCamPlane[1], uCamPlane[2] = view.planeX, view.planeY
        uQuadOrigin[1], uQuadOrigin[2] = 0, top
        uQuadSize[1], uQuadSize[2] = w, h - top
        uFog[1], uFog[2], uFog[3] = fog[1], fog[2], fog[3]

        send(shader, 'camPos', uCamPos)
        send(shader, 'camDir', uCamDir)
        send(shader, 'camPlane', uCamPlane)
        send(shader, 'quadOrigin', uQuadOrigin)
        send(shader, 'quadSize', uQuadSize)
        send(shader, 'screenW', w)
        -- The unrounded horizon, which is the one the wall loop uses. Rounding
        -- it here and not there would put the floor half a pixel out of step
        -- with the walls standing on it.
        send(shader, 'horizon', h / 2 + (view.horizonShift or 0))
        -- Eye height: half a wall, which is the assumption the wall loop
        -- already makes when it centres a wall of height h/dist on the horizon.
        send(shader, 'posZ', h / 2)
        send(shader, 'maxView', atmosphere.maxView)
        send(shader, 'ambient', atmosphere.ambient)
        -- One sample, at the camera, for the same reason the bands took one:
        -- see the note above. Per-pixel floor lighting needs the light grid
        -- uploaded as a texture, which is its own change.
        send(shader, 'bandLight', bandLight)
        send(shader, 'minShade', Lighting.MIN_DEPTH_SHADE)
        send(shader, 'fogColor', uFog)
        send(shader, 'floorTex', textures.floor)
        send(shader, 'ceilTex', textures.ceiling or textures.floor)

        setColor(1, 1, 1)
        gfx.setShader(shader)
        gfx.draw(castQuad, 0, top, 0, w, h - top)
        gfx.setShader(nil)
    end

    if not castCeiling then
        -- Above the horizon: sky if the theme is open, ceiling colour otherwise.
        local upper = theme.sky or theme.ceiling or { 0.08, 0.08, 0.10 }
        local ceilingLight = theme.sky and 1 or bandLight
        setColor(upper[1] * ceilingLight, upper[2] * ceilingLight,
                 upper[3] * ceilingLight)
        rectangle('fill', 0, 0, w, max(0, horizon))
    end

    if not castFloor then
        local lower = theme.floor or { 0.18, 0.18, 0.18 }
        setColor(lower[1] * bandLight, lower[2] * bandLight, lower[3] * bandLight)
        rectangle('fill', 0, horizon, w, h - horizon)
    end

    -- A cheap gradient toward the horizon, for whichever half is still a flat
    -- band. It is what fakes depth when there is no cast; where the cast runs,
    -- the shader has already applied the real thing at the real distance and a
    -- second pass of it would be fog on top of fog.
    --
    -- Guarded per rectangle rather than by splitting the loop in two, so that
    -- the surviving half draws in exactly the order it always did. The two
    -- halves overlap on the horizon row itself, and which of them lands on top
    -- there is decided by this interleaving.
    local bands = 24
    for i = 1, bands do
        local t = i / bands
        local bandH = (h - horizon) / bands
        if not castFloor then
            setColor(fog[1], fog[2], fog[3], (1 - t) * 0.55)
            rectangle('fill', 0, horizon + (i - 1) * bandH, w, bandH + 1)
        end
        if not castCeiling then
            setColor(fog[1], fog[2], fog[3], (1 - t) * 0.45)
            rectangle('fill', 0, horizon - i * bandH, w, bandH + 1)
        end
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

    -- Resolved once per frame, not once per column. The seam is a table lookup
    -- like any other, and eight hundred extra ones per frame inside the loop that
    -- draws every wall is exactly the cost this hoist exists to avoid — the same
    -- reason the quad below is allocated once and retargeted.
    local gfx = Platform.gfx
    local setColor, drawImage, rectangle = gfx.setColor, gfx.draw, gfx.rectangle

    -- One image for every wall material and the door, so a column that hits a
    -- different tile type than its neighbour changes a quad rather than a
    -- texture and stays in the same batch.
    local atlas, atlasW = textures.atlas, textures.atlasWidth
    local wallSlot, doorSlot = textures.wallSlot, textures.doorSlot

    fogN = 0

    setColor(1, 1, 1)

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

            -- Where this material starts in the atlas, in pixels.
            local slotX = isDoor and doorSlot or (wallSlot[tile] or wallSlot[1])

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
            quad:setViewport(slotX + texX, 0, 1, texSize, atlasW, texSize)

            setColor(briR, briG, briB)
            drawImage(
                atlas, quad,
                x, drawStart, 0, 1, (drawEnd - drawStart) / texSize
            )

            -- Fog tint over the strip, so distant walls take the atmosphere's
            -- colour rather than merely going dark. Recorded here and drawn
            -- after the loop: see fogStrips at the top of the file for why.
            local fogAlpha = min(0.85, (perpWallDist / maxView) ^ 1.2)
            if fogAlpha > 0.01 then
                fogStrips[fogN + 1] = x
                fogStrips[fogN + 2] = drawStart
                fogStrips[fogN + 3] = drawEnd - drawStart
                fogStrips[fogN + 4] = fogAlpha
                fogN = fogN + 4
            end
        end
    end

    -- The fog pass. Every strip is one screen column wide and no two columns
    -- overlap, so drawing them all after the walls puts exactly the same colour
    -- over exactly the same pixels as drawing each one the moment its wall was
    -- drawn.
    --
    -- It must land HERE, though: after the walls and before the ceiling band
    -- below, which paints over the top of the frame and therefore over the fog.
    -- Moving this pass any later would change what the ceiling looks like.
    if fogN > 0 then
        local fr, fg, fb = fog[1], fog[2], fog[3]
        for i = 1, fogN, 4 do
            setColor(fr, fg, fb, fogStrips[i + 3])
            rectangle('fill', fogStrips[i], fogStrips[i + 1], 1, fogStrips[i + 2])
        end
    end

    -- Unconditionally, not only when fog drew: the loop leaves the colour at the
    -- last column's brightness, and everything after this expects white.
    setColor(1, 1, 1)

    -- Where the camera stands outside every ceiling zone, the top of the frame
    -- is open air: wash it toward the sky colour. The cast in drawBackground
    -- skips the ceiling half in exactly this case, so this is painting over the
    -- flat band rather than over a textured ceiling.
    if not hasCeiling(floor(posX) + 1, floor(posY) + 1) then
        local theme = Themes.get(state.theme)
        local sky = theme.sky or { 0.3, 0.35, 0.45 }
        setColor(sky[1], sky[2], sky[3], 0.35)
        rectangle('fill', 0, 0, w, max(0, floor(horizon)))
        setColor(1, 1, 1)
    end

    return zBuffer
end

Raycaster.state = state

return Raycaster
