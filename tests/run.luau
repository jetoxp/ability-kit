--!strict
-- run.luau — carga y ejecuta cada suite del proyecto.

-- Uso, sin Studio y sin dependencias:
--     luau tests/run.luau

-- Cada suite devuelve true o false (TestKit.new(...).report()). Anade las tuyas aqui.

local todas = {}

local function cargar(nombre, ruta)
	local ok, resultado = pcall(function()
		return require(ruta)
	end)
	if not ok then
		print(string.format("  NO SE PUDO CARGAR %s: %s", nombre, tostring(resultado)))
		table.insert(todas, false)
		return
	end
	table.insert(todas, resultado == true)
end

cargar("AbilityDefinition", "./AbilityDefinitionSpec")
cargar("Ability", "./AbilitySpec")
cargar("AbilityManager", "./AbilityManagerSpec")
cargar("ResourceManager", "./ResourceManagerSpec")
cargar("EffectSystem", "./EffectSystemSpec")
cargar("Net", "./NetSpec")

local bien = 0
for _, ok in ipairs(todas) do
	if ok then
		bien += 1
	end
end

print()
print(string.format("===== TOTAL: %d de %d suites en verde =====", bien, #todas))
if #todas == 0 then
	print("AVISO: no se cargo ninguna suite. Eso NO es un aprobado.")
end
