# Beyond v1.0.0 — gaps, and an honest re-look at the "non-goals"

`ROADMAP.md` is the historical build order (all done). This is the
forward-looking list: the real gaps, and a corrected judgement of the things
earlier docs filed as "non-goals" — some too fast. Every item gets an honest
**feasibility**, **effort**, **value**, and a **plan or a defence**, because
"non-goal" should mean "wrong for this engine", not "not thought through".

Effort is rough calendar-for-one-focused-agent: S = a session, M = a few,
L = a sustained project, XL = multi-week.

---

## Part 1 — the gaps (things that should exist and don't)

### Crash reporting — DONE

`app.crash`: a `love.errorhandler` writes a report (build version, traceback,
OS, recent log) to the save directory and to stdout, then defers to LÖVE's own
error screen so the player-facing behaviour is unchanged. No telemetry —
writing a file is the whole feature; uploading is a consent+server decision
left to the game. Formatter headless-tested.

### macOS `.app` bundle — PLANNED (S), partial

The `.love` already runs on macOS via `love game.love`. A `.app` is mostly a
directory + `Info.plist` around a macOS `love` binary. `package.sh` can
assemble the bundle; the one piece it cannot supply on a non-Mac build box is
the macOS `love` binary itself. **Plan:** `package.sh` emits the `.app`
skeleton (Info.plist, `Resources/*.love`, the launch layout) and documents
dropping in `Contents/MacOS/love` from a macOS LÖVE — or, run on a Mac,
assembles the whole thing. Signing is the next item.

### Code signing / notarization — PLANNED (S to document), needs YOUR accounts

Cannot be done autonomously: Windows Authenticode needs your certificate,
Apple notarization needs your Developer ID and an Apple ID. **Plan:** document
the exact `signtool` (Windows) and `codesign` + `notarytool` (macOS) steps and
have the packager emit artifacts in the layout those tools expect, so signing
is one command you run with your credentials. The build is ready to sign; the
identity is yours.

### Player accounts / identity — PLANNED (M), a real design choice

Two honest tiers, and the first needs no backend:

1. **Self-sovereign crypto identity (M, no server).** Each client generates a
   keypair once (the crypto module already has the primitives) and signs its
   JOIN. A name becomes bound to a key: impersonation needs the private key,
   not just the string, and a server allows/bans by key. This is 80% of what
   "accounts" is for on a private/community server, with zero infrastructure,
   and it composes with the password-sealing and session-resume already built.
2. **Central accounts (L, needs a service).** Usernames, auth, cross-server
   persistence — a real backend (the master server is the natural host). A
   product decision; defer until a deployment needs it.

**Plan:** build tier 1; leave tier 2 until there is a reason.

### Networked demo recording — PLANNED (M)

Demos are solo-only; a hosted/joined session cannot be recorded. **Plan:** the
client captures the snapshot stream it already receives (plus its own inputs)
into the existing demo format, and replays by feeding those snapshots back
instead of simulating. The format and divergence-checksum machinery exist;
this is a capture/playback path on the client, not a new format.

### Sandboxed text modding — PLANNED (L), the honest Phase-4 gap

Visual graphs (F9-sandboxed) are the only safe lane for untrusted mods; there
is no ZScript/ACS-style text scripting. **Plan:** a restricted Lua environment
(no `io`/`os`/`load`/FS, a stepped instruction budget, an allowlisted API) —
the graph sandbox already proves the model; this extends it to text. Real work
and a real security surface, so it waits behind a reason (a workshop, maps
that outgrow graphs).

---

## Part 2 — the "non-goals", re-judged

### GPU rendering — RECLASSIFIED: not a non-goal. Feasible, valuable, L.

Filing this as a non-goal was wrong — it is a real optional project, not an
architectural impossibility. The renderer is a pure-CPU immediate-mode column
loop, which is the single biggest frame cost. Two honest paths:

- **A — batch the draw (M).** Keep the CPU DDA (the sim needs its exact hit
  info anyway) but emit the wall columns into one `Mesh`/`SpriteBatch` and draw
  in a single call instead of per-column immediate rectangles. A real GPU win,
  no logic duplicated, determinism and the headless split untouched. This is
  also the long-standing K2 item; it should just be done.
- **B — a shader raycaster (L).** DDA in a GLSL fragment shader sampling a
  texture atlas and the tile grid uploaded as a texture. The big win, and the
  big cost: the DDA now lives in TWO places (GLSL for pixels, Lua for the sim)
  that must never disagree, plus GLSL is a new, harder-to-test surface.

**Plan:** do **A** (clear win, low risk). Treat **B** as a real future project
gated on a profile showing the column loop is the bottleneck on target
hardware — decide by measurement, the rule that unblocked the crypto fast path.

### Mirrors — RECLASSIFIED: feasible, M.

Flat-wall mirrors are tractable: `Collide.rayTile` already returns the surface
normal, so a ray hitting a mirror wall reflects across it and continues, with a
recursion-depth cap. **Plan:** a `mirror` `.map` tile flag + a bounded
reflection pass in the renderer. Real feature, bounded scope. Not a non-goal —
just unbuilt.

### Portals — SPLIT honestly.

- **Axis-aligned portal pairs (M):** teleport a ray from one portal surface to
  its pair with a fixed transform, depth-capped. Feasible, same shape as
  mirrors. Buildable when a game wants it.
- **Arbitrary non-Euclidean open-tile portals (research, XL+):** *this* is the
  one with no clean public path in a tile-DDA renderer — the original note was
  right, but only about this case. Genuinely hard; honestly deferred.

### Build-style sectors — STILL a non-goal, and here is why.

This one I defend. Build (Duke3D) is not a tile grid at all: sectors are
arbitrary polygons with independent floor/ceiling planes and portals between
them. Adopting it means replacing the core world representation and, with it,
collision, rendering, pathfinding, the map format, and the editor — a different
engine, multi-year. And the *practical* wins people want from Build —
verticality, slopes, room-over-room — are already partly served by storeys +
variable heights and can be extended INCREMENTALLY (per-tile slope data, more
storey polish) without the rewrite. **Plan:** keep the tile core; grow
verticality within it as demand appears. Full sectors stay out.

### Voice chat — STILL a non-goal, defended.

Capture, a codec, mixing, echo cancellation and a jitter buffer are a large
specialized project that Steam and Discord solve better than an indie engine
will. Building it would be reinventing a solved wheel worse. Deferred to those
platforms.

### C ABI / native plugins — STILL a non-goal, defended.

The determinism and dual-interpreter portability guarantees rest on pure Lua;
native plugins break both, and the RL environment server and the MCP server
already provide the external-integration story a C ABI would be wanted for.
Stays out.

---

## The corrected shape

Filed too fast as non-goals, actually buildable: **GPU rendering (batch now,
shader later), mirrors, axis-aligned portals.** Genuine non-goals with real
defences: **Build sectors, voice, C ABI, arbitrary non-Euclidean portals.**
Real gaps with plans: **accounts (crypto-identity first), signing (needs your
certs), the .app bundle, networked demos, text modding** — and crash
reporting, now done.

Honest priority if the goal is "an engine people choose to ship on": GPU batch
draw (perf people feel) → crypto identity (private servers people trust) → the
.app bundle + signing docs (mac players) → mirrors and the rest as specific
games ask. None of it changes the fact that the biggest lever is still a human
playing v1.0.0.
