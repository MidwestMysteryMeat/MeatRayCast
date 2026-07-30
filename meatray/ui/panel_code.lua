--[[
    meatray.ui.panel_code — the code browser.

    Browse, view, quick-edit, reload on save, and hand off to a real editor for
    real work. That last part is the design: VS Code exists and is better at
    editing than anything shipped inside a game engine will be, so the honest move
    is to make the handoff one click rather than to spend months reimplementing
    find-and-replace, an undo stack, multi-cursor and clipboard semantics badly.

    What this is genuinely good for is the loop the external editor cannot close:
    change a number in a definition file, save, and watch the running engine pick
    it up without a restart. Reload is scoped to data and definitions — see
    meatray/ui/reload.lua for why engine modules deliberately do not reload.
]]

local Platform = require('meatray.platform')
local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local Reload = require('meatray.ui.reload')

local Panel = {}
Panel.__index = Panel

local floor, max, min = math.floor, math.max, math.min

-- Directories offered in the tree. The engine's own source is included on
-- purpose: reading entity.lua to check a signature should not require leaving the
-- window, even though editing it needs a restart to take effect.
local ROOTS = { 'game', 'maps', 'meatray', 'tests', '.' }

local EDITABLE = { lua = true, map = true, md = true, txt = true, json = true }

function Panel.new(opts)
    opts = opts or {}

    return setmetatable({
        id = 'code',
        title = 'Code',
        tree = {},
        selected = nil,       -- path of the open file
        lines = {},           -- the open file, split
        text = nil,           -- the open file, whole
        dirty = false,
        scroll = 0,
        editing = false,
        editLine = nil,
        editBuffer = '',
        watcher = Reload.watcher(0.5),
        reloadPath = opts.definitions,   -- the file a reload re-runs
        lastReload = nil,
        externalCommand = opts.externalCommand,
    }, Panel)
end

function Panel:attach(shell)
    self.shell = shell
    self:refresh()
end

---------------------------------------------------------------------------
-- The file tree
---------------------------------------------------------------------------

local function extensionOf(path)
    return (path:match('%.([%w]+)$') or ''):lower()
end

-- Walks the project. Depth-limited because the tree is a browsing aid, not a
-- filesystem crawler, and an unbounded walk over a directory someone has pointed
-- at their whole drive is a hang rather than a feature.
local function walk(dir, out, depth, maxDepth)
    if depth > maxDepth then return end

    local items = Platform.fs.getDirectoryItems(dir)
    table.sort(items)

    -- Directories first, then files, each alphabetical: a tree that reorders
    -- itself between runs is hard to build muscle memory against.
    local dirs, files = {}, {}
    for _, name in ipairs(items) do
        if not name:match('^%.') then
            local path = (dir == '' or dir == '.') and name or (dir .. '/' .. name)
            local info = Platform.fs.getInfo(path)
            if info and info.type == 'directory' then
                dirs[#dirs + 1] = path
            elseif info and EDITABLE[extensionOf(path)] then
                files[#files + 1] = path
            end
        end
    end

    for _, path in ipairs(dirs) do
        out[#out + 1] = { path = path, depth = depth, isDir = true }
        walk(path, out, depth + 1, maxDepth)
    end
    for _, path in ipairs(files) do
        out[#out + 1] = { path = path, depth = depth, isDir = false }
    end
end

function Panel:refresh()
    self.tree = {}

    for _, root in ipairs(ROOTS) do
        local info = Platform.fs.getInfo(root)
        if info and info.type == 'directory' then
            self.tree[#self.tree + 1] = { path = root, depth = 0, isDir = true, isRoot = true }
            walk(root, self.tree, 1, 3)
        end
    end

    -- Files at the project root that no directory covers.
    for _, name in ipairs(Platform.fs.getDirectoryItems('')) do
        local info = Platform.fs.getInfo(name)
        if info and info.type == 'file' and EDITABLE[extensionOf(name)] then
            self.tree[#self.tree + 1] = { path = name, depth = 0, isDir = false }
        end
    end
end

---------------------------------------------------------------------------
-- Opening and saving
---------------------------------------------------------------------------

function Panel:open(path)
    if self.dirty then
        -- Never discard edits silently. Losing work to a misclick is the fastest
        -- way to make someone stop trusting a tool.
        if self.shell then
            self.shell:warn(('%s has unsaved changes - save or revert first'):format(self.selected))
        end
        return false
    end

    local text = Platform.fs.read(path)
    if not text then
        if self.shell then self.shell:error('cannot read ' .. path) end
        return false
    end

    self.selected = path
    self.text = text
    self.lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        self.lines[#self.lines + 1] = line
    end

    self.scroll = 0
    self.dirty = false
    self.editing = false
    self.watcher:watch(path)

    return true
end

function Panel:save()
    if not self.selected or not self.dirty then return false end

    local text = table.concat(self.lines, '\n')

    -- Syntax-check Lua before writing. Saving a file that cannot load is allowed
    -- in a text editor; here it would immediately be reloaded into a running
    -- engine, so catching it at the point of saving is both cheaper and clearer.
    if extensionOf(self.selected) == 'lua' then
        local chunk, err = load(text, '@' .. self.selected)
        if not chunk then
            if self.shell then self.shell:error('not saved - ' .. tostring(err)) end
            return false
        end
    end

    local ok, err = Platform.fs.write(self.selected, text)
    if not ok then
        if self.shell then self.shell:error('write failed: ' .. tostring(err)) end
        return false
    end

    self.dirty = false
    self.text = text
    self.watcher:watch(self.selected)
    if self.shell then self.shell:ok('saved ' .. self.selected) end

    self:reload()
    return true
end

function Panel:revert()
    if not self.selected then return end
    self.dirty = false
    self:open(self.selected)
    if self.shell then self.shell:log('reverted ' .. self.selected) end
end

-- Re-runs the definitions file, if one is configured. Engine modules are not
-- reloaded, deliberately.
function Panel:reload()
    if not self.reloadPath then return end

    local ok, err = Reload.definitions(self.reloadPath, {})
    if ok then
        self.lastReload = 'ok'
        if self.shell then self.shell:ok('reloaded ' .. self.reloadPath) end
    else
        self.lastReload = tostring(err)
        -- The registries were restored, so the game is still running on the last
        -- good definitions rather than on half of the new ones.
        if self.shell then
            self.shell:error('reload failed, keeping the previous definitions:')
            self.shell:error('  ' .. tostring(err))
        end
    end
end

function Panel:openExternally()
    if not self.selected then return end

    -- The absolute path only exists if the file is in the source directory; a
    -- file read out of the save directory has a different root.
    local source = Platform.fs.getSource()
    local path = source .. '/' .. self.selected

    local command = self.externalCommand
    if not command then
        -- `start` on Windows opens with whatever is registered for the extension,
        -- which is the user's editor if they have one.
        command = (Platform.sys.os() == 'Windows')
            and ('start "" "%s"') or ('open "%s"')
    end

    local ok = os.execute(command:format(path))
    if self.shell then
        self.shell:log(('opened %s externally%s'):format(self.selected,
                        ok and '' or ' (the command reported a failure)'))
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- Minimal Lua highlighting. Deliberately crude: a real parser is a project, and
-- what this needs to do is make structure skimmable, not be correct about every
-- edge case. Comments and strings are what actually help the eye.
local KEYWORDS = {
    ['local'] = true, ['function'] = true, ['end'] = true, ['if'] = true,
    ['then'] = true, ['else'] = true, ['elseif'] = true, ['for'] = true,
    ['while'] = true, ['do'] = true, ['return'] = true, ['and'] = true,
    ['or'] = true, ['not'] = true, ['nil'] = true, ['true'] = true,
    ['false'] = true, ['break'] = true, ['repeat'] = true, ['until'] = true,
    ['in'] = true,
}

local SYNTAX = {
    comment = { 0.45, 0.55, 0.45 },
    keyword = { 0.62, 0.60, 0.92 },
    string  = { 0.82, 0.70, 0.48 },
    number  = { 0.70, 0.82, 0.62 },
}

function Panel:drawLine(line, x, y, maxWidth)
    -- A whole-line comment is the common case and worth the special case.
    local trimmed = line:match('^%s*(.*)$')
    if trimmed:sub(1, 2) == '--' then
        UI.textClipped(line, x, y, maxWidth, SYNTAX.comment)
        return
    end

    local cursor = x

    -- Token-ish split: words, everything else passes through uncoloured.
    for chunk in line:gmatch('[%w_]+[^%w_]*') do
        local word = chunk:match('^[%w_]+')
        local color

        if word and KEYWORDS[word] then
            color = SYNTAX.keyword
        elseif word and tonumber(word) then
            color = SYNTAX.number
        end

        if cursor - x > maxWidth then break end
        UI.text(chunk, cursor, y, color)
        cursor = cursor + UI.textWidth(chunk)
    end
end

function Panel:draw(rect, shell)
    if not self.selected then
        UI.text('select a file from the project tree', rect.x, rect.y, UI.theme.textDim)
        return
    end

    local rowH = UI.textHeight() + 2
    local contentH = #self.lines * rowH
    local gutter = UI.textWidth('0000 ')

    UI.beginScroll('code/scroll', rect.x, rect.y, rect.w, rect.h, contentH)

    -- Only the visible lines are drawn. A 900-line file is 900 draw calls per
    -- frame otherwise, for the sake of the twenty you can see.
    local slot = UI.persistent('code/scroll', { offset = 0 })
    local firstLine = max(1, floor(slot.offset / rowH))
    local lastLine = min(#self.lines, firstLine + floor(rect.h / rowH) + 2)

    for i = firstLine, lastLine do
        local y = rect.y + (i - 1) * rowH

        if i == self.editLine and self.editing then
            UI.rect(rect.x, y, rect.w, rowH, UI.theme.accentDim)
        end

        UI.text(('%4d'):format(i), rect.x, y, UI.theme.textDim)
        self:drawLine(self.lines[i] or '', rect.x + gutter, y, rect.w - gutter - 12)
    end

    UI.endScroll('code/scroll', rect.x, rect.y, rect.w, rect.h, contentH)

    -- Click a line to edit it. One line at a time is a deliberate limit: it keeps
    -- the editing model small enough to be correct, and anything bigger is what
    -- the external editor is for.
    local mx, my = UI.state.mx, UI.state.my
    if Rect.contains(rect, mx, my) and UI.state.clicked then
        local line = Rect.rowAt(rect, my, rowH, slot.offset, #self.lines)
        if line then
            self.editLine = line
            self.editBuffer = self.lines[line] or ''
            self.editing = true
        end
    end

    -- The edit field sits over the line being edited.
    if self.editing and self.editLine then
        local y = rect.y + (self.editLine - 1) * rowH - slot.offset
        if y >= rect.y - rowH and y <= rect.y + rect.h then
            local value, committed = UI.textField('code/edit', self.editBuffer,
                                                  rect.x + gutter, y, rect.w - gutter - 12)
            self.editBuffer = value
            if value ~= (self.lines[self.editLine] or '') then self.dirty = true end
            self.lines[self.editLine] = value

            if committed then
                self.editing = false
                self.editLine = nil
            end
        end
    end
end

function Panel:drawSidebar(rect, shell)
    local rowH = UI.metrics.rowHeight
    local listH = rect.h - rowH * 5

    local contentH = #self.tree * rowH
    UI.beginScroll('code/tree', rect.x, rect.y, rect.w, listH, contentH)

    for i, node in ipairs(self.tree) do
        local y = rect.y + (i - 1) * rowH
        local indent = node.depth * 8

        local isOpen = (node.path == self.selected)
        if isOpen then UI.rect(rect.x, y, rect.w, rowH, UI.theme.accentDim) end

        local label = node.path:match('[^/]+$') or node.path
        if node.isDir then label = label .. '/' end
        if node.path == self.selected and self.dirty then label = label .. ' *' end

        local color = node.isDir and UI.theme.textDim or UI.theme.text
        UI.textClipped(label, rect.x + indent + 2, y, rect.w - indent - 12, color)

        if not node.isDir then
            local _, _, _, activated = UI.hit('code/tree/' .. i,
                                              rect.x, y, rect.w, rowH)
            if activated then self:open(node.path) end
        end
    end

    UI.endScroll('code/tree', rect.x, rect.y, rect.w, listH, contentH)

    local y = rect.y + listH + 4
    if UI.button('code/refresh', 'Refresh tree', rect.x, y, { w = rect.w - 4 }) then
        self:refresh()
        if shell then shell:log(('%d entries'):format(#self.tree)) end
    end
    y = y + rowH + 2

    if UI.button('code/save', self.dirty and 'Save + reload *' or 'Save + reload',
                 rect.x, y, { w = rect.w - 4, disabled = not self.dirty }) then
        self:save()
    end
    y = y + rowH + 2

    if UI.button('code/revert', 'Revert', rect.x, y,
                 { w = rect.w - 4, disabled = not self.dirty }) then
        self:revert()
    end
    y = y + rowH + 2

    if UI.button('code/external', 'Open externally', rect.x, y,
                 { w = rect.w - 4, disabled = not self.selected }) then
        self:openExternally()
    end
end

function Panel:drawInspector(rect, shell)
    local y = rect.y

    if not self.selected then
        UI.text('no file open', rect.x, y, UI.theme.textDim)
        return
    end

    y = y + UI.labelValue('file', self.selected:match('[^/]+$'), rect.x, y, rect.w)
    y = y + UI.labelValue('path', self.selected, rect.x, y, rect.w)
    y = y + UI.labelValue('lines', #self.lines, rect.x, y, rect.w)
    y = y + UI.labelValue('state', self.dirty and 'modified' or 'saved', rect.x, y, rect.w,
                          { color = self.dirty and UI.theme.warn or UI.theme.ok })

    if self.editLine then
        y = y + UI.labelValue('editing', 'line ' .. self.editLine, rect.x, y, rect.w)
    end

    y = y + 8
    if self.reloadPath then
        y = y + UI.labelValue('reloads', self.reloadPath, rect.x, y, rect.w)
        if self.lastReload then
            y = y + UI.labelValue('last', self.lastReload == 'ok' and 'ok' or 'failed',
                                  rect.x, y, rect.w,
                                  { color = self.lastReload == 'ok' and UI.theme.ok
                                                                    or UI.theme.danger })
        end
    else
        UI.textClipped('no definitions file configured; saving will not reload',
                       rect.x, y, rect.w, UI.theme.textDim)
        y = y + UI.metrics.rowHeight
    end

    y = y + 8
    UI.textClipped('Engine modules need a restart to take effect - see docs/EDITOR.md',
                   rect.x, y, rect.w, UI.theme.textDim)
end

---------------------------------------------------------------------------
-- Input and watching
---------------------------------------------------------------------------

function Panel:update(dt)
    -- Reload when a watched file changes on disk, so editing in VS Code and
    -- saving there applies without touching the engine window at all. That is the
    -- workflow this panel is really for.
    local changed = self.watcher:poll(dt)
    if not changed then return end

    for _, path in ipairs(changed) do
        if path == self.selected and not self.dirty then
            self:open(path)
            if self.shell then self.shell:log(path .. ' changed on disk, reloaded') end
        elseif path == self.reloadPath then
            self:reload()
        end
    end
end

function Panel:keypressed(key, shell)
    if key == 'escape' and self.editing then
        -- Abandon the line edit, restoring what was there.
        self.lines[self.editLine] = self.editBuffer
        self.editing = false
        self.editLine = nil
        return true
    end

    if Platform.input.keyDown('lctrl', 'rctrl') then
        if key == 's' then self:save(); return true end
        if key == 'r' then self:reload(); return true end
    end

    return false
end

Panel.ROOTS = ROOTS

return Panel
