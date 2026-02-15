--[[
	TrailManager.luau

	Manages the visual trail behind the player character.
	Creates two Attachments on HumanoidRootPart and a Trail instance between them.
	The trail follows the exact flight path and fades out over its Lifetime.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrailConfig = require(ReplicatedStorage.Shared.TrailConfig)

local TrailManager = {}

local localPlayer = Players.LocalPlayer
local trail = nil
local attachment0 = nil
local attachment1 = nil
local colorCycleConnection = nil
local colorCycleTime = 0

--[[
	Stops the color cycling loop if active.
]]
local function stopColorCycle()
	if colorCycleConnection then
		colorCycleConnection:Disconnect()
		colorCycleConnection = nil
	end
end

--[[
	Builds a rainbow ColorSequence with the hue shifted by `offset` (0-1).
	Distributes `steps` evenly-spaced hue samples across the trail length.
]]
local function buildRainbowColorSequence(offset, steps)
	local keypoints = {}
	for i = 0, steps - 1 do
		local t = i / (steps - 1)
		local hue = (offset + t) % 1
		table.insert(keypoints, ColorSequenceKeypoint.new(t, Color3.fromHSV(hue, 1, 1)))
	end
	return ColorSequence.new(keypoints)
end

--[[
	Starts a Heartbeat loop that shifts the trail's hue each frame.
]]
local function startColorCycle(style)
	stopColorCycle()
	colorCycleTime = 0
	local speed = style.ColorCycleSpeed or 0.3
	local steps = style.ColorSteps or 8
	colorCycleConnection = RunService.Heartbeat:Connect(function(dt)
		if not trail then return end
		colorCycleTime = colorCycleTime + dt
		local offset = (colorCycleTime * speed) % 1
		trail.Color = buildRainbowColorSequence(offset, steps)
	end)
end

--[[
	Creates the trail on the current character's HumanoidRootPart.
	Applies all properties from the active TrailConfig style.
]]
local function createTrail()
	-- Clean up any existing trail objects first
	if trail then
		trail:Destroy()
		trail = nil
	end
	if attachment0 then
		attachment0:Destroy()
		attachment0 = nil
	end
	if attachment1 then
		attachment1:Destroy()
		attachment1 = nil
	end

	local character = localPlayer.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local style = TrailConfig.getStyle()
	if not style then
		warn("TrailManager: No active trail style found")
		return
	end

	local offset = style.AttachmentOffset or Vector3.new(0, 0, 0)
	local spread = style.AttachmentSpread or 1

	-- Create two attachments offset along the Z axis (perpendicular to travel direction)
	attachment0 = Instance.new("Attachment")
	attachment0.Name = "TrailAttachment0"
	attachment0.Position = offset + Vector3.new(0, 0, spread / 2)
	attachment0.Parent = hrp

	attachment1 = Instance.new("Attachment")
	attachment1.Name = "TrailAttachment1"
	attachment1.Position = offset - Vector3.new(0, 0, spread / 2)
	attachment1.Parent = hrp

	-- Create the Trail instance
	trail = Instance.new("Trail")
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1

	-- Apply style properties
	trail.Lifetime = style.Lifetime or 3
	trail.Transparency = style.Transparency or NumberSequence.new(0, 1)
	trail.Color = style.Color or ColorSequence.new(Color3.new(1, 1, 1))
	trail.WidthScale = style.WidthScale or NumberSequence.new(1)
	trail.MinLength = style.MinLength or 0.1
	trail.LightEmission = style.LightEmission or 0
	trail.LightInfluence = style.LightInfluence or 1
	trail.FaceCamera = style.FaceCamera ~= false

	if style.TextureId and style.TextureId ~= "" then
		trail.Texture = style.TextureId
	end
	trail.TextureMode = style.TextureMode or Enum.TextureMode.Stretch
	trail.TextureLength = style.TextureLength or 1

	trail.Enabled = true
	trail.Parent = hrp

	-- Start color cycling if the style defines it
	if style.ColorCycleSpeed and style.ColorCycleSpeed > 0 then
		startColorCycle(style)
	end
end

--[[
	Initializes TrailManager. No-op currently, but maintains pattern consistency.
]]
function TrailManager.init()
end

--[[
	Creates (or recreates) the trail on the current character and enables it.
]]
function TrailManager.start()
	createTrail()
end

--[[
	Stops the trail from emitting new segments.
	Existing segments continue fading out naturally via Lifetime.
]]
function TrailManager.stop()
	stopColorCycle()
	if trail then
		trail.Enabled = false
	end
end

--[[
	Destroys the trail and attachments completely.
]]
function TrailManager.destroy()
	stopColorCycle()
	if trail then
		trail:Destroy()
		trail = nil
	end
	if attachment0 then
		attachment0:Destroy()
		attachment0 = nil
	end
	if attachment1 then
		attachment1:Destroy()
		attachment1 = nil
	end
end

--[[
	Destroys and recreates the trail. Used on character respawn.
]]
function TrailManager.reset()
	TrailManager.destroy()
	createTrail()
end

return TrailManager
