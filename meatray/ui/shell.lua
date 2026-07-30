--[[
    meatray.ui.shell — the editor workspace.

    One window with docked regions and a tabbed centre, rather than four tools
    behind four launch flags. The difference matters later rather than now: every
    tool added after the first gets a home for free instead of another entry point,
    and two tools can be visible at once, which is the whole reason to look at a
    sprite while editing the map that uses it.

        +----------+---------------------------+-----------+
        | files    | [map] [code] [sprite]     | inspector |
        | assets   |                           |           |
        |          |     (active panel)        |           |
        +----------+---------------------------+-----------+
        | console                                          |
        +--------------------------------------------------+

    A panel is a table with `id`, `title`, and `draw(rect, shell)`. It may also
    have `drawSide(rect, shell)` for the inspector, `update(dt)`, and input hooks.
    Nothing here knows what a map or a sprite is — the shell lays out rectangles
    and routes input, and the panels do the work.

    Strippable by construction: a shipped game simply never requires this file.
]]

local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')

local Shell = {}
local ShellMT = {}
ShellMT.__index = ShellMT

local max, min, floor = math.max, math.min, math.floor

---------------------------------------------------------------------------

function Shell.new(opts)
    opts = opts or {}

    return setmetatable({
        panels = {},          -- ordered list of panel objects
        active = 1,           -- index of the tabbed panel in the centre
        sidebarWidth = opts.sidebarWidth or 190,
        inspectorWidth = opts.inspectorWidth or 210,
        consoleHeight = opts.consoleHeight or 110,
        showSidebar = true,
        showInspector = true,
        showConsole = true,
        console = {},         -- newest last
        maxConsole = opts.maxConsole or 400,
        status = '',
        onQuit = opts.onQuit,
    }, ShellMT)
end

function ShellMT:add(panel)
    assert(panel and panel.id, 'a panel needs an id')
    self.panels[#self.panels + 1] = panel
    if panel.attach then panel:attach(self) end
    return panel
end

function ShellMT:panel(id)
    for _, p in ipairs(self.panels) do
        if p.id == id then return p end
    end
    return nil
end

function ShellMT:activePanel()
    return self.panels[self.active]
end

function ShellMT:focus(id)
    for i, p in ipairs(self.panels) do
        if p.id == id then self.active = i; return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Console
--
-- Errors belong somewhere persistent and scrollable. A message that flashes over
-- the viewport for two seconds is a message you will miss, and a map parse error
-- with a line number is exactly the thing you need to still be there when you
-- look back at it.
---------------------------------------------------------------------------

function ShellMT:log(text, level)
    self.console[#self.console + 1] = {
        text = tostring(text),
        level = level or 'info',
        time = love.timer.getTime(),
    }
    while #self.console > self.maxConsole do table.remove(self.console, 1) end

    -- Mirror to stdout so a crash still leaves a trail on disk.
    print(('[editor] %s'):format(tostring(text)))
end

function ShellMT:warn(text) self:log(text, 'warn') end
function ShellMT:error(text) self:log(text, 'error') end
function ShellMT:ok(text) self:log(text, 'ok') end

local LEVEL_COLOR = {
    info = 'text', warn = 'warn', error = 'danger', ok = 'ok',
}

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- Splits the window into regions. Kept separate from drawing so the geometry can
-- be reasoned about (and tested) without a frame in flight.
function ShellMT:layout(w, h)
    local full = Rect.new(0, 0, w, h)
    local regions = {}

    local rest = full

    if self.showConsole then
        regions.console, rest = Rect.split(rest, 'bottom', self.consoleHeight)
    end
    if self.showSidebar then
        regions.sidebar, rest = Rect.split(rest, 'left', self.sidebarWidth)
    end
    if self.showInspector then
        regions.inspector, rest = Rect.split(rest, 'right', self.inspectorWidth)
    end

    regions.tabs, rest = Rect.split(rest, 'top', UI.metrics.tabHeight)
    regions.centre = rest

    return regions
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function ShellMT:update(dt)
    for _, p in ipairs(self.panels) do
        if p.update then p:update(dt, self) end
    end
end

function ShellMT:draw()
    local w, h = love.graphics.getDimensions()
    local r = self:layout(w, h)

    UI.beginFrame()
    UI.rect(0, 0, w, h, UI.theme.bg)

    -- Tab strip
    local titles = {}
    for i, p in ipairs(self.panels) do titles[i] = p.title or p.id end
    if r.tabs then
        UI.rect(r.tabs.x, r.tabs.y, r.tabs.w, r.tabs.h, UI.theme.bg)
        self.active = UI.tabs('shell/tabs', titles, self.active, r.tabs.x, r.tabs.y, r.tabs.w)
    end

    local panel = self:activePanel()

    -- Centre: the active tool.
    if r.centre and panel then
        local cx, cy, cw, ch = UI.beginPanel('shell/centre',
            r.centre.x, r.centre.y, r.centre.w, r.centre.h, nil)
        if panel.draw then
            local ok, err = pcall(panel.draw, panel,
                                  Rect.new(cx, cy, cw, ch), self)
            if not ok then
                -- A panel that throws must not take the editor with it. Report it
                -- where it can be read, and keep the rest of the shell alive so
                -- the fix is one hot reload away rather than a restart.
                UI.text('panel error: ' .. tostring(err), cx, cy, UI.theme.danger)
                if not panel._errored then
                    panel._errored = true
                    self:error(('panel "%s" failed to draw: %s'):format(panel.id, tostring(err)))
                end
            else
                panel._errored = nil
            end
        end
        UI.endPanel()
    end

    -- Sidebar
    if r.sidebar then
        local sx, sy, sw, sh = UI.beginPanel('shell/sidebar',
            r.sidebar.x, r.sidebar.y, r.sidebar.w, r.sidebar.h, 'Project')
        if panel and panel.drawSidebar then
            pcall(panel.drawSidebar, panel, Rect.new(sx, sy, sw, sh), self)
        else
            UI.text('no sidebar for this tool', sx, sy, UI.theme.textDim)
        end
        UI.endPanel()
    end

    -- Inspector
    if r.inspector then
        local ix, iy, iw, ih = UI.beginPanel('shell/inspector',
            r.inspector.x, r.inspector.y, r.inspector.w, r.inspector.h, 'Inspector')
        if panel and panel.drawInspector then
            pcall(panel.drawInspector, panel, Rect.new(ix, iy, iw, ih), self)
        else
            UI.text('nothing selected', ix, iy, UI.theme.textDim)
        end
        UI.endPanel()
    end

    -- Console
    if r.console then
        self:drawConsole(r.console)
    end

    UI.endFrame()
end

function ShellMT:drawConsole(rect)
    local cx, cy, cw, ch = UI.beginPanel('shell/console',
        rect.x, rect.y, rect.w, rect.h, 'Console')

    local font = love.graphics.getFont()
    local rowH = font:getHeight() + 2
    local contentH = #self.console * rowH

    local slot = UI.persistent('shell/console/scroll', { offset = 0, pinned = true })

    -- Stick to the bottom while the reader has not scrolled away, so new output
    -- is visible without chasing it — and stop sticking the moment they do scroll,
    -- because yanking someone back to the bottom mid-read is worse than silence.
    if slot.pinned then
        slot.offset = max(0, contentH - ch)
    end

    UI.beginScroll('shell/console/scroll', cx, cy, cw, ch, contentH)
    for i, line in ipairs(self.console) do
        local y = cy + (i - 1) * rowH
        UI.textClipped(line.text, cx, y, cw - UI.metrics.scrollbarWidth,
                       UI.theme[LEVEL_COLOR[line.level] or 'text'])
    end
    UI.endScroll('shell/console/scroll', cx, cy, cw, ch, contentH)

    slot.pinned = (slot.offset >= max(0, contentH - ch) - rowH)

    UI.endPanel()
end

---------------------------------------------------------------------------
-- Input routing
--
-- The shell gets first refusal on every event, then the active panel. Returning
-- true means handled, so a host game can tell whether the editor consumed a key
-- rather than guessing.
---------------------------------------------------------------------------

function ShellMT:keypressed(key)
    UI.keypressed(key)

    -- A text field owns the keyboard while focused, or typing a map name would
    -- also toggle panels and paint tiles.
    if UI.wantsKeyboard() then
        local panel = self:activePanel()
        if panel and panel.keypressed then panel:keypressed(key, self) end
        return true
    end

    if key == 'f1' then self.showSidebar = not self.showSidebar; return true end
    if key == 'f2' then self.showInspector = not self.showInspector; return true end
    if key == 'f3' then self.showConsole = not self.showConsole; return true end

    if key == 'tab' then
        self.active = (self.active % max(1, #self.panels)) + 1
        return true
    end

    local panel = self:activePanel()
    if panel and panel.keypressed then
        return panel:keypressed(key, self) and true or false
    end

    return false
end

function ShellMT:textinput(text)
    UI.textinput(text)
    local panel = self:activePanel()
    if panel and panel.textinput then panel:textinput(text, self) end
end

function ShellMT:mousepressed(x, y, button)
    UI.mousepressed(x, y, button)
    local panel = self:activePanel()
    if panel and panel.mousepressed then panel:mousepressed(x, y, button, self) end
end

function ShellMT:mousereleased(x, y, button)
    UI.mousereleased(x, y, button)
    local panel = self:activePanel()
    if panel and panel.mousereleased then panel:mousereleased(x, y, button, self) end
end

function ShellMT:wheelmoved(dx, dy)
    UI.wheelmoved(dx, dy)
    local panel = self:activePanel()
    if panel and panel.wheelmoved then panel:wheelmoved(dx, dy, self) end
end

function ShellMT:mousemoved(x, y, dx, dy)
    local panel = self:activePanel()
    if panel and panel.mousemoved then panel:mousemoved(x, y, dx, dy, self) end
end

return Shell
