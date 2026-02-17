--[[
	PoofManager.luau

	Spawns a particle "poof" burst at the player's position on each jump.
	Uses one-shot ParticleEmitter:Emit() — Rate stays 0, no continuous emission.
	The emitter part is oriented so particles shoot in the configured EmissionDirection
	(typically straight down, creating a thrust cone beneath the player).
	Temporary parts are cleaned up after particles fade.

	Implements the EffectRegistry lifecycle interface (init, stop, reset, destroy).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PoofConfig = require(ReplicatedStorage.Shared.PoofConfig)

local PoofManager = {}

-- Active poof parts awaiting cleanup { [part] = true }
local activePoofs = {}

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

--[[
	Builds a CFrame at the given position with the part's local +Y axis
	pointing along the given direction. ParticleEmitter's default
	EmissionDirection is Top (local +Y), so this aims the cone.
	@param position Vector3 - World position for the part
	@param direction Vector3 - Unit direction that local +Y should point toward
	@return CFrame
]]
local function buildEmissionCFrame(position, direction)
	-- Pick an up-vector that isn't parallel to direction for the cross product
	local upHint = Vector3.new(0, 1, 0)
	if math.abs(direction:Dot(upHint)) > 0.99 then
		upHint = Vector3.new(0, 0, 1)
	end

	-- Build an orthonormal basis with +Y = direction
	local right = direction:Cross(upHint).Unit
	local forward = right:Cross(direction).Unit

	return CFrame.fromMatrix(position, right, direction, -forward)
end

--[[
	Spawns a one-shot particle burst at the given world position.
	Called by PlayerController on each jump.
	@param position Vector3 - World position to spawn the poof
	@param velocity Vector3 - Player's current velocity (reserved for future use)
]]
function PoofManager.onJump(position, velocity)
	local style = PoofConfig.getStyle()
	if not style then return end

	local offset = style.Offset or Vector3.new(0, 0, 0)
	local spawnPos = position + offset
	local emitDir = style.EmissionDirection or Vector3.new(0, -1, 0)

	-- Create a tiny invisible anchored part as the emitter host,
	-- oriented so its Top face (+Y) points along the emission direction
	local part = Instance.new("Part")
	part.Name = "PoofEffect"
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.CFrame = buildEmissionCFrame(spawnPos, emitDir)
	part.Parent = workspace

	-- Configure the ParticleEmitter (emits from Top face = local +Y)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0 -- No continuous emission; we use Emit()
	emitter.Lifetime = style.Lifetime or NumberRange.new(0.5, 1)
	emitter.Speed = style.Speed or NumberRange.new(3, 6)
	emitter.SpreadAngle = style.SpreadAngle or Vector2.new(35, 35)
	emitter.Size = style.Size or NumberSequence.new(1)
	emitter.Transparency = style.Transparency or NumberSequence.new(0, 1)
	emitter.Color = style.Color or ColorSequence.new(Color3.new(1, 1, 1))
	emitter.LightEmission = style.LightEmission or 0
	emitter.LightInfluence = style.LightInfluence or 1
	emitter.Drag = style.Drag or 0

	if style.Texture and style.Texture ~= "" then
		emitter.Texture = style.Texture
	end

	emitter.Parent = part

	-- Emit a one-shot burst
	local count = style.ParticleCount or 8
	emitter:Emit(count)

	-- Track for cleanup
	activePoofs[part] = true

	-- Schedule cleanup after the longest possible particle lifetime
	local maxLifetime = 1
	if typeof(style.Lifetime) == "NumberRange" then
		maxLifetime = style.Lifetime.Max
	end

	task.delay(maxLifetime + 0.1, function()
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
	Stops the effect — cleans up any lingering poofs.
]]
function PoofManager.stop()
	cleanupAll()
end

--[[
	Resets for a new round — cleans up any lingering poofs from previous round.
]]
function PoofManager.reset()
	cleanupAll()
end

--[[
	Full cleanup — removes all instances permanently.
]]
function PoofManager.destroy()
	cleanupAll()
end

return PoofManager
