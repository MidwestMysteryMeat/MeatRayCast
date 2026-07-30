--[[
    meatray.ui.core — immediate-mode widgets.

    Built before the editor that needs it, deliberately. Four things want this
    toolkit (map editor, code browser, asset browser, sprite painter) and a
    toolkit extracted after the first one is written ends up shaped by that caller
    and fits the rest badly.

    Immediate mode suits an engine like this: there is no retained widget tree to
    keep in sync with game state, a panel is a function call, and a tool that
    appears for one frame costs nothing to write. State that genuinely must
    persist between frames — which widget has keyboard focus, where a list is
    scrolled, what is being dragged — lives in one table keyed by widget id, and
    nothing else survives the frame.

    The one real LÖVE gap this wraps: `love.graphics.setScissor` has no stack. A
    panel inside a scroll region inside a dock needs the intersection of three
    clips, and every caller hand-rolling that is how clipping bugs get shipped.
    `UI.pushClip` intersects with whatever is already active and `UI.popClip`
    restores it.

    This module needs LÖVE. It lives under meatray/ui/ rather than meatray/sim/
    for that reason, and the headless rule is unaffected.
]]

local UI = {}

local floor, max, min = math.floor, math.max, math.min

-- LÖVE ships utf8 as a MODULE, not a global. `utf8.offset(...)` without this
-- require is a nil-index at the moment someone types a character into a text
-- field, and this codebase's siblings have shipped exactly that bug. Guarded
-- because plain LuaJIT has no utf8 module at all: this file needs LÖVE anyway,
-- but failing to load is better than failing on the first keystroke.
local utf8 = rawget(_G, 'utf8')
if not utf8 then
    local ok, mod = pcall(require, 'utf8')
    utf8 = ok and mod or nil
end
assert(utf8, 'meatray.ui.core needs the utf8 module (LOVE provides it)')

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------

UI.theme = {
    bg          = { 0.09, 0.10, 0.12 },
    panel       = { 0.14, 0.15, 0.18 },
    panelHeader = { 0.18, 0.20, 0.24 },
    border      = { 0.28, 0.30, 0.36 },
    text        = { 0.88, 0.90, 0.94 },
    textDim     = { 0.55, 0.58, 0.64 },
    accent      = { 0.36, 0.68, 0.92 },
    accentDim   = { 0.22, 0.42, 0.58 },
    warn        = { 0.92, 0.72, 0.28 },
    danger      = { 0.90, 0.36, 0.32 },
    ok          = { 0.42, 0.82, 0.48 },
    hover       = { 0.22, 0.24, 0.29 },
    active      = { 0.30, 0.34, 0.42 },
    rowAlt      = { 0.115, 0.125, 0.15 },
}

UI.metrics = {
    rowHeight = 20,
    padding = 6,
    headerHeight = 24,
    scrollbarWidth = 10,
    tabHeight = 22,
}

---------------------------------------------------------------------------
-- Frame state
---------------------------------------------------------------------------

local state = {
    mx = 0, my = 0,
    mouseDown = false,
    clicked = false,        -- pressed this frame
    released = false,
    wheel = 0,
    hot = nil,              -- widget under the cursor
    activeId = nil,         -- widget being interacted with (held)
    focusId = nil,          -- widget with keyboard focus
    keys = {},              -- keys pressed this frame
    textInput = '',         -- text typed this frame
    persist = {},           -- [id] = arbitrary per-widget state
    clipStack = {},
    layoutStack = {},
    consumedMouse = false,
}

UI.state = state

-- Call once per frame before drawing any widgets.
function UI.beginFrame()
    state.mx, state.my = love.mouse.getPosition()
    state.hot = nil
    state.consumedMouse = false
end

-- Call at the end of the frame. Clears the one-frame inputs; anything that must
-- outlive a frame belongs in `persist`.
function UI.endFrame()
    state.clicked = false
    state.released = false
    state.wheel = 0
    state.keys = {}
    state.textInput = ''

    if not state.mouseDown then state.activeId = nil end

    -- A clip left on the stack means a pushClip without its popClip. Rather than
    -- leaking it into the next frame — where it would clip the game itself and
    -- look like a renderer bug — reset and complain.
    if #state.clipStack > 0 then
        state.clipStack = {}
        love.graphics.setScissor()
        if not state.warnedClip then
            state.warnedClip = true
            print('[ui] a clip was pushed and never popped; check pushClip/popClip pairing')
        end
    end
end

---------------------------------------------------------------------------
-- Input plumbing. The host game forwards LÖVE callbacks here.
---------------------------------------------------------------------------

function UI.mousepressed(x, y, button)
    if button ~= 1 then return false end
    state.mouseDown = true
    state.clicked = true
    state.mx, state.my = x, y
    return state.consumedMouse
end

function UI.mousereleased(x, y, button)
    if button ~= 1 then return false end
    state.mouseDown = false
    state.released = true
    state.mx, state.my = x, y
    return state.consumedMouse
end

function UI.wheelmoved(_, dy)
    state.wheel = state.wheel + (dy or 0)
end

function UI.keypressed(key)
    state.keys[key] = true
end

function UI.textinput(text)
    state.textInput = state.textInput .. text
end

-- True when the pointer is over any widget this frame, so the game can decline to
-- treat the same click as a world interaction. This is the fix that keeps a click
-- on a panel from also clearing a selection behind it.
function UI.wantsMouse()
    return state.consumedMouse
end

function UI.wantsKeyboard()
    return state.focusId ~= nil
end

---------------------------------------------------------------------------
-- Clip stack
---------------------------------------------------------------------------

local function intersect(a, b)
    local x1 = max(a.x, b.x)
    local y1 = max(a.y, b.y)
    local x2 = min(a.x + a.w, b.x + b.w)
    local y2 = min(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = max(0, x2 - x1), h = max(0, y2 - y1) }
end

-- Clips to the intersection of this rect and whatever is already clipped.
-- love.graphics.setScissor has no stack, which is the whole reason this exists.
function UI.pushClip(x, y, w, h)
    local rect = { x = floor(x), y = floor(y), w = floor(w), h = floor(h) }

    local top = state.clipStack[#state.clipStack]
    if top then rect = intersect(top, rect) end

    state.clipStack[#state.clipStack + 1] = rect
    love.graphics.setScissor(rect.x, rect.y, rect.w, rect.h)
    return rect
end

function UI.popClip()
    table.remove(state.clipStack)
    local top = state.clipStack[#state.clipStack]
    if top then
        love.graphics.setScissor(top.x, top.y, top.w, top.h)
    else
        love.graphics.setScissor()
    end
end

-- Whether a point is inside the current clip. Hit tests must respect clipping or
-- a button scrolled out of view still responds to clicks — a bug that is
-- invisible until someone clicks nothing and something happens.
local function inClip(x, y)
    local top = state.clipStack[#state.clipStack]
    if not top then return true end
    return x >= top.x and x < top.x + top.w and y >= top.y and y < top.y + top.h
end

---------------------------------------------------------------------------
-- Hit testing
---------------------------------------------------------------------------

local function pointIn(x, y, w, h)
    return state.mx >= x and state.mx < x + w
       and state.my >= y and state.my < y + h
end

-- Registers a rect as interactive and returns hover/active/clicked for it.
function UI.hit(id, x, y, w, h)
    local over = pointIn(x, y, w, h) and inClip(state.mx, state.my)

    if over then
        state.hot = id
        state.consumedMouse = true
        if state.clicked then state.activeId = id end
    end

    local held = state.activeId == id
    local pressed = over and state.clicked
    local activated = over and held and state.released

    return over, held, pressed, activated
end

function UI.persistent(id, initial)
    local slot = state.persist[id]
    if slot == nil then
        slot = initial or {}
        state.persist[id] = slot
    end
    return slot
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local function setColor(c, alpha)
    love.graphics.setColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

UI.setColor = setColor

function UI.rect(x, y, w, h, color, mode)
    setColor(color)
    love.graphics.rectangle(mode or 'fill', floor(x), floor(y), floor(w), floor(h))
end

function UI.text(str, x, y, color)
    setColor(color or UI.theme.text)
    love.graphics.print(str, floor(x), floor(y))
end

-- Truncates to fit a pixel width, with an ellipsis.
--
-- Codepoint-safe on purpose. Slicing a string by byte index splits multi-byte
-- UTF-8 characters, and measuring the broken fragment throws "UTF-8 decoding
-- error" from inside the font — a crash that reaches the player through a label.
-- This engine's own labels carry degree signs and box-drawing characters, so this
-- is reachable, not theoretical.
function UI.truncate(str, maxWidth, font)
    font = font or love.graphics.getFont()
    if font:getWidth(str) <= maxWidth then return str end

    local ellipsis = '...'
    local budget = maxWidth - font:getWidth(ellipsis)
    if budget <= 0 then return '' end

    -- Walk forward by codepoint, never by byte.
    local out, width = '', 0
    for _, code in utf8.codes(str) do
        local ch = utf8.char(code)
        local chWidth = font:getWidth(ch)
        if width + chWidth > budget then break end
        out = out .. ch
        width = width + chWidth
    end

    return out .. ellipsis
end

function UI.textClipped(str, x, y, maxWidth, color)
    UI.text(UI.truncate(str, maxWidth), x, y, color)
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

-- A button sized to its label, or to an explicit width. Auto-sizing matters:
-- a fixed-width button whose label outgrows it clips mid-word, which is what
-- "Gift 5 thermalCores" rendering as "Gift 5 therma" looks like.
function UI.button(id, label, x, y, opts)
    opts = opts or {}
    local font = love.graphics.getFont()
    local pad = opts.padding or UI.metrics.padding
    local h = opts.h or (font:getHeight() + pad)
    local w = opts.w or (font:getWidth(label) + pad * 2)

    local over, held, _, activated = UI.hit(id, x, y, w, h)

    local fill = UI.theme.panel
    if opts.disabled then
        fill = UI.theme.bg
    elseif held and over then
        fill = UI.theme.active
    elseif over then
        fill = UI.theme.hover
    end

    UI.rect(x, y, w, h, fill)
    UI.rect(x, y, w, h, opts.disabled and UI.theme.border or UI.theme.accentDim, 'line')

    local textColor = opts.disabled and UI.theme.textDim or UI.theme.text
    local label2 = UI.truncate(label, w - pad * 2)
    UI.text(label2, x + (w - font:getWidth(label2)) / 2, y + (h - font:getHeight()) / 2, textColor)

    return (not opts.disabled) and activated or false, w, h
end

function UI.label(text, x, y, opts)
    opts = opts or {}
    UI.text(text, x, y, opts.color)
    return love.graphics.getFont():getWidth(text)
end

-- Label on the left, value on the right of a fixed column. A shared column is
-- what stops a label running into its value, which is how "Trades:" ends up
-- overlapping "fuel, metal, steel".
function UI.labelValue(label, value, x, y, width, opts)
    opts = opts or {}
    local font = love.graphics.getFont()
    local valueX = x + (opts.column or floor(width * 0.42))
    local gap = opts.gap or 8

    UI.textClipped(label, x, y, valueX - x - gap, opts.labelColor or UI.theme.textDim)
    UI.textClipped(tostring(value), valueX, y, width - (valueX - x), opts.color)

    return font:getHeight()
end

function UI.checkbox(id, label, checked, x, y)
    local font = love.graphics.getFont()
    local box = font:getHeight()
    local w = box + 6 + font:getWidth(label)
    local _, _, _, activated = UI.hit(id, x, y, w, box)

    UI.rect(x, y, box, box, UI.theme.panel)
    UI.rect(x, y, box, box, UI.theme.border, 'line')
    if checked then
        UI.rect(x + 3, y + 3, box - 6, box - 6, UI.theme.accent)
    end
    UI.text(label, x + box + 6, y)

    return activated and (not checked) or (activated and false) or checked, activated
end

function UI.slider(id, value, minV, maxV, x, y, w, opts)
    opts = opts or {}
    local h = opts.h or 14
    local over, held = UI.hit(id, x, y, w, h)

    local v = value
    if held and state.mouseDown then
        local t = (state.mx - x) / max(1, w)
        t = max(0, min(1, t))
        v = minV + t * (maxV - minV)
        if opts.step then v = floor(v / opts.step + 0.5) * opts.step end
        v = max(minV, min(maxV, v))
    end

    local t = (v - minV) / max(1e-9, maxV - minV)
    UI.rect(x, y + h / 2 - 2, w, 4, UI.theme.panel)
    UI.rect(x, y + h / 2 - 2, w * t, 4, UI.theme.accentDim)

    local knobX = x + w * t
    UI.rect(knobX - 4, y, 8, h, (over or held) and UI.theme.accent or UI.theme.border)

    return v, held
end

-- A scroll region. Returns the content offset; the caller draws inside it and
-- calls endScroll. Clipping is handled here so nested regions compose.
function UI.beginScroll(id, x, y, w, h, contentHeight)
    local slot = UI.persistent(id, { offset = 0 })

    local maxOffset = max(0, contentHeight - h)

    -- Only scroll when the pointer is actually over this region, or nested
    -- regions all scroll together and the wheel feels broken.
    if pointIn(x, y, w, h) and inClip(state.mx, state.my) and state.wheel ~= 0 then
        slot.offset = slot.offset - state.wheel * UI.metrics.rowHeight * 3
        state.wheel = 0
        state.consumedMouse = true
    end

    slot.offset = max(0, min(maxOffset, slot.offset))

    UI.pushClip(x, y, w, h)
    love.graphics.push()
    love.graphics.translate(0, -floor(slot.offset))

    return slot.offset, maxOffset
end

function UI.endScroll(id, x, y, w, h, contentHeight)
    love.graphics.pop()
    UI.popClip()

    local slot = UI.persistent(id, { offset = 0 })
    local maxOffset = max(0, contentHeight - h)
    if maxOffset <= 0 then return end

    -- Scrollbar, drawn outside the clip so it is never scrolled away with the
    -- content it describes.
    local sw = UI.metrics.scrollbarWidth
    local sx = x + w - sw
    UI.rect(sx, y, sw, h, UI.theme.bg)

    local thumbH = max(20, h * (h / contentHeight))
    local t = slot.offset / maxOffset
    local thumbY = y + t * (h - thumbH)

    local over, held = UI.hit(id .. '/scrollbar', sx, y, sw, h)
    if held and state.mouseDown then
        local rel = (state.my - y - thumbH / 2) / max(1, h - thumbH)
        slot.offset = max(0, min(maxOffset, rel * maxOffset))
    end

    UI.rect(sx + 2, thumbY, sw - 4, thumbH, (over or held) and UI.theme.accent or UI.theme.border)
end

-- Single-line text field. Returns the (possibly edited) text and whether it was
-- committed with Enter.
function UI.textField(id, text, x, y, w, opts)
    opts = opts or {}
    local font = love.graphics.getFont()
    local h = opts.h or (font:getHeight() + UI.metrics.padding)

    local over, _, pressed = UI.hit(id, x, y, w, h)
    if pressed then state.focusId = id end
    if state.clicked and not over and state.focusId == id then state.focusId = nil end

    local focused = state.focusId == id
    local value = text or ''
    local committed = false

    if focused then
        if state.textInput ~= '' then value = value .. state.textInput end

        if state.keys.backspace and #value > 0 then
            -- Drop a whole codepoint, not a byte: lopping one byte off a
            -- multi-byte character leaves an invalid string that throws the next
            -- time the font measures it.
            local offset = utf8.offset(value, -1)
            value = offset and value:sub(1, offset - 1) or ''
        end

        if state.keys['return'] or state.keys.kpenter then
            committed = true
            state.focusId = nil
        end

        if state.keys.escape then state.focusId = nil end
    end

    UI.rect(x, y, w, h, UI.theme.bg)
    UI.rect(x, y, w, h, focused and UI.theme.accent or UI.theme.border, 'line')

    local pad = 4
    local shown = value
    if opts.placeholder and value == '' and not focused then
        UI.textClipped(opts.placeholder, x + pad, y + pad / 2, w - pad * 2, UI.theme.textDim)
    else
        -- Show the tail while typing, so the caret stays visible in a long value.
        while font:getWidth(shown) > w - pad * 2 - 6 and #shown > 0 do
            local offset = utf8.offset(shown, 2)
            shown = offset and shown:sub(offset) or ''
        end
        UI.text(shown, x + pad, y + pad / 2)
        if focused and (love.timer.getTime() % 1) < 0.5 then
            local cx = x + pad + font:getWidth(shown)
            UI.rect(cx, y + 3, 1, h - 6, UI.theme.text)
        end
    end

    return value, committed
end

---------------------------------------------------------------------------
-- Containers
---------------------------------------------------------------------------

-- A titled panel. Returns the content rect, already clipped; call endPanel after.
function UI.beginPanel(id, x, y, w, h, title)
    UI.rect(x, y, w, h, UI.theme.panel)
    UI.rect(x, y, w, h, UI.theme.border, 'line')

    local headerH = 0
    if title then
        headerH = UI.metrics.headerHeight
        UI.rect(x, y, w, headerH, UI.theme.panelHeader)
        UI.textClipped(title, x + UI.metrics.padding,
                       y + (headerH - love.graphics.getFont():getHeight()) / 2,
                       w - UI.metrics.padding * 2)
    end

    -- A panel swallows clicks on its background. Without this a click on empty
    -- panel space falls through to the world underneath and does something the
    -- player did not ask for.
    if pointIn(x, y, w, h) then state.consumedMouse = true end

    local cx, cy = x + 1, y + headerH
    local cw, ch = w - 2, h - headerH - 1
    UI.pushClip(cx, cy, cw, ch)

    return cx + UI.metrics.padding, cy + UI.metrics.padding,
           cw - UI.metrics.padding * 2, ch - UI.metrics.padding * 2
end

function UI.endPanel()
    UI.popClip()
end

-- A row of tabs. Returns the selected index.
function UI.tabs(id, labels, selected, x, y, w)
    local font = love.graphics.getFont()
    local h = UI.metrics.tabHeight
    local cursor = x

    for i, label in ipairs(labels) do
        local tw = font:getWidth(label) + UI.metrics.padding * 2
        if cursor + tw > x + w then break end

        local tabId = id .. '/tab/' .. i
        local over, _, _, activated = UI.hit(tabId, cursor, y, tw, h)
        local isSelected = (i == selected)

        UI.rect(cursor, y, tw, h,
                isSelected and UI.theme.panel or (over and UI.theme.hover or UI.theme.bg))
        if isSelected then
            UI.rect(cursor, y + h - 2, tw, 2, UI.theme.accent)
        end
        UI.text(label, cursor + UI.metrics.padding, y + (h - font:getHeight()) / 2,
                isSelected and UI.theme.text or UI.theme.textDim)

        if activated then selected = i end
        cursor = cursor + tw + 1
    end

    return selected
end

-- A selectable list. Returns the selected index and whether it changed.
function UI.list(id, items, selected, x, y, w, h, opts)
    opts = opts or {}
    local rowH = opts.rowHeight or UI.metrics.rowHeight
    local contentH = #items * rowH
    local changed = false

    UI.beginScroll(id, x, y, w, h, contentH)

    for i, item in ipairs(items) do
        local ry = y + (i - 1) * rowH
        local label = opts.format and opts.format(item, i) or tostring(item)

        local rowId = id .. '/row/' .. i
        local over, _, _, activated = UI.hit(rowId, x, ry, w, rowH)

        if i == selected then
            UI.rect(x, ry, w, rowH, UI.theme.accentDim)
        elseif over then
            UI.rect(x, ry, w, rowH, UI.theme.hover)
        elseif i % 2 == 0 then
            UI.rect(x, ry, w, rowH, UI.theme.rowAlt)
        end

        UI.textClipped(label, x + 4, ry + (rowH - love.graphics.getFont():getHeight()) / 2,
                       w - 8 - UI.metrics.scrollbarWidth)

        if activated and selected ~= i then
            selected = i
            changed = true
        end
    end

    UI.endScroll(id, x, y, w, h, contentH)

    return selected, changed
end

return UI
