--[[
    meatray.ui.panel_servers — the server browser.

    LAN discovery has worked for a while; `love . --browse` prints a list to the
    console. This is the same data with somewhere to click, which is the last piece
    of "players should be able to set up a server anywhere and have people join".

    It deliberately shows the things that decide whether you can actually join —
    ping, whether the server is full, whether it is locked, and what version it
    speaks — rather than just a name. A browser that lists a server you cannot join
    and does not say why is the same failure as an empty list with no explanation.
]]

local UI = require('meatray.ui.core')
local Rect = require('meatray.ui.rect')

local Panel = {}
Panel.__index = Panel

local floor, max = math.floor, math.max

function Panel.new(opts)
    opts = opts or {}

    return setmetatable({
        id = 'servers',
        title = 'Servers',
        browser = nil,
        servers = {},
        selected = 1,
        searching = false,
        elapsed = 0,
        directAddress = opts.address or '',
        -- Empty by default, and deliberately so: this project runs no public
        -- registry, so shipping a URL that answers nothing would make the
        -- browser look broken out of the box. Point it at your own (see
        -- docs/MASTERSERVER.md, or `love masterserver` to run one).
        registry = opts.registry or '',
        password = '',
        playerName = opts.name or 'player',
        status = 'not searching',
        lastError = nil,
        onJoin = opts.onJoin,      -- a game supplies this; the editor just lists
    }, Panel)
end

function Panel:attach(shell)
    self.shell = shell
end

---------------------------------------------------------------------------
-- Discovery
---------------------------------------------------------------------------

function Panel:startSearch()
    local Net = require('meatray.net')

    self:stopSearch()

    -- LAN always; a registry as well once one is configured. Asking for
    -- 'master' with no URL would list it as unavailable on every search and
    -- train the reader to ignore the warning line, which is the line that
    -- matters when something is genuinely wrong.
    local sources = { 'lan' }
    local registries = nil
    if self.registry and self.registry ~= '' then
        sources[#sources + 1] = 'master'
        registries = { self.registry }
    end

    local ok, browser = pcall(Net.browse, {
        discovery = sources,
        registries = registries,
        onWarning = function(text)
            self.lastError = tostring(text)
            if self.shell then self.shell:warn('discovery: ' .. tostring(text)) end
        end,
    })

    if not ok or not browser then
        -- The reason matters more than the failure. A blocked UDP port and a
        -- missing library look identical from an empty list, and `--netcheck`
        -- exists precisely to tell them apart.
        self.lastError = tostring(browser)
        self.status = 'could not start discovery'
        if self.shell then
            self.shell:error('discovery failed: ' .. tostring(browser))
            self.shell:error('run `love . --netcheck` to find out whether UDP works here')
        end
        return false
    end

    -- A backend that could not start is reported rather than silently absent.
    -- `Net.browse` keeps the working ones going and lists the rest in `missing`,
    -- so "no servers" and "the only backend that could find them failed to load"
    -- stay distinguishable.
    if browser.missing and #browser.missing > 0 then
        local names = {}
        for _, m in ipairs(browser.missing) do
            names[#names + 1] = tostring(m.name or m)
        end
        self.lastError = 'unavailable: ' .. table.concat(names, ', ')
        if self.shell then
            self.shell:warn('discovery backends unavailable: ' .. table.concat(names, ', '))
        end
    end

    self.browser = browser
    self.searching = true
    self.elapsed = 0
    self.status = 'searching...'
    if self.shell then
        self.shell:log(#sources > 1
            and ('searching the LAN and ' .. self.registry)
            or 'searching the LAN')
    end
    return true
end

function Panel:stopSearch()
    if self.browser and self.browser.close then pcall(self.browser.close, self.browser) end
    self.browser = nil
    self.searching = false
end

function Panel:update(dt)
    if not self.browser then return end

    self.elapsed = self.elapsed + dt
    pcall(self.browser.update, self.browser, dt)

    local ok, list = pcall(self.browser.servers, self.browser)
    if ok and list then
        self.servers = list
        if #list > 0 then
            self.status = ('%d server%s'):format(#list, #list == 1 and '' or 's')
        elseif self.elapsed > 4 then
            -- Say what an empty list means rather than leaving it ambiguous. This
            -- is the message that stops someone concluding their code is broken
            -- when nothing is hosting.
            -- Names what was actually searched. "Nothing on this network" is
            -- the wrong question to send someone away with when they also
            -- searched a registry that may simply have no servers on it.
            self.status = (self.registry ~= '')
                and 'nothing found - no host on this LAN, and the registry lists none'
                or 'nothing found - is a host running on this network?'
        end
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local describe = require('meatray.ui.server_row').describe

function Panel:draw(rect, shell)
    local rowH = UI.metrics.rowHeight
    local y = rect.y

    -- Header row, so the columns below mean something.
    UI.text(('%-22s %-12s %-8s %-7s %7s %s'):format(
                'ADDRESS', 'NAME', 'MAP', 'PLAYERS', 'PING', 'FLAGS'),
            rect.x, y, UI.theme.textDim)
    y = y + rowH + 2

    local listH = max(rowH * 3, rect.h - (y - rect.y) - rowH * 3)

    if #self.servers == 0 then
        UI.textClipped(self.status, rect.x, y, rect.w, UI.theme.textDim)
        if self.lastError then
            UI.textClipped(self.lastError, rect.x, y + rowH, rect.w, UI.theme.danger)
        end
    else
        self.selected = UI.list('servers/list', self.servers, self.selected,
                                rect.x, y, rect.w, listH,
                                { format = function(entry) return describe(entry) end })
    end

    y = y + listH + 4

    local entry = self.servers[self.selected]
    local canJoin = entry ~= nil
        and not (entry.players and entry.maxPlayers and entry.players >= entry.maxPlayers)

    if UI.button('servers/join', 'Join selected', rect.x, y,
                 { disabled = not canJoin }) then
        self:join(entry)
    end

    if entry and not canJoin then
        UI.text('that server is full', rect.x + 120, y + 3, UI.theme.warn)
    end
end

function Panel:drawSidebar(rect, shell)
    local rowH = UI.metrics.rowHeight + 2
    local y = rect.y

    UI.text('Discovery', rect.x, y, UI.theme.textDim); y = y + rowH

    if UI.button('servers/search', self.searching and 'Searching...' or 'Search LAN',
                 rect.x, y, { w = rect.w - 4 }) then
        if self.searching then self:stopSearch() else self:startSearch() end
    end
    y = y + rowH

    if UI.button('servers/netcheck', 'Can I host at all?', rect.x, y, { w = rect.w - 4 }) then
        -- Points at the diagnostic rather than pretending to run it inside the
        -- editor: netcheck binds a port and shakes hands with itself, which is not
        -- something to do underneath a running game.
        if shell then
            shell:log('run:  love . --netcheck')
            shell:log('it checks LuaSocket, enet, loopback UDP, bind, and a real handshake')
        end
    end
    y = y + rowH + 6

    UI.text('Registry (blank = LAN only)', rect.x, y, UI.theme.textDim); y = y + rowH
    local before = self.registry
    self.registry = UI.textField('servers/registry', self.registry,
                                 rect.x, y, rect.w - 4,
                                 { placeholder = 'http://host:8080' })
    -- Restart the search when it changes, or a URL typed while searching does
    -- nothing until the next manual refresh and reads as being ignored.
    if self.registry ~= before and self.searching then
        self:stopSearch(); self:startSearch()
    end
    y = y + rowH + 6

    UI.text('Direct connect', rect.x, y, UI.theme.textDim); y = y + rowH
    self.directAddress = UI.textField('servers/address', self.directAddress,
                                      rect.x, y, rect.w - 4,
                                      { placeholder = 'host:port' })
    y = y + rowH

    UI.text('Password (optional)', rect.x, y, UI.theme.textDim); y = y + rowH
    self.password = UI.textField('servers/password', self.password,
                                 rect.x, y, rect.w - 4, { placeholder = 'blank if open' })
    y = y + rowH

    UI.text('Name', rect.x, y, UI.theme.textDim); y = y + rowH
    self.playerName = UI.textField('servers/name', self.playerName,
                                   rect.x, y, rect.w - 4)
    y = y + rowH + 4

    if UI.button('servers/direct', 'Connect', rect.x, y,
                 { w = rect.w - 4, disabled = self.directAddress == '' }) then
        self:join{ address = self.directAddress }
    end
end

function Panel:drawInspector(rect, shell)
    local entry = self.servers[self.selected]
    local y = rect.y

    if not entry then
        UI.text('no server selected', rect.x, y, UI.theme.textDim)
        UI.textClipped('Direct connect always works even when discovery finds nothing.',
                       rect.x, y + UI.metrics.rowHeight * 2, rect.w, UI.theme.textDim)
        return
    end

    y = y + UI.labelValue('name', entry.name or 'server', rect.x, y, rect.w)
    y = y + UI.labelValue('address', entry.address or '?', rect.x, y, rect.w)
    y = y + UI.labelValue('map', entry.map or '-', rect.x, y, rect.w)
    y = y + UI.labelValue('players', ('%d/%d'):format(entry.players or 0,
                                                      entry.maxPlayers or 0),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('ping', (entry.ping and (entry.ping .. 'ms') or 'unknown'),
                          rect.x, y, rect.w)
    y = y + UI.labelValue('mode', entry.dedicated and 'dedicated' or 'listen',
                          rect.x, y, rect.w)
    y = y + UI.labelValue('locked', entry.locked and 'yes - needs a password' or 'no',
                          rect.x, y, rect.w,
                          { color = entry.locked and UI.theme.warn or UI.theme.ok })

    if entry.version then
        y = y + UI.labelValue('protocol', entry.version, rect.x, y, rect.w)
    end
end

---------------------------------------------------------------------------
-- Joining
---------------------------------------------------------------------------

function Panel:join(entry)
    if not entry then return false end

    if self.onJoin then
        -- A game supplies this and takes over. The browser's job ends at
        -- "which server", and it must not assume it is allowed to swap the world
        -- out from under whatever is running.
        local ok, err = self.onJoin(entry, {
            password = self.password ~= '' and self.password or nil,
            name = self.playerName,
        })
        if not ok and self.shell then
            self.shell:error('join failed: ' .. tostring(err))
        end
        return ok
    end

    if self.shell then
        self.shell:log(('would join %s'):format(tostring(entry.address)))
        self.shell:log('the editor lists servers; a game supplies onJoin to actually connect')
    end
    return false
end

function Panel:keypressed(key)
    if key == 'f5' then self:startSearch(); return true end
    return false
end

return Panel
