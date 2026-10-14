--[[
	HudPresenter.luau — what the HUD should draw, decided without an engine.

	It takes two snapshots (the previous one and the latest), how long ago the latest arrived, and the
	interval between snapshots, and returns plain tables describing the screen. No Instance, no service,
	no clock: the elapsed time is an argument, which is the only reason this module has a suite.

	**It interpolates between the pair and never beyond it.** At the end of an interval the drawn value
	equals what the server last said, so the client cannot reach zero early and cannot be ahead of the
	authority. Extrapolation from the latest snapshot would be smoother and would occasionally lie, and
	then every reader of these numbers would have to be trusted to handle the lie.
]]

local HudPresenter = {}

local function clamp01(value)
	if value < 0 then
		return 0
	elseif value > 1 then
		return 1
	end
	return value
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

-- The fraction of the interval that has passed since the latest snapshot arrived. Everything
-- interpolated below uses this same figure, so two bars on screen can never be at different times.
local function progressOf(elapsed, interval)
	if type(elapsed) ~= "number" or type(interval) ~= "number" or interval <= 0 then
		return 1
	end
	return clamp01(elapsed / interval)
end

local function number(value, fallback)
	if type(value) == "number" then
		return value
	end
	return fallback
end

--[[
	A cooldown, interpolated, and floored at zero.

	The floor is not decoration: the pair can straddle the moment a cooldown ends, and a bar drawn from
	1.4 to 0 must not pass through -0.2 on its way. Nothing here decides that the ability is ready —
	`ready` is simply "the server's latest number reached zero".
]]
local function cooldownAt(previous, latest, slot, t)
	local late = number(latest and latest.cooldowns and latest.cooldowns[slot], 0)
	local early = number(previous and previous.cooldowns and previous.cooldowns[slot], late)
	return math.max(0, lerp(early, late, t))
end

local function castAt(previous, latest, t)
	local late = latest and latest.cast
	if type(late) ~= "table" then
		-- The server said there is no cast. There is no bar, whatever the last frame drew.
		return nil
	end

	local lateProgress = clamp01(number(late.progress, 0))
	local early = previous and previous.cast
	local earlyProgress = lateProgress
	-- Interpolating a progress that went backwards would draw a cast bar running in reverse, which
	-- is what a second cast starting looks like from here. Only a cast that is still the same cast
	-- gets interpolated.
	if
		type(early) == "table"
		and early.slot == late.slot
		and early.id == late.id
		and number(early.progress, 0) <= lateProgress
	then
		earlyProgress = clamp01(number(early.progress, lateProgress))
	end

	return {
		slot = late.slot,
		id = late.id,
		progress = lerp(earlyProgress, lateProgress, t),
	}
end

--[[
	The whole screen, as tables:

	    {
	      resources = { { name, current, max, fraction } },   -- sorted by pool name
	      slots     = { { slot, id, name, cooldown, fraction, ready } },  -- in slot order
	      cast      = nil | { slot, id, name, progress },
	      globalCooldown = number,
	    }

	`fraction` on a slot is the cooldown as a share of the ability's full cooldown, which comes from the
	catalog: the snapshot says how long is left, and only the definition knows how long it started at.
	When the catalog has no such ability, `name` and `fraction` are nil and the slot is still drawn —
	a HUD that drops a slot because it cannot label it is a HUD that lies about the loadout.
]]
function HudPresenter.draw(previous, latest, elapsed, interval, catalog)
	local description = { resources = {}, slots = {}, cast = nil, globalCooldown = 0 }
	if type(latest) ~= "table" then
		return description
	end

	local t = progressOf(elapsed, interval)

	local names = {}
	for name in pairs(latest.resources or {}) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local late = latest.resources[name] or {}
		local early = (previous and previous.resources and previous.resources[name]) or late
		local max = number(late.max, 1)
		local current = math.max(
			0,
			lerp(number(early.current, number(late.current, 0)), number(late.current, 0), t)
		)
		table.insert(description.resources, {
			name = name,
			current = current,
			max = max,
			fraction = max > 0 and clamp01(current / max) or 0,
		})
	end

	-- Collected and sorted rather than walked with `#`: the loadout is an array with holes when a
	-- slot is empty, and `#` on a table with holes is not a length. The slots are drawn in order,
	-- which is what a hotbar is.
	local ordered = {}
	for slot in pairs(latest.equipped or {}) do
		if type(slot) == "number" then
			table.insert(ordered, slot)
		end
	end
	table.sort(ordered)
	for _, slot in ipairs(ordered) do
		local id = latest.equipped[slot]
		if id ~= nil then
			local definition = type(catalog) == "table" and catalog[id] or nil
			local cooldown = cooldownAt(previous, latest, slot, t)
			local total = number(definition and definition.cooldown, 0)
			table.insert(description.slots, {
				slot = slot,
				id = id,
				name = definition and definition.displayName or nil,
				cooldown = cooldown,
				fraction = total > 0 and clamp01(cooldown / total) or 0,
				ready = cooldown <= 0,
			})
		end
	end

	local cast = castAt(previous, latest, t)
	if cast ~= nil then
		local definition = type(catalog) == "table" and catalog[cast.id] or nil
		cast.name = definition and definition.displayName or nil
	end
	description.cast = cast

	description.globalCooldown = math.max(
		0,
		lerp(
			number(previous and previous.globalCooldown, number(latest.globalCooldown, 0)),
			number(latest.globalCooldown, 0),
			t
		)
	)

	return description
end

return HudPresenter
