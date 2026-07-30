--[[
    meatray.ui.panel_inventory — the bag, and a bench to exercise it on.

    The model in meatray/game/inventory.lua has been built and asserted for a
    while; this is the first thing that looks at it. It is deliberately not a
    read-only viewer: the interesting half of that model is what it does when
    something does NOT fit, and a panel that can only display a bag can never
    show you an overflow, a refused pickup or a half-drop.

    So the centre is a bag you can act on:

        slots       every slot in the bag, empties included, click to select
        equip       the selected slot, which drives the weapon component
        drop        into a floor pile beside the grid, and take it back again
        move        one slot onto another: merge, part-move or swap
        add         any item this build defines, in any quantity

    and the three numbers of every add are printed, because `added + leftover ==
    asked` is the model's entire promise and this is the only place a person can
    watch it hold.

    THE SUBJECT. By default the panel owns a bench entity it created itself, so
    the tool works with no game running. `Panel.new{ subject = entity }` points it
    at a live one instead — a player, an NPC, a container — and everything below
    then acts on that bag for real. A caller that supplies a live subject should
    also supply `emit`, or drops land in this panel's floor list rather than in
    the world.

    WHAT IS NOT HERE. Every decision about what a slot SAYS lives in
    meatray.ui.inventory_view, which requires nothing but the model and is
    unit-tested. That split is not tidiness: meatray/ui/core.lua needs LOVE's
    utf8 module and cannot load headless, so logic left in this file cannot be
    tested at all — and the bug that taught this project the lesson (a server row
    reading `maxPlayers` where every backend emits `max`) threw nothing and
    booted clean. This file is layout, input and drawing, and nothing else.

    Panel contract, per meatray.ui.shell: `id`, `title`, `draw(rect, shell)`, and
    optionally `drawSidebar`, `drawInspector`, `update`, `keypressed`, `attach`.
]]

local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local Entity = require('meatray.sim.entity')
local Inventory = require('meatray.game.inventory')
local View = require('meatray.ui.inventory_view')

local Panel = {}
Panel.__index = Panel

local floor, max, min = math.floor, math.max, math.min

local CELL_W = 116
local CELL_H = 44
local GAP = 6

---------------------------------------------------------------------------

function Panel.new(opts)
    opts = opts or {}

    local self = setmetatable({
        id = 'inventory',
        title = 'Inventory',

        selected = 1,
        moveFrom = nil,        -- the slot a move is staged from, if any
        itemIndex = 1,
        choices = {},

        addCount = '1',
        capacityText = '',

        floor = {},            -- pickups this panel has dropped
        floorIndex = 1,
        lastAdd = nil,

        -- Where a drop goes when the subject is a live entity in a real world.
        -- Without it the pickup lands in this panel's own floor list, which is
        -- right for the bench and wrong for a game.
        emit = opts.emit,
    }, Panel)

    self.owned = opts.subject == nil
    self.subject = opts.subject or self:makeBench(opts.capacity)
    self.capacityText = tostring(Inventory.capacity(self.subject))

    return self
end

-- The bench bag. Its own entity, so the panel is useful with no world loaded and
-- cannot disturb one that is.
function Panel:makeBench(capacity)
    local e = Entity.new{ kind = 'inventory.bench', x = 0, y = 0 }
    Inventory.attach(e, { capacity = capacity or Inventory.DEFAULT_CAPACITY })
    return e
end

-- Points the panel at a different bag. A game hands it a player; the editor
-- hands it back the bench.
function Panel:setSubject(e)
    self.subject = e or self:makeBench()
    self.owned = (e == nil)
    self.selected = 1
    self.moveFrom = nil
    self.capacityText = tostring(Inventory.capacity(self.subject))
    return self.subject
end

function Panel:attach(shell)
    if self.shell == shell then return end
    self.shell = shell
    self:refresh()

    if shell then
        shell:log(('inventory: %d item%s defined, bench holds %d slots')
            :format(#self.choices, #self.choices == 1 and '' or 's',
                    Inventory.capacity(self.subject)))
        if #self.choices == 0 then
            -- An empty pick list is otherwise indistinguishable from a broken
            -- panel. It means the project defined no items, not that the tool
            -- failed to find them.
            shell:warn('inventory: this build defines no items (Inventory.defineItem)')
        end
    end
end

function Panel:log(text, level)
    if self.shell then self.shell:log(text, level) end
end

-- Item definitions are global and a hot reload rebuilds them, so the pick list
-- is gathered rather than cached forever.
function Panel:refresh()
    self.choices = View.itemChoices()
    self.itemIndex = max(1, min(self.itemIndex, max(1, #self.choices)))
    self.selected = max(1, min(self.selected, max(1, Inventory.capacity(self.subject))))
    if self.moveFrom and self.moveFrom > Inventory.capacity(self.subject) then
        self.moveFrom = nil
    end
end

function Panel:selectedSlot()
    return View.slot(self.subject, self.selected)
end

---------------------------------------------------------------------------
-- Actions. Each one reports what the model answered, including the refusals:
-- an action that silently does nothing is the shape of a tool nobody trusts.
---------------------------------------------------------------------------

function Panel:add(id, count)
    local asked = floor(max(0, tonumber(count) or 0))
    local added, leftover, reason = Inventory.add(self.subject, id, asked)

    self.lastAdd = View.describeAdd(id, asked, added, leftover, reason)

    local level = 'ok'
    if View.addBrokeInvariant(asked, added, leftover, reason) then
        level = 'error'
    elseif leftover > 0 then
        level = 'warn'
    end
    self:log(self.lastAdd, level)

    return added, leftover
end

function Panel:equipSelected()
    local state, err = Inventory.equip(self.subject, self.selected)
    if state then
        local slot = self:selectedSlot()
        self:log(('equipped slot %d: %s'):format(self.selected,
                 tostring(slot and slot.name)), 'ok')
    else
        -- 'not a weapon', 'empty slot', 'unknown weapon: x'. The last one is the
        -- useful failure: the item declares a weapon this build never defined.
        self:log(('cannot equip slot %d: %s'):format(self.selected, tostring(err)), 'warn')
    end
    return state
end

function Panel:unequip()
    Inventory.unequip(self.subject)
    self:log('unequipped', 'ok')
end

function Panel:drop(count)
    local slot = self:selectedSlot()
    if not slot or slot.empty then return nil end

    local ctx = { x = self.subject.x or 0, y = self.subject.y or 0 }
    if self.emit then ctx.emit = self.emit else ctx.entities = self.floor end

    local pickup, err, taken = Inventory.drop(self.subject, self.selected, count, ctx)
    if not pickup then
        self:log(('drop refused: %s'):format(tostring(err)), 'warn')
        return nil
    end

    self:log(('dropped %s x%d from slot %d')
        :format(tostring(slot.id), taken or 0, self.selected), 'ok')
    return pickup
end

-- Takes a floor pickup back. The overflow rule is the thing to watch here: what
-- does not fit stays on the floor and the entity survives, so a bag with one
-- free slot takes part of a pile and leaves the rest.
function Panel:take(index)
    local pickup = self.floor[index]
    if not pickup then return 0 end

    local taken, remaining, reason = Inventory.pickup(self.subject, pickup)
    if taken > 0 then
        self:log(('took %d, %d left on the floor'):format(taken, remaining),
                 remaining > 0 and 'warn' or 'ok')
    else
        self:log(('took nothing: %s'):format(tostring(reason)), 'warn')
    end

    self:prune()
    return taken
end

-- Drops the panel's references to pickups the model marked dead. It marks them
-- rather than removing them, because it does not own the caller's entity list.
function Panel:prune()
    local kept = {}
    for _, p in ipairs(self.floor) do
        if not p.dead then kept[#kept + 1] = p end
    end
    self.floor = kept
    self.floorIndex = max(1, min(self.floorIndex, max(1, #self.floor)))
end

function Panel:completeMove()
    local from, to = self.moveFrom, self.selected
    self.moveFrom = nil
    if not from then return false end

    local ok, reason = Inventory.move(self.subject, from, to)
    if ok then
        self:log(('moved slot %d onto slot %d'):format(from, to), 'ok')
    else
        -- 'destination stack is full' and 'a partial move onto another item' are
        -- both refusals that protect the destination rather than errors.
        self:log(('move %d -> %d refused: %s'):format(from, to, tostring(reason)), 'warn')
    end
    return ok
end

function Panel:resize(capacity)
    local target = tonumber(capacity)
    if not target then
        self:log('capacity must be a number', 'warn')
        return false
    end
    target = floor(target)

    -- The one operation in the model that really does destroy items: attach
    -- re-decodes the contents string against the new capacity and the decoder
    -- drops out-of-range entries, with no leftover returned and nothing logged.
    -- Refusing beats a silent deletion; the items can be moved down first.
    local lost = View.lostByResize(self.subject, target)
    if #lost > 0 then
        self:log(('refused: shrinking to %d would destroy %s')
            :format(target, View.describeLoss(lost)), 'warn')
        return false
    end

    Inventory.attach(self.subject, { capacity = target })
    self.capacityText = tostring(Inventory.capacity(self.subject))
    self:refresh()
    self:log(('capacity is now %d'):format(Inventory.capacity(self.subject)), 'ok')
    return true
end

---------------------------------------------------------------------------
-- The grid
---------------------------------------------------------------------------

function Panel:drawGrid(rect)
    local slots = View.slots(self.subject)

    if #slots == 0 then
        UI.text('this entity has no inventory component', rect.x, rect.y, UI.theme.warn)
        return
    end

    local place, contentH = Rect.grid(rect.w - UI.metrics.scrollbarWidth,
                                      CELL_W, CELL_H, GAP, #slots)

    local offset = UI.beginScroll('inventory/grid', rect.x, rect.y, rect.w, rect.h, contentH)

    for i, slot in ipairs(slots) do
        local dx, dy = place(i)
        local x, y = rect.x + dx, rect.y + dy

        -- Drawing is in content space (the scroll region translated the canvas)
        -- and hit testing is in screen space. Passing content coordinates to
        -- UI.hit is how a scrolled grid selects the cell that used to be under
        -- the cursor.
        local over, _, _, activated = UI.hit('inventory/slot/' .. i,
                                             x, y - offset, CELL_W, CELL_H)

        UI.rect(x, y, CELL_W, CELL_H, UI.theme.bg)

        if slot.empty then
            UI.text(tostring(i), x + 4, y + 3, UI.theme.textDim)
        else
            -- A fill bar behind the text, so how full a stack is reads without
            -- doing the division. Only for things that stack: a bar that is
            -- always full carries no information.
            if slot.stack > 1 then
                UI.rect(x, y + CELL_H - 5, CELL_W * slot.fill, 5,
                        slot.over and UI.theme.danger or UI.theme.accentDim)
            end

            UI.text(tostring(i), x + 4, y + 3, UI.theme.textDim)
            UI.textClipped(slot.name, x + 20, y + 3, CELL_W - 24,
                           slot.unknown and UI.theme.warn or UI.theme.text)
            UI.textClipped(slot.countText, x + 20, y + 19, CELL_W - 24,
                           slot.over and UI.theme.danger or UI.theme.textDim)

            if slot.weapon then
                UI.rect(x + CELL_W - 8, y + 3, 5, 5, UI.theme.ok)
            elseif slot.ammoFor then
                UI.rect(x + CELL_W - 8, y + 3, 5, 5, UI.theme.accent)
            end
        end

        -- The border carries the state, which is what makes the equipped slot
        -- and the staged move findable in a grid of two hundred and fifty six.
        local border = UI.theme.border
        if slot.equipped then border = UI.theme.ok
        elseif i == self.moveFrom then border = UI.theme.warn
        elseif over then border = UI.theme.hover end

        UI.rect(x, y, CELL_W, CELL_H, border, 'line')
        if i == self.selected then
            UI.rect(x - 1, y - 1, CELL_W + 2, CELL_H + 2, UI.theme.accent, 'line')
        end

        if activated then self.selected = i end
    end

    UI.endScroll('inventory/grid', rect.x, rect.y, rect.w, rect.h, contentH)
end

---------------------------------------------------------------------------
-- The floor
---------------------------------------------------------------------------

function Panel:drawFloor(rect)
    local rowH = UI.metrics.rowHeight + 2
    local y = rect.y

    UI.text(('Floor (%d)'):format(#self.floor), rect.x, y, UI.theme.textDim)
    y = y + rowH

    if #self.floor == 0 then
        UI.textClipped('nothing dropped', rect.x, y, rect.w, UI.theme.textDim)
        return
    end

    local labels = {}
    for i, pickup in ipairs(self.floor) do
        labels[i] = View.describePickup(pickup) or '?'
    end

    local listH = max(rowH, rect.y + rect.h - y - rowH - 4)
    self.floorIndex = UI.list('inventory/floor', labels, self.floorIndex,
                              rect.x, y, rect.w, listH)
    y = y + listH + 4

    if UI.button('inventory/take', 'Take', rect.x, y, { w = rect.w - 4 }) then
        self:take(self.floorIndex)
    end
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function Panel:draw(rect, shell)
    local head, body = Rect.split(rect, 'top', UI.metrics.rowHeight + 10)

    local slot = self:selectedSlot()
    local summary = View.summary(self.subject)
    local holding = slot ~= nil and not slot.empty

    local cursor = head.x
    local function control(id, label, enabled, action)
        local pressed, w = UI.button('inventory/' .. id, label, cursor, head.y,
                                     { disabled = not enabled })
        if pressed then action() end
        cursor = cursor + w + 4
    end

    control('equip', 'Equip', holding and slot.weapon ~= nil,
            function() self:equipSelected() end)
    control('unequip', 'Unequip',
            summary ~= nil and (summary.equipped ~= nil or summary.equippedStale),
            function() self:unequip() end)
    control('drop1', 'Drop 1', holding, function() self:drop(1) end)
    control('dropall', 'Drop all', holding, function() self:drop(nil) end)

    -- Two clicks, because a move needs two slots and the grid selects one at a
    -- time. Staging shows as a warn-coloured border on the source cell.
    if self.moveFrom then
        control('move', ('Move %d -> %d'):format(self.moveFrom, self.selected), true,
                function() self:completeMove() end)
        control('movecancel', 'Cancel', true, function() self.moveFrom = nil end)
    else
        control('move', 'Move from...', holding, function() self.moveFrom = self.selected end)
    end

    control('clear', 'Clear bag', summary ~= nil and summary.used > 0, function()
        -- Named as destructive rather than done quietly: this empties the bag
        -- with no floor pickup and no leftover, which is the one thing the rest
        -- of the model refuses to do.
        local used = summary.used
        Inventory.clear(self.subject)
        self:log(('cleared the bag: %d slot%s emptied, nothing dropped')
            :format(used, used == 1 and '' or 's'), 'warn')
    end)

    UI.textClipped(View.summaryLine(self.subject), cursor + 8, head.y + 4,
                   max(20, head.x + head.w - cursor - 8), UI.theme.textDim)

    -- The floor lives beside the grid when there is room for it, and is simply
    -- absent when there is not, rather than squeezing both into nothing.
    local gridArea, floorRect = body, nil
    if body.w > 430 then
        floorRect, gridArea = Rect.split(body, 'right', floor(min(210, body.w * 0.32)))
        floorRect = Rect.inset(floorRect, 6, 2)
        gridArea = Rect.inset(gridArea, 0, 2)
    end

    -- The replicated string, verbatim, under the grid. It is the authoritative
    -- state — the slot array above it is only ever a decode of this — so seeing
    -- the two disagree is the fastest way to catch a cache that did not
    -- invalidate.
    local footer, gridRect = Rect.split(gridArea, 'bottom', 34)

    self:drawGrid(gridRect, shell)

    UI.text('contents', footer.x, footer.y, UI.theme.textDim)
    local contents = summary and summary.contents or ''
    UI.textClipped(contents == '' and '(empty)' or contents,
                   footer.x, footer.y + 15, footer.w, UI.theme.text)

    if floorRect then self:drawFloor(floorRect, shell) end
end

---------------------------------------------------------------------------
-- Sidebar: what this build defines, and how much of it to put in
---------------------------------------------------------------------------

function Panel:drawSidebar(rect, shell)
    local rowH = UI.metrics.rowHeight + 2
    local w = rect.w - 4
    local y = rect.y

    UI.text(('Items (%d)'):format(#self.choices), rect.x, y, UI.theme.textDim)
    y = y + rowH

    if #self.choices == 0 then
        UI.textClipped('this build defines none', rect.x, y, w, UI.theme.warn)
        y = y + rowH
        UI.textClipped('Inventory.defineItem(id, spec)', rect.x, y, w, UI.theme.textDim)
        return
    end

    local labels = {}
    for i, choice in ipairs(self.choices) do labels[i] = choice.label end

    local listH = max(rowH * 3, min(rowH * 8, rect.h * 0.4))
    self.itemIndex = UI.list('inventory/items', labels, self.itemIndex,
                             rect.x, y, w, listH)
    y = y + listH + 6

    local choice = self.choices[self.itemIndex]

    UI.text('count', rect.x, y, UI.theme.textDim)
    y = y + 16
    local committed
    self.addCount, committed = UI.textField('inventory/count', self.addCount,
                                            rect.x, y, w)
    y = y + rowH + 4

    local wants = floor(max(0, tonumber(self.addCount) or 0))

    -- How much of it would actually fit, before committing to putting it in.
    -- This is the number the model exposes for exactly this question, and it is
    -- what turns "Add" from a guess into a decision.
    if choice then
        local room = Inventory.room(self.subject, choice.id)
        UI.labelValue('room for', room, rect.x, y, w,
                      { color = (wants > room) and UI.theme.warn or UI.theme.textDim })
        y = y + rowH
    end

    if (UI.button('inventory/add', 'Add', rect.x, y, { w = w, disabled = choice == nil })
        or (committed and choice)) and choice then
        self:add(choice.id, wants)
    end
    y = y + rowH + 2

    if choice and UI.button('inventory/fill', 'Fill bag', rect.x, y, { w = w }) then
        -- Deliberately asks for more than can fit: the leftover line is the
        -- point of the button.
        self:add(choice.id, Inventory.room(self.subject, choice.id) + 1)
    end
    y = y + rowH + 8

    ---------------------------------------------------------------------
    UI.text('Capacity', rect.x, y, UI.theme.textDim)
    y = y + rowH

    self.capacityText = UI.textField('inventory/capacity', self.capacityText,
                                     rect.x, y, w)
    y = y + rowH + 2

    -- Says in advance what shrinking would cost, because the model does not:
    -- attach re-decodes against the new capacity and the decoder drops
    -- out-of-range slots without returning a leftover.
    local lost = View.lostByResize(self.subject, tonumber(self.capacityText))
    if UI.button('inventory/resize', 'Set capacity', rect.x, y,
                 { w = w, disabled = #lost > 0 }) then
        self:resize(self.capacityText)
    end
    y = y + rowH

    if #lost > 0 then
        UI.textClipped(('would destroy %d slot%s'):format(#lost, #lost == 1 and '' or 's'),
                       rect.x, y, w, UI.theme.danger)
        y = y + 16
        UI.textClipped(View.describeLoss(lost), rect.x, y, w, UI.theme.danger)
        y = y + 16
    end
    y = y + 6

    ---------------------------------------------------------------------
    if UI.button('inventory/rescan', 'Reread items', rect.x, y, { w = w }) then
        self:refresh()
        self:log(('%d item%s defined'):format(#self.choices,
                 #self.choices == 1 and '' or 's'))
    end
    y = y + rowH + 2

    if not self.owned and UI.button('inventory/bench', 'Back to bench', rect.x, y, { w = w }) then
        self:setSubject(nil)
        self:log('inventory panel is back on its own bench bag')
    end
end

---------------------------------------------------------------------------
-- Inspector: the selected slot, and the bag it is in
---------------------------------------------------------------------------

function Panel:drawInspector(rect, shell)
    local summary = View.summary(self.subject)
    local y = rect.y

    if not summary then
        UI.text('no inventory component', rect.x, y, UI.theme.warn)
        return
    end

    y = y + UI.labelValue('bag', self.owned and 'bench' or (self.subject.kind or 'entity'),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('slots', ('%d/%d'):format(summary.used, summary.capacity),
                          rect.x, y, rect.w,
                          { color = summary.full and UI.theme.warn or nil })
    y = y + UI.labelValue('free', summary.free, rect.x, y, rect.w)

    if summary.equipped then
        y = y + UI.labelValue('equipped', ('slot %d  %s'):format(summary.equipped,
                                                                 tostring(summary.equippedName)),
                              rect.x, y, rect.w, { color = UI.theme.ok })
        local reserve, weaponId = View.equippedReserve(self.subject)
        y = y + UI.labelValue('weapon', tostring(weaponId), rect.x, y, rect.w)
        -- Read with dryRun: the supplier consumes what it reports otherwise, and
        -- a draw path calling it for real would empty the bag every frame.
        y = y + UI.labelValue('reserve', reserve, rect.x, y, rect.w,
                              { color = reserve == 0 and UI.theme.warn or nil })
    elseif summary.equippedStale then
        -- `equipped` and `contents` are separate replicated fields, so a
        -- snapshot can land one without the other. Worth showing rather than
        -- rounding down to "nothing equipped".
        y = y + UI.labelValue('equipped', ('slot %s is empty'):format(
                                  tostring(summary.equippedIndex)),
                              rect.x, y, rect.w, { color = UI.theme.danger })
    else
        y = y + UI.labelValue('equipped', 'nothing', rect.x, y, rect.w)
    end

    y = y + 8

    ---------------------------------------------------------------------
    local slot = self:selectedSlot()
    if not slot then
        UI.text('no slot selected', rect.x, y, UI.theme.textDim)
        return
    end

    UI.text(('Slot %d'):format(slot.index), rect.x, y, UI.theme.textDim)
    y = y + UI.metrics.rowHeight

    if slot.empty then
        y = y + UI.labelValue('holds', 'nothing', rect.x, y, rect.w)
    else
        y = y + UI.labelValue('item', slot.id, rect.x, y, rect.w)
        y = y + UI.labelValue('name', slot.name, rect.x, y, rect.w)
        y = y + UI.labelValue('count', slot.countText, rect.x, y, rect.w,
                              { color = slot.over and UI.theme.danger
                                        or (slot.full and UI.theme.warn or nil) })
        if slot.weapon then
            y = y + UI.labelValue('equips', slot.weapon, rect.x, y, rect.w)
        end
        if slot.ammoFor then
            y = y + UI.labelValue('reloads', slot.ammoFor, rect.x, y, rect.w)
            y = y + UI.labelValue('in bag', View.reserveFor(self.subject, slot.ammoFor),
                                  rect.x, y, rect.w)
        end
        if slot.unknown then
            -- Not an error. The model carries an item this build does not define
            -- on purpose, so that a save written by a build with one more item in
            -- it does not lose that item on load.
            y = y + UI.labelValue('defined', 'not in this build', rect.x, y, rect.w,
                                  { color = UI.theme.warn })
        end
        if slot.over then
            y = y + UI.labelValue('over cap', ('%d > %d'):format(slot.count, slot.stack),
                                  rect.x, y, rect.w, { color = UI.theme.danger })
        end
    end

    if self.moveFrom then
        y = y + 8
        UI.textClipped(('move staged from slot %d'):format(self.moveFrom),
                       rect.x, y, rect.w, UI.theme.warn)
        y = y + 16
    end

    if self.lastAdd then
        y = y + 8
        UI.text('Last add', rect.x, y, UI.theme.textDim)
        y = y + UI.metrics.rowHeight
        UI.textClipped(self.lastAdd, rect.x, y, rect.w, UI.theme.text)
    end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

function Panel:update(dt)
    -- A pickup emptied by a take is marked dead rather than removed, because the
    -- model does not own this list. Dropping the reference here keeps the floor
    -- list honest without the model reaching into it.
    if #self.floor > 0 then self:prune() end
end

function Panel:keypressed(key, shell)
    -- Function keys only, deliberately. The shell forwards every key to the
    -- active panel even while a text field owns the keyboard, so a letter
    -- shortcut here would also fire while someone is typing a capacity.
    if key == 'f5' then
        self:refresh()
        return true
    end
    return false
end

return Panel
