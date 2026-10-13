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

## How to test it

```
luau tests/run.luau          # 178 cases across 6 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

`NetSpec` covers the client-facing boundary — every case is a payload this version refuses.
The Bootstrap has no suite and cannot have one: it is the file that needs a server. What it
has is a playtest, and the check that matters is that a snapshot reaches the client.

## What is verified, and what is not

**Verified in the playtest:** the Bootstrap runs, `AbilityKitNet` and both remotes exist, the
player has a character, and the player-already-present fix is in.

**Not yet verified:** that the snapshot actually reaches the client, that an intent refused
reaches the log, that activating spends the mana, and that stopping the playtest leaves
nothing behind. The fix for the boot bug landed after the playtest that found it, so the
re-run is the next step — and a phase is not finished on the strength of a fix that has not
been watched working.

## The numbers

- Tests: **178** across 6 suites — AbilityDefinitionSpec 42 · AbilitySpec 34 · AbilityManagerSpec 35 · ResourceManagerSpec 30 · EffectSystemSpec 31 · NetSpec 6
- Lines: **2570 source + 2171 tests** = 4741
- Commits: **29**
- selene: 0 errors, 0 warnings · stylua: clean
- Playtest: ran, found one bug, stopped. The re-run is pending.
