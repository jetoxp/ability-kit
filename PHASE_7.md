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
a clock.

**Interpolation, not extrapolation, and the difference is the whole point.** The figure drawn is a value
*between the two snapshots*, never beyond the last one: at the end of an interval it equals what the
server last said, and it cannot jump ahead of it. Extrapolation — extending the last value forward from
the last one received — would reach zero on its own, early, on any long frame, and would then need a
special case for "the client thinks it is ready but the server disagrees". **Interpolation lags up to
one interval behind and is therefore never wrong; extrapolation is smooth and occasionally lies.** The
100 ms of lag is the price of never having to be trusted. **The client never extends a cooldown, shortens one, or decides an ability is ready on its own.**
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

**And the HUD is the reason `ClientState` grows from one snapshot to two.** D2 interpolates between the
previous and the latest, and somebody has to keep the pair; the alternative is the presenter holding
history, which would break the property that makes it testable ("snapshot in, description out"). So the
duplicated state lives next to the state: `ClientState.previous` and `ClientState.latest`, written in
the same `set()` that already existed. **Interpolation is between them, never against a clock.**


## How this phase closes

With the same discipline as the last two, and this time the suite can do part of the work because the
presenter is pure:

1. **The presenter's suite** covers the arithmetic — interpolation between two snapshots, a cooldown
   crossing zero without going negative, a missing `cast` producing no bar, and a snapshot that has not
   advanced producing the same output.
2. **An observed run**, because a presenter with a suite proves the numbers and not the screen: the
   cooldown sweep visibly moving, the cast bar filling during a 0.4s cast, the mana bar dropping on an
   activation and refilling after a death, and the keybind labels matching the slots that fire.
3. **The one comparison that matters**: what the HUD shows against what the server's snapshot says. A
   HUD that is pretty and wrong is the same failure this project keeps finding, one layer out.

**The harness for that third one, written before the run, because it is the criterion with a difficulty
the other two do not have.** The snapshot changes ten times a second, so "at the same moment" is not
something a person can eyeball — it has to be constructed. The procedure, in a live playtest:

```lua
-- in the same frame, from the same table:
1. read ClientState.latest.cooldowns[slot]      -- what the server last said
2. read the fraction the HUD is drawing for that slot, from the description the presenter produced
   for that same snapshot
3. compare, against a tolerance with a DIRECTION
```

**The tolerance is directional, and that is what makes the comparison checkable rather than a
judgement call.** By D2 the HUD interpolates between the last two snapshots and can therefore be at
most one interval *behind* the server's newest number — and never ahead of it. So:

- HUD **more** cooldown left than the snapshot says -> **a bug**. The presenter is inventing time.
- HUD **less** cooldown left than the snapshot says -> **legitimate interpolation**, bounded by one
  interval (100 ms).
- HUD **equal** -> the interval had elapsed and the drawn value is the server's own.

Without that asymmetry the criterion is a sentence; with it, it is a check that fails on the right
side. The same table applies to the mana bar: equal or behind, never ahead.

## Out of scope, declared

- **Damage numbers, hit markers, target indicators** — see D6.
- **Effect icons with durations** — the client has no effect state.
- **Rebindable keys** — see D5.
- **Any HUD logic that the server could do** — if a value can be computed once on the server, the client
  draws a number rather than deriving it.

## Two notes for the phase's close

**A rule that has now bitten twice, one layer apart.** `Un error dentro de un callback lo desconecta`
was learned on the server's heartbeat in phase 6: a bad argument threw inside the tick, Roblox dropped
the connection, and the game spent mana while nothing ever fired. This phase paid for the same rule one
layer out: an exception inside the client's `OnClientEvent` killed the state connection on the first
snapshot, and the client then received nothing for the rest of the session — **which looks exactly like
a server that stopped talking.** It took a listener on the same remote, attached from outside the
script, to prove the server had been talking at 10 Hz the whole time.

The rule, stated so it stops being rediscovered: **a callback is not a function call.** An exception in
a function returns to its caller; an exception in a callback disconnects it, and the failure mode is
silence. Every callback that carries state now says whether it ran.

**And the process answer, which is not a discipline.** Writing this phase went through two failures of
*personal* process — remembered text anchors in phase 4b, and pushing with eleven warnings in this one,
which let the README contradict itself for a few minutes. Both were caught by reading, not by a gate,
and personal discipline has a ceiling that has now been touched twice.

The structural fix is a CI workflow running `luau tests/run.luau`, `selene` and `stylua --check` on
every push, so that the README cannot be wrong for even a minute and the gate does not depend on
anybody having a good day. It was written down here as "the week the project consolidates", and that
week was this one: `.github/workflows/ci.yml`, thirty-odd lines, pinned to the same tool versions the
project is developed against. **A lesson that stays a discipline is a lesson on a deadline.**

## The close, with the outputs

The phase that took the most playtests ends with the least dramatic evidence, which is the point:

```
GATE(a) version al empezar : p7.6
snapshots por mi conexion  : 15   |  recibidos por el script: 86
GATE(b) version al terminar: p7.6 -> ESTABLE, la medicion vale

pantalla antes   : mana [relleno 1]     | slot1 [0.25] "1  Fireball" | slot2 "2  Poison" | ...
pantalla durante : mana [0.91] | Frame [0.21]      <- la barra de cast
pantalla despues : mana [0.82] | Frame [0.9]       <- el cooldown rellenandose
snapshot         : mana=82.74 | cd slot1=2.11
```

Three criteria, each with its number:

1. **The mana falls on the activation** — `1.0 -> 0.91 -> 0.82` with regeneration, and the bar follows.
2. **The cast bar** — a fill appears at `0.21` during the cast and disappears.
3. **HUD against snapshot** — the bar reads `0.82` against the snapshot's `82.74/100 = 0.827`: equal or
   behind, never ahead. That is the directional tolerance written before the code, and it is what makes
   the comparison a check rather than a glance.

## Three modes of silence, and what the unit of debugging is

Phase 6 learned it once, on the server's heartbeat: **an exception inside a callback disconnects it, and
the failure mode is silence.** This phase paid for it twice more, one layer out each time, and the three
cases do not look alike from the outside:

| Mode | What happened | How it was distinguished |
|---|---|---|
| Never connected | Ordering: the handler was connected after the thing that fires it | The code ran to the end and the counter stayed at zero |
| Connected and dead | An exception inside `OnClientEvent` killed the connection on the first snapshot | A counter incremented in the handler's first line |
| Connected to the wrong identity | The module the script writes and the module a probe reads were two instances, two tables, two states | A `tostring` of the table, published as an attribute |

The general rule is not "wrap things in `pcall`". It is: **a callback that never fires is
indistinguishable from one connected to something that never arrives, and the unit of debugging is the
target of the callback, not its body.** A probe on the same remote, attached from outside the script,
is what separates "the server stopped talking" from "this connection is not the one receiving".

## The double gate

Rojo syncs instance by instance, not atomically: a LocalScript and its sibling ModuleScript are two
instances with two sync lives, and a script can run holding the previous generation of the module it
requires. That is how the contradiction at the end of this phase resolved — the script published `p7.6`
while its own module answered `received = 0`, and both readings were true about different instances.

So a version read once is not a version. **The gate reads it at the start and at the end of the probe
and requires them to agree**; the cheap rule underneath it is to freeze: *between the last sync and the
run, do not touch the tree.* A probe measures one thing when the thing measured holds still. **If you
move what you measure, you measure the movement.**

## The refraction: the bug was the laboratory

Five playtests, four instruments, three ghost hypotheses — and the client script was almost certainly
correct from the commit that wrote it. The bug was not in the presenter, not in the renderer, not in the
wire: it was in the measurement environment, because the project was being edited and re-synced while
playtests were running, so the script and the probe were always a generation apart.

This is a different class from the four boundary bugs in the README's table, which were product bugs.
Both are expensive, both are found by the same discipline, and only one of them is fixed by changing
code: **not every expensive bug is in the code, and some are in the environment you measure it in.**

It also revises, with more maturity, the line this project has been telling itself since phase 1 — *the
engine found four bugs and the document found none.* **The engine also finds bugs that do not exist,
when the observer moves the telescope.**

And the failed prediction, which belongs here rather than in a footnote: phase 7 was written up as the
one phase expected to earn an entry in "What it does" without earning one in "Lessons". It earned
three. The prediction was recorded before the work, which is the only reason it counts as a prediction
rather than an excuse — **predictions here are also measured.**

