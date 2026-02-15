--[[
	Pipe.luau

	Individual pipe obstacle (can be top or bottom).
	Pipes are spawned in pairs with a gap between them for the player to fly through.

	Supports two modes:
	- Part mode (default): Colored Part pipes using style color/material
	- Model mode: Uses a marketplace model scaled to fit pipe dimensions

	POSITIONING:
	- Top pipe: Top edge at MAX_Y, extends downward
	- Bottom pipe: Bottom edge at MIN_Y, extends upward
	- Gap between them is where player flies through
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local PipeConfig = require(ReplicatedStorage.Shared.PipeConfig)

local Pipe = {}
Pipe.__index = Pipe

-- Pipe dimensions (from PipeConfig)
local PIPE_WIDTH = PipeConfig.WIDTH

-- Default visual fallbacks
local DEFAULT_COLOR = Color3.fromRGB(0, 200, 0)
local DEFAULT_MATERIAL = Enum.Material.SmoothPlastic

--[[
	Gets the bounding box size and center CFrame of a template (Model or BasePart).
]]
local function getTemplateBounds(template)
	if template:IsA("Model") then
		local cf, size = template:GetBoundingBox()
		return size, cf
	else
		-- Single BasePart (MeshPart, Part, etc.)
		return template.Size, template.CFrame
	end
end

--[[
	Scales a cloned template (Model or single BasePart) to match target dimensions.
	@param template Instance - The cloned Model or BasePart to scale
	@param targetSize Vector3 - The desired bounding box size
]]
local function scaleModelToSize(template, targetSize)
	local modelBounds, modelCFrame = getTemplateBounds(template)
	local modelCenter = modelCFrame.Position

	local scaleX = targetSize.X / modelBounds.X
	local scaleY = targetSize.Y / modelBounds.Y
	local scaleZ = targetSize.Z / modelBounds.Z

	if template:IsA("BasePart") then
		-- Single part — just resize directly
		template.Size = targetSize
	else
		-- Model with multiple descendants
		for _, part in ipairs(template:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Size = Vector3.new(
					part.Size.X * scaleX,
					part.Size.Y * scaleY,
					part.Size.Z * scaleZ
				)

				local offset = part.Position - modelCenter
				local scaledOffset = Vector3.new(
					offset.X * scaleX,
					offset.Y * scaleY,
					offset.Z * scaleZ
				)
				part.CFrame = CFrame.new(modelCenter + scaledOffset) * (part.CFrame - part.CFrame.Position)
			end
		end
	end
end

--[[
	Creates a new Pipe with a specific height.
	@param orientation string - "top" or "bottom"
	@param xPosition number - X position for the pipe
	@param height number - Height of this specific pipe (calculated based on gap)
	@param style table|nil - Resolved style { color, material, modelTemplate }
	@return Pipe - New Pipe instance
]]
function Pipe.new(orientation, xPosition, height, style)
	local self = setmetatable({}, Pipe)

	self.orientation = orientation -- "top" or "bottom"
	self.part = nil
	self.xPosition = xPosition or 0
	self.height = height or 10
	self.hasBeenScored = false
	self.container = nil -- Container Model for model mode
	self.visualModel = nil -- The scaled visual model clone

	-- Store style info
	self.style = style or {}
	self.modelTemplate = self.style.modelTemplate
	self.color = self.style.color or DEFAULT_COLOR
	self.material = self.style.material or DEFAULT_MATERIAL

	if self.modelTemplate then
		self:_createModelPipe()
	else
		self:_createPartPipe()
	end

	return self
end

--[[
	Creates a standard Part-based pipe using style color/material.
]]
function Pipe:_createPartPipe()
	self.part = Instance.new("Part")
	self.part.Name = "Pipe_" .. self.orientation
	self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	self.part.Color = self.color
	self.part.Material = self.material
	self.part.Anchored = true
	self.part.CanCollide = false
	self.part.CastShadow = false

	self:updatePosition()
	self.part.Parent = workspace
end

--[[
	Creates a model-based pipe with an invisible hitbox for collision.
]]
function Pipe:_createModelPipe()
	-- Create container
	self.container = Instance.new("Model")
	self.container.Name = "PipeModel_" .. self.orientation

	-- Create invisible hitbox (collision detection uses this via self.part)
	self.part = Instance.new("Part")
	self.part.Name = "PipeHitbox_" .. self.orientation
	self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	self.part.Transparency = 1
	self.part.CanCollide = false
	self.part.Anchored = true
	self.part.CastShadow = false
	self.part.Parent = self.container

	-- Clone and scale the visual model
	self.visualModel = self.modelTemplate:Clone()
	self.visualModel.Name = "PipeVisual"

	-- Anchor all parts (handle single BasePart or Model with descendants)
	if self.visualModel:IsA("BasePart") then
		self.visualModel.Anchored = true
		self.visualModel.CanCollide = false
		self.visualModel.CastShadow = false
	end
	for _, part in ipairs(self.visualModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CastShadow = false
		end
	end

	-- Scale to match pipe dimensions
	local targetSize = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	scaleModelToSize(self.visualModel, targetSize)

	self.visualModel.Parent = self.container

	-- Position everything
	self:updatePosition()
	self.container.Parent = workspace
end

--[[
	Updates the pipe's visual position based on orientation and height.
]]
function Pipe:updatePosition()
	if not self.part then return end

	local centerY
	if self.orientation == "top" then
		-- Height includes TOP_PIPE_EXTENSION; anchor so bottom edge stays at the gap
		-- and the extra height extends above MAX_Y (off-screen)
		centerY = (WorldConfig.BOUNDARIES.MAX_Y + PipeConfig.TOP_PIPE_EXTENSION) - (self.height / 2)
	elseif self.orientation == "bottom" then
		centerY = WorldConfig.BOUNDARIES.MIN_Y + (self.height / 2)
	end

	local position = Vector3.new(self.xPosition, centerY, 0)
	self.part.Position = position

	-- Move visual to match hitbox position
	if self.visualModel then
		local _, modelCFrame = getTemplateBounds(self.visualModel)
		local offset = position - modelCFrame.Position

		if self.visualModel:IsA("BasePart") then
			self.visualModel.CFrame = self.visualModel.CFrame + offset
		else
			for _, part in ipairs(self.visualModel:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CFrame = part.CFrame + offset
				end
			end
		end

		-- Flip top pipes upside down (template is assumed to be bottom-pipe orientation)
		if self.orientation == "top" then
			local flipRotation = CFrame.Angles(0, 0, math.pi) -- 180° around Z axis
			if self.visualModel:IsA("BasePart") then
				self.visualModel.CFrame = CFrame.new(position) * flipRotation * (self.visualModel.CFrame - self.visualModel.CFrame.Position)
			else
				for _, part in ipairs(self.visualModel:GetDescendants()) do
					if part:IsA("BasePart") then
						local relOffset = part.Position - position
						local flippedOffset = flipRotation * relOffset
						part.CFrame = CFrame.new(position + flippedOffset) * flipRotation * (part.CFrame - part.CFrame.Position)
					end
				end
			end
		end
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

		-- Re-scale the visual model if in model mode
		if self.visualModel then
			-- Destroy old visual and clone fresh from template
			self.visualModel:Destroy()
			self.visualModel = self.modelTemplate:Clone()
			self.visualModel.Name = "PipeVisual"

			if self.visualModel:IsA("BasePart") then
				self.visualModel.Anchored = true
				self.visualModel.CanCollide = false
				self.visualModel.CastShadow = false
			end
			for _, part in ipairs(self.visualModel:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CastShadow = false
				end
			end

			local targetSize = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
			scaleModelToSize(self.visualModel, targetSize)
			self.visualModel.Parent = self.container
		end
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
	if self.container then
		self.container:Destroy()
		self.container = nil
		self.visualModel = nil
		self.part = nil
	elseif self.part then
		self.part:Destroy()
		self.part = nil
	end
end

return Pipe
