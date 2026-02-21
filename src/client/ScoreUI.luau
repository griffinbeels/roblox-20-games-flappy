--[[
	ScoreUI.luau

	Creates and manages the score display UI.
	The score display is split into a bacon icon prefix and a number label
	so the number can be independently targeted (e.g. by the bacon fly animation).
	Uses AutomaticSize + height-derived TextSize for viewport-adaptive sizing.
	Uses scale-based positioning so labels stay proportional on any screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScoreManager = require(script.Parent.ScoreManager)
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)

local ScoreUI = {}
ScoreUI.__index = ScoreUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local scoreFrame = nil
local prefixLabel = nil
local scoreValueLabel = nil
local bestLabel = nil
local updateConnection = nil
local resizeConnection = nil

local MIN_TEXT_SIZE = 14
local MAX_TEXT_SIZE = 36
local TEXT_HEIGHT_RATIO = 0.8

--[[
	Recomputes text size from the score frame's pixel height.
	Called on init and whenever the frame resizes (screen resize, orientation change).
]]
local function updateTextSize()
	if not scoreFrame then return end
	local frameHeight = scoreFrame.AbsoluteSize.Y
	local textSize = math.clamp(math.floor(frameHeight * TEXT_HEIGHT_RATIO), MIN_TEXT_SIZE, MAX_TEXT_SIZE)
	if prefixLabel then prefixLabel.TextSize = textSize end
	if scoreValueLabel then scoreValueLabel.TextSize = textSize end
end

--[[
	Initializes the ScoreUI.
]]
function ScoreUI.init()
	-- Create ScreenGui (hidden by default)
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ScoreUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false -- Start hidden
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Container frame for the split score display
	scoreFrame = Instance.new("Frame")
	scoreFrame.Name = "ScoreFrame"
	scoreFrame.Size = UDim2.new(0.3, 0, 0.06, 0)
	scoreFrame.Position = UDim2.new(0.5, 0, 0.02, 0)
	scoreFrame.AnchorPoint = Vector2.new(0.5, 0)
	scoreFrame.BackgroundTransparency = 1
	scoreFrame.Parent = screenGui

	-- Horizontal layout — prefix and value sit side by side, centered
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scoreFrame

	-- Bacon icon prefix (auto-width so it hugs its text)
	prefixLabel = Instance.new("TextLabel")
	prefixLabel.Name = "ScorePrefix"
	prefixLabel.LayoutOrder = 1
	prefixLabel.Size = UDim2.new(0, 0, 1, 0)
	prefixLabel.AutomaticSize = Enum.AutomaticSize.X
	prefixLabel.BackgroundTransparency = 1
	prefixLabel.Text = CurrencyConfig.UI.ICON .. " "
	prefixLabel.TextColor3 = Color3.new(1, 1, 1)
	prefixLabel.TextScaled = false
	prefixLabel.Font = Enum.Font.GothamBold
	prefixLabel.TextSize = MAX_TEXT_SIZE
	prefixLabel.Parent = scoreFrame

	-- Score number (auto-width, fly animation target)
	scoreValueLabel = Instance.new("TextLabel")
	scoreValueLabel.Name = "ScoreValue"
	scoreValueLabel.LayoutOrder = 2
	scoreValueLabel.Size = UDim2.new(0, 0, 1, 0)
	scoreValueLabel.AutomaticSize = Enum.AutomaticSize.X
	scoreValueLabel.BackgroundTransparency = 1
	scoreValueLabel.Text = "0"
	scoreValueLabel.TextColor3 = Color3.new(1, 1, 1)
	scoreValueLabel.TextScaled = false
	scoreValueLabel.Font = Enum.Font.GothamBold
	scoreValueLabel.TextSize = MAX_TEXT_SIZE
	scoreValueLabel.Parent = scoreFrame

	-- Keep text size proportional to frame height across screen sizes
	resizeConnection = scoreFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateTextSize)
	task.defer(updateTextSize)

	-- Create personal best label (scale-positioned, auto-sized text)
	bestLabel = Instance.new("TextLabel")
	bestLabel.Name = "BestLabel"
	bestLabel.Size = UDim2.new(0.25, 0, 0.04, 0)
	bestLabel.Position = UDim2.new(0.5, 0, 0.08, 0)
	bestLabel.AnchorPoint = Vector2.new(0.5, 0)
	bestLabel.BackgroundTransparency = 1
	bestLabel.Text = "Best: 0"
	bestLabel.TextColor3 = Color3.new(0.8, 0.8, 0.8)
	bestLabel.TextScaled = true
	bestLabel.Font = Enum.Font.Gotham
	bestLabel.Parent = screenGui

	local bestConstraint = Instance.new("UITextSizeConstraint")
	bestConstraint.MinTextSize = 10
	bestConstraint.MaxTextSize = 24
	bestConstraint.Parent = bestLabel
end

--[[
	Starts updating the score display.
]]
function ScoreUI.start()
	if updateConnection then
		return
	end

	local RunService = game:GetService("RunService")
	updateConnection = RunService.Heartbeat:Connect(function()
		if scoreValueLabel then
			scoreValueLabel.Text = tostring(ScoreManager.getScore())
		end
		if bestLabel then
			local best = ScoreManager.getPersonalBest()
			if best > 0 then
				bestLabel.Text = "Best: " .. best
			else
				bestLabel.Text = ""
			end
		end
	end)
end

--[[
	Stops updating the score display.
]]
function ScoreUI.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Shows the score UI.
]]
function ScoreUI.show()
	if screenGui then
		screenGui.Enabled = true
	end
end

--[[
	Hides the score UI.
]]
function ScoreUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	Returns the AbsolutePosition and AbsoluteSize of the score VALUE label.
	This is the number portion only (not the bacon icon prefix), so fly
	animations target the actual digit(s) regardless of screen size.
	@return Vector2?, Vector2?
]]
function ScoreUI.getScoreLabelPosition()
	if not scoreValueLabel then return nil, nil end
	return scoreValueLabel.AbsolutePosition, scoreValueLabel.AbsoluteSize
end

--[[
	Cleans up the ScoreUI.
]]
function ScoreUI.destroy()
	ScoreUI.stop()
	if resizeConnection then
		resizeConnection:Disconnect()
		resizeConnection = nil
	end
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return ScoreUI
