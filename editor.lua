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
local AudioPanel = require('meatray.ui.panel_audio')
local Project = require('meatray.game.project')
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

    -- H1: `--project <dir>` points every tool at a game folder on the real
    -- disk: the map panel loads and saves there, the trigger picker scans its
    -- graphs, the asset browser walks its tree, the audio panel writes its
    -- sounds. Without the flag everything keeps the old shape (repo dirs,
    -- saves into the LÖVE save directory).
    local project, projectFs
    if args.project then
        projectFs = Project.diskFs()
        local err
        project, err = Project.open(projectFs, args.project)
        if not project then
            print('project: ' .. tostring(err))
            projectFs = nil
        end
    end
    local roots = project and project:roots()

    -- H2: the build step, in the workspace. package.ps1 stages engine +
    -- project, fuses the exe and smoke-boots it; blocking is honest here — an
    -- export IS a build, and the log says so before it starts.
    local function exportProject()
        shell:log('exporting ' .. project.dir .. ' — building, this takes a minute...')
        local cmd = ('powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Project "%s"')
            :format(project.dir)
        if package.config:sub(1, 1) ~= '\\' then
            shell:warn('export scripting is Windows-only for now (scripts/package.ps1)')
            return
        end
        local code = os.execute(cmd)
        if code == 0 or code == true then
            shell:ok('export OK — build/dist has the game')
        else
            shell:error('export failed — run scripts/package.ps1 by hand to see why')
        end
    end

    local mapPanel = MapPanel.new{
        fs = projectFs,
        graphDirs = roots and { roots.graphs, 'meatgraphs', 'graphs' } or nil,
        onExport = project and exportProject or nil,
    }
    shell:add(mapPanel)
    shell:add(AssetPanel.new{
        scanRoots = roots and { roots.assets, roots.maps, 'assets', 'maps' } or nil,
    })
    shell:add(CodePanel.new{ definitions = args.definitions })
    shell:add(SpritePanel.new{})
    shell:add(AudioPanel.new{
        fs = projectFs,
        soundsDir = roots and (roots.assets .. '/sounds') or nil,
    })
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
    shell:status('Map: paint · click-drag · right-click = floor · Ctrl+Z undo · Save in sidebar')

    -- A named map on the command line loads it; in a project, no name means
    -- the project's start map; otherwise start on a blank one so there is
    -- always something to paint on.
    local path = type(args.editor) == 'string' and args.editor or nil
    if path then
        if not path:find('%.map$') then
            -- A bare name resolves through the project, then maps/; a path
            -- that already carries a separator just gains the extension —
            -- `--editor maps/arena` must not become maps/maps/arena.map.
            if path:find('[/\\]') then
                path = path .. '.map'
            else
                path = project and (project:mapPath(path) or path)
                       or ('maps/' .. path .. '.map')
            end
        end
        if not mapPanel:loadFile(path) then
            shell:warn('starting from a blank map instead')
        end
    elseif project then
        local startId = project:startMapId()
        if startId and mapPanel:loadFile(project:mapPath(startId)) then
            shell:log(('project %s — editing %s. Save writes back to the project.')
                :format(project.manifest.name, startId))
        else
            shell:log('project has no maps yet; started blank. Save with a path under '
                .. roots.maps .. '/')
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
