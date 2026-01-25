--[[
	CollisionDetector.luau
	
	Handles collision detection between player avatar and obstacles/floor.
	Checks player's HumanoidRootPart position against pipes and floor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local CollisionDetector = {}
CollisionDetector.__index = CollisionDetector

local PlayerController = nil
local PipeManager = nil

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
	Checks if a point is within a bounding box.
	@param point Vector3 - Point to check
	@param part Part - Part to check against
	@return boolean - True if point is inside part
]]
local function isPointInPart(point, part)
	local partCFrame = part.CFrame
	local partSize = part.Size
	
	-- Transform point to part's local space
	local localPoint = partCFrame:PointToObjectSpace(point)
	
	-- Check if point is within part bounds
	return math.abs(localPoint.X) <= partSize.X / 2 and
	       math.abs(localPoint.Y) <= partSize.Y / 2 and
	       math.abs(localPoint.Z) <= partSize.Z / 2
end

--[[
	Checks for collision with the floor (ground).
	Player dies if they touch the ground.
	@return boolean - True if colliding with floor
]]
local function checkFloorCollision()
	if not PlayerController then
		return false
	end
	
	local playerPos = PlayerController.getPosition()
	if not playerPos then
		return false
	end
	
	-- Character is ~4 studs tall, HumanoidRootPart is at center
	-- So feet are at playerY - 2
	local characterHalfHeight = 2
	local feetY = playerPos.Y - characterHalfHeight
	
	-- Floor top is at Y = 0 (baseplate center at -10, height 20, so top at -10 + 10 = 0)
	local floorTopY = Constants.FLOOR.Y_POSITION + (Constants.FLOOR.HEIGHT / 2)
	
	-- Player dies if their feet touch or go below the floor
	-- Add small tolerance to ensure detection
	return feetY <= floorTopY + 0.5
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
	
	-- Character is approximately 4 studs tall and 2 studs wide
	local characterRadius = 1.5 -- Slightly smaller than actual size for fair collision
	
	for _, pipe in ipairs(activePipes) do
		if pipe and pipe.part and pipe.part.Parent then
			local pipePos = pipe.part.Position
			local pipeSize = pipe.part.Size
			
			-- Simple AABB (Axis-Aligned Bounding Box) collision
			-- Check if player bounding box overlaps pipe bounding box
			local playerMinX = playerPos.X - characterRadius
			local playerMaxX = playerPos.X + characterRadius
			local playerMinY = playerPos.Y - 2 -- Feet
			local playerMaxY = playerPos.Y + 2 -- Head
			local playerMinZ = playerPos.Z - characterRadius
			local playerMaxZ = playerPos.Z + characterRadius
			
			local pipeMinX = pipePos.X - pipeSize.X / 2
			local pipeMaxX = pipePos.X + pipeSize.X / 2
			local pipeMinY = pipePos.Y - pipeSize.Y / 2
			local pipeMaxY = pipePos.Y + pipeSize.Y / 2
			local pipeMinZ = pipePos.Z - pipeSize.Z / 2
			local pipeMaxZ = pipePos.Z + pipeSize.Z / 2
			
			-- Check overlap on all axes
			local overlapX = playerMaxX > pipeMinX and playerMinX < pipeMaxX
			local overlapY = playerMaxY > pipeMinY and playerMinY < pipeMaxY
			local overlapZ = playerMaxZ > pipeMinZ and playerMinZ < pipeMaxZ
			
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
