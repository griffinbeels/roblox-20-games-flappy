--[[
	Pipe.luau

	Individual pipe obstacle (can be top or bottom).
	Pipes are spawned in pairs with a gap between them for the player to fly through.

	Supports three rendering types (dispatched via style.type):
	- "part" (default): Simple colored Part
	- "model": Marketplace model scaled to fit pipe dimensions
	- "studs": Composite shaft + fixed-size lip at the opening

	POSITIONING:
	- Top pipe: Top edge at MAX_Y, extends downward
	- Bottom pipe: Bottom edge at MIN_Y, extends upward
	- Gap between them is where player flies through

	All visual config comes from self.style (merged from STYLE_DEFAULTS
	+ per-style overrides by PipeManager at init time).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local PipeConfig = require(ReplicatedStorage.Shared.PipeConfig)

local Pipe = {}
Pipe.__index = Pipe

local PIPE_WIDTH = PipeConfig.WIDTH

--[[
	Gets the bounding box size and center CFrame of a template (Model or BasePart).
]]
local function getTemplateBounds(template)
	if template:IsA("Model") then
		local cf, size = template:GetBoundingBox()
		return size, cf
	else
		return template.Size, template.CFrame
	end
end

--[[
	Scales a cloned template (Model or single BasePart) to match target dimensions.
]]
local function scaleModelToSize(template, targetSize)
	local modelBounds, modelCFrame = getTemplateBounds(template)
	local modelCenter = modelCFrame.Position

	local scaleX = targetSize.X / modelBounds.X
	local scaleY = targetSize.Y / modelBounds.Y
	local scaleZ = targetSize.Z / modelBounds.Z

	if template:IsA("BasePart") then
		template.Size = targetSize
	else
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
	Clones a model template and prepares all parts (anchor, disable collide/shadow).
	@param template Instance - The source Model or BasePart to clone
	@return Instance - The prepared clone
]]
local function cloneAndPrepareModel(template)
	local clone = template:Clone()
	clone.Name = "PipeVisual"

	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CastShadow = false
	end
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CastShadow = false
		end
	end

	return clone
end

--[[
	Creates a new Pipe with a specific height.
	@param orientation string - "top" or "bottom"
	@param xPosition number - X position for the pipe
	@param height number - Height of this specific pipe (calculated based on gap)
	@param style table - Resolved style with `type` field and visual config
	@return Pipe - New Pipe instance
]]
function Pipe.new(orientation, xPosition, height, style)
	local self = setmetatable({}, Pipe)

	self.orientation = orientation -- "top" or "bottom"
	self.part = nil
	self.xPosition = xPosition or 0
	self.height = height or 10
	self.hasBeenScored = false
	self.container = nil -- Container Model for model/studs mode
	self.visualModel = nil -- The scaled visual model clone

	-- Studs mode parts
	self.shaft = nil
	self.lip = nil

	-- All visual config lives in self.style
	self.style = style or {}

	if self.style.type == "studs" then
		self:_createStudsPipe()
	elseif self.style.type == "model" then
		self:_createModelPipe()
	else
		self:_createPartPipe()
	end

	return self
end

--[[
	Creates the invisible hitbox Part used for collision detection.
	Used by studs and model types (part type uses its visible Part as hitbox).
]]
function Pipe:_createHitbox()
	self.part = Instance.new("Part")
	self.part.Name = "PipeHitbox_" .. self.orientation
	self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	self.part.Transparency = 1
	self.part.CanCollide = false
	self.part.Anchored = true
	self.part.CastShadow = false
end

--[[
	Creates a standard Part-based pipe using style color/material.
]]
function Pipe:_createPartPipe()
	self.part = Instance.new("Part")
	self.part.Name = "Pipe_" .. self.orientation
	self.part.Size = Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH)
	self.part.Color = self.style.color
	self.part.Material = self.style.material
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
	self.container = Instance.new("Model")
	self.container.Name = "PipeModel_" .. self.orientation

	self:_createHitbox()
	self.part.Parent = self.container

	-- Clone, prepare, and scale the visual model
	self.visualModel = cloneAndPrepareModel(self.style.modelTemplate)
	scaleModelToSize(self.visualModel, Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH))
	self.visualModel.Parent = self.container

	self:updatePosition()
	self.container.Parent = workspace
end

--[[
	Creates a composite studs pipe with a shaft and a lip/cap at the gap-facing end.
	The shaft uses a tiling material so vertical stretching looks clean.
	The lip is a fixed-size wider piece that gives the classic pipe silhouette.
]]
function Pipe:_createStudsPipe()
	local lipHeight = self.style.lipHeight
	local lipOverhang = self.style.lipOverhang
	local lipWidth = PIPE_WIDTH + 2 * lipOverhang
	local shaftHeight = math.max(0, self.height - lipHeight)

	self.container = Instance.new("Model")
	self.container.Name = "PipeStuds_" .. self.orientation

	self:_createHitbox()
	self.part.Parent = self.container

	-- Shaft (stretchy part — fills most of the height)
	self.shaft = Instance.new("Part")
	self.shaft.Name = "Shaft"
	self.shaft.Size = Vector3.new(PIPE_WIDTH, shaftHeight, PIPE_WIDTH)
	self.shaft.Color = self.style.shaftColor
	self.shaft.Material = self.style.shaftMaterial
	self.shaft.Anchored = true
	self.shaft.CanCollide = false
	self.shaft.CastShadow = false
	self.shaft.Parent = self.container

	-- Lip (fixed-size cap at the gap-facing end)
	self.lip = Instance.new("Part")
	self.lip.Name = "Lip"
	self.lip.Size = Vector3.new(lipWidth, lipHeight, lipWidth)
	self.lip.Color = self.style.lipColor
	self.lip.Material = self.style.lipMaterial
	self.lip.Anchored = true
	self.lip.CanCollide = false
	self.lip.CastShadow = false
	self.lip.Parent = self.container

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
		centerY = (WorldConfig.BOUNDARIES.MAX_Y + PipeConfig.TOP_PIPE_EXTENSION) - (self.height / 2)
	else
		centerY = (WorldConfig.BOUNDARIES.MIN_Y - PipeConfig.BOTTOM_PIPE_EXTENSION) + (self.height / 2)
	end

	local position = Vector3.new(self.xPosition, centerY, 0)
	self.part.Position = position

	-- Studs mode: position shaft and lip relative to pipe center
	if self.shaft then
		local lipHeight = self.style.lipHeight

		if self.orientation == "bottom" then
			local shaftCenterY = centerY - (lipHeight / 2)
			local lipCenterY = centerY + (self.height / 2) - (lipHeight / 2)
			self.shaft.Position = Vector3.new(self.xPosition, shaftCenterY, 0)
			self.lip.Position = Vector3.new(self.xPosition, lipCenterY, 0)
		else
			local shaftCenterY = centerY + (lipHeight / 2)
			local lipCenterY = centerY - (self.height / 2) + (lipHeight / 2)
			self.shaft.Position = Vector3.new(self.xPosition, shaftCenterY, 0)
			self.lip.Position = Vector3.new(self.xPosition, lipCenterY, 0)
		end
		return
	end

	-- Model mode: move visual to match hitbox position
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
			local flipRotation = CFrame.Angles(0, 0, math.pi)
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

		-- Studs mode: resize shaft (lip stays fixed size)
		if self.shaft then
			local shaftHeight = math.max(0, self.height - self.style.lipHeight)
			self.shaft.Size = Vector3.new(PIPE_WIDTH, shaftHeight, PIPE_WIDTH)
		elseif self.visualModel then
			-- Re-clone and scale the visual model
			self.visualModel:Destroy()
			self.visualModel = cloneAndPrepareModel(self.style.modelTemplate)
			scaleModelToSize(self.visualModel, Vector3.new(PIPE_WIDTH, self.height, PIPE_WIDTH))
			self.visualModel.Parent = self.container
		end
	end
	self:updatePosition()
end

--[[
	Gets the pipe's X position (for scoring and despawning).
]]
function Pipe:getX()
	return self.xPosition
end

function Pipe:markAsScored()
	self.hasBeenScored = true
end

function Pipe:isScored()
	return self.hasBeenScored
end

function Pipe:resetScored()
	self.hasBeenScored = false
end

function Pipe:destroy()
	if self.container then
		self.container:Destroy()
		self.container = nil
		self.visualModel = nil
		self.shaft = nil
		self.lip = nil
		self.part = nil
	elseif self.part then
		self.part:Destroy()
		self.part = nil
	end
end

return Pipe
