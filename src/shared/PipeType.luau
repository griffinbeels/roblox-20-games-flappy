--[[
	PipeType.luau
	
	Defines swappable pipe configurations for difficulty tuning.
	Allows easy swapping of pipe types to adjust game difficulty.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local PipeType = {}
PipeType.__index = PipeType

--[[
	Creates a new PipeType.
	@param config table - Configuration table with width, height, gapSize, color, material
	@return PipeType - New PipeType instance
]]
function PipeType.new(config)
	local self = setmetatable({}, PipeType)
	
	self.width = config.width or 2
	self.height = config.height or 50
	self.gapSize = config.gapSize or 8
	self.color = config.color or Color3.fromRGB(0, 255, 0)
	self.material = config.material or Enum.Material.SmoothPlastic
	self.difficulty = config.difficulty or 1
	
	return self
end

--[[
	Default PipeType configuration.
	Uses values from Constants for consistency.
]]
function PipeType.getDefault()
	return PipeType.new(Constants.PIPETYPE_DEFAULT)
end

return PipeType
