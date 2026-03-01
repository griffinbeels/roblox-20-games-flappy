--[[
	PoofManager.luau

	Spawns a particle "poof" burst at the player's position on each jump.
	Uses one-shot ParticleEmitter:Emit() with Rate = 0 (no continuous emission).
	The emitter host part is oriented so particles shoot in style.EmissionDirection.

	Implements the EffectRegistry lifecycle interface (init, stop, reset, destroy).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PoofConfig = require(ReplicatedStorage.Shared.PoofConfig)

local PoofManager = {}

-- Active poof parts awaiting cleanup { [part] = true }
local activePoofs = {}

local DEFAULT_EMIT_DIRECTION = Vector3.new(0, -1, 0)

local EMITTER_DEFAULTS = {
	Lifetime = NumberRange.new(0.5, 1),
	Speed = NumberRange.new(3, 6),
	SpreadAngle = Vector2.new(35, 35),
	Size = NumberSequence.new(1),
	Transparency = NumberSequence.new(0, 1),
	Color = ColorSequence.new(Color3.new(1, 1, 1)),
	LightEmission = 0,
	LightInfluence = 1,
	Drag = 0,
}

local OPTIONAL_EMITTER_PROPERTIES = {
	"Acceleration",
	"RotSpeed",
	"Rotation",
	"Squash",
	"ZOffset",
	"VelocityInheritance",
	"EmissionShape",
	"EmissionShapeInOut",
	"EmissionShapeStyle",
	"Orientation",
	"LockedToPart",
	"TimeScale",
}

--[[
	Destroys all active poof parts immediately.
]]
local function cleanupAll()
	for part in pairs(activePoofs) do
		if part and part.Parent then
			part:Destroy()
		end
	end
	activePoofs = {}
end

local function safeSetProperty(instance, propertyName, value)
	local ok, err = pcall(function()
		instance[propertyName] = value
	end)
	if not ok then
		warn(string.format("[PoofManager] Invalid style property %s: %s", propertyName, tostring(err)))
	end
end

local function normalizeDirection(direction)
	if typeof(direction) ~= "Vector3" then
		return DEFAULT_EMIT_DIRECTION
	end

	local magnitude = direction.Magnitude
	if magnitude < 0.001 then
		return DEFAULT_EMIT_DIRECTION
	end

	return direction / magnitude
end

--[[
	Builds a CFrame at the given position with the part's local +Y axis
	pointing along the given direction.
]]
local function buildEmissionCFrame(position, direction)
	local normalizedDirection = normalizeDirection(direction)

	local upHint = Vector3.new(0, 1, 0)
	if math.abs(normalizedDirection:Dot(upHint)) > 0.99 then
		upHint = Vector3.new(0, 0, 1)
	end

	local right = normalizedDirection:Cross(upHint)
	if right.Magnitude < 0.001 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	local forward = right:Cross(normalizedDirection)
	if forward.Magnitude < 0.001 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end

	return CFrame.fromMatrix(position, right, normalizedDirection, -forward)
end

local function applyEmitterStyle(emitter, style)
	emitter.Rate = 0

	for propertyName, defaultValue in pairs(EMITTER_DEFAULTS) do
		local value = style[propertyName]
		if value == nil then
			value = defaultValue
		end
		safeSetProperty(emitter, propertyName, value)
	end

	if type(style.Texture) == "string" and style.Texture ~= "" then
		safeSetProperty(emitter, "Texture", style.Texture)
	end

	for _, propertyName in ipairs(OPTIONAL_EMITTER_PROPERTIES) do
		local value = style[propertyName]
		if value ~= nil then
			safeSetProperty(emitter, propertyName, value)
		end
	end
end

--[[
	Spawns a one-shot particle burst at the given world position.
	Called by PlayerController on each jump.
	@param position Vector3 - World position to spawn the poof
	@param velocity Vector3 - Player's current velocity (reserved for future use)
]]
function PoofManager.onJump(position, velocity)
	if typeof(position) ~= "Vector3" then
		return
	end

	local style = PoofConfig.getStyle()
	if not style then
		return
	end

	local offset = style.Offset
	if typeof(offset) ~= "Vector3" then
		offset = Vector3.new(0, 0, 0)
	end

	local spawnPos = position + offset
	local emitDir = normalizeDirection(style.EmissionDirection)

	local part = Instance.new("Part")
	part.Name = "PoofEffect"
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CFrame = buildEmissionCFrame(spawnPos, emitDir)
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	applyEmitterStyle(emitter, style)
	emitter.Parent = part

	local count = tonumber(style.ParticleCount) or 8
	count = math.max(0, math.floor(count + 0.5))
	if count > 0 then
		emitter:Emit(count)
	end

	activePoofs[part] = true

	local maxLifetime = 1
	if typeof(style.Lifetime) == "NumberRange" then
		maxLifetime = style.Lifetime.Max
	elseif type(style.Lifetime) == "number" then
		maxLifetime = style.Lifetime
	end

	task.delay(maxLifetime + 0.15, function()
		activePoofs[part] = nil
		if part and part.Parent then
			part:Destroy()
		end
	end)
end

--[[
	One-time setup. No-op currently.
]]
function PoofManager.init()
end

--[[
	Stops the effect and cleans up any lingering poofs.
]]
function PoofManager.stop()
	cleanupAll()
end

--[[
	Resets for a new round and cleans up any lingering poofs.
]]
function PoofManager.reset()
	cleanupAll()
end

--[[
	Full cleanup and removes all instances permanently.
]]
function PoofManager.destroy()
	cleanupAll()
end

return PoofManager
