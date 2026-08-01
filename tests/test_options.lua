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
end
