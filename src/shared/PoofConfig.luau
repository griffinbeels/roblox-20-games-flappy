--[[
	PoofConfig.luau

	Single source of truth for jump poof effect configuration.
	Defines poof style presets and provides helpers to resolve styles safely.

	To change the poof: set ACTIVE_STYLE to one of the keys in STYLES.
	To add a new poof: add an entry to STYLES with all the properties below.

	EmissionDirection is a unit Vector3 defining where particles travel.
	The poof simulates the character pushing air downward to thrust upward,
	so EmissionDirection should point downward to create a thrust cone beneath the player.
]]

local PoofConfig = {}

PoofConfig.DEFAULT_STYLE = "Glitter"
PoofConfig.ACTIVE_STYLE = PoofConfig.DEFAULT_STYLE

--============================================================================
-- POOF STYLE PRESETS
-- Each style defines ParticleEmitter properties for a one-shot burst on jump.
-- The effect looks like a downward thrust cone, air displaced by the jump.
--
-- Common style fields:
--   ParticleCount        number
--   Offset               Vector3
--   EmissionDirection    Vector3
--   Texture              string
--   Lifetime             NumberRange
--   Speed                NumberRange
--   SpreadAngle          Vector2
--   Size                 NumberSequence
--   Transparency         NumberSequence
--   Color                ColorSequence
--   LightEmission        number
--   LightInfluence       number
--   Drag                 number
--
-- Optional advanced ParticleEmitter fields:
--   Acceleration         Vector3
--   RotSpeed             NumberRange
--   Rotation             NumberRange
--   Squash               NumberSequence
--   ZOffset              number
--   VelocityInheritance  number
--   EmissionShape        Enum.ParticleEmitterShape
--   EmissionShapeInOut   Enum.ParticleEmitterShapeInOut
--   EmissionShapeStyle   Enum.ParticleEmitterShapeStyle
--   Orientation          Enum.ParticleOrientation
--   LockedToPart         boolean
--   TimeScale            number
--============================================================================

PoofConfig.STYLES = {
	Smoke = {
		ParticleCount = 12,
		Lifetime = NumberRange.new(2.5, 3),
		Speed = NumberRange.new(8, 14),
		SpreadAngle = Vector2.new(35, 35), -- Cone spread in degrees
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(0.3, 2.5),
			NumberSequenceKeypoint.new(1, 1.5),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 230, 230)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 180, 180)),
		}),
		LightEmission = 0.2,
		LightInfluence = 0.8,
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Drag = 10,
		Offset = Vector3.new(-1, 1, 0), -- Beneath the player
		EmissionDirection = Vector3.new(0, -1, 0), -- Straight down (thrust cone)
	},

	Glitter = {
		ParticleCount = 24,
		Lifetime = NumberRange.new(0.45, 0.9),
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(25, 25),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.2, 0.95),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.75, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 245, 175)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 200, 90)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 180)),
		}),
		LightEmission = 0.85,
		LightInfluence = 0.1,
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Drag = 2.5,
		Acceleration = Vector3.new(0, -8, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-360, 360),
		Squash = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Offset = Vector3.new(-1, 1, 0),
		EmissionDirection = Vector3.new(0, -1, 0),
	},

	Burst = {
		ParticleCount = 16,
		Lifetime = NumberRange.new(0.3, 0.6),
		Speed = NumberRange.new(12, 20),
		SpreadAngle = Vector2.new(40, 40),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 2.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.4, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 200)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 200, 220)),
		}),
		LightEmission = 0.5,
		LightInfluence = 0.5,
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Drag = 4,
		Offset = Vector3.new(0, -1.5, 0),
		EmissionDirection = Vector3.new(0, -1, 0),
	},
}

--[[
	Returns the resolved style table for a style key, falling back to default.
	@param styleKey string?
	@return table - Style properties to apply to a ParticleEmitter instance
]]
function PoofConfig.getStyleByKey(styleKey)
	if type(styleKey) == "string" and PoofConfig.STYLES[styleKey] then
		return PoofConfig.STYLES[styleKey]
	end
	return PoofConfig.STYLES[PoofConfig.DEFAULT_STYLE]
end

--[[
	Returns the resolved style table for the active preset.
	@return table
]]
function PoofConfig.getStyle()
	return PoofConfig.getStyleByKey(PoofConfig.ACTIVE_STYLE)
end

return PoofConfig
