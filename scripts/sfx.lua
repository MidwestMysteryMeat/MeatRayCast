--[[
    Render a sound effect to a WAV file from the command line.

        luajit scripts/sfx.lua <preset> <out.wav> [seed]

    <preset> is one of Sfx.presetNames() (pickup, laser, explosion, hurt, jump,
    powerup, blip, step). With a seed, the file is a deterministic variation on
    the preset — the same seed writes the same bytes on every machine.

    Exit 1 with a reason on a bad preset or an unwritable path, so a build
    script can gate on it.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Sfx = require('meatray.asset.sfx')

local presetName, outPath, seed = arg[1], arg[2], tonumber(arg[3])

if not presetName or not outPath then
    io.stderr:write('usage: luajit scripts/sfx.lua <preset> <out.wav> [seed]\n')
    io.stderr:write('presets: ' .. table.concat(Sfx.presetNames(), ', ') .. '\n')
    os.exit(1)
end

local params, err
if seed then
    params, err = Sfx.randomize(presetName, seed)
else
    params, err = Sfx.preset(presetName)
end
if not params then
    io.stderr:write(err .. '\n')
    os.exit(1)
end

local bytes, wavErr = Sfx.wav(params)
if not bytes then
    io.stderr:write(tostring(wavErr) .. '\n')
    os.exit(1)
end

local f, ioErr = io.open(outPath, 'wb')
if not f then
    io.stderr:write(('cannot write %s: %s\n'):format(outPath, tostring(ioErr)))
    os.exit(1)
end
f:write(bytes)
f:close()

print(('%s -> %s (%d bytes, %.2fs)'):format(
    presetName .. (seed and ('#' .. seed) or ''), outPath, #bytes, Sfx.duration(params)))
