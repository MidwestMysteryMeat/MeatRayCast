--[[
    `love . --editor [map]`

    The editor entry point, and the only thing that reaches into meatray/ui/. A
    shipped game never requires this file, which is what "strippable from a release
    build" means in practice: not a flag that disables the editor, but a file whose
    absence costs nothing.

    It installs its own LÖVE callbacks and owns the frame from here, so the demo's
    game loop and the editor never both think they are driving.
]]

local Shell = require('meatray.ui.shell')
local MapPanel = require('meatray.ui.panel_map')
local AssetPanel = require('meatray.ui.panel_assets')
local CodePanel = require('meatray.ui.panel_code')
local SpritePanel = require('meatray.ui.panel_sprite')
local ServerPanel = require('meatray.ui.panel_servers')
local InventoryPanel = require('meatray.ui.panel_inventory')
local MeatGraphPanel = require('meatray.ui.panel_meatgraph')
local Map = require('meatray.sim.map')
local UI = require('meatray.ui.core')

return function(args)
    if not (love and love.graphics) then
        print('the editor needs a window; it cannot run headless')
        love.event.quit(2)
        return
    end

    love.graphics.setDefaultFilter('nearest', 'nearest')
    love.keyboard.setKeyRepeat(true)

    -- The editor wants a visible cursor. The game captures it for mouselook, and
    -- an editor you cannot point at is not an editor.
    if love.mouse then
        love.mouse.setRelativeMode(false)
        love.mouse.setVisible(true)
    end

    local shell = Shell.new{}

    local mapPanel = MapPanel.new{}
    shell:add(mapPanel)
    shell:add(AssetPanel.new{})
    shell:add(CodePanel.new{ definitions = args.definitions })
    shell:add(SpritePanel.new{})
    shell:add(ServerPanel.new{})
    -- No subject given, so the panel builds its own bench bag: the tool works
    -- with no world loaded, and cannot disturb one that is. A game hands it a
    -- live entity with `Panel.new{ subject = e, emit = ... }` instead.
    shell:add(InventoryPanel.new{})
    shell:add(MeatGraphPanel.new{})
    mapPanel:attach(shell)

    -- `--editor-tab code` opens straight to a panel. Mostly for verification:
    -- every panel needs to be screenshot-able, and a shot that can only ever
    -- capture whichever tab happens to be first proves nothing about the others.
    if args.editorTab then
        if not shell:focus(args.editorTab) then
            shell:warn(('no panel named "%s"'):format(tostring(args.editorTab)))
        end
    end

    shell:log('MeatRayCast editor')
    shell:log('F1 project  F2 inspector  F3 console  TAB next panel')
    shell:log('1-9 brushes  [ ] prev/next brush  P preview  wheel zoom')
    shell:log('Floor raise/lower, ceiling raise/lower, short/full wall, clear elev.')
    shell:log('Plan: warm = raised floor, cool stripe = low ceiling, gold = short wall')
    shell:log('MeatGraph tab: list meatgraphs/*.graph.json (MeatEngine MeatGraph kinship)')
    shell:status('Map: paint · click-drag · right-click = floor · Ctrl+S save')

    -- A named map on the command line loads it; otherwise start on a blank one so
    -- there is always something to paint on.
    local path = type(args.editor) == 'string' and args.editor or nil
    if path then
        if not path:find('%.map$') then path = 'maps/' .. path .. '.map' end
        if not mapPanel:loadFile(path) then
            shell:warn('starting from a blank map instead')
        end
    else
        shell:log('no map given; started blank. Save writes to the LOVE save directory.')
        shell:log('Tip: love . --editor maps/platforms  loads the elevation demo.')
    end

    ---------------------------------------------------------------------
    -- Take over the callbacks. Everything the game installed is replaced
    -- wholesale rather than conditionally shared, so there is no mode flag to
    -- get wrong and no chance of both loops running.
    ---------------------------------------------------------------------

    -- `--editor-shot name` draws a few frames, writes a screenshot and exits.
    -- Worth having beyond one-off checking: it is the only way to assert that the
    -- editor actually renders, and "it booted without erroring" is not the same
    -- claim as "it drew something".
    local shot = args.editorShot
    local framesDrawn = 0

    function love.update(dt)
        shell:update(dt)
    end

    function love.draw()
        shell:draw()

        if shot then
            framesDrawn = framesDrawn + 1
            -- A few frames in, so layout has settled and the console has content.
            if framesDrawn == 8 then
                love.graphics.captureScreenshot(function(imageData)
                    imageData:encode('png', shot .. '.png')
                    print(('editor screenshot: %s%s.png')
                        :format(love.filesystem.getSaveDirectory() .. '/', shot))
                    love.event.quit(0)
                end)
            end
        end

        -- A one-line status so the window always says what it is, even before a
        -- panel has drawn anything.
        local w, h = love.graphics.getDimensions()
        UI.setColor(UI.theme.textDim)
        love.graphics.print(('MeatRayCast editor  %s%s'):format(
            mapPanel.path or '(unsaved)', mapPanel.dirty and ' *' or ''), 8, h - 16)
    end

    function love.keypressed(key)
        if key == 'escape' and not UI.wantsKeyboard() then
            love.event.quit()
            return
        end
        shell:keypressed(key)
    end

    function love.textinput(text) shell:textinput(text) end
    function love.mousepressed(x, y, b) shell:mousepressed(x, y, b) end
    function love.mousereleased(x, y, b) shell:mousereleased(x, y, b) end
    function love.wheelmoved(dx, dy) shell:wheelmoved(dx, dy) end
    function love.mousemoved(x, y, dx, dy) shell:mousemoved(x, y, dx, dy) end

    function love.resize() end

    return shell
end
