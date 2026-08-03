--[[
    F7: votes — one at a time, one ballot per peer, threshold of the whole
    electorate (silence is NO), the target has no say on their own kick, early
    pass and early fail, cooldown, and disconnect handling.
]]

return function(t)
    local Vote = require('meatray.game.vote')
    local Game = require('meatray.game')

    t.eq(Game.vote, Vote, 'Game.vote is the module')

    ---------------------------------------------------------------------
    t.describe('calling: validated, one at a time')

    local passed
    local v = Vote.new{ duration = 30, threshold = 0.5,
                        onPass = function(vote) passed = vote end }

    t.eq(select(2, v:call('teleport', {}, { 1, 2 })), 'unknown vote kind: teleport',
         'an unknown kind is refused')
    t.eq(select(2, v:call('map', {}, { 1, 2 })), 'bad proposal for a map vote',
         'a map vote with no map is refused')

    local vote = v:call('map', { map = 'arena', by = 1 }, { 1, 2, 3, 4 })
    t.ok(vote, 'a valid vote opens')
    t.eq(vote.eligible, 4, 'the electorate is counted')
    t.eq(v:status().yes, 1, 'the caller\'s yes is implied')
    t.eq(select(2, v:call('restart', {}, { 1, 2 })),
         'a vote is already in progress', 'a second vote is refused while one is live')

    ---------------------------------------------------------------------
    t.describe('threshold is of the whole electorate; silence is NO')

    -- 4 electors, threshold 0.5 => need floor(0.5*4)+1 = 3 yes to pass.
    t.eq(v:status().need, 3, 'more than half of four is three')
    v:cast(2, true)                        -- caller(1) + 2 = 2 yes
    t.eq(v:update(0), nil, 'two of four is not enough, vote stays open')
    v:cast(3, true)                        -- 3 yes
    t.eq(v:update(0), 'pass', 'the third yes passes it the moment it lands')
    t.eq(passed.args.map, 'arena', 'and onPass fired with the proposal')
    t.eq(v:isActive(), false, 'the vote closed')

    ---------------------------------------------------------------------
    t.describe('a vote nobody answers fails when the clock runs out')

    v.cooldownLeft = 0                     -- skip the cooldown for the test
    local failed
    v.onFail = function(vote) failed = vote end
    v:call('restart', { by = 1 }, { 1, 2, 3, 4 })
    -- Only the caller's implied yes: 1 of 4, need 3. Never reachable? No —
    -- three electors have not voted, so it is not yet a certain fail; it rides
    -- the clock.
    t.eq(v:update(10), nil, 'still open at first because the rest COULD vote yes')
    t.eq(v:update(30), 'fail', 'but the clock runs out short of the threshold')
    t.ok(failed, 'and onFail fired')

    ---------------------------------------------------------------------
    t.describe('early fail: once it cannot reach the threshold, it is over')

    v.cooldownLeft = 0
    v:call('restart', { by = 1 }, { 1, 2, 3, 4 })   -- need 3, caller = 1 yes
    v:cast(2, false)
    v:cast(3, false)                       -- 1 yes, 2 no, 1 outstanding: max 2 yes < 3
    t.eq(v:update(0), 'fail', 'it fails early — no clock needed once it is lost')

    ---------------------------------------------------------------------
    t.describe('the kick target has no say on their own removal')

    v.cooldownLeft = 0
    local kickVote = v:call('kick', { target = 7, by = 1 }, { 1, 7 })
    t.eq(kickVote.eligible, 1, 'the target is struck from the electorate')
    t.eq(select(2, v:cast(7, false)), 'not eligible to vote',
         'and cannot cast a ballot')
    -- Electorate is just the caller; need floor(0.5*1)+1 = 1, caller already yes.
    t.eq(v:update(0), 'pass', 'so the lone caller carries their own kick')

    ---------------------------------------------------------------------
    t.describe('one ballot per peer, changeable until close')

    v.cooldownLeft = 0
    v:call('restart', { by = 1 }, { 1, 2, 3, 4, 5 })   -- need floor(2.5)+1 = 3
    v:cast(2, true)                        -- caller + 2 = 2 yes
    v:cast(2, false)                       -- 2 changes their mind: back to 1 yes
    t.eq(v:status().yes, 1, 'recasting replaces, it does not add')
    t.eq(v:status().no, 1, 'and the change is recorded')

    ---------------------------------------------------------------------
    t.describe('cooldown blocks a rapid re-call')

    local cd = Vote.new{ duration = 5, cooldown = 10 }
    cd:call('restart', { by = 1 }, { 1 })  -- 1 elector, need 1, caller yes: passes
    cd:update(0)
    t.eq(cd:isActive(), false, 'the vote resolved')
    t.ok(select(2, cd:call('restart', { by = 1 }, { 1 })):find('wait'),
         'and a second cannot be called during the cooldown')
    cd:update(10)
    t.ok(cd:call('restart', { by = 1 }, { 1 }), 'but can once it elapses')

    ---------------------------------------------------------------------
    t.describe('a voter leaving shrinks the electorate')

    local dv = Vote.new{ duration = 30, threshold = 0.5 }
    dv:call('restart', { by = 1 }, { 1, 2, 3, 4 })    -- need 3
    dv:cast(2, true)                        -- 2 yes
    dv:removeVoter(3)                        -- now 3 electors, need floor(1.5)+1 = 2
    dv:removeVoter(4)                        -- now 2 electors, need floor(1)+1 = 2
    t.eq(dv:status().eligible, 2, 'the electorate shrank')
    t.eq(dv:status().need, 2, 'and the bar came down with it')
    t.eq(dv:update(0), 'pass', 'so the two present yes-votes now carry it')

    ---------------------------------------------------------------------
    t.describe('status and describe are announce-ready')

    local sv = Vote.new{}
    t.eq(sv:status(), nil, 'no status when nothing is live')
    sv:call('kick', { target = 9, by = 1 }, { 1, 2 })
    t.ok(sv:describe():find('kick'), 'describe names the action')
    t.ok(sv:describe():find('9'), 'and the target')
    local st = sv:status()
    t.eq(st.kind, 'kick', 'status carries the kind')
    t.ok(st.left > 0, 'and the time left')
end
