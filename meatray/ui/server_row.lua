--[[
    meatray.ui.server_row — one server, as a line of text.

    Split out of panel_servers for two reasons.

    The editor's browser is a diagnostic, not the browser a game ships: a game
    builds its own, styled its own way. But deciding what a row must SAY -- that
    a server is full, locked, or listed with a port nobody proved was open -- is
    the same judgement whichever UI draws it, and it is worth having in a file a
    game can require without pulling in the editor's whole immediate-mode
    toolkit.

    The other reason is that this is where the browser's real failure mode
    lives, and it is not a crash. This code once read `entry.maxPlayers` while
    both discovery backends and the discovery contract emit `max`, so every
    server rendered as holding 0 players and FULL was dead code compared against
    nil. Nothing threw. The editor booted clean. The browser was simply wrong,
    and a smoke test cannot see that. meatray/ui/core.lua needs LOVE's utf8 and
    so cannot load headless, which is why the logic had to leave the panel to be
    testable at all.

    HEADLESS: requires nothing.
]]

local ServerRow = {}

function ServerRow.describe(entry)
    -- `max`, not `maxPlayers`. The discovery contract names this field `max` and
    -- both backends emit it; reading maxPlayers meant every row rendered as
    -- "2/0" and the FULL flag was dead code, because the value it compared
    -- against was always nil. maxPlayers is still accepted so a backend that
    -- sends the registry's own spelling is not punished for it.
    local max = entry.max or entry.maxPlayers or 0
    local players = ('%d/%d'):format(entry.players or 0, max)

    local flags = {}
    if entry.locked then flags[#flags + 1] = 'locked' end
    if entry.dedicated then flags[#flags + 1] = 'dedicated' end
    if entry.players and max > 0 and entry.players >= max then
        flags[#flags + 1] = 'FULL'
    end

    -- A registry lists a server whose game port was never actually proven open,
    -- because the challenge has to go to a port the beacon owns rather than to
    -- ENet's. Saying so is the difference between "this might not connect" and a
    -- player concluding the game is broken.
    if entry.portVerified == false then flags[#flags + 1] = 'unverified' end

    return ('%-22s %-12s %-8s %-7s %5sms %s'):format(
        tostring(entry.address or '?'):sub(1, 22),
        tostring(entry.name or 'server'):sub(1, 12),
        tostring(entry.map or '-'):sub(1, 8),
        players,
        tostring(entry.ping or '?'),
        table.concat(flags, ' '))
end

return ServerRow
