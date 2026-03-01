--[[
	CurrencyUI.luau

	Bacon currency counter displayed as a BillboardGui above the leaderboard.
	Visible during the READY state so the player sees their lifetime total.
	Hidden during gameplay to avoid distraction.
]]

local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
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
local visualBalanceValue = nil
local countUpStartValue = nil
local countUpTargetValue = nil
local countUpStartTime = nil
local countUpDuration = nil

local function getBalanceCountUpDuration(delta)
	local baseDuration = tonumber(CurrencyConfig.CELEBRATION and CurrencyConfig.CELEBRATION.COUNT_UP_DURATION) or 1
	baseDuration = math.max(0.1, baseDuration)

	local scaled = baseDuration * math.clamp((tonumber(delta) or 0) / 40, 0.15, 1)
	return math.clamp(scaled, 0.1, baseDuration)
end

local function formatBalanceText(value)
	local uiCfg = CurrencyConfig.UI
	local safeValue = math.max(0, math.floor(tonumber(value) or 0))
	return string.format(uiCfg.FORMAT, uiCfg.ICON, safeValue)
end

local function clearCountUpState()
	countUpStartValue = nil
	countUpTargetValue = nil
	countUpStartTime = nil
	countUpDuration = nil
end

local function snapVisualBalance(value)
	visualBalanceValue = math.max(0, math.floor(tonumber(value) or 0))
	clearCountUpState()
end

local function getCurrentVisualBalanceRounded()
	return math.max(0, math.floor(tonumber(visualBalanceValue) or 0))
end

local function startBalanceCountUp(toValue)
	local target = math.max(0, math.floor(tonumber(toValue) or 0))
	local fromValue = getCurrentVisualBalanceRounded()
	if target <= fromValue then
		snapVisualBalance(target)
		return
	end

	countUpStartValue = fromValue
	countUpTargetValue = target
	countUpStartTime = tick()
	countUpDuration = getBalanceCountUpDuration(target - fromValue)
	visualBalanceValue = fromValue
end

local function updateVisualBalanceToTarget(targetBalance, canAnimate)
	local target = math.max(0, math.floor(tonumber(targetBalance) or 0))

	if visualBalanceValue == nil then
		snapVisualBalance(target)
		return getCurrentVisualBalanceRounded()
	end

	if canAnimate ~= true then
		snapVisualBalance(target)
		return getCurrentVisualBalanceRounded()
	end

	if countUpTargetValue and countUpStartTime and countUpDuration then
		if target < countUpTargetValue then
			snapVisualBalance(target)
			return getCurrentVisualBalanceRounded()
		end
		if target > countUpTargetValue then
			startBalanceCountUp(target)
		end
	end

	if countUpTargetValue and countUpStartTime and countUpDuration then
		local duration = math.max(0.001, countUpDuration)
		local alpha = math.clamp((tick() - countUpStartTime) / duration, 0, 1)
		local fromValue = countUpStartValue or getCurrentVisualBalanceRounded()
		local toValue = countUpTargetValue or target
		local nextValue = math.floor(fromValue + (toValue - fromValue) * alpha)
		visualBalanceValue = math.clamp(nextValue, fromValue, toValue)

		if alpha >= 1 then
			visualBalanceValue = toValue
			clearCountUpState()
		end

		return getCurrentVisualBalanceRounded()
	end

	local currentRounded = getCurrentVisualBalanceRounded()
	if target > currentRounded then
		startBalanceCountUp(target)
		return getCurrentVisualBalanceRounded()
	end
	if target < currentRounded then
		snapVisualBalance(target)
		return getCurrentVisualBalanceRounded()
	end

	visualBalanceValue = target
	return target
end

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

	updateConnection = RunService.Heartbeat:Connect(function()
		applyAdaptiveLayout()
		if balanceLabel then
			local targetBalance = CurrencyManager.getDisplayBalance()
			local canAnimate = billboardGui ~= nil and billboardGui.Enabled == true
			local displayedBalance = updateVisualBalanceToTarget(targetBalance, canAnimate)
			balanceLabel.Text = formatBalanceText(displayedBalance)
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
		snapVisualBalance(CurrencyManager.getDisplayBalance())
		if balanceLabel then
			balanceLabel.Text = formatBalanceText(visualBalanceValue)
		end
		billboardGui.Enabled = true
	end
end

--[[
	Hides the currency UI.
]]
function CurrencyUI.hide()
	if billboardGui then
		snapVisualBalance(CurrencyManager.getDisplayBalance())
		billboardGui.Enabled = false
	end
end

--[[
	Returns the AbsolutePosition and AbsoluteSize of the balance label.
	Useful for screen-space fly animations targeting the bacon counter.
	@return Vector2?, Vector2?
]]
function CurrencyUI.getBalanceLabelPosition()
	if not balanceLabel then
		return nil, nil
	end
	return balanceLabel.AbsolutePosition, balanceLabel.AbsoluteSize
end

--[[
	Returns the projected screen rect of the bacon counter billboard in ScreenGui
	coordinates (i.e. adjusted for top inset, suitable for IgnoreGuiInset=false UIs).
	Use this for animations that need a stable target across resolutions/aspect ratios.
	@return Vector2?, Vector2?
]]
function CurrencyUI.getBalanceBillboardScreenRect()
	if not billboardGui or not billboardGui.Enabled then
		return nil, nil
	end

	local adornee = billboardGui.Adornee
	local camera = workspace.CurrentCamera
	if not adornee or not camera then
		return nil, nil
	end

	local worldPos = adornee.Position + billboardGui.StudsOffset
	local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
	if not onScreen or screenPos.Z <= 0 then
		return nil, nil
	end

	local halfFOV = math.rad(camera.FieldOfView / 2)
	local pixelsPerStud = camera.ViewportSize.Y / (2 * screenPos.Z * math.tan(halfFOV))
	local billboardSize = billboardGui.Size
	local widthPx = math.max(1, billboardSize.X.Scale * pixelsPerStud)
	local heightPx = math.max(1, billboardSize.Y.Scale * pixelsPerStud)

	local guiInset = GuiService:GetGuiInset()
	local topLeft = Vector2.new(
		screenPos.X - widthPx * 0.5 - guiInset.X,
		screenPos.Y - heightPx * 0.5 - guiInset.Y
	)

	return topLeft, Vector2.new(widthPx, heightPx)
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
	visualBalanceValue = nil
	clearCountUpState()
end

return CurrencyUI
