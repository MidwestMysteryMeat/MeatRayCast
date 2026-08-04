--[[
    Committed throughput FLOORS for meatray.dev.microbench (G7).

    Each number is ops-per-second below which the bench lane FAILS. They are
    set to roughly 45% of the throughput measured on the authoring machine
    (LuaJIT, 2026-08-03), which is another way of saying: a real 2x slowdown
    trips them, and ordinary machine-to-machine spread does not. A benchmark
    that fires on noise is a benchmark people learn to ignore.

    These are FLOORS, not targets — a faster machine sails past them, which is
    correct; the point is to catch a hot path that got 2x slower, not to pin a
    speed. When a change makes something legitimately and permanently slower,
    lower its floor here in the same commit and say why, so the next reader
    knows the budget moved on purpose.

    gas.step is a fast-path guard: the gas field short-circuits on a settled
    field, and the bench perturbs it only slightly, so this floor mostly
    protects that early-out from regressing into full work every tick.
]]

return {
    ['snapshot.encode']   = 15000,
    ['snapshot.decode']   = 25000,
    ['worldgen.generate'] = 2000,
    ['gas.step']          = 2000000,
    -- 150 LOD-enabled agents; measured ~4300/s (= ~70 full crowd steps per
    -- rendered frame of headroom). Guards the flow-field/steering hot loop.
    ['crowd.step150']     = 1900,
    ['demo.checksum']     = 35000,
}
