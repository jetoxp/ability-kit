# Phase 6 — targeting

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase is for

Every ability in this kit is self-cast. `Fireball` says it "burns a single target", `Config` carries
`range = 60`, and Fireball burns its caster — because the intent has no target and nothing on the
server resolves one. This phase makes what already exists behave as it is written.

## Decisions, taken before any code exists

These are choices, not discoveries. They are written first because the alternative — inventing the
rule at the moment it is needed, inside whatever function needs it — is how a kit ends up with two
half-rules that disagree.

### D1. Targeting is server-side, and the intent does not change

The client keeps sending `{ action = "activate", slot = N }`. Nothing about the wire moves. Target
selection, direction and range all live on the server, and a client that has an opinion about any of
them has no way to express it — which is the point.

### D2. The direction is computed by the server, and the function already exists

From the `HumanoidRootPart`'s `LookVector`, via `EffectAdapter.directionOf` — which is already
written, already flattened so a shot is not launched into the sky by somebody glancing upwards, and
already covering the vertical case. The client never sends a vector.

### D3. The enum has two values, and `nearest` is not one of them

`targeting = "self" | "raycast"`. `nearest` is deferred, deliberately:

- no definition uses it, so it would be **dead vocabulary validated at load** — a value the validator
  accepts and nothing can exercise;
- and "nearest" without its specification is ambiguous in three ways that matter: nearest within
  what range, nearest in the facing cone or in every direction, and whether walls count. Three
  questions with three wrong default answers.

It enters when a definition needs it and brings its own specification with it.

### D4. `radius` is the only genuinely new semantics, and it is two lines

- `radius == 0` → **single target**: the first hit of the raycast.
- `radius > 0` → **every candidate inside the sphere centred on the impact point.**
- and **the resolver always returns a list** — zero elements for a miss, one for a single-target
  shot, N for an area. A resolver that returned `target` for one case and `targets` for the other
  would push that special case into every caller; with a list, the caller is a loop that happens to
  run once.

**The impact point comes in, and is never nil.** The signature is
`resolve(candidates, origin, direction, range, radius, impactPoint)`, and the adapter always supplies
one:

```
hit       ->  where the ray actually landed
no hit    ->  origin + direction * range
```

The fallback is not a detail. Without it the sphere would have to be centred on nothing, or on a
guess, and the decision about what a shot that hit nothing means would move into the adapter — the
exact special case the list contract already killed for the return value. **A miss centres the blast
at the end of the shot, not in the air behind a wall.**

**Two rules about the caster**, both pure and therefore both tested here:

- **excluding the caster is the adapter's job, entirely.** The ray starts at the caster's root, and
  without `RaycastParams.FilterDescendantsInstances = { casterCharacter }` the first thing a Fireball
  hits is the arm firing it. **The resolver is not told who the caster is** and makes no exception for
  it, because an exception invented here would be describing a rule that lives in the other layer —
  the first draft of this section claimed "nothing is struck at zero distance", which is simply not
  true of a ray that starts inside a body;
- **which means the caster can be caught by the splash**, and that is geometry rather than a targeting
  decision: a blast at the caster's feet reaching the caster is the sphere doing its job.

**Selection discards candidates that are not alive**, and that rule IS here rather than in the
adapter, because it is pure and testable: **a corpse is not a target, and a shot whose only reachable
candidate is a corpse is a miss.** The adapter re-checks `Health` in engine; this is the half that has
a suite, and it is the same class of rule as the one below.

**The splash ignores walls**, and that is one line rather than a surprise: a candidate behind a wall
relative to the impact point takes the splash anyway. The raycast did the occlusion work for the
centre of the blast; the blast is the blast. **Occlusion-aware splash, like `nearest`, enters when
something asks for it by name.**

Both are stated here rather than left implicit because the first ability that needs an AoE would
otherwise invent the rule on its own, and this project has seen how that ends.

**Consequence worth stating:** under this division the resolver receives the caster as an ordinary
candidate and selects it if it is the best one — which happens exactly when the adapter failed to
filter. That is why the adapter's filter is not an optimisation: it is the rule's only enforcement
point.

**The spec case that pins this side of the rule, and the only one that can exist.** It asserts the
*absence* of a behaviour, which is all the resolver's side can be:

```lua
T("the resolver makes no exception for any candidate, including the caster")
-- candidates = { one sitting on the ray's origin, one further along }
-- radius == 0 -> the one along the ray, whoever is standing on the origin
-- and alone, the one on the origin IS selected: no hidden filter lives here
```

It is a test of "nothing odd happens", and it is written down as such rather than left as a feeling.
**If somebody ever wants defence in depth — the resolver excluding the caster too — that is the moment
to add a `caster` parameter to the signature**, and this case is the one that will fail and say why.

### D5. Which effects follow the resolved target

For an ability with `targeting = "raycast"`:

| effect kind | goes to |
|---|---|
| damage, dot, debuff | the **resolved target** |
| heal, buff, dash | **the caster**, always |

The split is by effect kind, not by ability: a raycast ability that heals heals its caster, because
there is no such thing as healing somebody at range by looking at them.

**Edge case, decided, and extended to a mirror rule.** Both directions of the contradiction are
errors at load, so the catalog is coherent whichever way a definition is written.

```lua
-- self means there is no resolved target that is not the caster, so an offensive effect in a self
-- ability contradicts D5 rather than describing it.
if targeting == "self" and any effect.kind in { damage, dot, debuff } -> error

-- and the mirror: a raycast whose effects all land on the caster fires a ray that does nothing on
-- contact. The ray is decorative.
if targeting == "raycast" and no effect.kind in { damage, dot, debuff } -> error
```

The messages name the specific kind, because "invalid definition" sends the reader back to the whole
file:

```
self-targeting ability with offensive effect 'dot': either a typo or a mechanic that needs its own name
raycast-targeting ability with no offensive effect: the ray is decorative and the effects would go to the caster anyway
```

The argument is the same in both directions, and it is the same argument as `buildCatalog` returning
`nil` rather than a half-built catalog: **the validator is where mistakes belong, and a mechanic that
needs to exist deserves its own name.**

### D6. A miss is not a refusal

A raycast that hits nothing produces **mana spent, cooldown running, and zero events**. The
`isAlive(nil)` guard in the effect system already produces exactly that, so nothing new is needed —
but it is written down because "a shot is a shot" is a design decision, and phase 5's lesson is that
a decision nobody wrote is a decision that gets re-decided by whoever touches it next.

**A miss logs nothing.** Logging it would put a line in the Output for every shot fired. Only invalid
*requests* log: a refused intent, an empty slot, a refusal from `canActivate`. That distinction —
invalid request versus legitimate miss — is the whole reason the logs are useful.

### The hybrid case: a miss on an ability that also heals

D5 says heal, buff and dash always go to the caster. D6 says a miss produces zero events. Combined, a
raycast ability carrying `[damage, heal]` that hits nothing produces:

- **damage:** no resolved target, so **no damage event**;
- **heal:** it goes to the caster unconditionally, so **the heal still happens**.

**That is the decision, not a bug.** A miss in a hybrid ability still heals its caster. The
alternative — a heal contingent on the shot landing — would require a hit/miss signal to travel from
the resolver up into the effect system, which is exactly the coupling the seam exists to prevent: the
effect system receives a target and does not know who chose it, and teaching it about misses for the
sake of one combination would put the outcome of detection in three files instead of one.

Whoever defines the first hybrid ability should read this paragraph rather than discover it in a
playtest. It is deliberately not a spec case for `TargetResolver`: a miss is not a resolver concern,
and the resolver has no opinion about it — the behaviour lives in the pre-split, and the pre-split's
proof is the engine run.

### D7. The enum is validated against its owner, injected rather than copied

`AbilityDefinition` validates `targeting` against the list `TargetResolver` declares, passed in at
`init()` — the same shape as `stack` being validated against `EffectSystem.STACKING`. A copy of the
list in the validator is a copy that drifts. `targeting = "raycst"` is an **error at load**, not a
silent fallback to self.

The injection becomes the third: `AbilityDefinition.init(Config, catalog, EffectSystem, TargetResolver)`.
**Every spec that calls `init()` with fewer arguments is updated with it** — same precedent as
"without EffectSystem injected, stack goes unchecked": a validator that cannot see the vocabulary
cannot check it, and a check that silently does not run is worse than no check.

### D8. `range` is validated now, because it finally does something

Debt from phase 1: `range = -50` and `range = "far"` both pass the validator today. Until this phase
`range` was decorative — it appeared in the definitions and nothing read it. Now it decides how far a
shot reaches, so it becomes load-bearing and the validator owes it a rule: **a number ≥ 0 when
present, with a ceiling of `maxRange = 500` in `EFFECT_LIMITS` alongside the others** — a concrete
number, because a placeholder is a debt rather than a rule.

`AbilityDefinitionSpec` grows its cases with them.

## The seam, made explicit

```
TargetResolver (pure)     candidates + origin + direction + range + radius + impactPoint -> a list
TargetAdapter (engine)    DETECTION: the real raycast, and Characters into units
EffectSystem (unchanged)  receives a target that is already resolved and does not know who chose it
```

**The seam splits into detection and selection**, and that split is the reason the resolver can be
tested with tables:

- **detection** is the engine's, and it is the only part that needs a world: `workspace:Raycast`,
  the parts it touches, and those parts' Characters turned into units;
- **selection** is pure, and it is the whole of the rules: what is in front, what is within range,
  which is nearest, and who is inside the sphere. It never asks where a wall is, because a candidate
  that reached it has already been through the raycast.

A firing is a single event carrying several effects, so **the Bootstrap pre-splits them**, and the
shape of the split matters:

```lua
-- SHAPE, NOT SIGNATURE. The real call is
--     effects:applyEffect(effect, firing.id, context)
-- with context = { source = caster, target = target, direction = ... }.
-- The point of the block is the nesting, and the nesting is real.
-- direction comes from EffectAdapter.directionOf(casterCharacter) and goes into every context;
-- only dash reads it, but the context is uniform. Without it a dash event carries direction = nil
-- and the adapter no-ops, which is a silent shortening of a dash rather than an error.
for _, target in ipairs(resolved) do
    for _, effect in ipairs(firing.effects) do
        if TargetResolver.isOffensive(effect.kind) then
            effects:applyEffect(effect, firing.id, { source = caster, target = target, direction = direction })
        end
    end
end
for _, effect in ipairs(firing.effects) do
    if not TargetResolver.isOffensive(effect.kind) then
        effects:applyEffect(effect, firing.id, { source = caster, target = caster, direction = direction })  -- ONCE
    end
end
```

**For `targeting == "self"`, `resolved = { caster}` and the same loop runs.** The resolver is not
called — there is nothing to resolve — but the shape of the data does not change, so the pre-split
above never needs to know which targeting the ability had. One shape, one loop, and no branch on
targeting in the heartbeat. The alternative, branching in the Bootstrap, would put a copy of the
targeting rules in the file that is supposed to know nothing about them.

**There is exactly one branch, and it lives in the resolution step.** "No branch on targeting in the
heartbeat" was too strong a sentence: the decision to call the resolver or to use `{ caster }` has to
be taken somewhere, and that somewhere is one line, per firing, reading
`ability:getDefinition().targeting`. **The pre-split loops below never see it** — they receive a list
and do not know where it came from.

And that is safe because of the validator, which is the connection worth naming: **the offensive
branch can never fire for a `self` ability, because the mirror rules of D5 refused that combination at
load.** A `self` ability carries no offensive effect, so running the same loop over `{ caster }`
produces only the non-offensive events it was always going to produce. **The catalog's coherence is
what makes the single loop shape safe** — remove the load-time rule and this shape stops being
correct, silently.

**The non-offensive loop is outside the target loop on purpose.** A raycast ability that buffs
itself while hitting three enemies produces **one** buff event, not three. The nested version would be
a buff stacked by the number of people standing in front of you, which is a bug that looks like a
feature until somebody reads the numbers.

`EffectSystem` stays unchanged, which the phase asked for; if a second reason to split appears in
phase 7, this is the place to promote it to the effect system knowing about both targets.

**The aimed-kinds list is declared once**, in `TargetResolver.OFFENSIVE_KINDS`, and it is read
through one function:

```lua
TargetResolver.OFFENSIVE_KINDS = { "damage", "dot", "debuff" }   -- the list
function TargetResolver.isOffensive(kind) -> boolean             -- the only way in
```

**Three readers — the validator, the pre-split above, and the resolver's own selection — all call
`isOffensive`, and none of them walks the list.** The list stays reachable as a field and the spec
asserts its contents, but a reader that iterates it is writing its own membership test: that is how a
fourth copy of a rule gets written by somebody who did not know the function existed. Same treatment
D7 gives the enum, for the same reason.

`TargetResolver` is testable in a terminal with tables, which is why the decision about what counts
as a candidate lives there and not in the raycast code.

## Out of scope, declared

- **teams and friendly-fire** — no notion of who is on whose side exists anywhere in the kit yet;
- **camera aiming** — the direction comes from the character, not from where the player is looking;
- **`nearest`** — see D3;
- **NPCs as targets** — they arrive for free if the adapter describes any `Character` with a
  `Humanoid`, which is how `describe` is written, but it is untested and therefore declared rather
  than claimed.

## File structure

```
src/shared/TargetResolver.luau        pure: the enum, the candidate rule, the pick
src/server/TargetAdapter.luau         thin: the raycast, and Characters into units
src/shared/AbilityDefinition.luau     + the targeting field, + its validation
src/shared/Config.luau                + the targeting limits
src/shared/abilities/Fireball.luau    targeting = "raycast"
src/shared/abilities/Poison.luau      targeting = "raycast"   (see the note below)
src/shared/abilities/Heal.luau        targeting = "self"
src/shared/abilities/Dash.luau        targeting = "self"
src/server/Bootstrap.server.luau      the heartbeat picks the target; targeting refusals log
tests/TargetResolverSpec.luau         the pure rules, in the terminal
```

**One definition the review did not name: `Poison`.** It is a DoT, so it is offensive, so it is
`"raycast"` — the same argument as Fireball. Flagged because it is a decision I am making rather
than one I was given.

## How this phase closes

Not with a suite. With **an observed run**, as phase 5 was:

- Fireball damaging **another character at distance** — not its caster;
- a **miss** spending mana with no effect and **no line in the Output**;
- a **targeting refusal** visible in the Output.

**The harness for the first one, because a solo playtest cannot observe it.** "Fireball damages
another character" needs a second character, and the kit has no second player. The procedure is the
one phase 4b used for its speed checks:

```
1. build a disposable Model in Workspace with a Humanoid and a HumanoidRootPart, anchored,
   positioned in front of the caster and inside the ability's range;
2. let **the adapter's `describe()` — the one the bootstrap already calls** — see it: no change to
   the kit, it is a Character with a Humanoid, which is exactly what the adapter accepts;
3. activate Fireball and read the dummy's Humanoid.Health before and after;
4. assert the CASTER's health is unchanged, which is the half that proves the fix rather than the
   symptom.
```

Written as procedure rather than as an aspiration: without the dummy the closing criterion is not
executable, and a criterion that cannot be executed is not a criterion.

A phase that ends with a green suite and a silent engine is phase 4b again.

The paragraph this phase opens with is worth keeping, because it is the answer to what phase 5
taught: *"the alternative — inventing the rule at the moment it is needed, inside whatever function
needs it — is how a kit ends up with two half-rules that disagree."*

## Process carried into this phase

1. **Diffs and hashes from day one**, not retrofitted. Phase 5 spent four rounds learning that a
   document whose prose and paste can disagree will disagree.
2. **Test counts come explained.** Every suite's count in the document says what case was added and
   why, because an unexplained jump reads as a hole in the process.
3. **`PHASE_5.md` gets consolidated** into a state README when phase 6 closes — it has accumulated
   duplicated sections and "what this round changed" blocks referencing rounds that no longer exist
   as rounds.
