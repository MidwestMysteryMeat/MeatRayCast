--[[
    meatray.game.menu — the shell's screen stack (G1).

    Every model a menu needs has existed for waves: options:menuRows() since
    A3, campaign since A1, session since A8. What never existed is the thing
    that lets a player REACH them — a title screen, a screen stack, a
    selection cursor, a bind-capture state. This is that thing, as a model:
    screens are plain data the game pushes, navigation is a handful of verbs,
    and what a verb DID comes back as a result the caller acts on. Nothing is
    drawn here and no key names appear here; main.lua owns both.

        local menu = Menu.new()
        menu:push{
            id = 'title', title = 'MEATRAYCAST',
            rows = {
                { id = 'new',     label = 'New Game',  kind = 'action' },
                { id = 'options', label = 'Options',   kind = 'action' },
                { id = 'quit',    label = 'Quit',      kind = 'action' },
            },
        }
        menu:navigate(1)                  -- down one row (wraps)
        local act = menu:activate()       -- { kind='action', screen='title', row=<row> }
        menu:back()                       -- pop; false at the bottom

    Row kinds and what activate/adjust mean for each:
      action   activate returns the row: the caller does the thing
      toggle   activate (or adjust) returns { kind='set', value = not v }
      slider   adjust(dir) returns { kind='set', value = v +/- step }
      choice   adjust(dir) returns { kind='set', value = <next choice> }
      bind     activate returns { kind='capture' } and the menu enters
               capture; the next feedKey() returns { kind='set', value=key }
      text     activate enters text entry; feedText()/feedKey() edit it;
               return produces { kind='submit', value = <string> }

    The options screen needs no adapter at all: options:menuRows() rows carry
    exactly these kinds, which is why this file adds none of its own.

    HEADLESS: pure Lua.
]]

local Menu = {}
local MenuMT = {}
MenuMT.__index = MenuMT

function Menu.new()
    return setmetatable({
        stack = {},           -- bottom..top screens
        capture = nil,        -- 'bind' | 'text' when a row is eating input
    }, MenuMT)
end

---------------------------------------------------------------------------
-- Stack
---------------------------------------------------------------------------

-- screen: { id, title, rows = { {id, label, kind, value, min, max, step,
--           choices, ...}, ... }, selected (optional starting row) }
function MenuMT:push(screen)
    screen = screen or {}
    screen.rows = screen.rows or {}
    screen.selected = screen.selected or 1
    self.stack[#self.stack + 1] = screen
    self.capture = nil
    return screen
end

function MenuMT:pop()
    if #self.stack == 0 then return nil end
    self.capture = nil
    return table.remove(self.stack)
end

-- Back is pop-with-a-floor: the bottom screen stays, and false says "this
-- press was not consumed" so the caller can close the whole shell instead.
function MenuMT:back()
    if self.capture then
        self.capture = nil
        return true
    end
    if #self.stack > 1 then
        self:pop()
        return true
    end
    return false
end

function MenuMT:current()
    return self.stack[#self.stack]
end

function MenuMT:depth()
    return #self.stack
end

function MenuMT:isOpen()
    return #self.stack > 0
end

function MenuMT:close()
    self.stack = {}
    self.capture = nil
end

function MenuMT:selectedRow()
    local screen = self:current()
    return screen and screen.rows[screen.selected]
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

function MenuMT:navigate(dir)
    local screen = self:current()
    if not screen or #screen.rows == 0 or self.capture then return end
    local n = #screen.rows
    screen.selected = ((screen.selected - 1 + (dir or 1)) % n) + 1
    return screen.rows[screen.selected]
end

-- Left/right on the selected row. Sliders step, toggles flip, choices cycle;
-- everything else ignores it.
function MenuMT:adjust(dir)
    local screen, row = self:current(), self:selectedRow()
    if not row or self.capture then return nil end
    dir = dir or 1

    if row.kind == 'slider' then
        local step = row.step or 0.05
        local v = (tonumber(row.value) or 0) + dir * step
        if row.min and v < row.min then v = row.min end
        if row.max and v > row.max then v = row.max end
        return { kind = 'set', screen = screen.id, row = row, value = v }
    end
    if row.kind == 'toggle' then
        return { kind = 'set', screen = screen.id, row = row, value = not row.value }
    end
    if row.kind == 'choice' then
        local list = row.choices or {}
        if #list == 0 then return nil end
        local at = 1
        for i = 1, #list do
            if list[i] == row.value then at = i break end
        end
        local nextAt = ((at - 1 + dir) % #list) + 1
        return { kind = 'set', screen = screen.id, row = row, value = list[nextAt] }
    end
    return nil
end

-- Enter / fire on the selected row.
function MenuMT:activate()
    local screen, row = self:current(), self:selectedRow()
    if not row or self.capture then return nil end

    if row.kind == 'action' then
        return { kind = 'action', screen = screen.id, row = row }
    end
    if row.kind == 'toggle' or row.kind == 'choice' then
        return self:adjust(1)
    end
    if row.kind == 'bind' then
        self.capture = 'bind'
        return { kind = 'capture', screen = screen.id, row = row }
    end
    if row.kind == 'text' then
        self.capture = 'text'
        row.value = row.value or ''
        return { kind = 'capture', screen = screen.id, row = row }
    end
    return nil
end

function MenuMT:capturing()
    return self.capture
end

---------------------------------------------------------------------------
-- Capture: the two states where a row is eating raw input
---------------------------------------------------------------------------

-- A raw key while capturing. Bind capture takes it as the answer; text
-- capture takes backspace/return/escape as editing verbs.
function MenuMT:feedKey(key)
    local screen, row = self:current(), self:selectedRow()
    if not self.capture or not row then return nil end

    if self.capture == 'bind' then
        self.capture = nil
        if key == 'escape' then
            return { kind = 'cancelled', screen = screen.id, row = row }
        end
        return { kind = 'set', screen = screen.id, row = row, value = key }
    end

    -- text
    if key == 'return' or key == 'kpenter' then
        self.capture = nil
        return { kind = 'submit', screen = screen.id, row = row,
                 value = row.value or '' }
    end
    if key == 'escape' then
        self.capture = nil
        return { kind = 'cancelled', screen = screen.id, row = row }
    end
    if key == 'backspace' then
        row.value = (row.value or ''):sub(1, -2)
        return { kind = 'editing', row = row }
    end
    return nil
end

-- Printable text while a text row captures.
function MenuMT:feedText(text)
    local row = self:selectedRow()
    if self.capture ~= 'text' or not row then return nil end
    row.value = (row.value or '') .. tostring(text)
    return { kind = 'editing', row = row }
end

return Menu
