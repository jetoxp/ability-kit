# Phase 7 — the HUD

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase is for

The kit sends a snapshot to the client at 10 Hz and nothing draws it. This phase writes the thing that
draws it, and it is the first phase whose subject is a **consumer** rather than a decision-maker: the
HUD is where the project finds out whether the state it chose to replicate is actually enough to build
a game's interface on.

## Decisions, taken before any code exists

### D1. The HUD is a pure presenter and a dumb renderer

The same seam as everywhere else, applied one layer out:

```
HudPresenter (pure)   snapshot + elapsed time -> a description of what to draw, as plain tables
HudRenderer  (engine) that description -> Instance writes, and nothing else
```

The presenter takes no `Instance`, reads no engine time and touches no service, so **phase 7 has a
suite** — the first UI in this project that does. The renderer decides nothing: it is told "bar 3 is at
41% and is cooling down" and it draws 41%.

This is not decoration. Putting interpolation in the renderer and the *figures to interpolate* in the
presenter is the difference between testing the arithmetic and testing the pixels.

### D2. The client interpolates between snapshots, and it may not invent a value

The server speaks at 10 Hz; a screen refreshes faster. A cooldown drawn from a snapshot that arrives ten
times a second visibly steps, so the renderer interpolates **between the last two snapshots** using the
time since the last one arrived.

The presenter is given that elapsed time as an input and produces the interpolated figure; it never reads
a clock. **The client never extends a cooldown, shortens one, or decides an ability is ready on its own.**
If the server says 1.4, the client draws a value between 1.4 and the next one it receives — never less
than zero, and it never concludes "ready" before the server does. The snapshot is the authority; the
interpolation is presentation.

### D3. The cast bar comes from `cast.progress`

The snapshot's `cast` is `{ id, slot, remaining, progress }` or `nil`. **The bar is driven by
`progress`**, which the server already computed as a 0..1 fraction, and not by dividing `remaining` by
something the client does not have.

And it is driven by the server's `cast` being present at all: when the snapshot says `nil`, there is no
bar, whatever the previous frame was drawing. **A cast bar that lingers because the client did not notice
the cast ended is a client that is deciding.**

### D4. Names come from the catalog, not from the snapshot — and that is a decision, not an accident

`equipped[slot]` carries an ability **id** (`"FIREBALL"`), not a display name and not an icon. The
snapshot deliberately carries no costs, no effects and no definitions: the client is told what it needs
to draw a bar, and nothing more.

Two ways to put a name on a slot:

- **the snapshot carries `displayName`** — this makes the state bigger and puts presentation data on the
  wire, but the client needs no other source;
- **the HUD reads the replicated catalog** — `src/shared` maps to `ReplicatedStorage`, so the
  definitions are already on the client, and the presenter can resolve an id to a name and an icon
  without changing the protocol.

**This phase takes the second**: the snapshot is *state*, the catalog is *static data*, and a UI is
allowed to know what an ability is called. It does **not** follow that the client may read costs or
effects for display — the HUD shows cooldowns and resources, and what is not in the snapshot is not
drawn.

### D5. Keybinds are shown, not configurable

The client binds `1`..`4` to slots `1`..`4`; the HUD shows that mapping. Rebinding is out of scope: the
key list lives in one place and the HUD reads it rather than keeping a second copy that can drift.

### D6. What the HUD does not have, because the client does not receive it

Declared before anything is built, so that nobody discovers it while drawing:

- **There is no effect state on the client.** The snapshot carries resources, cooldowns, equipped,
  globalCooldown and cast — and no list of active effects. **A buff icon with a remaining time is not
  drawable from what the client has**, and it is not in this phase.
- **No damage numbers and no hit markers.** The client is never told a damage number or a hit result;
  that is phase 5's decision and this phase does not reopen it.
- **No target indicator** until targeting tells the client who was hit, which it does not.

If the HUD needs any of those, it is a decision about the snapshot — made deliberately and in its own
phase — and not a client that guesses.

### D7. `ClientState.changed` gets its first real consumer

Phase 5 left a note: `changed` is created by the client script, so a module requiring `ClientState`
earlier in the load order sees `nil`. The HUD is the first consumer that note was written for, and it
makes the order concrete: **the client script requires `ClientState`, creates the event, and then
requires the HUD** — or the HUD guards. The note stops being a note and becomes a call site.

## How this phase closes

With the same discipline as the last two, and this time the suite can do part of the work because the
presenter is pure:

1. **The presenter's suite** covers the arithmetic — interpolation between two snapshots, a cooldown
   crossing zero without going negative, a missing `cast` producing no bar, and a snapshot that has not
   advanced producing the same output.
2. **An observed run**, because a presenter with a suite proves the numbers and not the screen: the
   cooldown sweep visibly moving, the cast bar filling during a 0.4s cast, the mana bar dropping on an
   activation and refilling after a death, and the keybind labels matching the slots that fire.
3. **The one comparison that matters**: what the HUD shows against what the server's snapshot says, at
   the same moment. A HUD that is pretty and wrong is the same failure this project keeps finding, one
   layer out.

## Out of scope, declared

- **Damage numbers, hit markers, target indicators** — see D6.
- **Effect icons with durations** — the client has no effect state.
- **Rebindable keys** — see D5.
- **Any HUD logic that the server could do** — if a value can be computed once on the server, the client
  draws a number rather than deriving it.
