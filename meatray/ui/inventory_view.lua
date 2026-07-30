--[[
    meatray.ui.inventory_view — what a bag has to SAY, separated from drawing it.

    Split out of panel_inventory for the reason meatray.ui.server_row was split
    out of panel_servers, and it is worth restating because the lesson was
    expensive: meatray/ui/core.lua requires LOVE's utf8 module and therefore
    cannot load under plain LuaJIT, so anything written inside a panel is
    unreachable by the test suite. The server browser paid for that by reading
    `entry.maxPlayers` when every backend emits `max` — every row showed 0
    players, the FULL flag was dead code compared against nil, nothing threw, and
    the editor booted perfectly clean. A smoke test cannot see a bug like that.

    So every decision about what an inventory panel displays lives here, where a
    test can look at it, and the panel does nothing but draw the answers.

    The decisions this file owns, and why each one is a decision rather than a
    formality:

      * EMPTY SLOTS ARE LISTED, not skipped. A bag is `capacity` slots, and a
        view that only renders the occupied ones cannot show how much room is
        left, cannot be clicked to say "put it there", and disagrees with the
        model's own indices the moment slot 2 is empty and slot 3 is not.

      * ITEM DEFINITIONS ARE READ THROUGH `Inventory.itemDef`, NOT
        `Inventory.item`. The model deliberately carries an item this build does
        not define — that is what stops a save written by a build with one more
        item in it from losing that item on load. `Inventory.item` returns nil
        for exactly that case, so a view that reaches through it for `.name`
        crashes on precisely the bag the model went out of its way to preserve.
        `itemDef` always answers, and marks the answer `unknown`.

      * A COUNT ABOVE THE STACK CAP IS SHOWN AS SUCH. Same cause: an item that
        stacked to 60 in the build that wrote the save stacks to 1 in a build
        that no longer defines it, so `count > stack` is reachable and real. A
        fill fraction is clamped so the bar cannot draw past its box, and the
        slot is flagged rather than quietly rendered as merely "full".

      * AN EQUIPPED INDEX POINTING AT NOTHING IS NOT AN EQUIPPED ITEM. The
        component's `equipped` field and its `contents` string replicate
        independently, so a snapshot or a save can leave `equipped` on a slot
        that is now empty or beyond capacity. Reporting that as an equipped item
        means reading a nil slot; reporting it as nothing at all hides a state
        worth seeing. It is reported as stale.

      * THE AMMUNITION RESERVE IS READ WITH `dryRun` TRUE AND A FINITE CAP.
        `Inventory.supplier` is a closure that CONSUMES what it returns unless
        the second argument is true — a display that forgot it would empty the
        player's bag once per frame for as long as the panel was open. And the
        cap has to be finite: the supplier sanitises `need` through
        Attributes.number, which rejects math.huge, so asking for infinity
        answers zero and a bag full of ammunition reads as empty.

    HEADLESS: requires only meatray.game.inventory, which is headless itself.
    Nothing here touches love.* or meatray.ui.core.
]]

local Inventory = require('meatray.game.inventory')

local View = {}

local floor, min = math.floor, math.min

-- The most a bag can physically hold: every slot filled to the largest stack the
-- model permits. Used as the supplier's `need`, because it must be a real finite
-- number (see the header) and this is the honest upper bound rather than a
-- magic constant.
View.MAX_HELD = Inventory.MAX_CAPACITY * Inventory.MAX_STACK

-- Reasons `Inventory.add` returns when the request never reached the bag at all.
-- They are not overflow, so the added+leftover invariant does not apply to them
-- and flagging one as a broken invariant would cry wolf about a typo.
local REFUSED = {
    ['no inventory'] = true,
    ['unusable item id'] = true,
    ['unusable count'] = true,
}

---------------------------------------------------------------------------
-- One slot
---------------------------------------------------------------------------

--[[
    Describes slot `index` of `e`'s bag. Returns nil only when there is no such
    slot — an EMPTY slot is described, not omitted, because "nothing is here" is
    a thing the panel has to draw.

        index      the slot number, 1-based, as the model spells it
        empty      true when nothing is in it
        id         item id, or nil
        name       display name from the definition, falling back to the id
        count      how many
        stack      the cap for one slot of this item, per THIS build
        countText  count formatted for a cell
        fill       0..1, clamped, for a bar
        full       count has reached the cap
        over       count is ABOVE the cap (a save from a build that stacked more)
        unknown    this build does not define the item
        weapon     weapon id this equips, or nil
        ammoFor    weapon id a reload consumes this for, or nil
        equipped   this is the equipped slot AND it holds something
]]
function View.slot(e, index)
    local capacity = Inventory.capacity(e)
    if type(index) ~= 'number' or index < 1 or index > capacity then return nil end

    local inv = Inventory.of(e)
    local equippedIndex = inv and inv.equipped or nil

    -- A copy, never the live slot table. Handing the live one to a drawing layer
    -- invites a mutation the contents string never hears about, and the model is
    -- explicit that a direct edit is discarded on the next re-read.
    local held = Inventory.get(e, index)

    if not held then
        return {
            index = index,
            empty = true,
            count = 0,
            stack = 0,
            name = '(empty)',
            countText = '',
            fill = 0,
            full = false,
            over = false,
            unknown = false,
            equipped = false,
        }
    end

    -- itemDef, not item: see the header. An item this build dropped is still
    -- carried, and it is exactly the one that must not crash the panel.
    local def = Inventory.itemDef(held.id)
    local stack = def.stack or 1
    local count = held.count or 0

    return {
        index = index,
        empty = false,
        id = held.id,
        name = def.name or held.id,
        count = count,
        stack = stack,
        countText = (stack > 1) and ('%d/%d'):format(count, stack) or tostring(count),
        fill = (stack > 0) and min(1, count / stack) or 0,
        full = count >= stack,
        over = count > stack,
        unknown = Inventory.item(held.id) == nil,
        weapon = def.weapon,
        ammoFor = def.ammoFor,
        equipped = (equippedIndex == index),
    }
end

-- Every slot in the bag, in order, empties included. Length is the capacity.
function View.slots(e)
    local out = {}
    for i = 1, Inventory.capacity(e) do
        out[i] = View.slot(e, i)
    end
    return out
end

-- One slot as a line of text. Column-formatted like meatray.ui.server_row so a
-- list of them lines up.
function View.describeSlot(slot)
    if not slot then return '' end
    if slot.empty then
        return ('%2d  %-18s'):format(slot.index, '(empty)')
    end

    local flags = {}
    if slot.equipped then flags[#flags + 1] = 'equipped' end
    if slot.weapon then flags[#flags + 1] = 'weapon' end
    if slot.ammoFor then flags[#flags + 1] = 'ammo:' .. tostring(slot.ammoFor) end
    -- OVER instead of full, not as well as: a stack past its cap is a different
    -- and more interesting fact than one that has reached it.
    if slot.over then flags[#flags + 1] = 'OVER'
    elseif slot.full then flags[#flags + 1] = 'full' end
    if slot.unknown then flags[#flags + 1] = 'UNKNOWN' end

    return ('%2d  %-18s %9s  %s'):format(
        slot.index,
        tostring(slot.name):sub(1, 18),
        slot.countText,
        table.concat(flags, ' '))
end

---------------------------------------------------------------------------
-- The bag as a whole
---------------------------------------------------------------------------

--[[
    Bag-level state. Returns nil when the entity has no inventory at all, which
    a panel must distinguish from an empty one: "this thing does not carry
    anything" and "this bag is empty" are different answers.

        equipped       the equipped slot index, ONLY when it holds something
        equippedStale  the component names an equipped slot that holds nothing
        contents       the replicated string, verbatim — the authoritative state
]]
function View.summary(e)
    local inv = Inventory.of(e)
    if not inv then return nil end

    local capacity = inv.capacity or 0
    local used = Inventory.used(e)

    local equipped, equippedName, equippedWeapon, stale = nil, nil, nil, false
    local index = inv.equipped
    if index then
        local slot = View.slot(e, index)
        if slot and not slot.empty then
            equipped = index
            equippedName = slot.name
            equippedWeapon = slot.weapon
        else
            -- `equipped` and `contents` replicate as separate fields, so a
            -- snapshot can land one without the other. Saying so beats drawing
            -- a weapon nobody is holding.
            stale = true
        end
    end

    return {
        capacity = capacity,
        used = used,
        free = capacity - used,
        full = used >= capacity,
        -- The raw component field, whether or not it points at anything. Kept
        -- separate from `equipped` so a stale index can be NAMED rather than
        -- just reported as absent.
        equippedIndex = index,
        equipped = equipped,
        equippedName = equippedName,
        equippedWeapon = equippedWeapon,
        equippedStale = stale,
        contents = inv.contents or '',
    }
end

function View.summaryLine(e)
    local s = View.summary(e)
    if not s then return 'no inventory' end

    local line = ('%d/%d slots, %d free'):format(s.used, s.capacity, s.free)
    if s.full then line = line .. '  FULL' end
    if s.equipped then
        line = line .. ('  equipped: %s'):format(tostring(s.equippedName))
    elseif s.equippedStale then
        line = line .. ('  equipped slot %s holds nothing'):format(tostring(s.equippedIndex))
    end
    return line
end

---------------------------------------------------------------------------
-- Ammunition
---------------------------------------------------------------------------

--[[
    How much ammunition in this bag feeds `weaponId`, without taking any.

    Both arguments to the supplier matter and both are easy to get wrong:

      * `dryRun` MUST be true. The supplier is the closure a reload consumes
        through; called for real from a draw path it would empty the bag every
        frame the panel is visible.

      * the cap MUST be finite. The supplier sanitises `need` through
        Attributes.number, which rejects math.huge, so `supply(math.huge, true)`
        answers 0 — a bag full of ammunition would read as having none.
]]
function View.reserveFor(e, weaponId)
    if weaponId == nil or not Inventory.of(e) then return 0 end
    local supply = Inventory.supplier(e, weaponId)
    return supply(View.MAX_HELD, true)
end

-- The reserve for whatever is equipped right now, and the weapon it is for.
function View.equippedReserve(e)
    local s = View.summary(e)
    if not s or not s.equippedWeapon then return 0, nil end
    return View.reserveFor(e, s.equippedWeapon), s.equippedWeapon
end

---------------------------------------------------------------------------
-- Item definitions, as a pick list
---------------------------------------------------------------------------

-- Every item this build defines, with enough of its definition attached to tell
-- them apart in a list. `pistol` and `ammo.pistol` are one character different
-- and completely different things.
function View.itemChoices()
    local out = {}
    for _, id in ipairs(Inventory.itemIds()) do
        local def = Inventory.item(id)
        local note
        if def.weapon then note = 'weapon ' .. tostring(def.weapon)
        elseif def.ammoFor then note = 'ammo ' .. tostring(def.ammoFor)
        elseif (def.stack or 1) > 1 then note = 'x' .. tostring(def.stack) end

        out[#out + 1] = {
            id = id,
            stack = def.stack,
            weapon = def.weapon,
            ammoFor = def.ammoFor,
            label = note and ('%s  (%s)'):format(id, note) or id,
        }
    end
    return out
end

---------------------------------------------------------------------------
-- Outcomes
---------------------------------------------------------------------------

--[[
    The result of an add, said out loud.

    Showing only `added` is the mistake worth avoiding: it cannot tell a bag that
    took everything from one that took half and refused the rest, which is the
    single case this model was built around. So the line carries all three
    numbers, and checks the model's own invariant in front of the reader —
    `added + leftover == asked`, on every path in.

    A request the model refused outright (a bad id, a bad count, no bag) is not
    overflow and is exempt: it never entered the bag, so nothing about it can
    have vanished.
]]
function View.describeAdd(id, asked, added, leftover, reason)
    asked, added, leftover = asked or 0, added or 0, leftover or 0

    local line = ('%s: asked %d, took %d, left %d')
                 :format(tostring(id), asked, added, leftover)
    if reason then line = line .. ('  (%s)'):format(tostring(reason)) end

    if not (reason and REFUSED[reason]) and added + leftover ~= asked then
        line = line .. '  INVARIANT BROKEN: added + leftover should equal asked'
    end

    return line
end

function View.addBrokeInvariant(asked, added, leftover, reason)
    if reason and REFUSED[reason] then return false end
    return (added or 0) + (leftover or 0) ~= (asked or 0)
end

-- A world pickup, as a line. `count` is replicated so this needs no lookup, and
-- the item may be one this build does not define — hence itemDef again.
function View.describePickup(entity)
    if not Inventory.isPickup(entity) then return nil end
    local comp = entity.components.pickup
    local def = Inventory.itemDef(comp.item)
    return ('%s x%d'):format(tostring(def.name or comp.item), comp.count or 0)
end

---------------------------------------------------------------------------
-- Resizing
---------------------------------------------------------------------------

--[[
    What re-attaching this bag at `capacity` would DESTROY.

    `Inventory.attach` re-decodes the contents string against the new capacity,
    and the decoder drops any entry whose index is out of range — so shrinking a
    bag deletes whatever was in the slots above the new size, silently, with no
    leftover returned. That is the one operation in the module that breaks its
    own "nothing vanishes" promise, and a panel that offers a capacity field
    without saying so is a panel that eats items.

    Returns an array of { index, id, count }, empty when nothing would be lost.
]]
-- The occupied slots that stand in the way of shrinking to `capacity`.
--
-- This used to be called lostByResize and meant it: Inventory.attach re-decoded
-- the contents against the smaller size and the decoder silently dropped
-- anything above it, so shrinking a bag ate items. That is fixed in the model --
-- a shrink is now honoured only as far as it is free, and the capacity is held
-- at the occupied high-water mark rather than eating what sits above it.
--
-- The computation is unchanged, because it was always the same set of slots.
-- Only what they mean changed: not "these will be destroyed" but "these are why
-- you will not get the size you asked for".
function View.blockingResize(e, capacity)
    local out = {}
    local current = Inventory.capacity(e)
    if type(capacity) ~= 'number' then return out end

    local target = floor(capacity)
    if target >= current then return out end

    for i = target + 1, current do
        local held = Inventory.get(e, i)
        if held then
            out[#out + 1] = { index = i, id = held.id, count = held.count }
        end
    end
    return out
end

function View.describeBlockers(lost)
    if not lost or #lost == 0 then return '' end
    local parts = {}
    for _, entry in ipairs(lost) do
        parts[#parts + 1] = ('slot %d: %s x%d'):format(entry.index, tostring(entry.id),
                                                       entry.count or 0)
    end
    return table.concat(parts, ', ')
end

return View
