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


### `src/shared/Net.luau`

*The contract, and the client-facing trust boundary as a pure function — which is why it has a suite.*

`git hash-object src/shared/Net.luau` -> `32acf422fcfc`

```lua
--[[
	Net.luau — the wire between the two sides, described once.

	One remote up and one remote down. The up remote carries exactly one shape:

	    { action = "activate", slot = 3 }

	and nothing else. No cost, no target, no direction, no damage. Every one of those is decided on
	the server from a definition the client cannot see. A client that sends a cost is not a client
	this kit is written for, and the validator below is what says so rather than a comment hoping.

	The names live here so the two sides cannot drift, and the shape check is a pure function so it
	can be tested without an engine — which is the only reason a client's payload gets validated
	before it reaches anything that matters.
]]

local Net = {}

Net.FOLDER = "AbilityKitNet"
Net.INTENT = "Intent" -- client -> server
Net.STATE = "State" -- server -> client

-- The only action there is. An ability is activated; it is never "used with 40 damage".
Net.ACTIONS = { "activate" }

Net.MAX_SLOT = nil -- set from Config.MAX_EQUIPPED by Net.configure

function Net.configure(config)
	Net.MAX_SLOT = config.MAX_EQUIPPED
end

--[[
	Checks a client's payload and returns (ok, intentOrReason).

	This is the whole of the client-facing trust boundary, and it is deliberately dull: an action
	from a known list, and a slot within range. Anything else is refused, including a payload that
	carries an extra field — the only way to keep a future field from becoming a future exploit is
	to reject what this version does not know.

	The reason is for the log. It is never sent back: a client that can read why it was refused is a
	client being taught how to ask.
]]
function Net.validateIntent(payload)
	if type(payload) ~= "table" then
		return false, "intent is not a table"
	end

	if type(payload.action) ~= "string" then
		return false, "intent has no action"
	end

	local known = false
	for _, action in ipairs(Net.ACTIONS) do
		if payload.action == action then
			known = true
			break
		end
	end
	if not known then
		return false, string.format("unknown action '%s'", tostring(payload.action))
	end

	if type(payload.slot) ~= "number" or payload.slot ~= payload.slot then
		return false, "slot must be a number"
	end
	if payload.slot < 1 or (Net.MAX_SLOT ~= nil and payload.slot > Net.MAX_SLOT) then
		return false, string.format("slot %s is out of range", tostring(payload.slot))
	end

	-- No extra fields. Stated as a rule rather than assumed, because "it only reads slot" stops
	-- being true the moment somebody adds a convenient field to the client's payload.
	for name in pairs(payload) do
		if name ~= "action" and name ~= "slot" then
			return false, string.format("intent carries unexpected field '%s'", tostring(name))
		end
	end

	return true, { action = payload.action, slot = payload.slot }
end

return Net
```

### `src/server/Bootstrap.server.luau`

*The composition root. Read the header for what it refuses to do, and the intent handler for the order.*

`git hash-object src/server/Bootstrap.server.luau` -> `8595b007725d`

```lua
--[[
	Bootstrap.server.luau — the composition root.

	The only file in this kit where the modules meet. Everything else was written so that it would
	not have to know about anything else: the manager does not know what an effect is, the effect
	system does not know what a player is, and the adapter does not know what a cost is. This file
	introduces them, once per player, and then stays out of the way.

	Its three jobs, and nothing else:

	  1. build the per-player set and keep it in one table
	  2. answer intents, in the order that matters: can it be paid, then activate, then pay
	  3. run one heartbeat that advances everything and hands the resulting events to the adapter

	That second order is the one that is easy to get wrong. Paying after activating means a failed
	spend leaves an activation in flight that has to be cancelled; checking first means the only
	possible failure is a refusal that changed nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local kit = ReplicatedStorage:WaitForChild("AbilityKit")
local Config = require(kit.Config)
local Ability = require(kit.Ability)
local AbilityManager = require(kit.AbilityManager)
local ResourceManager = require(kit.ResourceManager)
local EffectSystem = require(kit.EffectSystem)
local AbilityDefinition = require(kit.AbilityDefinition)
local Net = require(kit.Net)
local DefaultLoadout = require(kit.DefaultLoadout)

local EffectAdapter =
	require(ServerScriptService:WaitForChild("AbilityServer"):WaitForChild("EffectAdapter"))

-- The catalog validates as it builds, so a broken definition stops the game here rather than
-- half-running with an ability nobody can cast. This is also where the validator gets the
-- EffectSystem it checks `stack` policies against.
local Catalog = require(kit.abilities)
AbilityDefinition.init(Config, Catalog, EffectSystem)
Net.configure(Config)

-- One folder, created by the server, so the client waits for something that always exists.
local netFolder = Instance.new("Folder")
netFolder.Name = Net.FOLDER
netFolder.Parent = ReplicatedStorage

local intentRemote = Instance.new("RemoteEvent")
intentRemote.Name = Net.INTENT
intentRemote.Parent = netFolder

local stateRemote = Instance.new("RemoteEvent")
stateRemote.Name = Net.STATE
stateRemote.Parent = netFolder

-- How often a snapshot goes down. Not every frame: a client drawing a cooldown sweep does not need
-- 60 messages a second, and the tick below does not care either way.
local STATE_INTERVAL = 1 / 10

local sessions = {} -- [player] = session

print(
	string.format(
		"[ability-kit] bootstrap up: %d abilities in the catalog, %d equipped by default",
		#Catalog,
		Config.MAX_EQUIPPED
	)
)

--[[
	The unit a session's own systems read, built fresh each time from the live character.

	This is the proxy the composition order depends on: `resources` is the ResourceManager's own
	pool table, in exactly the shape Ability:canActivate reads, so the manager's affordability check
	and the spend that follows cannot disagree — they are looking at the same numbers.
]]
local function ownerProxy(session, player)
	local character = player.Character
	local unit = nil
	if character ~= nil then
		unit = session.adapter:describe(character)
	end
	return {
		alive = unit ~= nil and unit.alive or false,
		resources = session.resources:getOwnerResources(),
		unit = unit,
		character = character,
	}
end

local function buildSession(player)
	local adapter = EffectAdapter.new(Config)
	local session = {
		manager = AbilityManager.new(Config, Ability, Catalog, DefaultLoadout),
		resources = ResourceManager.new(Config),
		effects = EffectSystem.new(Config),
		adapter = adapter,
		stateClock = 0,
	}
	sessions[player] = session
	return session
end

local function snapshot(session)
	local managerState = session.manager:toState()
	-- The two halves of the same table, joined where both are in scope. `resources` is the
	-- ResourceManager's row, and the shapes were declared together in Config.
	local state = {}
	for _, field in ipairs(Config.MANAGER_REQUIRED_FIELDS) do
		state[field] = managerState[field]
	end
	for _, field in ipairs(Config.MANAGER_OPTIONAL_FIELDS) do
		state[field] = managerState[field]
	end
	state.resources = session.resources:toState()
	return state
end

Players.PlayerAdded:Connect(function(player)
	buildSession(player)
end)

-- And the players who are already here. A script connects PlayerAdded at the point it runs, and in
-- Studio that point is reached AFTER the local player has joined — so the event never fires for them
-- and they get no session: no state, no intents, nothing. This is not a Studio quirk to work around;
-- the same thing happens to anyone already in a server when a script reloads.
for _, player in ipairs(Players:GetPlayers()) do
	buildSession(player)
end

Players.PlayerRemoving:Connect(function(player)
	local session = sessions[player]
	if session ~= nil then
		-- Nothing to save: this kit persists no state. What there is to do is let go of it, so a
		-- session cannot outlive the player it belongs to.
		session.effects:clear(player)
		sessions[player] = nil
	end
end)

intentRemote.OnServerEvent:Connect(function(player, payload)
	local session = sessions[player]
	if session == nil then
		return
	end

	local ok, intent = Net.validateIntent(payload)
	if not ok then
		-- The reason goes to the log and never back to the client. A refusal teaches nothing.
		print(
			string.format(
				"[ability-kit] refused an intent from %s: %s",
				player.Name,
				tostring(intent)
			)
		)
		return
	end

	local ability = session.manager:getAbility(intent.slot)
	if ability == nil then
		return
	end

	local owner = ownerProxy(session, player)

	-- The order. `manager:activate` checks the cost against `owner.resources`, which IS the
	-- ResourceManager's live pool table, so this line and the spend below cannot disagree.
	if not session.manager:activate(intent.slot, owner) then
		return
	end

	-- Only now does anything move. The check above cannot have passed and this fail, because both
	-- read the same table in the same frame.
	session.resources:spend(ability:getCost())
end)

--[[
	The single heartbeat.

	One connection for the whole server, not one per player's loops: every session is advanced from
	here, so there is exactly one place where time passes. Effects are handed to the adapter, which
	translates and does not decide.
]]
RunService.Heartbeat:Connect(function(dt)
	for player, session in pairs(sessions) do
		local owner = ownerProxy(session, player)
		local unit = owner.unit

		session.resources:advance(dt)

		for _, firing in ipairs(session.manager:advance(dt)) do
			if unit ~= nil then
				local events = session.effects:applyFiring(firing, {
					source = unit,
					target = unit,
					direction = session.adapter:directionOf(owner.character),
				})
				for _, event in ipairs(events) do
					session.adapter:apply(event)
				end
			end
		end

		-- The timed effects tick whether or not anything fired, and a DoT that cannot reach its
		-- target still expires rather than living forever.
		if unit ~= nil then
			for _, event in ipairs(session.effects:advance(dt)) do
				session.adapter:apply(event)
			end
		end

		session.stateClock = session.stateClock + dt
		if session.stateClock >= STATE_INTERVAL then
			session.stateClock = 0
			stateRemote:FireClient(player, snapshot(session))
		end
	end
end)

-- A server that is shutting down should not leave sessions behind either. There is no state to
-- persist yet, so this is where saving would go, and having the hook in place is the difference
-- between adding it later and forgetting it.
game:BindToClose(function()
	for player in pairs(sessions) do
		sessions[player] = nil
	end
end)
```

### `src/client/AbilityClient.client.luau`

*The client's whole job: a keypress becomes an intent. No local cooldown check, no cost, no target.*

`git hash-object src/client/AbilityClient.client.luau` -> `8802ae2e4d45`

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

`git hash-object src/client/ClientState.luau` -> `7236a8d567af`

```lua
--[[
	ClientState.luau — the last snapshot the server sent, and nothing else.

	It exists as a module rather than a variable inside the client script so that the UI of phase 7
	can read it without being wired into the input handling. The client has no other state, and
	deliberately no logic: it does not check a cooldown locally, does not know a cost, and cannot
	decide that an ability is ready. It asks, and it waits.
]]

local ClientState = {}

ClientState.latest = nil
ClientState.changed = nil -- a BindableEvent, created by the client, for whatever draws this

function ClientState.set(state)
	ClientState.latest = state
	if ClientState.changed ~= nil then
		ClientState.changed:Fire(state)
	end
end

return ClientState
```

### `src/shared/Config.luau`

*The single source of truth for the replicated state, and where the `MANAGER_FIELDS` split is
explained. Read the two field lists and the comment above them.*

`git hash-object src/shared/Config.luau` -> `d21115a9ce04`

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
luau tests/run.luau          # 178 cases across 6 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

`NetSpec` covers the client-facing boundary — every case is a payload this version refuses.
The Bootstrap has no suite and cannot have one: it is the file that needs a server. What it
has is a playtest, and the check that matters is that a snapshot reaches the client.

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

- Tests: **178** across 6 suites — AbilityDefinitionSpec 42 · AbilitySpec 34 · AbilityManagerSpec 35 · ResourceManagerSpec 30 · EffectSystemSpec 31 · NetSpec 6
- Lines: **2570 source + 2171 tests** = 4741
- Commits: **29**
- selene: 0 errors, 0 warnings · stylua: clean
- Playtest: ran, found one bug, stopped. The re-run is pending.
