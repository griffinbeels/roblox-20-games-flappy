--[[
	Pipe.luau
	
	Individual pipe obstacle (can be top or bottom).
	Pipes are spawned in pairs with a gap between them for the player to fly through.
	
	POSITIONING:
	- Top pipe: Top edge at MAX_Y, extends downward
	- Bottom pipe: Bottom edge at MIN_Y, extends upward
	- Gap between them is where player flies through
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local PipeType = require(ReplicatedStorage.Shared.PipeType)

local Pipe = {}
Pipe.__index = Pipe

-- Pipe visual settings (from Constants for easy adjustment)
local PIPE_WIDTH = Constants.PIPE.WIDTH
local PIPE_COLOR = Constants.PIPE.COLOR
local PIPE_MATERIAL = Constants.PIPE.MATERIAL

--[[
	Creates a new Pipe with a specific height.
	@param pipeType PipeType - The PipeType configuration to use (legacy, optional)
	@param orientation string - "top" or "bottom"
	@param xPosition number - X position for the pipe
	@param height number - Height of this specific pipe (calculated based on gap)
	@return Pipe - New Pipe instance
]]
function Pipe.new(pipeType, orientation, xPosition, height)
	local self = setmetatable({}, Pipe)
	
	self.pipeType = pipeType or PipeType.getDefault()
	self.orientation = orientation -- "top" or "bottom"
	self.part = nil
	self.xPosition = xPosition or 0
	self.height = height or 10
	self.hasBeenScored = false
	
	-- Create the pipe part
	self.part = Instance.new("Part")
	self.part.Name = "Pipe_" .. orientation
	-- Use Constants for visual properties
	self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	self.part.Color = PIPE_COLOR
	self.part.Material = PIPE_MATERIAL
	self.part.Anchored = true
	self.part.CanCollide = true
	self.part.CastShadow = false
	
	-- Position based on orientation
	self:updatePosition()
	
	self.part.Parent = workspace
	
	return self
end

--[[
	Updates the pipe's visual position based on orientation and height.
]]
function Pipe:updatePosition()
	if not self.part then return end
	
	if self.orientation == "top" then
		-- Top pipe: hangs from ceiling (MAX_Y), extends downward
		-- Center Y = MAX_Y - height/2
		local centerY = Constants.BOUNDARIES.MAX_Y - (self.height / 2)
		self.part.Position = Vector3.new(self.xPosition, centerY, 0)
	elseif self.orientation == "bottom" then
		-- Bottom pipe: sits on floor (MIN_Y), extends upward
		-- Center Y = MIN_Y + height/2
		local centerY = Constants.BOUNDARIES.MIN_Y + (self.height / 2)
		self.part.Position = Vector3.new(self.xPosition, centerY, 0)
	end
end

--[[
	Sets the pipe's X position and height.
	@param xPosition number - New X position
	@param height number - New height (optional, keeps current if not provided)
]]
function Pipe:setPositionAndHeight(xPosition, height)
	self.xPosition = xPosition
	if height then
		self.height = height
		self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	end
	self:updatePosition()
end

--[[
	Gets the pipe's X position (for scoring and despawning).
	@return number - X position
]]
function Pipe:getX()
	return self.xPosition
end

--[[
	Marks this pipe as scored.
]]
function Pipe:markAsScored()
	self.hasBeenScored = true
end

--[[
	Checks if this pipe has been scored.
	@return boolean - True if scored
]]
function Pipe:isScored()
	return self.hasBeenScored
end

--[[
	Resets the scored flag.
]]
function Pipe:resetScored()
	self.hasBeenScored = false
end

--[[
	Destroys the pipe.
]]
function Pipe:destroy()
	if self.part then
		self.part:Destroy()
		self.part = nil
	end
end

return Pipe
