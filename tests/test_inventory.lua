--[[
    Inventory: slots, stacks, pickups, and the rule that nothing vanishes.

    The invariant under test everywhere in this file is

        added + leftover == what was asked for

    for every path in and out of a bag. "The game ate my item" is a bug report
    players file and remember, and it is almost always an overflow that was
    deleted instead of returned — a pickup that half-fitted and was despawned
    anyway, or a stack that was capped and lost the remainder. So the suite
    checks the boring cases (add ten, take ten) and then spends most of its
    assertions on the ones where something does NOT fit.
]]

local Entity   = require('meatray.sim.entity')
local C        = require('meatray.sim.components')
local Worldgen = require('meatray.sim.worldgen')
local Game     = require('meatray.game')

local Inventory = Game.inventory
local Weapons   = Game.weapons

return function(t)
    Game.reset()
    Entity.clearArchetypes()

    local function bag(capacity)
        local e = Entity.new{ kind = 'carrier', x = 4.5, y = 4.5 }
        Inventory.attach(e, { capacity = capacity or 4 })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('item ids are checked, because they live inside a delimited string')

    t.ok(Inventory.checkId('ammo.9mm'), 'a dotted id is fine')
    t.ok(Inventory.checkId('med-kit'), 'and a dashed one')
    t.ok(not Inventory.checkId('a|b'), 'a pipe is refused: it is the record separator')
    t.ok(not Inventory.checkId('a=b'), 'and an equals sign')
    t.ok(not Inventory.checkId('a*b'), 'and a star')
    t.ok(not Inventory.checkId(''), 'an empty id is refused')
    t.ok(not Inventory.checkId(42), 'and a number')
    t.ok(not Inventory.checkId(('x'):rep(200)), 'and an absurdly long one')

    Inventory.defineItem('ammo.9mm', { stack = 60, ammoFor = 'pistol' })
    Inventory.defineItem('medkit',   { stack = 5 })
    Inventory.defineItem('pistol',   { stack = 1, weapon = 'pistol' })
    Inventory.defineItem('brick',    { stack = 10 })

    t.eq(Inventory.item('ammo.9mm').stack, 60, 'a defined item remembers its stack size')
    t.eq(Inventory.item('pistol').stack, 1, 'and a non-stacking one stacks to one')

    ---------------------------------------------------------------------
    t.describe('adding fills partial stacks first, then empty slots')

    local e = bag(4)
    t.eq(Inventory.capacity(e), 4, 'the bag has the capacity it was given')
    t.eq(Inventory.freeSlots(e), 4, 'and starts empty')

    local added, leftover = Inventory.add(e, 'ammo.9mm', 150)
    t.eq(added, 150, 'a hundred and fifty rounds go in')
    t.eq(leftover, 0, 'with nothing left over')
    t.eq(Inventory.count(e, 'ammo.9mm'), 150, 'and the count agrees')
    t.eq(Inventory.get(e, 1).count, 60, 'the first slot is a full stack')
    t.eq(Inventory.get(e, 2).count, 60, 'and the second')
    t.eq(Inventory.get(e, 3).count, 30, 'and the third holds the remainder')
    t.eq(Inventory.get(e, 4), nil, 'the fourth is untouched')
    t.eq(Inventory.used(e), 3, 'three slots are in use')

    added = Inventory.add(e, 'ammo.9mm', 20)
    t.eq(added, 20, 'twenty more go in')
    t.eq(Inventory.get(e, 3).count, 50, 'topping up the partial stack first')
    t.eq(Inventory.get(e, 4), nil, 'rather than opening a new one')

    ---------------------------------------------------------------------
    t.describe('OVERFLOW IS RETURNED, NEVER DELETED')

    local small = bag(2)
    local got, over, why = Inventory.add(small, 'brick', 25)
    t.eq(got, 20, 'a two-slot bag with ten-stacks takes twenty')
    t.eq(over, 5, 'and returns the five that did not fit')
    t.eq(got + over, 25, 'added + leftover is exactly what was asked for')
    t.eq(why, 'full', 'and it says why there is a remainder')
    t.eq(Inventory.count(small, 'brick'), 20, 'the bag holds exactly what it accepted')
    t.ok(Inventory.isFull(small), 'and is full')

    local none, allOver = Inventory.add(small, 'medkit', 3)
    t.eq(none, 0, 'a full bag takes nothing at all')
    t.eq(allOver, 3, 'and hands the whole lot back')

    t.eq(Inventory.room(small, 'brick'), 0, 'room() agrees there is none')
    t.eq(Inventory.room(e, 'ammo.9mm'), 70,
         'and counts space in partial stacks as well as empty slots')

    -- Never over-stacks, even under repeated adds.
    local capTest = bag(1)
    Inventory.add(capTest, 'brick', 6)
    Inventory.add(capTest, 'brick', 6)
    t.eq(Inventory.get(capTest, 1).count, 10, 'a stack never exceeds its cap')
    t.eq(Inventory.count(capTest, 'brick'), 10, 'and the surplus was returned, not stored')

    ---------------------------------------------------------------------
    t.describe('removing')

    t.eq(Inventory.remove(e, 'ammo.9mm', 70), 70, 'seventy come out')
    t.eq(Inventory.count(e, 'ammo.9mm'), 100, 'leaving a hundred')
    t.eq(Inventory.remove(e, 'ammo.9mm', 1000), 100,
         'asking for more than you have takes what there is')
    t.eq(Inventory.count(e, 'ammo.9mm'), 0, 'and empties the bag')
    t.eq(Inventory.used(e), 0, 'freeing every slot')
    t.eq(Inventory.remove(e, 'ammo.9mm', 5), 0, 'removing from nothing removes nothing')

    ---------------------------------------------------------------------
    t.describe('moving between slots')

    local m = bag(4)
    Inventory.add(m, 'brick', 10)
    Inventory.add(m, 'medkit', 3)
    t.eq(Inventory.get(m, 1).id, 'brick', 'bricks in slot one')
    t.eq(Inventory.get(m, 2).id, 'medkit', 'medkits in slot two')

    t.ok(Inventory.move(m, 2, 3), 'a whole stack moves to an empty slot')
    t.eq(Inventory.get(m, 2), nil, 'vacating the old one')
    t.eq(Inventory.get(m, 3).count, 3, 'and arriving intact')

    t.ok(Inventory.move(m, 3, 4, 1), 'part of a stack moves')
    t.eq(Inventory.get(m, 3).count, 2, 'leaving the rest')
    t.eq(Inventory.get(m, 4).count, 1, 'and taking the requested amount')

    t.ok(Inventory.move(m, 4, 3), 'and merges back')
    t.eq(Inventory.get(m, 3).count, 3, 'to the full three')
    t.eq(Inventory.get(m, 4), nil, 'with the source emptied')

    local okMove, moveWhy = Inventory.move(m, 3, 1, 1)
    t.ok(not okMove, 'a PARTIAL move onto a different item is refused')
    t.eq(moveWhy, 'a partial move onto another item', 'by name')
    t.eq(Inventory.get(m, 1).id, 'brick', 'and nothing was overwritten')
    t.eq(Inventory.get(m, 3).id, 'medkit', 'on either side')
    t.eq(Inventory.get(m, 3).count, 3, 'and nothing was taken from the source')

    t.ok(Inventory.move(m, 3, 1), 'a WHOLE move onto a different item swaps them')
    t.eq(Inventory.get(m, 1).id, 'medkit', 'the destination now holds the source')
    t.eq(Inventory.get(m, 3).id, 'brick', 'and the source holds the destination')

    t.ok(Inventory.swap(m, 1, 3), 'a swap can also be asked for outright')
    t.eq(Inventory.get(m, 1).id, 'brick', 'and exchanges them')
    t.eq(Inventory.get(m, 3).id, 'medkit', 'both ways')

    local overflowBag = bag(2)
    Inventory.add(overflowBag, 'brick', 10)
    Inventory.add(overflowBag, 'brick', 10)
    local okFull, fullWhy = Inventory.move(overflowBag, 2, 1)
    t.ok(not okFull, 'merging into a full stack is refused')
    t.eq(fullWhy, 'destination stack is full', 'rather than silently over-stacking')
    t.eq(Inventory.count(overflowBag, 'brick'), 20, 'and nothing was lost')

    t.ok(not Inventory.move(m, 1, 99), 'a slot out of range is refused')
    t.ok(not Inventory.move(m, 2, 3), 'and moving from an empty slot')

    ---------------------------------------------------------------------
    t.describe('dropping is lossless')

    local dropper = bag(4)
    Inventory.add(dropper, 'brick', 10)
    local ents = {}

    local pickup = Inventory.drop(dropper, 1, 4, { entities = ents })
    t.ok(pickup ~= nil, 'a drop produces a world entity')
    t.eq(#ents, 1, 'which was placed in the list it was given')
    t.ok(Inventory.isPickup(pickup), 'and is recognisably a pickup')
    t.eq(pickup:get('pickup').item, 'brick', 'holding the item')
    t.eq(pickup:get('pickup').count, 4, 'and exactly the count dropped')
    t.eq(Inventory.count(dropper, 'brick'), 6, 'the bag lost exactly that many')
    t.near(pickup.x, dropper.x, 1e-12, 'and it landed where the dropper was')

    local wholeStack = Inventory.drop(dropper, 1, nil, { entities = ents })
    t.eq(wholeStack:get('pickup').count, 6, 'dropping with no count drops the stack')
    t.eq(Inventory.used(dropper), 0, 'emptying the slot')

    t.ok(Inventory.drop(dropper, 1, 1, {}) == nil, 'dropping an empty slot is refused')

    -- A drop that cannot build its entity puts the items back rather than
    -- eating them, which is the failure this module is written against.
    Inventory.add(dropper, 'brick', 7)
    local failed, failWhy = Inventory.drop(dropper, 1, 3, { x = 0 / 0 })
    t.ok(failed == nil, 'a drop to a NaN position fails')
    t.ok(failWhy ~= nil, 'with a reason', failWhy)
    t.eq(Inventory.count(dropper, 'brick'), 7,
         'AND THE ITEMS ARE STILL IN THE BAG')

    ---------------------------------------------------------------------
    t.describe('a pickup that half fits leaves the rest on the floor')

    local half = bag(1)                                -- one slot, ten bricks max
    Inventory.add(half, 'brick', 4)                    -- six of room

    local ground = Inventory.spawnPickup('brick', 50, 4.5, 4.5)
    t.ok(ground ~= nil, 'a pickup can be spawned directly')

    local taken, left, reason = Inventory.pickup(half, ground)
    t.eq(taken, 6, 'the bag takes what fits')
    t.eq(left, 44, 'and the rest stays on the floor')
    t.eq(taken + left, 50, 'taken + left is exactly what was there')
    t.eq(reason, 'full', 'with a reason for the remainder')
    t.ok(not ground.dead, 'THE PICKUP IS STILL THERE to come back for')
    t.eq(ground:get('pickup').count, 44, 'holding the remainder')
    t.eq(Inventory.count(half, 'brick'), 10, 'and the bag is full')

    local nothing, still, fullReason = Inventory.pickup(half, ground)
    t.eq(nothing, 0, 'a full bag takes nothing more')
    t.eq(still, 44, 'and the pickup is untouched')
    t.eq(fullReason, 'full', 'and says so')
    t.ok(not ground.dead, 'and is definitely not despawned')

    local roomy = bag(8)
    local allOfIt = Inventory.pickup(roomy, ground)
    t.eq(allOfIt, 44, 'a bag with room takes the lot')
    t.ok(ground.dead, 'and only then does the pickup go')
    t.eq(ground:get('pickup').count, 0, 'with nothing left in it')

    t.eq(Inventory.pickup(roomy, ground), 0, 'a dead pickup gives nothing')
    t.eq(Inventory.pickup(roomy, Entity.new{}), 0, 'and neither does a non-pickup')

    ---------------------------------------------------------------------
    t.describe('the contents string is the state, and it round-trips')

    local s = bag(4)
    Inventory.add(s, 'brick', 12)
    Inventory.add(s, 'medkit', 2)

    local contents = s:get('inventory').contents
    t.ok(contents:find('brick%*10'), 'the string carries the full stack', contents)
    t.ok(contents:find('medkit%*2'), 'and the partial one', contents)

    local decoded = Inventory.decode(contents, 4)
    t.eq(decoded[1].id, 'brick', 'decoding gives the slots back')
    t.eq(decoded[1].count, 10, 'with their counts')
    t.eq(decoded[3].id, 'medkit', 'in their slots')
    t.eq(Inventory.encode(decoded, 4), contents, 'and re-encodes identically')

    -- Rubbish in the string costs one entry, not the bag.
    local salvaged = Inventory.decode('1=brick*10|nonsense|3=medkit*2|9=brick*1', 4)
    t.eq(salvaged[1].count, 10, 'a malformed entry is skipped')
    t.eq(salvaged[3].count, 2, 'and the readable ones survive')
    t.eq(salvaged[9], nil, 'while a slot past the capacity is dropped')

    -- Writing the string is enough to change the bag: this is what makes a
    -- network snapshot and a save both work with nothing else written.
    s:get('inventory').contents = '2=medkit*5'
    t.eq(Inventory.get(s, 1), nil, 'writing the contents string re-slots the bag')
    t.eq(Inventory.get(s, 2).id, 'medkit', 'to exactly what the string said')
    t.eq(Inventory.count(s, 'brick'), 0, 'and the old contents are gone')

    ---------------------------------------------------------------------
    t.describe('an inventory survives a save with nothing added to the save layer')

    local State = require('meatray.save.state')

    Entity.archetype('carrier', function(ent)
        Inventory.attach(ent, { capacity = 6 })
    end)

    local saveWorld = Worldgen.box(12, 12)
    local keeper = Entity.spawn('carrier', 3.5, 3.5)
    Inventory.add(keeper, 'ammo.9mm', 90)
    Inventory.add(keeper, 'medkit', 3)

    local doc = State.capture{ world = saveWorld, entities = { keeper }, savedAt = 1 }
    t.ok(doc ~= nil, 'a bag captures')

    local loaded = State.restore(doc)
    t.ok(loaded ~= nil, 'and restores')
    local back = loaded.entities[1]
    t.eq(Inventory.count(back, 'ammo.9mm'), 90, 'with every round still in it')
    t.eq(Inventory.count(back, 'medkit'), 3, 'and every medkit')
    t.eq(Inventory.get(back, 1).count, 60, 'in the same stacks')
    t.eq(Inventory.get(back, 2).count, 30, 'and the same slots')
    t.eq(Inventory.capacity(back), 6, 'and the same capacity')

    ---------------------------------------------------------------------
    t.describe('equipping drives the weapon component')

    Weapons.define('pistol', {
        damage = 12, magazine = 12, reserve = 0,
        fireInterval = 0.15, reloadTime = 0, range = 32,
        ammoItem = 'ammo.9mm',
    })

    local soldier = bag(6)
    Inventory.add(soldier, 'pistol', 1)
    Inventory.add(soldier, 'ammo.9mm', 40)

    local noWeapon, notWhy = Inventory.equip(soldier, 2)
    t.ok(noWeapon == nil, 'equipping a slot of ammunition is refused')
    t.eq(notWhy, 'not a weapon', 'by name')

    t.ok(Inventory.equip(soldier, 99) == nil, 'and so is an empty slot')

    local state = Inventory.equip(soldier, 1)
    t.ok(state ~= nil, 'equipping the pistol works')
    t.eq(Weapons.equipped(soldier), 'pistol', 'the weapon component says so')
    t.eq(select(1, Inventory.equipped(soldier)), 1, 'and the bag remembers the slot')
    t.eq(state.ammo, 12, 'with a full magazine')

    ---------------------------------------------------------------------
    t.describe('and a reload eats the right item out of the right bag')

    Weapons.equip(soldier, 'pistol', {
        ammo = 2, reserve = 0, supply = Inventory.supplier(soldier, 'pistol'),
    })

    t.eq(Inventory.count(soldier, 'ammo.9mm'), 40, 'forty rounds in the bag')
    local ok = Weapons.reload(soldier)
    t.ok(ok, 'the reload runs (zero reload time, so it completes at once)')
    t.eq(soldier:get('weapon').ammo, 12, 'the magazine is full')
    t.eq(Inventory.count(soldier, 'ammo.9mm'), 30,
         'and the ten rounds came out of the BAG, not a reserve field')

    -- Empty the bag and the same reload is refused for the right reason.
    Inventory.remove(soldier, 'ammo.9mm', 1000)
    Weapons.equip(soldier, 'pistol', {
        ammo = 0, reserve = 0, supply = Inventory.supplier(soldier, 'pistol'),
    })
    local failed, failReason = Weapons.reload(soldier)
    t.ok(not failed, 'an empty bag cannot reload')
    t.eq(failReason, 'no reserve', 'with the reason a HUD can show')
    t.eq(soldier:get('weapon').ammo, 0, 'and the magazine is untouched')

    -- A partial bag loads what it has and empties.
    Inventory.add(soldier, 'ammo.9mm', 5)
    t.ok(Weapons.reload(soldier), 'five rounds are enough to start')
    t.eq(soldier:get('weapon').ammo, 5, 'and load five')
    t.eq(Inventory.count(soldier, 'ammo.9mm'), 0, 'emptying the bag exactly')

    -- Ammunition for a DIFFERENT weapon is not consumed.
    Inventory.defineItem('ammo.12g', { stack = 40, ammoFor = 'shotgun' })
    Inventory.add(soldier, 'ammo.12g', 20)
    Weapons.equip(soldier, 'pistol', {
        ammo = 0, reserve = 0, supply = Inventory.supplier(soldier, 'pistol'),
    })
    local wrong, wrongReason = Weapons.reload(soldier)
    t.ok(not wrong, 'shotgun shells do not fit a pistol')
    t.eq(wrongReason, 'no reserve', 'and the reload is refused')
    t.eq(Inventory.count(soldier, 'ammo.12g'), 20, 'and they were not consumed')

    ---------------------------------------------------------------------
    t.describe('unequipping and equipping by weapon id')

    Inventory.add(soldier, 'ammo.9mm', 12)
    t.ok(Inventory.equipWeapon(soldier, 'pistol'), 'a weapon can be found by id')
    t.ok(Inventory.equipWeapon(soldier, 'railgun') == nil,
         'and one the bag does not hold is refused')

    t.ok(Inventory.unequip(soldier), 'unequipping works')
    t.eq(Weapons.equipped(soldier), nil, 'and clears the weapon component')
    t.eq(Inventory.equipped(soldier), nil, 'and the bag\'s record')

    -- Removing the equipped item unequips it rather than leaving a phantom gun.
    Inventory.equipWeapon(soldier, 'pistol')
    t.eq(Weapons.equipped(soldier), 'pistol', 'armed again')
    Inventory.remove(soldier, 'pistol', 1)
    t.eq(Weapons.equipped(soldier), nil,
         'and losing the item disarms, rather than leaving a gun with no item')

    ---------------------------------------------------------------------
    t.describe('an item this build does not know is carried, not eaten')

    local stranger = bag(4)
    local strangeAdded = Inventory.add(stranger, 'artifact.unknown', 1)
    t.eq(strangeAdded, 1, 'an undefined item still goes in')
    t.eq(Inventory.count(stranger, 'artifact.unknown'), 1, 'and can be counted')
    t.ok(stranger:get('inventory').contents:find('artifact.unknown'),
         'and survives to the save file, because losing it on a version change '
         .. 'is exactly the failure this module exists to prevent')

    ---------------------------------------------------------------------
    t.describe('pickups can be found in the world')

    local scatter = { Inventory.spawnPickup('brick', 1, 5.0, 5.0),
                      Inventory.spawnPickup('brick', 1, 9.0, 9.0),
                      Entity.new{ kind = 'wall', x = 5.1, y = 5.1 } }
    local near = Inventory.pickupsNear(scatter, 5.0, 5.0, 1)
    t.eq(#near, 1, 'only the pickup in range comes back')
    t.eq(near[1], scatter[1], 'and it is the right one')

    t.ok(Inventory.spawnPickup('brick', 0, 1, 1) == nil, 'a pickup of zero is refused')
    t.ok(Inventory.spawnPickup('brick', 1, 0 / 0, 1) == nil, 'and one at a NaN position')

    ---------------------------------------------------------------------
    t.describe('resizing a bag never eats what is in it')

    -- attach() re-decodes the contents string against the new capacity, and the
    -- decoder drops entries that fall outside it. Shrinking therefore used to
    -- destroy whatever sat above the new size, silently -- the one operation
    -- that broke this module's own "nothing vanishes" rule.
    local shrink = Entity.new{ x = 0, y = 0 }
    Inventory.attach(shrink, { capacity = 8 })
    Inventory.add(shrink, 'shell', 3)
    Inventory.add(shrink, 'medkit', 1)
    local bag = Inventory.of(shrink)

    -- Find the highest occupied slot by asking, rather than assuming where an
    -- add landed. Stack sizes decide that, and a test that hard-codes slot
    -- numbers breaks the day an item definition changes.
    local highest = 0
    for i = bag.capacity, 1, -1 do
        if Inventory.get(shrink, i) then highest = i; break end
    end
    t.ok(highest > 0, 'something is in the bag')

    local shellsBefore  = Inventory.count(shrink, 'shell')
    local medkitsBefore = Inventory.count(shrink, 'medkit')

    -- Ask for a capacity below the occupied high-water mark.
    local _, kept = Inventory.attach(shrink, { capacity = highest - 1 })

    t.eq(Inventory.count(shrink, 'shell'), shellsBefore,
         'shrinking the bag destroys nothing')
    t.eq(Inventory.count(shrink, 'medkit'), medkitsBefore, 'on either item')
    t.ok(bag.capacity >= highest,
         'the capacity is held at the occupied high-water mark instead')
    t.ok(kept ~= nil and kept > 0,
         'and the caller is told how many slots it did not get')

    -- A shrink that costs nothing is honoured in full.
    local roomy = Entity.new{ x = 0, y = 0 }
    Inventory.attach(roomy, { capacity = 10 })
    Inventory.add(roomy, 'shell', 1)
    local _, free = Inventory.attach(roomy, { capacity = 4 })
    t.eq(Inventory.of(roomy).capacity, 4, 'a shrink with nothing in the way is honoured')
    t.eq(free, nil, 'and reports no cost')

    -- Growing is always free.
    local grown = Entity.new{ x = 0, y = 0 }
    Inventory.attach(grown, { capacity = 4 })
    Inventory.add(grown, 'shell', 2)
    local _, grewCost = Inventory.attach(grown, { capacity = 16 })
    t.eq(Inventory.of(grown).capacity, 16, 'growing works')
    t.eq(grewCost, nil, 'and costs nothing')
    t.eq(Inventory.count(grown, 'shell'), 2, 'with contents intact')

    Game.reset()
    Entity.clearArchetypes()
end
