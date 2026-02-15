--[[
	GhostService.luau

	Prevents player-to-player collision using a server-side collision group.
	This must be done on the server so the character is set up BEFORE
	it replicates to other clients (no brief collision window on respawn).
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local GhostService = {}

function GhostService.init()
	-- Create collision group where players can't collide with each other
	-- pcall because RegisterCollisionGroup errors if the group already exists (Studio re-runs)
	pcall(function()
		PhysicsService:RegisterCollisionGroup("PlayerCharacters")
	end)
	PhysicsService:CollisionGroupSetCollidable("PlayerCharacters", "PlayerCharacters", false)

	-- Assign all character parts to the group, including late-loading parts
	local function onCharacter(character)
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CollisionGroup = "PlayerCharacters"
			end
		end
		character.DescendantAdded:Connect(function(part)
			if part:IsA("BasePart") then
				part.CollisionGroup = "PlayerCharacters"
			end
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		if player.Character then onCharacter(player.Character) end
		player.CharacterAdded:Connect(onCharacter)
	end)

	-- Handle players already in the game (Studio fast-start)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then onCharacter(player.Character) end
		player.CharacterAdded:Connect(onCharacter)
	end
end

return GhostService
