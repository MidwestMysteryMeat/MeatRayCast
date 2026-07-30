--[[
    meatray.ui.panel_sprite — the sprite painter.

    An in-engine pixel editor that produces sheets the asset registry imports.
    Its reason to exist is narrower and more specific than "the engine should have
    a paint tool", and worth stating plainly:

        A sheet is `angles` ROWS of angle buckets by `frames` COLUMNS of animation
        frames. Hand-authoring an eight-bucket directional sheet in an external
        editor and getting the bucket order wrong produces art that looks perfect
        in the art tool and renders as an enemy walking toward you showing its
        back. Nothing catches it until it is in the game.

    So the grid is not a background detail here, it is the subject. The canvas
    always draws the whole sheet with its cell boundaries and bucket labels on it,
    the active cell is outlined, painting is confined to one cell by default, and
    the preview beside it runs the *renderer's own* facing maths — meatray.sim
    .billboard, the same module meatray.render.sprites calls — rather than a
    lookalike that could agree with the painter while disagreeing with the game.

    What it does:

        canvas      zoom, pan, pixel grid, cell grid, bucket and frame labels
        tools       brush, eraser, flood fill, colour picker, rectangle
        cells       step between buckets and frames, copy one cell over another
        onion       the previous frame showing faintly under the current one
        preview     billboard projection, orbiting camera, live animation
        history     bounded undo/redo over diffs (see meatray.asset.history)
        files       export a PNG the asset pipeline imports, and read one back

    Almost none of that logic lives here. The pixel model is meatray.asset.sheet,
    the undo bound is meatray.asset.history, the ImageData bridge is
    meatray.asset.sheet_image, and the grid arithmetic is meatray.asset.slice —
    all headless, all asserted under plain LuaJIT. This file is layout, input and
    drawing, which is the part a unit test cannot honestly cover anyway.

    Panel contract, per meatray.ui.shell: `id`, `title`, `draw(rect, shell)`, and
    optionally `drawSidebar`, `drawInspector`, `update`, `keypressed`, `attach`.
]]

local Platform = require('meatray.platform')
local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local Sheet = require('meatray.asset.sheet')
local SheetImage = require('meatray.asset.sheet_image')
local History = require('meatray.asset.history')
local Billboard = require('meatray.sim.billboard')
local Names = require('meatray.asset.names')

local Panel = {}
Panel.__index = Panel

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local cos, sin, pi = math.cos, math.sin, math.pi

local MIN_ZOOM, MAX_ZOOM = 1, 32

-- Wide enough for the glyph inside it. UI.button truncates its label to the
-- button minus padding and gives up entirely when the ellipsis will not fit, so a
-- 20-pixel button holding '<' draws an empty box — which is exactly what the first
-- version of this toolbar did.
local STEP_W = 26
local LABEL_GUTTER = 22          -- room at the left of the sheet for bucket labels
local LABEL_HEADER = 14          -- and above it for frame labels

-- UI.slider draws its unfilled track in theme.panel, which is the same colour as
-- the panel it sits on. At a value of zero there is nothing filled either, so the
-- control reads as a stray knob floating next to a label. A darker backing under
-- it makes the range it covers visible.
local function sliderTrack(x, y, w)
    UI.rect(x, y + 4, w, 6, UI.theme.bg)
    UI.rect(x, y + 4, w, 6, UI.theme.border, 'line')
end

local TOOLS = {
    { id = 'brush',  label = 'Brush',  key = 'b' },
    { id = 'erase',  label = 'Erase',  key = 'e' },
    { id = 'fill',   label = 'Fill',   key = 'f' },
    { id = 'pick',   label = 'Pick',   key = 'i' },
    { id = 'rect',   label = 'Rect',   key = 'r' },
}

---------------------------------------------------------------------------

function Panel.new(opts)
    opts = opts or {}

    local self = setmetatable({
        id = opts.id or 'sprite',
        title = opts.title or 'Sprite',

        name = opts.name or 'untitled',
        path = nil,
        dirty = false,

        tool = 'brush',
        color = 3,               -- palette index being painted
        brush = 1,
        lockToCell = true,
        onion = true,

        bucket = 0,
        frame = 0,
        clipCell = nil,          -- source cell for copy/paste

        zoom = 4,
        panX = LABEL_GUTTER,
        panY = LABEL_HEADER,
        needsFit = true,

        time = 0,
        playing = true,
        fps = opts.fps or 8,
        facing = 0,              -- where the previewed entity is turned
        orbit = 0,               -- where the previewed camera is standing
        anchor = 'feet',
        previewScale = 1,

        -- Form fields, kept as strings because that is what a text field holds
        -- while someone is halfway through typing a number into it.
        fieldAngles = tostring(opts.angles or 8),
        fieldFrames = tostring(opts.frames or 4),
        fieldCellW = tostring(opts.cellW or 16),
        fieldCellH = tostring(opts.cellH or 16),
        fieldPath = '',

        history = History.new{
            maxSteps = opts.maxUndo or 64,
            maxPixels = opts.maxUndoPixels or 250000,
        },
    }, Panel)

    local sheet, err = Sheet.new{
        angles = opts.angles or 8,
        frames = opts.frames or 4,
        cellW = opts.cellW or 16,
        cellH = opts.cellH or 16,
    }
    -- A refused default would leave the panel with no sheet at all, so fall back
    -- to the smallest thing that always builds rather than carrying a nil around.
    self.sheet = sheet or Sheet.new{ angles = 1, frames = 1, cellW = 16, cellH = 16 }
    self.buildError = err

    if not opts.blank then Sheet.starter(self.sheet) end

    return self
end

function Panel:attach(shell)
    if self.shell == shell then return end
    self.shell = shell
    if shell then
        shell:log(('sprite painter: %s'):format(Sheet.describe(self.sheet)))
        shell:log('B brush  E erase  F fill  I pick  R rect   arrows step cells')
        shell:log('ctrl+Z undo  wheel zooms  right-drag pans  HOME fits  END fills with one cell')
        if self.buildError then shell:warn('sprite painter: ' .. tostring(self.buildError)) end
    end
end

function Panel:log(text, level)
    if self.shell then self.shell:log(text, level) end
end

---------------------------------------------------------------------------
-- The picture on the GPU
--
-- The sheet lives in a plain Lua array; what gets drawn is an Image built from an
-- ImageData that mirrors it. Keeping them in step incrementally rather than
-- rebuilding is the difference between a painter that feels immediate and one
-- that stutters: a full rebuild is one setPixel per pixel of the sheet, per dab.
---------------------------------------------------------------------------

function Panel:rebuildImage()
    if not Platform.canRender() then return end

    local previous = self.imageData
    self.imageData = SheetImage.toImageData(self.sheet, self.imageData)
    if not self.imageData then return end

    if self.image and self.imageData == previous then
        self.image:replacePixels(self.imageData)
    else
        -- Nearest filtering comes from the backend: a smoothed pixel-art sheet
        -- in the painter that draws it would be worse than wrong.
        self.image = Platform.gfx.newImage(self.imageData)
    end

    self.imageDirty = false
end

-- Pushes pending ImageData edits to the texture, once per frame at most.
function Panel:syncImage()
    if not self.image then self:rebuildImage(); return end
    if self.imageDirty then
        self.image:replacePixels(self.imageData)
        self.imageDirty = false
    end
end

-- Applies a completed edit: to the sheet already (the tools wrote it), to the
-- picture, and to the undo stack.
function Panel:record(diff)
    if not diff or diff.n == 0 then return false end
    self.history:push(diff)
    SheetImage.applyDiff(self.sheet, self.imageData, diff, false)
    self.imageDirty = true
    self.dirty = true
    return true
end

function Panel:undo()
    local diff = self.history:undo()
    if not diff then return false end
    Sheet.applyDiff(self.sheet, diff, true)
    SheetImage.applyDiff(self.sheet, self.imageData, diff, true)
    self.imageDirty = true
    self.dirty = true
    return true
end

function Panel:redo()
    local diff = self.history:redo()
    if not diff then return false end
    Sheet.applyDiff(self.sheet, diff, false)
    SheetImage.applyDiff(self.sheet, self.imageData, diff, false)
    self.imageDirty = true
    self.dirty = true
    return true
end

---------------------------------------------------------------------------
-- Sheet lifecycle
---------------------------------------------------------------------------

function Panel:adopt(sheet, why)
    self.sheet = sheet
    self.history:clear()
    self.bucket = min(self.bucket, sheet.angles - 1)
    self.frame = min(self.frame, sheet.frames - 1)
    self.color = min(max(1, self.color), max(1, Sheet.colorCount(sheet)))
    self.fieldAngles = tostring(sheet.angles)
    self.fieldFrames = tostring(sheet.frames)
    self.fieldCellW = tostring(sheet.cellW)
    self.fieldCellH = tostring(sheet.cellH)
    self.needsFit = true
    self.image = nil
    self.imageData = nil
    self:rebuildImage()
    if why then self:log(why, 'ok') end
end

function Panel:newSheet(blank)
    local sheet, err = Sheet.new{
        angles = tonumber(self.fieldAngles),
        frames = tonumber(self.fieldFrames),
        cellW = tonumber(self.fieldCellW),
        cellH = tonumber(self.fieldCellH),
    }
    if not sheet then
        self:log('new sheet: ' .. tostring(err), 'error')
        return false
    end

    if not blank then Sheet.starter(sheet) end
    self.dirty = false
    self.path = nil
    self:adopt(sheet, 'new sheet: ' .. Sheet.describe(sheet))
    return true
end

-- Reinterprets the current pixels under the grid in the form fields, without
-- moving a pixel. The cheap way to answer "is this 8 buckets of 4 frames, or 4 of
-- 8?" — flip the numbers and look at the preview.
function Panel:regrid()
    local angles = tonumber(self.fieldAngles)
    local frames = tonumber(self.fieldFrames)
    if not angles or not frames then
        self:log('regrid: angles and frames must be numbers', 'warn')
        return false
    end

    local ok, why = Sheet.regrid(self.sheet, angles, frames)
    if not ok then
        self:log('regrid refused: ' .. tostring(why), 'error')
        return false
    end

    self.bucket = min(self.bucket, self.sheet.angles - 1)
    self.frame = min(self.frame, self.sheet.frames - 1)
    self.fieldCellW = tostring(self.sheet.cellW)
    self.fieldCellH = tostring(self.sheet.cellH)
    self.needsFit = true
    self.dirty = true
    self:log('regridded to ' .. Sheet.describe(self.sheet), 'ok')
    return true
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

-- Writes the sheet, then reads it straight back and compares every byte.
--
-- The round trip is the promise this panel makes, so it is checked on every
-- export rather than assumed. It costs one decode of a file already in the page
-- cache, and it turns "the exported sheet does not match what I drew" from a bug
-- someone finds days later into a red console line at the moment it happens.
function Panel:export()
    if not SheetImage.available() then
        self:log('export needs a graphics context', 'error')
        return false
    end

    local path = SheetImage.pathFor(self.name, self.sheet)
    local written, err = SheetImage.write(self.sheet, path)
    if not written then
        self:log('export failed: ' .. tostring(err), 'error')
        return false
    end

    self.path = written
    self.fieldPath = written
    self.dirty = false
    self:log(('exported %s — %s'):format(written, Sheet.describe(self.sheet)), 'ok')

    local back, readErr = SheetImage.read(written, {
        angles = self.sheet.angles, frames = self.sheet.frames,
    })
    if not back then
        self:log('exported, but reading it back failed: ' .. tostring(readErr), 'error')
        return true
    end

    local same, detail = Sheet.sameBytes(Sheet.toBytes(back), Sheet.toBytes(self.sheet))
    if same then
        self:log('round trip verified: the file holds exactly what is on the canvas', 'ok')
    else
        self:log('ROUND TRIP MISMATCH: ' .. tostring(detail), 'error')
    end

    return true
end

function Panel:load(path)
    path = path or self.fieldPath
    if not path or path == '' then
        self:log('load: give a path first', 'warn')
        return false
    end

    -- The filename hint wins when there is one, because a file this panel wrote
    -- carries its own grid; the form fields are the fallback for a file that does
    -- not say.
    local hint = Names.hints(path)
    local sheet, err = SheetImage.read(path, {
        angles = hint and hint.angles or tonumber(self.fieldAngles),
        frames = hint and hint.frames or tonumber(self.fieldFrames),
    })
    if not sheet then
        self:log('load failed: ' .. tostring(err), 'error')
        return false
    end

    self.path = path
    self.name = Names.fromPath(path)
    self.dirty = false
    self:adopt(sheet, ('loaded %s — %s'):format(path, Sheet.describe(sheet)))
    return true
end

-- Wires the exported sheet into the asset registry, so the sprite it defines is
-- live in the running engine. This is the whole point of painting in-engine: the
-- thing you just drew is the thing the renderer is now drawing.
function Panel:register()
    if not self.path then
        if not self:export() then return false end
    end

    local Asset = require('meatray.asset')
    local name = Names.normalise(self.name)
    local record = Asset.importSprite(name, self.path, {
        angles = self.sheet.angles,
        frames = self.sheet.frames,
        fps = self.fps,
    })

    if record.state == 'file' then
        self:log(('registered sprite "%s": %d buckets x %d frames from %s')
            :format(name, self.sheet.angles, self.sheet.frames, self.path), 'ok')
        return true
    end

    self:log(('registering "%s" fell back to a placeholder: %s')
        :format(name, tostring(record.problem)), 'error')
    return false
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------

function Panel:originIn(vp)
    return floor(vp.x + self.panX), floor(vp.y + self.panY)
end

function Panel:toSheet(vp, px, py)
    local ox, oy = self:originIn(vp)
    return floor((px - ox) / self.zoom), floor((py - oy) / self.zoom)
end

function Panel:fit(vp)
    local sheet = self.sheet
    local usableW = max(1, vp.w - LABEL_GUTTER - 4)
    local usableH = max(1, vp.h - LABEL_HEADER - 4)

    local z = min(floor(usableW / sheet.width), floor(usableH / sheet.height))
    self.zoom = max(MIN_ZOOM, min(MAX_ZOOM, z))

    local sw = sheet.width * self.zoom
    local sh = sheet.height * self.zoom
    self.panX = max(LABEL_GUTTER, floor((vp.w - sw) / 2))
    self.panY = max(LABEL_HEADER, floor((vp.h - sh) / 2))
    self.needsFit = false
end

-- Zooms about a point, so the pixel under the cursor stays under the cursor.
-- Zooming about the origin instead is what makes a canvas run away from you.
function Panel:zoomAt(vp, delta, px, py)
    local before = self.zoom
    local target = max(MIN_ZOOM, min(MAX_ZOOM, before + delta))
    if target == before then return end

    local ox, oy = self:originIn(vp)
    local fx = (px - ox) / before
    local fy = (py - oy) / before

    self.zoom = target
    self.panX = self.panX + floor(fx * (before - target))
    self.panY = self.panY + floor(fy * (before - target))
end

-- Fills the viewport with the active cell alone.
--
-- Fit and this are the two views the panel needs and they answer different
-- questions. Fit shows the whole sheet, which is how you check that bucket 4
-- faces away — but on an eight-bucket sheet it lands around 2x, and nobody can
-- paint at 2x. This is the other half: get in close enough to place pixels,
-- without losing which cell you are in.
function Panel:zoomToCell(vp)
    local b = Sheet.cellBounds(self.sheet, self.bucket, self.frame)
    if not b or vp.w < 20 or vp.h < 20 then return end

    local z = min(floor((vp.w - LABEL_GUTTER - 8) / b.w),
                  floor((vp.h - LABEL_HEADER - 8) / b.h))
    self.zoom = max(MIN_ZOOM, min(MAX_ZOOM, z))

    self.panX = floor(vp.w / 2 - (b.x + b.w / 2) * self.zoom)
    self.panY = floor(vp.h / 2 - (b.y + b.h / 2) * self.zoom)
    self.pendingCellZoom = false
end

function Panel:setCell(bucket, frame)
    self.bucket = bucket % self.sheet.angles
    self.frame = frame % self.sheet.frames
end

---------------------------------------------------------------------------
-- Tools
---------------------------------------------------------------------------

-- The index a tool writes: the eraser writes transparency, everything else
-- writes the selected colour.
function Panel:paintIndex()
    return self.tool == 'erase' and 0 or self.color
end

function Panel:activeBounds()
    if not self.lockToCell then return nil end
    return Sheet.cellBounds(self.sheet, self.bucket, self.frame)
end

function Panel:strokeBegin(x, y)
    local sheet = self.sheet

    -- Clicking somewhere always makes that cell the active one first. Painting
    -- across a cell boundary is never what someone means on a sprite sheet, and
    -- silently ignoring a click in another cell is worse than moving to it.
    local bucket, frame = Sheet.cellAt(sheet, x, y)
    if bucket then self:setCell(bucket, frame) end

    self.strokeBounds = self:activeBounds()

    if self.tool == 'pick' then
        local index = Sheet.get(sheet, x, y)
        if index and index > 0 then
            self.color = index
            self:log(('picked colour %d'):format(index))
        end
        return
    end

    if self.tool == 'rect' then
        self.dragTool = 'rect'
        self.rectFrom = { x = x, y = y }
        self.rectTo = { x = x, y = y }
        return
    end

    if self.tool == 'fill' then
        local diff = Sheet.diff('fill')
        local n = Sheet.fill(sheet, x, y, self:paintIndex(), diff, self.strokeBounds)
        if n > 0 then self:record(diff) end
        return
    end

    self.dragTool = self.tool
    self.stroke = Sheet.diff(self.tool)
    self.synced = 0
    self.lastX, self.lastY = x, y
    Sheet.stamp(sheet, x, y, self:paintIndex(), self.brush, self.stroke, self.strokeBounds)
    self:syncStroke()
end

function Panel:strokeMove(x, y)
    if self.dragTool == 'rect' then
        self.rectTo = { x = x, y = y }
        return
    end
    if not self.stroke then return end

    if x ~= self.lastX or y ~= self.lastY then
        Sheet.line(self.sheet, self.lastX, self.lastY, x, y,
                   self:paintIndex(), self.brush, self.stroke, self.strokeBounds)
        self.lastX, self.lastY = x, y
        self:syncStroke()
    end
end

function Panel:strokeEnd()
    if self.dragTool == 'rect' and self.rectFrom and self.rectTo then
        local diff = Sheet.diff('rect')
        local n = Sheet.rectangle(self.sheet, self.rectFrom.x, self.rectFrom.y,
                                  self.rectTo.x, self.rectTo.y, self:paintIndex(),
                                  { filled = self.rectFilled }, diff, self.strokeBounds)
        if n > 0 then self:record(diff) end
        self.rectFrom, self.rectTo = nil, nil
    elseif self.stroke then
        if self.stroke.n > 0 then
            self.history:push(self.stroke)
            self.dirty = true
        end
    end

    self.stroke = nil
    self.dragTool = nil
    self.synced = 0
end

-- Pushes the pixels a live stroke has added since last frame into the picture.
function Panel:syncStroke()
    local diff = self.stroke
    if not diff then return end
    if diff.n > (self.synced or 0) then
        SheetImage.applyDiff(self.sheet, self.imageData, diff, false, self.synced + 1, diff.n)
        self.synced = diff.n
        self.imageDirty = true
    end
end

function Panel:clearCell()
    local diff = Sheet.diff('clear cell')
    if Sheet.clearCell(self.sheet, self.bucket, self.frame, diff) > 0 then
        self:record(diff)
    end
end

function Panel:copyCell()
    self.clipCell = { bucket = self.bucket, frame = self.frame }
    self:log(('copied bucket %d frame %d'):format(self.bucket, self.frame))
end

function Panel:pasteCell()
    if not self.clipCell then
        self:log('nothing copied yet', 'warn')
        return false
    end
    local diff = Sheet.diff('paste cell')
    local n = Sheet.copyCell(self.sheet, self.clipCell.bucket, self.clipCell.frame,
                             self.bucket, self.frame, diff)
    if n > 0 then self:record(diff) end
    return n > 0
end

---------------------------------------------------------------------------
-- Drawing the canvas
---------------------------------------------------------------------------

local function quadFor(self, bucket, frame)
    local x, y, w, h = Sheet.cell(self.sheet, bucket, frame)
    if not x then return nil end

    if not self.quad then
        self.quad = Platform.gfx.newQuad(x, y, w, h, self.sheet.width, self.sheet.height)
    else
        self.quad:setViewport(x, y, w, h, self.sheet.width, self.sheet.height)
    end
    return self.quad
end

-- A checkerboard, drawn in screen space and clipped to the viewport, so its cost
-- is bounded by the size of the window rather than by the zoom or the sheet.
local function checkerboard(vp, x0, y0, x1, y1)
    local size = 8
    local light = { 0.18, 0.18, 0.21 }
    local dark = { 0.13, 0.13, 0.16 }

    UI.rect(x0, y0, x1 - x0, y1 - y0, dark)

    local startX = floor(x0 / size) * size
    local startY = floor(y0 / size) * size
    for y = startY, y1, size do
        for x = startX, x1, size do
            if (floor(x / size) + floor(y / size)) % 2 == 0 then
                UI.rect(max(x, x0), max(y, y0),
                        min(size, x1 - x), min(size, y1 - y), light)
            end
        end
    end
end

function Panel:drawCanvas(vp)
    local sheet = self.sheet

    UI.rect(vp.x, vp.y, vp.w, vp.h, { 0.07, 0.07, 0.09 })
    if vp.w < 20 or vp.h < 20 then return end

    if self.needsFit then self:fit(vp) end
    if self.pendingCellZoom then self:zoomToCell(vp) end
    self:syncImage()

    local ox, oy = self:originIn(vp)
    local zoom = self.zoom
    local sw, sh = sheet.width * zoom, sheet.height * zoom

    UI.pushClip(vp.x, vp.y, vp.w, vp.h)

    local x0 = max(vp.x, ox)
    local y0 = max(vp.y, oy)
    local x1 = min(vp.x + vp.w, ox + sw)
    local y1 = min(vp.y + vp.h, oy + sh)

    if x1 > x0 and y1 > y0 then
        checkerboard(vp, x0, y0, x1, y1)
    end

    -- Onion skin: the previous frame of this bucket, faintly, under the current
    -- cell. Drawn before the sheet so it shows only where the current cell is
    -- transparent, which is the only place it is any use.
    if self.onion and sheet.frames > 1 and self.image then
        local prev = (self.frame - 1) % sheet.frames
        local quad = quadFor(self, self.bucket, prev)
        local cell = Sheet.cellBounds(sheet, self.bucket, self.frame)
        if quad and cell then
            Platform.gfx.setColor(1, 1, 1, 0.3)
            Platform.gfx.draw(self.image, quad, ox + cell.x * zoom, oy + cell.y * zoom,
                              0, zoom, zoom)
        end
    end

    if self.image then
        Platform.gfx.setColor(1, 1, 1, 1)
        Platform.gfx.draw(self.image, ox, oy, 0, zoom, zoom)
    end

    -- Pixel grid, only once a pixel is big enough for a line between them to mean
    -- anything rather than to swallow the picture.
    if zoom >= 5 then
        local grid = { 1, 1, 1, 0.07 }
        for x = 0, sheet.width do
            local px = ox + x * zoom
            if px >= vp.x and px <= vp.x + vp.w then
                UI.rect(px, max(y0, oy), 1, min(sh, y1 - max(y0, oy)), grid)
            end
        end
        for y = 0, sheet.height do
            local py = oy + y * zoom
            if py >= vp.y and py <= vp.y + vp.h then
                UI.rect(max(x0, ox), py, min(sw, x1 - max(x0, ox)), 1, grid)
            end
        end
    end

    -- Cell boundaries. Heavier than the pixel grid on purpose: this is the
    -- structure that matters and the one that is wrong when a sheet is wrong.
    local cellLine = { 0.45, 0.48, 0.56, 0.9 }
    for bucket = 0, sheet.angles do
        local py = oy + bucket * sheet.cellH * zoom
        UI.rect(ox, py, sw, 1, cellLine)
    end
    for frame = 0, sheet.frames do
        local px = ox + frame * sheet.cellW * zoom
        UI.rect(px, oy, 1, sh, cellLine)
    end

    -- Bucket and frame labels, in the margin the fit reserved for them. A grid
    -- with no numbers on it does not tell you that row 3 is bucket 3.
    local rowStep = sheet.cellH * zoom
    if rowStep >= UI.textHeight() + 2 and ox - vp.x >= LABEL_GUTTER - 4 then
        for bucket = 0, sheet.angles - 1 do
            local py = oy + bucket * rowStep + max(0, (rowStep - UI.textHeight()) / 2)
            UI.text('b' .. bucket, ox - LABEL_GUTTER + 2, py,
                    bucket == self.bucket and UI.theme.accent or UI.theme.textDim)
        end
    end

    local colStep = sheet.cellW * zoom
    if colStep >= UI.textWidth('f0') + 4 and oy - vp.y >= LABEL_HEADER - 2 then
        for frame = 0, sheet.frames - 1 do
            UI.text('f' .. frame, ox + frame * colStep + 2, oy - LABEL_HEADER + 1,
                    frame == self.frame and UI.theme.accent or UI.theme.textDim)
        end
    end

    -- The active cell. Everything above is context; this is where the next brush
    -- stroke will land.
    local active = Sheet.cellBounds(sheet, self.bucket, self.frame)
    if active then
        local ax, ay = ox + active.x * zoom, oy + active.y * zoom
        UI.rect(ax - 1, ay - 1, active.w * zoom + 2, active.h * zoom + 2,
                UI.theme.accent, 'line')
        UI.rect(ax - 2, ay - 2, active.w * zoom + 4, active.h * zoom + 4,
                UI.theme.accentDim, 'line')
    end

    -- The rectangle being dragged, before it is committed.
    if self.dragTool == 'rect' and self.rectFrom and self.rectTo then
        local lx = min(self.rectFrom.x, self.rectTo.x)
        local ly = min(self.rectFrom.y, self.rectTo.y)
        local hx = max(self.rectFrom.x, self.rectTo.x)
        local hy = max(self.rectFrom.y, self.rectTo.y)
        UI.rect(ox + lx * zoom, oy + ly * zoom,
                (hx - lx + 1) * zoom, (hy - ly + 1) * zoom, UI.theme.warn, 'line')
    end

    -- The pixel under the cursor, so a one-pixel brush at 4x zoom is aimable.
    if self.hoverX and Sheet.get(sheet, self.hoverX, self.hoverY) ~= nil then
        local half = floor((self.brush - 1) / 2)
        UI.rect(ox + (self.hoverX - half) * zoom, oy + (self.hoverY - half) * zoom,
                self.brush * zoom, self.brush * zoom, { 1, 1, 1, 0.55 }, 'line')
    end

    UI.popClip()
    UI.rect(vp.x, vp.y, vp.w, vp.h, UI.theme.border, 'line')
end

---------------------------------------------------------------------------
-- Input over the canvas
---------------------------------------------------------------------------

function Panel:handleCanvas(vp)
    local over, held, pressed = UI.hit('sprite/canvas', vp.x, vp.y, vp.w, vp.h)
    local mx, my = UI.state.mx, UI.state.my
    local sx, sy = self:toSheet(vp, mx, my)

    self.hoverX, self.hoverY = (over or held) and sx or nil, sy
    self.canvasRect = vp

    -- Right-drag pans. The middle button would be the other convention, and
    -- laptop trackpads mostly do not have one.
    local rightDown = Platform.input.mouseDown(2)
    if rightDown and (over or self.panning) then
        if self.panning and self.lastMX then
            self.panX = self.panX + (mx - self.lastMX)
            self.panY = self.panY + (my - self.lastMY)
        end
        self.panning = true
        self.hoverX = nil
    else
        self.panning = false
    end
    self.lastMX, self.lastMY = mx, my

    if self.panning then return end

    if pressed then
        self:strokeBegin(sx, sy)
    end

    if self.dragTool or self.stroke then
        if UI.state.mouseDown and held then
            self:strokeMove(sx, sy)
        elseif not UI.state.mouseDown then
            self:strokeEnd()
        end
    end
end

---------------------------------------------------------------------------
-- The live preview
--
-- This is the assertion the panel makes visually: the facing you see here is the
-- facing the renderer will draw, because it is computed by meatray.sim.billboard,
-- the same module meatray.render.sprites calls. A preview that reimplemented the
-- bucket choice could agree with the painter and disagree with the game, which is
-- the exact failure the painter exists to prevent.
---------------------------------------------------------------------------

function Panel:previewState()
    local sheet = self.sheet
    local dist = self.previewDistance or 3

    local camX, camY = cos(self.orbit) * dist, sin(self.orbit) * dist
    local dirX, dirY = -cos(self.orbit), -sin(self.orbit)
    local planeX, planeY = -dirY * 0.66, dirX * 0.66

    local bearing = Billboard.bearing(camX, camY, 0, 0)
    local bucket = Billboard.angleBucket(self.facing, bearing, sheet.angles)
    local frame = Billboard.animFrame(self.time, sheet.frames, self.fps)

    return {
        camX = camX, camY = camY,
        dirX = dirX, dirY = dirY,
        planeX = planeX, planeY = planeY,
        bearing = bearing,
        bucket = bucket,
        frame = frame,
    }
end

function Panel:drawPreview(rect)
    local sheet = self.sheet
    local view = self:previewState()

    local box = Rect.new(rect.x, rect.y, rect.w, max(40, rect.h - 96))
    UI.rect(box.x, box.y, box.w, box.h, { 0.05, 0.05, 0.07 })

    UI.pushClip(box.x, box.y, box.w, box.h)

    local tx, ty = Billboard.project(0, 0, view.camX, view.camY,
                                     view.dirX, view.dirY, view.planeX, view.planeY)

    -- The horizon, and the floor the sprite's feet land on. Those are not the same
    -- line: 'feet' anchoring puts the sprite on the base of a unit-high wall at
    -- that depth, which is below the horizon by half a wall. Drawing only the
    -- horizon makes a correctly anchored sprite look like it is floating low.
    UI.rect(box.x, box.y + box.h / 2, box.w, 1, { 0.16, 0.17, 0.20 })
    if ty then
        local wallH = box.h / ty
        UI.rect(box.x, floor(box.y + box.h / 2 + wallH / 2), box.w, 1,
                { 0.24, 0.26, 0.31 })
    end

    local drew = false
    if tx and self.image then
        local screen = Billboard.screenRect(tx, ty, box.w, box.h, {
            scale = self.previewScale,
            anchor = self.anchor,
        })
        if screen then
            local quad = quadFor(self, view.bucket, view.frame)
            if quad then
                Platform.gfx.setColor(1, 1, 1, 1)
                Platform.gfx.draw(self.image, quad,
                                  box.x + screen.x, box.y + screen.y, 0,
                                  screen.w / sheet.cellW, screen.h / sheet.cellH)
                drew = true
            end
        end
    end

    if not drew then
        UI.text('nothing to project', box.x + 6, box.y + 6, UI.theme.textDim)
    end

    UI.popClip()
    UI.rect(box.x, box.y, box.w, box.h, UI.theme.border, 'line')

    local y = box.y + box.h + 4

    -- The two numbers the whole panel is about. Highlighted when the preview is
    -- showing a cell other than the one being edited, because that is the moment
    -- to notice that bucket 3 is not what you thought bucket 3 was.
    local matches = (view.bucket == self.bucket)
    UI.text(('bucket %d/%d   frame %d/%d')
            :format(view.bucket, sheet.angles - 1, view.frame, sheet.frames - 1),
            rect.x, y, matches and UI.theme.ok or UI.theme.warn)
    y = y + UI.textHeight() + 2

    -- Jumping the canvas to whatever the preview is showing. This is the move that
    -- closes the loop: turn the sprite until something looks wrong, then edit the
    -- exact cell that is wrong, without counting rows.
    local editW = min(rect.w - 58, 108)
    if UI.button('sprite/preview/edit', 'Edit this cell', rect.x, y, { w = editW }) then
        self:setCell(view.bucket, view.frame)
        self.pendingCellZoom = true
    end
    if UI.button('sprite/preview/play', self.playing and 'Pause' or 'Play',
                 rect.x + editW + 4, y, { w = 50 }) then
        self.playing = not self.playing
    end
    y = y + 24

    -- The label column is measured rather than guessed. A fixed 44 pixels fits
    -- 'facing' and clips 'camera', which is the kind of thing that only shows up
    -- in a screenshot.
    local gutter = max(UI.textWidth('facing'), UI.textWidth('camera')) + 8

    local sliderW = max(20, rect.w - gutter - 4)

    UI.text('facing', rect.x, y, UI.theme.textDim)
    sliderTrack(rect.x + gutter, y, sliderW)
    self.facing = UI.slider('sprite/preview/facing', self.facing, 0, pi * 2,
                            rect.x + gutter, y, sliderW)
    y = y + 20

    UI.text('camera', rect.x, y, UI.theme.textDim)
    sliderTrack(rect.x + gutter, y, sliderW)
    self.orbit = UI.slider('sprite/preview/orbit', self.orbit, 0, pi * 2,
                           rect.x + gutter, y, sliderW)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function Panel:drawToolbar(rect)
    local x = rect.x
    local y = rect.y

    for _, tool in ipairs(TOOLS) do
        local selected = (self.tool == tool.id)
        local pressed, w = UI.button('sprite/tool/' .. tool.id,
                                     (selected and '> ' or '') .. tool.label, x, y)
        if pressed then self.tool = tool.id end
        if selected then
            UI.rect(x, y + UI.textHeight() + UI.metrics.padding - 2, w, 2, UI.theme.accent)
        end
        x = x + w + 3
    end

    x = x + 6
    UI.text('size', x, y + 4, UI.theme.textDim)
    x = x + UI.textWidth('size') + 4
    if UI.button('sprite/brush/less', '-', x, y, { w = STEP_W }) then
        self.brush = max(1, self.brush - 1)
    end
    x = x + STEP_W + 3
    UI.text(tostring(self.brush), x, y + 4)
    x = x + UI.textWidth('00') + 3
    if UI.button('sprite/brush/more', '+', x, y, { w = STEP_W }) then
        self.brush = min(16, self.brush + 1)
    end
    x = x + STEP_W + 10

    local canUndo = self.history:canUndo()
    local canRedo = self.history:canRedo()
    local pressedUndo, uw = UI.button('sprite/undo', 'Undo', x, y, { disabled = not canUndo })
    if pressedUndo then self:undo() end
    x = x + uw + 3
    local pressedRedo, rw = UI.button('sprite/redo', 'Redo', x, y, { disabled = not canRedo })
    if pressedRedo then self:redo() end
    x = x + rw + 3
end

function Panel:drawCellBar(rect)
    local sheet = self.sheet
    local x = rect.x
    local y = rect.y

    -- A stepper: `< n/max >`. Returns the x to carry on from.
    local function stepper(id, label, value, limit, onStep)
        UI.text(label, x, y + 4, UI.theme.textDim)
        x = x + UI.textWidth(label) + 4
        if UI.button(id .. '/prev', '<', x, y, { w = STEP_W }) then onStep(-1) end
        x = x + STEP_W + 3
        UI.text(('%d/%d'):format(value, limit), x, y + 4, UI.theme.accent)
        x = x + UI.textWidth('00/00') + 3
        if UI.button(id .. '/next', '>', x, y, { w = STEP_W }) then onStep(1) end
        x = x + STEP_W + 10
    end

    stepper('sprite/bucket', 'bucket', self.bucket, sheet.angles - 1, function(d)
        self:setCell(self.bucket + d, self.frame)
    end)
    stepper('sprite/frame', 'frame', self.frame, sheet.frames - 1, function(d)
        self:setCell(self.bucket, self.frame + d)
    end)

    local _, lockHit = UI.checkbox('sprite/lock', 'lock', self.lockToCell, x, y + 3)
    if lockHit then self.lockToCell = not self.lockToCell end
    x = x + UI.textWidth('lock') + UI.textHeight() + 14

    local _, onionHit = UI.checkbox('sprite/onion', 'onion', self.onion, x, y + 3)
    if onionHit then self.onion = not self.onion end
    x = x + UI.textWidth('onion') + UI.textHeight() + 14

    if UI.button('sprite/zoom/out', '-', x, y, { w = STEP_W }) then
        self.zoom = max(MIN_ZOOM, self.zoom - 1)
    end
    x = x + STEP_W + 3
    UI.text(('%dx'):format(self.zoom), x, y + 4, UI.theme.textDim)
    x = x + UI.textWidth('00x') + 3
    if UI.button('sprite/zoom/in', '+', x, y, { w = STEP_W }) then
        self.zoom = min(MAX_ZOOM, self.zoom + 1)
    end
    x = x + STEP_W + 6

    local fitPressed, fw = UI.button('sprite/zoom/fit', 'Fit', x, y)
    if fitPressed then self.needsFit = true end
    x = x + fw + 3

    local cellPressed, cw = UI.button('sprite/zoom/cell', 'Cell', x, y)
    if cellPressed then self.pendingCellZoom = true end
    x = x + cw + 3
end

function Panel:draw(rect, shell)
    local rowH = UI.metrics.rowHeight + 6

    local toolbar, rest = Rect.split(rect, 'top', rowH)
    local cellbar, body = Rect.split(rest, 'top', rowH)

    self:drawToolbar(toolbar)
    self:drawCellBar(cellbar)

    local canvasRect, previewRect = body, nil
    if body.w > 420 then
        previewRect, canvasRect = Rect.split(body, 'right', floor(min(210, body.w * 0.36)))
        previewRect = Rect.inset(previewRect, 6, 2)
        canvasRect = Rect.inset(canvasRect, 0, 2)
    end

    -- Input before drawing, so what is drawn this frame already includes the dab
    -- that was just painted. The other order shows every stroke one frame late,
    -- which reads as input lag.
    self:handleCanvas(canvasRect)
    self:drawCanvas(canvasRect)

    if previewRect then self:drawPreview(previewRect) end
end

---------------------------------------------------------------------------
-- Sidebar: the sheet, and the files it comes from and goes to
---------------------------------------------------------------------------

function Panel:drawSidebar(rect, shell)
    local rowH = UI.metrics.rowHeight + 2
    local w = rect.w - 4
    local half = floor((w - 4) / 2)
    local y = rect.y

    UI.text('Sheet', rect.x, y, UI.theme.textDim); y = y + rowH

    self.name = UI.textField('sprite/name', self.name, rect.x, y, w,
                             { placeholder = 'sprite name' })
    y = y + rowH + 4

    UI.text('buckets', rect.x, y, UI.theme.textDim)
    UI.text('frames', rect.x + half + 4, y, UI.theme.textDim)
    y = y + 16
    self.fieldAngles = UI.textField('sprite/angles', self.fieldAngles, rect.x, y, half)
    self.fieldFrames = UI.textField('sprite/frames', self.fieldFrames,
                                    rect.x + half + 4, y, half)
    y = y + rowH + 4

    UI.text('cell w', rect.x, y, UI.theme.textDim)
    UI.text('cell h', rect.x + half + 4, y, UI.theme.textDim)
    y = y + 16
    self.fieldCellW = UI.textField('sprite/cellw', self.fieldCellW, rect.x, y, half)
    self.fieldCellH = UI.textField('sprite/cellh', self.fieldCellH,
                                   rect.x + half + 4, y, half)
    y = y + rowH + 4

    if UI.button('sprite/new', 'New sheet', rect.x, y, { w = half }) then
        self:newSheet(false)
    end
    if UI.button('sprite/blank', 'Blank', rect.x + half + 4, y, { w = half }) then
        self:newSheet(true)
    end
    y = y + rowH + 2

    if UI.button('sprite/regrid', 'Regrid (same pixels)', rect.x, y, { w = w }) then
        self:regrid()
    end
    y = y + rowH + 8

    ---------------------------------------------------------------------
    UI.text('Files', rect.x, y, UI.theme.textDim); y = y + rowH

    local committed
    self.fieldPath, committed = UI.textField('sprite/path', self.fieldPath, rect.x, y, w,
                                             { placeholder = 'assets/sprites/x.png' })
    if committed then self:load(self.fieldPath) end
    y = y + rowH + 2

    if UI.button('sprite/load', 'Load', rect.x, y, { w = half }) then
        self:load(self.fieldPath)
    end
    if UI.button('sprite/export', 'Export', rect.x + half + 4, y, { w = half }) then
        self:export()
    end
    y = y + rowH + 2

    if UI.button('sprite/register', 'Export + register', rect.x, y, { w = w }) then
        self.path = nil          -- always write before registering
        self:register()
    end
    y = y + rowH + 6

    UI.textClipped(self.path or '(not exported)', rect.x, y, w,
                   self.path and UI.theme.ok or UI.theme.textDim)
    y = y + rowH

    if self.dirty then
        UI.text('unsaved changes', rect.x, y, UI.theme.warn)
    else
        UI.text('no unsaved changes', rect.x, y, UI.theme.textDim)
    end
    y = y + rowH + 6

    ---------------------------------------------------------------------
    UI.text('Cell', rect.x, y, UI.theme.textDim); y = y + rowH

    if UI.button('sprite/cell/copy', 'Copy', rect.x, y, { w = half }) then
        self:copyCell()
    end
    if UI.button('sprite/cell/paste', 'Paste', rect.x + half + 4, y,
                 { w = half, disabled = self.clipCell == nil }) then
        self:pasteCell()
    end
    y = y + rowH + 2

    if UI.button('sprite/cell/clear', 'Clear cell', rect.x, y, { w = w }) then
        self:clearCell()
    end
    y = y + rowH + 2

    if self.clipCell then
        UI.textClipped(('copied: b%d f%d'):format(self.clipCell.bucket, self.clipCell.frame),
                       rect.x, y, w, UI.theme.textDim)
    end
end

---------------------------------------------------------------------------
-- Inspector: the palette, and what the sheet currently is
---------------------------------------------------------------------------

function Panel:drawInspector(rect, shell)
    local sheet = self.sheet
    local y = rect.y

    UI.text('Palette', rect.x, y, UI.theme.textDim); y = y + UI.metrics.rowHeight

    local swatch = 18
    local gap = 2
    local perRow = max(1, floor((rect.w + gap) / (swatch + gap)))
    local count = Sheet.colorCount(sheet)

    -- Transparent first, as a swatch of its own. An eraser is a tool; transparent
    -- is also a colour, and picking it from the palette is how you get a hole in
    -- the middle of a shape with the brush you already have.
    local total = count + 1
    for i = 0, count do
        local col = i % perRow
        local row = floor(i / perRow)
        local sxp = rect.x + col * (swatch + gap)
        local syp = y + row * (swatch + gap)

        local _, _, _, activated = UI.hit('sprite/swatch/' .. i, sxp, syp, swatch, swatch)
        if activated then self.color = i end

        if i == 0 then
            UI.rect(sxp, syp, swatch, swatch, { 0.16, 0.16, 0.19 })
            UI.rect(sxp, syp, swatch / 2, swatch / 2, { 0.11, 0.11, 0.14 })
            UI.rect(sxp + swatch / 2, syp + swatch / 2, swatch / 2, swatch / 2,
                    { 0.11, 0.11, 0.14 })
        else
            local r, g, b, a = Sheet.color(sheet, i)
            UI.rect(sxp, syp, swatch, swatch, { r / 255, g / 255, b / 255, a / 255 })
        end

        UI.rect(sxp, syp, swatch, swatch,
                i == self.color and UI.theme.accent or UI.theme.border, 'line')
    end

    y = y + math.ceil(total / perRow) * (swatch + gap) + 6

    -- Editing the selected slot recolours every pixel already drawn in it, which
    -- is the point: a sheet should be recolourable without being repainted.
    if self.color > 0 then
        local r, g, b, a = Sheet.color(sheet, self.color)
        local sliderW = max(20, rect.w - 22)
        local changed = false
        local values = { r, g, b, a }

        for i, label in ipairs({ 'R', 'G', 'B', 'A' }) do
            UI.text(label, rect.x, y, UI.theme.textDim)
            sliderTrack(rect.x + 14, y, sliderW)
            local v = UI.slider('sprite/colour/' .. label, values[i], 0, 255,
                                rect.x + 14, y, sliderW, { step = 1 })
            if floor(v + 0.5) ~= values[i] then
                values[i] = floor(v + 0.5)
                changed = true
            end
            y = y + 18
        end

        if changed then
            Sheet.setColor(sheet, self.color, values[1], values[2], values[3], values[4])
            self.dirty = true
            self:rebuildImage()
        end

        UI.text(('#%02X%02X%02X %d%%'):format(r, g, b, floor(a / 255 * 100 + 0.5)),
                rect.x, y, UI.theme.textDim)
        y = y + UI.textHeight() + 2
    else
        UI.text('transparent selected', rect.x, y, UI.theme.textDim)
        y = y + UI.textHeight() + 2
    end

    if UI.button('sprite/colour/add', 'Duplicate colour', rect.x, y, { w = rect.w - 4 }) then
        local r, g, b, a = Sheet.color(sheet, max(1, self.color))
        -- Nudged, or the duplicate would dedupe straight back onto the original.
        local index, why = Sheet.addColor(sheet, min(255, r + 1), g, b, a)
        if index then self.color = index else self:log(tostring(why), 'warn') end
    end
    y = y + UI.metrics.rowHeight + 8

    ---------------------------------------------------------------------
    UI.text('Sheet', rect.x, y, UI.theme.textDim); y = y + UI.metrics.rowHeight

    y = y + UI.labelValue('size', ('%dx%d'):format(sheet.width, sheet.height),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('grid', ('%d x %d'):format(sheet.angles, sheet.frames),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('cell', ('%dx%d'):format(sheet.cellW, sheet.cellH),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('colours', Sheet.colorCount(sheet), rect.x, y, rect.w)
    y = y + UI.labelValue('editing', ('b%d f%d'):format(self.bucket, self.frame),
                          rect.x, y, rect.w, { color = UI.theme.accent })

    -- Which buckets have been drawn at all. On a half-finished directional sheet
    -- this is the question, and the answer is otherwise "click through 32 cells".
    local coverage = Sheet.coverage(sheet)
    local drawn = 0
    for i = 1, Sheet.cellCount(sheet) do
        if (coverage.cells[i] or 0) > 0 then drawn = drawn + 1 end
    end
    y = y + UI.labelValue('cells drawn', ('%d/%d'):format(drawn, Sheet.cellCount(sheet)),
                          rect.x, y, rect.w,
                          { color = drawn == Sheet.cellCount(sheet)
                                    and UI.theme.ok or UI.theme.warn })

    y = y + 6
    UI.textClipped(self.history:describe(), rect.x, y, rect.w, UI.theme.textDim)
    y = y + UI.textHeight() + 2

    if self.hoverX and Sheet.get(sheet, self.hoverX, self.hoverY) then
        local bucket, frame = Sheet.cellAt(sheet, self.hoverX, self.hoverY)
        local lx, ly = Sheet.localAt(sheet, self.hoverX, self.hoverY)
        UI.textClipped(('%d,%d = b%d f%d @ %d,%d')
                       :format(self.hoverX, self.hoverY, bucket, frame, lx, ly),
                       rect.x, y, rect.w, UI.theme.textDim)
    end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

function Panel:update(dt)
    if self.playing then self.time = self.time + dt end
end

function Panel:wheelmoved(dx, dy)
    if not self.canvasRect or (dy or 0) == 0 then return false end
    local mx, my = UI.state.mx, UI.state.my
    if not Rect.contains(self.canvasRect, mx, my) then return false end

    self:zoomAt(self.canvasRect, dy > 0 and 1 or -1, mx, my)
    return true
end

function Panel:keypressed(key, shell)
    -- The shell forwards keys to the active panel even while a text field has
    -- focus, so that a panel can still see Escape. Without this guard, typing a
    -- name into the sidebar would also switch tools and step through buckets.
    if UI.wantsKeyboard() then return false end

    local keyDown = Platform.input.keyDown
    local ctrl = keyDown('lctrl', 'rctrl')
    local shift = keyDown('lshift', 'rshift')

    if ctrl and key == 'z' then
        if shift then self:redo() else self:undo() end
        return true
    end
    if ctrl and key == 'y' then self:redo(); return true end
    if ctrl and key == 's' then self:export(); return true end

    for _, tool in ipairs(TOOLS) do
        if key == tool.key then self.tool = tool.id; return true end
    end

    if key == 'left' then self:setCell(self.bucket, self.frame - 1); return true end
    if key == 'right' then self:setCell(self.bucket, self.frame + 1); return true end
    if key == 'up' then self:setCell(self.bucket - 1, self.frame); return true end
    if key == 'down' then self:setCell(self.bucket + 1, self.frame); return true end

    if key == '[' then self.brush = max(1, self.brush - 1); return true end
    if key == ']' then self.brush = min(16, self.brush + 1); return true end

    if key == '-' or key == 'kp-' then
        self.zoom = max(MIN_ZOOM, self.zoom - 1); return true
    end
    if key == '=' or key == 'kp+' then
        self.zoom = min(MAX_ZOOM, self.zoom + 1); return true
    end
    if key == 'home' then self.needsFit = true; return true end
    if key == 'end' then self.pendingCellZoom = true; return true end

    if key == 'o' then self.onion = not self.onion; return true end
    if key == 'l' then self.lockToCell = not self.lockToCell; return true end
    if key == 'space' then self.playing = not self.playing; return true end
    if key == 'c' then self:copyCell(); return true end
    if key == 'v' then self:pasteCell(); return true end
    if key == 'delete' or key == 'backspace' then self:clearCell(); return true end

    return false
end

Panel.TOOLS = TOOLS

return Panel
