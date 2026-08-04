--[[
    Seal one file's bytes for `-Encrypt` packaging. Build-time only.

        luajit scripts/sealfile.lua <keyhex> <in> <out>

    Reads <in> (a compiled bytecode chunk), seals it with the build key and
    the cryptoload AAD, writes <out>. The runtime loader
    (meatray.pack.cryptoload) opens exactly this.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'
local Crypto = require('meatray.net.crypto')
local Cryptoload = require('meatray.pack.cryptoload')

local keyhex, inp, outp = arg[1], arg[2], arg[3]
if not (keyhex and inp and outp) then
    io.stderr:write('usage: luajit scripts/sealfile.lua <keyhex> <in> <out>\n')
    os.exit(1)
end

local key, kerr = Crypto.fromHex(keyhex)
if not key or #key ~= Crypto.KEY_BYTES then
    io.stderr:write('bad key: ' .. tostring(kerr or 'wrong length') .. '\n')
    os.exit(1)
end

local f = assert(io.open(inp, 'rb'))
local data = f:read('*a')
f:close()

local sealed, serr = Crypto.seal(key, data, Cryptoload.AAD)
if not sealed then
    io.stderr:write('seal failed: ' .. tostring(serr) .. '\n')
    os.exit(1)
end

local o = assert(io.open(outp, 'wb'))
o:write(sealed)
o:close()
