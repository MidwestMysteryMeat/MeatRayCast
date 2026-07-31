--[[
    meatray.ui.panel_map — the map editor.

    Top-down paint grid on the left, live first-person preview on the right. The
    preview is the point: a level that reads well as a plan can feel like a
    corridor of identical walls once you are standing in it, and finding that out
    after launching the game is a slow way to iterate.

    It authors exactly what the engine understands — tiles, doors, spawn, entity
    markers, theme, name — and nothing it does not. Anything this panel can write,
    meatray.sim.map can parse, and vice versa; the format is the contract.
]]

local Platform = require('meatray.platform')
local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local Map = require('meatray.sim.map')
local World = require('meatray.sim.world')

local Panel = {}
Panel.__index = Panel

local floor, max, min = math.floor, math.max, math.min

-- What the brush can paint. Kept as data so the palette draws itself and a new
-- tool is one entry rather than a new branch.
local TOOLS = {
    { id = 'floor',  label = 'Floor',  tile = 0 },
    { id = 'wall1',  label = 'Wall 1', tile = 1 },
    { id = 'wall2',  label = 'Wall 2', tile = 2 },
    { id = 'wall3',  label = 'Wall 3', tile = 3 },
    { id = 'wall4',  label = 'Wall 4', tile = 4 },
    { id = 'door',   label = 'Door',   tile = World.DOOR },
    { id = 'spawn',  label = 'Spawn' },
    { id = 'entity', label = 'Entity' },
    -- Elevation: walk surface and short walls. Step is a fifth of a wall so a
    -- few strokes build a climbable platform without overshooting MAX_STEP.
    { id = 'raise',  label = 'Raise floor' },
    { id = 'lower',  label = 'Lower floor' },
    { id = 'short',  label = 'Short wall' },
    { id = 'full',   label = 'Full wall' },
    { id = 'flat',   label = 'Clear elev.' },
    { id = 'erase',  label = 'Erase',  tile = 0 },
}

local FLOOR_STEP = 0.2
local SHORT_WALL = 0.5

function Panel.new(opts)
    opts = opts or {}

    local self = setmetatable({
        id = 'map',
        title = 'Map',
        map = nil,
        path = opts.path,
        tool = 2,               -- start on a wall, since a blank map is all floor
        zoom = 16,
        panX = 0, panY = 0,
        dirty = false,
        hoverTx = nil, hoverTy = nil,
        entityKind = opts.defaultKind or 'imp',
        preview = {
            x = 2.5, y = 2.5, angle = 0,
            enabled = true,
        },
        painting = false,
    }, Panel)

    self:load(opts.map or Map.blank(24, 24))
    return self
end

function Panel:attach(shell)
    self.shell = shell
end

---------------------------------------------------------------------------
-- Map lifecycle
---------------------------------------------------------------------------

function Panel:load(map)
    self.map = map
    self.dirty = false
    self.world = nil

    if map.spawn then
        self.preview.x, self.preview.y = map.spawn.x, map.spawn.y
        self.preview.angle = map.spawn.angle or 0
    end

    self:rebuild()
end

-- The preview needs a World, and a World is built from the map. Rebuilding on
-- every edit is affordable at these sizes and removes a whole class of bug where
-- the preview and the grid disagree about what the level is.
function Panel:rebuild()
    local ok, world = pcall(Map.toWorld, self.map)
    if ok then
        self.world = world
    elseif self.shell then
        self.shell:error('could not build the world: ' .. tostring(world))
    end
end

function Panel:loadFile(path)
    local text = Platform.fs.read(path)
    if not text then
        if self.shell then self.shell:error('cannot read ' .. tostring(path)) end
        return false
    end

    local map, errs = Map.parse(text)
    if not map then
        -- Parse errors carry a row and column, and this is exactly the message
        -- that must survive on screen rather than flashing past.
        if self.shell then
            self.shell:error(('%s: %s'):format(path, tostring(errs and errs[1])))
            for i = 2, math.min(#(errs or {}), 6) do self.shell:error('  ' .. errs[i]) end
        end
        return false
    end

    self.path = path
    self:load(map)
    if self.shell then self.shell:ok(('loaded %s (%dx%d)'):format(path, map.width, map.height)) end
    return true
end

function Panel:save(path)
    path = path or self.path
    if not path then
        if self.shell then self.shell:error('no path to save to') end
        return false
    end

    local text = Map.serialize(self.map)

    -- Round-trip before writing. Serialising something that cannot be parsed back
    -- is how an editor eats an afternoon of work, and the check costs microseconds.
    local reparsed, errs = Map.parse(text)
    if not reparsed then
        if self.shell then
            self.shell:error('refusing to save: the output does not parse back')
            self.shell:error('  ' .. tostring(errs and errs[1]))
        end
        return false
    end

    local ok, err = Platform.fs.write(path, text)
    if not ok then
        if self.shell then self.shell:error('write failed: ' .. tostring(err)) end
        return false
    end

    self.dirty = false
    if self.shell then
        self.shell:ok(('saved %s to %s'):format(path, Platform.fs.getSaveDirectory()))
    end
    return true
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

local function ensureRow(map, ty)
    map.tiles[ty] = map.tiles[ty] or {}
    return map.tiles[ty]
end

function Panel:removeDoorAt(tx, ty)
    for i = #self.map.doors, 1, -1 do
        local d = self.map.doors[i]
        if d.x == tx and d.y == ty then table.remove(self.map.doors, i) end
    end
end

function Panel:removeEntityAt(tx, ty)
    for i = #self.map.entities, 1, -1 do
        local e = self.map.entities[i]
        if floor(e.x) + 1 == tx and floor(e.y) + 1 == ty then
            table.remove(self.map.entities, i)
        end
    end
end

function Panel:paint(tx, ty)
    if tx < 1 or ty < 1 or tx > self.map.width or ty > self.map.height then return end

    local tool = TOOLS[self.tool]
    if not tool then return end

    -- Elevation tools do not clear doors/entities: they only change height data.
    if tool.id == 'raise' or tool.id == 'lower' or tool.id == 'short'
       or tool.id == 'full' or tool.id == 'flat' then
        local tile = self.map.tiles[ty] and self.map.tiles[ty][tx] or 0
        if tool.id == 'raise' then
            if tile ~= 0 and tile ~= World.DOOR and tile ~= World.STAIRS_UP
               and tile ~= World.STAIRS_DOWN and tile ~= World.RUBBLE then
                return -- only open floor can be a raised walk surface
            end
            local z = Map.floorHeight(self.map, tx, ty) + FLOOR_STEP
            if z > 1 then z = 1 end
            Map.setFloorHeight(self.map, tx, ty, z)
        elseif tool.id == 'lower' then
            local z = Map.floorHeight(self.map, tx, ty) - FLOOR_STEP
            if z < 0 then z = 0 end
            Map.setFloorHeight(self.map, tx, ty, z)
        elseif tool.id == 'short' then
            if tile == 0 or tile == World.DOOR then return end
            Map.setWallHeight(self.map, tx, ty, SHORT_WALL)
        elseif tool.id == 'full' then
            Map.setWallHeight(self.map, tx, ty, nil)
        elseif tool.id == 'flat' then
            Map.clearElevation(self.map, tx, ty)
        end
        self.dirty = true
        self:rebuild()
        return
    end

    -- Painting anything over a tile clears whatever else claimed it, so a door
    -- and an entity marker can never occupy the same square and disagree.
    self:removeDoorAt(tx, ty)
    self:removeEntityAt(tx, ty)

    if tool.id == 'spawn' then
        self.map.spawn = { x = tx - 0.5, y = ty - 0.5, angle = self.map.spawn and self.map.spawn.angle or 0 }
        ensureRow(self.map, ty)[tx] = 0

    elseif tool.id == 'entity' then
        ensureRow(self.map, ty)[tx] = 0
        local entry = { kind = self.entityKind, x = tx - 0.5, y = ty - 0.5, angle = 0 }
        entry.char = Map.charFor(self.map, self.entityKind)
        self.map.entities[#self.map.entities + 1] = entry

    elseif tool.id == 'door' then
        ensureRow(self.map, ty)[tx] = World.DOOR
        self.map.doors[#self.map.doors + 1] = { x = tx, y = ty, open = false }

    else
        ensureRow(self.map, ty)[tx] = tool.tile
        -- Erasing a wall also drops short-wall height so a later wall paint is
        -- full height rather than inheriting a previous short entry.
        if tool.id == 'erase' or tool.tile == 0 then
            Map.setWallHeight(self.map, tx, ty, nil)
        end
    end

    self.dirty = true
    self:rebuild()
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local TILE_COLOR = {
    [0] = { 0.16, 0.17, 0.20 },
    [1] = { 0.52, 0.50, 0.46 },
    [2] = { 0.42, 0.38, 0.34 },
    [3] = { 0.36, 0.40, 0.46 },
    [4] = { 0.50, 0.44, 0.30 },
}

function Panel:draw(rect, shell)
    -- Grid on the left, preview on the right. The preview earns half the width
    -- only when it is on; otherwise the grid takes everything.
    local gridRect, previewRect
    if self.preview.enabled and rect.w > 420 then
        previewRect, gridRect = Rect.split(rect, 'right', floor(rect.w * 0.42))
    else
        gridRect = rect
    end

    self:drawGrid(gridRect, shell)
    if previewRect then self:drawPreview(previewRect, shell) end
end

function Panel:drawGrid(rect, shell)
    UI.pushClip(rect.x, rect.y, rect.w, rect.h)

    local z = self.zoom
    local ox = rect.x + self.panX
    local oy = rect.y + self.panY

    -- Only draw the tiles that can actually be seen. A 200x200 map is 40,000
    -- rectangles, and drawing the ones off screen costs the same as the ones on it.
    local firstTx = max(1, floor((rect.x - ox) / z) + 1)
    local lastTx  = min(self.map.width,  floor((rect.x + rect.w - ox) / z) + 1)
    local firstTy = max(1, floor((rect.y - oy) / z) + 1)
    local lastTy  = min(self.map.height, floor((rect.y + rect.h - oy) / z) + 1)

    for ty = firstTy, lastTy do
        for tx = firstTx, lastTx do
            local tile = self.map.tiles[ty] and self.map.tiles[ty][tx] or 0
            local color = TILE_COLOR[tile] or TILE_COLOR[1]
            if tile == World.DOOR then color = { 0.62, 0.42, 0.20 } end

            -- Raised floors tint warmer; short walls get a top stripe so both
            -- elevation systems are visible on the plan without a second layer.
            local fz = Map.floorHeight(self.map, tx, ty)
            if fz > 0 and (tile == 0 or tile == World.DOOR) then
                local t = min(1, fz)
                color = {
                    color[1] + 0.22 * t,
                    color[2] + 0.12 * t,
                    color[3] + 0.04 * t,
                }
            end

            local x, y = ox + (tx - 1) * z, oy + (ty - 1) * z
            UI.rect(x, y, z - 1, z - 1, color)

            local wh = Map.wallHeight(self.map, tx, ty)
            if wh < 1 - 1e-6 and tile ~= 0 and tile ~= World.DOOR then
                UI.rect(x + 1, y + 1, z - 3, max(2, floor((z - 2) * wh)),
                        { 0.85, 0.75, 0.35 })
            end
        end
    end

    -- Markers on top, so they are never hidden by the tile beneath them.
    for _, d in ipairs(self.map.doors) do
        local x, y = ox + (d.x - 1) * z, oy + (d.y - 1) * z
        UI.rect(x + 2, y + 2, z - 5, z - 5, d.open and UI.theme.ok or UI.theme.warn, 'line')
    end

    for _, e in ipairs(self.map.entities) do
        local x = ox + floor(e.x) * z
        local y = oy + floor(e.y) * z
        UI.rect(x + 3, y + 3, z - 7, z - 7, UI.theme.danger)
    end

    if self.map.spawn then
        local x = ox + floor(self.map.spawn.x) * z
        local y = oy + floor(self.map.spawn.y) * z
        UI.rect(x + 2, y + 2, z - 5, z - 5, UI.theme.accent)
    end

    -- The preview camera, so the two views are legibly the same place.
    local px = ox + (self.preview.x) * z
    local py = oy + (self.preview.y) * z
    UI.setColor(UI.theme.ok)
    Platform.gfx.circle('line', px, py, max(3, z * 0.3))
    Platform.gfx.line(px, py,
                      px + math.cos(self.preview.angle) * z,
                      py + math.sin(self.preview.angle) * z)

    -- Hover and painting.
    local mx, my = UI.state.mx, UI.state.my
    if Rect.contains(rect, mx, my) then
        local tx = floor((mx - ox) / z) + 1
        local ty = floor((my - oy) / z) + 1
        self.hoverTx, self.hoverTy = tx, ty

        if tx >= 1 and ty >= 1 and tx <= self.map.width and ty <= self.map.height then
            UI.rect(ox + (tx - 1) * z, oy + (ty - 1) * z, z - 1, z - 1, UI.theme.accent, 'line')
        end

        -- Drag-painting: holding the button paints every tile crossed, which is
        -- the difference between drawing a room and clicking four hundred times.
        UI.state.consumedMouse = true
        if Platform.input.mouseDown(1) then self:paint(tx, ty) end
        if Platform.input.mouseDown(2) then
            local held = self.tool
            self.tool = 1
            self:paint(tx, ty)
            self.tool = held
        end
    else
        self.hoverTx, self.hoverTy = nil, nil
    end

    UI.popClip()
end

function Panel:drawPreview(rect, shell)
    UI.rect(rect.x, rect.y, rect.w, rect.h, { 0, 0, 0 })

    if not self.world then
        UI.text('no world', rect.x + 8, rect.y + 8, UI.theme.textDim)
        return
    end

    -- The renderer draws in window coordinates, so the preview is rendered to a
    -- canvas at its own size and then blitted into place. Rendering straight into
    -- a sub-rect would need the raycaster to know about viewports, which is a
    -- coupling the renderer does not deserve.
    local w, h = floor(rect.w), floor(rect.h)
    if w < 8 or h < 8 then return end

    local gfx = Platform.gfx

    if not self.canvas or self.canvasW ~= w or self.canvasH ~= h then
        self.canvas = gfx.newCanvas(w, h)
        self.canvasW, self.canvasH = w, h
    end

    local Raycaster = require('meatray.render.raycaster')

    local prevW, prevH = Raycaster.state.screenW, Raycaster.state.screenH
    local prevTheme = Raycaster.getTheme()

    -- The scissor set by the enclosing panel is in WINDOW coordinates and stays
    -- active across setCanvas, so it would clip the canvas as though the canvas
    -- were the window — leaving only the band where the two happen to overlap.
    -- Clear it for the render and restore it afterwards.
    local sx, sy, sw, sh = gfx.getScissor()
    gfx.setScissor()

    gfx.setCanvas(self.canvas)
    gfx.clear(0, 0, 0, 1)

    Raycaster.resize(w, h)
    if self.map.theme and self.map.theme ~= prevTheme then
        pcall(Raycaster.setTheme, self.map.theme)
    end

    local floorZ = 0
    if self.world and self.world.floorHeightAtPoint then
        floorZ = self.world:floorHeightAtPoint(self.preview.x, self.preview.y)
    end
    local eyeH = World.EYE_HEIGHT
    local view = Raycaster.view(self.preview.x, self.preview.y, self.preview.angle, {
        eyeZ = floorZ + eyeH,
        eyeHeight = eyeH,
    })
    pcall(Raycaster.render, view, self.world)

    gfx.setCanvas()

    -- setScissor with no arguments clears it, so passing a nil x restores "no
    -- clip" without a branch.
    gfx.setScissor(sx, sy, sw, sh)

    -- Restore, so the editor's preview cannot leave the renderer configured for a
    -- window size that no longer exists.
    Raycaster.resize(prevW, prevH)
    if prevTheme ~= Raycaster.getTheme() then pcall(Raycaster.setTheme, prevTheme) end

    UI.setColor({ 1, 1, 1 })
    gfx.draw(self.canvas, rect.x, rect.y)
    UI.rect(rect.x, rect.y, rect.w, rect.h, UI.theme.border, 'line')

    UI.text('preview - WASD/arrows to walk, drag to look',
            rect.x + 6, rect.y + rect.h - 18, UI.theme.textDim)
end

---------------------------------------------------------------------------
-- Sidebar: tools and file actions
---------------------------------------------------------------------------

function Panel:drawSidebar(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight + 2

    UI.text('Brush', rect.x, y, UI.theme.textDim); y = y + rowH

    for i, tool in ipairs(TOOLS) do
        local selected = (i == self.tool)
        local pressed = UI.button('map/tool/' .. tool.id,
                                  (selected and '> ' or '  ') .. tool.label,
                                  rect.x, y, { w = rect.w - 4 })
        if pressed then self.tool = i end
        y = y + rowH
    end

    y = y + 6
    UI.text('Entity kind', rect.x, y, UI.theme.textDim); y = y + rowH
    local kind, committed = UI.textField('map/entitykind', self.entityKind,
                                         rect.x, y, rect.w - 4,
                                         { placeholder = 'archetype name' })
    self.entityKind = kind
    y = y + rowH + 6

    UI.text('Map', rect.x, y, UI.theme.textDim); y = y + rowH

    if UI.button('map/save', self.dirty and 'Save *' or 'Save', rect.x, y, { w = rect.w - 4 }) then
        self:save()
    end
    y = y + rowH

    if UI.button('map/reload', 'Reload', rect.x, y, { w = rect.w - 4 }) then
        if self.path then self:loadFile(self.path) end
    end
    y = y + rowH

    if UI.button('map/new', 'New 24x24', rect.x, y, { w = rect.w - 4 }) then
        self:load(Map.blank(24, 24))
        if shell then shell:ok('new blank map') end
    end
    y = y + rowH + 6

    UI.text('Preview', rect.x, y, UI.theme.textDim); y = y + rowH
    local shown = UI.button('map/preview', self.preview.enabled and 'On' or 'Off',
                            rect.x, y, { w = rect.w - 4 })
    if shown then self.preview.enabled = not self.preview.enabled end
end

---------------------------------------------------------------------------
-- Inspector: what is under the cursor
---------------------------------------------------------------------------

function Panel:drawInspector(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight

    y = y + UI.labelValue('name', self.map.name or 'untitled', rect.x, y, rect.w)
    y = y + UI.labelValue('theme', self.map.theme or 'dungeon', rect.x, y, rect.w)
    y = y + UI.labelValue('size', ('%dx%d'):format(self.map.width, self.map.height),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('doors', #self.map.doors, rect.x, y, rect.w)
    y = y + UI.labelValue('entities', #self.map.entities, rect.x, y, rect.w)
    if self.map.spawn then
        y = y + UI.labelValue('spawn', ('%.1f, %.1f'):format(self.map.spawn.x, self.map.spawn.y),
                              rect.x, y, rect.w)
    end

    y = y + 8
    if self.hoverTx then
        UI.text('Under cursor', rect.x, y, UI.theme.textDim); y = y + rowH
        y = y + UI.labelValue('tile', ('%d, %d'):format(self.hoverTx, self.hoverTy),
                              rect.x, y, rect.w)

        local row = self.map.tiles[self.hoverTy]
        local tile = row and row[self.hoverTx]
        y = y + UI.labelValue('value', tile == nil and '-' or tostring(tile),
                              rect.x, y, rect.w)

        local fz = Map.floorHeight(self.map, self.hoverTx, self.hoverTy)
        local wh = Map.wallHeight(self.map, self.hoverTx, self.hoverTy)
        if fz > 0 then
            y = y + UI.labelValue('floor z', ('%.2f'):format(fz), rect.x, y, rect.w)
        end
        if wh < 1 - 1e-6 then
            y = y + UI.labelValue('wall h', ('%.2f'):format(wh), rect.x, y, rect.w)
        end

        for _, d in ipairs(self.map.doors) do
            if d.x == self.hoverTx and d.y == self.hoverTy then
                y = y + UI.labelValue('door', d.open and 'open' or 'shut', rect.x, y, rect.w)
            end
        end

        for _, e in ipairs(self.map.entities) do
            if floor(e.x) + 1 == self.hoverTx and floor(e.y) + 1 == self.hoverTy then
                y = y + UI.labelValue('entity', e.kind, rect.x, y, rect.w)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

function Panel:update(dt)
    if not self.preview.enabled then return end

    -- Walking the preview camera. Deliberately not collision-checked: an editor
    -- camera that gets stuck on the geometry you are trying to inspect is worse
    -- than one that can pass through it.
    local speed, turn = 4 * dt, 2.4 * dt
    local a = self.preview.angle
    local fwd, strafe = 0, 0

    local keyDown = Platform.input.keyDown
    if keyDown('w') then fwd = fwd + 1 end
    if keyDown('s') then fwd = fwd - 1 end
    if keyDown('a') then strafe = strafe - 1 end
    if keyDown('d') then strafe = strafe + 1 end
    if keyDown('left') then self.preview.angle = a - turn end
    if keyDown('right') then self.preview.angle = a + turn end

    if not UI.wantsKeyboard() and (fwd ~= 0 or strafe ~= 0) then
        local c, s = math.cos(a), math.sin(a)
        self.preview.x = self.preview.x + (c * fwd - s * strafe) * speed
        self.preview.y = self.preview.y + (s * fwd + c * strafe) * speed
    end
end

function Panel:wheelmoved(_, dy)
    if dy ~= 0 then
        self.zoom = max(6, min(48, self.zoom + dy * 2))
    end
end

function Panel:keypressed(key, shell)
    if key == 'lctrl' or key == 'rctrl' then return false end

    -- Number keys pick a brush, which is what a paint tool should do.
    local n = tonumber(key)
    if n and TOOLS[n] then self.tool = n; return true end

    if key == 'p' then self.preview.enabled = not self.preview.enabled; return true end
    return false
end

Panel.TOOLS = TOOLS

return Panel
