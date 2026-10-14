--[[
	HudPresenterSpec.luau — runs with `luau tests/HudPresenterSpec.luau`. No Studio.

	The first UI in this project with a suite, and that is the whole point of D1: the arithmetic of what
	to draw is testable because the presenter takes plain tables and is told how much time has passed.
]]

local TestKit = require("./TestKit")
local HudPresenter = require("../src/client/HudPresenter")

local T = TestKit.new("HudPresenter")

local CATALOG = {
	FIREBALL = { id = "FIREBALL", displayName = "Fireball", cooldown = 3 },
	HEAL = { id = "HEAL", displayName = "Heal", cooldown = 8 },
}

local function snap(overrides)
	local base = {
		resources = { mana = { current = 100, max = 100 } },
		cooldowns = { [1] = 0 },
		equipped = { [1] = "FIREBALL" },
		globalCooldown = 0,
		cast = nil,
	}
	for k, v in pairs(overrides or {}) do
		base[k] = v
	end
	return base
end

T("a first snapshot with no previous draws the server's own numbers", function()
	-- Nothing to interpolate against: `t` collapses and every value is the latest snapshot's. A
	-- presenter that needed a previous snapshot to draw anything would blank the HUD on join.
	local d = HudPresenter.draw(nil, snap({ cooldowns = { [1] = 2 } }), 0, 0.1, CATALOG)
	assert(d.slots[1].cooldown == 2, "the server's value, got " .. tostring(d.slots[1].cooldown))
	assert(d.slots[1].ready == false, "and it is not ready")
end)

T("halfway through an interval, the drawn value is halfway between the pair", function()
	local previous = snap({ cooldowns = { [1] = 2.0 } })
	local latest = snap({ cooldowns = { [1] = 1.9 } })
	local d = HudPresenter.draw(previous, latest, 0.05, 0.1, CATALOG)
	assert(
		math.abs(d.slots[1].cooldown - 1.95) < 0.0001,
		"expected 1.95, got " .. tostring(d.slots[1].cooldown)
	)
end)

T("at the end of the interval the drawn value IS the latest snapshot's", function()
	-- This is the property that makes interpolation safe: it can never be ahead of the server,
	-- because at the end of the interval it is exactly what the server said.
	local previous = snap({ cooldowns = { [1] = 2.0 } })
	local latest = snap({ cooldowns = { [1] = 1.9 } })
	local d = HudPresenter.draw(previous, latest, 0.1, 0.1, CATALOG)
	assert(
		math.abs(d.slots[1].cooldown - 1.9) < 0.0001,
		"expected 1.9, got " .. tostring(d.slots[1].cooldown)
	)
end)

T("a long frame does not push the value past the latest snapshot", function()
	-- The case extrapolation gets wrong, pinned: five intervals late and the number is still the
	-- server's last word, not a value invented by the client.
	local previous = snap({ cooldowns = { [1] = 2.0 } })
	local latest = snap({ cooldowns = { [1] = 1.9 } })
	local d = HudPresenter.draw(previous, latest, 0.5, 0.1, CATALOG)
	assert(
		math.abs(d.slots[1].cooldown - 1.9) < 0.0001,
		"expected the latest, got " .. tostring(d.slots[1].cooldown)
	)
end)

T("a cooldown that reaches zero does not go negative", function()
	local d = HudPresenter.draw(
		snap({ cooldowns = { [1] = 0.2 } }),
		snap({ cooldowns = { [1] = 0 } }),
		60,
		0.1,
		CATALOG
	)
	assert(d.slots[1].cooldown == 0, "floored at zero, got " .. tostring(d.slots[1].cooldown))
	assert(d.slots[1].ready == true, "and ready, because the server said zero")
end)

T("ready is the server's zero, never the client's guess", function()
	-- A client that extrapolated would answer `ready` here. The presenter reports the latest
	-- snapshot's number, which is 0.4, so nothing is ready.
	local d = HudPresenter.draw(
		snap({ cooldowns = { [1] = 0.5 } }),
		snap({ cooldowns = { [1] = 0.4 } }),
		3,
		0.1,
		CATALOG
	)
	assert(d.slots[1].ready == false, "not ready, got " .. tostring(d.slots[1].cooldown))
end)

T("the cooldown fraction comes from the catalog, not from the snapshot", function()
	-- The snapshot says how long is left; only the definition knows what it started at.
	local d = HudPresenter.draw(nil, snap({ cooldowns = { [1] = 1.5 } }), 0, 0.1, CATALOG)
	assert(
		math.abs(d.slots[1].fraction - 0.5) < 0.0001,
		"1.5 of 3, got " .. tostring(d.slots[1].fraction)
	)
end)

T("slots are drawn in order, and a hole in the loadout does not shift them", function()
	-- The loadout is a sparse array. Walking it with `#` would draw the wrong slots, or none.
	--
	-- This is the SECOND time this kit has paid for the same rule, and the cousin is worth naming:
	-- phase 5 printed `#Catalog` over a dictionary (0, on a table that was full), and the presenter
	-- walked `#latest.equipped` over an array with holes. **`#` is not a length — it is the last
	-- frontier of a contiguous sequence, and on any table with a gap it lies.** Six phases apart,
	-- same cause, same shape of surprise.
	local d = HudPresenter.draw(nil, snap({ equipped = { [3] = "HEAL" } }), 0, 0.1, CATALOG)
	assert(#d.slots == 1, "one slot, got " .. #d.slots)
	assert(d.slots[1].slot == 3, "and it is slot 3")
end)

T("an unknown ability still draws its slot, without a name", function()
	-- Dropping the slot would make the HUD lie about the loadout, which is worse than an unlabelled
	-- square.
	local d = HudPresenter.draw(nil, snap({ equipped = { [1] = "MYSTERY" } }), 0, 0.1, CATALOG)
	assert(#d.slots == 1, "drawn")
	assert(d.slots[1].id == "MYSTERY" and d.slots[1].name == nil, "with its id and no name")
	assert(d.slots[1].fraction == 0, "and no fraction to claim")
end)

T("a cast carries its progress, interpolated between the pair", function()
	local previous =
		snap({ cast = { id = "FIREBALL", slot = 1, remaining = 0.3, progress = 0.25 } })
	local latest = snap({ cast = { id = "FIREBALL", slot = 1, remaining = 0.2, progress = 0.5 } })
	local d = HudPresenter.draw(previous, latest, 0.05, 0.1, CATALOG)
	assert(d.cast ~= nil, "there is a bar")
	assert(math.abs(d.cast.progress - 0.375) < 0.0001, "halfway, got " .. tostring(d.cast.progress))
	assert(d.cast.name == "Fireball", "and it can be labelled from the catalog")
end)

T("no cast in the latest snapshot means no bar, whatever the previous frame drew", function()
	local previous = snap({ cast = { id = "FIREBALL", slot = 1, remaining = 0.1, progress = 0.9 } })
	local d = HudPresenter.draw(previous, snap({ cast = nil }), 0.05, 0.1, CATALOG)
	assert(d.cast == nil, "the bar is gone the moment the server stops saying there is a cast")
end)

T("a second cast does not interpolate backwards into the first", function()
	-- Progress going 0.9 -> 0.05 is a new cast, not a cast running in reverse. Interpolating it
	-- would draw a bar sweeping backwards.
	local previous = snap({ cast = { id = "HEAL", slot = 2, remaining = 1.0, progress = 0.9 } })
	local latest = snap({ cast = { id = "HEAL", slot = 2, remaining = 1.1, progress = 0.05 } })
	local d = HudPresenter.draw(previous, latest, 0.05, 0.1, CATALOG)
	assert(
		d.cast.progress == 0.05,
		"the latest progress, not a value in between, got " .. tostring(d.cast.progress)
	)
end)

T("resources interpolate and carry a fraction of their max", function()
	local previous = snap({ resources = { mana = { current = 100, max = 100 } } })
	local latest = snap({ resources = { mana = { current = 80, max = 100 } } })
	local d = HudPresenter.draw(previous, latest, 0.05, 0.1, CATALOG)
	assert(
		math.abs(d.resources[1].current - 90) < 0.0001,
		"halfway, got " .. tostring(d.resources[1].current)
	)
	assert(math.abs(d.resources[1].fraction - 0.9) < 0.0001, "90 of 100")
end)

T("pools are drawn in a stable order", function()
	local d = HudPresenter.draw(
		nil,
		snap({
			resources = {
				stamina = { current = 10, max = 100 },
				mana = { current = 50, max = 100 },
			},
		}),
		0,
		0.1,
		CATALOG
	)
	assert(d.resources[1].name == "mana", "sorted by name, got " .. tostring(d.resources[1].name))
	assert(d.resources[2].name == "stamina", "and the second follows")
end)

T("the global cooldown is interpolated like any other number", function()
	local previous = snap({ globalCooldown = 0.3 })
	local latest = snap({ globalCooldown = 0.2 })
	local d = HudPresenter.draw(previous, latest, 0.05, 0.1, CATALOG)
	assert(
		math.abs(d.globalCooldown - 0.25) < 0.0001,
		"halfway, got " .. tostring(d.globalCooldown)
	)
end)

T(
	"a negative elapsed time draws the previous snapshot's values, not a value before them",
	function()
		local d = HudPresenter.draw(
			snap({ cooldowns = { [1] = 2.5 } }),
			snap({ cooldowns = { [1] = 2.0 } }),
			-1,
			0.1,
			CATALOG
		)
		assert(
			math.abs(d.slots[1].cooldown - 2.5) < 0.0001,
			"clamped at the previous value, got " .. tostring(d.slots[1].cooldown)
		)
	end
)

T("junk in returns an empty description rather than a crash", function()
	-- This runs on a renderer's frame. A presenter that throws takes the HUD's loop with it.
	local empty = HudPresenter.draw(nil, nil, 0, 0.1, CATALOG)
	assert(
		type(empty) == "table" and #empty.slots == 0 and empty.cast == nil,
		"a valid empty description"
	)
	assert(
		#HudPresenter.draw(nil, snap(), 0, 0, CATALOG).slots == 1,
		"an interval of zero still draws, without dividing by it"
	)
	assert(
		HudPresenter.draw(nil, snap(), 0, 0.1, nil).slots[1].name == nil,
		"no catalog, no names, still a slot"
	)
	assert(
		#HudPresenter.draw(nil, snap(), "soon", 0.1, CATALOG).slots == 1,
		"a nonsense elapsed time does not crash"
	)
end)

return T.report()
