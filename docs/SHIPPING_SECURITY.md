# Protecting a shipped game — the honest menu

You asked whether we can go past bytecode and encrypt further. Yes — and
this document is the researched answer, because the topic is full of
security theatre and the difference between "raises the cost" and "actually
secret" matters.

## The one law that governs all of it

**No client-side code can be made truly secret.** If a machine can run
your game, it must be able to read your game — so any scheme that encrypts
the game files has to ship the key to unlock them in the same download. It
is a lock with the key taped to the box. A determined person will always
win against anything that runs on their hardware; this is not a
MeatRayCast limitation, it is the nature of shipping software to a machine
you do not control.

So the honest goal is never "unbreakable". It is **raising the cost** —
turning a five-second copy into an afternoon of reverse engineering, which
filters out everyone except the rare person willing to spend that
afternoon. Every technique below is measured by how much cost it adds and
how easily the afternoon-person removes it.

## The layers, weakest to strongest

### 1. Bytecode — SHIPPED (`-Compile`)

`luajit -b -s` turns each `.lua` into an opaque compiled chunk with the
comments, formatting and local names stripped. Stops "unzip and read".
**Defeated by:** a LuaJIT bytecode decompiler (`ljd`, `luajit-decomp`),
which is imperfect for 2.1 and produces unnamed, uncommented, sometimes
wrong output — an afternoon, not five seconds. Good baseline; keep it.

### 2. Encrypted bytecode — SHIPPED (`-Encrypt`, composes with `-Compile`)

Each compiled chunk is sealed with the engine's own AEAD
(`meatray.net.crypto`: encrypt-then-MAC over SHA-256) and shipped as
`.luac`. A tiny bootstrap in `conf.lua` installs a `require` loader that
decrypts each module in memory as it loads. Now an attacker cannot even
read the bytecode without first finding the key and reproducing the
decryption. **Defeated by:** finding the embedded key (it is in the
bootstrap, which ships as plain bytecode) OR hooking Lua's `load` to dump
each chunk after the loader decrypts it. Both are real work and both are
possible — this is a second deadbolt, not a vault. Honestly: it mostly
raises the cost of the *find-the-key* step; the afternoon-person still
wins. Worth it against lazy asset-flippers, not against a professional.

### 3. Anti-tamper / integrity self-checks — NOT BUILT, and mostly not worth it

Hashing your own files at boot and refusing to run if they changed. Trivially
removed (patch out the check), and it punishes legitimate users first — a
mod, a translation, an antivirus false-positive quarantine all trip it.
Commercial DRM does elaborate versions of this and it is always cracked;
for an indie game it is cost with little benefit. Deliberately skipped.

### 4. Native packing / VM obfuscation — NOT A GOAL

Tools that wrap the interpreter in a custom VM or pack the binary
(Themida-style). Enormous effort, breaks portability, and the LÖVE runtime
is open source so the seams are known. A different engine's game, not this
one. Out of scope on purpose.

### 5. Server authority — THE ONLY STRONG ANSWER, and already the architecture

The technique that actually works is not to ship the secret at all. Run
the valuable, cheatable, copy-worthy logic on **your** server, where the
client cannot read or forge it, and let the client be a renderer of state
it is *told*. MeatRayCast is already built this way: the host is
authoritative over every rule (see `docs/SECURITY.md` — damage, hits,
spawns, votes, map changes all resolve host-side; a client "asks and is
told"), and `--sealed` now encrypts the wire so the traffic cannot be read
or spoofed either. Whatever must stay secret — matchmaking, an economy, an
anti-cheat model, a progression server — belongs there. A copied *client*
of a server-authoritative game is a client with no server: it cannot BE
the game, only talk to yours.

## The recommendation

For a typical game shipped on this engine:

1. **Ship bytecode** (`-Compile`) — free, standard, stops casual reading.
2. **Add `-Encrypt`** if the single-player logic itself is the IP you are
   protecting and you accept it is a cost-raiser, not a guarantee.
3. **Put anything that must truly stay secret on a server** you control,
   with `--sealed` on the wire. This is the only part that is actually
   secure, and the engine is already shaped for it.
4. Do **not** build anti-tamper self-checks — they cost more in support
   tickets than they save in copies.

The blunt version: bytecode + encryption make copying your client annoying;
server authority makes copying it *pointless*. Spend your effort on the
second one.

## What the two engine features do (they are different things)

| Feature | Protects | Against |
|---|---|---|
| `-Compile` / `-Encrypt` | your shipped **source/logic** at rest | someone reading/copying the game files |
| `--sealed` | your network **traffic** in flight | someone reading/forging packets on the wire |

Neither is the other. A game can ship encrypted and talk in plaintext, or
ship as source and talk sealed. Match the tool to the threat.
