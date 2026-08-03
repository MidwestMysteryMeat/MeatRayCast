--[[
    F6: the message system — centerprint arbitration, the fading ticker, the
    obituary feed, and fades that run on real time.
]]

return function(t)
    local Messages = require('meatray.game.messages')
    local Game = require('meatray.game')

    t.eq(Game.messages, Messages, 'Game.messages is the module')

    ---------------------------------------------------------------------
    t.describe('centerprint is exclusive and priority-arbitrated')

    local m = Messages.new{ fade = 0.5 }
    t.eq(m:centered(), nil, 'nothing centred at the start')

    m:centerprint('GO', { hold = 2, size = 'big' })
    local c = m:centered()
    t.eq(c.text, 'GO', 'the centerprint shows')
    t.eq(c.size, 'big', 'at its size')
    t.eq(c.alpha, 1, 'full while held')

    -- A LOWER priority does not shove a live higher one aside.
    m:centerprint('countdown 3', { priority = 5, hold = 3 })
    t.eq(m:centered().text, 'countdown 3', 'a higher priority replaces')
    t.eq(m:centerprint('a pickup shout', { priority = 1 }), false,
         'a lower priority is refused while the higher one lives')
    t.eq(m:centered().text, 'countdown 3', 'so the important one keeps the middle')

    -- Equal or higher always replaces.
    t.eq(m:centerprint('countdown 2', { priority = 5 }), true, 'equal priority replaces')
    t.eq(m:centered().text, 'countdown 2', 'with the newer text')

    ---------------------------------------------------------------------
    t.describe('centerprint fades then clears on real time')

    local f = Messages.new{ fade = 0.5 }
    f:centerprint('FLASH', { hold = 1 })   -- life = hold + fade = 1.5
    f:update(1.25)                         -- clearly into the fade: life 0.25
    local mid = f:centered()
    t.ok(mid and mid.alpha < 1 and mid.alpha > 0, 'fading, not gone')
    f:update(0.5)                          -- fade complete
    t.eq(f:centered(), nil, 'and then cleared')

    ---------------------------------------------------------------------
    t.describe('the ticker feeds, caps and fades oldest first')

    local tk = Messages.new{ tickerHold = 2, fade = 0.5 }
    tk:pickup('picked up the red key')
    tk:notify('objective: reach the exit')
    local rows = tk:ticker()
    t.eq(#rows, 2, 'both lines')
    t.eq(rows[1].text, 'picked up the red key', 'oldest first')
    t.eq(rows[1].kind, 'pickup', 'tagged by channel')
    t.eq(rows[2].kind, 'notify', 'and the other')

    for i = 1, 10 do tk:pickup('spam ' .. i) end
    t.eq(#tk:ticker(), Messages.TICKER_MAX, 'the feed is capped')
    t.eq(tk:ticker()[#tk:ticker()].text, 'spam 10', 'newest kept')

    -- The oldest fades out first. Both start at life = hold+fade = 1.5.
    local age = Messages.new{ tickerHold = 1, fade = 0.5 }
    age:pickup('first')
    age:update(0.5)                        -- first: life 1.0
    age:pickup('second')                   -- second: life 1.5
    age:update(0.8)                        -- first: 0.2 (fading); second: 0.7 (held)
    local a = age:ticker()
    t.ok(a[1].alpha < 1, 'the older line is fading')
    t.eq(a[2].alpha, 1, 'the newer is still full')
    age:update(0.3)                        -- first: -0.1 (gone); second: 0.4
    t.eq(#age:ticker(), 1, 'the older one dropped')
    t.eq(age:ticker()[1].text, 'second', 'leaving the newer')

    ---------------------------------------------------------------------
    t.describe('killfeed is structured, newest first, capped')

    local kf = Messages.new{ killHold = 2, fade = 0.5 }
    kf:kill('meat', 'grunt', 'rocket')
    kf:kill(nil, 'meat', 'lava')           -- an environment kill: no attacker
    local feed = kf:killfeed()
    t.eq(#feed, 2, 'two obituaries')
    t.eq(feed[1].victim, 'meat', 'newest first')
    t.eq(feed[1].attacker, nil, 'a nil attacker reads as the world')
    t.eq(feed[1].cause, 'lava', 'with the cause')
    t.eq(feed[2].attacker, 'meat', 'and the earlier row below')

    for i = 1, 10 do kf:kill('a', 'b' .. i, 'x') end
    t.eq(#kf:killfeed(), Messages.KILLFEED_MAX, 'the feed is capped')

    kf:update(10)
    t.eq(#kf:killfeed(), 0, 'and everything expires')

    ---------------------------------------------------------------------
    t.describe('clear and garbage-dt hygiene')

    local h = Messages.new()
    h:centerprint('x'); h:pickup('y'); h:kill('a', 'b', 'c')
    h:update(-5)                           -- negative dt must not run time backwards
    t.ok(h:centered() ~= nil, 'a negative dt is ignored, nothing expired early')
    h:clear()
    t.eq(h:centered(), nil, 'clear clears the centerprint')
    t.eq(#h:ticker(), 0, 'the ticker')
    t.eq(#h:killfeed(), 0, 'and the killfeed')
end
