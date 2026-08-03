--[[
    A8: pause policy by role, menus that are not pauses, and the end of a
    session — including the cascade a disconnect actually arrives as.
]]

return function(t)
    local Session = require('meatray.game.session')
    local Game    = require('meatray.game')

    t.eq(Game.session, Session, 'Game.session is the session module')

    ---------------------------------------------------------------------
    t.describe('solo: pausing stops the simulation clock')

    local s = Session.new()
    t.eq(s.role, 'solo', 'solo by default')
    t.eq(s:isPaused(), false, 'running to begin with')
    t.eq(s:simDelta(0.016), 0.016, 'and time passes')

    t.eq(s:pause('menu'), true, 'solo may pause')
    t.eq(s:isPaused(), true, 'and is paused')
    t.eq(s:simDelta(0.016), 0, 'the simulation gets no time')
    t.eq(s:reason(), 'menu', 'and remembers why')

    t.eq(s:pause('again'), true, 'pausing twice is harmless')
    t.eq(s:reason(), 'menu', 'and does not overwrite the first reason')

    t.eq(s:resume(), true, 'resume takes')
    t.eq(s:simDelta(0.016), 0.016, 'and time runs again')
    t.eq(s:resume(), true, 'resuming a running session is harmless')

    s:togglePause('menu')
    t.eq(s:isPaused(), true, 'toggle pauses')
    s:togglePause()
    t.eq(s:isPaused(), false, 'and unpauses')

    -- Garbage dt cannot make time run backwards or produce a NaN step.
    t.eq(s:simDelta(-5), 0, 'negative dt is refused')
    t.eq(s:simDelta(0 / 0), 0, 'NaN dt is refused')
    t.eq(s:simDelta(nil), 0, 'missing dt is zero, not an error')

    ---------------------------------------------------------------------
    t.describe('client: the world is not yours to stop')

    local c = Session.new{ role = 'client' }
    local may, why = c:mayPause()
    t.eq(may, false, 'a client may not pause')
    t.eq(why, 'you cannot pause an online game', 'and is told in plain words')

    local ok, refusal = c:pause('menu')
    t.eq(ok, nil, 'the pause is refused')
    t.eq(refusal, why, 'with the same sentence')
    t.eq(c:isPaused(), false, 'nothing paused')
    t.eq(c:simDelta(0.016), 0.016, 'and the client keeps simulating')

    ---------------------------------------------------------------------
    t.describe('host: off by default, because it freezes everyone')

    local h = Session.new{ role = 'host' }
    t.eq(h:pause('menu'), nil, 'a host may not pause by default')
    t.eq(select(2, h:mayPause()), 'pausing would freeze everyone else',
         'and the refusal says whose game it would stop')

    local hp = Session.new{ role = 'host', allowHostPause = true }
    t.eq(hp:pause('menu'), true, 'a host may pause when the game allows it')
    t.eq(hp:simDelta(0.016), 0, 'and the world stops')

    ---------------------------------------------------------------------
    t.describe('changing role drops a pause it can no longer justify')

    local moving = Session.new{ role = 'solo' }
    moving:pause('menu')
    t.eq(moving:isPaused(), true, 'paused while solo')
    moving:setRole('host')
    t.eq(moving:isPaused(), false, 'hosting resumes it rather than freezing')
    t.eq(moving:simDelta(0.016), 0.016, 'so the clock cannot stick forever')

    moving:setRole('solo')
    t.eq(moving:pause('menu'), true, 'and solo may pause again')
    t.eq(select(2, moving:setRole('spectator')), 'unknown role', 'unknown roles refuse')
    t.eq(moving.role, 'solo', 'and change nothing')

    ---------------------------------------------------------------------
    t.describe('menus open even where pauses are refused')

    local m = Session.new{ role = 'solo' }
    local opened, blocked = m:openMenu()
    t.eq(opened, true, 'solo menu opens')
    t.eq(blocked, nil, 'with no refusal')
    t.eq(m:isPaused(), true, 'and pauses')
    m:closeMenu()
    t.eq(m:menuOpen(), false, 'menu closes')
    t.eq(m:isPaused(), false, 'and the pause closes with it')

    local mc = Session.new{ role = 'client' }
    opened, blocked = mc:openMenu()
    t.eq(opened, true, 'an online menu still opens')
    t.eq(blocked, 'you cannot pause an online game',
         'and reports that it could not stop time')
    t.eq(mc:menuOpen(), true, 'the menu is up')
    t.eq(mc:simDelta(0.016), 0.016, 'while the game keeps running underneath')
    mc:closeMenu()
    t.eq(mc:menuOpen(), false, 'and closes')

    -- A pause taken for another reason is not cancelled by closing a menu.
    local keep = Session.new()
    keep:pause('focus')
    keep:openMenu()
    keep:closeMenu()
    t.eq(keep:isPaused(), true, 'closing a menu does not undo a focus pause')
    t.eq(keep:reason(), 'focus', 'which still knows why it paused')

    ---------------------------------------------------------------------
    t.describe('ending: the first reason wins')

    local ended = {}
    local e = Session.new{
        role = 'client',
        onEnd = function(_, kind, text) ended[#ended + 1] = kind .. ':' .. text end,
    }
    t.eq(e:isOver(), false, 'running')
    t.eq(e:disconnected('the server stopped responding', 'timeout'), true, 'ends')
    t.eq(e:isOver(), true, 'over')
    t.eq(e:reason(), 'the server stopped responding', 'with the sentence to show')
    t.eq(e:endKindOf(), 'timeout', 'and the kind')
    t.eq(e:endedByChoice(), false, 'nobody chose this')
    t.eq(e:simDelta(0.016), 0, 'an ended session simulates nothing')
    t.eq(#ended, 1, 'onEnd fired once')

    -- The cascade: transport timeout, then a disconnect event, then the state
    -- machine giving up. Only the first is worth showing anyone.
    t.eq(e:disconnected('the server closed the connection'), false,
         'a later reason does not overwrite')
    t.eq(e:reason(), 'the server stopped responding', 'the first sentence stands')
    t.eq(#ended, 1, 'and onEnd does not fire again')

    -- An ended session refuses to pause or open a menu.
    t.eq(e:pause('menu'), nil, 'no pausing what is already over')
    t.eq(select(2, e:mayPause()), 'the session is over', 'and it says so')
    t.eq(e:openMenu(), nil, 'no menu either')

    local q = Session.new()
    q:quit()
    t.eq(q:endedByChoice(), true, 'quitting is a decision, not an interruption')
    t.eq(q:endKindOf(), 'quit', 'recorded as such')

    -- An unrecognised kind is still an ending, filed as a loss.
    local odd = Session.new()
    odd:endSession('meteor', 'a meteor hit the server')
    t.eq(odd:endKindOf(), 'lost', 'unknown kinds fall back to lost')
    t.eq(odd:reason(), 'a meteor hit the server', 'keeping the sentence')

    ---------------------------------------------------------------------
    t.describe('restart and status')

    local r = Session.new{ role = 'client' }
    r:disconnected('kicked for idling', 'kicked')
    r:restart('solo')
    t.eq(r:isOver(), false, 'restart clears the ending')
    t.eq(r.role, 'solo', 'and takes the new role')
    t.eq(r:simDelta(0.016), 0.016, 'and time runs')
    t.eq(r:pause('menu'), true, 'and it may pause again')

    local st = r:status()
    t.eq(st.state, 'paused', 'status reports paused')
    t.eq(st.role, 'solo', 'with the role')
    t.eq(st.reason, 'menu', 'and the reason')
    r:resume()
    t.eq(r:status().state, 'running', 'and running once resumed')

    r:disconnected('lost the host')
    st = r:status()
    t.eq(st.state, 'over', 'status reports the ending')
    t.eq(st.byChoice, false, 'and that it was not chosen')
end
