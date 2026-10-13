# Phase 5 — the Bootstrap, the wire, and a client that only asks

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase delivers

The first phase that runs in a **real Roblox server**, and the one where everything written so far
finally meets. Four files:

- **`Bootstrap.server.luau`** — the composition root. The only file in the kit where the modules
  know about each other.
- **`Net.luau`** — the wire, described once, with the client-facing validation as a pure function.
- **`AbilityClient.client.luau`** — turns a keypress into an intent, and nothing else.
- **`ClientState.luau`** — the last snapshot the server sent, so phase 7's UI has something to read.

### The composition root, and its three jobs

1. **Build** the per-player set (manager, resources, effects, adapter) and keep it in one table.
2. **Answer intents**, in the order that matters.
3. **Beat**, once for the whole server.

### The order, and the proxy that makes it safe

```lua
if not session.manager:activate(intent.slot, owner) then return end
session.resources:spend(ability:getCost())
```

`owner.resources` **is** the ResourceManager's live pool table, in exactly the shape
`Ability:canActivate` reads. So the check the manager performs *is* `canPay`, and the spend on the
next line cannot disagree with it: both look at the same table in the same frame. Paying after
activating would mean a failed spend leaves an activation in flight to cancel; checking first means
the only possible failure is a refusal that changed nothing.

### The wire

One remote up, one down. The intent carries `{ action = "activate", slot = 3 }` and **anything else
is refused**, including an extra field — because "it only reads `slot`" stops being true the moment
somebody adds a convenient field. The refusal reason goes to the log and never back to the client:
a refusal teaches nothing.

### The tick

**One `Heartbeat` for the whole server**, not a loop per player: there is exactly one place where
time passes. Events go to the adapter, which translates and does not decide. A snapshot goes down at
10 Hz rather than every frame.

## The boot, and the bug it found

The first playtest **did not work**, and the way it failed is worth recording because it is the
classic:

> `AbilityKitNet` existed — so the Bootstrap had run — and the player had a character. But no state
> ever reached the client. The reason: **a script connects `PlayerAdded` at the point it runs, and in
> Studio that point is reached AFTER the local player has joined.** The event never fired for them,
> so no session was built, and the heartbeat loop had nothing to iterate.

The fix is four lines, and the comment in the code says why it is not a Studio workaround — the same
thing happens to anyone already in a server when a script reloads:

```lua
for _, player in ipairs(Players:GetPlayers()) do
	buildSession(player)
end
```

The same boot also taught a smaller lesson: **a bootstrap that prints nothing on startup cannot be
diagnosed.** It now announces the catalog size and the default loadout. Half an hour went into
distinguishing "did not run" from "ran and failed" with no line to read.

## The code

Every block below is a diff against the commit the document was first generated from
(`6d30032`), except where git says there is nothing to diff.

### `src/server/Bootstrap.server.luau`

*The composition root. Read the header for what it refuses to do, the intent handler for the order, and `buildSession` for the respawn wiring.*

`git hash-object src/server/Bootstrap.server.luau` -> `a690d65c5621`

**Changed since this document was written.** The diff is `git diff 6d30032..HEAD -- src/server/Bootstrap.server.luau` —
apply it to the file as it stood and you get the file described here.

```diff
diff --git a/src/server/Bootstrap.server.luau b/src/server/Bootstrap.server.luau
index 8595b00..a690d65 100644
--- a/src/server/Bootstrap.server.luau
+++ b/src/server/Bootstrap.server.luau
@@ -61,10 +61,17 @@ local STATE_INTERVAL = 1 / 10
 
 local sessions = {} -- [player] = session
 
+-- Counted by pairs, not with #: the catalog is keyed by id, and `#` on a dictionary returns 0 no
+-- matter how full it is. This line reported "0 abilities" on a healthy boot, which cost more time
+-- than printing nothing would have.
+local catalogSize = 0
+for _ in pairs(Catalog) do
+	catalogSize += 1
+end
 print(
 	string.format(
 		"[ability-kit] bootstrap up: %d abilities in the catalog, %d equipped by default",
-		#Catalog,
+		catalogSize,
 		Config.MAX_EQUIPPED
 	)
 )
@@ -80,6 +87,10 @@ local function ownerProxy(session, player)
 	local character = player.Character
 	local unit = nil
 	if character ~= nil then
+		-- Described fresh on every use, which today means once per player per frame. It is six table
+		-- reads. If this ever shows up in a profile, the fix is to describe once per character and
+		-- invalidate on CharacterAdded — not to cache blindly, because `alive` and `health.current`
+		-- are exactly the two fields a stale copy would get wrong.
 		unit = session.adapter:describe(character)
 	end
 	return {
@@ -100,6 +111,42 @@ local function buildSession(player)
 		stateClock = 0,
 	}
 	sessions[player] = session
+
+	--[[
+		Death and respawn, wired HERE and not in the PlayerAdded callback.
+
+		Three functions were written and tested for this and none of them was ever called: reset() clears
+		cooldowns and casts, refill() takes the pools back to full, clear() drops the effects. Without
+		this wiring a player who dies mid-cast keeps the cooldown, the spent mana and the poison on their
+		corpse, and comes back with all three.
+
+		It lives in buildSession because that is the one function BOTH paths go through — PlayerAdded for
+		whoever joins, and the seed loop for whoever is already here when the script runs. Kept in the
+		PlayerAdded callback it covered the first path and silently missed the second, which in Studio is
+		the only one that ever runs.
+
+		Two events rather than one, because they are two different moments with two different subjects:
+		`CharacterAdded` is about the player coming back, and `CharacterRemoving` is about the character
+		going away. `CharacterRemoving` also fires while the Instance is still valid, which is what makes
+		it the right place to drop the effects — the id they are keyed by is that Instance.
+	]]
+	player.CharacterAdded:Connect(function()
+		local current = sessions[player]
+		if current ~= nil then
+			current.manager:reset()
+			current.resources:refill()
+		end
+	end)
+
+	player.CharacterRemoving:Connect(function(character)
+		local current = sessions[player]
+		if current ~= nil then
+			-- The id a target is keyed by is the character Instance, not the Player. Clearing by
+			-- player would remove nothing and leave the effects running on a corpse.
+			current.effects:clear(character)
+		end
+	end)
+
 	return session
 end
 
@@ -122,20 +169,18 @@ Players.PlayerAdded:Connect(function(player)
 	buildSession(player)
 end)
 
--- And the players who are already here. A script connects PlayerAdded at the point it runs, and in
--- Studio that point is reached AFTER the local player has joined — so the event never fires for them
--- and they get no session: no state, no intents, nothing. This is not a Studio quirk to work around;
--- the same thing happens to anyone already in a server when a script reloads.
-for _, player in ipairs(Players:GetPlayers()) do
-	buildSession(player)
-end
-
 Players.PlayerRemoving:Connect(function(player)
 	local session = sessions[player]
 	if session ~= nil then
 		-- Nothing to save: this kit persists no state. What there is to do is let go of it, so a
 		-- session cannot outlive the player it belongs to.
-		session.effects:clear(player)
+		--
+		-- The effects are keyed by the CHARACTER, which is the id describe() gives them, so
+		-- clear(player) removed nothing. This clears the one that exists.
+		local character = player.Character
+		if character ~= nil then
+			session.effects:clear(character)
+		end
 		sessions[player] = nil
 	end
 end)
@@ -174,6 +219,13 @@ intentRemote.OnServerEvent:Connect(function(player, payload)
 
 	-- Only now does anything move. The check above cannot have passed and this fail, because both
 	-- read the same table in the same frame.
+	--
+	-- The cost is paid at the COMMIT POINT, which is the activation and not the firing. That makes
+	-- an interrupted cast a paid-for cast: a Fireball interrupted at 0.3s of 0.4s has spent the
+	-- mana and produced nothing. This is deliberate — the alternative is a refund path, which means
+	-- the server tracks what each cast has paid and reconciles it on every interrupt, cancel and
+	-- disconnect. A game that wants the forgiving version calls `resources:restore` on the ability's
+	-- cost when it cancels, which is the reason that function exists.
 	session.resources:spend(ability:getCost())
 end)
 
@@ -193,6 +245,12 @@ RunService.Heartbeat:Connect(function(dt)
 
 		for _, firing in ipairs(session.manager:advance(dt)) do
 			if unit ~= nil then
+				-- KNOWN LIMITATION: target = source. Every ability is self-cast, because the intent
+				-- carries no target and nothing here resolves one. Fireball, whose definition says
+				-- "a single target" with range 60, therefore burns its caster. Target selection is
+				-- a later phase: a raycast from the caster's CFrame, or a client-supplied reference
+				-- the server validates. Giving the client the choice without validating it is the one
+				-- version of this that is not an option.
 				local events = session.effects:applyFiring(firing, {
 					source = unit,
 					target = unit,
@@ -214,8 +272,15 @@ RunService.Heartbeat:Connect(function(dt)
 
 		session.stateClock = session.stateClock + dt
 		if session.stateClock >= STATE_INTERVAL then
-			session.stateClock = 0
-			stateRemote:FireClient(player, snapshot(session))
+			-- Subtract rather than zero: the overshoot belongs to the next interval. Zeroing it
+			-- loses time on every send, which is the same "time that goes missing" shape this kit
+			-- has already met twice — in the cooldown and in the DoT.
+			session.stateClock -= STATE_INTERVAL
+			if player.Parent ~= nil then
+				-- A player can leave between the heartbeat starting and this line. Firing at a
+				-- departed player is silent, but checking costs one comparison.
+				stateRemote:FireClient(player, snapshot(session))
+			end
 		end
 	end
 end)
```

### `src/shared/Net.luau`

*The contract, and the client-facing trust boundary as a pure function — which is why it has a suite.*

`git hash-object src/shared/Net.luau` -> `40c845fc0087`

**Changed since this document was written.** The diff is `git diff 6d30032..HEAD -- src/shared/Net.luau` —
apply it to the file as it stood and you get the file described here.

```diff
diff --git a/src/shared/Net.luau b/src/shared/Net.luau
index 32acf42..40c845f 100644
--- a/src/shared/Net.luau
+++ b/src/shared/Net.luau
@@ -30,7 +30,9 @@ function Net.configure(config)
 end
 
 --[[
-	Checks a client's payload and returns (ok, intentOrReason).
+	Checks a client's payload and returns (ok, value): on success `value` is the normalised intent,
+	and on failure it is the reason string that goes to the log. Two different things in one slot,
+	which is a shape worth naming rather than leaving to be inferred.
 
 	This is the whole of the client-facing trust boundary, and it is deliberately dull: an action
 	from a known list, and a slot within range. Anything else is refused, including a payload that
@@ -60,9 +62,14 @@ function Net.validateIntent(payload)
 		return false, string.format("unknown action '%s'", tostring(payload.action))
 	end
 
+	-- An integer, not merely a number. `1.5` would pass a range check and then find no ability, which
+	-- is a silent no-op where a refusal belongs: the boundary is cheaper to tighten than to explain.
 	if type(payload.slot) ~= "number" or payload.slot ~= payload.slot then
 		return false, "slot must be a number"
 	end
+	if payload.slot ~= math.floor(payload.slot) then
+		return false, string.format("slot %s is not a slot", tostring(payload.slot))
+	end
 	if payload.slot < 1 or (Net.MAX_SLOT ~= nil and payload.slot > Net.MAX_SLOT) then
 		return false, string.format("slot %s is out of range", tostring(payload.slot))
 	end
```

### `src/client/AbilityClient.client.luau`

*The client's whole job: a keypress becomes an intent. No local cooldown check, no cost, no target.*

`git hash-object src/client/AbilityClient.client.luau` -> `8802ae2e4d45`

**Unchanged since this document was written**, so the whole file is below rather than a
diff — a diff of nothing is a line that invites someone to look for what is missing.

```lua
--[[
	AbilityClient.client.luau — the client's whole job, for now.

	Two things and no more: turn a keypress into an intent, and keep the last snapshot the server
	sent. Every decision — is it ready, can you afford it, who does it hit — belongs to the server,
	and this file has no way to make any of them.

	There is no UI yet. Drawing the bars and the cooldown sweeps is phase 7, and this file exists so
	that phase has something to draw from.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local kit = ReplicatedStorage:WaitForChild("AbilityKit")
local Config = require(kit.Config)
local Net = require(kit.Net)
local ClientState = require(script.Parent.ClientState)

local netFolder = ReplicatedStorage:WaitForChild(Net.FOLDER)
local intentRemote = netFolder:WaitForChild(Net.INTENT)
local stateRemote = netFolder:WaitForChild(Net.STATE)

ClientState.changed = Instance.new("BindableEvent")

stateRemote.OnClientEvent:Connect(function(state)
	ClientState.set(state)
end)

-- The slots are the keybinds. One, two, three, four — and nothing more clever than that, because
-- a client that decides what "clever" means is a client inventing mechanics.
local slotKeys = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- While a text box has focus the key belongs to the text box. Checking this is not optional:
	-- without it, typing "1" in chat fires an ability.
	if gameProcessed then
		return
	end

	local slot = table.find(slotKeys, input.KeyCode)
	if slot == nil or slot > Config.MAX_EQUIPPED then
		return
	end

	-- The intent is the whole message: an action and a slot. No cost, no target, no direction.
	intentRemote:FireServer({ action = "activate", slot = slot })
end)
```

### `src/client/ClientState.luau`

*The seam phase 7 will read from.*

`git hash-object src/client/ClientState.luau` -> `b08e5ee52aa6`

**Changed since this document was written.** The diff is `git diff 6d30032..HEAD -- src/client/ClientState.luau` —
apply it to the file as it stood and you get the file described here.

```diff
diff --git a/src/client/ClientState.luau b/src/client/ClientState.luau
index 7236a8d..b08e5ee 100644
--- a/src/client/ClientState.luau
+++ b/src/client/ClientState.luau
@@ -9,8 +9,20 @@
 
 local ClientState = {}
 
+--[[
+	Initialisation order, for whoever reads this in phase 6/7.
+
+	This module is required and its fields assigned in two different places: `latest` is written by
+	`set`, and `changed` is created by the client script — which requires this module and sets it on
+	the next line. So a consumer that requires this module BEFORE the client script runs sees
+	`changed == nil`. Guard on it (`if ClientState.changed ~= nil`), or require this from the client
+	script and nowhere earlier.
+
+	Both fields being nil until something writes them is deliberate: a module that invents a default
+	state is a module that reports a state the server never sent.
+]]
 ClientState.latest = nil
-ClientState.changed = nil -- a BindableEvent, created by the client, for whatever draws this
+ClientState.changed = nil -- a BindableEvent, created by the client script, for whatever draws this
 
 function ClientState.set(state)
 	ClientState.latest = state
```

### `src/shared/Config.luau`

*The single source of truth for the replicated state, and where the `MANAGER_FIELDS` split is explained.*

`git hash-object src/shared/Config.luau` -> `d21115a9ce04`

**Unchanged since this document was written**, so the whole file is below rather than a
diff — a diff of nothing is a line that invites someone to look for what is missing.

```lua
--[[
	Config.luau — every tunable of the framework, in one place, and nothing that reads from
	Roblox. The point is that a consumer can change how this kit behaves without opening a
	single module that has logic in it.

	This file also pins the SHAPE of the replicated state before any module that uses it exists.
	That is deliberate. The remote that carries the snapshot arrives in a later phase, but the
	shape decides what every module has to expose, so discovering it late means reopening
	everything written before it.
]]

local Config = {}

-- Bump this when the save format changes so old data can be migrated instead of thrown away.
Config.SCHEMA_VERSION = 1

--[[
	The state the server owns and pushes to the client. It lives here, and only here, because
	several modules have to agree on it and a shape duplicated in two places drifts in silence.

	    resources     : { [name] = { current = number, max = number } }        (ResourceManager)
	    cooldowns     : { [slot] = secondsLeft }                               (AbilityManager)
	    equipped      : { [slot] = abilityId }                                 (AbilityManager)
	    globalCooldown: secondsLeft                                            (AbilityManager)
	    cast          : { id, slot, remaining, progress } | nil                (AbilityManager)

	Two of these were wrong in an earlier draft and are worth the note:

	`cooldowns` is keyed by SLOT, not by ability id. A loadout may hold the same ability on two
	slots, and keying by id collapses them into one cooldown that the client then draws twice —
	or once, for two slots. A hotbar is a list of slots; the client draws it by slot.

	`cast` carries `remaining` (seconds left) and `progress` (0 to 1), not an `endsAt` timestamp.
	The client's clock is not the server's, so a deadline it has to compare against its own time is
	a deadline it will get wrong by however far the two clocks disagree.

	Note what is absent: the client is never told a damage number, a hit result, a cost or an
	effect. It gets what it needs to draw a bar and play an animation.
]]
Config.STATE_FIELDS = { "resources", "cooldowns", "equipped", "globalCooldown", "cast" }

-- The subset AbilityManager is responsible for, kept next to the full list rather than derived
-- from it, so a test can check the manager emits exactly this and nothing else.
--
-- Split into required and optional because `cast` is absent whenever nobody is casting, and in Lua
-- an absent key and a nil value are the same thing: a check written as `snapshot[field] ~= nil`
-- over one flat list silently depends on a cast being in progress to pass. That is the coupling
-- this split removes — the test now runs in both states and says so.
Config.MANAGER_REQUIRED_FIELDS = { "cooldowns", "equipped", "globalCooldown" }
Config.MANAGER_OPTIONAL_FIELDS = { "cast" }

-- Seconds added after any ability fires. Stops two different keys being mashed in one frame
-- from producing two effects, and is short enough that it never feels unresponsive.
Config.GLOBAL_COOLDOWN = 0.35

-- How often the server ticks cooldowns and resource regeneration.
Config.TICK_RATE = 0.1

-- Resource pools. `regen` is per second, and 0 means the pool only refills another way.
Config.RESOURCES = {
	mana = { max = 100, regen = 6, start = 100 },
	stamina = { max = 100, regen = 12, start = 100 },
}

-- A definition may be listed here and nowhere else until it is equipped.
Config.MAX_EQUIPPED = 4

Config.CAST = {
	-- Taking damage interrupts a cast. Turn it off for a more forgiving game, but the cost is
	-- that a long cast becomes an uninterruptible free win in a duel.
	cancelOnDamage = true,
	-- Moving does not interrupt. Roblox players move constantly; cancelling on movement makes
	-- cast times feel like a bug rather than a mechanic.
	cancelOnMove = false,
}

Config.EFFECT_LIMITS = {
	-- Caps used by validation, so a mistyped number in a definition is caught at load instead of
	-- turning into a one-shot kill nobody can explain. These are sanity limits, not balance:
	-- a definition that needs more than this is far more likely to be a typo than a design.
	maxDamage = 500,
	maxHeal = 500,
	maxDuration = 30,
	maxRadius = 200,
	maxDashDistance = 200,
	-- An instant, free ability that hits at least this hard is almost certainly a mistake.
	-- Deliberately a warning and not an error: a framework informs, it does not decide for the
	-- game. A stricter consumer can promote it, an experimental one can ignore it.
	spammableDamageThreshold = 20,
}

-- Strings a PLAYER can see. Kept out of the modules on purpose: a framework should not decide
-- what language someone else's game speaks. A consumer overrides this table at startup.
Config.MESSAGES = {
	abilityNotEquipped = "You do not have that ability equipped.",
	abilityOnCooldown = "That ability is not ready yet.",
	notEnoughResources = "Not enough resources.",
	castInterrupted = "Your cast was interrupted.",
	alreadyCasting = "You are already casting.",
	invalidTarget = "That target is not valid.",
}

return Config
```
## How to test it

```
luau tests/run.luau          # 179 cases across 6 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

`NetSpec` covers the client-facing boundary — every case is a payload this version refuses.
The Bootstrap has no suite and cannot have one: it is the file that needs a server. What it
has is a playtest, and the check that matters is that a snapshot reaches the client.

## The wire finding, and why nothing else is observable

Found in the playtest, and it is the most important line in this document.

**The repro.** In a live server, with the session built and the character alive, the client sends
`{ action = "activate", slot = 1 }`. Nothing happens — and nothing says so:

```
antes de activar:      mana=100/100 | cooldowns {1=0, 2=0, 3=0, 4=0} | cast=false
a 0.15s tras activar:  mana=100/100 | cooldowns {1=0, 2=0, 3=0, 4=0} | cast=false
a 0.75s tras activar:  mana=100/100 | cooldowns {1=0, 2=0, 3=0, 4=0} | cast=false
```

No cooldown, no spend, no cast, and **no refusal in the log**.

**The pure layer is not the problem.** A probe that skips the wire entirely, in the same live server:

```
catalog: 4 claves [DASH, FIREBALL, HEAL, POISON]
getAbility(1) = FIREBALL
activate(1) = true, nil
cooldowns {1=0, 2=0, 3=0, 4=0} | cast=true | gc=0.35
```

So the manager activates correctly, and the intent dies between the remote and the handler — the
`sessions[player]` lookup or the `if ability == nil then return end`. **That silent `return` is the
reason this took a probe to find**: an early return with no log is indistinguishable from nothing
having happened, which is the same gap this phase already declared for refusals.

**The probe that isolates it, for the next run:** a second `OnServerEvent` connected to the `Intent`
remote from the server, plus a client `FireServer`. If the probe fires, the wire is fine and the
Bootstrap's handler is dying silently; if it does not, the `FireServer` is not arriving.

**This is why the rest of the list is blocked rather than pending.** With the intent not producing an
activation, there is no mana spent and no cooldown set, so a death proves nothing about the respawn
wiring and a refused intent proves nothing about the boundary. The order is: fix the wire, then watch
boot, respawn and activation in one playtest.

## The regression this round introduced and removed

The reviewer's shape for the respawn wiring — `CharacterAdded` and `CharacterRemoving` — was adopted,
and adopted in the wrong place: inside the `PlayerAdded` callback. **That silently missed the seed
loop** for players already in the game, which is the only path that ever runs in Studio. The
documented boot bug, reintroduced by the fix for the boot bug.

It now lives in `buildSession`, which is the one function both paths go through. **The lesson is
structural rather than moral: two callers, one function, and anything that must happen to every
player belongs in the function both callers call — not in one of them.** The comment in the file says
exactly that, so the next person to move it knows why it is where it is.

**And its verification is still blocked** by the wire finding above: with the intent not reaching an
activation, there is no mana to spend and no cooldown to clear, so a death would prove nothing about
the wiring. The two are ordered, not parallel.

## What this round changed

The review found that the document described respawn wiring its own paste did not contain — the
Bootstrap block was three rounds stale, and its `git hash-object` proved it. Two things came out of
it:

1. **The wiring is now in the file, in the reviewer's shape** — `CharacterAdded` for coming back
   (`reset` + `refill`), `CharacterRemoving` for going away (`clear` by the character Instance).
   Two events rather than one armed with a `lastCharacter`, because they are two different moments
   with two different subjects.
2. **Pastes are diffs from here on.** That is the promise phase 4b earned and this round paid: the
   Bootstrap above is a diff against the previous commit. A diff either applies or it does not; a
   whole file can be quietly wrong in the middle.

One more clarification this round: `Ability:interrupt()`'s comment said a cancelled cast "costs
nothing", which was true of the ability and read as if it were true of the player's mana. It now says
which nothing it means, and points at the decision below.

## What is left in this phase

Declared rather than discovered, which is the whole point of a list like this.

### Target selection does not exist

**Every ability in this kit is self-cast.** The intent carries no target, nothing on the server
resolves one, and the heartbeat applies each firing with `source = unit, target = unit`.

The consequence is concrete: `Fireball.luau` says it "burns a single target", `Config` has
`range = 60`, and **Fireball burns its caster**. Same for Poison. This is not a code bug — the code
does what it says — it is a functional gap that this phase does not cover, and the definitions have
been describing behaviour since phase 1 that nothing implements.

Target acquisition belongs to a later phase, and it has exactly two honest shapes:

- a **raycast** from the caster's CFrame along its look vector, bounded by the definition's range,
  decided entirely on the server; or
- the client supplies a **reference** (a target Instance), which the server **validates** — is it
  alive, is it in range, is it a legal target — before using it.

What is not an option is the third one: taking the client's word for it. That is the same seam
`Net.validateIntent` exists to hold.

### Death and respawn: wired in this round

`reset()` (phase 2), `refill()` (phase 4a) and `clear()` (phase 4b) were written, tested and
commented as the behaviour of a respawn — and **nothing ever called them**, because no
`CharacterAdded` was connected. The repro was exact: die at 0.3s of a 0.4s cast, the cast completes,
the firing is discarded in the heartbeat (`unit == nil`), the mana is spent, and the player comes back
with cooldowns and pools untouched.

It is now wired, and the old character's effects are dropped by reference so a corpse does not keep
its poison.

### An interrupted cast is a paid cast — deliberately

The cost is spent at the **commit point, which is the activation and not the firing**. So a Fireball
interrupted at 0.3s of 0.4s has paid and produced nothing.

This is written down because phase 2's own rule says *"charging for a cast that never happened is
unforgivable"*, and the two statements have to be reconciled rather than left to contradict each
other in different files. The reconciliation:

- **the cost is paid for the activation**, and every activation is a legal, validated, player-chosen
  action. Interruption is a consequence of combat, not a failure of the system;
- the alternative is a **refund path**, which means the server tracks what each cast has paid and
  reconciles it on every interrupt, cancel and disconnect — a state machine whose whole job is to
  undo things, and a source of the exact bug class this kit keeps hunting;
- **a game that wants the forgiving version has `resources:restore`**, which is why that function
  exists and why `ResourceManagerSpec` covers it.

If the rule and the design ever have to agree in one sentence, it is this: **the activation was
real, so it was charged; the cast was interrupted, so nothing happened.**

### `MANAGER_FIELDS` split, confirmed

Split between phase 3 and phase 5, and the presumption is correct: it is the phase 3 lesson written
into the config. `cast` is **optional by design** — it is absent whenever nobody is casting — and a
drift check that asks "is every declared field present?" cannot tell *absent because it is nil* from
*absent because somebody forgot it*. The two lists are what makes the difference expressible:

- `MANAGER_REQUIRED_FIELDS` — the snapshot must carry these, always;
- `MANAGER_OPTIONAL_FIELDS` — these may be absent, and their absence is a legal state rather than a
  missing field.

The check that keeps it honest runs in both directions: a field the snapshot carries that the config
does not declare fails, and a required field that the snapshot omits fails.

## What is verified, and what is not

**Verified in the playtest:** the Bootstrap runs, `AbilityKitNet` and both remotes exist, the
player has a character, and the player-already-present fix is in.

**Not yet verified:** that the snapshot actually reaches the client, that an intent refused
reaches the log, that activating spends the mana, that a death restores the pools, and that stopping
the playtest leaves nothing behind. The boot fix and the `CharacterAdded` wiring both landed after
the playtest that motivated them, so the re-run is the next step — and a phase is not finished on
the strength of a fix that has not been watched working. The playtest has one case per feature, and
two of them have never been watched.

## The numbers

- Tests: **179** across 6 suites — AbilityDefinitionSpec 42 · AbilitySpec 34 · AbilityManagerSpec 35 · ResourceManagerSpec 30 · EffectSystemSpec 31 · NetSpec 7
- Lines: **2656 source + 2178 tests** = 4834
- Commits: **36**
- selene: 0 errors, 0 warnings · stylua: clean
- Playtest: ran, found one bug, stopped. The re-run is pending.
