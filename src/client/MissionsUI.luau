--[[
	MissionsUI.luau

	Modal missions overlay that mirrors the shop modal lifecycle:
	init() -> show()/hide() -> destroy()

	Displays every mission (locked, in-progress, completed) sorted by
	progress closeness (% complete), with progress bars and reward details.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)

local MissionManager = require(script.Parent.MissionManager)

local MissionsUI = {}

local localPlayer = Players.LocalPlayer
local screenGui = nil
local onCloseCallback = nil
local latestState = nil

local listFrame = nil
local listLayout = nil
local summaryLabel = nil
local uiScaleInstance = nil
local viewportScaleConnection = nil
local canvasPositionConnection = nil
local isDestroyed = false
local bottomRubberbandTween = nil
local bottomRubberbandScheduled = false
local wasPastBottomRest = false

local UI = MissionConfig.UI
local BOTTOM_OVERSCROLL_SLIVER = 8
local BOTTOM_RUBBERBAND_DELAY = 0.05
local BOTTOM_RUBBERBAND_DURATION = 0.12

local updateListCanvasSize = nil

local function getCurrentUIScale()
	if not uiScaleInstance then
		return 1
	end
	return math.max(0.01, uiScaleInstance.Scale)
end

local function updateUIScale()
	if not uiScaleInstance then return end
	local viewportHeight = workspace.CurrentCamera.ViewportSize.Y
	local scale = math.clamp(viewportHeight / UI.REFERENCE_HEIGHT, UI.MIN_SCALE, UI.MAX_SCALE)
	uiScaleInstance.Scale = scale
	if updateListCanvasSize then
		updateListCanvasSize()
	end
end

local function missionPercent(mission)
	if mission.completed then
		return 1
	end

	local progress = mission.progress
	if progress and type(progress.percent) == "number" then
		return math.clamp(progress.percent, 0, 1)
	end

	return 0
end

local function missionStatus(mission)
	if mission.completed then
		return "Completed"
	end
	if mission.unlocked then
		return "In Progress"
	end
	return "Locked"
end

local function missionSortGroup(mission)
	-- Sort buckets:
	-- 1) In Progress
	-- 2) Locked
	-- 3) Completed
	if mission.completed then
		return 3
	end
	if mission.unlocked then
		return 1
	end
	return 2
end

local function rewardTextForMission(mission)
	local rewards = mission.rewards or {}
	local rewardParts = {}
	local baconIcon = CurrencyConfig.UI and CurrencyConfig.UI.ICON or CurrencyConfig.NAME

	for _, reward in ipairs(rewards) do
		if reward.type == "bacon" then
			table.insert(rewardParts, string.format("%d %s", reward.amount or 0, baconIcon))
		elseif reward.type == "shop_item" then
			local item = ShopConfig.getItem(reward.itemId)
			local name = if item and item.name then item.name else tostring(reward.itemId)
			table.insert(rewardParts, "Unlock " .. name)
		end
	end

	if #rewardParts == 0 then
		return "Reward: None"
	end

	return "Reward: " .. table.concat(rewardParts, " + ")
end

local function progressTextForMission(mission, percent)
	if mission.completed then
		return "Completed (100%)"
	end

	local progress = mission.progress
	local percentInt = math.floor(percent * 100 + 0.5)

	if progress then
		local current = math.floor(tonumber(progress.current) or 0)
		local target = math.max(1, math.floor(tonumber(progress.target) or 1))
		return string.format("Progress: %d / %d (%d%%)", current, target, percentInt)
	end

	return string.format("Progress: %d%%", percentInt)
end

local function clearCards()
	if not listFrame then return end
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function cancelBottomRubberband()
	if bottomRubberbandTween then
		bottomRubberbandTween:Cancel()
		bottomRubberbandTween = nil
	end
	bottomRubberbandScheduled = false
end

local function getBottomScrollBounds()
	if not listFrame then
		return 0, 0
	end

	local scale = getCurrentUIScale()
	local maxY = math.max(0, (listFrame.AbsoluteCanvasSize.Y - listFrame.AbsoluteWindowSize.Y) / scale)
	local restY = math.max(0, maxY - BOTTOM_OVERSCROLL_SLIVER)
	return maxY, restY
end

local function bounceBackFromBottomOverscroll()
	if not listFrame then return end
	local _, restY = getBottomScrollBounds()
	if listFrame.CanvasPosition.Y <= restY + 0.5 then
		return
	end

	if bottomRubberbandTween then
		bottomRubberbandTween:Cancel()
		bottomRubberbandTween = nil
	end

	bottomRubberbandTween = TweenService:Create(
		listFrame,
		TweenInfo.new(BOTTOM_RUBBERBAND_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CanvasPosition = Vector2.new(0, restY) }
	)
	bottomRubberbandTween.Completed:Connect(function()
		bottomRubberbandTween = nil
	end)
	bottomRubberbandTween:Play()
end

local function scheduleBottomRubberband()
	if bottomRubberbandScheduled then return end
	bottomRubberbandScheduled = true
	task.delay(BOTTOM_RUBBERBAND_DELAY, function()
		bottomRubberbandScheduled = false
		if isDestroyed or not listFrame then return end
		bounceBackFromBottomOverscroll()
	end)
end

local function onListCanvasPositionChanged()
	if not listFrame then return end
	local _, restY = getBottomScrollBounds()
	local pastBottomRest = listFrame.CanvasPosition.Y > restY + 0.5

	if pastBottomRest and not wasPastBottomRest then
		scheduleBottomRubberband()
	elseif not pastBottomRest then
		cancelBottomRubberband()
	end

	wasPastBottomRest = pastBottomRest
end

updateListCanvasSize = function()
	if not listFrame or not listLayout then return end

	-- AbsoluteContentSize is already scale-transformed by UIScale.
	-- Convert back to pre-scale UI units before assigning CanvasSize offsets.
	local scale = getCurrentUIScale()
	local unscaledContentHeight = listLayout.AbsoluteContentSize.Y / scale
	local canvasHeight = math.max(
		0,
		math.floor(unscaledContentHeight + UI.LIST_PADDING * 2 + BOTTOM_OVERSCROLL_SLIVER + 0.5)
	)

	listFrame.CanvasSize = UDim2.new(0, 0, 0, canvasHeight)

	task.defer(function()
		if isDestroyed or not listFrame then return end
		local _, restY = getBottomScrollBounds()
		if listFrame.CanvasPosition.Y > restY then
			listFrame.CanvasPosition = Vector2.new(0, restY)
		end
	end)
end

local function renderMissions()
	if not listFrame or not summaryLabel then return end

	local missions = {}
	if latestState and latestState.missions then
		for _, mission in ipairs(latestState.missions) do
			table.insert(missions, mission)
		end
	end

	table.sort(missions, function(a, b)
		local ga = missionSortGroup(a)
		local gb = missionSortGroup(b)
		if ga ~= gb then
			return ga < gb
		end

		local pa = missionPercent(a)
		local pb = missionPercent(b)
		if pa ~= pb then
			return pa > pb
		end
		return (a.order or 0) < (b.order or 0)
	end)

	local completedCount = 0
	for _, mission in ipairs(missions) do
		if mission.completed then
			completedCount += 1
		end
	end
	summaryLabel.Text = string.format(
		"%d / %d completed",
		completedCount,
		#missions
	)

	clearCards()

	if #missions == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyState"
		empty.Size = UDim2.new(1, -12, 0, 44)
		empty.BackgroundTransparency = 1
		empty.Text = "No missions available yet."
		empty.Font = Enum.Font.GothamBold
		empty.TextSize = 15
		empty.TextColor3 = Color3.fromRGB(220, 220, 220)
		empty.Parent = listFrame
		updateListCanvasSize()
		return
	end

	for _, mission in ipairs(missions) do
		local percent = missionPercent(mission)
		local status = missionStatus(mission)

		local card = Instance.new("Frame")
		card.Name = "Mission_" .. tostring(mission.id)
		card.Size = UDim2.new(1, -12, 0, UI.CARD_HEIGHT)
		card.BorderSizePixel = 0
		if status == "Completed" then
			card.BackgroundColor3 = UI.CARD_BG_COMPLETED
		elseif status == "Locked" then
			card.BackgroundColor3 = UI.CARD_BG_LOCKED
		else
			card.BackgroundColor3 = UI.CARD_BG_IN_PROGRESS
		end
		card.Parent = listFrame

		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UI.CARD_CORNER_RADIUS
		cardCorner.Parent = card

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(0.65, 0, 0, 24)
		title.Position = UDim2.new(0, 10, 0, 8)
		title.BackgroundTransparency = 1
		title.Text = mission.title or "Mission"
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Font = UI.TITLE_FONT_CARD
		title.TextSize = UI.TITLE_SIZE_CARD
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = card

		local statusLabel = Instance.new("TextLabel")
		statusLabel.Name = "Status"
		statusLabel.Size = UDim2.new(0, 110, 0, 22)
		statusLabel.Position = UDim2.new(1, -118, 0, 9)
		statusLabel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
		statusLabel.BackgroundTransparency = 0.3
		statusLabel.BorderSizePixel = 0
		statusLabel.Text = status
		statusLabel.Font = UI.STATUS_FONT
		statusLabel.TextSize = UI.STATUS_SIZE
		statusLabel.TextColor3 = Color3.fromRGB(245, 245, 245)
		statusLabel.Parent = card

		local statusCorner = Instance.new("UICorner")
		statusCorner.CornerRadius = UDim.new(0, 6)
		statusCorner.Parent = statusLabel

		local howLabel = Instance.new("TextLabel")
		howLabel.Name = "How"
		howLabel.Size = UDim2.new(1, -20, 0, 34)
		howLabel.Position = UDim2.new(0, 10, 0, 34)
		howLabel.BackgroundTransparency = 1
		howLabel.Text = "How: " .. (mission.description or "Complete this mission.")
		howLabel.TextXAlignment = Enum.TextXAlignment.Left
		howLabel.TextYAlignment = Enum.TextYAlignment.Top
		howLabel.Font = UI.DESC_FONT
		howLabel.TextSize = UI.DESC_SIZE
		howLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
		howLabel.TextWrapped = true
		howLabel.Parent = card

		local barBg = Instance.new("Frame")
		barBg.Name = "ProgressBarBg"
		barBg.Size = UDim2.new(1, -20, 0, UI.PROGRESS_BAR_HEIGHT)
		barBg.Position = UDim2.new(0, 10, 0, 74)
		barBg.BackgroundColor3 = UI.PROGRESS_BAR_BG
		barBg.BorderSizePixel = 0
		barBg.Parent = card

		local barBgCorner = Instance.new("UICorner")
		barBgCorner.CornerRadius = UDim.new(1, 0)
		barBgCorner.Parent = barBg

		local barFill = Instance.new("Frame")
		barFill.Name = "ProgressBarFill"
		barFill.Size = UDim2.new(percent, 0, 1, 0)
		barFill.BackgroundColor3 = UI.PROGRESS_BAR_FILL
		barFill.BorderSizePixel = 0
		barFill.Parent = barBg

		local barFillCorner = Instance.new("UICorner")
		barFillCorner.CornerRadius = UDim.new(1, 0)
		barFillCorner.Parent = barFill

		local progressLabel = Instance.new("TextLabel")
		progressLabel.Name = "ProgressText"
		progressLabel.Size = UDim2.new(1, -20, 0, 18)
		progressLabel.Position = UDim2.new(0, 10, 0, 88)
		progressLabel.BackgroundTransparency = 1
		progressLabel.Text = progressTextForMission(mission, percent)
		progressLabel.TextXAlignment = Enum.TextXAlignment.Left
		progressLabel.Font = UI.PROGRESS_FONT
		progressLabel.TextSize = UI.PROGRESS_SIZE
		progressLabel.TextColor3 = Color3.fromRGB(245, 220, 160)
		progressLabel.TextTruncate = Enum.TextTruncate.AtEnd
		progressLabel.Parent = card

		local rewardLabel = Instance.new("TextLabel")
		rewardLabel.Name = "Reward"
		rewardLabel.Size = UDim2.new(1, -20, 0, 18)
		rewardLabel.Position = UDim2.new(0, 10, 1, -22)
		rewardLabel.BackgroundTransparency = 1
		rewardLabel.Text = rewardTextForMission(mission)
		rewardLabel.TextXAlignment = Enum.TextXAlignment.Left
		rewardLabel.Font = UI.REWARD_FONT
		rewardLabel.TextSize = UI.REWARD_SIZE
		rewardLabel.TextColor3 = Color3.fromRGB(190, 255, 210)
		rewardLabel.TextTruncate = Enum.TextTruncate.AtEnd
		rewardLabel.Parent = card
	end

	updateListCanvasSize()
end

function MissionsUI.init()
	if screenGui then return end
	isDestroyed = false

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MissionsUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 11 -- above ShopUI
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = UI.OVERLAY_COLOR
	overlay.BackgroundTransparency = UI.OVERLAY_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.Active = true
	overlay.Parent = screenGui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, UI.CONTAINER_WIDTH, 0, UI.CONTAINER_HEIGHT)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundColor3 = UI.CONTAINER_BG_COLOR
	container.BackgroundTransparency = UI.CONTAINER_BG_TRANSPARENCY
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UI.CONTAINER_CORNER_RADIUS
	containerCorner.Parent = container

	uiScaleInstance = Instance.new("UIScale")
	uiScaleInstance.Parent = container
	updateUIScale()

	viewportScaleConnection = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateUIScale()
	end)

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, UI.HEADER_HEIGHT)
	header.BackgroundTransparency = 1
	header.Parent = container

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.75, 0, 1, 0)
	title.Position = UDim2.new(0, 15, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = UI.TITLE_TEXT
	title.Font = UI.TITLE_FONT
	title.TextSize = UI.TITLE_SIZE
	title.TextColor3 = UI.TITLE_COLOR
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextStrokeColor3 = UI.TITLE_STROKE_COLOR
	title.TextStrokeTransparency = UI.TITLE_STROKE_TRANSPARENCY
	title.Parent = header

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, UI.CLOSE_BUTTON_SIZE, 0, UI.CLOSE_BUTTON_SIZE)
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -10, 0.5, 0)
	closeBtn.BackgroundColor3 = UI.CLOSE_BUTTON_COLOR
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "X"
	closeBtn.Font = UI.CLOSE_BUTTON_FONT
	closeBtn.TextSize = 18
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Parent = header

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		MissionsUI.hide()
		if onCloseCallback then
			onCloseCallback()
		end
	end)

	summaryLabel = Instance.new("TextLabel")
	summaryLabel.Name = "Summary"
	summaryLabel.Size = UDim2.new(1, -20, 0, 20)
	summaryLabel.AnchorPoint = Vector2.new(0.5, 0)
	summaryLabel.Position = UDim2.new(0.52, 0, 0, UI.HEADER_HEIGHT + 2)
	summaryLabel.BackgroundTransparency = 1
	summaryLabel.Text = "Sorted by closeness"
	summaryLabel.Font = UI.SUMMARY_FONT
	summaryLabel.TextSize = UI.SUMMARY_SIZE
	summaryLabel.TextColor3 = UI.SUMMARY_COLOR
	summaryLabel.TextXAlignment = Enum.TextXAlignment.Left
	summaryLabel.Parent = container

	local listTop = UI.HEADER_HEIGHT + 26
	local listHeight = UI.CONTAINER_HEIGHT - listTop - 10

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "MissionList"
	listFrame.Size = UDim2.new(1, -20, 0, listHeight)
	listFrame.AnchorPoint = Vector2.new(0.5, 0)
	listFrame.Position = UDim2.new(0.5, 0, 0, listTop)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = UI.SCROLLBAR_THICKNESS
	listFrame.ScrollBarImageColor3 = UI.SCROLLBAR_COLOR
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	listFrame.ElasticBehavior = Enum.ElasticBehavior.Never
	listFrame.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, UI.LIST_PADDING)
	padding.PaddingBottom = UDim.new(0, UI.LIST_PADDING)
	padding.PaddingLeft = UDim.new(0, 0)
	padding.PaddingRight = UDim.new(0, 0)
	padding.Parent = listFrame

	listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, UI.LIST_PADDING)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		updateListCanvasSize()
	end)

	canvasPositionConnection = listFrame:GetPropertyChangedSignal("CanvasPosition"):Connect(onListCanvasPositionChanged)

	MissionManager.onStateChanged(function(newState)
		if isDestroyed then return end
		latestState = newState
		if screenGui and screenGui.Enabled then
			renderMissions()
		end
	end)
end

function MissionsUI.show()
	if not screenGui then return end
	latestState = MissionManager.getState()
	renderMissions()
	screenGui.Enabled = true
	MissionManager.requestState()
end

function MissionsUI.hide()
	if not screenGui then return end
	screenGui.Enabled = false
end

function MissionsUI.isOpen()
	return screenGui ~= nil and screenGui.Enabled
end

function MissionsUI.setOnClose(callback)
	onCloseCallback = callback
end

function MissionsUI.destroy()
	isDestroyed = true
	onCloseCallback = nil
	latestState = nil
	listFrame = nil
	listLayout = nil
	summaryLabel = nil
	wasPastBottomRest = false

	cancelBottomRubberband()

	if viewportScaleConnection then
		viewportScaleConnection:Disconnect()
		viewportScaleConnection = nil
	end

	if canvasPositionConnection then
		canvasPositionConnection:Disconnect()
		canvasPositionConnection = nil
	end
	uiScaleInstance = nil

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return MissionsUI
