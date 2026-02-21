--[[
	CurrencyUI.luau

	Bacon currency counter displayed as a BillboardGui above the leaderboard.
	Visible during the READY state so the player sees their lifetime total.
	Hidden during gameplay to avoid distraction.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CurrencyManager = require(script.Parent.CurrencyManager)

local CurrencyUI = {}

local billboardGui = nil
local balanceLabel = nil
local updateConnection = nil
local leaderboardPart = nil
local leaderboardBillboardGui = nil
local baseBillboardSize = nil
local baseStudsOffset = nil

local function resolveLeaderboardBillboard()
	if leaderboardPart and leaderboardPart.Parent then
		if leaderboardBillboardGui
			and leaderboardBillboardGui.Parent == leaderboardPart
			and leaderboardBillboardGui:IsA("BillboardGui") then
			return
		end
	else
		leaderboardPart = nil
		leaderboardBillboardGui = nil
	end

	if not leaderboardPart then
		leaderboardPart = workspace:FindFirstChild(GameConfig.LEADERBOARD.PART.NAME)
	end

	if leaderboardPart then
		local candidate = leaderboardPart:FindFirstChild("LeaderboardBillboardGui")
		if candidate and candidate:IsA("BillboardGui") then
			leaderboardBillboardGui = candidate
		end
	end
end

local function getLeaderboardScaleAndHeight()
	local baseLeaderboardSize = GameConfig.LEADERBOARD.BILLBOARD.SIZE
	local baseWidth = math.max(baseLeaderboardSize.X.Scale, 0.001)
	local baseHeight = math.max(baseLeaderboardSize.Y.Scale, 0.001)
	local currentWidth = baseWidth
	local currentHeight = baseHeight

	if leaderboardBillboardGui and leaderboardBillboardGui.Parent then
		currentWidth = leaderboardBillboardGui.Size.X.Scale > 0 and leaderboardBillboardGui.Size.X.Scale or currentWidth
		currentHeight = leaderboardBillboardGui.Size.Y.Scale > 0 and leaderboardBillboardGui.Size.Y.Scale or currentHeight
	end

	local scaleX = currentWidth / baseWidth
	local scaleY = currentHeight / baseHeight
	local scale = math.max(0.1, math.min(scaleX, scaleY))

	return scale, currentHeight
end

local function applyAdaptiveLayout()
	if not billboardGui or not baseBillboardSize or not baseStudsOffset then
		return
	end

	resolveLeaderboardBillboard()

	local scale, leaderboardHeight = getLeaderboardScaleAndHeight()
	billboardGui.Size = UDim2.new(
		baseBillboardSize.X.Scale * scale,
		0,
		baseBillboardSize.Y.Scale * scale,
		0
	)

	-- Keep the counter attached to leaderboard top with a scaled vertical gap.
	local baseLeaderboardHeight = math.max(GameConfig.LEADERBOARD.BILLBOARD.SIZE.Y.Scale, 0.001)
	local baseTopY = baseLeaderboardHeight * 0.5
	local baseGapAboveTop = baseStudsOffset.Y - baseTopY
	local currentTopY = leaderboardHeight * 0.5
	billboardGui.StudsOffset = Vector3.new(
		baseStudsOffset.X * scale,
		currentTopY + (baseGapAboveTop * scale),
		baseStudsOffset.Z
	)
end

--[[
	Initializes the CurrencyUI. Creates a BillboardGui above the leaderboard Part.
]]
function CurrencyUI.init()
	local uiCfg = CurrencyConfig.UI

	-- Find the leaderboard Part (created by LeaderboardUI.init before this runs)
	leaderboardPart = workspace:FindFirstChild(GameConfig.LEADERBOARD.PART.NAME)
	if not leaderboardPart then
		warn("[CurrencyUI] Leaderboard Part not found - currency display disabled.")
		return
	end

	baseBillboardSize = UDim2.new(uiCfg.BILLBOARD_WIDTH, 0, uiCfg.BILLBOARD_HEIGHT, 0)
	baseStudsOffset = Vector3.new(0, uiCfg.BILLBOARD_Y_OFFSET, 0)

	-- BillboardGui positioned just above the leaderboard billboard.
	billboardGui = Instance.new("BillboardGui")
	billboardGui.Name = "CurrencyBillboardGui"
	billboardGui.Adornee = leaderboardPart
	billboardGui.Size = baseBillboardSize
	billboardGui.StudsOffset = baseStudsOffset
	billboardGui.MaxDistance = GameConfig.LEADERBOARD.BILLBOARD.MAX_DISTANCE
	billboardGui.AlwaysOnTop = false
	billboardGui.Enabled = false
	billboardGui.Parent = leaderboardPart

	balanceLabel = Instance.new("TextLabel")
	balanceLabel.Name = "BalanceLabel"
	balanceLabel.Size = UDim2.new(1, 0, 1, 0)
	balanceLabel.BackgroundTransparency = 1
	balanceLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, 0)
	balanceLabel.TextColor3 = uiCfg.TEXT_COLOR
	balanceLabel.TextScaled = true
	balanceLabel.Font = uiCfg.FONT
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Center
	balanceLabel.TextStrokeColor3 = uiCfg.STROKE_COLOR
	balanceLabel.TextStrokeTransparency = uiCfg.STROKE_TRANSPARENCY
	balanceLabel.Parent = billboardGui

	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MinTextSize = GameConfig.LEADERBOARD.TEXT_MIN_SIZE
	textConstraint.MaxTextSize = GameConfig.LEADERBOARD.TEXT_MAX_SIZE
	textConstraint.Parent = balanceLabel

	applyAdaptiveLayout()
end

--[[
	Starts the Heartbeat update loop to refresh the displayed balance.
]]
function CurrencyUI.start()
	if updateConnection then return end

	local uiCfg = CurrencyConfig.UI
	updateConnection = RunService.Heartbeat:Connect(function()
		applyAdaptiveLayout()
		if balanceLabel then
			balanceLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, CurrencyManager.getDisplayBalance())
		end
	end)
end

--[[
	Stops the update loop.
]]
function CurrencyUI.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Shows the currency UI.
]]
function CurrencyUI.show()
	if billboardGui then
		applyAdaptiveLayout()
		billboardGui.Enabled = true
	end
end

--[[
	Hides the currency UI.
]]
function CurrencyUI.hide()
	if billboardGui then
		billboardGui.Enabled = false
	end
end

--[[
	Cleans up the CurrencyUI.
]]
function CurrencyUI.destroy()
	CurrencyUI.stop()
	if billboardGui then
		billboardGui:Destroy()
		billboardGui = nil
	end
	leaderboardPart = nil
	leaderboardBillboardGui = nil
	baseBillboardSize = nil
	baseStudsOffset = nil
end

return CurrencyUI
