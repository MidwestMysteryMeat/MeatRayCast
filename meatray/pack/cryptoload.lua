--[[
    meatray.pack.cryptoload — the runtime half of `-Encrypt` packaging.

    A packaged, encrypted build ships each module as a `.luac` file: its
    compiled bytecode SEALED with meatray.net.crypto (encrypt-then-MAC over
    SHA-256). This installs a `require` loader that finds those files,
    decrypts them in memory as they load, and hands Lua the bytecode — so a
    module is never plaintext on disk and never plaintext in the archive.

    conf.lua runs before main.lua and installs this with the build key, so
    the searcher is live before the first engine module is required. The
    honest caveat, spelled out in docs/SHIPPING_SECURITY.md: the key ships
    inside conf.lua (as bytecode) because the machine must be able to
    decrypt to run. This raises the cost of copying, it does not make the
    code secret — nothing client-side can. It is a second deadbolt on top
    of bytecode, deliberately not sold as a vault.

    The bootstrap set — conf.lua, main.lua, meatray.net.crypto and this
    module — ships as ordinary bytecode, not encrypted, because something
    has to be able to decrypt everything else.

    HEADLESS-irrelevant: only a packaged build ever loads this; it needs
    love.filesystem, and it is never on the test path.
]]

local Crypto = require('meatray.net.crypto')

local M = {}

M.AAD = 'mrpack1'          -- construction tag, bound into every module's MAC

-- Installs the searcher at the front of the require chain. `key` is the
-- 32-byte build key (conf.lua holds it as hex and fromHex's it in).
function M.install(key)
    local searchers = package.loaders or package.searchers
    table.insert(searchers, 1, function(name)
        local base = name:gsub('%.', '/')
        -- Both a plain module and a package (its init), same order require does.
        for _, cand in ipairs({ base .. '.luac', base .. '/init.luac' }) do
            if love.filesystem.getInfo(cand) then
                local sealed = love.filesystem.read(cand)
                local plain, why = Crypto.open(key, sealed, M.AAD)
                if not plain then
                    -- A real failure — tampered file or wrong key — is loud,
                    -- because a silent nil here would fall through to "module
                    -- not found", which points at the wrong problem.
                    return ('\n\tsealed module %q failed to open: %s')
                        :format(cand, tostring(why))
                end
                local chunk, err = load(plain, '@' .. cand)
                if not chunk then return '\n\t' .. tostring(err) end
                return chunk
            end
        end
        return nil          -- not one of ours; let the next searcher try
    end)
end

return M
