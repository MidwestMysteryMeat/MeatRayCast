--[[
    meatray.ui.panel_meatgraph — browse and inspect MeatGraphRay JSON graphs.

    Not a full node editor (MeatEngine's imnodes UI is the visual authoring path
    for MeatGraph). This panel lists graphs under meatgraphs/, shows node/link/
    volume counts, and lets you open the JSON in the code browser or an external
    editor. Enough for first-run discovery without inventing a second graph UI.
]]

local Platform = require('meatray.platform')
local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local MeatGraphRay = require('meatray.game.meatgraph_ray')

local Panel = {}
Panel.__index = Panel

local floor = math.floor

local ROOTS = { 'meatgraphs', 'graphs' }

function Panel.new(opts)
    opts = opts or {}
    return setmetatable({
        id = 'meatgraph',
        title = 'MeatGraph',
        files = {},
        selected = nil,
        graph = nil,
        parseError = nil,
        status = 'no graph loaded',
    }, Panel)
end

function Panel:attach(shell)
    self.shell = shell
    self:refresh()
end

local function listJson(dir, out)
    local items = Platform.fs.getDirectoryItems(dir)
    if not items then return end
    table.sort(items)
    for _, name in ipairs(items) do
        if name:match('%.graph%.json$') or name:match('%.json$') then
            local path = dir .. '/' .. name
            local info = Platform.fs.getInfo(path)
            if info and info.type == 'file' then
                out[#out + 1] = path
            end
        end
    end
end

function Panel:refresh()
    self.files = {}
    for _, root in ipairs(ROOTS) do
        local info = Platform.fs.getInfo(root)
        if info and info.type == 'directory' then
            listJson(root, self.files)
        end
    end
    if self.shell then
        self.shell:log(('MeatGraphRay: %d graph file(s)'):format(#self.files))
    end
end

function Panel:load(path)
    local text = Platform.fs.read(path)
    if not text then
        self.parseError = 'cannot read ' .. tostring(path)
        self.graph = nil
        self.status = self.parseError
        if self.shell then self.shell:error(self.parseError) end
        return false
    end
    local g, err = MeatGraphRay.load(text)
    if not g then
        self.parseError = tostring(err)
        self.graph = nil
        self.status = 'parse failed: ' .. self.parseError
        if self.shell then self.shell:error(self.status) end
        return false
    end
    self.selected = path
    self.graph = g
    self.parseError = nil
    self.status = ('%s · %d nodes · %d links · %d volumes')
        :format(g.name or path, #g.nodes, #g.links, #(g.volumes or {}))
    if self.shell then
        self.shell:ok(self.status)
        self.shell:status('MeatGraphRay: ' .. self.status)
    end
    return true
end

function Panel:draw(rect, shell)
    local y = rect.y + 4
    local rowH = UI.metrics.rowHeight + 2

    UI.text('MeatGraphRay graphs', rect.x + 6, y, UI.theme.textDim)
    y = y + rowH

    if UI.button('mg/refresh', 'Refresh list', rect.x + 6, y, { w = 120 }) then
        self:refresh()
    end
    y = y + rowH + 4

    if #self.files == 0 then
        UI.text('No .graph.json under meatgraphs/', rect.x + 6, y, UI.theme.warn)
        y = y + rowH
        UI.text('Tip: meatgraphs/demo.graph.json ships with the repo.',
                rect.x + 6, y, UI.theme.textDim)
        return
    end

    UI.beginScroll('mg/list', rect.x + 4, y, rect.w - 8, rect.h - (y - rect.y) - 8,
                   #self.files * rowH + 4)
    local ly = y
    for i, path in ipairs(self.files) do
        local label = (path == self.selected and '> ' or '  ') .. path
        if UI.button('mg/file/' .. i, label, rect.x + 6, ly, { w = rect.w - 24 }) then
            self:load(path)
        end
        ly = ly + rowH
    end
    UI.endScroll('mg/list', rect.x + 4, y, rect.w - 8, rect.h - (y - rect.y) - 8,
                 #self.files * rowH + 4)
end

function Panel:drawSidebar(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight + 2
    UI.text('MeatGraphRay', rect.x, y, UI.theme.textDim); y = y + rowH
    UI.text('Sibling of MeatEngine MeatGraph.', rect.x, y, UI.theme.textDim)
    y = y + rowH + 4
    UI.text('Not Unreal Blueprints.', rect.x, y, UI.theme.warn)
    y = y + rowH + 8
    UI.text('Run in game:', rect.x, y, UI.theme.textDim); y = y + rowH
    UI.text('love . --meatgraph', rect.x, y, UI.theme.ok); y = y + rowH
    if self.selected then
        y = y + 4
        UI.text('Selected:', rect.x, y, UI.theme.textDim); y = y + rowH
        UI.textClipped(self.selected, rect.x, y, rect.w - 4, UI.theme.text)
    end
end

function Panel:drawInspector(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight
    if not self.graph then
        UI.text(self.status or 'select a graph', rect.x, y, UI.theme.textDim)
        return
    end
    local g = self.graph
    y = y + UI.labelValue('name', g.name or '—', rect.x, y, rect.w)
    y = y + UI.labelValue('nodes', #g.nodes, rect.x, y, rect.w)
    y = y + UI.labelValue('links', #g.links, rect.x, y, rect.w)
    y = y + UI.labelValue('volumes', #(g.volumes or {}), rect.x, y, rect.w)
    y = y + 8
    UI.text('Events', rect.x, y, UI.theme.textDim); y = y + rowH
    local seen = {}
    for i = 1, #g.nodes do
        local k = g.nodes[i].kind
        if k and k:match('^Event') and not seen[k] then
            seen[k] = true
            UI.text('  ' .. k, rect.x, y, UI.theme.text); y = y + rowH
        end
    end
    if next(g.volumes or {}) then
        y = y + 4
        UI.text('Volumes', rect.x, y, UI.theme.textDim); y = y + rowH
        for i = 1, #g.volumes do
            local v = g.volumes[i]
            local line = v.name or ('vol' .. i)
            if v.tx1 then
                line = line .. ('  tiles %d,%d–%d,%d')
                    :format(v.tx1, v.ty1 or v.tx1, v.tx2 or v.tx1, v.ty2 or v.ty1 or v.tx1)
            end
            UI.textClipped(line, rect.x, y, rect.w - 4, UI.theme.text)
            y = y + rowH
        end
    end
end

return Panel
