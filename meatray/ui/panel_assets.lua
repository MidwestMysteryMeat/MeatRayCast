--[[
    meatray.ui.panel_assets — browse, preview, import.

    The front end for meatray.asset, and the reason import settings are worth
    having a UI for at all: angle-bucket and frame counts are two numbers that are
    easy to get wrong by hand, produce no error when wrong, and are immediately
    obvious the moment you can see bucket 3 of 8 rendered at size. A dialog that
    only asked for them would be a worse version of typing them into a Lua file.
    One that shows you the result is a different tool.

    Four categories, one grid, one preview:

        sprites   the sheet, stepped through its buckets, animating
        sounds    audition, with the distance/pan mix it would play at
        maps      dimensions, doors, entities, and a top-down thumbnail
        themes    the wall palette the procedural textures are built from

    Missing assets are drawn distinctly rather than omitted. An asset that was
    asked for and did not arrive is the single most useful thing this panel can
    tell you, and a browser that quietly skips them tells you nothing at all.

    Panel contract, per meatray.ui.shell: `id`, `title`, `draw(rect, shell)`, and
    optionally `drawSidebar`, `drawInspector`, `update`, `keypressed`, `attach`.
]]

local Platform = require('meatray.platform')
local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')
local Asset = require('meatray.asset')
local Slice = require('meatray.asset.slice')
local Names = require('meatray.asset.names')
local Billboard = require('meatray.sim.billboard')

local Panel = {}
Panel.__index = Panel

local floor, max, min = math.floor, math.max, math.min

local CELL = 74
local GAP = 8

local CATEGORIES = {
    { id = 'sprites', label = 'Sprites' },
    { id = 'sounds',  label = 'Sounds' },
    { id = 'maps',    label = 'Maps' },
    { id = 'themes',  label = 'Themes' },
}

---------------------------------------------------------------------------

function Panel.new(opts)
    opts = opts or {}

    local self = setmetatable({
        id = 'assets',
        title = 'Assets',

        category = 1,
        selected = 1,
        items = {},
        found = {},          -- importable files seen on disk, not yet wired in
        time = 0,

        bucket = 0,          -- which angle row the sprite preview is showing
        autoTurn = true,     -- step through the buckets on a timer

        -- Where the preview pretends the listener and the source are, so the
        -- falloff and pan numbers mean something before a sound is in a level.
        -- Off to one side by default: a source dead ahead pans to zero, which
        -- looks identical to panning being broken.
        listener = { x = 0, y = 0, angle = 0 },
        auditionX = 2,
        auditionY = 2,

        importPath = opts.importPath or '',
        importName = '',
        importAngles = '1',
        importFrames = '1',

        scanRoots = opts.scanRoots or { 'assets', 'maps' },
    }, Panel)

    -- Opening on a named category, so a tool that wants the browser on sounds can
    -- say so rather than reaching into the panel's state after construction.
    if opts.category then
        for i, category in ipairs(CATEGORIES) do
            if category.id == opts.category then self.category = i end
        end
    end

    return self
end

function Panel:attach(shell)
    if self.shell == shell then return end
    self.shell = shell
    self:refresh()
    if shell then
        shell:log('assets: ' .. Asset.summaryLine())
    end
end

function Panel:log(text, level)
    if self.shell then self.shell:log(text, level) end
end

---------------------------------------------------------------------------
-- Gathering
--
-- Two different things are listed, and conflating them would be a mistake:
-- what the project has *declared* (which may be missing) and what is *on disk*
-- (which may not be wired in yet). The grid shows the first; the sidebar shows
-- the second, as candidates for import.
---------------------------------------------------------------------------

local function spriteItems()
    local Sprites = require('meatray.render.sprites')
    local out, seen = {}, {}

    -- Registry records first: these are the ones that can be missing.
    for _, record in ipairs(Asset.records('sprite')) do
        Asset.registry.resolve(record.name, 'sprite')
        seen[record.name] = true
        out[#out + 1] = {
            name = record.name, kind = 'sprite',
            record = record,
            def = Sprites.get(record.name),
        }
    end

    -- Then anything defined straight through Sprites.define, which is how the
    -- demo and the selftest declare their placeholders. Deliberately not
    -- registered on sight: declaring them here would re-run Sprites.define under
    -- the registry's settings and quietly replace a definition the game made.
    for _, name in ipairs(Sprites.names()) do
        if not seen[name] then
            out[#out + 1] = {
                name = name, kind = 'sprite',
                def = Sprites.get(name),
            }
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function soundItems()
    local out = {}
    for _, record in ipairs(Asset.records('sound')) do
        Asset.registry.resolve(record.name, 'sound')
        out[#out + 1] = { name = record.name, kind = 'sound', record = record }
    end
    return out
end

local function mapItems()
    local out = {}
    for _, record in ipairs(Asset.records('map')) do
        Asset.registry.resolve(record.name, 'map')
        out[#out + 1] = { name = record.name, kind = 'map', record = record,
                          map = record.value }
    end
    return out
end

local function themeItems()
    local Themes = require('meatray.render.themes')
    local out = {}
    for _, name in ipairs(Themes.names()) do
        Asset.declareTheme(name)
        Asset.registry.resolve(name, 'theme')
        out[#out + 1] = { name = name, kind = 'theme', theme = Themes.get(name) }
    end
    return out
end

-- Walks the scan roots and declares what it can safely declare.
--
-- Maps and sounds are declared on sight: both registries are this module's own,
-- so a file appearing there cannot disturb anything. Images are not — a PNG named
-- `imp.png` declared automatically would resolve through Sprites.define with a
-- guessed grid and overwrite whatever the game defined as `imp`. Those are listed
-- as candidates and imported only when someone says so.
function Panel:scan()
    self.found = {}

    for _, root in ipairs(self.scanRoots) do
        for _, file in ipairs(Asset.scan(root)) do
            if file.kind == 'map' then
                if not Asset.get(file.name, 'map') then
                    Asset.declareMap(file.name, file.path)
                end
            elseif file.kind == 'sound' then
                if not Asset.get(file.name, 'sound') then
                    Asset.declareSound(file.name, { path = file.path })
                end
            elseif file.kind == 'image' then
                self.found[#self.found + 1] = file
            end
        end
    end
end

function Panel:refresh()
    self:scan()

    local gather = {
        sprites = spriteItems,
        sounds = soundItems,
        maps = mapItems,
        themes = themeItems,
    }

    self.items = gather[CATEGORIES[self.category].id]()
    self.selected = max(1, min(self.selected, max(1, #self.items)))
end

function Panel:selectedItem()
    return self.items[self.selected]
end

function Panel:setCategory(index)
    if index == self.category then return end
    self.category = index
    self.selected = 1
    self.bucket = 0
    self:refresh()
end

---------------------------------------------------------------------------
-- Import
---------------------------------------------------------------------------

-- Wires a file into the registry. Reports the outcome to the console either way:
-- an import that silently does nothing is indistinguishable from one that worked
-- until the sprite fails to appear three minutes later.
function Panel:doImport()
    local path = (self.importPath or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if path == '' then
        self:log('import: give a path first', 'warn')
        return false
    end

    local name = self.importName
    if not name or name == '' then name = Names.fromPath(path) end

    local kind = Names.kindFor(path)

    if kind == 'sound' then
        local record = Asset.importSound(name, path)
        if record.state == 'file' then
            self:log(('imported sound "%s" from %s'):format(name, path), 'ok')
        else
            self:log(('sound "%s" did not load: %s'):format(name, tostring(record.problem)), 'error')
        end
        self:reveal(name, 'sounds')
        return record.state == 'file'
    end

    if kind == 'map' then
        Asset.declareMap(name, path)
        local record = Asset.registry.resolve(name, 'map', true)
        if record.state == 'file' then
            self:log(('imported map "%s" (%dx%d)'):format(name, record.value.width,
                                                          record.value.height), 'ok')
        else
            self:log(('map "%s" did not load: %s'):format(name, tostring(record.problem)), 'error')
        end
        self:reveal(name, 'maps')
        return record.state == 'file'
    end

    -- Anything else is treated as a sprite sheet, including a path with no
    -- extension: the loader's own "file not found" is a better message than a
    -- refusal from here about a file nobody has looked for yet.
    local angles = tonumber(self.importAngles) or 1
    local frames = tonumber(self.importFrames) or 1

    local record = Asset.importSprite(name, path, { angles = angles, frames = frames })

    if record.state == 'file' then
        self:log(('imported sprite "%s": %d bucket%s x %d frame%s from %s')
            :format(name, angles, angles == 1 and '' or 's',
                    frames, frames == 1 and '' or 's', path), 'ok')
    else
        -- The grid mismatch message carries the numbers, and this is the one
        -- place they are worth reading in full.
        self:log(('sprite "%s" fell back to a placeholder: %s')
            :format(name, tostring(record.problem)), 'error')
    end

    self:reveal(name, 'sprites')
    return record.state == 'file'
end

-- Shows what was just imported, including its failure. Switching to the right
-- category matters most when the import went wrong: an error line in the console
-- and no visible change is the shape of a tool nobody trusts, whereas landing on
-- the red-bordered cell with the reason in the inspector is the whole answer.
function Panel:reveal(name, categoryId)
    for i, category in ipairs(CATEGORIES) do
        if category.id == categoryId then self.category = i end
    end
    self:refresh()
    self.bucket = 0
    return self:focusOn(name)
end

function Panel:focusOn(name)
    for i, item in ipairs(self.items) do
        if item.name == name then self.selected = i; return true end
    end
    return false
end

-- Prefills the import form from a file found on disk, including any grid hint in
-- its filename. This is the whole reason filename hints exist: the numbers are
-- already written down, so nobody should have to retype them.
function Panel:prefill(file)
    self.importPath = file.path
    self.importName = file.name
    if file.hints then
        self.importAngles = tostring(file.hints.angles)
        self.importFrames = tostring(file.hints.frames)
    else
        local Image = require('meatray.asset.image')
        local info = Image.inspect(file.path)
        if info then
            self.importAngles = tostring(info.angles)
            self.importFrames = tostring(info.frames)
        end
    end
end

---------------------------------------------------------------------------
-- Thumbnails
---------------------------------------------------------------------------

local function drawSpriteCell(def, x, y, w, h, bucket, frame)
    if not def or not def.image then return false end

    local b = min(bucket or 0, def.angles - 1)
    local f = min(frame or 0, def.frames - 1)
    local quad = def.quads[b] and def.quads[b][f]
    if not quad then return false end

    local scale = min(w / max(1, def.cellW), h / max(1, def.cellH))
    local dw, dh = def.cellW * scale, def.cellH * scale

    UI.setColor({ 1, 1, 1 })
    Platform.gfx.draw(def.image, quad,
                      floor(x + (w - dw) / 2), floor(y + (h - dh) / 2), 0, scale, scale)
    return true
end

-- A top-down thumbnail of a map, subsampled to fit. Cheap enough to draw every
-- frame at thumbnail size, and the only representation of a map that answers
-- "which one was that" at a glance.
local function drawMapCell(map, x, y, w, h, samples)
    if not map or not map.tiles then return false end

    samples = samples or 16
    local sx = max(1, floor(map.width / samples))
    local sy = max(1, floor(map.height / samples))

    local cols = math.ceil(map.width / sx)
    local rows = math.ceil(map.height / sy)
    local size = max(1, floor(min(w / max(1, cols), h / max(1, rows))))

    local ox = floor(x + (w - cols * size) / 2)
    local oy = floor(y + (h - rows * size) / 2)

    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local tile = map.tiles[row * sy + 1] and map.tiles[row * sy + 1][col * sx + 1] or 0
            local color = (tile == 0) and { 0.14, 0.15, 0.18 } or { 0.52, 0.50, 0.46 }
            UI.rect(ox + col * size, oy + row * size, size, size, color)
        end
    end
    return true
end

local function drawThemeCell(theme, x, y, w, h)
    if not theme or not theme.walls then return false end

    local swatches = {}
    for i = 1, 4 do swatches[#swatches + 1] = theme.walls[i] or theme.walls[1] end
    swatches[#swatches + 1] = theme.floor or { 0.2, 0.2, 0.2 }

    local band = h / #swatches
    for i, color in ipairs(swatches) do
        UI.rect(x, y + (i - 1) * band, w, band + 1, color)
    end
    return true
end

-- Sounds have no picture, so they get a deterministic bar figure derived from the
-- name. Not a waveform — reading the samples to draw one would mean decoding
-- every WAV in the project to fill a grid. Distinct per name is all a thumbnail
-- has to be.
local function drawSoundCell(name, x, y, w, h, playing)
    local bars = 9
    local bw = w / bars
    local seed = 0
    for i = 1, #name do seed = (seed * 31 + name:byte(i)) % 65536 end

    for i = 0, bars - 1 do
        seed = (seed * 1103515245 + 12345) % 65536
        local amp = 0.15 + (seed / 65536) * 0.8
        local bh = h * amp
        UI.rect(x + i * bw + 1, y + (h - bh) / 2, max(1, bw - 2), bh,
                playing and UI.theme.ok or UI.theme.accentDim)
    end
    return true
end

---------------------------------------------------------------------------
-- The grid
---------------------------------------------------------------------------

function Panel:drawGrid(rect, shell)
    local items = self.items

    if #items == 0 then
        UI.text('nothing in this category yet', rect.x, rect.y, UI.theme.textDim)
        UI.text('use Import in the sidebar, or Rescan', rect.x, rect.y + 18, UI.theme.textDim)
        return
    end

    local labelH = UI.textHeight() + 2
    local cellH = CELL + labelH

    local pos, contentH = Rect.grid(rect.w - UI.metrics.scrollbarWidth,
                                    CELL, cellH, GAP, #items)

    local offset = UI.beginScroll('assets/grid', rect.x, rect.y, rect.w, rect.h, contentH)

    for i, item in ipairs(items) do
        local dx, dy = pos(i)
        local x, y = rect.x + dx, rect.y + dy

        -- Drawing happens in content space (the scroll region has translated the
        -- canvas); hit testing happens in screen space. Passing content
        -- coordinates to UI.hit is how a scrolled grid ends up selecting the cell
        -- that used to be under the cursor.
        local over, _, _, activated = UI.hit('assets/cell/' .. i,
                                             x, y - offset, CELL, cellH)

        local record = item.record
        local missing = record and record.state == 'fallback'

        UI.rect(x, y, CELL, CELL, UI.theme.bg)

        local drew = false
        if item.kind == 'sprite' then
            drew = drawSpriteCell(item.def, x, y, CELL, CELL, self.bucket,
                                  Billboard.animFrame(self.time, item.def and item.def.frames,
                                                      item.def and item.def.fps))
        elseif item.kind == 'map' then
            drew = drawMapCell(item.map, x, y, CELL, CELL)
        elseif item.kind == 'theme' then
            drew = drawThemeCell(item.theme, x, y, CELL, CELL)
        elseif item.kind == 'sound' then
            drew = drawSoundCell(item.name, x + 6, y + 6, CELL - 12, CELL - 12,
                                 record and record.state == 'file')
        end

        if not drew then
            UI.text('?', x + CELL / 2 - 4, y + CELL / 2 - 8, UI.theme.textDim)
        end

        -- The border carries the state, which is what makes a missing asset
        -- findable in a grid of eighty.
        local border = UI.theme.border
        if missing then border = UI.theme.danger
        elseif i == self.selected then border = UI.theme.accent
        elseif over then border = UI.theme.hover end

        UI.rect(x, y, CELL, CELL, border, 'line')
        if i == self.selected then
            UI.rect(x - 1, y - 1, CELL + 2, CELL + 2, UI.theme.accent, 'line')
        end

        if missing then
            UI.rect(x + CELL - 14, y + 2, 12, 12, UI.theme.danger)
            UI.text('!', x + CELL - 11, y + 1, { 0, 0, 0 })
        elseif record and record.state == 'generated' then
            UI.rect(x + CELL - 14, y + 2, 12, 12, UI.theme.accentDim)
        end

        UI.textClipped(item.name, x, y + CELL + 1, CELL,
                       missing and UI.theme.danger or UI.theme.text)

        if activated then
            self.selected = i
            self.bucket = 0
        end
    end

    UI.endScroll('assets/grid', rect.x, rect.y, rect.w, rect.h, contentH)
end

---------------------------------------------------------------------------
-- The preview
---------------------------------------------------------------------------

function Panel:drawPreview(rect, shell)
    UI.rect(rect.x, rect.y, rect.w, rect.h, UI.theme.bg)
    UI.rect(rect.x, rect.y, rect.w, rect.h, UI.theme.border, 'line')

    local item = self:selectedItem()
    if not item then
        UI.text('nothing selected', rect.x + 8, rect.y + 8, UI.theme.textDim)
        return
    end

    local inner = Rect.inset(rect, 8)
    local y = inner.y

    UI.textClipped(item.name, inner.x, y, inner.w, UI.theme.text)
    y = y + 18

    local handler = {
        sprite = self.drawSpritePreview,
        sound = self.drawSoundPreview,
        map = self.drawMapPreview,
        theme = self.drawThemePreview,
    }

    local draw = handler[item.kind]
    if draw then
        draw(self, item, Rect.new(inner.x, y, inner.w, inner.y + inner.h - y), shell)
    end
end

function Panel:drawSpritePreview(item, rect, shell)
    local def = item.def
    if not def then
        UI.text('no sheet', rect.x, rect.y, UI.theme.textDim)
        return
    end

    local y = rect.y

    -- The bucket stepper. Seeing bucket 3 of 8 at size is the entire reason to
    -- have this panel rather than a config file: a sheet whose rows are in the
    -- wrong order looks fine everywhere except here.
    local buttonW = 26
    if UI.button('assets/bucket/prev', '<', rect.x, y, { w = buttonW }) then
        self.bucket = (self.bucket - 1) % def.angles
        self.autoTurn = false
    end
    if UI.button('assets/bucket/next', '>', rect.x + buttonW + 4, y, { w = buttonW }) then
        self.bucket = (self.bucket + 1) % def.angles
        self.autoTurn = false
    end

    local bucket = min(self.bucket, def.angles - 1)
    UI.text(('bucket %d/%d'):format(bucket + 1, def.angles),
            rect.x + buttonW * 2 + 14, y + 4, UI.theme.textDim)

    if UI.button('assets/bucket/auto', self.autoTurn and 'turning' or 'still',
                 rect.x + rect.w - 62, y, { w = 60 }) then
        self.autoTurn = not self.autoTurn
    end

    y = y + 26

    local frame = Billboard.animFrame(self.time, def.frames, def.fps)
    local box = Rect.new(rect.x, y, rect.w, max(40, rect.y + rect.h - y - 40))

    UI.rect(box.x, box.y, box.w, box.h, { 0.06, 0.06, 0.08 })
    drawSpriteCell(def, box.x, box.y, box.w, box.h, bucket, frame)
    UI.rect(box.x, box.y, box.w, box.h, UI.theme.border, 'line')

    y = box.y + box.h + 4
    UI.text(('frame %d/%d at %g fps'):format(frame + 1, def.frames, def.fps),
            rect.x, y, UI.theme.textDim)
    y = y + 16
    UI.text(('cell %dx%d  %s'):format(def.cellW, def.cellH,
                                      def.generated and 'generated' or 'imported'),
            rect.x, y, def.generated and UI.theme.warn or UI.theme.ok)
end

-- Plays a sound from the panel's own listener, then puts the real one back. The
-- browser borrowing the listener for the length of one audition is fine; keeping
-- it is not, because a game running behind the editor would then hear everything
-- from the origin.
function Panel:audition(name)
    local Sound = require('meatray.asset.sound')
    if not Sound.available() then return nil end

    local previous = Sound.getListener()
    Sound.setListener(self.listener.x, self.listener.y, self.listener.angle)

    local voice = Sound.playAt(name, self.auditionX, self.auditionY)

    if previous then
        Sound.setListener(previous.x, previous.y, previous.angle)
    else
        Sound.clearListener()
    end
    return voice
end

function Panel:drawSoundPreview(item, rect, shell)
    local Sound = require('meatray.asset.sound')
    local record = item.record
    local y = rect.y

    if not Sound.available() then
        UI.text('audio is off in this run', rect.x, y, UI.theme.warn)
        y = y + 18
    end

    local playable = Sound.available() and record and record.state == 'file'

    if UI.button('assets/sound/play', 'Audition', rect.x, y, { w = 84, disabled = not playable }) then
        if not self:audition(item.name) then
            self:log(('nothing to play for "%s"'):format(item.name), 'warn')
        end
    end
    if UI.button('assets/sound/flat', 'Flat', rect.x + 90, y,
                 { w = 60, disabled = not playable }) then
        Sound.play(item.name)
    end
    y = y + 28

    drawSoundCell(item.name, rect.x, y, rect.w, 46, playable)
    y = y + 54

    -- The mix numbers, so the falloff settings can be understood before a sound
    -- is wired into a level rather than after it turns out to be inaudible. The
    -- listener is passed in rather than set, so opening this panel beside a
    -- running game does not move that game's ears to the origin.
    local volume, pan, dist = Sound.previewMix(item.name, self.auditionX, self.auditionY,
                                               self.listener)

    y = y + UI.labelValue('distance', ('%.1f tiles'):format(dist), rect.x, y, rect.w)
    y = y + UI.labelValue('volume', ('%.2f'):format(volume), rect.x, y, rect.w)
    y = y + UI.labelValue('pan', ('%+.2f'):format(pan), rect.x, y, rect.w)

    local sliderY = y + 4
    UI.text('source x', rect.x, sliderY, UI.theme.textDim)
    self.auditionX = UI.slider('assets/sound/x', self.auditionX, -20, 20,
                               rect.x + 60, sliderY, max(20, rect.w - 64))
    sliderY = sliderY + 20
    UI.text('source y', rect.x, sliderY, UI.theme.textDim)
    self.auditionY = UI.slider('assets/sound/y', self.auditionY, -20, 20,
                               rect.x + 60, sliderY, max(20, rect.w - 64))

    y = sliderY + 24
    UI.text(('%d voice%s playing'):format(Sound.voiceCount(),
                                          Sound.voiceCount() == 1 and '' or 's'),
            rect.x, y, UI.theme.textDim)
end

function Panel:drawMapPreview(item, rect, shell)
    local map = item.map or (item.record and item.record.value)
    if not map then
        UI.text('map did not load', rect.x, rect.y, UI.theme.danger)
        return
    end

    local box = Rect.new(rect.x, rect.y, rect.w, max(40, rect.h - 90))
    UI.rect(box.x, box.y, box.w, box.h, { 0.06, 0.06, 0.08 })
    drawMapCell(map, box.x, box.y, box.w, box.h, 128)
    UI.rect(box.x, box.y, box.w, box.h, UI.theme.border, 'line')

    local y = box.y + box.h + 6
    y = y + UI.labelValue('size', ('%d x %d'):format(map.width, map.height), rect.x, y, rect.w)
    y = y + UI.labelValue('theme', map.theme or 'dungeon', rect.x, y, rect.w)
    y = y + UI.labelValue('doors', #(map.doors or {}), rect.x, y, rect.w)
    y = y + UI.labelValue('entities', #(map.entities or {}), rect.x, y, rect.w)
end

function Panel:drawThemePreview(item, rect, shell)
    local Themes = require('meatray.render.themes')
    local theme = item.theme or Themes.get(item.name)

    local box = Rect.new(rect.x, rect.y, rect.w, max(40, rect.h - 90))
    drawThemeCell(theme, box.x, box.y, box.w, box.h)
    UI.rect(box.x, box.y, box.w, box.h, UI.theme.border, 'line')

    local y = box.y + box.h + 6
    local atmos = Themes.atmosphere(item.name)
    y = y + UI.labelValue('atmosphere', theme.atmosphere or '-', rect.x, y, rect.w)
    if atmos then
        y = y + UI.labelValue('max view', ('%.0f tiles'):format(atmos.maxView or 0),
                              rect.x, y, rect.w)
    end
    y = y + UI.labelValue('textures', 'generated', rect.x, y, rect.w)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function Panel:draw(rect, shell)
    local tabs, body = Rect.split(rect, 'top', UI.metrics.rowHeight + 6)

    local cursor = tabs.x
    for i, category in ipairs(CATEGORIES) do
        local label = category.label
        local pressed, w = UI.button('assets/cat/' .. category.id,
                                     (i == self.category and '> ' or '  ') .. label,
                                     cursor, tabs.y)
        if pressed then self:setCategory(i) end
        cursor = cursor + w + 4
    end

    -- Two numbers, because they answer different questions: how many of these am
    -- I looking at, and how many of everything the project declared did not
    -- arrive. Showing only the registry total next to a category listing is how a
    -- header ends up disagreeing with the grid under it.
    local report = Asset.report()
    UI.text(('%d %s'):format(#self.items, CATEGORIES[self.category].id),
            cursor + 8, tabs.y + 4, UI.theme.textDim)
    cursor = cursor + 8 + UI.textWidth('00 sprites') + 10

    if report.missing > 0 then
        UI.text(('%d MISSING'):format(report.missing), cursor, tabs.y + 4, UI.theme.danger)
    else
        UI.text(('%d declared, none missing'):format(report.total),
                cursor, tabs.y + 4, UI.theme.textDim)
    end

    local gridRect, previewRect = body, nil
    if body.w > 420 then
        previewRect, gridRect = Rect.split(body, 'right', floor(min(300, body.w * 0.4)))
        gridRect = Rect.inset(gridRect, 0, 4)
        previewRect = Rect.inset(previewRect, 4, 4)
    end

    self:drawGrid(gridRect, shell)
    if previewRect then self:drawPreview(previewRect, shell) end
end

---------------------------------------------------------------------------
-- Sidebar: import, and what is on disk
---------------------------------------------------------------------------

function Panel:drawSidebar(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight + 2
    local w = rect.w - 4

    UI.text('Import', rect.x, y, UI.theme.textDim); y = y + rowH

    self.importPath = UI.textField('assets/import/path', self.importPath, rect.x, y, w,
                                   { placeholder = 'path/to/sheet.png' })
    y = y + rowH + 2

    self.importName = UI.textField('assets/import/name', self.importName, rect.x, y, w,
                                   { placeholder = 'name (from filename)' })
    y = y + rowH + 2

    local halfW = floor((w - 4) / 2)
    UI.text('angles', rect.x, y, UI.theme.textDim)
    UI.text('frames', rect.x + halfW + 4, y, UI.theme.textDim)
    y = y + 16

    self.importAngles = UI.textField('assets/import/angles', self.importAngles,
                                     rect.x, y, halfW)
    self.importFrames = UI.textField('assets/import/frames', self.importFrames,
                                     rect.x + halfW + 4, y, halfW)
    y = y + rowH + 4

    if UI.button('assets/import/go', 'Import', rect.x, y, { w = w }) then
        self:doImport()
    end
    y = y + rowH + 2

    if UI.button('assets/rescan', 'Rescan disk', rect.x, y, { w = w }) then
        self:refresh()
        self:log(('rescanned: %d importable image%s on disk, %s')
            :format(#self.found, #self.found == 1 and '' or 's', Asset.summaryLine()))
    end
    y = y + rowH + 2

    if UI.button('assets/report', 'Report missing', rect.x, y, { w = w }) then
        local lines = Asset.missingLines()
        if #lines == 0 then
            self:log('no missing assets: everything declared either loaded or is generated', 'ok')
        else
            self:log(('%d missing asset%s:'):format(#lines, #lines == 1 and '' or 's'), 'error')
            for _, line in ipairs(lines) do self:log('  ' .. line, 'error') end
        end
    end
    y = y + rowH + 8

    ---------------------------------------------------------------------
    UI.text(('On disk (%d)'):format(#self.found), rect.x, y, UI.theme.textDim)
    y = y + rowH

    if #self.found == 0 then
        UI.textClipped('no images under ' .. table.concat(self.scanRoots, ', '),
                       rect.x, y, w, UI.theme.textDim)
        y = y + rowH
        UI.textClipped('the engine needs none', rect.x, y, w, UI.theme.textDim)
        return
    end

    local listH = max(rowH, rect.y + rect.h - y)
    local labels = {}
    for i, file in ipairs(self.found) do
        labels[i] = file.name .. (file.hints and (' (%dx%d)'):format(file.hints.angles,
                                                                    file.hints.frames) or '')
    end

    local picked, changed = UI.list('assets/found', labels, self.foundIndex or 0,
                                    rect.x, y, w, listH)
    self.foundIndex = picked
    if changed and self.found[picked] then
        self:prefill(self.found[picked])
        self:log('prefilled import from ' .. self.found[picked].path)
    end
end

---------------------------------------------------------------------------
-- Inspector: everything the registry knows about the selection
---------------------------------------------------------------------------

function Panel:drawInspector(rect, shell)
    local item = self:selectedItem()
    if not item then
        UI.text('nothing selected', rect.x, rect.y, UI.theme.textDim)
        return
    end

    local y = rect.y
    y = y + UI.labelValue('name', item.name, rect.x, y, rect.w)
    y = y + UI.labelValue('kind', item.kind, rect.x, y, rect.w)

    local record = item.record

    if not record then
        y = y + UI.labelValue('source', 'defined in code', rect.x, y, rect.w)
    else
        local STATE_COLOR = {
            file = UI.theme.ok,
            generated = UI.theme.warn,
            fallback = UI.theme.danger,
            pending = UI.theme.textDim,
        }
        y = y + UI.labelValue('state', record.state, rect.x, y, rect.w,
                              { color = STATE_COLOR[record.state] })
        y = y + UI.labelValue('path', record.path or '(none)', rect.x, y, rect.w)

        if record.problem then
            y = y + 6
            UI.text('Problem', rect.x, y, UI.theme.danger); y = y + UI.metrics.rowHeight

            -- Wrapped rather than truncated: the grid-mismatch message is the one
            -- that has to be read in full, and it is the longest one there is.
            --
            -- LOVE 11's Font:getWrap returns (width, LINES-TABLE), not a line
            -- count. Multiplying that table by a height throws, and the shell
            -- runs drawInspector inside a bare pcall — so the symptom was not an
            -- error but the rest of this panel silently vanishing whenever an
            -- asset had a problem, which is exactly when you are reading it.
            -- The seam's textWrap returns the lines and nothing else, so the
            -- shape that caused this can no longer arrive here.
            local danger = UI.theme.danger
            Platform.gfx.setColor(danger[1], danger[2], danger[3], danger[4] or 1)
            Platform.gfx.printf(record.problem, rect.x, y, rect.w)

            local lines = Platform.gfx.textWrap(record.problem, rect.w)
            y = y + max(1, #lines) * UI.textHeight() + 4

            UI.setColor(UI.theme.text)
        end
    end

    if item.kind == 'sprite' and item.def then
        local def = item.def
        y = y + 6
        y = y + UI.labelValue('angles', def.angles, rect.x, y, rect.w)
        y = y + UI.labelValue('frames', def.frames, rect.x, y, rect.w)
        y = y + UI.labelValue('fps', def.fps, rect.x, y, rect.w)
        y = y + UI.labelValue('cell', ('%dx%d'):format(def.cellW, def.cellH), rect.x, y, rect.w)
        y = y + UI.labelValue('sheet', ('%dx%d'):format(def.image:getWidth(),
                                                        def.image:getHeight()), rect.x, y, rect.w)
        y = y + UI.labelValue('anchor', def.anchor, rect.x, y, rect.w)
        y = y + UI.labelValue('scale', ('%.2f'):format(def.scale), rect.x, y, rect.w)

        local plan = Slice.forSheet(def.image:getWidth(), def.image:getHeight(),
                                    def.angles, def.frames)
        y = y + UI.labelValue('grid', plan.ok and 'exact' or 'INEXACT', rect.x, y, rect.w,
                              { color = plan.ok and UI.theme.ok or UI.theme.danger })
    end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

function Panel:update(dt)
    self.time = self.time + dt

    -- Stepping the buckets on a timer means a directional sheet shows every side
    -- of itself without anyone clicking, which is how a transposed sheet gets
    -- noticed rather than looked past.
    if self.autoTurn then
        local item = self:selectedItem()
        local def = item and item.def
        if def and def.angles > 1 then
            self.bucketClock = (self.bucketClock or 0) + dt
            if self.bucketClock > 0.6 then
                self.bucketClock = 0
                self.bucket = (self.bucket + 1) % def.angles
            end
        end
    end
end

function Panel:keypressed(key, shell)
    local item = self:selectedItem()

    if key == 'left' or key == 'right' then
        local def = item and item.def
        if def then
            local step = (key == 'right') and 1 or -1
            self.bucket = (self.bucket + step) % def.angles
            self.autoTurn = false
            return true
        end
    end

    if key == 'space' and item and item.kind == 'sound' then
        self:audition(item.name)
        return true
    end

    if key == 'r' then self:refresh(); return true end

    return false
end

function Panel:wheelmoved() return false end

Panel.CATEGORIES = CATEGORIES

return Panel
