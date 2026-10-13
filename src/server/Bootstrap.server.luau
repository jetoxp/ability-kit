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

-- Counted by pairs, not with #: the catalog is keyed by id, and `#` on a dictionary returns 0 no
-- matter how full it is. This line reported "0 abilities" on a healthy boot, which cost more time
-- than printing nothing would have.
local catalogSize = 0
for _ in pairs(Catalog) do
	catalogSize += 1
end
print(
	string.format(
		"[ability-kit] bootstrap up: %d abilities in the catalog, %d equipped by default",
		catalogSize,
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
		-- Described fresh on every use, which today means once per player per frame. It is six table
		-- reads. If this ever shows up in a profile, the fix is to describe once per character and
		-- invalidate on CharacterAdded — not to cache blindly, because `alive` and `health.current`
		-- are exactly the two fields a stale copy would get wrong.
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

	--[[
		Death and respawn, wired HERE and not in the PlayerAdded callback.

		Three functions were written and tested for this and none of them was ever called: reset() clears
		cooldowns and casts, refill() takes the pools back to full, clear() drops the effects. Without
		this wiring a player who dies mid-cast keeps the cooldown, the spent mana and the poison on their
		corpse, and comes back with all three.

		It lives in buildSession because that is the one function BOTH paths go through — PlayerAdded for
		whoever joins, and the seed loop for whoever is already here when the script runs. Kept in the
		PlayerAdded callback it covered the first path and silently missed the second, which in Studio is
		the only one that ever runs.

		Two events rather than one, because they are two different moments with two different subjects:
		`CharacterAdded` is about the player coming back, and `CharacterRemoving` is about the character
		going away. `CharacterRemoving` also fires while the Instance is still valid, which is what makes
		it the right place to drop the effects — the id they are keyed by is that Instance.
	]]
	player.CharacterAdded:Connect(function()
		local current = sessions[player]
		if current ~= nil then
			current.manager:reset()
			current.resources:refill()
		end
	end)

	player.CharacterRemoving:Connect(function(character)
		local current = sessions[player]
		if current ~= nil then
			-- The id a target is keyed by is the character Instance, not the Player. Clearing by
			-- player would remove nothing and leave the effects running on a corpse.
			current.effects:clear(character)
		end
	end)

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

Players.PlayerRemoving:Connect(function(player)
	local session = sessions[player]
	if session ~= nil then
		-- Nothing to save: this kit persists no state. What there is to do is let go of it, so a
		-- session cannot outlive the player it belongs to.
		--
		-- The effects are keyed by the CHARACTER, which is the id describe() gives them, so
		-- clear(player) removed nothing. This clears the one that exists.
		local character = player.Character
		if character ~= nil then
			session.effects:clear(character)
		end
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
	--
	-- The cost is paid at the COMMIT POINT, which is the activation and not the firing. That makes
	-- an interrupted cast a paid-for cast: a Fireball interrupted at 0.3s of 0.4s has spent the
	-- mana and produced nothing. This is deliberate — the alternative is a refund path, which means
	-- the server tracks what each cast has paid and reconciles it on every interrupt, cancel and
	-- disconnect. A game that wants the forgiving version calls `resources:restore` on the ability's
	-- cost when it cancels, which is the reason that function exists.
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
				-- KNOWN LIMITATION: target = source. Every ability is self-cast, because the intent
				-- carries no target and nothing here resolves one. Fireball, whose definition says
				-- "a single target" with range 60, therefore burns its caster. Target selection is
				-- a later phase: a raycast from the caster's CFrame, or a client-supplied reference
				-- the server validates. Giving the client the choice without validating it is the one
				-- version of this that is not an option.
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
			-- Subtract rather than zero: the overshoot belongs to the next interval. Zeroing it
			-- loses time on every send, which is the same "time that goes missing" shape this kit
			-- has already met twice — in the cooldown and in the DoT.
			session.stateClock -= STATE_INTERVAL
			if player.Parent ~= nil then
				-- A player can leave between the heartbeat starting and this line. Firing at a
				-- departed player is silent, but checking costs one comparison.
				stateRemote:FireClient(player, snapshot(session))
			end
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
