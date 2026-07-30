--[[
    meatray.render.sprites — the sprite registry and the billboard draw pass.

    All the arithmetic lives in meatray.sim.billboard, which is headless and
    tested; this module is the part that needs a GPU. It keeps a registry of
    sprite definitions, generates placeholder sheets for any sprite with no image
    (which today is all of them, since the engine ships no media), and draws
    entities as vertical billboards clipped against the raycaster's z-buffer.

    A definition declares how many angle buckets its sheet provides. `angles = 1`
    is a single image that always faces the viewer; `angles = 8` is Doom-style
    directional. Nothing here assumes 8 — the sheet layout is rows of angle
    buckets by columns of animation frames, whatever the counts.
]]

local Platform = require('meatray.platform')
local Billboard = require('meatray.sim.billboard')
local Lighting = require('meatray.render.lighting')

local Sprites = {}

local floor, max, min = math.floor, math.max, math.min

local registry = {}
local CELL = 48          -- placeholder cell size, in pixels

---------------------------------------------------------------------------
-- Placeholder generation
---------------------------------------------------------------------------

-- Draws a distinct silhouette per angle bucket so directional facing is visibly
-- verifiable without art: bucket 0 (facing the viewer) gets a full body with two
-- eyes, side buckets get a narrower body with one eye, and the rear bucket gets
-- no eyes at all. If facing is wired up wrongly you can see it immediately, which
-- is the entire point of a placeholder.
local function placeholderSheet(angles, frames, color)
    local w, h = CELL * frames, CELL * angles
    local data = Platform.gfx.newImageData(w, h)

    local r, g, b = color[1], color[2], color[3]

    for bucket = 0, angles - 1 do
        -- 0 = facing viewer, angles/2 = facing away.
        local half = angles / 2
        local awayness = angles > 1 and (min(bucket, angles - bucket) / half) or 0
        local facingAway = awayness > 0.99

        for frame = 0, frames - 1 do
            local ox, oy = frame * CELL, bucket * CELL
            -- A one-pixel bob per frame, so animation is visible too.
            local bob = (frame % 2 == 0) and 0 or 1

            local bodyW = floor(CELL * (0.46 - awayness * 0.10))
            local bodyH = floor(CELL * 0.62)
            local bodyX = floor((CELL - bodyW) / 2)
            local bodyY = CELL - bodyH - 2 + bob

            -- Every pixel is written at its own cell offset (ox, oy) directly.
            -- An earlier version drew each cell at the origin and then shifted it
            -- into place, which moved frame 0's pixels into frame 1 and erased
            -- frame 0 in the process. Compute the destination once instead.
            local headR = floor(CELL * 0.15)
            local hx, hy = CELL / 2, bodyY - headR

            for py = 0, CELL - 1 do
                for px = 0, CELL - 1 do
                    local inBody = px >= bodyX and px < bodyX + bodyW
                                   and py >= bodyY and py < bodyY + bodyH
                    local inHead = ((px - hx) ^ 2 + (py - hy) ^ 2) < headR * headR

                    if inBody or inHead then
                        local shade = 1 - awayness * 0.35
                        -- A lighter front panel, so the facing side is obvious.
                        if inBody and not facingAway and px > bodyX + bodyW * 0.25
                           and px < bodyX + bodyW * 0.75 then
                            shade = shade * 1.25
                        end
                        data:setPixel(ox + px, oy + py,
                                      min(1, r * shade), min(1, g * shade), min(1, b * shade), 1)
                    end
                end
            end

            -- Eyes: two facing the viewer, one in profile, none from behind. This
            -- is what makes a facing bug visible instead of subtle.
            if not facingAway then
                local eyeY = floor(bodyY - CELL * 0.15)
                local eyes = (awayness < 0.5) and { -0.07, 0.07 } or { 0.0 }
                for _, dx in ipairs(eyes) do
                    local ex = floor(CELL / 2 + CELL * dx)
                    for py = eyeY, eyeY + 1 do
                        for px = ex, ex + 1 do
                            if px >= 0 and px < CELL and py >= 0 and py < CELL then
                                data:setPixel(ox + px, oy + py, 1, 1, 1, 1)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Nearest filtering is applied by the backend, for every image the engine
    -- makes: it is the house style rather than this call site's preference, and a
    -- host that smoothed placeholders would look broken rather than different.
    return Platform.gfx.newImage(data)
end

---------------------------------------------------------------------------
-- Registry
---------------------------------------------------------------------------

-- Defines a sprite. `image` is optional: with none, a placeholder sheet is
-- generated, which is what keeps the engine runnable with zero media.
--
--   Sprites.define('imp', { angles = 8, frames = 4, fps = 8, color = {0.7,0.2,0.2} })
--
function Sprites.define(name, def)
    assert(type(name) == 'string' and name ~= '', 'sprite needs a name')
    def = def or {}

    local angles = def.angles or 1
    local frames = def.frames or 1
    assert(angles >= 1, 'angles must be at least 1')
    assert(frames >= 1, 'frames must be at least 1')

    local entry = {
        name = name,
        angles = angles,
        frames = frames,
        fps = def.fps or 8,
        anchor = def.anchor or 'feet',
        scale = def.scale or 1,
        color = def.color or { 0.7, 0.7, 0.7 },
        image = def.image,
        generated = def.image == nil,
    }

    if not entry.image then
        entry.image = placeholderSheet(angles, frames, entry.color)
        entry.cellW, entry.cellH = CELL, CELL
    else
        -- An imported sheet is rows of buckets by columns of frames.
        entry.cellW = floor(entry.image:getWidth() / frames)
        entry.cellH = floor(entry.image:getHeight() / angles)
    end

    -- Quads are built once. Rebuilding them per frame per sprite is the classic
    -- way to make a raycaster allocate its way into a stutter.
    entry.quads = {}
    for bucket = 0, angles - 1 do
        entry.quads[bucket] = {}
        for frame = 0, frames - 1 do
            entry.quads[bucket][frame] = Platform.gfx.newQuad(
                frame * entry.cellW, bucket * entry.cellH,
                entry.cellW, entry.cellH,
                entry.image:getWidth(), entry.image:getHeight())
        end
    end

    registry[name] = entry
    return entry
end

function Sprites.get(name)
    return registry[name]
end

function Sprites.defined(name)
    return registry[name] ~= nil
end

function Sprites.names()
    local out = {}
    for name in pairs(registry) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Sprites.clear()
    registry = {}
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- Draws every entity carrying a `billboard` component, clipped against the
-- z-buffer so walls hide what is behind them.
--
--   Sprites.draw(entities, zbuffer, view, { time = clock:time(), alpha = alpha })
--
-- Pass `lighting` (a meatray.render.lighting grid) and every sprite is shaded by
-- the light where it is standing, on the same curve and with the same floor the
-- wall loop uses. That is what puts an entity *in* the scene: shaded by distance
-- alone, a creature in an unlit corner is as bright as one under a torch, and the
-- eye reads it as pasted on top of the render rather than standing in it.
function Sprites.draw(entities, zbuffer, view, opts)
    opts = opts or {}
    local gfx = Platform.gfx
    local screenW = opts.screenW or gfx.getWidth()
    local screenH = opts.screenH or gfx.getHeight()
    local time = opts.time or 0
    local alpha = opts.alpha or 1
    local ambient = opts.ambient or 1
    local maxView = opts.maxView or 32
    local lighting = opts.lighting

    -- Project everything first, discard what is behind the camera, then paint
    -- far to near so nearer sprites cover farther ones.
    local visible = {}

    for i = 1, #entities do
        local e = entities[i]
        local billboard = (not e.dead) and e.components and e.components.billboard
        local def = billboard and registry[billboard.sheet]

        if def then
            local ex, ey, eangle = e:interpolated(alpha)

            local tx, ty = Billboard.project(ex, ey, view.x, view.y,
                                             view.dirX, view.dirY,
                                             view.planeX, view.planeY)
            if tx and ty < maxView then
                local rect = Billboard.screenRect(tx, ty, screenW, screenH, {
                    scale = billboard.scale or def.scale,
                    anchor = billboard.anchor or def.anchor,
                    horizonShift = view.horizonShift or 0,
                })

                if rect then
                    -- Which row of the sheet: how the entity is turned relative to
                    -- the line from the camera to it.
                    local bearing = Billboard.bearing(view.x, view.y, ex, ey)
                    local bucket = Billboard.angleBucket(eangle, bearing, def.angles)
                    local frame = Billboard.animFrame(time + (e.id or 0) * 0.13,
                                                      def.frames, def.fps)

                    visible[#visible + 1] = {
                        def = def, rect = rect, depth = ty,
                        bucket = bucket, frame = frame,
                        -- Kept so the draw pass can ask the light grid where this
                        -- entity is standing, which the screen rect no longer says.
                        wx = ex, wy = ey,
                    }
                end
            end
        end
    end

    Billboard.sortByDepth(visible)

    for i = 1, #visible do
        local item = visible[i]
        local def, rect = item.def, item.rect

        -- Per-column occlusion: a sprite half behind a wall must be half drawn,
        -- which is why the renderer hands back a z-buffer instead of a single
        -- depth per wall.
        local first, run = nil, 0
        local scaleX = rect.w / def.cellW
        local scaleY = rect.h / def.cellH

        -- The same depth curve and the same floor the wall loop uses, in the same
        -- order — `ambient * max(floor, depthShade)`, not `max(floor, ambient *
        -- depthShade)`. The old form floored at 0.15 after ambient while walls
        -- floored at 0.10 before it, which left distant sprites reading a shade
        -- brighter than the wall behind them.
        local depthShade = 1 - min(0.85, (rect.depth / maxView) ^ 0.9)
        local shade = ambient * max(Lighting.MIN_DEPTH_SHADE, depthShade)

        local shR, shG, shB = shade, shade, shade
        if lighting then
            local lr, lg, lb = lighting:sample(item.wx, item.wy)
            shR, shG, shB = shade * lr, shade * lg, shade * lb
        end
        gfx.setColor(shR, shG, shB)

        local quad = def.quads[item.bucket][item.frame]

        -- Drawing column runs rather than one strip per pixel keeps the draw call
        -- count sane; a fully visible sprite becomes a single draw.
        for x = rect.x, rect.x + rect.w - 1 do
            local ok = Billboard.columnVisible(x, rect.depth, zbuffer, screenW)
            if ok then
                if not first then first, run = x, 0 end
                run = run + 1
            elseif first then
                Sprites._drawRun(def, quad, rect, first, run, scaleX, scaleY)
                first, run = nil, 0
            end
        end
        if first then
            Sprites._drawRun(def, quad, rect, first, run, scaleX, scaleY)
        end
    end

    gfx.setColor(1, 1, 1)
    return #visible
end

-- Draws one horizontal run of a sprite by scissoring to it. Scissor is saved and
-- restored so a caller that had one set keeps it.
function Sprites._drawRun(def, quad, rect, startX, width, scaleX, scaleY)
    if width <= 0 then return end

    local gfx = Platform.gfx
    local sx, sy, sw, sh = gfx.getScissor()
    gfx.setScissor(startX, rect.y, width, rect.h)
    gfx.draw(def.image, quad, rect.x, rect.y, 0, scaleX, scaleY)

    -- setScissor with no arguments clears it, which is how the seam spells "no
    -- clip" as well.
    gfx.setScissor(sx, sy, sw, sh)
end

return Sprites
