--[[
    C22: bots — the controller produces INPUT (not motion), fights what it
    sees, paths to what it does not, opens doors in the way, wanders when idle,
    is deterministic, and — driven through the real applyInput — actually
    closes on its target.
]]

return function(t)
    local Bot      = require('meatray.game.bot')
    local World    = require('meatray.sim.world')
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Rep      = require('meatray.net').replication
    local Game     = require('meatray.game')

    t.eq(Game.bot, Bot, 'Game.bot is the module')

    -- An open room with a wall down the middle (x=6) and a doorway gap at
    -- y=5, so line-of-sight and pathing both have something to work with.
    local function room()
        local g = {}
        for y = 1, 11 do
            g[y] = {}
            for x = 1, 11 do
                local edge = (x == 1 or y == 1 or x == 11 or y == 11)
                g[y][x] = (edge or (x == 6 and y ~= 5)) and 1 or 0
            end
        end
        return World.new(g)
    end

    local function player(x, y)
        local e = Entity.new{}
        e.x, e.y, e.angle, e.radius = x, y, 0, 0.24
        e:add(C.Player{ peerId = 0, name = 'p' })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('sees an enemy in range: faces it and fires')

    local w = room()
    local bot = player(2.5, 2.5)
    local prey = player(4.5, 2.5)          -- same side, clear LOS, close
    local b = Bot.new{ seed = 1, fireRange = 9 }

    local intent = b:think(bot, w, { bot, prey }, 1 / 60)
    t.eq(intent.fire, true, 'it opens fire on a visible close target')
    t.near(intent.input.angle, 0, 0.2, 'facing roughly toward the target (+x)')
    t.eq(type(intent.input.strafe), 'number', 'and produces a strafe, not a hold still')

    ---------------------------------------------------------------------
    t.describe('the intent is INPUT — the same a human produces')

    -- No teleport field, no velocity: only forward/strafe/angle plus intents.
    for k in pairs(intent.input) do
        t.ok(k == 'forward' or k == 'strafe' or k == 'angle',
             'input carries only human keys, saw ' .. k)
    end

    ---------------------------------------------------------------------
    t.describe('enemy behind the wall: it paths and moves, does not fire')

    local w2 = room()
    local bot2 = player(3, 3)
    local prey2 = player(9, 3)              -- far side of the x=6 wall
    local b2 = Bot.new{ seed = 2 }
    local i2 = b2:think(bot2, w2, { bot2, prey2 }, 1 / 60)
    t.eq(i2.fire, false, 'no shot through a wall')
    t.ok(b2.path ~= nil, 'a path was computed')
    t.ok(math.abs(i2.input.forward) > 0 or math.abs(i2.input.strafe) > 0,
         'and the bot is trying to move')

    ---------------------------------------------------------------------
    t.describe('a shut door in the path: it asks to open it')

    local wd = room()
    wd:addDoor(6, 5, false)                 -- the gap is now a shut door
    local botd = player(3, 5)
    local preyd = player(9, 5)              -- straight through the doorway
    local bd = Bot.new{ seed = 3 }
    -- Step a few times so it advances to the door tile.
    local askedUse = false
    for _ = 1, 180 do
        local id = bd:think(botd, wd, { botd, preyd }, 1 / 60)
        Rep.applyInput(botd, Rep.sanitiseInput(id.input), 1 / 60, wd,
                       { moveSpeed = 3.2, turnSpeed = 2.6 })
        if id.use and id.useDoor then
            askedUse = true
            t.eq(id.useDoor.tx, 6, 'the door it names is the one in the way')
            wd:setDoorOpen(id.useDoor.tx, id.useDoor.ty, true)
        end
    end
    t.eq(askedUse, true, 'the bot asked to open the door blocking its path')

    ---------------------------------------------------------------------
    t.describe('no target: it wanders, and legally')

    local ww = room()
    local lonely = player(5.5, 5.5)
    local bw = Bot.new{ seed = 4 }
    local moved = false
    for _ = 1, 30 do
        local iw = bw:think(lonely, ww, { lonely }, 1 / 60)
        if math.abs(iw.input.forward) > 0 or math.abs(iw.input.strafe) > 0 then
            moved = true
        end
        Rep.applyInput(lonely, Rep.sanitiseInput(iw.input), 1 / 60, ww,
                       { moveSpeed = 3.2, turnSpeed = 2.6 })
    end
    t.eq(moved, true, 'an idle bot wanders rather than freezing')
    t.ok(not lonely.dead, 'and does not walk itself into a broken state')
    -- It stayed inside the room (collision held it, because it moved by input).
    t.ok(lonely.x > 1 and lonely.x < 11 and lonely.y > 1 and lonely.y < 11,
         'and stayed inside the walls, because input goes through collision')

    ---------------------------------------------------------------------
    t.describe('determinism: same seed, same choices')

    local wa, wb = room(), room()
    local ba = player(5.5, 5.5); local bb = player(5.5, 5.5)
    local ca = Bot.new{ seed = 42 }; local cb = Bot.new{ seed = 42 }
    for _ = 1, 20 do
        local ia = ca:think(ba, wa, { ba }, 1 / 60)
        local ib = cb:think(bb, wb, { bb }, 1 / 60)
        t.near(ia.input.forward, ib.input.forward, 1e-9, nil)
        Rep.applyInput(ba, Rep.sanitiseInput(ia.input), 1/60, wa, { moveSpeed = 3.2 })
        Rep.applyInput(bb, Rep.sanitiseInput(ib.input), 1/60, wb, { moveSpeed = 3.2 })
    end
    t.near(ba.x, bb.x, 1e-9, 'two bots on the same seed walk the same path')
    t.near(ba.y, bb.y, 1e-9, 'to the same place')

    ---------------------------------------------------------------------
    t.describe('the claim: driven through applyInput, it closes on its prey')

    local wc = room()
    local hunter = player(2.5, 8.5)
    local quarry = player(4.5, 8.5)         -- same side, in the open
    local bc = Bot.new{ seed = 7, fireRange = 1 }  -- tiny fire range: forced to approach
    local startD = math.sqrt((hunter.x - quarry.x) ^ 2 + (hunter.y - quarry.y) ^ 2)
    for _ = 1, 90 do
        local ic = bc:think(hunter, wc, { hunter, quarry }, 1 / 60)
        Rep.applyInput(hunter, Rep.sanitiseInput(ic.input), 1 / 60, wc,
                       { moveSpeed = 3.2, turnSpeed = 2.6 })
    end
    local endD = math.sqrt((hunter.x - quarry.x) ^ 2 + (hunter.y - quarry.y) ^ 2)
    t.ok(endD < startD - 0.5, ('the bot got measurably closer (%.2f -> %.2f)')
         :format(startD, endD))
end
