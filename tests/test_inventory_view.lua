--[[
    Inventory display logic.

    Pure, and tested for the same reason meatray.ui.server_row is: its failures
    are not crashes. meatray/ui/core.lua needs LOVE's utf8 module and cannot load
    headless, so anything left inside a panel is invisible to this suite — and
    the browser bug that taught the project this lesson (`entry.maxPlayers` read
    where every backend emits `max`, so every server showed 0 players and FULL
    was dead code) threw nothing and booted clean.

    The equivalents here, each with an assertion below:

      * reading item definitions through `Inventory.item` instead of
        `Inventory.itemDef` crashes on exactly the item the model preserves on
        purpose — one this build no longer defines;
      * calling the ammunition supplier without `dryRun` EMPTIES THE BAG from a
        draw path, once per frame;
      * calling it with math.huge answers 0, because the supplier sanitises its
        argument and rejects infinity, so a full bag reads as empty;
      * an equipped index left pointing at an empty slot by a snapshot indexes
        nil;
      * shrinking a bag's capacity silently deletes the slots above it.
]]

local Entity = require('meatray.sim.entity')
local Game = require('meatray.game')

local Inventory = Game.inventory
local View = require('meatray.ui.inventory_view')

return function(t)
    Game.reset()
    Entity.clearArchetypes()

    local function bag(capacity)
        local e = Entity.new{ kind = 'bench', x = 0, y = 0 }
        Inventory.attach(e, { capacity = capacity or 6 })
        return e
    end

    Inventory.defineItem('pistol',       { stack = 1, weapon = 'pistol' })
    Inventory.defineItem('ammo.9mm',     { stack = 60, ammoFor = 'pistol' })
    Inventory.defineItem('medkit',       { stack = 5, name = 'medkit' })

    ---------------------------------------------------------------------
    t.describe('every slot is described, including the empty ones')

    local e = bag(6)
    local slots = View.slots(e)
    t.eq(#slots, 6, 'a bag of six describes six slots when it is empty')
    t.ok(slots[1].empty, 'and each one says it is empty')
    t.eq(slots[4].index, 4, 'a descriptor carries the model index it came from')
    t.eq(slots[1].count, 0, 'an empty slot counts zero rather than nil')

    Inventory.add(e, 'pistol', 1)
    Inventory.add(e, 'ammo.9mm', 30)

    slots = View.slots(e)
    t.eq(#slots, 6, 'and still six once two of them are filled')
    t.ok(not slots[1].empty, 'slot 1 holds the pistol')
    t.ok(not slots[2].empty, 'slot 2 holds the ammunition')
    t.ok(slots[3].empty, 'slot 3 is still empty and is still listed')
    -- The whole point of listing empties: the gap between filled slots has to be
    -- clickable, or "put it there" has nowhere to land.
    t.eq(slots[6].index, 6, 'the last slot is present so its index can be aimed at')

    t.ok(View.slot(e, 0) == nil, 'slot 0 does not exist')
    t.ok(View.slot(e, 7) == nil, 'nor slot 7 in a bag of six')
    t.ok(View.slot(e, 'x') == nil, 'nor a slot named x')
    t.ok(View.slot(Entity.new{ kind = 'rock' }, 1) == nil,
         'and an entity with no bag has no slot 1')

    ---------------------------------------------------------------------
    t.describe('counts and caps')

    t.eq(slots[2].count, 30, 'the count is what the model holds')
    t.eq(slots[2].stack, 60, 'the cap comes from the definition')
    t.ok(slots[2].countText:find('30/60'), 'a stacking item shows count over cap')
    t.ok(not slots[2].full, '30 of 60 is not full')
    t.near(slots[2].fill, 0.5, 1e-9, 'and is half a bar')

    -- A single-slot item showing "1/1" is noise, so it shows the count alone.
    t.eq(slots[1].countText, '1', 'a non-stacking item shows just its count')
    t.ok(slots[1].full, 'and one of a stack of one is full')

    Inventory.add(e, 'ammo.9mm', 30)
    t.ok(View.slot(e, 2).full, 'topped up to the cap it reads full')
    t.near(View.slot(e, 2).fill, 1, 1e-9, 'and fills the bar exactly')

    ---------------------------------------------------------------------
    t.describe('an item this build does not define is still drawable')

    -- This is the case the model goes out of its way to carry: a save written by
    -- a build with one more item in it must not lose that item on load. So the
    -- view meets an id with no definition, and `Inventory.item` answers nil for
    -- it. Reaching through that nil for `.name` is a crash on precisely the bag
    -- the model was protecting.
    t.ok(Inventory.item('mystery') == nil, 'the test premise: mystery is undefined')

    local ghost = bag(3)
    Inventory.add(ghost, 'mystery', 1)
    local unknown = View.slot(ghost, 1)
    t.ok(unknown ~= nil, 'an undefined item still produces a slot descriptor')
    t.eq(unknown.name, 'mystery', 'and falls back to the id as its name')
    t.ok(unknown.unknown, 'and is flagged as undefined by this build')
    t.ok(View.describeSlot(unknown):find('UNKNOWN'), 'which the row says out loud')
    t.ok(not View.slot(e, 1).unknown, 'a defined item is not flagged')

    -- And the harder half of the same case: the save also carried a count above
    -- what this build thinks a slot holds.
    local stale = bag(3)
    local inv = Inventory.of(stale)
    inv.contents = '1=mystery*90'
    local over = View.slot(stale, 1)
    t.eq(over.count, 90, 'a count above the cap survives the decode')
    t.eq(over.stack, 1, 'while this build believes the cap is one')
    t.ok(over.over, 'so the slot is flagged as over its cap')
    t.ok(over.fill <= 1, 'and the bar is clamped rather than drawing past its box')
    t.ok(View.describeSlot(over):find('OVER'), 'the row says OVER rather than merely full')

    ---------------------------------------------------------------------
    t.describe('the equipped slot')

    local armed = bag(4)
    Inventory.add(armed, 'pistol', 1)
    Inventory.add(armed, 'ammo.9mm', 45)

    local weapons = Game.weapons
    weapons.define('pistol', { magazine = 12, ammoItem = 'ammo.9mm' })

    t.ok(Inventory.equip(armed, 1) ~= nil, 'the pistol equips')
    t.ok(View.slot(armed, 1).equipped, 'and its slot says so')
    t.ok(not View.slot(armed, 2).equipped, 'while the ammunition does not')
    t.ok(View.describeSlot(View.slot(armed, 1)):find('equipped'), 'the row marks it')
    t.ok(View.describeSlot(View.slot(armed, 1)):find('weapon'), 'and marks it a weapon')
    t.ok(View.describeSlot(View.slot(armed, 2)):find('ammo:pistol'),
         'and the ammunition row names the weapon it feeds')

    local summary = View.summary(armed)
    t.eq(summary.equipped, 1, 'the summary reports the equipped slot')
    t.eq(summary.equippedWeapon, 'pistol', 'and the weapon it drives')
    t.ok(not summary.equippedStale, 'and does not call it stale')

    -- `equipped` and `contents` are separate replicated fields, so a snapshot can
    -- land one without the other and leave the index pointing at nothing. A view
    -- that trusts it indexes nil.
    local ghostEquip = bag(4)
    local gi = Inventory.of(ghostEquip)
    gi.equipped = 3
    local ghostSummary = View.summary(ghostEquip)
    t.ok(ghostSummary ~= nil, 'a bag whose equipped slot is empty still summarises')
    t.ok(ghostSummary.equipped == nil, 'and reports nothing equipped')
    t.ok(ghostSummary.equippedStale, 'while saying the index is stale')
    t.eq(ghostSummary.equippedIndex, 3, 'and naming which index it was')
    t.ok(not View.slot(ghostEquip, 3).equipped,
         'the empty slot itself never claims to be the equipped item')
    t.ok(View.summaryLine(ghostEquip):find('3'), 'the summary line names the stale slot')

    -- Out of range entirely, which a capacity change can also produce.
    gi.equipped = 99
    t.ok(View.summary(ghostEquip).equippedStale, 'an out-of-range equipped index is stale too')
    t.ok(View.summary(ghostEquip).equipped == nil, 'and equips nothing')

    ---------------------------------------------------------------------
    t.describe('the bag summary')

    local s = View.summary(e)
    t.eq(s.capacity, 6, 'capacity')
    t.eq(s.used, 2, 'used slots')
    t.eq(s.free, 4, 'free slots')
    t.ok(not s.full, 'and it is not full')
    t.ok(s.contents:find('pistol'), 'the replicated contents string is passed through verbatim')

    local packed = bag(2)
    Inventory.add(packed, 'pistol', 1)
    Inventory.add(packed, 'medkit', 1)
    t.ok(View.summary(packed).full, 'a bag with no free slot reports full')
    t.ok(View.summaryLine(packed):find('FULL'), 'and the line says FULL')

    -- No inventory at all is a different answer from an empty inventory, and a
    -- panel has to be able to tell them apart.
    t.ok(View.summary(Entity.new{ kind = 'rock' }) == nil,
         'an entity with no bag summarises as nil, not as an empty bag')
    t.eq(View.summaryLine(Entity.new{ kind = 'rock' }), 'no inventory',
         'and its line says so rather than showing 0/0')
    t.eq(#View.slots(Entity.new{ kind = 'rock' }), 0, 'and it has no slots to draw')

    ---------------------------------------------------------------------
    t.describe('the ammunition reserve is read, not consumed')

    local supplied = bag(4)
    Inventory.add(supplied, 'pistol', 1)
    Inventory.add(supplied, 'ammo.9mm', 45)

    t.eq(View.reserveFor(supplied, 'pistol'), 45, 'the reserve counts the matching ammunition')

    -- The bug this guards: `Inventory.supplier` returns a closure that TAKES what
    -- it reports unless dryRun is true. A display that forgot would empty the
    -- bag once per frame for as long as the panel was open.
    t.eq(Inventory.count(supplied, 'ammo.9mm'), 45,
         'and reading it takes nothing out of the bag')
    View.reserveFor(supplied, 'pistol')
    View.reserveFor(supplied, 'pistol')
    View.reserveFor(supplied, 'pistol')
    t.eq(Inventory.count(supplied, 'ammo.9mm'), 45,
         'nor does reading it three more times, which is what a draw loop does')

    -- The other half: the cap handed to the supplier has to be a real number.
    -- Attributes.number rejects math.huge, so asking for infinity answers zero
    -- and a bag full of ammunition would render as empty.
    t.ok(View.MAX_HELD < math.huge, 'the reserve cap is finite')
    t.ok(View.MAX_HELD >= Inventory.MAX_CAPACITY * Inventory.MAX_STACK,
         'and is at least as large as a bag can physically hold')
    t.eq(Inventory.supplier(supplied, 'pistol')(math.huge, true), 0,
         'the premise: infinity is refused by the supplier, so it must not be used')

    t.eq(View.reserveFor(supplied, 'launcher'), 0, 'ammunition for another weapon does not count')
    t.eq(View.reserveFor(supplied, nil), 0, 'and no weapon needs no reserve')
    t.eq(View.reserveFor(Entity.new{ kind = 'rock' }, 'pistol'), 0,
         'an entity with no bag has no reserve')

    local reserve, weaponId = View.equippedReserve(armed)
    t.eq(weaponId, 'pistol', 'the equipped reserve names the equipped weapon')
    t.ok(reserve > 0, 'and reports what is in the bag for it')
    local bare = bag(2)
    local bareReserve, bareWeapon = View.equippedReserve(bare)
    t.eq(bareReserve, 0, 'a bag with nothing equipped has no equipped reserve')
    t.ok(bareWeapon == nil, 'and names no weapon')

    ---------------------------------------------------------------------
    t.describe('the item pick list distinguishes near-identical ids')

    local choices = View.itemChoices()
    t.eq(#choices, 3, 'every defined item is offered, and only those')
    t.eq(choices[1].id, 'ammo.9mm', 'the list is sorted, so a panel does not reorder per frame')

    local byId = {}
    for _, c in ipairs(choices) do byId[c.id] = c end

    t.ok(byId['pistol'] ~= nil, 'the pistol is listed')
    t.ok(byId['ammo.9mm'] ~= nil, 'and its ammunition')
    -- `pistol` and `ammo.9mm (ammo pistol)` are one careless glance apart, which
    -- is the whole reason the label carries the definition.
    t.ok(byId['pistol'].label:find('weapon'), 'a weapon item says it is a weapon')
    t.ok(byId['ammo.9mm'].label:find('ammo'), 'an ammunition item says what it feeds')
    t.ok(byId['ammo.9mm'].label:find('pistol'), 'and names the weapon')
    t.ok(byId['medkit'].label:find('5'), 'a plain stacking item shows its stack size')
    t.eq(byId['ammo.9mm'].stack, 60, 'the choice carries the stack size for the caller')

    ---------------------------------------------------------------------
    t.describe('an add says all three numbers, and checks the invariant in public')

    local small = bag(1)
    local added, leftover, reason = Inventory.add(small, 'medkit', 8)
    t.eq(added, 5, 'the model took what fitted')
    t.eq(leftover, 3, 'and returned the rest')

    local line = View.describeAdd('medkit', 8, added, leftover, reason)
    -- Showing only `added` cannot distinguish a bag that took everything from
    -- one that took half, which is the single case this model exists for.
    t.ok(line:find('8'), 'the line says what was asked for')
    t.ok(line:find('5'), 'what was taken')
    t.ok(line:find('3'), 'and what was left over')
    t.ok(line:find('full'), 'and why')
    t.ok(not line:find('INVARIANT'), 'a correct add is not flagged')

    t.ok(View.describeAdd('x', 10, 10, 0):find('10'), 'an add that all fits still reports')
    t.ok(not View.describeAdd('x', 10, 10, 0):find('INVARIANT'), 'and is not flagged')

    -- The flag itself has to work, or it is decoration.
    t.ok(View.describeAdd('x', 10, 4, 3):find('INVARIANT'),
         'numbers that do not add up ARE flagged')
    t.ok(View.addBrokeInvariant(10, 4, 3), 'and the predicate agrees')

    -- A refusal is not overflow: nothing entered the bag, so nothing can have
    -- vanished, and flagging it would cry wolf about a typo.
    t.ok(not View.addBrokeInvariant(10, 0, 0, 'unusable count'),
         'a refused count is exempt from the invariant')
    t.ok(not View.addBrokeInvariant(10, 0, 0, 'unusable item id'),
         'and a refused id')
    t.ok(not View.addBrokeInvariant(10, 0, 0, 'no inventory'),
         'and an entity with no bag')
    t.ok(View.addBrokeInvariant(10, 0, 0, 'full'),
         "but 'full' is an overflow answer and is NOT exempt")
    t.ok(not View.describeAdd('x', 10, 0, 0, 'unusable count'):find('INVARIANT'),
         'and the line agrees with the predicate')

    ---------------------------------------------------------------------
    t.describe('a world pickup describes itself')

    local dropper = bag(3)
    Inventory.add(dropper, 'medkit', 4)
    local floor = {}
    local pickup = Inventory.drop(dropper, 1, 2, { entities = floor, x = 1, y = 1 })
    t.ok(pickup ~= nil, 'the drop produced a world entity')
    t.eq(#floor, 1, 'and it landed in the caller list')

    local pickupLine = View.describePickup(pickup)
    t.ok(pickupLine:find('medkit'), 'the floor line names the item')
    t.ok(pickupLine:find('2'), 'and how many are lying there')
    t.ok(View.describePickup(dropper) == nil, 'a bag is not a pickup')
    t.ok(View.describePickup(nil) == nil, 'and neither is nothing')

    ---------------------------------------------------------------------
    t.describe('shrinking a bag is capped by what is in it')

    -- This block used to assert the opposite, and was right to at the time:
    -- Inventory.attach re-decoded the contents against the smaller capacity and
    -- the decoder silently dropped anything out of range, so offering a capacity
    -- field without a warning was offering a button that deletes inventory.
    --
    -- The model no longer does that. A shrink is honoured only as far as it is
    -- free and the capacity is held at the occupied high-water mark. The same
    -- set of slots is still worth naming -- they are why the requested size was
    -- not granted -- so the computation stands and only its meaning changed.
    local wide = bag(6)
    Inventory.add(wide, 'medkit', 5)
    Inventory.add(wide, 'medkit', 5)
    Inventory.add(wide, 'medkit', 5)
    t.eq(Inventory.used(wide), 3, 'three slots are occupied')

    local lost = View.blockingResize(wide, 2)
    t.eq(#lost, 1, 'shrinking from six to two is blocked by one occupied slot')
    t.eq(lost[1].index, 3, 'and names which')
    t.eq(lost[1].count, 5, 'and how much is in it')
    t.ok(View.describeBlockers(lost):find('medkit'), 'the warning names the item')
    t.ok(View.describeBlockers(lost):find('slot 3'), 'and the slot')

    t.eq(#View.blockingResize(wide, 3), 0, 'shrinking to exactly what is used is unblocked')
    t.eq(#View.blockingResize(wide, 6), 0, 'and staying the same size is unblocked')
    t.eq(#View.blockingResize(wide, 12), 0, 'nor does growing block')
    t.eq(View.describeBlockers({}), '', 'and there is nothing to warn about')
    t.eq(#View.blockingResize(wide, 'big'), 0, 'a non-number capacity blocks nothing')

    -- The prediction has to match what the model actually does, or it is worse
    -- than no prediction at all. It said one occupied slot stands in the way of
    -- shrinking to two, so the shrink must stop at that slot and keep everything.
    local before = Inventory.count(wide, 'medkit')
    local _, short = Inventory.attach(wide, { capacity = 2 })

    t.eq(Inventory.used(wide), 3, 'the occupied slot is still occupied')
    t.eq(Inventory.count(wide, 'medkit'), before, 'and not one medkit was destroyed')
    t.ok(Inventory.capacity(wide) >= 3, 'the capacity stopped at the high-water mark')
    t.ok(short ~= nil and short > 0, 'and attach reported the slots it withheld')

    ---------------------------------------------------------------------
    t.describe('C16: the bag grid layout')

    local g = View.grid(8, { cols = 4, cell = 40, pad = 6 })
    t.eq(g.cols, 4, 'columns as asked')
    t.eq(g.rows, 2, 'rows from the count')
    t.eq(#g.cells, 8, 'one cell per slot')
    t.eq(g.cells[1].x, 0, 'first cell at the origin')
    t.eq(g.cells[1].y, 0, 'top-left')
    t.eq(g.cells[5].col, 0, 'the fifth slot wraps to the next row')
    t.eq(g.cells[5].row, 1, 'row 1')
    t.eq(g.cells[5].x, 0, 'back at the left edge')
    t.eq(g.cells[5].y, 46, 'one cell + pad down')
    t.eq(g.cells[4].x, 3 * 46, 'the fourth cell is three steps right')
    t.eq(g.width, 4 * 40 + 3 * 6, 'width spans the columns and the gaps between')
    t.eq(g.height, 2 * 40 + 1 * 6, 'height the rows')

    -- No explicit cols: a near-square arrangement.
    local sq = View.grid(9)
    t.eq(sq.cols, 3, 'nine slots default to 3 wide')
    t.eq(sq.rows, 3, 'and 3 tall')

    local one = View.grid(1, { cols = 4 })
    t.eq(one.rows, 1, 'a single slot is one row')
    t.eq(#one.cells, 1, 'and one cell')

    local none = View.grid(0)
    t.eq(#none.cells, 0, 'no slots, no cells')
    t.eq(none.width, 0, 'and no width')
    t.eq(none.height, 0, 'nor height — a bag panel can skip drawing entirely')

    -- Indices are 1-based and match the slot order, so cell.index reads
    -- straight into View.slots(e).
    local seq = View.grid(6, { cols = 3 })
    for i = 1, 6 do t.eq(seq.cells[i].index, i, 'cell index tracks slot ' .. i) end
end
