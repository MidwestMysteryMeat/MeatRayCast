--[[
    app.draw — every pixel the demo puts on screen.

    Eleventh cut of un-god-filing main.lua: the whole render path. The
    world pass (with the A7 render-scale canvas), the camera decision chain
    (eyes -> spectator -> photo/rail), the demo's lighting policy, and every
    overlay in its fixed order — crosshair, screen FX, HUD kit, minimap,
    bag, messages, intermission, shell, console last (a console that can be
    covered by a death screen is a console you cannot debug the death with).

    Exports { hudState, lightingFor, draw }: the first two are shared with
    love.update (the HUD watches state deltas; join/reseed rebuild
    lighting); draw() IS love.draw.
]]

local InventoryView = require('meatray.ui.inventory_view')

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Net, Weapons, Inventory = ctx.Net, ctx.Weapons, ctx.Inventory
    local note, args = ctx.note, ctx.args
    local activeWorld, activeEntities = ctx.activeWorld, ctx.activeEntities
    local activePlayer = ctx.activePlayer
    local drawDecals, drawParticles = ctx.drawDecals, ctx.drawParticles

    local M = {}

    -- What the HUD model watches each frame. The flash comes from deltas in these
    -- numbers, so this works identically for a host and for a client whose hp
    -- arrives in snapshots — see meatray/game/hud.lua.
    function M.hudState(player)
        if not player then return {} end
        local health = player:get('health')
        local status = Weapons.status(player)
        local carried = status and Inventory.count(player,
            status.id == 'launcher' and 'ammo.grenade' or 'ammo.pistol') or nil
        return {
            hp = health and health.hp, hpMax = health and health.max,
            weapon = status, carried = carried,
        }
    end

    -----------------------------------------------------------------------
    -- Lighting. Demo policy, not an engine rule: the engine ships lighting
    -- off by default, and this is one way to switch it on.
    -----------------------------------------------------------------------

    -- How dark an unlit tile is before meatray.render.lighting applies its own
    -- readability floor. Low enough that a torch is worth carrying, high enough that
    -- the floor is what you actually see in an unlit room rather than a clamp you
    -- never reach.
    local DEMO_BASE_LEVEL = 0.34

    -- Static lights are placed deterministically off the tile coordinates, not from
    -- an RNG: a host and a client that generate the same world must bake the same
    -- lighting, and "the level looks different on each machine" is a bug that only
    -- shows up with two people in the room.
    local function placeStaticLights(grid, world)
        local placed = 0

        for ty = 2, world.height - 1 do
            for tx = 2, world.width - 1 do
                if placed < 18 and not world:isSolid(tx, ty)
                   and (tx * 7 + ty * 13) % 29 == 0 then
                    -- Against a wall, so it reads as a sconce rather than as a
                    -- floating ball of light.
                    local againstWall = world:isSolid(tx - 1, ty) or world:isSolid(tx + 1, ty)
                                   or world:isSolid(tx, ty - 1) or world:isSolid(tx, ty + 1)
                    if againstWall then
                        placed = placed + 1
                        -- Every third one is cold, so a coloured light tinting a wall
                        -- is visible in any screenshot of the demo rather than only
                        -- in a scene built to show it.
                        local cold = (placed % 3 == 0)
                        grid:addStatic{
                            x = tx - 0.5, y = ty - 0.5,
                            radius = cold and 5.5 or 6.5,
                            intensity = cold and 0.85 or 1.0,
                            color = cold and { 0.30, 0.58, 1.00 } or { 1.00, 0.60, 0.24 },
                        }
                    end
                end
            end
        end

        return placed
    end

    -- Built once per world and cached against it, so switching level, reseeding, or
    -- joining a host all rebuild it exactly once and nothing rebakes per frame.
    function M.lightingFor(world)
        if not world then return nil end
        if game.lighting and game.lightingWorld == world then return game.lighting end

        local grid = MeatRay.lighting.new{ world = world, baseLevel = DEMO_BASE_LEVEL }
        local placed = placeStaticLights(grid, world)
        grid:update()

        game.lighting, game.lightingWorld = grid, world
        if MeatRay.canRender() then MeatRay.raycaster.setLighting(grid) end
        note(('lighting: %d static lights baked'):format(placed))
        return grid
    end

    -----------------------------------------------------------------------
    -- A7: the render-scale pass.
    --
    -- At scale 1 these two are almost nothing: the world draws straight to the
    -- window, exactly as it did before options existed. Below 1 they route it
    -- through a canvas the size `options:renderSize` asked for, and the renderer
    -- is told that smaller size so its column loop and its z-buffer are the ones
    -- the buffer actually has. The upscale is nearest-neighbour on purpose —
    -- smoothing a software raycaster's output is how a deliberate low-res look
    -- turns into a smeared one.
    -----------------------------------------------------------------------

    local function beginWorldPass()
        local scale = game.options and game.options:getGraphics().scale or 1
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        if scale >= 1 then
            -- Still make sure the renderer agrees with the window, in case the
            -- previous frame was scaled and this one is not.
            MeatRay.raycaster.resize(w, h)
            return nil
        end

        local cw, ch = game.options:renderSize(w, h)
        local canvas = game.scaleCanvas
        if not canvas or game.scaleCanvasW ~= cw or game.scaleCanvasH ~= ch then
            canvas = love.graphics.newCanvas(cw, ch)
            canvas:setFilter('nearest', 'nearest')
            game.scaleCanvas, game.scaleCanvasW, game.scaleCanvasH = canvas, cw, ch
        end

        MeatRay.raycaster.resize(cw, ch)
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        return { canvas = canvas, w = w, h = h, cw = cw, ch = ch }
    end

    local function endWorldPass(target)
        if not target then return end
        love.graphics.setCanvas()
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(target.canvas, 0, 0, 0,
                           target.w / target.cw, target.h / target.ch)
        -- The HUD that follows measures itself against the window, so put the
        -- renderer back before anything else asks how big the screen is.
        MeatRay.raycaster.resize(target.w, target.h)
    end

    -- G1: the shell drawn. One column of rows, a cursor, and per-kind value
    -- text; the whole point of the model split is that this function is the only
    -- place any of that becomes pixels.
    local function drawShell()
        if not game.shell:isOpen() then return end
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        local screen = game.shell:current()
        local lineH = love.graphics.getFont():getHeight() + 10

        love.graphics.setColor(0, 0, 0, 0.82)
        love.graphics.rectangle('fill', 0, 0, w, h)
        love.graphics.setColor(0.95, 0.85, 0.40)
        love.graphics.printf(screen.title or screen.id, 0, h * 0.14, w, 'center')

        local rows = screen.rows
        local top = h * 0.26
        -- Long screens (options) scroll around the cursor.
        local lineCount = math.floor((h * 0.62) / lineH)
        local first = 1
        if #rows > lineCount then
            first = math.max(1, math.min(screen.selected - math.floor(lineCount / 2),
                                         #rows - lineCount + 1))
        end

        for i = first, math.min(#rows, first + lineCount - 1) do
            local row = rows[i]
            local y = top + (i - first) * lineH
            local isSel = (i == screen.selected)

            love.graphics.setColor(isSel and 1 or 0.62, isSel and 1 or 0.62,
                                   isSel and 0.75 or 0.65)
            love.graphics.printf((isSel and '> ' or '  ') .. row.label,
                                 w * 0.22, y, w * 0.34, 'left')

            local value
            if row.kind == 'toggle' then
                value = row.value and 'on' or 'off'
            elseif row.kind == 'slider' then
                value = ('%.2f'):format(tonumber(row.value) or 0)
            elseif row.kind == 'choice' then
                value = tostring(row.value)
            elseif row.kind == 'bind' then
                local keys = row.value
                value = type(keys) == 'table' and table.concat(keys, ', ')
                        or tostring(keys or '')
                if isSel and game.shell:capturing() == 'bind' then
                    value = 'press a key...'
                end
            elseif row.kind == 'text' then
                value = tostring(row.value or '')
                if isSel and game.shell:capturing() == 'text' then
                    value = value .. '_'
                end
            end
            if value then
                love.graphics.printf(value, w * 0.56, y, w * 0.24, 'right')
            end
        end

        love.graphics.setColor(0.5, 0.5, 0.55)
        love.graphics.printf(
            'arrows move   left/right adjust   enter select   esc back',
            0, h * 0.9, w, 'center')
        love.graphics.setColor(1, 1, 1)
    end

    -- F4: the tally between missions. Full-frame, over the world and the HUD;
    -- only the console outranks it.
    local function drawIntermission()
        if not game.intermission:active() then return end
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        love.graphics.setColor(0, 0, 0, 0.78)
        love.graphics.rectangle('fill', 0, 0, w, h)

        local head = game.intermission:header()
        love.graphics.setColor(0.95, 0.85, 0.40)
        love.graphics.printf(head.title or '', 0, h * 0.22, w, 'center')

        local y = h * 0.32
        for _, row in ipairs(game.intermission:rows()) do
            love.graphics.setColor(0.65, 0.65, 0.68)
            love.graphics.printf(row.label, w * 0.28, y, w * 0.18, 'left')
            love.graphics.setColor(row.done and 1 or 0.8, row.done and 1 or 0.8, 0.85)
            love.graphics.printf(row.text, w * 0.48, y, w * 0.24, 'right')
            y = y + love.graphics.getFont():getHeight() + 8
        end

        if head.prompt then
            love.graphics.setColor(0.55, 0.90, 0.55)
            love.graphics.printf('fire — ' .. head.prompt, 0, h * 0.72, w, 'center')
        end
        love.graphics.setColor(1, 1, 1)
    end

    -- C16: the bag as a grid overlay. Cells and their positions come from
    -- meatray.ui.inventory_view (grid + slots), tested; this blits them.
    local function drawBag(w, h)
        if not game.showBag then return end
        local player = activePlayer()
        if not player then return end
        local slots = InventoryView.slots(player)
        if #slots == 0 then return end

        local grid = InventoryView.grid(#slots, { cols = 4, cell = 46, pad = 6 })
        local ox = (w - grid.width) / 2
        local oy = (h - grid.height) / 2

        love.graphics.setColor(0, 0, 0, 0.72)
        love.graphics.rectangle('fill', ox - 16, oy - 34, grid.width + 32, grid.height + 50)
        love.graphics.setColor(0.9, 0.85, 0.5)
        love.graphics.print('BAG', ox, oy - 28)

        for _, cell in ipairs(grid.cells) do
            local slot = slots[cell.index]
            local x, y = ox + cell.x, oy + cell.y
            local sz = grid.cellSize

            -- The cell: brighter when it holds something, ringed when equipped.
            love.graphics.setColor(0.14, 0.15, 0.18, 0.95)
            love.graphics.rectangle('fill', x, y, sz, sz)
            if slot.equipped then
                love.graphics.setColor(0.95, 0.85, 0.35)
                love.graphics.rectangle('line', x, y, sz, sz)
            elseif not slot.empty then
                love.graphics.setColor(0.4, 0.42, 0.48)
                love.graphics.rectangle('line', x, y, sz, sz)
            end

            if not slot.empty then
                love.graphics.setColor(slot.over and 1 or 0.85,
                                       slot.over and 0.5 or 0.9, 0.85)
                love.graphics.printf(tostring(slot.name):sub(1, 8), x + 2, y + 4, sz - 4, 'center')
                love.graphics.setColor(1, 1, 1)
                love.graphics.printf(slot.countText, x + 2, y + sz - 16, sz - 4, 'center')
                -- Stack fill bar along the bottom edge.
                if slot.stack > 1 then
                    love.graphics.setColor(0.35, 0.7, 0.4, 0.8)
                    love.graphics.rectangle('fill', x + 2, y + sz - 3, (sz - 4) * slot.fill, 2)
                end
            end
        end
        love.graphics.setColor(1, 1, 1)
    end

    -- C28: the screen-effect layers, blitted full-frame. A fill is a flat rect; a
    -- vignette darkens only the edges. Drawn under the HUD so the numbers stay
    -- legible through a tint, over the world so the tint actually reads.
    local function drawScreenFX(w, h)
        for _, layer in ipairs(game.screenfx:layers()) do
            -- F8: photosensitivity — every full-screen effect's alpha runs through
            -- the accessibility flash scale, and its colour through the colourblind
            -- remap, so a player who dimmed flashes or set a colourblind mode sees
            -- the adjusted version.
            local c = game.a11y:colorTable(layer.color)
            local alpha = game.a11y:flash(layer.alpha)
            if layer.style == 'vignette' then
                -- Four edge bands, heavier than a fill would be, so the centre
                -- stays clear — the shape a damage/underwater edge wants.
                local edge = math.floor(math.min(w, h) * 0.18)
                love.graphics.setColor(c[1], c[2], c[3], alpha)
                love.graphics.rectangle('fill', 0, 0, w, edge)
                love.graphics.rectangle('fill', 0, h - edge, w, edge)
                love.graphics.rectangle('fill', 0, edge, edge, h - edge * 2)
                love.graphics.rectangle('fill', w - edge, edge, edge, h - edge * 2)
            else
                love.graphics.setColor(c[1], c[2], c[3], alpha)
                love.graphics.rectangle('fill', 0, 0, w, h)
            end
        end
        love.graphics.setColor(1, 1, 1)
    end

    -- F6: the three message channels. Killfeed top-right, ticker bottom-left
    -- above the HUD, centerprint dead centre. Every string and fade comes from
    -- meatray.game.messages; this is the only place any of it becomes pixels.
    local function drawMessages(w, h)
        local msg = game.messages

        -- Killfeed, top-right, newest at the top.
        local ky = 30
        for _, k in ipairs(msg:killfeed()) do
            local line = k.attacker and ('%s  »  %s'):format(k.attacker, k.victim)
                         or ('%s died'):format(k.victim)
            if k.cause then line = line .. ('  [%s]'):format(k.cause) end
            love.graphics.setColor(0.9, 0.85, 0.8, k.alpha)
            love.graphics.printf(line, 0, ky, w - 12, 'right')
            ky = ky + 16
        end

        -- Ticker, bottom-left, above where the HUD bars sit.
        local ticker = msg:ticker()
        local ty = h - 104
        for i = #ticker, 1, -1 do
            local row = ticker[i]
            local c = row.kind == 'pickup' and { 0.7, 0.95, 0.7 } or { 0.85, 0.85, 0.95 }
            love.graphics.setColor(c[1], c[2], c[3], row.alpha)
            love.graphics.print(row.text, 12, ty)
            ty = ty - 15
        end

        -- Centerprint, dead centre, exclusive.
        local c = msg:centered()
        if c then
            love.graphics.setColor(1, 0.95, 0.6, c.alpha)
            local oy = c.size == 'big' and -8 or 0
            love.graphics.printf(c.text, 0, h * 0.34 + oy, w, 'center')
        end
        love.graphics.setColor(1, 1, 1)
    end

    -- F3: the console overlay. Drawn last, over everything — a console that can
    -- be covered by a death screen is a console you cannot debug the death with.
    local function drawConsole()
        if not game.consoleOpen then return end
        local w = love.graphics.getWidth()
        local h = math.floor(love.graphics.getHeight() * 0.4)
        local lineH = love.graphics.getFont():getHeight() + 2

        love.graphics.setColor(0.05, 0.06, 0.08, 0.92)
        love.graphics.rectangle('fill', 0, 0, w, h)
        love.graphics.setColor(0.3, 0.6, 0.3, 0.9)
        love.graphics.rectangle('fill', 0, h - 1, w, 1)

        local ring = game.console:lines()
        local rows = math.floor((h - lineH * 1.5) / lineH)
        love.graphics.setColor(0.85, 0.9, 0.85)
        local y = h - lineH * 2
        for i = #ring, math.max(1, #ring - rows + 1), -1 do
            love.graphics.print(ring[i], 6, y)
            y = y - lineH
            if y < 0 then break end
        end

        love.graphics.setColor(1, 1, 1)
        love.graphics.print('] ' .. game.consoleInput .. '_', 6, h - lineH - 2)
    end

    -- The A4 feedback kit drawn: every number here comes from meatray.game.hud,
    -- and everything about how it looks is decided in this function and nowhere
    -- else. The debug print line above the log stays; this is the player-facing
    -- layer, that one is the developer-facing one.
    local function drawHudKit(w, h)
        local hud = game.hud

        -- Damage flash and heal glow, whole-frame washes. F8: through the
        -- accessibility flash scale (photosensitivity) and colourblind remap.
        local flash = hud:flashStrength()
        if flash > 0 then
            local fr, fg, fb = game.a11y:color(0.90, 0.08, 0.05)
            love.graphics.setColor(fr, fg, fb, game.a11y:flash(flash * 0.32))
            love.graphics.rectangle('fill', 0, 0, w, h)
        end
        local glow = hud:healStrength()
        if glow > 0 then
            local hr, hg, hb = game.a11y:color(0.20, 0.85, 0.30)
            love.graphics.setColor(hr, hg, hb, game.a11y:flash(glow * 0.18))
            love.graphics.rectangle('fill', 0, 0, w, h)
        end

        -- Low-health throb: a border, not a wash, so the world stays readable.
        local pulse = hud:lowPulse(love.timer.getTime())
        if pulse > 0 then
            local edge = 24
            love.graphics.setColor(0.80, 0.05, 0.05, pulse * 0.30)
            love.graphics.rectangle('fill', 0, 0, w, edge)
            love.graphics.rectangle('fill', 0, h - edge, w, edge)
            love.graphics.rectangle('fill', 0, edge, edge, h - edge * 2)
            love.graphics.rectangle('fill', w - edge, edge, edge, h - edge * 2)
        end

        -- Hit marker: four ticks just outside the crosshair.
        local hit = hud:hitStrength()
        if hit > 0 then
            love.graphics.setColor(1, 1, 1, hit)
            for _, s in ipairs{ {1,1}, {1,-1}, {-1,1}, {-1,-1} } do
                love.graphics.line(w / 2 + s[1] * 9,  h / 2 + s[2] * 9,
                                   w / 2 + s[1] * 15, h / 2 + s[2] * 15)
            end
        end

        -- Directional damage: arcs around the crosshair. The model hands over a
        -- relative bearing where 0 is dead ahead; on screen, ahead is up.
        for _, ind in ipairs(hud:indicators()) do
            local a = -ind.angle - math.pi / 2
            love.graphics.setColor(0.95, 0.15, 0.10, ind.strength * 0.9)
            love.graphics.arc('line', 'open', w / 2, h / 2, 52, a - 0.35, a + 0.35)
        end

        local rows = hud:bars()

        -- Health (and armour, when a game tracks it), bottom-left.
        local x, y = 10, h - 78
        if rows.hp then
            local frac = rows.hp.fraction
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.rectangle('fill', x, y, 180, 14)
            love.graphics.setColor(0.90 - 0.55 * frac, 0.15 + 0.60 * frac, 0.14, 0.9)
            love.graphics.rectangle('fill', x + 1, y + 1, 178 * frac, 12)
            love.graphics.setColor(1, 1, 1)
            love.graphics.print(('%d / %d'):format(rows.hp.value, rows.hp.max),
                                x + 4, y - 1)
            y = y + 18
        end
        if rows.armour then
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.rectangle('fill', x, y, 180, 10)
            if rows.armour.fraction then
                love.graphics.setColor(0.35, 0.55, 0.90, 0.9)
                love.graphics.rectangle('fill', x + 1, y + 1,
                                        178 * rows.armour.fraction, 8)
            end
            love.graphics.setColor(1, 1, 1)
            love.graphics.print(tostring(rows.armour.value), x + 186, y - 3)
        end

        -- Weapon and ammo, bottom-right.
        if rows.weapon then
            local text
            if rows.weapon.reloading then
                text = ('%s  reloading %d%%'):format(rows.weapon.id,
                    math.floor((rows.weapon.reloadFraction or 0) * 100 + 0.5))
            else
                text = ('%s  %d/%s%s'):format(rows.weapon.id, rows.weapon.ammo,
                    tostring(rows.weapon.magazine or '-'),
                    rows.weapon.carried and ('  (%d)'):format(rows.weapon.carried) or '')
            end
            love.graphics.setColor(1, 1, 1, rows.weapon.empty and 0.5 or 1)
            love.graphics.print(text, w - 10 - love.graphics.getFont():getWidth(text),
                                h - 78)
        end

        -- F1: say when the frame is a recording or a replay. The dot is the
        -- classic camcorder promise that input is being written down.
        if game.demoRec then
            love.graphics.setColor(0.95, 0.2, 0.15)
            love.graphics.circle('fill', w - 18, 18, 5)
            love.graphics.print('REC', w - 52, 10)
        elseif game.demoPlay then
            love.graphics.setColor(0.4, 0.9, 0.5)
            local tag = game.demoDiverged
                and ('PLAY (diverged @%d)'):format(game.demoDiverged) or 'PLAY'
            love.graphics.print(tag, w - 10 - love.graphics.getFont():getWidth(tag), 10)
        end
        love.graphics.setColor(1, 1, 1)

        -- A8: paused, or over. Drawn before the death overlay reads, because
        -- being disconnected outranks being dead — a corpse in a session that
        -- ended is not waiting for anything.
        if game.session:isOver() then
            love.graphics.setColor(0, 0, 0, 0.72)
            love.graphics.rectangle('fill', 0, 0, w, h)
            local head = game.session:endedByChoice() and 'left the game' or 'disconnected'
            local why = tostring(game.session:reason() or '')
            love.graphics.setColor(0.95, 0.75, 0.30)
            love.graphics.printf(head, 0, h / 2 - 40, w, 'center')
            love.graphics.setColor(0.85, 0.85, 0.85)
            love.graphics.printf(why, 0, h / 2 - 18, w, 'center')
            love.graphics.printf('P for a fresh game', 0, h / 2 + 12, w, 'center')
            love.graphics.setColor(1, 1, 1)
            return
        end
        if game.session:isPaused() then
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.rectangle('fill', 0, 0, w, h)
            love.graphics.setColor(1, 1, 1)
            love.graphics.printf('paused', 0, h / 2 - 24, w, 'center')
            love.graphics.printf('P to resume', 0, h / 2, w, 'center')
        elseif game.session:menuOpen() then
            -- Online: the menu is up but the world is still moving. Say so, so
            -- nobody reads a menu as safety.
            love.graphics.setColor(1, 0.85, 0.4)
            love.graphics.printf('menu open — the game is still running',
                                 0, 10, w, 'center')
            love.graphics.setColor(1, 1, 1)
        end

        -- A5 feedback: the dead see the wait; the just-returned see their shield.
        local player = activePlayer()
        if game.respawn:state('local') ~= 'alive' then
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.rectangle('fill', 0, 0, w, h)
            local left = game.respawn:remaining('local')
            local text = left > 0 and ('you died — back in %.1f'):format(left)
                                  or 'you died'
            love.graphics.setColor(0.92, 0.25, 0.18)
            love.graphics.printf(text, 0, h / 2 - 32, w, 'center')
            -- D35: name what the camera is doing while you are down.
            local scam = game.spectator:camera(player)
            if scam then
                love.graphics.setColor(0.8, 0.8, 0.85)
                local tag = scam.mode == 'killcam' and 'killcam'
                         or ('spectating ' .. (scam.targetName or 'a player')
                             .. '  —  click to cycle')
                love.graphics.printf(tag, 0, h / 2 - 8, w, 'center')
            end
        elseif player and Game.respawn.isProtected(player) then
            love.graphics.setColor(0.45, 0.80, 1.00, 0.55)
            love.graphics.circle('line', w / 2, h / 2, 24)
        end

        love.graphics.setColor(1, 1, 1)
    end

    -----------------------------------------------------------------------
    -- The frame
    -----------------------------------------------------------------------

    function M.draw()
        if args.selftest then return end

        local world, player = activeWorld(), activePlayer()
        if not world or not player then
            love.graphics.setColor(1, 1, 1)
            -- A8: a client that joined without ever loading a local level has no
            -- world to fall back to when the session ends, and "no world" is not
            -- what happened. Say what did.
            local headline = game.client and 'connecting...' or 'no world'
            if game.session:isOver() then
                headline = ('disconnected: %s   —   P for a fresh game')
                           :format(tostring(game.session:reason() or ''))
            end
            love.graphics.print(headline, 8, 8)
            for i, line in ipairs(game.log) do love.graphics.print(line, 8, 26 + (i - 1) * 14) end
            drawShell()
            drawConsole()
            return
        end

        -- The local player is predicted, so it interpolates on the simulation tick;
        -- everything the host owns interpolates between snapshots. Two different
        -- alphas, because they are two different clocks.
        local cameraAlpha = game.client and game.client:tickAlpha() or game.alpha
        local px, py, pangle, pz = player:interpolated(cameraAlpha)
        local storey = player.storey or 1

        -- D35: when the spectator has a pose (killcam or spectating a live player),
        -- the camera comes from there instead of the player's own eyes.
        local spCam = game.spectator:camera(player)
        if spCam then
            px, py, pangle = spCam.x, spCam.y, spCam.angle
            storey = spCam.storey or storey
        end
        -- F10/C20: a detached script camera wins over both eyes and spectator —
        -- the photo free-cam, or a running cutscene rail. Same pose shape, so the
        -- renderer treats them alike; the only extra a photo pose carries is a FOV.
        local photoCam = game.photo:pose()
            or (game.rail and game.rail:isActive() and game.rail:pose())
            or nil
        local camPitch = game.pitch
        local camFovPlane = nil
        if photoCam then
            px, py, pangle = photoCam.x, photoCam.y, photoCam.angle
            storey = photoCam.storey or storey
            camPitch = photoCam.pitch or camPitch
            -- radians of horizontal FOV -> the raycaster's camera-plane scale.
            if photoCam.fov then camFovPlane = math.tan(photoCam.fov * 0.5) end
        end

        local floorZ = pz or player.z or 0
        local eyeHeight = MeatRay.world.EYE_HEIGHT
        -- Low ceilings crouch the camera (relative ceiling within storey) — but a
        -- free-cam flies where you put it, ceilings and all, so it never crouches.
        if world.ceilingHeightAtPoint and not photoCam then
            local relFloor = world.floorHeightAtPoint
                and world:floorHeightAtPoint(px, py, storey) or 0
            local relCeil = world:ceilingHeightAtPoint(px, py, storey)
            local room = relCeil - relFloor
            local maxEye = room - 0.08
            if maxEye < 0.12 then maxEye = 0.12 end
            if eyeHeight > maxEye then eyeHeight = maxEye end
        end
        -- In photo mode the flown z is an absolute camera height (seeded from the
        -- eye on entry), decoupled from the player's floor.
        local eyeZ = photoCam and photoCam.z or (floorZ + eyeHeight)
        local view = MeatRay.raycaster.view(px, py, pangle, {
            eyeZ = eyeZ,
            eyeHeight = eyeHeight,
            pitch = camPitch,
            storey = storey,
            fovPlane = camFovPlane,   -- nil = the configured default
        })

        -- One frame of lighting: forget last frame's dynamic lights, then declare
        -- this frame's. The carried torch is the whole demonstration that dynamic
        -- light costs nothing to move — it changes position every single frame and
        -- rebakes nothing.
        local lighting = M.lightingFor(world)
        if lighting then
            lighting:beginFrame()
            if game.torch then
                lighting:addDynamic{
                    x = px, y = py, radius = 6.5, intensity = 0.9,
                    color = { 1.00, 0.86, 0.62 },
                }
            end

            -- Explosion flashes, fading. `Explosion.detonate` described these; the
            -- game decided to keep them for a quarter of a second and push them here,
            -- and a dedicated server ignored the same descriptions entirely.
            for i = 1, #game.flashes do
                local f = game.flashes[i]
                local fade = f.life / f.maxLife
                lighting:addDynamic{
                    x = f.x, y = f.y, radius = f.radius,
                    intensity = f.intensity * fade, color = f.color, curve = 'inverse',
                }
            end

            -- Burning tiles glow. This is the gas field driving the light grid: the
            -- cost is one light per burning tile, bounded by the grid's own cap, and
            -- the field only reports cells that actually hold something.
            local field = (game.fireWorld == world) and game.fire or nil
            if field then
                local lit = 0
                field:each(function(tx, ty, d)
                    if d > 0.25 and lit < 24 then
                        lit = lit + 1
                        local strength = d > 1 and 1 or d
                        lighting:addDynamic{
                            x = tx - 0.5, y = ty - 0.5,
                            radius = 2.2 + strength * 2.0,
                            intensity = 0.5 + strength * 0.9,
                            color = { 1.00, 0.52, 0.18 },
                            curve = 'inverse',
                        }
                    end
                end)
            end
        end

        -- A7: the world is drawn at the render scale, the HUD at native. Below
        -- scale 1 that means an offscreen canvas the size the options asked for,
        -- stretched over the window afterwards — the one graphics setting that
        -- reliably buys frames on a software raycaster, because the cost here is
        -- per pixel and nothing else in the frame is.
        local target = beginWorldPass()

        game.zbuffer = MeatRay.raycaster.render(view, world)

        local atmosphere = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())
        MeatRay.sprites.draw(activeEntities(), game.zbuffer, view, {
            time = (game.clock and game.clock:time()) or 0,
            alpha = game.alpha,
            ambient = atmosphere.ambient,
            maxView = atmosphere.maxView,
            lighting = lighting,
        })

        drawDecals(view, game.zbuffer)
        drawParticles(view, game.zbuffer)

        endWorldPass(target)

        -- HUD
        love.graphics.setColor(1, 1, 1)
        local health = player:get('health')
        local status = Weapons.status(player)
        local carried = status and Inventory.count(player,
                            status.id == 'launcher' and 'ammo.grenade' or 'ammo.pistol') or 0
        love.graphics.print(('%d fps   hp %d/%d   %s %d/%d (%d)%s   [%s]  theme %s  %s')
            :format(love.timer.getFPS(),
                    health and health.hp or 0, health and health.max or 0,
                    status and status.id or 'unarmed',
                    status and status.ammo or 0, status and status.magazine or 0,
                    carried,
                    (status and status.reloading) and ' reloading' or '',
                    game.source, MeatRay.raycaster.getTheme(), Net.mode()), 8, 8)

        if game.host then
            love.graphics.print(('hosting on UDP %d   %d player(s)   %s')
                :format(game.host.port, game.host:playerCount(), game.host.report.reach),
                8, love.graphics.getHeight() - 52)
        elseif game.client then
            love.graphics.print(('client of %s   %d player(s)   snapshots %d   corrections %d')
                :format(game.client.address, game.client:playerCount(),
                        game.client.snapshots, game.client.corrections),
                8, love.graphics.getHeight() - 52)
        end

        for i, line in ipairs(game.log) do
            love.graphics.setColor(1, 1, 1, 1 - (i - 1) * 0.15)
            love.graphics.print(line, 8, 26 + (i - 1) * 14)
        end

        if game.showHelp then
            love.graphics.setColor(1, 1, 1, 0.75)
            love.graphics.print(
                'WASD move  mouse look (yaw+pitch)  Q/E turn  F door/stairs  click fire  L torch\n'
                .. '1 pistol  2 grenade launcher  M minimap  TAB world  R reseed  T theme\n'
                .. 'F1 help  I bag  F2 quality  F3/F4 fov  F6 record  F7 replay  O photo  P pause  ` console',
                8, love.graphics.getHeight() - 48)
        end

        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        -- F10: a hidden HUD means a clean frame — no crosshair, bars, minimap or
        -- bag. Only a small corner tag stays, and it too is gone once you exit.
        -- C20: a playing rail hides chrome for a clean cutscene frame too.
        local railActive = game.rail and game.rail:isActive()
        local chromeHidden = game.photo:hudIsHidden()
        if railActive then
            local rp = game.rail:pose()
            chromeHidden = chromeHidden or (rp and rp.hudHidden) or false
        end

        -- A crosshair, so firing has somewhere to aim.
        if not chromeHidden then
            love.graphics.setColor(1, 1, 1, 0.6)
            love.graphics.line(w / 2 - 6, h / 2, w / 2 + 6, h / 2)
            love.graphics.line(w / 2, h / 2 - 6, w / 2, h / 2 + 6)
            love.graphics.setColor(1, 1, 1)
        end

        -- C28: screen tints sit over the world and crosshair, under the HUD and
        -- messages, so a lava wash colours the scene without drowning the numbers.
        drawScreenFX(w, h)

        if game.photo:isActive() then
            love.graphics.setColor(0.9, 0.9, 0.95, 0.8)
            love.graphics.print(chromeHidden and 'photo  (H: HUD)'
                or 'PHOTO MODE  —  WASD/Space/Ctrl fly  mouse look  [ ] fov  H hud  O/Esc exit',
                8, 8)
            love.graphics.setColor(1, 1, 1)
        end

        if not chromeHidden then drawHudKit(w, h) end

        if not chromeHidden and game.showMinimap and MeatRay.minimap then
            if not game.minimap or game.minimap.world ~= world then
                game.minimap = MeatRay.minimap.new{
                    world = world, size = 128, corner = 'br', margin = 10,
                }
            end
            game.minimap:draw(px, py, pangle, {
                entities = activeEntities(),
                storey = storey,
                screenW = w, screenH = h,
                -- F2: only what this player has seen. The minimap has taken a
                -- fog table since it was written; this is the memory behind it.
                fog = game.automap:visited(storey),
            })
        end

        if not chromeHidden then drawBag(w, h) end
        if not chromeHidden then drawMessages(w, h) end
        drawIntermission()
        drawShell()
        drawConsole()
    end

    return M
end
