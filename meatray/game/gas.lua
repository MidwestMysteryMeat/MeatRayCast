--[[
    meatray.game.gas — smoke, fire and toxic clouds on the tile grid.

        local field = Gas.new{ world = world, name = 'smoke', rate = 2 }

        field:emit(12, 9, 8)                    -- eight units on one tile

        -- inside the fixed tick, on the host:
        field:step(step)
        Gas.damage(field, entities, step, { amount = 6, tags = { 'damage.type.toxic' } })

    A field is one scalar quantity spread over open tiles. That single mechanism
    is smoke, fire and poison, because those differ only in their constants:

        smoke   rate 2,   decay 0.15,  no damage
        fire    rate 0.6, decay 0.4,   damage with 'damage.type.fire'
        toxic   rate 1,   decay 0,     damage with 'damage.type.toxic'

    ---------------------------------------------------------------------------
    THE COST IS PROPORTIONAL TO ACTIVITY. THIS IS THE POINT OF THE FILE.
    ---------------------------------------------------------------------------

    A sibling project shipped a diffusion sim that walked every cell of the world
    every tick. Eighteen thousand cells, all settled, all producing exactly zero
    change, every tick, forever — and because generating terrain woke cells that
    woke more cells, it fed itself. It did not present as a performance problem.
    It presented as a NETWORKING TIMEOUT, because the tick that was supposed to
    service the socket was busy doing nothing to seventeen thousand nine hundred
    cells, and it cost real time to find.

    So:

      * A cell is ACTIVE only if something about it changed last step, or a
        neighbour's did. Everything else sleeps and is not visited.
      * `step` visits the active list and nothing else. There is no loop over the
        grid anywhere in this file. `field:step()` on a settled field returns
        `0, 0` and touches nothing, and a test asserts exactly that.
      * The same disturbance in a 20x20 world and a 40x40 world visits the same
        cells in the same numbers, and a test asserts that too — which is the
        assertion that would have caught the original bug, because it fails the
        moment cost starts depending on world size.

    The activity set terminates because a cell only stays awake if it exchanged
    more than `threshold` this step, and diffusion flattens gradients
    geometrically. It is not a heuristic; there is no configuration in which a
    settled field keeps waking itself.

    ---------------------------------------------------------------------------
    CONSERVATION, WHICH IS THE OTHER WAY THIS GOES WRONG
    ---------------------------------------------------------------------------

    A second sibling project had a room-atmosphere model whose exchange rules
    were subtly wrong. Nothing noticed until colonists silently suffocated. Every
    test was green, because every test asserted that the code did what it did.

    So this field states its conservation law and the suite asserts it:

      * With `decay = 0`, MASS IS CONSERVED EXACTLY. Every exchange is written as
        `-flow` on one cell and `+flow` on the other, in the same expression, so
        the sum is invariant to within floating-point noise. Nothing is culled:
        a cell holding a millionth of a unit keeps it and goes to sleep, because
        deleting it would be a leak, and a leak of a millionth per cell per tick
        is a fog bank that quietly evaporates over ten minutes.

      * With `decay > 0`, mass decays at a stated rate and nowhere else:
        after one step of `dt`, a cell with no open neighbours holds exactly
        `d * (1 - decay * dt)`. Everything discarded — including the sub-
        `minimum` remainders that are culled to keep the sparse map small — is
        added to `field.lost`, so `field:total() + field.lost` equals everything
        ever emitted. A test asserts that ledger, which is the only way to know
        the difference between "decayed" and "leaked".

      * GAS DOES NOT PASS THROUGH WALLS OR CLOSED DOORS. Flow is only ever
        computed between two tiles the world says are not solid, and
        `world:isSolid` is what already answers that for a closed door. A test
        fills one side of a shut door, runs a hundred steps, and asserts the far
        side is still exactly zero — then opens the door and asserts it is not.

    THE ONE THING THAT USED TO BE A CALLER OBLIGATION: when the world changes
    shape — a door opens, a wall is destroyed — the settled cells either side
    have no idea anything happened, because nothing about THEM changed. That is
    still true of the field. What is no longer true is that every game path has
    to remember to call `field:wake(tx, ty)`.

    A field constructed against a World that exposes `watchShape` (the stock
    `meatray.sim.world` does) subscribes once and wakes itself on every door
    toggle, destroy and repair. `wake` remains public for worlds that do not
    emit shape events, for tests that want to drive the contract by hand, and
    for a wholesale `wakeAll` after a level rebuild. Pass `listen = false` to
    opt out of the subscription when the caller wants to own waking itself.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Collide    = require('meatray.sim.collide')
local Attributes = require('meatray.game.attributes')
local Damage     = require('meatray.game.damage')

local Gas = {}

local floor, min, sqrt = math.floor, math.min, math.sqrt
local huge = math.huge

-- Diffusion is explicit, so it is only stable while a cell cannot push out more
-- than it holds: four neighbours at a quarter each. A higher `rate` or a longer
-- step is clamped to this rather than allowed to produce negative densities,
-- which is the classic way a fluid sim starts oscillating and then explodes.
Gas.MAX_ALPHA = 0.25

Gas.DEFAULT_RATE = 1.0
Gas.DEFAULT_THRESHOLD = 1e-6
Gas.DEFAULT_MINIMUM = 1e-4

-- A hard cap on how many cells one step may visit. A field is meant to cost what
-- its activity costs; this exists so a pathological emission pattern degrades
-- into "some gas moves late" rather than "the tick never finishes".
Gas.MAX_ACTIVE = 65536

local DX = { 1, -1, 0, 0 }
local DY = { 0, 0, 1, -1 }

local Field = {}
Field.__index = Field

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

--[[
    opts:
        world       required; anything with width, height and isSolid
        name        for diagnostics and for Gas.damage's default tags
        rate        diffusion coefficient, per second      (default 1)
        decay       fraction of a cell lost per second     (default 0)
        threshold   smallest gradient that produces flow, and the smallest
                    change that keeps a cell awake         (default 1e-6)
        minimum     with decay > 0, the density below which a cell is culled and
                    its remainder booked to `lost`         (default 1e-4)
        capacity    most a single cell may hold            (default unlimited)
        listen      when true (default) and the world has watchShape, the field
                    wakes itself on door/destroy/repair. false keeps the old
                    "caller must wake" contract for tests and custom worlds.
        storey      world layer this field lives on (default 1). Shape events
                    on other storeys are ignored; isSolid queries this layer.
]]
function Gas.new(opts)
    opts = opts or {}

    local world = opts.world
    assert(type(world) == 'table' and world.width and world.height
           and type(world.isSolid) == 'function', 'a gas field needs a world')

    local rate = Attributes.number(opts.rate)
    if rate == nil or rate < 0 then rate = Gas.DEFAULT_RATE end

    local decay = Attributes.number(opts.decay) or 0
    if decay < 0 then decay = 0 end

    local threshold = Attributes.number(opts.threshold)
    if threshold == nil or threshold <= 0 then threshold = Gas.DEFAULT_THRESHOLD end

    local minimum = Attributes.number(opts.minimum)
    if minimum == nil or minimum < 0 then minimum = Gas.DEFAULT_MINIMUM end

    local capacity = Attributes.number(opts.capacity) or huge
    local storey = tonumber(opts.storey) or 1
    if storey < 1 then storey = 1 end

    local field = setmetatable({
        world     = world,
        width     = world.width,
        height    = world.height,
        name      = opts.name or 'gas',
        storey    = storey,

        rate      = rate,
        decay     = decay,
        threshold = threshold,
        minimum   = minimum,
        capacity  = capacity,

        density   = {},      -- [index] = amount; absent means exactly zero
        active    = {},      -- array of indices to visit next step
        isActive  = {},      -- [index] = true, for cheap deduplication

        emitted   = 0,       -- everything ever put in
        lost      = 0,       -- everything decay or culling took out
        steps     = 0,
        visited   = 0,       -- cells the last step looked at
        flows     = 0,       -- exchanges the last step performed
        _unwatch  = nil,     -- unsubscribe from world shape events, if any
    }, Field)

    -- Default on: a field that can listen and does not is the original bug
    -- (settled gas trapped behind a door the player just opened). Tests that
    -- pin the bare wake contract pass listen = false.
    if opts.listen ~= false and type(world.watchShape) == 'function' then
        field._unwatch = world:watchShape(function(_, tx, ty, _kind, eventStorey)
            if (eventStorey or 1) ~= field.storey then return end
            field:wake(tx, ty)
        end)
    end

    return field
end

-- Solidity on this field's storey (gas does not diffuse through floors).
function Field:_solid(tx, ty)
    return self.world:isSolid(tx, ty, self.storey)
end

-- Detach from the world's shape watcher. Safe to call more than once; a field
-- that was never listening is a no-op.
function Field:detach()
    if self._unwatch then
        self._unwatch()
        self._unwatch = nil
    end
    return self
end

function Field:index(tx, ty)
    return (ty - 1) * self.width + tx
end

function Field:tileOf(i)
    local x = (i - 1) % self.width + 1
    local y = floor((i - 1) / self.width) + 1
    return x, y
end

function Field:inBounds(tx, ty)
    return tx >= 1 and ty >= 1 and tx <= self.width and ty <= self.height
end

---------------------------------------------------------------------------
-- Waking
---------------------------------------------------------------------------

local function wakeIndex(self, i)
    if self.isActive[i] then return false end
    if #self.active >= Gas.MAX_ACTIVE then return false end
    self.isActive[i] = true
    self.active[#self.active + 1] = i
    return true
end

-- Wakes a tile and its four neighbours. Both halves matter: the tile because its
-- own density changed, and the neighbours because a SETTLED neighbour holding
-- more gas is the one that has to push into it, and it has no other way to find
-- out that it should.
function Field:wake(tx, ty)
    if not self:inBounds(tx, ty) then return 0 end

    local woken = wakeIndex(self, self:index(tx, ty)) and 1 or 0
    for k = 1, 4 do
        local nx, ny = tx + DX[k], ty + DY[k]
        if self:inBounds(nx, ny) then
            if wakeIndex(self, self:index(nx, ny)) then woken = woken + 1 end
        end
    end
    return woken
end

-- Wakes everything holding gas. For a caller that changed the world wholesale —
-- a level rebuild, a save being loaded — and does not want to name every tile.
-- This is the one operation whose cost is proportional to occupancy rather than
-- to activity, and it is not called from inside the tick.
function Field:wakeAll()
    local keys = {}
    for i in pairs(self.density) do keys[#keys + 1] = i end
    table.sort(keys)
    for k = 1, #keys do
        local tx, ty = self:tileOf(keys[k])
        self:wake(tx, ty)
    end
    return #self.active
end

function Field:activeCount() return #self.active end

---------------------------------------------------------------------------
-- Reading and writing
---------------------------------------------------------------------------

function Field:densityAt(tx, ty)
    if not self:inBounds(tx, ty) then return 0 end
    return self.density[self:index(tx, ty)] or 0
end

-- Same question in world coordinates, which is what an entity has.
function Field:densityAtPoint(x, y)
    local px, py = Attributes.number(x), Attributes.number(y)
    if px == nil or py == nil then return 0 end
    return self:densityAt(floor(px) + 1, floor(py) + 1)
end

--[[
    Adds gas to a tile. Returns how much was ACTUALLY added, plus a reason when
    that is less than was asked for:

        'out of bounds'   'solid'   'unusable amount'   'full'

    Returning the difference rather than swallowing it is what lets a caller know
    a smoke grenade landed in a wall.
]]
function Field:emit(tx, ty, amount)
    if not self:inBounds(tx, ty) then return 0, 'out of bounds' end

    local a = Attributes.number(amount)
    if a == nil then return 0, 'unusable amount' end
    if a == 0 then return 0 end

    -- Gas is never created inside a wall or a shut door. It could not get out,
    -- and it would make `total()` disagree with what is visible in the level.
    if self:_solid(tx, ty) then return 0, 'solid' end

    local i = self:index(tx, ty)
    local before = self.density[i] or 0
    local after = before + a
    if after < 0 then after = 0 end

    local capped = false
    if after > self.capacity then after = self.capacity; capped = true end

    self.density[i] = (after > 0) and after or nil
    local moved = after - before
    self.emitted = self.emitted + moved

    self:wake(tx, ty)

    return moved, capped and 'full' or nil
end

-- Sets a tile's density outright. Bookkeeping still balances: the difference
-- goes to `emitted` (a gain) or `lost` (a loss), so the ledger holds.
function Field:set(tx, ty, value)
    if not self:inBounds(tx, ty) then return 0, 'out of bounds' end

    local v = Attributes.number(value)
    if v == nil then return 0, 'unusable amount' end
    if v < 0 then v = 0 end
    if v > self.capacity then v = self.capacity end
    if v > 0 and self:_solid(tx, ty) then return 0, 'solid' end

    local i = self:index(tx, ty)
    local before = self.density[i] or 0
    self.density[i] = (v > 0) and v or nil

    local moved = v - before
    if moved >= 0 then self.emitted = self.emitted + moved
    else self.lost = self.lost - moved end

    self:wake(tx, ty)
    return moved
end

--[[
    Spreads `amount` over the open tiles within `radius` of a world point,
    weighted by a linear falloff and normalised so the total injected is the
    amount asked for (minus whatever fell on walls or behind them).

    Line of sight is respected: a smoke charge on one side of a wall does not
    seed the room on the other side. Returns the total actually injected.
]]
function Field:emitCircle(x, y, radius, amount)
    local cx, cy = Attributes.number(x), Attributes.number(y)
    local r = Attributes.number(radius)
    local a = Attributes.number(amount)
    if cx == nil or cy == nil or r == nil or a == nil then return 0 end
    if r <= 0 or a <= 0 then return 0 end

    local minTx, maxTx = floor(cx - r) + 1, floor(cx + r) + 1
    local minTy, maxTy = floor(cy - r) + 1, floor(cy + r) + 1

    -- Two passes: weights, then the normalised injection. One pass would have to
    -- guess the divisor, and guessing it is how a smoke grenade in a corridor
    -- produces a tenth of the smoke it does in a room.
    local weights, total = {}, 0
    for ty = minTy, maxTy do
        for tx = minTx, maxTx do
            if self:inBounds(tx, ty) and not self:_solid(tx, ty) then
                local dx, dy = (tx - 0.5) - cx, (ty - 0.5) - cy
                local dist = sqrt(dx * dx + dy * dy)
                if dist <= r and Collide.lineOfSight(self.world, cx, cy, tx - 0.5, ty - 0.5, self.storey) then
                    local w = 1 - dist / r
                    if w > 0 then
                        weights[#weights + 1] = { tx = tx, ty = ty, w = w }
                        total = total + w
                    end
                end
            end
        end
    end

    if total <= 0 then return 0 end

    local injected = 0
    for i = 1, #weights do
        local cell = weights[i]
        injected = injected + (self:emit(cell.tx, cell.ty, a * cell.w / total))
    end

    return injected
end

-- Everything the field currently holds. Summed in index order so two runs of the
-- same simulation produce the same total to the last bit.
function Field:total()
    local keys = {}
    for i in pairs(self.density) do keys[#keys + 1] = i end
    table.sort(keys)

    local sum = 0
    for k = 1, #keys do sum = sum + self.density[keys[k]] end
    return sum
end

function Field:occupiedCount()
    local n = 0
    for _ in pairs(self.density) do n = n + 1 end
    return n
end

function Field:clear()
    self.lost = self.lost + self:total()
    self.density = {}
    self.active = {}
    self.isActive = {}
    return self
end

-- Every occupied cell, in index order: fn(tx, ty, density). For a renderer that
-- wants to draw the cloud, or a test that wants to see it.
function Field:each(fn)
    local keys = {}
    for i in pairs(self.density) do keys[#keys + 1] = i end
    table.sort(keys)

    for k = 1, #keys do
        local i = keys[k]
        local tx, ty = self:tileOf(i)
        fn(tx, ty, self.density[i])
    end
    return #keys
end

---------------------------------------------------------------------------
-- The step
---------------------------------------------------------------------------

--[[
    One fixed simulation step. Returns `visited, flows`: how many cells were
    looked at and how many exchanges happened, which is the field's whole cost
    and is what the tests assert on.

    `dt` is the simulation step. Nothing here reads a clock.
]]
function Field:step(dt)
    self.visited, self.flows = 0, 0

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return 0, 0 end

    self.steps = self.steps + 1

    local active = self.active
    local n = #active
    if n == 0 then return 0, 0 end

    -- Sorted so the accumulation order — and therefore the floating-point
    -- result — is the same on every machine, whatever order the wakes arrived in.
    table.sort(active)

    local alpha = self.rate * step
    if alpha > Gas.MAX_ALPHA then alpha = Gas.MAX_ALPHA end
    if alpha < 0 then alpha = 0 end

    local decayFactor = self.decay * step
    if decayFactor > 1 then decayFactor = 1 end

    local density   = self.density
    local world     = self.world
    local width     = self.width
    local height    = self.height
    local threshold = self.threshold

    local delta, touched = {}, {}

    local function touch(i)
        if delta[i] == nil then
            delta[i] = 0
            touched[#touched + 1] = i
        end
    end

    local visited, flows = 0, 0

    for k = 1, n do
        local i = active[k]
        visited = visited + 1

        local d = density[i]
        if d and d > 0 then
            local tx = (i - 1) % width + 1
            local ty = floor((i - 1) / width) + 1

            if decayFactor > 0 then
                touch(i)
                delta[i] = delta[i] - d * decayFactor
            end

            -- A cell the world has since made solid — a door shut over a cloud —
            -- keeps what it holds and exchanges nothing, in either direction.
            if not self:_solid(tx, ty) then
                for s = 1, 4 do
                    local nx, ny = tx + DX[s], ty + DY[s]
                    if nx >= 1 and ny >= 1 and nx <= width and ny <= height
                       and not self:_solid(nx, ny) then
                        local j = (ny - 1) * width + nx
                        local diff = d - (density[j] or 0)
                        if diff > threshold then
                            -- The one place mass moves, written as a single
                            -- pair. There is no path by which the two halves can
                            -- disagree, which is what makes conservation a
                            -- property of the code rather than of the tests.
                            local flow = diff * alpha
                            touch(i)
                            touch(j)
                            delta[i] = delta[i] - flow
                            delta[j] = delta[j] + flow
                            flows = flows + 1
                        end
                    end
                end
            end
        end
    end

    table.sort(touched)

    local nextActive, nextIs = {}, {}
    local function wake(i)
        if not nextIs[i] and #nextActive < Gas.MAX_ACTIVE then
            nextIs[i] = true
            nextActive[#nextActive + 1] = i
        end
    end

    -- The ledger is MEASURED, not derived. Every flow appears as a matching
    -- -f and +f on two cells that are both in `touched`, so summing what the
    -- touched cells held before and after cancels the flows exactly and leaves
    -- precisely what decay, culling and clamping removed. Deriving it instead —
    -- "lost = sum of d * decayFactor" — is right until a cell clamps at zero,
    -- and then the books are wrong in a way nothing notices.
    local removed = 0

    for k = 1, #touched do
        local i = touched[k]
        local change = delta[i]
        local before = density[i] or 0

        local nd = before + change
        if nd < 0 then nd = 0 end

        -- Culling only ever happens in a field that has declared it decays. In a
        -- conserving field nothing is culled at all: a cell holding a millionth
        -- of a unit keeps it and sleeps, because deleting it would be a leak.
        if self.decay > 0 and nd > 0 and nd < self.minimum then
            nd = 0
        end

        density[i] = (nd > 0) and nd or nil
        removed = removed + (before - nd)

        if change > threshold or change < -threshold then
            wake(i)
            local tx = (i - 1) % width + 1
            local ty = floor((i - 1) / width) + 1
            for s = 1, 4 do
                local nx, ny = tx + DX[s], ty + DY[s]
                if nx >= 1 and ny >= 1 and nx <= width and ny <= height then
                    wake((ny - 1) * width + nx)
                end
            end
        end
    end

    self.lost = self.lost + removed

    self.active, self.isActive = nextActive, nextIs
    self.visited, self.flows = visited, flows

    return visited, flows
end

---------------------------------------------------------------------------
-- Damage
---------------------------------------------------------------------------

--[[
    Applies a gas field to whoever is standing in it, once per simulation step.

        Gas.damage(fire, entities, step, {
            amount = 20,                       -- per second, at density 1
            tags = { 'damage.type.fire' },
            minDensity = 0.05,
            effects = { 'burning' },
        })

    The damage goes through `meatray.game.damage`, so it is an effect: a fire
    resistance reduces it, armour soaks it, an immunity refuses it, and none of
    that is written here. Returns an array of what it did, and the number of
    entities affected.
]]
function Gas.damage(field, entities, dt, opts)
    opts = opts or {}

    if type(field) ~= 'table' or type(field.densityAtPoint) ~= 'function' then
        return {}, 0
    end
    if type(entities) ~= 'table' then return {}, 0 end

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return {}, 0 end

    local amount = Attributes.number(opts.amount)
    if amount == nil or amount <= 0 then return {}, 0 end

    local minDensity = Attributes.number(opts.minDensity) or 0
    local cap = Attributes.number(opts.maxDensity) or huge

    local out, n = {}, 0

    for i = 1, #entities do
        local e = entities[i]
        if type(e) == 'table' and not e.dead and e ~= opts.ignore then
            local d = field:densityAtPoint(e.x, e.y)
            if d > 0 and d >= minDensity then
                local scaled = min(d, cap)
                local hurt = amount * scaled * step
                local applied, err, refused = Damage.applyWith(e, hurt, opts.effects, {
                    tags = opts.tags, source = opts.source, id = opts.id or field.name,
                })
                n = n + 1
                out[n] = { entity = e, density = d, damage = hurt,
                           result = applied, reason = (not applied) and err or nil,
                           refused = refused }
            end
        end
    end

    return out, n
end

---------------------------------------------------------------------------
-- Several fields at once
---------------------------------------------------------------------------

function Gas.stepAll(fields, dt)
    local visited, flows = 0, 0
    for i = 1, #(fields or {}) do
        local v, f = fields[i]:step(dt)
        visited, flows = visited + v, flows + f
    end
    return visited, flows
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

-- Only occupied cells travel, as a flat { index, amount, index, amount, ... }
-- array — which the serialiser writes in its compact array form, and which is a
-- fraction of the size of a table of per-cell records.
function Field:snapshot()
    local keys = {}
    for i in pairs(self.density) do keys[#keys + 1] = i end
    table.sort(keys)

    local cells = {}
    for k = 1, #keys do
        cells[#cells + 1] = keys[k]
        cells[#cells + 1] = self.density[keys[k]]
    end

    return { name = self.name, width = self.width, cells = cells,
             emitted = self.emitted, lost = self.lost }
end

function Field:applySnapshot(snap)
    if type(snap) ~= 'table' then return false, 'a gas snapshot must be a table' end

    local cells = snap.cells
    if type(cells) ~= 'table' then return false, 'this gas snapshot has no cells' end

    -- A snapshot written against a differently-sized world would put every cell
    -- in the wrong place. Refusing is the only honest answer.
    if snap.width and snap.width ~= self.width then
        return false, ('this gas snapshot is %s tiles wide, this world is %d')
                      :format(tostring(snap.width), self.width)
    end

    self.density = {}
    self.active = {}
    self.isActive = {}

    for k = 1, #cells - 1, 2 do
        local i = Attributes.number(cells[k])
        local v = Attributes.number(cells[k + 1])
        if i and v and v > 0 and i >= 1 and i <= self.width * self.height then
            self.density[floor(i)] = v
        end
    end

    self.emitted = Attributes.number(snap.emitted) or self:total()
    self.lost = Attributes.number(snap.lost) or 0

    self:wakeAll()
    return true
end

Gas.Field = Field

return Gas
