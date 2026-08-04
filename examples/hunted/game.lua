-- Hunted — the example project's gameplay code (H5).
--
-- This file is why the map can say `entity s stalker`: the engine has no
-- 'stalker' archetype; THIS project defines one. Without game.lua the map
-- still loads and logs "unknown archetype"; with it, the warren is
-- populated. That is the whole demonstration — a project brings its own
-- entity kinds, the engine brings everything else.
--
-- The stalker is the imp's shape with different numbers: less health, more
-- speed, a longer nose. Its sprite is procedural like all placeholder art,
-- so this project ships zero media and still runs.

return function(api)
    local C = api.engine.components
    local AI = api.engine.ai

    api.archetype('stalker', function(e)
        e:add(C.Billboard{ sheet = 'stalker' })
        e:add(C.Health{ hp = 20, max = 20 })
        e:add(C.Brain{ state = 'patrol' })
        e.radius = 0.26
        api.game.attach(e, { authority = api.isAuthority() })
        -- Host only, same gate the engine's own creatures use: clients are
        -- told where things are; they never think for them.
        if api.isAuthority() then
            AI.attach(e, { state = 'patrol', alertRange = 12, speed = 3.0 })
        end
    end)

    api.note('hunted: stalker archetype defined')
end
