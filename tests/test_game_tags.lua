--[[
    Hierarchical gameplay tags.

    The interesting assertions are the near-misses. A prefix comparison alone
    makes `damage.typeX` look like a child of `damage.type`, and a resistance
    written for `damage.type` would then soak an unrelated tag forever without
    anybody noticing, because the symptom is a number being slightly too small.
]]

return function(t)
    local Tags = require('meatray.game.tags')

    ---------------------------------------------------------------------
    t.describe('validation refuses tags that would be invisible at runtime')

    t.ok(Tags.valid('damage'), 'a single word is a tag')
    t.ok(Tags.valid('damage.type.fire'), 'dotted words are a tag')
    t.ok(Tags.valid('state.stunned_hard'), 'underscores are allowed inside a segment')
    t.ok(Tags.valid('_private.tag'), 'a segment may start with an underscore')

    t.ok(not Tags.valid(''), 'the empty string is not a tag')
    t.ok(not Tags.valid('.leading'), 'a leading dot is refused')
    t.ok(not Tags.valid('trailing.'), 'a trailing dot is refused')
    t.ok(not Tags.valid('double..dot'), 'an empty segment is refused')
    t.ok(not Tags.valid('has space'), 'a space is refused')
    t.ok(not Tags.valid('9lives'), 'a segment may not start with a digit')
    t.ok(not Tags.valid(42), 'a number is not a tag')
    t.ok(not Tags.valid(nil), 'nil is not a tag')

    local ok, err = Tags.check('bad tag')
    t.ok(ok == nil and type(err) == 'string', 'check returns a reason, not a raise')

    ---------------------------------------------------------------------
    t.describe('matching respects the hierarchy')

    t.ok(Tags.matches('damage.type.fire', 'damage.type.fire'), 'exact matches')
    t.ok(Tags.matches('damage.type.fire', 'damage.type'), 'a child matches its parent query')
    t.ok(Tags.matches('damage.type.fire', 'damage'), 'and its grandparent')
    t.ok(Tags.matches('damage.type.fire.greek', 'damage.type.fire'),
         'a tag invented later still matches the query written first')

    -- The whole reason this module exists rather than string.find.
    t.ok(not Tags.matches('damage.typeX', 'damage.type'),
         'damage.typeX is NOT a child of damage.type')
    t.ok(not Tags.matches('damage.types', 'damage.type'),
         'nor is damage.types')
    t.ok(not Tags.matches('damagex', 'damage'), 'nor damagex of damage')
    t.ok(not Tags.matches('damage', 'damage.type'),
         'a parent does not satisfy a more specific query')
    t.ok(not Tags.matches('heal.over_time', 'damage'), 'unrelated tags do not match')
    t.ok(not Tags.matches(nil, 'damage'), 'a nil owned tag matches nothing')
    t.ok(not Tags.matches('damage', nil), 'a nil query matches nothing')

    ---------------------------------------------------------------------
    t.describe('ancestors and parents')

    local chain = Tags.ancestors('damage.type.fire')
    t.eq(#chain, 3, 'three levels')
    t.eq(chain[1], 'damage.type.fire', 'most specific first')
    t.eq(chain[2], 'damage.type', 'then the parent')
    t.eq(chain[3], 'damage', 'then the root')
    t.eq(Tags.parent('damage.type.fire'), 'damage.type', 'parent of a child')
    t.eq(Tags.parent('damage'), nil, 'a root has no parent')
    t.eq(#Tags.ancestors(''), 0, 'the empty string has no ancestors')

    ---------------------------------------------------------------------
    t.describe('containers count grants rather than flagging them')

    local c = Tags.newContainer()
    t.ok(c:isEmpty(), 'a new container is empty')
    t.ok(not c:has('state.stunned'), 'and has nothing')

    c:add('state.stunned')
    c:add('state.stunned')
    t.eq(c:count('state.stunned'), 2, 'two grants counted')

    c:remove('state.stunned')
    t.ok(c:has('state.stunned'), 'one effect expiring leaves the other stun standing')
    c:remove('state.stunned')
    t.ok(not c:has('state.stunned'), 'the second removal clears it')
    t.eq(c:count('state.stunned'), 0, 'and the count is zero, not negative')

    c:remove('state.stunned')
    t.eq(c:count('state.stunned'), 0, 'removing what is not there is harmless')

    local added, addErr = c:add('not a tag')
    t.ok(added == nil and addErr ~= nil, 'an invalid tag is refused with a reason')

    ---------------------------------------------------------------------
    t.describe('container queries are hierarchical')

    local d = Tags.newContainer()
    d:add('damage.type.fire')
    d:add('state.stunned')

    t.ok(d:has('damage'), 'a parent query finds the child')
    t.ok(d:has('damage.type'), 'and an intermediate one')
    t.ok(d:has('damage.type.fire'), 'and the exact tag')
    t.ok(not d:has('damage.type.ice'), 'a sibling is not found')
    t.ok(not d:has('damage.typeX'), 'and neither is a near-miss')

    t.ok(d:hasExact('damage.type.fire'), 'hasExact finds the exact tag')
    t.ok(not d:hasExact('damage.type'), 'hasExact does not walk the hierarchy')

    local any, which = d:hasAny({ 'state.rooted', 'state.stunned' })
    t.ok(any, 'hasAny finds one of several')
    t.eq(which, 'state.stunned', 'and names which')

    local all, missing = d:hasAll({ 'damage', 'state.silenced' })
    t.ok(not all, 'hasAll fails when one is absent')
    t.eq(missing, 'state.silenced', 'and names the missing one')
    t.ok(d:hasAll({ 'damage', 'state' }), 'hasAll passes when all are present')
    t.eq(d:firstMatch({ 'nothing.here', 'damage' }), 'damage', 'firstMatch names the hit')
    t.eq(d:firstMatch({ 'nothing.here' }), nil, 'and nil when there is none')

    ---------------------------------------------------------------------
    t.describe('the wire form is sorted, so it is the same everywhere')

    local w = Tags.newContainer()
    w:add('state.stunned')
    w:add('ability.dash')
    w:add('damage.type.fire')

    local s = w:toString()
    t.eq(s, 'ability.dash damage.type.fire state.stunned', 'sorted, space separated')

    -- Insertion order must not change the string: this ends up in a snapshot,
    -- and a field that changes for no reason is a field that costs bandwidth
    -- every tick and defeats any future delta compression.
    local w2 = Tags.newContainer()
    w2:add('damage.type.fire')
    w2:add('state.stunned')
    w2:add('ability.dash')
    t.eq(w2:toString(), s, 'a different insertion order produces the same string')

    local back = Tags.fromString(s)
    t.ok(back:has('damage'), 'a parsed container answers hierarchical queries')
    t.eq(back:toString(), s, 'and round-trips')

    t.ok(Tags.stringHas(s, 'damage.type'), 'stringHas walks the hierarchy too')
    t.ok(not Tags.stringHas(s, 'damage.typeX'), 'including the near-miss')
    t.ok(not Tags.stringHas(nil, 'damage'), 'and a nil string has nothing')

    t.eq(Tags.newContainer():toString(), '', 'an empty container is the empty string')

    w:clear()
    t.ok(w:isEmpty(), 'clear empties the container')
    t.eq(#w:list(), 0, 'and its listing')
end
