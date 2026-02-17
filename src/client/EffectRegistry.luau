--[[
	EffectRegistry.luau

	Singleton registry for player effects (Trail, Ghost, etc.).
	Effects register themselves by name and must implement a standard interface:
	  init()    — one-time setup
	  start()   — begin/restart the effect
	  stop()    — disable the effect (graceful)
	  reset()   — destroy + recreate for fresh state
	  destroy() — remove all instances and connections
	All methods are optional — the registry skips missing ones.
]]

local EffectRegistry = {}
local effects = {} -- { [name] = effectModule }

function EffectRegistry.register(name, effectModule)
	effects[name] = effectModule
end

function EffectRegistry.get(name)
	return effects[name]
end

-- Bulk lifecycle methods — iterate all registered effects

function EffectRegistry.initAll()
	for _, fx in pairs(effects) do
		if fx.init then fx.init() end
	end
end

function EffectRegistry.startAll()
	for _, fx in pairs(effects) do
		if fx.start then fx.start() end
	end
end

function EffectRegistry.stopAll()
	for _, fx in pairs(effects) do
		if fx.stop then fx.stop() end
	end
end

function EffectRegistry.resetAll()
	for _, fx in pairs(effects) do
		if fx.reset then fx.reset() end
	end
end

function EffectRegistry.destroyAll()
	for _, fx in pairs(effects) do
		if fx.destroy then fx.destroy() end
	end
end

return EffectRegistry
