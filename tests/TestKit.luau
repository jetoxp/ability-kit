--!strict
--[[
	TestKit.luau — a micro test runner. No framework, no dependencies.

	WHY THIS EXISTS
	The kit needs a way to say "this rule holds" from a terminal, with no Studio
	and nothing installed. It is 45 lines and hides nothing: each case prints one
	line, and the report at the end is the gate.

	WHY T IS A TABLE WITH __call
	T("name", fn) registers a case and T.report() closes the run. That only works
	if T is callable AND indexable, so it is a table with a __call metamethod.
	As a plain function, T.report would be "attempt to index a function".

	USAGE
	  local T = TestKit.new("MyModule")
	  T("something that must hold", function() assert(...) end)
	  return T.report()
]]

local TestKit = {}

function TestKit.new(moduleName: string)
	local cases = {}

	local T = setmetatable({}, {
		__call = function(_, name: string, fn: () -> ())
			table.insert(cases, { name = name, fn = fn })
		end,
	})

	function T.report(): boolean
		print(string.format("\n===== %s =====", moduleName))
		local passed, failed = 0, 0
		for _, case in ipairs(cases) do
			-- pcall on purpose: one exploding case must not hide the rest.
			local ok, err = pcall(case.fn)
			if ok then
				passed += 1
				print("  PASS  " .. case.name)
			else
				failed += 1
				print("  FAIL  " .. case.name)
				print("        " .. tostring(err):gsub("\n", "\n        "))
			end
		end
		print(string.format("  -> %d passed, %d failed, of %d", passed, failed, #cases))
		if #cases == 0 then
			print("  WARNING: not a single case ran. An empty suite looks like")
			print("  a pass and is not one.")
		end
		return failed == 0
	end

	return T
end

return TestKit
