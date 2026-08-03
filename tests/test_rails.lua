--[[
    C20: the scripted camera rail. Waypoints glide over their travel time, dwell
    for their hold, take angles the short way round, and finish (or loop). Pose
    output matches the spectator/photo convention.
]]

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

return function(t)
    local Rails = require('meatray.game.rails')
    local Game = require('meatray.game')

    t.eq(Game.rails, Rails, 'Game.rails is the module')

    ---------------------------------------------------------------------
    t.describe('validation')

    t.ok(Rails.validate{ { x = 0, y = 0 } }, 'one waypoint is a valid rail')
    t.ok(not Rails.validate({}), 'an empty rail is refused')

    ---------------------------------------------------------------------
    t.describe('a two-point rail glides over its travel time')

    local rail = Rails.new({
        { x = 0, y = 0, angle = 0 },
        { x = 10, y = 0, angle = 0, travel = 2.0 },
    })
    rail:play()
    t.ok(rail:isActive(), 'active after play')
    local p0 = rail:pose()
    t.ok(near(p0.x, 0), 'starts at the first waypoint')
    t.eq(p0.mode, 'rail', 'pose is tagged rail')
    t.eq(p0.hudHidden, true, 'and hides the HUD by default')

    rail:update(1.0)                     -- halfway through the 2s travel
    t.ok(near(rail:pose().x, 5), 'linear halfway is halfway along')

    rail:update(1.0)                     -- reach the end
    t.ok(near(rail:pose().x, 10), 'arrives at the second waypoint')
    t.ok(rail:isDone(), 'and the rail is done')
    t.eq(rail:pose().done, true, 'the pose reports done')

    ---------------------------------------------------------------------
    t.describe('overshooting dt does not lose time')

    local fast = Rails.new({
        { x = 0, y = 0 },
        { x = 4, y = 0, travel = 1.0 },
        { x = 4, y = 8, travel = 1.0 },
    })
    fast:play()
    fast:update(1.5)                     -- 1.0 to reach wp2, 0.5 into wp3's travel
    local p = fast:pose()
    t.ok(near(p.x, 4), 'x reached the corner')
    t.ok(near(p.y, 4), 'and carried the leftover 0.5s into the next segment')

    ---------------------------------------------------------------------
    t.describe('a hold dwells before moving on')

    local held = Rails.new({
        { x = 0, y = 0 },
        { x = 10, y = 0, travel = 1.0, hold = 1.0 },
        { x = 10, y = 10, travel = 1.0 },
    })
    held:play()
    held:update(1.0)                     -- finished travel to wp2, hold begins
    t.ok(near(held:pose().x, 10) and near(held:pose().y, 0), 'sitting on wp2')
    held:update(0.5)                     -- still holding
    t.ok(near(held:pose().y, 0), 'still dwelling, not moving yet')
    held:update(0.5)                     -- hold done; now at start of next travel
    held:update(0.5)                     -- half of the 1s travel to wp3
    t.ok(near(held:pose().y, 5), 'moves only after the hold elapses')

    ---------------------------------------------------------------------
    t.describe('angle takes the short way round')

    local turn = Rails.new({
        { x = 0, y = 0, angle = math.rad(350) },
        { x = 0, y = 0, angle = math.rad(10), travel = 1.0 },
    })
    turn:play()
    turn:update(0.5)                     -- halfway: should be at 0deg, not 180
    local a = turn:pose().angle
    -- Halfway between 350 and 10 the short way is 0 (i.e. 360/0).
    t.ok(near(a, 0, 1e-3) or near(a, math.pi * 2, 1e-3),
         ('short-way angle sweeps through 0, got %.3f'):format(a))

    ---------------------------------------------------------------------
    t.describe('smoothstep easing is slower at the ends')

    local smooth = Rails.new({
        { x = 0, y = 0 },
        { x = 10, y = 0, travel = 1.0 },
    }, { ease = 'smooth' })
    smooth:play()
    smooth:update(0.25)
    -- smoothstep(0.25) = 0.15625 -> x = 1.5625, well under the linear 2.5.
    t.ok(smooth:pose().x < 2.0, 'eased motion lags linear early in the segment')
    t.ok(near(smooth:pose().x, 1.5625, 1e-3), 'smoothstep value is exact')

    ---------------------------------------------------------------------
    t.describe('a loop restarts instead of finishing')

    local loop = Rails.new({
        { x = 0, y = 0 },
        { x = 10, y = 0, travel = 1.0 },
    }, { loop = true })
    loop:play()
    loop:update(1.5)                     -- past the end; loops back
    t.ok(not loop:isDone(), 'a looping rail never reports done')
    t.ok(loop:pose().x < 10, 'and has wrapped back toward the start')
end
