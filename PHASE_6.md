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
  run once. The caster is inside the sphere if the impact point is close enough, because geometry
  does not know about teams — declared here rather than discovered in a playtest.

Both are stated here rather than left implicit because the first ability that needs an AoE would
otherwise invent the rule on its own, and this project has seen how that ends.

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

### D7. The enum is validated against its owner, injected rather than copied

`AbilityDefinition` validates `targeting` against the list `TargetResolver` declares, passed in at
`init()` — the same shape as `stack` being validated against `EffectSystem.STACKING`. A copy of the
list in the validator is a copy that drifts. `targeting = "raycst"` is an **error at load**, not a
silent fallback to self.

## The seam, made explicit

```
TargetResolver (pure)     receives candidates + origin + direction + range + radius -> a list
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

A firing is a single event carrying several effects, so **the Bootstrap pre-splits them** — offensive
effects are applied to the resolved target and the rest to the caster, one `applyEffect` call each.
That keeps `EffectSystem` unchanged, which the phase asked for; if a second reason to split appears in
phase 7, this is the place to promote it to the effect system knowing about both targets.

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
