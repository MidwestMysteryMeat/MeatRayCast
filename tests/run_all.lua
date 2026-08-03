--[[
    Headless test runner. Runs under plain LuaJIT with no LÖVE present, which is
    the point: the simulation half of the engine is testable without a window,
    a GPU, or a graphics stub that would let untested draw paths masquerade as
    covered code.

    Run from the repository root:
        luajit tests/run_all.lua
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local SUITES = {
    'test_headless',
    'test_platform',
    'test_entity',
    'test_collide',
    'test_segments',
    'test_pathfind',
    'test_triggers',
    'test_ai',
    'test_decals',
    'test_destruction',
    'test_wallheight',
    'test_floorheight',
    'test_movers',
    'test_minimap',
    'test_masked_anim',
    'test_tick',
    'test_worldgen',
    'test_map',
    'test_storeys',
    'test_sprites',
    'test_net_serialize',
    'test_net_snapcodec',
    'test_net_transport',
    'test_net_replication',
    'test_net_dirty',
    'test_masterserver',
    'test_net_json',
    'test_net_master',
    'test_net_lagcomp',
    'test_server_row',
    'test_net_punch',
    'test_relay',
    'test_net_relay',
    'test_net_crypto',
    'test_discovery_steam',
    'test_masterserver_http',
    'test_net_access',
    'test_net_contract',
    'test_net_hardening',
    'test_net_rcon',
    'test_net_fuzz',
    'test_compat',
    'test_microbench',
    'test_ui_rect',
    'test_engine_layering',
    'test_reload',
    'test_asset_slice',
    'test_asset_names',
    'test_asset_registry',
    'test_music',
    'test_asset_spatial',
    'test_paint_sheet',
    'test_paint_history',
    'test_save_format',
    'test_save_state',
    'test_save_slots',
    'test_lighting',
    'test_render_floorcast',
    'test_render_segments',
    'test_particles',
    'test_render_lightgrid',
    'test_game_tags',
    'test_game_attributes',
    'test_game_effects',
    'test_game_abilities',
    'test_weapons',
    'test_inventory',
    'test_explosion',
    'test_projectiles',
    'test_gas',
    'test_mode',
    'test_modes',
    'test_options',
    'test_hud',
    'test_respawn',
    'test_secrets',
    'test_session',
    'test_demo',
    'test_automap',
    'test_console',
    'test_intermission',
    'test_hazards',
    'test_menu',
    'test_i18n',
    'test_messages',
    'test_screenfx',
    'test_vote',
    'test_spectator',
    'test_bot',
    'test_map_entities',
    'test_maplint',
    'test_prefab',
    'test_campaign',
    'test_meatgraph_ray',
    -- Last on purpose: it calls Game.reset() and defines its own items, and the
    -- suites are not isolated from each other's registries.
    'test_inventory_view',
}

---------------------------------------------------------------------------
-- Tiny assertion harness
---------------------------------------------------------------------------

local passed, failed, errors = 0, 0, 0
local failures = {}
local currentSuite, currentGroup = '', ''

local t = {}

function t.describe(name)
    currentGroup = name
end

function t.ok(cond, label, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = ('%s / %s: %s%s'):format(
            currentSuite, currentGroup, label or '(unnamed)',
            detail and ('  [' .. tostring(detail) .. ']') or '')
    end
end

function t.eq(got, want, label)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = ('%s / %s: %s  (got %s, wanted %s)'):format(
            currentSuite, currentGroup, label or '(unnamed)',
            tostring(got), tostring(want))
    end
end

function t.near(got, want, tol, label)
    t.ok(math.abs(got - want) <= (tol or 1e-9), label,
         ('got %s, wanted %s'):format(tostring(got), tostring(want)))
end

---------------------------------------------------------------------------

print('MeatRayCast test suite (headless, no LOVE)')
print(('-'):rep(58))

for _, suite in ipairs(SUITES) do
    currentSuite = suite
    currentGroup = ''

    local before = failed
    local loaded, chunk = pcall(require, 'tests.' .. suite)

    if not loaded then
        errors = errors + 1
        print(('  [ERR ] %-20s could not load: %s'):format(suite, tostring(chunk)))
    else
        local ok, err = pcall(chunk, t)
        if not ok then
            errors = errors + 1
            print(('  [ERR ] %-20s raised: %s'):format(suite, tostring(err)))
        elseif failed > before then
            print(('  [FAIL] %-20s %d failing'):format(suite, failed - before))
        else
            print(('  [PASS] %-20s'):format(suite))
        end
    end
end

print(('-'):rep(58))

if #failures > 0 then
    print('Failures:')
    for _, line in ipairs(failures) do print('  - ' .. line) end
    print(('-'):rep(58))
end

print(('TOTAL: %d passed, %d failed, %d errors'):format(passed, failed, errors))

if failed == 0 and errors == 0 then
    print('All tests passed.')
    os.exit(0)
else
    os.exit(1)
end
