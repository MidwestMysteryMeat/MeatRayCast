--[[
    meatray.net.discovery — how players find a server, pluggably and in parallel.

    A host announces through zero or more backends; a client browses through zero
    or more. Passing a list runs all of them and merges the results, which is the
    property that matters:

        MeatRay.net.host{ discovery = { 'lan', 'master' } }

    If 'master' is unavailable — not implemented, down, or blocked — the host
    still comes up and 'lan' still works. An outage in a registry must never be
    the reason a game cannot be played, so an unavailable backend is recorded in
    `.missing` and warned about, and is never an error. That is also exactly how
    'master' and 'steam' plug in later: register a backend under the name, and
    every call site above already passes the name through.

    A backend is a table:

        { beacon  = function(opts) -> beacon,  or nil if it cannot announce
          browser = function(opts) -> browser, or nil if it cannot search }

    A beacon implements  :update(dt), :close(), and reads opts.info() for the
    current server description. A browser implements :update(dt), :refresh(),
    :servers(), :close().

    A server list entry is:

        { address, name, map, players, max, locked, mode, ping, source, lastSeen }

    `address` is the only required field, because it is the only one join needs;
    everything else is for a browser UI to display. `source` names the backend
    that found it, so a UI can say where a server came from and a merge can prefer
    one.

    HEADLESS: no LOVE here. The lan backend needs LuaSocket and loads lazily.
]]

local Discovery = {}

local backends = {}

Discovery.builtin = {
    lan    = 'meatray.net.discovery.lan',
    master = 'meatray.net.discovery.master',
}

Discovery.planned = {
    steam  = 'Steam lobby discovery arrives with the Steam transport, '
          .. 'which is planned, not implemented',
}

function Discovery.register(name, impl)
    assert(type(name) == 'string' and name ~= '', 'a discovery backend needs a name')
    assert(type(impl) == 'table', 'a discovery backend is a table of functions')
    backends[name] = impl
    return impl
end

function Discovery.names()
    local out = {}
    local seen = {}
    for name in pairs(backends) do out[#out + 1] = name; seen[name] = true end
    for name in pairs(Discovery.builtin) do
        if not seen[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function Discovery.resolve(name)
    if backends[name] then return backends[name] end

    local path = Discovery.builtin[name]
    if path then
        local ok, mod = pcall(require, path)
        if not ok then
            return nil, ('discovery backend %q failed to load: %s'):format(name, tostring(mod))
        end
        backends[name] = mod
        return mod
    end

    if Discovery.planned[name] then return nil, Discovery.planned[name] end

    return nil, ('unknown discovery backend %q (have: %s)')
        :format(tostring(name), table.concat(Discovery.names(), ', '))
end

---------------------------------------------------------------------------
-- 'direct' — paste an address. Always available and cannot break.
---------------------------------------------------------------------------

-- It has no beacon, because there is nothing to announce, and its browser is a
-- list the player typed. Registering it as a backend rather than special-casing
-- it means a browser UI has one code path, and a favourites list is a discovery
-- source like any other.
local Direct = {}

function Direct.browser(opts)
    local self = { source = 'direct', entries = {} }

    function self:add(address, info)
        if type(address) == 'table' then address = address.address end
        if type(address) ~= 'string' or address == '' then return nil end
        local entry = { address = address, source = 'direct' }
        for k, v in pairs(info or {}) do entry[k] = v end
        self.entries[address] = entry
        return entry
    end

    function self:remove(address) self.entries[address] = nil end
    function self:update() end
    function self:refresh() end
    function self:close() self.entries = {} end

    function self:servers()
        local out = {}
        for _, entry in pairs(self.entries) do out[#out + 1] = entry end
        table.sort(out, function(a, b) return a.address < b.address end)
        return out
    end

    for _, address in ipairs((opts and opts.addresses) or {}) do self:add(address) end

    return self
end

Discovery.register('direct', Direct)

---------------------------------------------------------------------------
-- Fan-out
---------------------------------------------------------------------------

local function asList(names)
    if names == nil then return {} end
    if type(names) == 'string' then return { names } end
    if type(names) == 'table' then return names end
    return {}
end

-- Builds a beacon that announces through every named backend that can. Missing
-- backends land in `.missing` and are warned about once, never raised.
function Discovery.beacon(names, opts)
    opts = opts or {}

    local self = { members = {}, missing = {}, sources = {} }

    for _, name in ipairs(asList(names)) do
        local impl, err = Discovery.resolve(name)
        if not impl or not impl.beacon then
            local reason = err or ('discovery backend %q cannot announce'):format(name)
            self.missing[#self.missing + 1] = { name = name, reason = reason }
            if opts.onWarning then opts.onWarning(reason) end
        else
            local member, memberErr = impl.beacon(opts)
            if member then
                self.members[#self.members + 1] = member
                self.sources[#self.sources + 1] = name
            else
                local reason = memberErr or ('%s beacon could not start'):format(name)
                self.missing[#self.missing + 1] = { name = name, reason = reason }
                if opts.onWarning then opts.onWarning(reason) end
            end
        end
    end

    function self:active() return #self.members > 0 end

    function self:update(dt)
        for _, member in ipairs(self.members) do member:update(dt) end
    end

    function self:close()
        for _, member in ipairs(self.members) do member:close() end
        self.members = {}
    end

    return self
end

-- Builds a browser over every named backend that can search, merging results by
-- address. Later sources do not clobber earlier ones' fields, so a 'direct'
-- favourite keeps the name the player gave it even once 'lan' finds the same box.
function Discovery.browser(names, opts)
    opts = opts or {}

    local self = { members = {}, missing = {}, sources = {} }

    for _, name in ipairs(asList(names)) do
        local impl, err = Discovery.resolve(name)
        if not impl or not impl.browser then
            local reason = err or ('discovery backend %q cannot search'):format(name)
            self.missing[#self.missing + 1] = { name = name, reason = reason }
            if opts.onWarning then opts.onWarning(reason) end
        else
            local member, memberErr = impl.browser(opts)
            if member then
                self.members[#self.members + 1] = member
                self.sources[#self.sources + 1] = name
                self[name] = member          -- so browser.direct:add(...) works
            else
                local reason = memberErr or ('%s browser could not start'):format(name)
                self.missing[#self.missing + 1] = { name = name, reason = reason }
                if opts.onWarning then opts.onWarning(reason) end
            end
        end
    end

    function self:active() return #self.members > 0 end

    function self:update(dt)
        for _, member in ipairs(self.members) do member:update(dt) end
    end

    function self:refresh()
        for _, member in ipairs(self.members) do member:refresh() end
    end

    function self:close()
        for _, member in ipairs(self.members) do member:close() end
        self.members = {}
    end

    function self:servers()
        local merged, order = {}, {}
        for _, member in ipairs(self.members) do
            for _, entry in ipairs(member:servers()) do
                local existing = merged[entry.address]
                if not existing then
                    merged[entry.address] = entry
                    order[#order + 1] = entry.address
                else
                    for k, v in pairs(entry) do
                        if existing[k] == nil then existing[k] = v end
                    end
                end
            end
        end

        local out = {}
        for _, address in ipairs(order) do out[#out + 1] = merged[address] end
        table.sort(out, function(a, b)
            if (a.name or '') ~= (b.name or '') then return (a.name or '') < (b.name or '') end
            return a.address < b.address
        end)
        return out
    end

    return self
end

return Discovery
