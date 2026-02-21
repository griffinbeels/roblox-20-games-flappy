--[[
	GameOverUI.luau

	Flappy Bird–style Game Over screen with retro/pixel feel.
	Shows score, high score, medal, and a PLAY button.
	Includes a bacon total counter with count-up animation (same style as billboard CurrencyUI).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local JumpInput = require(script.Parent.JumpInput)

local GameOverUI = {}
GameOverUI.__index = GameOverUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local onPlayAgainCallback = nil

-- UIScale: viewport-adaptive scaling
local UI_REFERENCE_HEIGHT = 800
local UI_MIN_SCALE = 0.45
local UI_MAX_SCALE = 1.2
local uiScaleInstance = nil
local viewportScaleConnection = nil

local function updateUIScale()
	if not uiScaleInstance then return end
	local viewportHeight = workspace.CurrentCamera.ViewportSize.Y
	local scale = math.clamp(viewportHeight / UI_REFERENCE_HEIGHT, UI_MIN_SCALE, UI_MAX_SCALE)
	uiScaleInstance.Scale = scale
end

-- References for dynamic updates
local scoreLabelValue = nil
local bestLabelValue = nil
local medalLabel = nil
local newBestIndicator = nil
local baconTotalLabel = nil
local baconEarnedLabel = nil

-- Count-up animation state
local countUpConnection = nil
local countUpStartTime = nil
local countUpStartValue = nil
local countUpEndValue = nil

--============================================================================
-- MEDAL HELPER
--============================================================================

local MEDAL_TIERS = {
	{ threshold = GameConfig.MEDALS.GOLD,   label = "GOLD",   color = Color3.fromRGB(255, 215, 0),   icon = "★" },
	{ threshold = GameConfig.MEDALS.SILVER, label = "SILVER", color = Color3.fromRGB(192, 192, 192), icon = "★" },
	{ threshold = GameConfig.MEDALS.BRONZE, label = "BRONZE", color = Color3.fromRGB(205, 127, 50),  icon = "★" },
}

local function getMedal(score)
	for _, tier in ipairs(MEDAL_TIERS) do
		if score >= tier.threshold then
			return tier
		end
	end
	return nil -- no medal
end

--============================================================================
-- COUNT-UP ANIMATION
--============================================================================

--[[
	Cancels any in-progress count-up animation and snaps to the final value.
]]
local function cancelCountUp()
	if countUpConnection then
		countUpConnection:Disconnect()
		countUpConnection = nil
	end
	-- Snap to final value if animation was in progress
	if countUpEndValue and baconTotalLabel then
		local uiCfg = CurrencyConfig.UI
		baconTotalLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, countUpEndValue)
	end
	countUpStartTime = nil
	countUpStartValue = nil
	countUpEndValue = nil
end

--[[
	Starts a count-up animation on the bacon total label.
	@param startVal number - Starting value (total before this run)
	@param endVal number - Ending value (total after this run)
]]
local function startCountUp(startVal, endVal)
	cancelCountUp()

	local uiCfg = CurrencyConfig.UI
	local celCfg = CurrencyConfig.CELEBRATION

	-- Show starting value immediately
	baconTotalLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, startVal)

	-- If nothing to animate, just show final value
	if startVal == endVal then
		return
	end

	countUpStartValue = startVal
	countUpEndValue = endVal
	countUpStartTime = tick() + celCfg.COUNT_UP_DELAY

	countUpConnection = RunService.Heartbeat:Connect(function()
		local now = tick()
		if now < countUpStartTime then return end -- still in delay

		local elapsed = now - countUpStartTime
		local alpha = math.min(elapsed / celCfg.COUNT_UP_DURATION, 1)
		local value = math.floor(countUpStartValue + (countUpEndValue - countUpStartValue) * alpha)
		baconTotalLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, value)

		if alpha >= 1 then
			countUpConnection:Disconnect()
			countUpConnection = nil
			countUpStartTime = nil
			countUpStartValue = nil
			countUpEndValue = nil
		end
	end)
end

--============================================================================
-- UI CONSTRUCTION
--============================================================================

--[[
	Creates a retro-styled TextLabel helper.
]]
local function makeLabel(props)
	local label = Instance.new("TextLabel")
	label.Name = props.Name or "Label"
	label.Size = props.Size
	label.Position = props.Position
	label.BackgroundTransparency = 1
	label.Text = props.Text or ""
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.TextSize = props.TextSize or 18
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.Parent = props.Parent
	return label
end

--[[
	Initializes the GameOverUI.
]]
function GameOverUI.init()
	-- Create ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GameOverUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Full-screen dimming overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.4
	overlay.BorderSizePixel = 0
	overlay.Parent = screenGui

	-- Container (centered column)
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 340, 0, 440)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	-- UIScale: scales the entire container to fit any viewport size
	uiScaleInstance = Instance.new("UIScale")
	uiScaleInstance.Parent = container
	updateUIScale()

	viewportScaleConnection = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateUIScale()
	end)

	--------------------------------------------------------------------
	-- "GAME OVER" title
	--------------------------------------------------------------------
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 50)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "GAME OVER"
	title.TextColor3 = Color3.fromRGB(255, 80, 60)
	title.TextSize = 40
	title.Font = Enum.Font.GothamBlack
	title.TextStrokeTransparency = 0.4
	title.TextStrokeColor3 = Color3.fromRGB(80, 20, 10)
	title.Parent = container

	--------------------------------------------------------------------
	-- Score panel (rounded tan/cream background, like original Flappy Bird)
	--------------------------------------------------------------------
	local panel = Instance.new("Frame")
	panel.Name = "ScorePanel"
	panel.Size = UDim2.new(1, 0, 0, 200)
	panel.Position = UDim2.new(0, 0, 0, 65)
	panel.BackgroundColor3 = Color3.fromRGB(222, 196, 148)
	panel.BorderSizePixel = 3
	panel.BorderColor3 = Color3.fromRGB(100, 70, 30)
	panel.Parent = container

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	-- Inner shadow/inset frame
	local innerPanel = Instance.new("Frame")
	innerPanel.Name = "InnerPanel"
	innerPanel.Size = UDim2.new(1, -20, 1, -20)
	innerPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	innerPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	innerPanel.BackgroundColor3 = Color3.fromRGB(195, 170, 120)
	innerPanel.BorderSizePixel = 0
	innerPanel.Parent = panel

	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 6)
	innerCorner.Parent = innerPanel

	-- "SCORE" header + value
	makeLabel({
		Name = "ScoreHeader",
		Size = UDim2.new(0.5, 0, 0, 24),
		Position = UDim2.new(0.5, 0, 0, 15),
		Text = "SCORE",
		TextColor3 = Color3.fromRGB(255, 100, 50),
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		Parent = innerPanel,
	})

	scoreLabelValue = makeLabel({
		Name = "ScoreValue",
		Size = UDim2.new(0.5, 0, 0, 36),
		Position = UDim2.new(0.5, 0, 0, 38),
		Text = "0",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 32,
		Font = Enum.Font.GothamBlack,
		Parent = innerPanel,
	})
	scoreLabelValue.TextStrokeTransparency = 0.5
	scoreLabelValue.TextStrokeColor3 = Color3.fromRGB(50, 30, 10)

	-- Divider line
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(0.85, 0, 0, 2)
	divider.AnchorPoint = Vector2.new(0.5, 0)
	divider.Position = UDim2.new(0.5, 0, 0, 82)
	divider.BackgroundColor3 = Color3.fromRGB(160, 140, 100)
	divider.BorderSizePixel = 0
	divider.Parent = innerPanel

	-- "BEST" header + value
	makeLabel({
		Name = "BestHeader",
		Size = UDim2.new(0.5, 0, 0, 24),
		Position = UDim2.new(0.5, 0, 0, 92),
		Text = "BEST",
		TextColor3 = Color3.fromRGB(255, 100, 50),
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		Parent = innerPanel,
	})

	bestLabelValue = makeLabel({
		Name = "BestValue",
		Size = UDim2.new(0.5, 0, 0, 36),
		Position = UDim2.new(0.5, 0, 0, 115),
		Text = "0",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 32,
		Font = Enum.Font.GothamBlack,
		Parent = innerPanel,
	})
	bestLabelValue.TextStrokeTransparency = 0.5
	bestLabelValue.TextStrokeColor3 = Color3.fromRGB(50, 30, 10)

	-- "NEW!" indicator (hidden by default, positioned to the right of BEST section)
	newBestIndicator = makeLabel({
		Name = "NewBest",
		Size = UDim2.new(0, 50, 0, 20),
		Position = UDim2.new(1, -60, 0, 98),
		Text = "NEW!",
		TextColor3 = Color3.fromRGB(255, 50, 50),
		TextSize = 14,
		Font = Enum.Font.GothamBlack,
		Parent = innerPanel,
	})
	newBestIndicator.Visible = false

	-- Medal display (left side of panel)
	local medalFrame = Instance.new("Frame")
	medalFrame.Name = "MedalFrame"
	medalFrame.Size = UDim2.new(0, 60, 0, 60)
	medalFrame.Position = UDim2.new(0, 20, 0.5, -30)
	medalFrame.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
	medalFrame.BorderSizePixel = 0
	medalFrame.Parent = innerPanel

	local medalCorner = Instance.new("UICorner")
	medalCorner.CornerRadius = UDim.new(0, 8)
	medalCorner.Parent = medalFrame

	medalLabel = Instance.new("TextLabel")
	medalLabel.Name = "MedalIcon"
	medalLabel.Size = UDim2.new(1, 0, 1, 0)
	medalLabel.BackgroundTransparency = 1
	medalLabel.Text = ""
	medalLabel.TextColor3 = Color3.new(1, 1, 1)
	medalLabel.TextSize = 36
	medalLabel.Font = Enum.Font.GothamBlack
	medalLabel.Parent = medalFrame

	--------------------------------------------------------------------
	-- Bacon total counter (same style as billboard CurrencyUI)
	--------------------------------------------------------------------
	local uiCfg = CurrencyConfig.UI
	local celCfg = CurrencyConfig.CELEBRATION
	baconTotalLabel = makeLabel({
		Name = "BaconTotal",
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 0, 270),
		Text = "",
		TextColor3 = uiCfg.TEXT_COLOR,
		TextSize = celCfg.TEXT_SIZE,
		Font = uiCfg.FONT,
		Parent = container,
	})
	baconTotalLabel.TextStrokeColor3 = uiCfg.STROKE_COLOR
	baconTotalLabel.TextStrokeTransparency = uiCfg.STROKE_TRANSPARENCY
	baconTotalLabel.Visible = false

	--------------------------------------------------------------------
	-- Bacon earned this run (below total counter)
	--------------------------------------------------------------------
	local goCfg = CurrencyConfig.GAME_OVER
	baconEarnedLabel = makeLabel({
		Name = "BaconEarned",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 300),
		Text = "",
		TextColor3 = goCfg.TEXT_COLOR,
		TextSize = goCfg.TEXT_SIZE,
		Font = goCfg.FONT,
		Parent = container,
	})
	baconEarnedLabel.Visible = false

	--------------------------------------------------------------------
	-- PLAY button
	--------------------------------------------------------------------
	local playButton = Instance.new("TextButton")
	playButton.Name = "PlayButton"
	playButton.Size = UDim2.new(1, 0, 0, 60)
	playButton.Position = UDim2.new(0, 0, 0, 328)
	playButton.BackgroundColor3 = Color3.fromRGB(80, 190, 60)
	playButton.BorderSizePixel = 3
	playButton.BorderColor3 = Color3.fromRGB(40, 100, 30)
	playButton.Text = "PLAY"
	playButton.TextColor3 = Color3.new(1, 1, 1)
	playButton.TextSize = 30
	playButton.Font = Enum.Font.GothamBlack
	playButton.AutoButtonColor = true
	playButton.Parent = container

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 8)
	btnCorner.Parent = playButton

	-- Stroke for button text
	playButton.TextStrokeTransparency = 0.5
	playButton.TextStrokeColor3 = Color3.fromRGB(20, 60, 10)

	-- Hint text below button (shows actual jump key for current device)
	makeLabel({
		Name = "Hint",
		Size = UDim2.new(1, 0, 0, 24),
		Position = UDim2.new(0, 0, 0, 395),
		Text = "or press " .. JumpInput.getKeyLabel(),
		TextColor3 = Color3.fromRGB(200, 200, 200),
		TextSize = 14,
		Font = Enum.Font.Gotham,
		Parent = container,
	})

	-- Button click handler
	playButton.MouseButton1Click:Connect(function()
		if onPlayAgainCallback then
			onPlayAgainCallback()
		end
	end)
end

--[[
	Shows the game over screen.
	@param score number - Final score
	@param personalBest number - Personal best score
	@param baconEarned number? - Bacon earned this run (optional)
	@param baconTotal number? - Lifetime bacon total after this run (optional)
]]
function GameOverUI.show(score, personalBest, baconEarned, baconTotal)
	if not screenGui then
		GameOverUI.init()
	end

	score = score or 0
	personalBest = personalBest or 0
	baconEarned = baconEarned or 0
	baconTotal = baconTotal or 0

	-- Update score
	scoreLabelValue.Text = tostring(score)

	-- Update best (show whichever is higher: stored best or current score)
	local displayBest = math.max(personalBest, score)
	if displayBest > 0 then
		bestLabelValue.Text = tostring(displayBest)
	else
		bestLabelValue.Text = "--"
	end

	-- "NEW!" indicator if this run beat the previous best
	if score > 0 and score >= displayBest and (personalBest == 0 or score > personalBest) then
		newBestIndicator.Visible = true
	else
		newBestIndicator.Visible = false
	end

	-- Medal
	local medal = getMedal(score)
	if medal then
		medalLabel.Text = medal.icon
		medalLabel.TextColor3 = medal.color
		medalLabel.Parent.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
	else
		medalLabel.Text = ""
		medalLabel.Parent.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
	end

	-- Bacon total counter + earned label
	if baconTotal > 0 then
		baconTotalLabel.Visible = true
		startCountUp(baconTotal - baconEarned, baconTotal)

		if baconEarned > 0 then
			local goCfg = CurrencyConfig.GAME_OVER
			baconEarnedLabel.Text = string.format(goCfg.FORMAT, baconEarned, CurrencyConfig.NAME)
			baconEarnedLabel.Visible = true
		else
			baconEarnedLabel.Visible = false
		end
	else
		baconTotalLabel.Visible = false
		baconEarnedLabel.Visible = false
	end

	screenGui.Enabled = true
end

--[[
	Sets the callback for when Play Again is triggered (button click or Space key).
	@param callback function - Called when play again is activated
]]
function GameOverUI.setOnPlayAgain(callback)
	onPlayAgainCallback = callback
end

--[[
	Hides the game over screen. Cancels any running count-up animation.
]]
function GameOverUI.hide()
	cancelCountUp()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	Cleans up the GameOverUI.
]]
function GameOverUI.destroy()
	cancelCountUp()
	onPlayAgainCallback = nil
	if viewportScaleConnection then
		viewportScaleConnection:Disconnect()
		viewportScaleConnection = nil
	end
	uiScaleInstance = nil
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return GameOverUI
