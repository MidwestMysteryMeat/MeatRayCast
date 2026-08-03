--[[
    Options: keybinds, mouse prefs, volume buses, serialize / storage.
]]

return function(t)
    local Options = require('meatray.game.options')
    local Game    = require('meatray.game')
    local Storage = require('meatray.save.storage')

    t.eq(Game.options, Options, 'Game.options is the options module')

    ---------------------------------------------------------------------
    t.describe('defaults and movement')

    local opts = Options.new()
    t.eq(opts.mouse.invertY, false, 'default invert off')
    t.ok(opts.mouse.sensitivity > 0, 'default sens')
    t.eq(opts.volume.master, 1, 'master full')
    t.ok(#opts:keysOf('forward') >= 1, 'forward bound')
    t.eq(opts:actionForKey('w'), 'forward', 'w is forward')
    t.eq(opts:actionForKey('space'), 'jump', 'space jump')

    local keys = { w = true, d = true }
    t.eq(opts:isActive('forward', keys), true, 'forward active')
    t.eq(opts:isActive('back', keys), false, 'back inactive')
    local mx, my = opts:moveVector(keys)
    t.eq(mx, 1, 'strafe right')
    t.eq(my, 1, 'move forward')

    ---------------------------------------------------------------------
    t.describe('rebind and conflict steal')

    t.eq(opts:rebind('use', 'f'), true, 'rebind use to f')
    t.eq(opts:keysOf('use')[1], 'f', 'use is f')
    t.eq(opts:actionForKey('e'), nil, 'e freed')

    -- Steal: r is reload by default; steal for use.
    t.eq(opts:rebind('use', 'r'), true, 'steal r')
    t.eq(opts:actionForKey('r'), 'use', 'r now use')
    t.eq(#opts:keysOf('reload'), 0, 'reload cleared')

    -- f is free after use moved to r; bind jump to w without steal (w = forward).
    local ok, err = opts:rebind('jump', 'w', { steal = false })
    t.eq(ok, false, 'no steal refused')
    t.ok(err and err:find('in use'), 'conflict message')

    opts:addBind('jump', 'g')
    local jk = opts:keysOf('jump')
    t.ok(#jk >= 2, 'multi bind jump')

    opts:resetBinds()
    t.eq(opts:actionForKey('w'), 'forward', 'reset restores defaults')

    ---------------------------------------------------------------------
    t.describe('mouse look deltas')

    opts:setMouse{ sensitivity = 0.01, invertY = false }
    local yaw, pitch = opts:lookDelta(10, -5) -- mouse right + up
    t.near(yaw, 0.1, 1e-9, 'yaw from dx')
    t.near(pitch, 0.05, 1e-9, 'pitch look up from -dy')

    opts:setMouse{ invertY = true }
    local _, pitch2 = opts:lookDelta(0, -5)
    t.near(pitch2, -0.05, 1e-9, 'invert Y flips pitch')

    ---------------------------------------------------------------------
    t.describe('volumes and applyAudio')

    t.eq(opts:setVolume('music', 0.5), 0.5, 'set music')
    t.eq(opts:getVolume('music'), 0.5, 'get music')
    t.eq(opts:setVolume('sfx', 0.8), 0.8, 'set sfx')
    t.eq(opts:setVolume('master', 0.5), 0.5, 'set master')
    t.near(opts:effectiveVolume('sfx'), 0.4, 1e-9, 'effective sfx')
    t.near(opts:effectiveVolume('music'), 0.25, 1e-9, 'effective music')

    local bad = opts:setVolume('voice', 1)
    t.eq(bad, nil, 'unknown bus refused')

    local applied = opts:applyAudio()
    t.near(applied.sfx, 0.4, 1e-9, 'applyAudio sfx')
    t.near(applied.music, 0.25, 1e-9, 'applyAudio music')

    local Sound = require('meatray.asset.sound')
    local Music = require('meatray.asset.music')
    t.near(Sound.getMasterVolume(), 0.4, 1e-9, 'sound master bus')
    t.near(Music.getVolume(), 0.25, 1e-9, 'music bus')

    ---------------------------------------------------------------------
    t.describe('serialize round-trip')

    local o2 = Options.new()
    o2:setMouse{ sensitivity = 0.005, invertY = true }
    o2:setVolume('master', 0.9)
    o2:setVolume('sfx', 0.6)
    o2:setVolume('music', 0.3)
    o2:rebind('forward', 'i')
    o2:addBind('forward', 'up')
    o2:ensureAction('custom_emote', 'Emote', { 'h' })

    local text = o2:serialize()
    t.ok(text:find('mouse.invertY=true', 1, true), 'serialize invert')
    t.ok(text:find('bind.forward=i', 1, true), 'serialize bind')
    t.ok(text:find('bind.custom_emote=h', 1, true), 'custom action')

    local o3 = Options.new()
    t.eq(o3:deserialize(text), true, 'deserialize ok')
    t.eq(o3.mouse.invertY, true, 'restored invert')
    t.near(o3.mouse.sensitivity, 0.005, 1e-9, 'restored sens')
    t.near(o3.volume.music, 0.3, 1e-9, 'restored music vol')
    t.eq(o3:keysOf('forward')[1], 'i', 'restored forward')
    t.eq(o3:keysOf('forward')[2], 'up', 'multi-bind restored')
    t.eq(o3:actionForKey('h'), 'custom_emote', 'custom restored')

    ---------------------------------------------------------------------
    t.describe('storage save/load')

    local mem = Storage.memory()
    local o4 = Options.new()
    o4:setMouse{ invertY = true }
    o4:rebind('pause', 'f1')
    t.eq(o4:save(mem, 'cfg/options.cfg'), true, 'save ok')
    local raw = mem.read('cfg/options.cfg')
    t.ok(raw and raw:find('bind.pause=f1', 1, true), 'bytes on storage')

    local o5 = Options.new()
    t.eq(o5:load(mem, 'cfg/options.cfg'), true, 'load ok')
    t.eq(o5.mouse.invertY, true, 'loaded invert')
    t.eq(o5:keysOf('pause')[1], 'f1', 'loaded pause bind')

    local missing, merr = Options.new():load(mem, 'nope.cfg')
    t.eq(missing, nil, 'missing file fails')
    t.ok(merr, 'missing reason')

    ---------------------------------------------------------------------
    t.describe('export/import and menu model')

    local snap = o5:export()
    local o6 = Options.new()
    t.eq(o6:import(snap), true, 'import')
    t.eq(o6.mouse.invertY, true, 'import invert')

    local rows = o6:menuRows()
    t.ok(#rows > 10, 'menu has rows')
    local kinds = {}
    for i = 1, #rows do kinds[rows[i].kind] = true end
    t.ok(kinds.slider and kinds.toggle and kinds.bind, 'row kinds present')

    o6:menuSet('volume.master', 0.2)
    t.near(o6.volume.master, 0.2, 1e-9, 'menuSet volume')
    o6:menuNudge('mouse.invertY')
    t.eq(o6.mouse.invertY, false, 'nudge toggles invert')
    o6:menuSet('bind.fire', 'mouse3')
    t.eq(o6:keysOf('fire')[1], 'mouse3', 'menu rebind')

    ---------------------------------------------------------------------
    t.describe('unknown extra keys preserved')

    local o7 = Options.new()
    o7:deserialize([[
version=1
mouse.sensitivity=0.0028
mouse.invertY=false
volume.master=1
volume.sfx=1
volume.music=1
extra.mod_foo=bar
future.thing=1
]])
    t.eq(o7.extra.mod_foo, 'bar', 'extra preserved')
    t.eq(o7.extra['future.thing'], '1', 'unknown keys stored in extra')
    local s7 = o7:serialize()
    t.ok(s7:find('extra.mod_foo=bar', 1, true), 'extra re-emitted')

    ---------------------------------------------------------------------
    t.describe('graphics: defaults and clamping (A7)')

    local g = Options.new()
    local gfx = g:getGraphics()
    t.eq(gfx.scale, 1, 'full scale by default')
    t.eq(gfx.fov, Options.DEFAULT_FOV, 'classic FOV by default')
    t.eq(gfx.quality, 'high', 'defaults are the high preset')
    t.eq(gfx.floorCast, true, 'textured floors on')

    -- The renderer's number, not the player's. 66 degrees is the engine's
    -- historical 0.66 plane, which is where that constant came from.
    t.near(g:fovPlane(), math.tan(math.rad(66) / 2), 1e-9, 'fov converts to a plane')
    t.ok(math.abs(g:fovPlane() - 0.66) < 0.02, 'and lands near the old constant')

    -- Values arrive from settings screens, hand-edited files and old saves.
    -- All three get clamped, never rejected.
    g:setGraphics{ fov = 500 }
    t.eq(g:getGraphics().fov, Options.FOV_MAX, 'absurd FOV clamps high')
    g:setGraphics{ fov = -10 }
    t.eq(g:getGraphics().fov, Options.FOV_MIN, 'and low')
    g:setGraphics{ scale = 9 }
    t.eq(g:getGraphics().scale, Options.SCALE_MAX, 'scale cannot exceed native')
    g:setGraphics{ scale = 0 }
    t.eq(g:getGraphics().scale, Options.SCALE_MIN, 'nor collapse')
    g:setGraphics{ pitchLimit = 99 }
    t.eq(g:getGraphics().pitchLimit, Options.PITCH_MAX, 'pitch limit capped')
    t.eq(g:setGraphics('nope'), nil, 'setGraphics wants a table')

    local w, h = g:renderSize(800, 600)
    t.eq(w, 200, 'render size follows scale')
    t.eq(h, 150, 'in both axes')
    w, h = g:renderSize(0, 0)
    t.ok(w >= 1 and h >= 1, 'a render buffer is never zero-sized')

    ---------------------------------------------------------------------
    t.describe('graphics: presets and the custom fallback')

    local q = Options.new()
    t.ok(q:setQuality('low'), 'low preset applies')
    local low = q:getGraphics()
    t.eq(low.quality, 'low', 'named low')
    t.eq(low.floorCast, false, 'low turns textured floors off')
    t.eq(low.lightTexture, false, 'and per-pixel light')
    t.eq(low.scale, 0.5, 'and halves the buffer')

    t.eq(q:setQuality('ultra'), nil, 'an unknown preset refuses')
    t.eq(q:getGraphics().quality, 'low', 'and changes nothing')

    -- Touching one field moves the label to custom rather than lying.
    q:setGraphics{ lightTexture = true }
    t.eq(q:getGraphics().quality, 'custom', 'a hand-edited field is custom')
    q:setGraphics{ lightTexture = false }
    t.eq(q:getGraphics().quality, 'low', 'and going back restores the name')

    -- An explicit field in the same call beats the preset it came with.
    q:setGraphics{ quality = 'high', scale = 0.5 }
    t.eq(q:getGraphics().scale, 0.5, 'the explicit field wins')
    t.eq(q:getGraphics().floorCast, true, 'the rest of the preset still applied')

    ---------------------------------------------------------------------
    t.describe('graphics: persistence')

    local p = Options.new()
    p:setGraphics{ fov = 95, scale = 0.75, pitchLimit = 0.4, lightTexture = false }
    local text = p:serialize()
    t.ok(text:find('graphics.fov=95', 1, true), 'fov written')
    t.ok(text:find('graphics.scale=0.75', 1, true), 'scale written')

    local p2 = Options.new()
    t.eq(p2:deserialize(text), true, 'reads back')
    local back = p2:getGraphics()
    t.near(back.fov, 95, 1e-9, 'fov survives')
    t.near(back.scale, 0.75, 1e-9, 'scale survives')
    t.near(back.pitchLimit, 0.4, 1e-9, 'pitch limit survives')
    t.eq(back.lightTexture, false, 'toggle survives')

    -- A file whose fields disagree with its quality label: the fields win and
    -- the label is re-derived, so nothing reports itself as a preset it isn't.
    local lying = Options.new()
    lying:deserialize([[
version=1
graphics.scale=0.5
graphics.floorCast=false
graphics.lightTexture=false
graphics.quality=high
]])
    t.eq(lying:getGraphics().quality, 'low', 'the fields decide, not the label')

    -- A file with only a preset name still configures the fields.
    local terse = Options.new()
    terse:deserialize('version=1\ngraphics.quality=low\n')
    t.eq(terse:getGraphics().scale, 0.5, 'a lone quality line applies its preset')

    local exported = p:export()
    t.eq(type(exported.graphics), 'table', 'export carries graphics')
    local imported = Options.new()
    imported:import(exported)
    t.near(imported:getGraphics().fov, 95, 1e-9, 'import carries it back')

    ---------------------------------------------------------------------
    t.describe('graphics: menu rows and apply')

    local m = Options.new()
    local mrows = m:menuRows()
    local byId = {}
    for i = 1, #mrows do byId[mrows[i].id] = mrows[i] end
    t.ok(byId['graphics.fov'], 'FOV has a row')
    t.eq(byId['graphics.fov'].kind, 'slider', 'as a slider')
    t.eq(byId['graphics.quality'].kind, 'choice', 'quality is a choice row')
    t.eq(byId['graphics.floorCast'].kind, 'toggle', 'floors are a toggle')

    m:menuSet('graphics.fov', 100)
    t.near(m:getGraphics().fov, 100, 1e-9, 'menuSet writes FOV')
    m:menuNudge('graphics.fov', -1)
    t.near(m:getGraphics().fov, 99, 1e-9, 'nudge steps by one degree')
    m:menuNudge('graphics.floorCast')
    t.eq(m:getGraphics().floorCast, false, 'nudge flips a toggle')

    m:setQuality('low')
    m:menuNudge('graphics.quality', 1)
    t.eq(m:getGraphics().quality, 'medium', 'quality cycles up')
    m:menuNudge('graphics.quality', -1)
    t.eq(m:getGraphics().quality, 'low', 'and back down')
    m:setQuality('high')
    m:menuNudge('graphics.quality', 1)
    t.eq(m:getGraphics().quality, 'low', 'and wraps rather than sticking')

    t.eq(select(1, m:menuSet('graphics.nonsense', 1)), false, 'unknown field refuses')

    -- applyGraphics reaches the renderer when one is loadable and reports what
    -- it pushed either way, so a dedicated server can call it unconditionally.
    local applied = m:applyGraphics()
    t.near(applied.fovPlane, m:fovPlane(), 1e-12, 'applied plane matches')
    t.eq(applied.scale, m:getGraphics().scale, 'scale is reported, not applied')
    t.eq(type(applied.renderer), 'boolean', 'says whether a renderer took it')

    local okRay, Raycaster = pcall(require, 'meatray.render.raycaster')
    if okRay and Raycaster.fovPlane then
        t.near(Raycaster.fovPlane(), m:fovPlane(), 1e-12,
               'the renderer really took the FOV')
        t.near(Raycaster.MAX_PITCH, m:getGraphics().pitchLimit, 1e-12,
               'and the pitch limit')
        t.eq(Raycaster.clampPitch(99), m:getGraphics().pitchLimit,
             'which clampPitch then enforces')

        -- Nothing may raise the limit past the renderer's own ceiling.
        Raycaster.setMaxPitch(50)
        t.eq(Raycaster.MAX_PITCH, Raycaster.MAX_PITCH_CEILING, 'ceiling holds')
        Raycaster.setFovPlane(0)
        t.ok(Raycaster.fovPlane() > 0, 'a zero-width camera is refused')

        -- Leave the renderer as the suite found it.
        Options.new():applyGraphics()
    end
end
