--[[
	TrailConfig.luau

	Single source of truth for trail effect configuration.
	Defines trail style presets and provides a helper to resolve the active style.

	To change the trail: set ACTIVE_STYLE to one of the keys in STYLES.
	To add a new trail: add an entry to STYLES with all the properties below.
]]

local TrailConfig = {}

-- Which style preset is currently active
TrailConfig.ACTIVE_STYLE = "Rainbow"

--============================================================================
-- TRAIL STYLE PRESETS
-- Each style defines all properties applied to the Trail instance.
--============================================================================

TrailConfig.STYLES = {
	Smoke = {
		Lifetime = 3,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 220, 220)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
		}),
		WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		MinLength = 0.1,
		MaxWidth = 3,
		LightEmission = 0.2,
		LightInfluence = 0.8,
		TextureId = "",
		TextureMode = Enum.TextureMode.Stretch,
		TextureLength = 1,
		FaceCamera = true,
		AttachmentOffset = Vector3.new(-1, -1, 0), -- Behind and below center
		AttachmentSpread = 1.5, -- Distance between the two attachments (trail width axis)
	},

	Rainbow = {
		Lifetime = 3,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.7, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		-- Initial color (overridden each frame by color cycling)
		Color = ColorSequence.new(Color3.fromHSV(0, 1, 1)),
		ColorCycleSpeed = 0.3, -- Full hue rotations per second (0 = static)
		ColorSteps = 8, -- Number of hue samples across the trail length
		WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.3),
		}),
		MinLength = 0.1,
		LightEmission = 0.8,
		LightInfluence = 0.2,
		TextureId = "",
		TextureMode = Enum.TextureMode.Stretch,
		TextureLength = 1,
		FaceCamera = true,
		AttachmentOffset = Vector3.new(-1, -1, 0),
		AttachmentSpread = 2,
	}
}

--[[
	Returns the resolved style table for the active preset.
	@return table - Style properties to apply to a Trail instance
]]
function TrailConfig.getStyle()
	return TrailConfig.STYLES[TrailConfig.ACTIVE_STYLE]
end

return TrailConfig
