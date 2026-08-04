--[[
    Map-editor undo. Snapshot-based over the text format, so undo can never
    restore a state that would not save. One entry per paint stroke; redo
    survives undo and dies on the next edit; a loaded file starts fresh
    history; the cap holds. Headless: the panel takes an injected fs, and
    nothing here draws.
]]

return function(t)
    -- meatray.ui.core hard-requires the utf8 module LÖVE provides (LuaJIT has
    -- none; Lua 5.4 has its own). A minimal ASCII stand-in lets the panel's
    -- EDIT LOGIC run headless; the text widgets that really need utf8 are not
    -- exercised here — they are host-side and the selftest's problem.
    if not package.loaded['utf8'] and not pcall(require, 'utf8') then
        package.loaded['utf8'] = {
            len = function(s) return #s end,
            char = string.char,
            codes = function(s)
                local i = 0
                return function()
                    i = i + 1
                    if i <= #s then return i, s:byte(i) end
                end
            end,
            offset = function(s, n, i)
                i = i or (n < 0 and #s + 1 or 1)
                local pos = i + n
                if pos < 1 or pos > #s + 1 then return nil end
                return pos
            end,
        }
    end

    local Panel = require('meatray.ui.panel_map')
    local Map = require('meatray.sim.map')

    local fakeFs = {
        read = function() return nil end,
        write = function() return true end,
        getInfo = function() return nil end,
        getDirectoryItems = function() return {} end,
    }

    local function tileAt(p, tx, ty)
        return p.map.tiles[ty] and p.map.tiles[ty][tx] or 0
    end

    ---------------------------------------------------------------------
    t.describe('a stroke is one undo entry')

    local p = Panel.new{ fs = fakeFs }
    p.tool = 2                       -- a wall brush
    t.eq(#p.undoStack, 0, 'fresh panel, empty history')

    -- One stroke, three tiles: mousereleased ends it.
    p:paint(3, 3); p:paint(4, 3); p:paint(5, 3)
    p:mousereleased()
    t.eq(#p.undoStack, 1, 'three painted tiles in one stroke = one entry')
    t.ok(tileAt(p, 4, 3) ~= 0, 'the wall is there')

    -- A second stroke elsewhere.
    p:paint(8, 8)
    p:mousereleased()
    t.eq(#p.undoStack, 2, 'a new stroke opens a new entry')

    ---------------------------------------------------------------------
    t.describe('undo steps back, redo steps forward, edits kill redo')

    t.ok(p:undo(), 'undo succeeds')
    t.eq(tileAt(p, 8, 8), 0, 'the second stroke is gone')
    t.ok(tileAt(p, 4, 3) ~= 0, 'the first survives')
    t.eq(#p.redoStack, 1, 'the undone state parked on redo')

    t.ok(p:redo(), 'redo succeeds')
    t.ok(tileAt(p, 8, 8) ~= 0, 'the second stroke is back')

    p:undo()
    p:paint(10, 10); p:mousereleased()
    t.eq(#p.redoStack, 0, 'a fresh edit clears the redo branch')
    t.ok(not p:redo(), 'and redo now honestly refuses')

    t.ok(p:undo() and p:undo(), 'walk all the way back')
    t.eq(tileAt(p, 3, 3), 0, 'blank again')
    t.ok(not p:undo(), 'past the bottom, undo refuses instead of inventing')

    ---------------------------------------------------------------------
    t.describe('dirty and selections behave across a restore')

    local q = Panel.new{ fs = fakeFs }
    q.tool = 2
    q:paint(2, 2); q:mousereleased()
    q.dirty = false                  -- pretend it was just saved
    q:undo()
    t.ok(q.dirty, 'stepping the map changes it, so it is dirty again')

    -- An entity selection is a reference into the map; a restore clears it.
    local r = Panel.new{ fs = fakeFs }
    r.tool = 1                       -- spawn? tool 1 is spawn per TOOLS order
    for i, tool in ipairs(Panel.TOOLS) do
        if tool.id == 'entity' then r.tool = i end
    end
    r:paint(5, 5); r:mousereleased()
    t.ok(r.selectedEntity, 'placing an entity selects it')
    r:undo()
    t.eq(r.selectedEntity, nil, 'undo cleared the dangling selection')
    t.eq(#(r.map.entities or {}), 0, 'and the entity itself')

    ---------------------------------------------------------------------
    t.describe('trigger operations are undoable')

    local s = Panel.new{ fs = fakeFs }
    for i, tool in ipairs(Panel.TOOLS) do
        if tool.id == 'trigger' then s.tool = i end
    end
    s.triggerGraph = 'g'
    s:triggerClick(3, 3)
    s:triggerClick(5, 5)
    t.eq(#(s.map.triggers or {}), 1, 'two corners place a volume')
    t.eq(#s.undoStack, 1, 'as one undo entry')
    s:undo()
    t.eq(#(s.map.triggers or {}), 0, 'undone')

    ---------------------------------------------------------------------
    t.describe('the cap holds and loadFile starts fresh history')

    local c = Panel.new{ fs = fakeFs }
    c.tool = 2
    for i = 1, Panel.UNDO_LIMIT + 10 do
        c:paint(1 + (i % 20), 1 + math.floor(i / 20))
        c:mousereleased()
    end
    t.eq(#c.undoStack, Panel.UNDO_LIMIT, 'the stack never exceeds the cap')

    local loaded = Panel.new{ fs = {
        read = function() return Map.serialize(Map.blank(8, 8)) end,
        write = function() return true end,
        getInfo = function() return nil end,
        getDirectoryItems = function() return {} end,
    } }
    loaded.tool = 2
    loaded:paint(2, 2); loaded:mousereleased()
    t.ok(loaded:loadFile('whatever.map'), 'a file loads')
    t.eq(#loaded.undoStack, 0, 'a file boundary is a history boundary')
    t.eq(#loaded.redoStack, 0, 'both directions')
end
