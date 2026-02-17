--[[
	PoofConfig.luau

	Single source of truth for jump poof effect configuration.
	Defines poof style presets and provides a helper to resolve the active style.

	To change the poof: set ACTIVE_STYLE to one of the keys in STYLES.
	To add a new poof: add an entry to STYLES with all the properties below.

	EmissionDirection is a unit Vector3 defining where particles travel.
	The poof simulates the character pushing air downward to thrust upward,
	so EmissionDirection should point downward to create a thrust cone beneath the player.
]]

local PoofConfig = {}

-- Which style preset is currently active
PoofConfig.ACTIVE_STYLE = "Smoke"

--============================================================================
-- POOF STYLE PRESETS
-- Each style defines ParticleEmitter properties for a one-shot burst on jump.
-- The effect looks like a downward thrust cone — air displaced by the jump.
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
	Returns the resolved style table for the active preset.
	@return table - Style properties to apply to a ParticleEmitter instance
]]
function PoofConfig.getStyle()
	return PoofConfig.STYLES[PoofConfig.ACTIVE_STYLE]
end

return PoofConfig
