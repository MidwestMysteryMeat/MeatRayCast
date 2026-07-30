--[[
    meatray.game.inventory — slots, stacks, pickups and equipping.

        Inventory.defineItem('ammo.9mm', { stack = 60, ammoFor = 'pistol' })
        Inventory.defineItem('pistol',   { stack = 1,  weapon = 'pistol' })

        Inventory.attach(player, { capacity = 8 })
        Inventory.add(player, 'pistol', 1)
        Inventory.add(player, 'ammo.9mm', 90)
        Inventory.equip(player, 1)              -- drives the `weapon` component

    ---------------------------------------------------------------------------
    NOTHING VANISHES. THIS IS THE WHOLE DESIGN.
    ---------------------------------------------------------------------------

    "The game ate my item" is a bug report players file, remember, and repeat, and
    it is almost never a corrupted save — it is a pickup that did not fit and was
    deleted anyway, or a stack that overflowed past its cap and lost the
    remainder. So every operation in this module obeys one invariant, and the
    tests assert it directly:

        added + leftover == asked for,  always, for every path in.

      * `add` fills partial stacks of the same item first (lowest slot first),
        then empty slots, each capped at the item's stack size. What does not fit
        is RETURNED as `leftover`. It is never silently dropped, and `add` never
        creates a stack larger than the cap.

      * `pickup` takes what fits and DECREMENTS THE WORLD ENTITY by exactly that
        much. A pickup that half-fits leaves the remainder lying on the floor for
        you to come back to. It is removed from the world only when its count
        reaches zero.

      * `drop` removes from the inventory and spawns a world entity holding
        precisely what was removed, so the round trip is lossless.

      * A pickup that fits nowhere at all is refused with the reason 'full' and
        the world entity is untouched.

    ---------------------------------------------------------------------------
    THE CONTENTS STRING, AND WHY SLOTS ARE A CACHE
    ---------------------------------------------------------------------------

    The `inventory` component's replicated state is ONE STRING:

        "1=pistol*1|3=ammo.9mm*60|4=ammo.9mm*30"

    A string rather than a table of slots, for the reason `meatray.game.effects`
    gives for the tag string: a table in a netFields declaration is shared by
    reference into the snapshot, so a listen server would have its host and its
    local client mutating the same slots. A string cannot be aliased.

    That choice pays for itself twice. Because the string is the authoritative
    state, an inventory survives a save with NOTHING added to meatray.save.state
    — it is a netField, and the save layer captures netFields. And because the
    slot array is only ever a decode of the string, applying a snapshot (from the
    network, or from a save) automatically invalidates it: every accessor
    compares the string it decoded last against the string in the component, and
    re-decodes when they differ. There is no cache-invalidation call to forget,
    because the cache's version tag IS the data.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity     = require('meatray.sim.entity')
local Collide    = require('meatray.sim.collide')
local Attributes = require('meatray.game.attributes')
local Weapons    = require('meatray.game.weapons')

local Inventory = {}

local floor, min, max = math.floor, math.min, math.max
local concat = table.concat

Inventory.DEFAULT_CAPACITY = 10
Inventory.MAX_CAPACITY = 256
Inventory.MAX_STACK = 1e6

-- The replicated inventory: capacity, the equipped slot, and the contents
-- string. All three are things a client legitimately needs — it draws the bag.
Inventory.Component = Entity.component('inventory', { 'contents', 'capacity', 'equipped' })

-- A world pickup. `item` and `count` replicate so a client can label the thing on
-- the floor without asking.
Inventory.PickupComponent = Entity.component('pickup', { 'item', 'count' })

---------------------------------------------------------------------------
-- Item definitions
---------------------------------------------------------------------------

local items = {}

-- Item ids share the tag alphabet — dotted words — because they end up inside a
-- delimited string and because a game will inevitably want `ammo.9mm` to sort
-- next to `ammo.12g`. The delimiters this module uses (| = *) are therefore
-- impossible in an id by construction rather than by escaping, and there is no
-- escaping bug to have.
function Inventory.checkId(id)
    if type(id) ~= 'string' or id == '' then
        return nil, ('an item id must be a non-empty string, got %s'):format(type(id))
    end
    if #id > 64 then
        return nil, ('item id %q is too long'):format(id:sub(1, 32))
    end
    if id:find('[|=*]') then
        return nil, ('item id %q may not contain | = or *'):format(id)
    end
    if not id:match('^[%w_][%w_%.%-]*$') then
        return nil, ('%q is not a usable item id (word characters, dots and dashes)'):format(id)
    end
    return id
end

--[[
    Declares an item.

        stack     how many fit in one slot          (default 1)
        weapon    weapon id this equips             (optional)
        ammoFor   weapon id a reload consumes this for (optional)
        name      display name                      (optional)
        kind      pickup entity kind to spawn on drop (default 'pickup')
        tags      free-form, never interpreted here
]]
function Inventory.compileItem(spec, id)
    if type(spec) ~= 'table' then
        return nil, ('an item spec must be a table, got %s'):format(type(spec))
    end

    local stack = spec.stack
    if stack == nil then stack = 1 end
    stack = Attributes.number(stack)
    if stack == nil or stack < 1 or stack > Inventory.MAX_STACK then
        return nil, ('%s: stack must be between 1 and %d, got %s')
                    :format(tostring(id), Inventory.MAX_STACK, tostring(spec.stack))
    end

    return {
        id      = id,
        stack   = floor(stack),
        weapon  = spec.weapon,
        ammoFor = spec.ammoFor,
        name    = spec.name or id,
        kind    = spec.kind or 'pickup',
        tags    = spec.tags,
        onPickup = spec.onPickup,
        onDrop   = spec.onDrop,

        -- What a UI should draw for this item. Deliberately NOT interpreted
        -- here: this module has no idea what a sprite is, and giving it one
        -- would drag the renderer into a file that a dedicated server loads.
        -- It is carried, handed back, and that is all.
        --
        -- Distinct from `kind`, which names the *pickup entity* spawned when the
        -- item is dropped into the world, and from `tags`, which is explicitly
        -- uninterpreted game data. Without a field of its own, an inventory grid
        -- has nothing to draw but text -- which is what the panel does today and
        -- is the single thing stopping it being a shippable bag UI.
        icon    = spec.icon,

        -- Called when a game decides the item is used. The engine never calls
        -- it: what "use" means is a rule, and rules belong to the game, exactly
        -- as onPickup and onDrop already work. It exists so a consumable has
        -- somewhere to put its effect instead of every game inventing a parallel
        -- table keyed by item id.
        onUse   = spec.onUse,
    }
end

function Inventory.defineItem(id, spec)
    local ok, err = Inventory.checkId(id)
    assert(ok, err)
    local def, compileErr = Inventory.compileItem(spec or {}, id)
    assert(def, compileErr)
    items[id] = def
    return def
end

function Inventory.item(id) return items[id] end

function Inventory.itemIds()
    local out = {}
    for id in pairs(items) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Inventory.resetItems() items = {} return Inventory end

function Inventory.captureItems()
    local out = {}
    for id, def in pairs(items) do out[id] = def end
    return out
end

function Inventory.restoreItems(captured)
    items = {}
    for id, def in pairs(captured or {}) do items[id] = def end
end

-- An item this build does not define is still carried: it stacks alone and does
-- nothing. Refusing it would mean a save written by a build with one more item
-- in it loses that item on load, which is exactly the "ate my stuff" failure
-- this module exists to avoid.
local function itemDef(id)
    return items[id] or { id = id, stack = 1, name = id, kind = 'pickup', unknown = true }
end

Inventory.itemDef = itemDef

---------------------------------------------------------------------------
-- The contents string
---------------------------------------------------------------------------

-- "1=pistol*1|3=ammo.9mm*60"
function Inventory.encode(slots, capacity)
    local parts = {}
    for i = 1, capacity do
        local s = slots[i]
        if s and s.id and (s.count or 0) > 0 then
            parts[#parts + 1] = ('%d=%s*%d'):format(i, s.id, floor(s.count))
        end
    end
    return concat(parts, '|')
end

-- Decodes into a slot array. Malformed entries are skipped rather than raising:
-- this string can arrive from a network snapshot or a save file written by
-- another build, and one unreadable entry must not cost the other nine.
function Inventory.decode(str, capacity)
    local slots = {}
    if type(str) ~= 'string' or str == '' then return slots end

    for entry in str:gmatch('[^|]+') do
        local index, id, count = entry:match('^(%d+)=([^*]+)%*(%d+)$')
        index, count = tonumber(index), tonumber(count)
        if index and id and count and count > 0
           and index >= 1 and index <= (capacity or Inventory.MAX_CAPACITY)
           and Inventory.checkId(id) then
            slots[index] = { id = id, count = floor(count) }
        end
    end

    return slots
end

-- Writes the slot array back into the component and records what was written, so
-- the next read knows the cache is current.
local function sync(inv)
    inv.contents = Inventory.encode(inv.slots, inv.capacity)
    inv.encoded = inv.contents
    return inv
end

-- The slot array, decoded from `contents` if something else wrote it (a
-- snapshot, a save, an editor). See the header: the string is the version tag.
local function slotsOf(inv)
    if inv.slots == nil or inv.encoded ~= inv.contents then
        inv.slots = Inventory.decode(inv.contents, inv.capacity)
        inv.encoded = inv.contents
    end
    return inv.slots
end

---------------------------------------------------------------------------
-- Attachment
---------------------------------------------------------------------------

function Inventory.attach(e, opts)
    opts = opts or {}
    assert(type(e) == 'table' and type(e.components) == 'table', 'attach needs an entity')

    local inv = e.components.inventory
    if not inv then
        inv = Inventory.Component{}
        e:add(inv)
    end

    local capacity = Attributes.number(opts.capacity or opts.slots or inv.capacity)
                     or Inventory.DEFAULT_CAPACITY
    capacity = max(1, min(Inventory.MAX_CAPACITY, floor(capacity)))

    inv.contents = inv.contents or ''

    -- Shrinking used to destroy whatever sat above the new capacity, silently.
    -- Re-decoding the contents string against a smaller size makes the decoder
    -- drop the out-of-range entries, nothing is logged, and the module's own
    -- "nothing vanishes" rule is broken by the one call that resizes the bag.
    --
    -- So a shrink is honoured only as far as it is free. The occupied high-water
    -- mark is read against the CURRENT capacity, before anything changes, and
    -- the new capacity is never set below it. Asking for less than that is not
    -- refused outright -- a caller trimming a bag that happens to be full should
    -- not fail -- but it does not get the size it asked for, and the second
    -- return value says so rather than leaving it to be discovered.
    local highest = 0
    local existing = slotsOf(inv)
    for i = #existing, 1, -1 do
        local slot = existing[i]
        if slot and slot.id then highest = i; break end
    end

    local kept = nil
    if capacity < highest then
        kept = highest - capacity
        capacity = highest
    end

    inv.capacity = capacity
    inv.slots = nil
    inv.encoded = nil
    slotsOf(inv)
    sync(inv)

    return inv, kept
end

function Inventory.of(e)
    return e and e.components and e.components.inventory or nil
end

function Inventory.has(e)
    return Inventory.of(e) ~= nil
end

function Inventory.capacity(e)
    local inv = Inventory.of(e)
    return inv and inv.capacity or 0
end

-- The live slot array. Mutating it directly is possible and unsupported: call
-- `Inventory.sync(e)` afterwards or the change will be discarded the next time
-- the contents string is re-read.
function Inventory.slots(e)
    local inv = Inventory.of(e)
    if not inv then return {} end
    return slotsOf(inv)
end

function Inventory.sync(e)
    local inv = Inventory.of(e)
    if not inv then return nil end
    return sync(inv)
end

function Inventory.get(e, index)
    local slots = Inventory.slots(e)
    local s = slots[index]
    if not s then return nil end
    return { id = s.id, count = s.count }
end

function Inventory.count(e, id)
    local slots = Inventory.slots(e)
    local inv = Inventory.of(e)
    if not inv then return 0 end
    local total = 0
    for i = 1, inv.capacity do
        local s = slots[i]
        if s and s.id == id then total = total + s.count end
    end
    return total
end

function Inventory.used(e)
    local slots = Inventory.slots(e)
    local inv = Inventory.of(e)
    if not inv then return 0 end
    local n = 0
    for i = 1, inv.capacity do
        if slots[i] then n = n + 1 end
    end
    return n
end

function Inventory.freeSlots(e)
    local inv = Inventory.of(e)
    if not inv then return 0 end
    return inv.capacity - Inventory.used(e)
end

function Inventory.isFull(e)
    return Inventory.freeSlots(e) <= 0
end

-- How many more of `id` would fit right now, counting room in existing stacks
-- and in empty slots. This is what a caller asks before it commits to a trade.
function Inventory.room(e, id)
    local inv = Inventory.of(e)
    if not inv then return 0 end
    local slots = slotsOf(inv)
    local def = itemDef(id)

    local room = 0
    for i = 1, inv.capacity do
        local s = slots[i]
        if s == nil then
            room = room + def.stack
        elseif s.id == id then
            room = room + max(0, def.stack - s.count)
        end
    end
    return room
end

---------------------------------------------------------------------------
-- Adding and removing
---------------------------------------------------------------------------

--[[
    Puts items in. Returns `added, leftover, reason`.

    `added + leftover` always equals the count asked for. `reason` is 'full' when
    leftover > 0 and there was nowhere left to put it, and nil otherwise.
]]
function Inventory.add(e, id, count, opts)
    opts = opts or {}

    local inv = Inventory.of(e)
    if not inv then return 0, 0, 'no inventory' end

    local ok = Inventory.checkId(id)
    if not ok then return 0, 0, 'unusable item id' end

    local n = Attributes.number(count == nil and 1 or count)
    if n == nil or n < 0 then return 0, 0, 'unusable count' end
    n = floor(n)
    if n == 0 then return 0, 0 end

    local slots = slotsOf(inv)
    local def = itemDef(id)
    local remaining = n

    -- Existing stacks first, lowest slot first. Deterministic, and it is what a
    -- player expects: topping up before opening a new stack.
    for i = 1, inv.capacity do
        if remaining <= 0 then break end
        local s = slots[i]
        if s and s.id == id and s.count < def.stack then
            local take = min(def.stack - s.count, remaining)
            s.count = s.count + take
            remaining = remaining - take
        end
    end

    -- Then empty slots.
    if not opts.existingOnly then
        for i = 1, inv.capacity do
            if remaining <= 0 then break end
            if slots[i] == nil then
                local take = min(def.stack, remaining)
                slots[i] = { id = id, count = take }
                remaining = remaining - take
            end
        end
    end

    sync(inv)

    local added = n - remaining
    if def.onPickup and added > 0 then def.onPickup(e, def, added) end

    return added, remaining, (remaining > 0) and 'full' or nil
end

-- Takes items out, lowest slot first. Returns how many were actually removed,
-- which is `min(count, what you had)` — never more, and never a negative stack.
function Inventory.remove(e, id, count)
    local inv = Inventory.of(e)
    if not inv then return 0 end

    local n = Attributes.number(count == nil and 1 or count)
    if n == nil or n <= 0 then return 0 end
    n = floor(n)

    local slots = slotsOf(inv)
    local removed = 0

    for i = 1, inv.capacity do
        if removed >= n then break end
        local s = slots[i]
        if s and s.id == id then
            local take = min(s.count, n - removed)
            s.count = s.count - take
            removed = removed + take
            if s.count <= 0 then
                slots[i] = nil
                if inv.equipped == i then Inventory.unequip(e) end
            end
        end
    end

    if removed > 0 then sync(inv) end
    return removed
end

-- Takes from one slot only. Returns the item id and how many came out.
function Inventory.removeSlot(e, index, count)
    local inv = Inventory.of(e)
    if not inv then return nil, 0 end

    local slots = slotsOf(inv)
    local s = slots[index]
    if not s then return nil, 0 end

    local n = Attributes.number(count == nil and s.count or count)
    if n == nil or n <= 0 then return nil, 0 end
    n = min(floor(n), s.count)

    local id = s.id
    s.count = s.count - n
    if s.count <= 0 then
        slots[index] = nil
        if inv.equipped == index then Inventory.unequip(e) end
    end

    sync(inv)
    return id, n
end

function Inventory.clear(e)
    local inv = Inventory.of(e)
    if not inv then return false end
    inv.slots = {}
    inv.equipped = nil
    sync(inv)
    return true
end

--[[
    Moves items between slots. Same item: merges up to the stack cap and leaves
    the remainder where it was — never over-stacks, never destroys the overflow.
    Different items: swaps.

    Returns true, or false plus a reason.
]]
function Inventory.move(e, from, to, count)
    local inv = Inventory.of(e)
    if not inv then return false, 'no inventory' end
    if from == to then return false, 'same slot' end

    local slots = slotsOf(inv)
    if type(from) ~= 'number' or from < 1 or from > inv.capacity then
        return false, 'slot out of range'
    end
    if type(to) ~= 'number' or to < 1 or to > inv.capacity then
        return false, 'slot out of range'
    end

    local src = slots[from]
    if not src then return false, 'empty slot' end

    local dst = slots[to]

    local n = Attributes.number(count == nil and src.count or count)
    if n == nil or n <= 0 then return false, 'unusable count' end
    n = min(floor(n), src.count)

    if dst == nil then
        if n == src.count then
            slots[to], slots[from] = src, nil
            if inv.equipped == from then inv.equipped = to end
        else
            slots[to] = { id = src.id, count = n }
            src.count = src.count - n
        end
        sync(inv)
        return true
    end

    if dst.id == src.id then
        local def = itemDef(src.id)
        local take = min(def.stack - dst.count, n)
        if take <= 0 then return false, 'destination stack is full' end
        dst.count = dst.count + take
        src.count = src.count - take
        if src.count <= 0 then
            slots[from] = nil
            if inv.equipped == from then inv.equipped = to end
        end
        sync(inv)
        return true
    end

    -- Different items: a swap, and only ever a whole-slot one. A partial swap
    -- has no meaning and the obvious implementation loses the destination.
    if n ~= src.count then return false, 'a partial move onto another item' end
    slots[from], slots[to] = dst, src
    if inv.equipped == from then inv.equipped = to
    elseif inv.equipped == to then inv.equipped = from end
    sync(inv)
    return true
end

function Inventory.swap(e, a, b)
    local inv = Inventory.of(e)
    if not inv then return false, 'no inventory' end
    local slots = slotsOf(inv)
    if type(a) ~= 'number' or a < 1 or a > inv.capacity then return false, 'slot out of range' end
    if type(b) ~= 'number' or b < 1 or b > inv.capacity then return false, 'slot out of range' end
    slots[a], slots[b] = slots[b], slots[a]
    if inv.equipped == a then inv.equipped = b
    elseif inv.equipped == b then inv.equipped = a end
    sync(inv)
    return true
end

---------------------------------------------------------------------------
-- World pickups
---------------------------------------------------------------------------

-- Builds a world entity holding an item stack. Does not add it to any list; the
-- caller owns its entity array.
function Inventory.spawnPickup(id, count, x, y, ctx)
    ctx = ctx or {}

    local ok, err = Inventory.checkId(id)
    if not ok then return nil, err end

    local n = Attributes.number(count)
    if n == nil or n <= 0 then
        return nil, ('a pickup needs a positive count, got %s'):format(tostring(count))
    end
    n = floor(n)

    local px, py = Attributes.number(x), Attributes.number(y)
    if px == nil or py == nil then
        return nil, ('pickup position is unusable (%s, %s)'):format(tostring(x), tostring(y))
    end

    local def = itemDef(id)
    local kind = ctx.kind or def.kind or 'pickup'

    local pickup
    if type(ctx.spawn) == 'function' then
        pickup = ctx.spawn(kind, px, py, { item = id, count = n })
    end
    if not pickup then
        if Entity.hasArchetype(kind) then
            pickup = Entity.spawn(kind, px, py)
        else
            pickup = Entity.new{ kind = kind, x = px, y = py }
        end
    end

    pickup.x, pickup.y = px, py
    pickup:snapPrevious()

    local comp = pickup.components.pickup
    if not comp then
        comp = Inventory.PickupComponent{}
        pickup:add(comp)
    end
    comp.item = id
    comp.count = n

    return pickup
end

function Inventory.isPickup(e)
    return type(e) == 'table' and type(e.components) == 'table'
           and e.components.pickup ~= nil
end

--[[
    Drops a slot into the world. Returns the pickup entity, or nil plus a reason.

    `ctx.emit(entity)` places it, or `ctx.entities` is appended to. With neither,
    the entity comes back and placing it is the caller's job — the same contract
    projectiles use, and for the same reason: this module does not own the world.
]]
function Inventory.drop(e, index, count, ctx)
    ctx = ctx or {}

    local inv = Inventory.of(e)
    if not inv then return nil, 'no inventory' end

    local slots = slotsOf(inv)
    local slot = slots[index]
    if not slot then return nil, 'empty slot' end

    -- The landing site is validated BEFORE anything leaves the bag. Falling back
    -- to the dropper's position when an explicit one was given and turned out to
    -- be a NaN would hide the caller's bug and put the loot somewhere nobody
    -- asked for; refusing costs a click.
    local x, y = e.x or 0, e.y or 0
    if ctx.x ~= nil then
        x = Attributes.number(ctx.x)
        if x == nil then
            return nil, ('drop position is unusable (%s)'):format(tostring(ctx.x))
        end
    end
    if ctx.y ~= nil then
        y = Attributes.number(ctx.y)
        if y == nil then
            return nil, ('drop position is unusable (%s)'):format(tostring(ctx.y))
        end
    end

    local wantId = slot.id
    local id, taken = Inventory.removeSlot(e, index, count)
    if not id or taken <= 0 then return nil, 'nothing to drop' end

    local pickup, err = Inventory.spawnPickup(id, taken, x, y, ctx)
    if not pickup then
        -- A backstop, and deliberately not removed for being hard to reach:
        -- a drop that failed to build its entity AFTER taking the items out of
        -- the bag is precisely the "the game ate my item" bug, and the two lines
        -- that make it impossible are cheaper than the bug report.
        Inventory.add(e, wantId, taken)
        return nil, err
    end

    if type(ctx.emit) == 'function' then
        ctx.emit(pickup)
    elseif type(ctx.entities) == 'table' then
        ctx.entities[#ctx.entities + 1] = pickup
    end

    local def = itemDef(id)
    if def.onDrop then def.onDrop(e, def, taken, pickup) end

    return pickup, nil, taken
end

--[[
    Takes a world pickup into a bag. Returns `taken, leftover, reason`.

    THE OVERFLOW RULE: what does not fit stays on the floor. The pickup entity's
    count is reduced by exactly what was taken and the entity survives; it is
    marked dead only when it is empty. A pickup that fits nowhere is refused with
    'full' and is not touched at all.
]]
function Inventory.pickup(e, pickup, ctx)
    ctx = ctx or {}

    local inv = Inventory.of(e)
    if not inv then return 0, 0, 'no inventory' end

    if not Inventory.isPickup(pickup) or pickup.dead then
        return 0, 0, 'not a pickup'
    end

    local comp = pickup.components.pickup
    local id = comp.item
    local available = Attributes.number(comp.count) or 0
    if available <= 0 then return 0, 0, 'empty pickup' end
    available = floor(available)

    local want = Attributes.number(ctx.count) or available
    want = min(floor(max(0, want)), available)
    if want <= 0 then return 0, available, 'nothing asked for' end

    local added = Inventory.add(e, id, want)

    comp.count = available - added
    if comp.count <= 0 then
        pickup.dead = true
        comp.count = 0
    end

    return added, comp.count, (added < want) and 'full' or nil
end

-- Every pickup within `range` of an entity, nearest first. A convenience over
-- Collide.query so a game's "walk over it to take it" loop is three lines.
function Inventory.pickupsNear(entities, x, y, range)
    return Collide.query(entities, x, y, range or 0.6, Inventory.isPickup)
end

---------------------------------------------------------------------------
-- Equipping
---------------------------------------------------------------------------

--[[
    Ammunition supply for a weapon, drawn from this bag.

    Returned as a closure and handed to `Weapons.equip`, which is what makes a
    reload consume the right item out of the right inventory without weapons.lua
    knowing that inventories exist. `dryRun` answers "how many could I get"
    without taking them, which is how `Weapons.reload` refuses with 'no reserve'
    before starting an animation for nothing.
]]
function Inventory.supplier(e, weaponId)
    return function(need, dryRun)
        local inv = Inventory.of(e)
        if not inv then return 0 end

        local n = Attributes.number(need) or 0
        if n <= 0 then return 0 end

        local slots = slotsOf(inv)
        local available = 0
        local matches = {}

        for i = 1, inv.capacity do
            local s = slots[i]
            if s then
                local def = items[s.id]
                if def and def.ammoFor == weaponId then
                    available = available + s.count
                    matches[#matches + 1] = i
                end
            end
        end

        local take = min(available, floor(n))
        if take <= 0 or dryRun then return take end

        local remaining = take
        for k = 1, #matches do
            if remaining <= 0 then break end
            local i = matches[k]
            local s = slots[i]
            local got = min(s.count, remaining)
            s.count = s.count - got
            remaining = remaining - got
            if s.count <= 0 then slots[i] = nil end
        end

        sync(inv)
        return take
    end
end

--[[
    Equips the weapon in a slot. Returns the weapon state, or nil plus a reason:

        'no inventory'  'empty slot'  'not a weapon'  'unknown weapon: x'

    The slot's item must declare `weapon`. The equipped weapon's reload supply is
    wired to this bag, so `Weapons.reload` consumes the matching `ammoFor` item.
]]
--[[
    Uses the item in a slot. Returns used(bool), reason.

    The engine does not decide what "use" means -- that is a rule, and rules are
    the game's, exactly as with onPickup and onDrop. What it does decide is the
    bookkeeping either side of the rule, because that is the part every game
    would otherwise write again and get subtly different:

      * the slot is read and the definition looked up
      * the item's `onUse(entity, index, def)` is called
      * ONE is consumed only if the hook returns true

    Returning false is how a hook says "not now" -- a medkit at full health, a
    key in the wrong room -- and nothing is consumed. A hook that raises does not
    consume either and the error propagates, because an item that errors halfway
    through its effect has not been used and silently eating it would hide the
    bug behind a missing item.

    An item with no `onUse` is not usable and says so, rather than being consumed
    for no effect.
]]
function Inventory.use(e, index)
    local slot = Inventory.get(e, index)
    if not slot then return false, 'empty slot' end

    -- itemDef never returns nil: an item this build does not define is
    -- synthesised as a placeholder so a save from a build with one more item in
    -- it does not lose that item. So the check is `unknown`, not nil -- and an
    -- item we cannot describe must not be consumable, because consuming it would
    -- destroy the very thing the placeholder exists to preserve.
    local def = Inventory.itemDef(slot.id)
    if def.unknown then
        return false, ('this build does not define %s'):format(tostring(slot.id))
    end
    if not def.onUse then return false, 'not usable' end

    -- Called before anything is removed, so the hook sees the bag as the player
    -- does at the moment they press the key.
    local consumed = def.onUse(e, index, def)
    if not consumed then return false, 'declined' end

    Inventory.removeSlot(e, index, 1)
    return true
end

function Inventory.equip(e, index, opts)
    opts = opts or {}

    local inv = Inventory.of(e)
    if not inv then return nil, 'no inventory' end

    local slots = slotsOf(inv)
    local slot = slots[index]
    if not slot then return nil, 'empty slot' end

    local def = items[slot.id]
    if not def or not def.weapon then return nil, 'not a weapon' end

    local state, err = Weapons.equip(e, def.weapon, {
        ammo    = opts.ammo,
        reserve = 0,
        seed    = opts.seed,
        supply  = Inventory.supplier(e, def.weapon),
    })
    if not state then return nil, err end

    inv.equipped = index
    sync(inv)

    return state
end

function Inventory.equipped(e)
    local inv = Inventory.of(e)
    if not inv or not inv.equipped then return nil end
    return inv.equipped, Inventory.get(e, inv.equipped)
end

function Inventory.unequip(e)
    local inv = Inventory.of(e)
    if not inv then return false end
    inv.equipped = nil
    Weapons.unequip(e)
    sync(inv)
    return true
end

-- Finds the first slot holding an item whose weapon is `weaponId`, and equips it.
function Inventory.equipWeapon(e, weaponId, opts)
    local inv = Inventory.of(e)
    if not inv then return nil, 'no inventory' end
    local slots = slotsOf(inv)
    for i = 1, inv.capacity do
        local s = slots[i]
        if s then
            local def = items[s.id]
            if def and def.weapon == weaponId then return Inventory.equip(e, i, opts) end
        end
    end
    return nil, ('nothing in this bag equips %s'):format(tostring(weaponId))
end

return Inventory
