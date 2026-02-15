--[[
	GhostManager.luau

	Makes other players' characters transparent and non-collidable.
	Roblox already replicates character positions — no custom syncing needed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GhostConfig = require(ReplicatedStorage.Shared.GhostConfig)

local GhostManager = {}

local localPlayer = Players.LocalPlayer
local connections = {}
local enabled = true

local function addNametag(character, player)
	local head = character:WaitForChild("Head", 5)
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "GhostNametag"
	billboard.Adornee = head
	billboard.Size = UDim2.new(0, 40, 0, 8)
	billboard.StudsOffset = Vector3.new(0, 1.2, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = player.DisplayName
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = GhostConfig.GHOST_TRANSPARENCY
	label.TextStrokeTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.Arcade
	label.Parent = billboard
end

local function styleCharacter(character, player)
	if not character then return end

	local function stylePart(part)
		if part:IsA("BasePart") then
			part.Transparency = enabled and GhostConfig.GHOST_TRANSPARENCY or 1
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end

	for _, d in ipairs(character:GetDescendants()) do
		stylePart(d)
	end

	-- Catch late-loading accessories
	table.insert(connections, character.DescendantAdded:Connect(stylePart))

	-- Add nametag above head
	addNametag(character, player)

	-- Hide nametag if disabled
	if not enabled then
		local head = character:FindFirstChild("Head")
		if head then
			local tag = head:FindFirstChild("GhostNametag")
			if tag then tag.Enabled = false end
		end
	end
end

local function setupPlayer(player)
	if player == localPlayer then return end
	if player.Character then styleCharacter(player.Character, player) end
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		styleCharacter(character, player)
	end))
end

function GhostManager.init()
	for _, p in ipairs(Players:GetPlayers()) do
		setupPlayer(p)
	end
	table.insert(connections, Players.PlayerAdded:Connect(setupPlayer))
end

function GhostManager.setEnabled(value)
	enabled = value
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and player.Character then
			local character = player.Character
			for _, d in ipairs(character:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Transparency = enabled and GhostConfig.GHOST_TRANSPARENCY or 1
				end
			end
			local head = character:FindFirstChild("Head")
			if head then
				local tag = head:FindFirstChild("GhostNametag")
				if tag then tag.Enabled = enabled end
			end
		end
	end
end

function GhostManager.destroy()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	connections = {}
end

return GhostManager
