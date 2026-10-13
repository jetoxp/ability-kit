# ability-kit

A data-driven ability framework for Roblox, built so that **the logic that decides is pure Luau you can
run in a terminal** and the contact with the engine is confined to two thin files. Abilities are data,
not code: there is no `if id == "FIREBALL"` anywhere in the kit, and the validator refuses a definition
that contradicts itself at load rather than at runtime.

Most ability frameworks put the decision and the engine call in the same function, which means the only
way to test a cooldown is to open Studio. Here the split is the point: 208 test cases run in a few
seconds without Roblox, and the two adapters that do touch the engine are small enough to audit by eye.

## What it does

Straight from the code, not from a roadmap:

- **Abilities declared as data** — id, cost, cooldown, cast time, targeting, effects. Validated at load,
  with warnings that name the field you probably meant (`raduis` -> `radius`).
- **State machine per ability** — `idle`, `casting`, `active` (an instant, not a duration), `cooldown`.
  Effects fire exactly once per activation.
- **Per-player management** — a loadout on numbered slots, per-slot cooldowns, and a global cooldown
  between abilities. Keyed by **slot**, not by ability id, so the same ability can sit on two slots.
- **Resource pools with regeneration** — mana and stamina out of the box, declared in `Config`.
- **Instant and timed effects** — damage, dot, heal, buff, debuff, dash. Timed effects carry a stacking
  policy (`refresh`, `stack`, `ignore`) declared per effect.
- **Server-side targeting** — `self` and `raycast`, with the caster excluded from direct targets, dead
  candidates discarded, and a radius that catches everybody near the impact point.
- **State replication at 10 Hz** — a snapshot to the client, shaped by one source of truth
  (`Config.STATE_FIELDS`).
- **Server-authoritative composition** — the client sends one thing and only one thing:
  `{ action = "activate", slot = N }`.

## Architecture

```
                    Client                      Server
                      |                            |
   key 1..4 --> AbilityClient.client                |
                      |                            |
                      +---- Intent (remote) -------> Net.validateIntent
                                                   |
                                              Bootstrap  (composition root,
                                                   |       one session per player)
                      +----------------------------+----------------------------+
                      |              |             |             |              |
              AbilityManager  ResourceManager  EffectSystem  TargetResolver  EffectAdapter
                      |              |             |             |          TargetAdapter
                      +--------------+-------------+             |              |
                                     |                          |              |
                              RunService.Heartbeat -------------+              |
                                     |                                         |
                                     +------- events ------------------------->+
                                                                               |
                      State (remote) <-----------------------------------------+
                             |
                       ClientState  (the last snapshot; nothing draws it yet)
```

One line each, including what it does **not** do:

| Module | Does | Does not |
|---|---|---|
| `Config` | Every tunable, and the shape of the replicated state | Read from Roblox |
| `AbilityDefinition` | Validates definitions and builds the catalog | Know what an effect does |
| `Ability` | The state machine for one ability | Apply effects, or know about other abilities |
| `AbilityManager` | Loadout, per-slot cooldowns, global cooldown, the tick | Know what mana is, or what an effect is |
| `ResourceManager` | Pools, spending, regeneration | Decide whether something is affordable — that is a refusal, and refusals belong to the ability |
| `EffectSystem` | Emits effect events; instant ones fire now, timed ones register | Apply anything, or touch a Humanoid |
| `TargetResolver` | Chooses who is hit, from candidates and an impact point | Ask where a wall is, or touch the world |
| `Net` | The wire, and the client-facing trust boundary | Trust the client |
| `EffectAdapter` | Humanoid damage/heal, WalkSpeed, dash displacement | Decide anything |
| `TargetAdapter` | The raycast, the impact point, Characters into units | Choose the target |
| `Bootstrap` | Composition root: builds sessions, answers intents, runs one heartbeat | Contain gameplay rules |
| `AbilityClient` / `ClientState` | Sends an intent on a keypress; keeps the last snapshot | Check a cooldown, know a cost, or draw anything |

## The seam

**The property the kit is built around: everything that decides is pure, and everything that touches
the engine is thin.** Two consequences, and the second is the interesting one.

The pure modules have no `require` of each other — config and catalog are injected at `init()` — so each
one can be tested alone with plain tables. 208 cases cover them, including the ones written for bugs
that were found in Studio and then pinned in the suite so they cannot come back.

**And the bugs that matter live in the seam.** Not in the pure logic, which is covered, and not in the
prose that announced the design: in the place where the two layers meet, which no unit test crosses by
construction because the test speaks plain tables and the boundary is the thing that might fail to.

| Where it lived | What it looked like |
|---|---|
| Between definition and catalog | A container replaced by name, taking a neighbouring loop with it; the game ran, spent mana, and never fired again |
| Between module and module | A function declared with a dot called with a colon, so the adapter arrived where a character was expected |
| Between pure layer and engine | The adapter was supposed to convert a `Vector3` into `{ x, y, z }`; no adapter did, and every candidate was silently rejected |
| Between design and engine | A shot that hit nothing selected its own caster as the only eligible target and dealt it 44 damage |

## How to run it

No external dependencies, no packages, no Studio required for the test suite.

```bash
luau tests/run.luau          # 208 cases across 7 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

`luau`, `selene` and `stylua` are the only tools needed for that, and they are all optional if you only
want to read the code.

**To run it in Studio**, with [Rojo](https://rojo.space) 7.x:

1. `rojo serve` in the repository root.
2. Connect from the Rojo plugin in a place you own. `default.project.json` maps `src/shared` to
   `ReplicatedStorage.AbilityKit`, `src/server` to `ServerScriptService.AbilityServer`, and `src/client`
   to `StarterPlayer.StarterPlayerScripts.AbilityClient`.
3. Press Play. The Output should show one line:

```
[ability-kit] bootstrap up: 4 abilities in the catalog, 4 equipped by default
```

4. Press `1` to `4` to activate the loadout. The snapshot arrives at the client and `ClientState.latest`
   holds it — nothing draws it yet, and reading that table is how you inspect the kit from a playtest.

## Verified in engine

The list below is observed behaviour from a live playtest, not intended behaviour. Each line is a run
whose output is quoted in `PHASE_5.md` and `PHASE_6.md`:

- **A single-target ability damages another character at distance**, and the caster's own health does not
  change — the second half is the one that proves the fix rather than the symptom.
- **A miss spends mana, produces zero events, and writes zero lines to the Output.** A shot that hits
  nothing is a shot; only invalid requests are logged.
- **A miss leaves the caster at full health**, which is the case that caught the self-damage above.
- **An activation spends the cost at the activation**, not when the effect fires: a cast interrupted
  halfway has been paid for, and that is a decision, not an oversight.
- **A second activation is refused by the cooldown without charging again.**
- **Death restores the pools and clears the cooldowns**, and drops the effects attached to the character
  that died.

## Known limitations

Declared rather than discovered:

- **There is no UI.** The client sends intents and keeps the last snapshot; nothing draws it. The kit is
  complete without one, and a HUD is a small file that reads `ClientState`.
- **Targeting does not accept client-supplied references.** Only the server's raycast from the caster's
  facing direction. The alternative — the client names a target and the server validates it — is a
  deliberate non-goal for now, because the validation is the whole difficulty.
- **NPCs work as targets by construction and are not tested.** Any `Model` with a `Humanoid` is described
  by the adapter like any other character, but no test or playtest has exercised it.
- **A dash is a single displacement, not motion over time.** A smooth dash needs a `LinearVelocity` for
  its duration, which belongs to a movement phase.
- **Only `speed` is translated for buffs and debuffs.** Other stats are the game's business; the effect
  system carries them, the adapter ignores them.
- **A miss in a hybrid ability still heals its caster.** An ability carrying both `damage` and `heal`
  that hits nothing produces no damage event and a heal on the caster. That follows from "each effect
  decides its target by kind", and making the heal contingent on the hit would drag a hit/miss signal
  into the effect system.
- **The two adapters have no test suite and cannot have one.** That is the price of the other seven
  modules having one.

## Out of scope

What the kit does not do, and why, so that a reader can tell a decision from an omission:

- **Teams and friendly-fire** — the kit has no notion of who is on whose side, so every candidate is a
  candidate.
- **Camera aiming** — the direction comes from the character, never from where the player is looking.
- **`nearest`** — the targeting enum has `self` and `raycast` only. "Nearest" is ambiguous in three ways
  that matter (within what range, in the facing cone or everywhere, and whether walls count) and no
  definition needs it yet.
- **Persistence between sessions** — pools are recreated, not saved. `PlayerRemoving` and `BindToClose`
  release state; they do not store it.

## Lessons

The five that cost the most, each with the bug that produced it. They are here rather than only in the
phase notes because they are the transferable part.

**An early return with no log is indistinguishable from nothing having happened.** A `PlayerAdded`
callback had lost the loop that builds a session for players already in the game, and the intent handler
returned in silence for every request. Three playtests reported "nothing happens" before a log line said
which of the three silent paths it was. Every reachable refusal now names itself — and a *miss* still
logs nothing, because a line per shot is a log nobody reads.

**A promise about the seam that nobody executes is indistinguishable from a promise nobody wrote.** The
documentation had said "the adapter converts" since the effects layer was written. The adapter handed the
pure resolver a `Vector3` where it expected `{ x, y, z }`, the resolver rejected every candidate it was
given, and the shot resolved to nobody — with a green suite of 208 cases, because the suite is written
against the contract and therefore cannot catch the boundary failing to honour it.

**A Heartbeat connection that errors is disconnected, and a disconnected Heartbeat is a game that spends
mana and never fires again.** One malformed argument threw inside the tick; Roblox dropped the
connection; the intent handler, which is a different connection, kept charging the player for shots that
could never fire. The tick is shared infrastructure — one player must not be able to switch off the
clock — so the per-session body is wrapped and the error is logged loudly rather than swallowed.

**Two callers, one function: anything that must happen to every player belongs in the function both
callers call.** Respawn wiring was added to the `PlayerAdded` callback, which covered everyone who
joined and silently missed everyone already in the game — which, in Studio, is everyone.

**A test can agree with the bug it was written to catch, and then confirm it instead of finding it.**
The definition validator was supposed to refuse two abilities sharing an id. It walked the catalog with
the table key as the identity, and a table key is unique by construction, so the collision check was
dead code that could never fire. Its test built the input the same way — indexing by the same key — so
it passed for exactly the same wrong reason, and stayed green. This is the most uncomfortable of the
five, because it is the one that answers the question a reviewer is actually asking: *why did the tests
not catch it?* **Because the test and the code shared one reading of the problem.** Writing the test
from the same head that wrote the function does not verify the function; it verifies the
misunderstanding, and files it as evidence.

And a smaller one, in the same family. **A gate that reports a count without a name is a promise closed
without saying what it promised.** The quality gate reported `0 errors, 1 warning` for several rounds,
and the warning was a number with no noun: naming it as `unused_variable: hit` was the fix, and the
number alone had been hiding it.

## Files

```
src/shared/     pure modules, testable in a terminal: Config, AbilityDefinition,
                Ability, AbilityManager, ResourceManager, EffectSystem, TargetResolver,
                Net, the default loadout, and the four sample abilities
src/server/     the only files that touch the engine: Bootstrap (composition root),
                EffectAdapter, TargetAdapter
src/client/     a keypress becomes an intent, and ClientState holds the last snapshot
tests/          seven Luau suites, a shared test kit, and the runner (only the seven
                Spec files are suites); no Studio needed
PHASE_*.md      the working notes of each phase, in order, including the bugs and the
                corrections they forced. The two most recent are the ones worth reading
                for how the seam behaves: PHASE_5.md (the wire and the boot) and
                PHASE_6.md (targeting, and four bugs the engine found that the suite
                could not)
```

## License

MIT — see [`LICENSE`](LICENSE).
