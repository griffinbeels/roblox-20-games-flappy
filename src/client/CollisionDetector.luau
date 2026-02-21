--[[
	CollisionDetector.luau
	
	Handles collision detection between player avatar and obstacles/floor.
	Checks player's HumanoidRootPart position against pipes and floor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)

local CollisionDetector = {}
CollisionDetector.__index = CollisionDetector

local PlayerController = nil
local PipeManager = nil
local ParallaxBackground = nil

--[[
	Initializes the CollisionDetector.
	@param playerCtrl PlayerController - The PlayerController instance
	@param pipeMgr PipeManager - The PipeManager instance
]]
function CollisionDetector.init(playerCtrl, pipeMgr)
	PlayerController = playerCtrl
	PipeManager = pipeMgr
end

--[[
	Sets the ParallaxBackground reference so floor collision can query the actual tiles.
	@param parallax ParallaxBackground module
]]
function CollisionDetector.setParallaxBackground(parallax)
	ParallaxBackground = parallax
end

--[[
	Checks for collision with the floor by reading ParallaxBackground's floor surface part.
	Player dies if their hitbox overlaps the floor collider/surface.
	@return boolean - True if colliding with floor
]]
local function checkFloorCollision()
	if not PlayerController or not ParallaxBackground then
		return false
	end

	local floorPart = ParallaxBackground.getFloorPart()
	if not floorPart or not floorPart.Parent then
		return false
	end

	local playerPos = PlayerController.getPosition()
	if not playerPos then
		return false
	end

	local halfH = PlayerConfig.HITBOX_HALF_HEIGHT
	local tol = PlayerConfig.COLLISION_TOLERANCE

	local playerMinY = playerPos.Y - halfH
	local floorMaxY = floorPart.Position.Y + floorPart.Size.Y / 2

	-- Player dies if bottom of hitbox is within tolerance of the floor surface
	return playerMinY < floorMaxY + tol
end

--[[
	Checks for collision with pipes.
	Player dies if they touch any pipe.
	Uses bounding box check accounting for character size.
	@return boolean - True if colliding with any pipe
]]
local function checkPipeCollision()
	if not PlayerController or not PipeManager then
		return false
	end
	
	local playerPos = PlayerController.getPosition()
	if not playerPos then
		return false
	end
	
	local activePipes = PipeManager.getActivePipes()
	if not activePipes then
		return false
	end
	
	local radius = PlayerConfig.HITBOX_RADIUS
	local halfH = PlayerConfig.HITBOX_HALF_HEIGHT
	local tol = PlayerConfig.COLLISION_TOLERANCE

	local playerMinX = playerPos.X - radius
	local playerMaxX = playerPos.X + radius
	local playerMinY = playerPos.Y - halfH
	local playerMaxY = playerPos.Y + halfH
	local playerMinZ = playerPos.Z - radius
	local playerMaxZ = playerPos.Z + radius

	for _, pipe in ipairs(activePipes) do
		-- Support any object: use the hitbox part's Position/Size
		-- This works for Part pipes, Model pipes with invisible hitbox,
		-- or any future pipe representation that sets pipe.part
		if pipe and pipe.part and pipe.part.Parent then
			local pipePos = pipe.part.Position
			local pipeSize = pipe.part.Size

			local pipeMinX = pipePos.X - pipeSize.X / 2
			local pipeMaxX = pipePos.X + pipeSize.X / 2
			local pipeMinY = pipePos.Y - pipeSize.Y / 2
			local pipeMaxY = pipePos.Y + pipeSize.Y / 2
			local pipeMinZ = pipePos.Z - pipeSize.Z / 2
			local pipeMaxZ = pipePos.Z + pipeSize.Z / 2

			-- AABB overlap with tolerance so touching edges count as collision
			local overlapX = playerMaxX > (pipeMinX - tol) and playerMinX < (pipeMaxX + tol)
			local overlapY = playerMaxY > (pipeMinY - tol) and playerMinY < (pipeMaxY + tol)
			local overlapZ = playerMaxZ > (pipeMinZ - tol) and playerMinZ < (pipeMaxZ + tol)

			if overlapX and overlapY and overlapZ then
				return true
			end
		end
	end
	
	return false
end

--[[
	Checks for any collision (floor or pipes).
	@return boolean - True if colliding
]]
function CollisionDetector.checkCollision()
	return checkFloorCollision() or checkPipeCollision()
end

return CollisionDetector
