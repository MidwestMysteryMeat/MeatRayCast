--[[
    app.menu — the shell's screens and what its rows DO (G1).

    Third cut of un-god-filing main.lua. The menu MODEL (meatray.game.menu)
    proposes — navigation, capture, value cycling; this module disposes:
    which screens exist, what each row id means, and which demo function a
    choice lands on. main.lua keeps the key routing and the drawing.

    Construction takes a ctx of demo functions. Two of them — startHost and
    startClient — are assigned AFTER this module is built (they live in the
    networking section), so the ctx wraps them in thin closures over
    main.lua's forward-declared locals rather than passing values that
    would be permanently nil. Everything else exists at build time.

    Returns { open, close, apply } — bound in main.lua to the same local
    names the key handlers always called.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local note, setMouseLook = ctx.note, ctx.setMouseLook
    local loadProcedural, reloadMap = ctx.loadProcedural, ctx.reloadMap
    local mountProject, applyTemplate = ctx.mountProject, ctx.applyTemplate
    local startCampaign = ctx.startCampaign
    local startHost, startClient = ctx.startHost, ctx.startClient

    local M = {}

    function M.open()
        if game.shell:isOpen() then return end
        -- A project boot titles the menu with the game's name: a packaged game's
        -- first screen belongs to that game, not to the engine underneath it.
        game.shell:push{
            id = 'title',
            title = game.project and game.project.manifest.name:upper() or 'MEATRAYCAST',
            rows = {
                { id = 'continue', label = 'Continue', kind = 'action' },
                { id = 'campaign', label = 'New Campaign', kind = 'action' },
                { id = 'roam', label = 'Free Roam (new seed)', kind = 'action' },
                { id = 'templates', label = 'Genre Templates', kind = 'action' },
                { id = 'projects', label = 'Projects', kind = 'action' },
                { id = 'join', label = 'Join Game', kind = 'action' },
                { id = 'host', label = 'Host Game', kind = 'action' },
                { id = 'options', label = 'Options', kind = 'action' },
                { id = 'quit', label = 'Quit', kind = 'action' },
            },
        }
        game.session:openMenu('menu')
        if MeatRay.canRender() then setMouseLook(false) end
    end

    function M.close()
        game.shell:close()
        game.session:closeMenu()
        -- Anything the options screen changed is applied live; the file is
        -- written once here, and only if something is actually dirty.
        game.options:applyGraphics()
        game.options:applyAudio()
        game.sensitivity = game.options:getMouse().sensitivity or game.sensitivity
        if game.options.dirty then game.options:save(game.storage) end
    end

    -- One row activated (or one captured value landed). The menu proposed; this
    -- disposes.
    function M.apply(result)
        if not result then return end
        local screen = result.screen

        if result.kind == 'set' or result.kind == 'submit' then
            if screen == 'options' then
                -- F8: accessibility rows (a11y.*) route to the a11y model; the
                -- rest to options. One Options screen, two backing models.
                if tostring(result.row.id):sub(1, 5) == 'a11y.' then
                    game.a11y:menuSet(result.row.id, result.value)
                    game.a11y:save(game.storage)
                else
                    game.options:menuSet(result.row.id, result.value)
                    game.options:applyGraphics()
                    game.options:applyAudio()
                end
                -- Refresh the rows so the screen shows what was actually accepted
                -- (clamps, custom-quality rederivation, bind lists, a11y clamps).
                local fresh = game.options:menuRows()
                for _, ar in ipairs(game.a11y:menuRows()) do fresh[#fresh + 1] = ar end
                local rows = game.shell:current().rows
                for i = 1, #rows do
                    if fresh[i] and rows[i].id == fresh[i].id then
                        rows[i].value = fresh[i].value
                    end
                end
            elseif screen == 'join' and result.kind == 'submit' then
                local addr = result.value
                if addr ~= '' then
                    M.close()
                    startClient(addr, { name = 'player' })
                end
            elseif screen == 'projects' and result.kind == 'submit' then
                -- H1: create the project, mount it, and put the player in its
                -- starter map. The folder lands under projects/ beside the engine.
                local name = result.value
                if name ~= '' then
                    local slug = Game.project.slug(name)
                    if not slug then
                        note('project: a name needs at least one letter or digit')
                        return
                    end
                    local dir = 'projects/' .. slug
                    local proj, err = Game.project.create(Game.project.diskFs(), dir, name)
                    if not proj then
                        note('project: ' .. tostring(err))
                        return
                    end
                    if mountProject(dir) then
                        M.close()
                        game.session:restart('solo')
                        reloadMap(game.project:startMapId())
                        note(('created %s — edit it with: love . --editor --project %s')
                            :format(dir, dir))
                    end
                end
            end
            return
        end

        if result.kind ~= 'action' then return end
        local id = result.row.id

        if id == 'continue' then
            M.close()
        elseif id == 'campaign' then
            M.close()
            startCampaign()
        elseif id == 'roam' then
            M.close()
            game.seed = game.seed + 1
            game.session:restart('solo')
            loadProcedural()
        elseif id == 'templates' then
            -- A screen of every genre; picking one starts a fresh world and
            -- applies the template to it.
            local rows = {}
            for _, name in ipairs(Game.template.list()) do
                local cfg = Game.template.resolve(name)
                rows[#rows + 1] = {
                    id = 'template.' .. name,
                    label = ('%s  (%s)'):format(cfg.name or name,
                        cfg.ready == 'playable' and 'playable' or 'scaffold'),
                    kind = 'action',
                }
            end
            game.shell:push{ id = 'templates', title = 'GENRE TEMPLATES', rows = rows }
        elseif id:sub(1, 9) == 'template.' then
            M.close()
            game.seed = game.seed + 1
            game.session:restart('solo')
            loadProcedural()
            applyTemplate(id:sub(10))
        elseif id == 'projects' then
            -- H1: one screen for both halves of "my game": type a name to create,
            -- or pick an existing folder under projects/ to play it.
            local rows = {
                { id = 'newname', label = 'Create — type a name', kind = 'text', value = '' },
            }
            local fs = Game.project.diskFs()
            if fs.getInfo('projects') then
                local names = fs.getDirectoryItems('projects') or {}
                table.sort(names)
                for _, name in ipairs(names) do
                    if fs.getInfo('projects/' .. name .. '/' .. Game.project.MANIFEST) then
                        rows[#rows + 1] = {
                            id = 'project.' .. name,
                            label = 'Play  ' .. name,
                            kind = 'action',
                        }
                    end
                end
            end
            game.shell:push{ id = 'projects', title = 'PROJECTS', rows = rows }
        elseif id:sub(1, 8) == 'project.' then
            local dir = 'projects/' .. id:sub(9)
            if game.project and ('projects/' .. game.project.manifest.id) ~= dir then
                -- The registry holds the first project's ids; a second mount can
                -- collide. Honest answer for now: one project per run.
                note('a project is already mounted — restart with --project ' .. dir)
            elseif game.project or mountProject(dir) then
                M.close()
                game.session:restart('solo')
                reloadMap(game.project:startMapId())
            end
        elseif id == 'join' then
            game.shell:push{
                id = 'join', title = 'JOIN GAME',
                rows = {
                    { id = 'addr', label = 'Address', kind = 'text',
                      value = '127.0.0.1:6789' },
                },
            }
        elseif id == 'host' then
            M.close()
            startHost{ mode = 'listen', name = 'MeatRayCast', port = 6789 }
            note('hosting on UDP 6789')
        elseif id == 'options' then
            -- F8: the options screen carries graphics/audio/binds AND the
            -- accessibility rows, so they persist and apply the same way.
            local rows = game.options:menuRows()
            for _, ar in ipairs(game.a11y:menuRows()) do rows[#rows + 1] = ar end
            game.shell:push{ id = 'options', title = 'OPTIONS', rows = rows }
        elseif id == 'quit' then
            game.session:quit('left the game')
            if game.host then game.host:close() end
            if game.client then game.client:leave() end
            love.event.quit()
        end
    end

    return M
end
