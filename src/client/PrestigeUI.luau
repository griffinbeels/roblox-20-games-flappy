
--[[
	PrestigeUI.luau

	Modal prestige UI lifecycle:
	init() -> show() / hide() -> destroy()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)
local AnalyticsConfig = require(ReplicatedStorage.Shared.AnalyticsConfig)
local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)

local PrestigeManager = require(script.Parent.PrestigeManager)
local MissionManager = require(script.Parent.MissionManager)
local Analytics = require(script.Parent.Analytics)

local PrestigeUI = {}

local localPlayer = Players.LocalPlayer
local UI = PrestigeConfig.UI
local MissionUIStyle = MissionConfig.UI

local screenGui = nil
local onCloseCallback = nil
local isDestroyed = false

local uiScaleInstance = nil
local viewportScaleConnection = nil

local latestState = nil
local latestMissionState = nil
local draftTuning = nil

local progressionLabel = nil
local requirementLabel = nil
local readyLabel = nil
local thresholdsLabel = nil
local progressFrame = nil
local savedLabel = nil
local currentLabel = nil
local unsavedLabel = nil
local feedbackLabel = nil
local attemptButton = nil
local attemptButtonPulseTween = nil
local firstPrestigeMissionOverlay = nil
local firstPrestigeMissionTitleLabel = nil
local firstPrestigeMissionRequirementLabel = nil
local firstPrestigeMissionProgressFrame = nil
local firstPrestigeMissionFooterLabel = nil
local firstPrestigeMissionUnlockButton = nil
local prePrestigeTuningMenuUnlocked = false

local sliders = {}
local sliderConnections = {}
local activeSlider = nil
local changedWhileDragging = false
local prestigeMissionRedeemingIds = {}

local function trackSliderConnection(connection)
	table.insert(sliderConnections, connection)
	return connection
end

local function disconnectSliderConnections()
	for _, connection in ipairs(sliderConnections) do
		connection:Disconnect()
	end
	table.clear(sliderConnections)
	activeSlider = nil
	changedWhileDragging = false
end

local function updateUIScale()
	if not uiScaleInstance then
		return
	end

	local viewportHeight = workspace.CurrentCamera.ViewportSize.Y
	local scale = math.clamp(viewportHeight / UI.REFERENCE_HEIGHT, UI.MIN_SCALE, UI.MAX_SCALE)
	uiScaleInstance.Scale = scale
end

local function formatSpeed(value)
	return string.format("%.2f", tonumber(value) or 0)
end

local function formatGravity(value)
	return string.format("%d", math.floor((tonumber(value) or 0) + 0.5))
end

local function formatJumpPower(value)
	return string.format("%.2f", tonumber(value) or 0)
end

local function setFeedback(text, color)
	if not feedbackLabel then
		return
	end

	feedbackLabel.Text = text or ""
	feedbackLabel.TextColor3 = color or Color3.fromRGB(225, 225, 225)
end

local function getDisabledButtonColor(baseColor)
	if typeof(baseColor) ~= "Color3" then
		return Color3.fromRGB(70, 70, 80)
	end

	return Color3.new(
		math.clamp(baseColor.R * 0.45, 0, 1),
		math.clamp(baseColor.G * 0.45, 0, 1),
		math.clamp(baseColor.B * 0.45, 0, 1)
	)
end

local function setButtonEnabledState(button, enabled, baseColor)
	if not button then
		return
	end

	local isEnabled = enabled == true
	button.Active = isEnabled
	button.Selectable = isEnabled
	button.AutoButtonColor = isEnabled
	button.BackgroundColor3 = if isEnabled then baseColor else getDisabledButtonColor(baseColor)
	button.BackgroundTransparency = if isEnabled then 0 else 0.18
	button.TextTransparency = if isEnabled then 0 else 0.2
end

local function setAttemptButtonPulseEnabled(enabled)
	if attemptButtonPulseTween then
		attemptButtonPulseTween:Cancel()
		attemptButtonPulseTween = nil
	end

	if not attemptButton then
		return
	end

	local isButtonEnabled = attemptButton.Active == true
	attemptButton.BackgroundTransparency = if isButtonEnabled then 0 else 0.18
	attemptButton.TextTransparency = if isButtonEnabled then 0 else 0.2

	if enabled ~= true then
		return
	end

	attemptButtonPulseTween = TweenService:Create(
		attemptButton,
		TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{
			BackgroundTransparency = 0.2,
		}
	)
	attemptButtonPulseTween:Play()
end

local function clearProgressRows()
	if not progressFrame then
		return
	end

	for _, child in ipairs(progressFrame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if progressFrame:IsA("ScrollingFrame") then
		progressFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		progressFrame.CanvasPosition = Vector2.new(0, 0)
	end
end

local function clearFirstPrestigeMissionRows()
	if not firstPrestigeMissionProgressFrame then
		return
	end

	for _, child in ipairs(firstPrestigeMissionProgressFrame:GetChildren()) do
		if child:IsA("GuiObject") and child.Name == "MissionRow" then
			child:Destroy()
		end
	end

	if firstPrestigeMissionProgressFrame:IsA("ScrollingFrame") then
		firstPrestigeMissionProgressFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		firstPrestigeMissionProgressFrame.CanvasPosition = Vector2.new(0, 0)
	end
end

local function getPrestigeMissionProgressSummaryFromRows(rows)
	local progressRows = if type(rows) == "table" then rows else {}
	if #progressRows <= 0 then
		return {
			percent = 0,
			progressText = "Progress: 0%",
		}
	end

	if #progressRows == 1 then
		local row = progressRows[1]
		local percent = math.clamp(tonumber(row and row.percent) or 0, 0, 1)
		local current = math.floor(tonumber(row and row.current) or 0)
		local target = math.max(1, math.floor(tonumber(row and row.target) or 1))
		local percentInt = math.floor(percent * 100 + 0.5)
		return {
			percent = percent,
			progressText = string.format("Progress: %d / %d (%d%%)", current, target, percentInt),
		}
	end

	local sumPercent = 0
	local completedObjectives = 0
	for _, row in ipairs(progressRows) do
		local p = math.clamp(tonumber(row and row.percent) or 0, 0, 1)
		sumPercent += p
		if p >= 1 then
			completedObjectives += 1
		end
	end

	local percent = math.clamp(sumPercent / math.max(1, #progressRows), 0, 1)
	local percentInt = math.floor(percent * 100 + 0.5)
	return {
		percent = percent,
		progressText = string.format("Progress: %d / %d objectives (%d%%)", completedObjectives, #progressRows, percentInt),
	}
end

local function getPrestigeMissionRewardText(nextLevel)
	local rewardParts = {}
	local levelNumber = math.max(1, math.floor(tonumber(type(nextLevel) == "table" and nextLevel.level or 1) or 1))
	table.insert(rewardParts, string.format("Prestige %d", levelNumber))

	local currentLevel = math.max(0, levelNumber - 1)
	local currentBand = PrestigeConfig.getTuningBand(currentLevel)
	local unlockedBand = PrestigeConfig.getTuningBand(levelNumber)
	local currentSpeedRange = type(currentBand) == "table" and currentBand.speedCapMultiplier or nil
	local unlockedSpeedRange = type(unlockedBand) == "table" and unlockedBand.speedCapMultiplier or nil
	local currentSpeedMax = tonumber(currentSpeedRange and (currentSpeedRange.max or currentSpeedRange.min))
	local unlockedSpeedMax = tonumber(unlockedSpeedRange and (unlockedSpeedRange.max or unlockedSpeedRange.min))

	if currentSpeedMax and unlockedSpeedMax and unlockedSpeedMax > currentSpeedMax + 0.0001 then
		table.insert(rewardParts, string.format("Speed Ramp cap %.2fx", unlockedSpeedMax))
	end

	return "Reward: " .. table.concat(rewardParts, " + ")
end

local function getPrestigeRewardLevelFromRewards(rewards)
	if type(rewards) ~= "table" then
		return nil
	end

	for _, reward in ipairs(rewards) do
		if type(reward) == "table" and reward.type == "prestige_level" then
			local level = tonumber(reward.level)
			if level then
				return math.max(1, math.floor(level))
			end
		end
	end

	return nil
end

local function filterPrestigeMissionStateEntriesForNextLevel(missions, nextLevelNumber)
	if type(missions) ~= "table" then
		return {}
	end

	local targetLevel = math.max(1, math.floor(tonumber(nextLevelNumber) or 1))
	local filtered = {}
	for _, mission in ipairs(missions) do
		local rewardLevel = getPrestigeRewardLevelFromRewards(type(mission) == "table" and mission.rewards or nil)
		if rewardLevel == nil or rewardLevel == targetLevel then
			table.insert(filtered, mission)
		end
	end
	return filtered
end

local function prestigeMissionPercentFromMissionState(mission)
	if type(mission) ~= "table" then
		return 0
	end
	if mission.completed == true then
		return 1
	end

	local progress = mission.progress
	if type(progress) == "table" and type(progress.percent) == "number" then
		return math.clamp(progress.percent, 0, 1)
	end
	return 0
end

local function prestigeMissionProgressRowsFromMissionState(mission)
	local progress = type(mission) == "table" and mission.progress or nil
	if type(progress) ~= "table" then
		return {}
	end

	if type(progress.rows) == "table" and #progress.rows > 0 then
		return progress.rows
	end

	return {
		{
			label = tostring(mission and mission.title or "Requirement"),
			current = tonumber(progress.current) or 0,
			target = tonumber(progress.target) or 1,
			percent = tonumber(progress.percent) or 0,
		},
	}
end

local function prestigeMissionProgressTextFromMissionState(mission)
	if type(mission) ~= "table" then
		return "Progress: 0%"
	end
	if mission.canRedeem == true then
		return "Ready to complete!"
	end
	if mission.completed == true then
		return "Completed (100%)"
	end

	local summary = getPrestigeMissionProgressSummaryFromRows(prestigeMissionProgressRowsFromMissionState(mission))
	return summary.progressText
end

local function prestigeMissionStatusSortBucket(mission)
	if type(mission) ~= "table" then
		return 3
	end
	if mission.canRedeem == true then
		return 0 -- completed and ready to claim
	end
	if mission.completed == true then
		return 2 -- completed and already claimed
	end
	return 1 -- in progress / locked
end

local function sortPrestigeMissionStateMissions(missions)
	table.sort(missions, function(a, b)
		local ga = prestigeMissionStatusSortBucket(a)
		local gb = prestigeMissionStatusSortBucket(b)
		if ga ~= gb then
			return ga < gb
		end

		if ga == 1 then
			local pa = prestigeMissionPercentFromMissionState(a)
			local pb = prestigeMissionPercentFromMissionState(b)
			if pa ~= pb then
				return pa > pb
			end
		end

		return (a.order or 0) < (b.order or 0)
	end)
end

local function buildPrestigeMissionCardEntries(state)
	if type(state) ~= "table" then
		return {}
	end

	local nextLevel = state.nextLevel
	if type(nextLevel) ~= "table" then
		return {}
	end

	local progression = state.progression or {}
	local currentLevel = math.max(0, math.floor(tonumber(progression.level) or 0))
	local rewardText = getPrestigeMissionRewardText(nextLevel)

	local missionStateEntries = filterPrestigeMissionStateEntriesForNextLevel(
		MissionManager.getPrestigeMissions(latestMissionState),
		nextLevel.level
	)
	if #missionStateEntries > 0 then
		sortPrestigeMissionStateMissions(missionStateEntries)

		local entries = table.create(#missionStateEntries)
		for _, mission in ipairs(missionStateEntries) do
			local rows = prestigeMissionProgressRowsFromMissionState(mission)
			local summary = getPrestigeMissionProgressSummaryFromRows(rows)
			local canComplete = mission.canRedeem == true
			local isCompleted = mission.completed == true
			local isBusy = canComplete and prestigeMissionRedeemingIds[tostring(mission.id)] == true
			local statusText = "In Progress"
			if canComplete then
				statusText = if isBusy then "Completing..." else "Complete"
			elseif isCompleted then
				statusText = "Completed"
			elseif mission.unlocked ~= true then
				statusText = "Locked"
			end

			table.insert(entries, {
				missionId = tostring(mission.id or ""),
				title = tostring(mission.title or (nextLevel.title or "Prestige Mission")),
				description = tostring(mission.description or nextLevel.requirementText or "Complete this mission."),
				percent = if canComplete then 1 else summary.percent,
				progressText = prestigeMissionProgressTextFromMissionState(mission),
				statusText = statusText,
				completed = isCompleted,
				rewardText = rewardText,
				canComplete = canComplete,
				isActionBusy = isBusy,
			})
		end
		return entries
	end

	local progressRows = if type(nextLevel.progress) == "table" then nextLevel.progress else {}

	local missionDefs = nil
	if type(PrestigeConfig.getNextPrestigeMissions) == "function" then
		local ok, result = pcall(PrestigeConfig.getNextPrestigeMissions, currentLevel)
		if ok and type(result) == "table" then
			missionDefs = result
		end
	end

	if type(missionDefs) == "table" and #missionDefs > 1 and #missionDefs == #progressRows then
		local entries = table.create(#missionDefs)
		for index, missionDef in ipairs(missionDefs) do
			local row = progressRows[index]
			local summary = getPrestigeMissionProgressSummaryFromRows({ row })
			local rowPercent = math.clamp(tonumber(row and row.percent) or 0, 0, 1)
			table.insert(entries, {
				title = tostring((type(missionDef) == "table" and missionDef.title) or (nextLevel.title or "Prestige Mission")),
				description = tostring((type(missionDef) == "table" and missionDef.description) or (nextLevel.requirementText or "Complete this mission.")),
				percent = summary.percent,
				progressText = summary.progressText,
				statusText = if rowPercent >= 1 then "Completed" else "In Progress",
				completed = rowPercent >= 1,
				rewardText = rewardText,
				canComplete = false,
			})
		end
		return entries
	end

	local summary = getPrestigeMissionProgressSummaryFromRows(progressRows)
	local singleMission = if type(missionDefs) == "table" then missionDefs[1] else nil
	return {
		{
			title = tostring((type(singleMission) == "table" and singleMission.title) or (nextLevel.title or "Prestige Mission")),
			description = tostring((type(singleMission) == "table" and singleMission.description) or (nextLevel.requirementText or "Complete this mission.")),
			percent = summary.percent,
			progressText = summary.progressText,
			statusText = if nextLevel.unlocked == true then "Completed" else "In Progress",
			completed = nextLevel.unlocked == true,
			rewardText = rewardText,
			canComplete = false,
		},
	}
end

local function renderPrestigeMissionCards(frame, entries, zIndexBase, options)
	if not frame then
		return 0
	end

	local opts = if type(options) == "table" then options else {}
	local baseZ = math.max(1, math.floor(tonumber(zIndexBase) or 1))
	local cardHeight = tonumber(MissionUIStyle.CARD_HEIGHT) or 126
	local cardSpacing = 8
	local yOffset = 0

	for _, entry in ipairs(entries or {}) do
		local percent = math.clamp(tonumber(entry and entry.percent) or 0, 0, 1)
		local completed = entry and entry.completed == true

		local card = Instance.new("Frame")
		card.Name = "MissionRow"
		card.Size = UDim2.new(1, -10, 0, cardHeight)
		card.Position = UDim2.new(0, 0, 0, yOffset)
		card.BorderSizePixel = 0
		card.BackgroundColor3 = if completed
			then (MissionUIStyle.CARD_BG_COMPLETED or Color3.fromRGB(48, 76, 58))
			else (MissionUIStyle.CARD_BG_IN_PROGRESS or Color3.fromRGB(52, 60, 72))
		card.ZIndex = baseZ
		card.Parent = frame

		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = MissionUIStyle.CARD_CORNER_RADIUS or UDim.new(0, 8)
		cardCorner.Parent = card

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(0.65, 0, 0, 24)
		title.Position = UDim2.new(0, 10, 0, 8)
		title.BackgroundTransparency = 1
		title.Text = tostring((entry and entry.title) or "Prestige Mission")
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Font = MissionUIStyle.TITLE_FONT_CARD or UI.TEXT_BOLD_FONT
		title.TextSize = tonumber(MissionUIStyle.TITLE_SIZE_CARD) or 17
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.ZIndex = baseZ + 1
		title.Parent = card

		local hasAction = entry and entry.canComplete == true and type(opts.onComplete) == "function"
		local statusLabel = if hasAction then Instance.new("TextButton") else Instance.new("TextLabel")
		statusLabel.Name = "Status"
		statusLabel.Size = UDim2.new(0, 110, 0, 22)
		statusLabel.Position = UDim2.new(1, -118, 0, 9)
		statusLabel.BorderSizePixel = 0
		statusLabel.Text = tostring((entry and entry.statusText) or "In Progress")
		statusLabel.Font = MissionUIStyle.STATUS_FONT or UI.TEXT_BOLD_FONT
		statusLabel.TextSize = tonumber(MissionUIStyle.STATUS_SIZE) or 12
		statusLabel.TextColor3 = Color3.fromRGB(245, 245, 245)
		statusLabel.ZIndex = baseZ + 1
		if hasAction then
			local isBusy = entry and entry.isActionBusy == true
			statusLabel.BackgroundColor3 = if isBusy then Color3.fromRGB(58, 105, 67) else Color3.fromRGB(52, 176, 79)
			statusLabel.BackgroundTransparency = if isBusy then 0.12 else 0.02
			statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			statusLabel.AutoButtonColor = not isBusy
			statusLabel.Active = not isBusy
		else
			statusLabel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
			statusLabel.BackgroundTransparency = 0.3
		end
		statusLabel.Parent = card

		local statusCorner = Instance.new("UICorner")
		statusCorner.CornerRadius = UDim.new(0, 6)
		statusCorner.Parent = statusLabel

		if hasAction then
			statusLabel.Activated:Connect(function()
				if isDestroyed then
					return
				end
				opts.onComplete(entry)
			end)
		end

		local howLabel = Instance.new("TextLabel")
		howLabel.Name = "How"
		howLabel.Size = UDim2.new(1, -20, 0, 34)
		howLabel.Position = UDim2.new(0, 10, 0, 34)
		howLabel.BackgroundTransparency = 1
		howLabel.Text = "How: " .. tostring((entry and entry.description) or "Complete this mission.")
		howLabel.TextXAlignment = Enum.TextXAlignment.Left
		howLabel.TextYAlignment = Enum.TextYAlignment.Top
		howLabel.Font = MissionUIStyle.DESC_FONT or UI.TEXT_FONT
		howLabel.TextSize = tonumber(MissionUIStyle.DESC_SIZE) or UI.BODY_TEXT_SIZE
		howLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
		howLabel.TextWrapped = true
		howLabel.ZIndex = baseZ + 1
		howLabel.Parent = card

		local barBg = Instance.new("Frame")
		barBg.Name = "ProgressBarBg"
		barBg.Size = UDim2.new(1, -20, 0, tonumber(MissionUIStyle.PROGRESS_BAR_HEIGHT) or 10)
		barBg.Position = UDim2.new(0, 10, 0, 74)
		barBg.BackgroundColor3 = MissionUIStyle.PROGRESS_BAR_BG or Color3.fromRGB(30, 30, 30)
		barBg.BorderSizePixel = 0
		barBg.ZIndex = baseZ + 1
		barBg.Parent = card

		local barBgCorner = Instance.new("UICorner")
		barBgCorner.CornerRadius = UDim.new(1, 0)
		barBgCorner.Parent = barBg

		local barFill = Instance.new("Frame")
		barFill.Name = "ProgressBarFill"
		barFill.Size = UDim2.new(percent, 0, 1, 0)
		barFill.BackgroundColor3 = MissionUIStyle.PROGRESS_BAR_FILL or Color3.fromRGB(255, 200, 90)
		barFill.BorderSizePixel = 0
		barFill.ZIndex = baseZ + 2
		barFill.Parent = barBg

		local barFillCorner = Instance.new("UICorner")
		barFillCorner.CornerRadius = UDim.new(1, 0)
		barFillCorner.Parent = barFill

		local progressLabel = Instance.new("TextLabel")
		progressLabel.Name = "ProgressText"
		progressLabel.Size = UDim2.new(1, -20, 0, 18)
		progressLabel.Position = UDim2.new(0, 10, 0, 88)
		progressLabel.BackgroundTransparency = 1
		progressLabel.Text = tostring((entry and entry.progressText) or "Progress: 0%")
		progressLabel.TextXAlignment = Enum.TextXAlignment.Left
		progressLabel.Font = MissionUIStyle.PROGRESS_FONT or UI.TEXT_BOLD_FONT
		progressLabel.TextSize = tonumber(MissionUIStyle.PROGRESS_SIZE) or UI.SMALL_TEXT_SIZE
		progressLabel.TextColor3 = Color3.fromRGB(245, 220, 160)
		progressLabel.TextTruncate = Enum.TextTruncate.AtEnd
		progressLabel.ZIndex = baseZ + 1
		progressLabel.Parent = card

		local rewardLabel = Instance.new("TextLabel")
		rewardLabel.Name = "Reward"
		rewardLabel.Size = UDim2.new(1, -20, 0, 18)
		rewardLabel.Position = UDim2.new(0, 10, 1, -22)
		rewardLabel.BackgroundTransparency = 1
		rewardLabel.Text = tostring((entry and entry.rewardText) or "Reward: None")
		rewardLabel.TextXAlignment = Enum.TextXAlignment.Left
		rewardLabel.Font = MissionUIStyle.REWARD_FONT or UI.TEXT_BOLD_FONT
		rewardLabel.TextSize = tonumber(MissionUIStyle.REWARD_SIZE) or UI.SMALL_TEXT_SIZE
		rewardLabel.TextColor3 = Color3.fromRGB(190, 255, 210)
		rewardLabel.TextTruncate = Enum.TextTruncate.AtEnd
		rewardLabel.ZIndex = baseZ + 1
		rewardLabel.Parent = card

		yOffset += cardHeight + cardSpacing
	end

	local contentHeight = math.max(0, yOffset - cardSpacing)
	if frame:IsA("ScrollingFrame") then
		frame.CanvasSize = UDim2.new(0, 0, 0, contentHeight)
		frame.CanvasPosition = Vector2.new(0, 0)
	end

	return contentHeight
end

local function getFirstPrestigeMissionGateState(state)
	if type(state) ~= "table" then
		return nil
	end

	local progression = state.progression or {}
	local currentLevel = math.max(0, math.floor(tonumber(progression.level) or 0))
	if currentLevel ~= 0 then
		return nil
	end

	local nextLevel = state.nextLevel
	if type(nextLevel) ~= "table" then
		return nil
	end

	if math.max(0, math.floor(tonumber(nextLevel.level) or 0)) ~= 1 then
		return nil
	end

	local missionComplete = nextLevel.unlocked == true
	local tuningLockedByGate = missionComplete and not prePrestigeTuningMenuUnlocked

	return {
		nextLevel = nextLevel,
		missionComplete = missionComplete,
		tuningLockedByGate = tuningLockedByGate,
		shouldShowOverlay = (not missionComplete) or tuningLockedByGate,
	}
end

local function renderFirstPrestigeMissionOverlay()
	if not firstPrestigeMissionOverlay then
		return
	end

	local gateState = getFirstPrestigeMissionGateState(latestState)
	local shouldShow = gateState ~= nil and gateState.shouldShowOverlay == true
	firstPrestigeMissionOverlay.Visible = shouldShow
	if not shouldShow then
		return
	end

	local nextLevel = gateState and gateState.nextLevel or (latestState and latestState.nextLevel or nil)
	local missionTitle = "First Prestige Mission"
	if type(nextLevel) == "table" and nextLevel.title then
		missionTitle = tostring(nextLevel.title) .. " Mission"
	end
	if firstPrestigeMissionTitleLabel then
		firstPrestigeMissionTitleLabel.Text = missionTitle
	end

	if firstPrestigeMissionRequirementLabel then
		firstPrestigeMissionRequirementLabel.Text = tostring(
			(type(nextLevel) == "table" and nextLevel.requirementText)
				or "Complete the first prestige mission to unlock prestige tuning."
		)
	end

	if firstPrestigeMissionUnlockButton then
		local canUnlock = gateState ~= nil and gateState.missionComplete == true and gateState.tuningLockedByGate == true
		firstPrestigeMissionUnlockButton.Visible = canUnlock
		setButtonEnabledState(firstPrestigeMissionUnlockButton, canUnlock, UI.BUTTON_PRIMARY)
	end

	clearFirstPrestigeMissionRows()

	local contentHeight = 0
	if firstPrestigeMissionProgressFrame and type(nextLevel) == "table" then
		contentHeight = renderPrestigeMissionCards(firstPrestigeMissionProgressFrame, buildPrestigeMissionCardEntries(latestState), 22)
	end

	if firstPrestigeMissionFooterLabel then
		if gateState ~= nil and gateState.missionComplete == true and gateState.tuningLockedByGate == true then
			firstPrestigeMissionFooterLabel.Text = "Mission complete. Click UNLOCK PRESTIGE TUNING to promote to Prestige 1 and open the full prestige tuning menu."
		else
			firstPrestigeMissionFooterLabel.Text = if contentHeight > 0
				then "Complete the mission requirements above to unlock the full prestige tuning menu."
				else "Complete the first prestige mission to unlock the full prestige tuning menu."
		end
	end
end

local function ensureDraft(forceReset)
	local selected = latestState and latestState.tuning and latestState.tuning.selected
	if not selected then
		return
	end

	if forceReset or not draftTuning then
		draftTuning = RuntimeTuning.cloneTuning(selected)
		return
	end

	local limits = latestState and latestState.tuning and latestState.tuning.limits
	draftTuning = RuntimeTuning.clampTuning(draftTuning, limits)
end

local function quantize(value, step, minValue)
	if not step or step <= 0 then
		return value
	end
	local base = minValue or 0
	local snappedSteps = math.floor(((value - base) / step) + 0.5)
	return base + snappedSteps * step
end

local function clampAndQuantize(value, minValue, maxValue, step)
	local clamped = math.clamp(value, minValue, maxValue)
	local snapped = quantize(clamped, step, minValue)
	return math.clamp(snapped, minValue, maxValue)
end

local function valueToAlpha(value, minValue, maxValue)
	if maxValue <= minValue then
		return 0
	end
	return math.clamp((value - minValue) / (maxValue - minValue), 0, 1)
end

local function getDefinedBandLevels()
	if type(PrestigeConfig.getDefinedTuningBandLevels) == "function" then
		return PrestigeConfig.getDefinedTuningBandLevels()
	end

	local levels = {}
	for bandLevel in pairs(PrestigeConfig.TUNING_BANDS or {}) do
		if type(bandLevel) == "number" then
			table.insert(levels, math.floor(bandLevel))
		end
	end
	table.sort(levels)
	return levels
end

local function buildMarkerLevels(sliderKey, currentLevel)
	local levels = {}
	local seen = {}

	local function addLevel(level)
		if type(level) ~= "number" then
			return
		end

		local normalized = math.max(0, math.floor(level))
		if seen[normalized] then
			return
		end

		seen[normalized] = true
		table.insert(levels, normalized)
	end

	addLevel(0)
	local markerSourceLevels = nil
	if type(PrestigeConfig.getTuningBandChangeLevelsForKey) == "function" and type(sliderKey) == "string" then
		markerSourceLevels = PrestigeConfig.getTuningBandChangeLevelsForKey(sliderKey)
	end
	if type(markerSourceLevels) ~= "table" then
		markerSourceLevels = getDefinedBandLevels()
	end

	for _, bandLevel in ipairs(markerSourceLevels) do
		addLevel(bandLevel)
	end
	local highestMarkerLevel = markerSourceLevels[#markerSourceLevels]
	if type(currentLevel) == "number" and (#levels == 0 or currentLevel > (tonumber(highestMarkerLevel) or -1)) then
		addLevel(currentLevel)
	end

	table.sort(levels)
	return levels
end

local function markerSignature(levels)
	local parts = table.create(#levels)
	for i, level in ipairs(levels) do
		parts[i] = tostring(level)
	end
	return table.concat(parts, ",")
end

local function rebuildSliderMarkers(slider, levels)
	if markerSignature(levels) == slider.markerSignature then
		return
	end

	for _, marker in ipairs(slider.markers) do
		if marker.line then
			marker.line:Destroy()
		end
		if marker.label then
			marker.label:Destroy()
		end
	end
	table.clear(slider.markers)

	for _, level in ipairs(levels) do
		local markerLine = Instance.new("Frame")
		markerLine.Name = string.format("P%dLine", level)
		markerLine.Size = UDim2.new(0, 2, 0, 10)
		markerLine.AnchorPoint = Vector2.new(0.5, 0.5)
		markerLine.Position = UDim2.new(0, 0, 0.5, 0)
		markerLine.BackgroundColor3 = Color3.fromRGB(95, 95, 112)
		markerLine.BorderSizePixel = 0
		markerLine.Visible = false
		markerLine.Parent = slider.markerLayer

		local markerLabel = Instance.new("TextLabel")
		markerLabel.Name = string.format("P%dLabel", level)
		markerLabel.Size = UDim2.new(0, 48, 0, 10)
		markerLabel.AnchorPoint = Vector2.new(0.5, 0)
		markerLabel.Position = UDim2.new(0, 0, 1, 2)
		markerLabel.BackgroundTransparency = 1
		markerLabel.Text = string.format("P%d", level)
		markerLabel.Font = UI.TEXT_FONT
		markerLabel.TextSize = 9
		markerLabel.TextColor3 = Color3.fromRGB(130, 130, 150)
		markerLabel.Visible = false
		markerLabel.Parent = slider.markerLayer

		table.insert(slider.markers, {
			level = level,
			line = markerLine,
			label = markerLabel,
		})
	end

	slider.markerSignature = markerSignature(levels)
end

local function getSliderBounds(key)
	if not latestState then
		return nil
	end

	local progression = latestState.progression or {}
	local currentLevel = math.max(0, math.floor(tonumber(progression.level) or 0))
	local maxLevel = math.max(currentLevel, math.floor(tonumber(progression.maxLevel) or 0))
	local highestBandLevel = tonumber(PrestigeConfig.getHighestDefinedTuningBandLevel and PrestigeConfig.getHighestDefinedTuningBandLevel() or 0) or 0
	maxLevel = math.max(maxLevel, math.floor(highestBandLevel))

	local limits = latestState.tuning and latestState.tuning.limits and latestState.tuning.limits[key]
	local currentMin = tonumber(limits and limits.min)
	local currentMax = tonumber(limits and limits.max)
	local step = tonumber(limits and limits.step)

	local globalMin = math.huge
	local globalMax = -math.huge
	local segmentMaxByLevel = {}

	for _, level in ipairs(getDefinedBandLevels()) do
		local band = PrestigeConfig.getTuningBand(level)
		local range = type(band) == "table" and band[key] or nil
		local levelMin = tonumber(range and range.min)
		local levelMax = tonumber(range and range.max)

		if levelMin then
			globalMin = math.min(globalMin, levelMin)
		end
		if levelMax then
			globalMax = math.max(globalMax, levelMax)
			segmentMaxByLevel[level] = levelMax
		elseif levelMin then
			segmentMaxByLevel[level] = levelMin
		end
	end

	segmentMaxByLevel[currentLevel] = currentMax or currentMin

	-- Anchor the left edge of the slider to P0's lower bound so later
	-- prestiges only expand the selectable range to the right.
	do
		local baseBand = PrestigeConfig.getTuningBand(0)
		local baseRange = type(baseBand) == "table" and baseBand[key] or nil
		local baseMin = tonumber(baseRange and baseRange.min)
		if baseMin ~= nil then
			globalMin = baseMin
		end
	end

	if globalMin == math.huge then
		globalMin = currentMin or 0
	end
	if globalMax == -math.huge then
		globalMax = currentMax or globalMin
	end

	if currentMin == nil then
		currentMin = globalMin
	end
	if currentMax == nil then
		currentMax = globalMax
	end
	if currentMax < currentMin then
		currentMax = currentMin
	end

	globalMin = math.min(globalMin, currentMin)
	globalMax = math.max(globalMax, currentMax)
	if step and step <= 0 then
		step = nil
	end

	return {
		currentLevel = currentLevel,
		maxLevel = maxLevel,
		currentMin = currentMin,
		currentMax = currentMax,
		step = step,
		globalMin = globalMin,
		globalMax = globalMax,
		segmentMaxByLevel = segmentMaxByLevel,
	}
end

local function refreshUnsavedLabel()
	if not unsavedLabel then
		return
	end

	if not latestState then
		unsavedLabel.Text = ""
		return
	end

	local selected = latestState.tuning and latestState.tuning.selected or RuntimeTuning.getDefaultTuning()
	local unsaved = draftTuning and (not RuntimeTuning.tuningEquals(draftTuning, selected))
	if unsaved then
		unsavedLabel.Text = "Draft has unsaved changes."
		unsavedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	else
		unsavedLabel.Text = "Draft matches saved tuning."
		unsavedLabel.TextColor3 = Color3.fromRGB(150, 220, 170)
	end
end

local function refreshSlider(slider)
	if not slider then
		return
	end

	local bounds = getSliderBounds(slider.key)
	if not bounds then
		slider.valueLabel.Text = "--"
		slider.rangeLabel.Text = ""
		slider.fill.Size = UDim2.new(0, 0, 1, 0)
		slider.lockedLeft.Size = UDim2.new(0, 0, 1, 0)
		slider.lockedRight.Position = UDim2.new(1, 0, 0, 0)
		slider.lockedRight.Size = UDim2.new(0, 0, 1, 0)
		slider.thumb.Visible = false
		for _, marker in ipairs(slider.markers) do
			marker.line.Visible = false
			marker.label.Visible = false
		end
		return
	end

	ensureDraft(false)
	local rawValue = tonumber(draftTuning and draftTuning[slider.key]) or bounds.currentMin
	local value = clampAndQuantize(rawValue, bounds.currentMin, bounds.currentMax, bounds.step)
	if draftTuning then
		draftTuning[slider.key] = value
	end

	local unlockedMinAlpha = valueToAlpha(bounds.currentMin, bounds.globalMin, bounds.globalMax)
	local unlockedMaxAlpha = valueToAlpha(bounds.currentMax, bounds.globalMin, bounds.globalMax)
	local valueAlpha = valueToAlpha(value, bounds.globalMin, bounds.globalMax)

	slider.valueLabel.Text = slider.formatter(value)
	slider.rangeLabel.Text = string.format(
		"P%d range: %s - %s",
		bounds.currentLevel,
		slider.formatter(bounds.currentMin),
		slider.formatter(bounds.currentMax)
	)

	slider.lockedLeft.Size = UDim2.new(unlockedMinAlpha, 0, 1, 0)
	slider.lockedRight.Position = UDim2.new(unlockedMaxAlpha, 0, 0, 0)
	slider.lockedRight.Size = UDim2.new(math.max(1 - unlockedMaxAlpha, 0), 0, 1, 0)

	slider.fill.Position = UDim2.new(unlockedMinAlpha, 0, 0, 0)
	slider.fill.Size = UDim2.new(math.max(valueAlpha - unlockedMinAlpha, 0), 0, 1, 0)
	slider.thumb.Visible = true
	slider.thumb.Position = UDim2.new(valueAlpha, 0, 0.5, 0)

	rebuildSliderMarkers(slider, buildMarkerLevels(slider.key, bounds.currentLevel))

	for _, marker in ipairs(slider.markers) do
		local markerValue = bounds.segmentMaxByLevel[marker.level]
		local visible = marker.level <= bounds.maxLevel and markerValue ~= nil
		marker.line.Visible = visible
		marker.label.Visible = visible
		if visible then
			local markerAlpha = valueToAlpha(markerValue, bounds.globalMin, bounds.globalMax)
			marker.line.Position = UDim2.new(markerAlpha, 0, 0.5, 0)
			marker.label.Position = UDim2.new(markerAlpha, 0, 1, 2)

			local unlocked = marker.level <= bounds.currentLevel
			marker.line.BackgroundColor3 = unlocked and Color3.fromRGB(250, 225, 130) or Color3.fromRGB(95, 95, 112)
			marker.label.TextColor3 = unlocked and Color3.fromRGB(245, 235, 190) or Color3.fromRGB(130, 130, 150)
		end
	end
end

local function refreshAllSliders()
	for _, slider in ipairs(sliders) do
		refreshSlider(slider)
	end
end

local function setSliderValueFromInputX(slider, inputX)
	if not slider or not latestState then
		return false
	end

	ensureDraft(false)
	if not draftTuning then
		return false
	end

	local bounds = getSliderBounds(slider.key)
	if not bounds then
		return false
	end

	local trackLeft = slider.track.AbsolutePosition.X
	local trackWidth = slider.track.AbsoluteSize.X
	if trackWidth <= 0 then
		return false
	end

	local alpha = math.clamp((inputX - trackLeft) / trackWidth, 0, 1)
	local raw = bounds.globalMin + alpha * (bounds.globalMax - bounds.globalMin)
	local value = clampAndQuantize(raw, bounds.currentMin, bounds.currentMax, bounds.step)

	local previous = tonumber(draftTuning[slider.key]) or 0
	if math.abs(previous - value) < 0.0001 then
		return false
	end

	draftTuning[slider.key] = value
	refreshSlider(slider)
	refreshUnsavedLabel()
	return true
end
local function prepareDraftForApply()
	if not latestState then
		return nil, "Prestige state not loaded yet."
	end

	ensureDraft(false)
	if not draftTuning then
		return nil, "Prestige state not loaded yet."
	end

	local limits = latestState.tuning and latestState.tuning.limits
	draftTuning = RuntimeTuning.clampTuning(draftTuning, limits)
	refreshAllSliders()
	refreshUnsavedLabel()
	return draftTuning, nil
end

local function handlePrestigeMissionCompletePressed(entry)
	if type(entry) ~= "table" then
		return
	end

	local missionId = tostring(entry.missionId or "")
	if missionId == "" then
		return
	end
	if prestigeMissionRedeemingIds[missionId] == true then
		return
	end

	prestigeMissionRedeemingIds[missionId] = true
	if screenGui and screenGui.Enabled then
		renderState()
	end

	task.spawn(function()
		local success, redeemResultOrReason = MissionManager.redeemMission(missionId)
		prestigeMissionRedeemingIds[missionId] = nil

		if not success then
			warn(string.format("[PrestigeUI] Failed to complete prestige mission '%s': %s", missionId, tostring(redeemResultOrReason)))
			if not isDestroyed and screenGui and screenGui.Enabled then
				setFeedback("Failed to complete prestige mission.", Color3.fromRGB(255, 160, 160))
				renderState()
			end
		elseif not isDestroyed and screenGui and screenGui.Enabled then
			renderState()
		end
	end)
end

local function renderPrestigeRequirementsList()
	clearProgressRows()
	if not progressFrame then
		return 0
	end

	local entries = buildPrestigeMissionCardEntries(latestState)
	if #entries <= 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyState"
		empty.Size = UDim2.new(1, -8, 1, 0)
		empty.Position = UDim2.new(0, 0, 0, 0)
		empty.BackgroundTransparency = 1
		empty.Text = "No prestige mission requirements available."
		empty.TextWrapped = true
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.TextYAlignment = Enum.TextYAlignment.Top
		empty.Font = UI.TEXT_FONT
		empty.TextSize = UI.BODY_TEXT_SIZE
		empty.TextColor3 = Color3.fromRGB(220, 220, 220)
		empty.Parent = progressFrame
		return 0
	end

	return renderPrestigeMissionCards(progressFrame, entries, 1, {
		onComplete = handlePrestigeMissionCompletePressed,
	})
end

local function renderState()
	if not latestState then
		if progressionLabel then progressionLabel.Text = "Prestige: loading..." end
		if requirementLabel then requirementLabel.Text = "" end
		if readyLabel then readyLabel.Text = "" end
		if thresholdsLabel then thresholdsLabel.Text = "" end
		if savedLabel then savedLabel.Text = "" end
		if currentLabel then currentLabel.Text = "" end
		if unsavedLabel then unsavedLabel.Text = "" end
		clearProgressRows()
		setButtonEnabledState(attemptButton, false, UI.BUTTON_ACCENT)
		setAttemptButtonPulseEnabled(false)
		refreshAllSliders()
		renderFirstPrestigeMissionOverlay()
		return
	end

	ensureDraft(false)
	refreshAllSliders()

	local progression = latestState.progression or {}
	local level = progression.level or 0
	local maxLevel = progression.maxLevel
	local isUnbounded = progression.isUnbounded == true or maxLevel == nil
	if isUnbounded then
		progressionLabel.Text = string.format("Prestige Level: %d / INF", level)
	else
		progressionLabel.Text = string.format("Prestige Level: %d / %d", level, math.floor(tonumber(maxLevel) or 0))
	end

	local nextLevel = latestState.nextLevel
	clearProgressRows()

	local canAttemptPrestige = false
	if nextLevel then
		canAttemptPrestige = nextLevel.unlocked == true
		renderPrestigeRequirementsList()
	elseif not isUnbounded then
		if progressFrame then
			local empty = Instance.new("TextLabel")
			empty.Name = "EmptyState"
			empty.Size = UDim2.new(1, -8, 1, 0)
			empty.Position = UDim2.new(0, 0, 0, 0)
			empty.BackgroundTransparency = 1
			empty.Text = "Maximum prestige reached."
			empty.TextWrapped = true
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.TextYAlignment = Enum.TextYAlignment.Top
			empty.Font = UI.TEXT_FONT
			empty.TextSize = UI.BODY_TEXT_SIZE
			empty.TextColor3 = Color3.fromRGB(220, 220, 220)
			empty.Parent = progressFrame
		end
	else
		if progressFrame then
			local empty = Instance.new("TextLabel")
			empty.Name = "EmptyState"
			empty.Size = UDim2.new(1, -8, 1, 0)
			empty.Position = UDim2.new(0, 0, 0, 0)
			empty.BackgroundTransparency = 1
			empty.Text = "Generating next prestige tier..."
			empty.TextWrapped = true
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.TextYAlignment = Enum.TextYAlignment.Top
			empty.Font = UI.TEXT_FONT
			empty.TextSize = UI.BODY_TEXT_SIZE
			empty.TextColor3 = Color3.fromRGB(220, 220, 220)
			empty.Parent = progressFrame
		end
	end

	if requirementLabel then requirementLabel.Text = "" end
	if readyLabel then readyLabel.Text = "" end
	if thresholdsLabel then thresholdsLabel.Text = "" end
	if savedLabel then savedLabel.Text = "" end
	if currentLabel then currentLabel.Text = "" end
	if unsavedLabel then unsavedLabel.Text = "" end

	local runActive = latestState.isRunActive == true
	if attemptButton then
		attemptButton.Text = if canAttemptPrestige then "Prestige" else "Prestige Not Ready"
	end
	setButtonEnabledState(attemptButton, (not runActive) and canAttemptPrestige, UI.BUTTON_ACCENT)
	setAttemptButtonPulseEnabled((not runActive) and canAttemptPrestige)
	if runActive then
		setFeedback("Tuning and prestige are locked during active runs.", Color3.fromRGB(255, 185, 120))
	end

	renderFirstPrestigeMissionOverlay()
end

local function createTextButton(name, text, size, position, color, parent)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = UI.BUTTON_TEXT
	button.Font = UI.TEXT_BOLD_FONT
	button.TextSize = UI.BODY_TEXT_SIZE
	button.AutoButtonColor = true
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	return button
end

local function createSliderRow(parent, config)
	local row = Instance.new("Frame")
	row.Name = config.name .. "SliderRow"
	row.Size = UDim2.new(1, 0, 0, 50)
	row.Position = UDim2.new(0, 0, 0, config.yOffset)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = config.name .. "Label"
	label.Size = UDim2.new(0, 220, 0, 18)
	label.Position = UDim2.new(0, 18, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = config.label
	label.Font = UI.TEXT_BOLD_FONT
	label.TextSize = UI.BODY_TEXT_SIZE
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = config.name .. "ValueLabel"
	valueLabel.Size = UDim2.new(0, 120, 0, 18)
	valueLabel.Position = UDim2.new(1, -138, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text = "--"
	valueLabel.TextColor3 = Color3.fromRGB(245, 225, 120)
	valueLabel.Font = UI.TEXT_BOLD_FONT
	valueLabel.TextSize = UI.BODY_TEXT_SIZE
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = row

	local track = Instance.new("Frame")
	track.Name = config.name .. "Track"
	track.Size = UDim2.new(1, -36, 0, 8)
	track.Position = UDim2.new(0, 18, 0, 21)
	track.BackgroundColor3 = Color3.fromRGB(58, 58, 72)
	track.BorderSizePixel = 0
	track.Parent = row

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	local lockedLeft = Instance.new("Frame")
	lockedLeft.Name = "LockedLeft"
	lockedLeft.Size = UDim2.new(0, 0, 1, 0)
	lockedLeft.BackgroundColor3 = Color3.fromRGB(35, 35, 44)
	lockedLeft.BackgroundTransparency = 0.3
	lockedLeft.BorderSizePixel = 0
	lockedLeft.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = config.fillColor
	fill.BorderSizePixel = 0
	fill.Parent = track

	local lockedRight = Instance.new("Frame")
	lockedRight.Name = "LockedRight"
	lockedRight.Size = UDim2.new(0, 0, 1, 0)
	lockedRight.Position = UDim2.new(1, 0, 0, 0)
	lockedRight.BackgroundColor3 = Color3.fromRGB(35, 35, 44)
	lockedRight.BackgroundTransparency = 0.3
	lockedRight.BorderSizePixel = 0
	lockedRight.Parent = track

	local thumb = Instance.new("TextButton")
	thumb.Name = config.name .. "Thumb"
	thumb.Size = UDim2.new(0, 16, 0, 16)
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Position = UDim2.new(0, 0, 0.5, 0)
	thumb.BackgroundColor3 = Color3.fromRGB(250, 250, 250)
	thumb.BorderSizePixel = 0
	thumb.Text = ""
	thumb.AutoButtonColor = false
	thumb.ZIndex = 3
	thumb.Parent = track

	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(0.5, 0)
	thumbCorner.Parent = thumb

	local markerLayer = Instance.new("Frame")
	markerLayer.Name = "MarkerLayer"
	markerLayer.Size = UDim2.new(1, 0, 0, 18)
	markerLayer.Position = UDim2.new(0, 0, 1, 1)
	markerLayer.BackgroundTransparency = 1
	markerLayer.Parent = track

	local rangeLabel = Instance.new("TextLabel")
	rangeLabel.Name = config.name .. "RangeLabel"
	rangeLabel.Size = UDim2.new(1, -36, 0, 16)
	rangeLabel.Position = UDim2.new(0, 18, 0, 33)
	rangeLabel.BackgroundTransparency = 1
	rangeLabel.Text = ""
	rangeLabel.TextColor3 = Color3.fromRGB(180, 180, 205)
	rangeLabel.Font = UI.TEXT_FONT
	rangeLabel.TextSize = 11
	rangeLabel.TextXAlignment = Enum.TextXAlignment.Left
	rangeLabel.Parent = row

	local markers = {}

	local slider = {
		key = config.key,
		formatter = config.formatter,
		track = track,
		fill = fill,
		lockedLeft = lockedLeft,
		lockedRight = lockedRight,
		thumb = thumb,
		valueLabel = valueLabel,
		rangeLabel = rangeLabel,
		markerLayer = markerLayer,
		markers = markers,
		markerSignature = nil,
	}

	table.insert(sliders, slider)

	trackSliderConnection(thumb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			activeSlider = slider
			changedWhileDragging = false
		end
	end))

	trackSliderConnection(track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			activeSlider = slider
			local changed = setSliderValueFromInputX(slider, input.Position.X)
			changedWhileDragging = changedWhileDragging or changed
		end
	end))

	return slider
end

local function saveDraftTuningIfNeeded(options)
	local opts = if type(options) == "table" then options else {}
	local silent = opts.silent == true

	if not latestState then
		if not silent then
			setFeedback("Prestige state not loaded yet.", Color3.fromRGB(255, 150, 150))
		end
		return false, "STATE_NOT_LOADED"
	end

	ensureDraft(false)
	local selected = latestState.tuning and latestState.tuning.selected or RuntimeTuning.getDefaultTuning()
	if not draftTuning or RuntimeTuning.tuningEquals(draftTuning, selected) then
		return true, "NO_CHANGES"
	end

	if latestState.isRunActive then
		if not silent then
			setFeedback("Finish the run before saving tuning.", Color3.fromRGB(255, 150, 150))
		end
		return false, "RUN_ACTIVE"
	end

	local tuning, err = prepareDraftForApply()
	if not tuning then
		if not silent then
			setFeedback(err, Color3.fromRGB(255, 150, 150))
		end
		return false, err
	end

	if RuntimeTuning.tuningEquals(tuning, selected) then
		return true, "NO_CHANGES"
	end

	local response = PrestigeManager.setTuning(tuning)
	if type(response) ~= "table" or response.success ~= true then
		if not silent then
			setFeedback((response and response.message) or "Failed to save tuning.", Color3.fromRGB(255, 150, 150))
		end
		return false, (response and response.message) or "FAILED"
	end

	Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_TUNING_APPLIED, nil, {
		speedCap = tuning.speedCapMultiplier,
		gravity = tuning.gravity,
		jumpPower = tuning.jumpPowerMultiplier,
		clamped = response.clamped == true,
		autoSavedOnClose = opts.autoClose == true,
	})

	if not silent then
		if response.clamped then
			setFeedback("Saved with limit clamping.", Color3.fromRGB(255, 220, 120))
		else
			setFeedback("Tuning saved.", Color3.fromRGB(170, 230, 170))
		end
	end

	draftTuning = nil
	latestState = response.state or latestState
	ensureDraft(true)
	if screenGui and screenGui.Enabled then
		renderState()
	end

	return true, response
end

local function requestClose()
	if not screenGui or not screenGui.Enabled then
		return
	end

	PrestigeUI.hide()
	if onCloseCallback then
		onCloseCallback()
	end
end

local function handleAttemptPressed()
	if not latestState then
		setFeedback("Prestige state not loaded yet.", Color3.fromRGB(255, 150, 150))
		return
	end

	if latestState.isRunActive then
		setFeedback("Finish the run before attempting prestige.", Color3.fromRGB(255, 150, 150))
		return
	end

	local nextLevel = latestState.nextLevel
	if type(nextLevel) ~= "table" or nextLevel.unlocked ~= true then
		setFeedback("Complete all prestige requirements first.", Color3.fromRGB(255, 150, 150))
		return
	end

	local response = PrestigeManager.attemptPrestige()
	if type(response) ~= "table" then
		setFeedback("Prestige attempt failed.", Color3.fromRGB(255, 150, 150))
		Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_ATTEMPT, 0, {
			success = false,
			reasonCode = "INVALID_RESPONSE",
		})
		return
	end

	if response.success then
		Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_ATTEMPT, 1, {
			success = true,
			level = response.newLevel,
		})
		Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_SUCCESS, response.newLevel, {
			level = response.newLevel,
			title = response.levelTitle,
		})

		latestState = response.state or latestState
		draftTuning = nil
		ensureDraft(true)
		renderState()
		setFeedback("Prestige successful!", Color3.fromRGB(120, 230, 170))
		return
	end

	setFeedback(response.message or "Requirements not met.", Color3.fromRGB(255, 160, 160))
	Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_ATTEMPT, 0, {
		success = false,
		reasonCode = response.reasonCode,
	})
	latestState = response.state or latestState
	renderState()
end

local function handleUnlockPrestigeTuningPressed()
	local gateState = getFirstPrestigeMissionGateState(latestState)
	if gateState == nil then
		return
	end
	if gateState.missionComplete ~= true then
		return
	end

	-- Unlock action for the first gate also performs the player's first prestige
	-- so they don't have to click a separate "Attempt Prestige" button.
	handleAttemptPressed()
end

function PrestigeUI.init()
	if PrestigeConfig.ENABLED ~= true then
		return
	end

	if screenGui then
		return
	end
	isDestroyed = false

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PrestigeUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 12
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
	overlay.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			requestClose()
		end
	end)

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, UI.CONTAINER_WIDTH, 0, UI.CONTAINER_HEIGHT)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundColor3 = UI.CONTAINER_BG_COLOR
	container.BackgroundTransparency = UI.CONTAINER_BG_TRANSPARENCY
	container.BorderSizePixel = 0
	container.Active = true
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

	local closeButton = createTextButton(
		"CloseButton",
		"X",
		UDim2.new(0, UI.CLOSE_BUTTON_SIZE, 0, UI.CLOSE_BUTTON_SIZE),
		UDim2.new(1, -46, 0, 7),
		UI.CLOSE_BUTTON_COLOR,
		header
	)
	closeButton.Font = UI.CLOSE_BUTTON_FONT
	closeButton.TextSize = 18
	closeButton.MouseButton1Click:Connect(requestClose)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -24, 1, -UI.HEADER_HEIGHT - 12)
	body.Position = UDim2.new(0, 12, 0, UI.HEADER_HEIGHT + 6)
	body.BackgroundTransparency = 1
	body.Parent = container

	progressionLabel = Instance.new("TextLabel")
	progressionLabel.Name = "ProgressionLabel"
	progressionLabel.Size = UDim2.new(1, -172, 0, 24)
	progressionLabel.Position = UDim2.new(0, 0, 0, 0)
	progressionLabel.BackgroundTransparency = 1
	progressionLabel.TextXAlignment = Enum.TextXAlignment.Left
	progressionLabel.Font = UI.TEXT_BOLD_FONT
	progressionLabel.TextSize = 18
	progressionLabel.TextColor3 = Color3.fromRGB(245, 235, 200)
	progressionLabel.TextTruncate = Enum.TextTruncate.AtEnd
	progressionLabel.Parent = body

	requirementLabel = Instance.new("TextLabel")
	requirementLabel.Name = "RequirementLabel"
	requirementLabel.Size = UDim2.new(1, 0, 0, 42)
	requirementLabel.Position = UDim2.new(0, 0, 0, 28)
	requirementLabel.BackgroundTransparency = 1
	requirementLabel.TextWrapped = true
	requirementLabel.TextXAlignment = Enum.TextXAlignment.Left
	requirementLabel.TextYAlignment = Enum.TextYAlignment.Top
	requirementLabel.Font = UI.TEXT_FONT
	requirementLabel.TextSize = UI.BODY_TEXT_SIZE
	requirementLabel.TextColor3 = Color3.fromRGB(225, 225, 225)
	requirementLabel.Visible = false
	requirementLabel.Parent = body

	readyLabel = Instance.new("TextLabel")
	readyLabel.Name = "ReadyLabel"
	readyLabel.Size = UDim2.new(1, 0, 0, 22)
	readyLabel.Position = UDim2.new(0, 0, 0, 72)
	readyLabel.BackgroundTransparency = 1
	readyLabel.TextXAlignment = Enum.TextXAlignment.Left
	readyLabel.Font = UI.TEXT_BOLD_FONT
	readyLabel.TextSize = UI.BODY_TEXT_SIZE
	readyLabel.TextColor3 = Color3.fromRGB(120, 230, 170)
	readyLabel.Visible = false
	readyLabel.Parent = body

	progressFrame = Instance.new("ScrollingFrame")
	progressFrame.Name = "ProgressFrame"
	progressFrame.Size = UDim2.new(1, 0, 0, 220)
	progressFrame.Position = UDim2.new(0, 0, 0, 42)
	progressFrame.BackgroundTransparency = 1
	progressFrame.BorderSizePixel = 0
	progressFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	progressFrame.ScrollBarThickness = 6
	progressFrame.ScrollBarImageColor3 = Color3.fromRGB(200, 180, 140)
	progressFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	progressFrame.Parent = body

	thresholdsLabel = Instance.new("TextLabel")
	thresholdsLabel.Name = "ThresholdsLabel"
	thresholdsLabel.Size = UDim2.new(1, 0, 0, 20)
	thresholdsLabel.Position = UDim2.new(0, 0, 0, 234)
	thresholdsLabel.BackgroundTransparency = 1
	thresholdsLabel.TextXAlignment = Enum.TextXAlignment.Left
	thresholdsLabel.Font = UI.TEXT_FONT
	thresholdsLabel.TextSize = UI.SMALL_TEXT_SIZE
	thresholdsLabel.TextColor3 = Color3.fromRGB(185, 185, 205)
	thresholdsLabel.Visible = false
	thresholdsLabel.Parent = body

	savedLabel = Instance.new("TextLabel")
	savedLabel.Name = "SavedLabel"
	savedLabel.Size = UDim2.new(1, 0, 0, 20)
	savedLabel.Position = UDim2.new(0, 0, 0, 260)
	savedLabel.BackgroundTransparency = 1
	savedLabel.TextXAlignment = Enum.TextXAlignment.Left
	savedLabel.Font = UI.TEXT_FONT
	savedLabel.TextSize = UI.SMALL_TEXT_SIZE
	savedLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	savedLabel.Visible = false
	savedLabel.Parent = body

	currentLabel = Instance.new("TextLabel")
	currentLabel.Name = "CurrentLabel"
	currentLabel.Size = UDim2.new(1, 0, 0, 20)
	currentLabel.Position = UDim2.new(0, 0, 0, 282)
	currentLabel.BackgroundTransparency = 1
	currentLabel.TextXAlignment = Enum.TextXAlignment.Left
	currentLabel.Font = UI.TEXT_FONT
	currentLabel.TextSize = UI.SMALL_TEXT_SIZE
	currentLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	currentLabel.Visible = false
	currentLabel.Parent = body

	unsavedLabel = Instance.new("TextLabel")
	unsavedLabel.Name = "UnsavedLabel"
	unsavedLabel.Size = UDim2.new(1, 0, 0, 20)
	unsavedLabel.Position = UDim2.new(0, 0, 0, 304)
	unsavedLabel.BackgroundTransparency = 1
	unsavedLabel.TextXAlignment = Enum.TextXAlignment.Left
	unsavedLabel.Font = UI.TEXT_BOLD_FONT
	unsavedLabel.TextSize = UI.SMALL_TEXT_SIZE
	unsavedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	unsavedLabel.Visible = false
	unsavedLabel.Parent = body

	createSliderRow(body, {
		name = "SpeedCap",
		key = "speedCapMultiplier",
		label = "Speed Ramp Multiplier",
		yOffset = 278,
		formatter = formatSpeed,
		fillColor = UI.BUTTON_PRIMARY,
	})

	createSliderRow(body, {
		name = "Gravity",
		key = "gravity",
		label = "Gravity Multiplier",
		yOffset = 342,
		formatter = formatGravity,
		fillColor = UI.BUTTON_ACCENT,
	})

	createSliderRow(body, {
		name = "JumpPower",
		key = "jumpPowerMultiplier",
		label = "Jump Power Multiplier",
		yOffset = 406,
		formatter = formatJumpPower,
		fillColor = Color3.fromRGB(235, 170, 95),
	})

	trackSliderConnection(UserInputService.InputChanged:Connect(function(input)
		if not activeSlider then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local changed = setSliderValueFromInputX(activeSlider, input.Position.X)
			changedWhileDragging = changedWhileDragging or changed
		end
	end))

	trackSliderConnection(UserInputService.InputEnded:Connect(function(input)
		if not activeSlider then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			activeSlider = nil
			changedWhileDragging = false
		end
	end))

	attemptButton = createTextButton(
		"AttemptPrestigeButton",
		"Prestige",
		UDim2.new(0, 160, 0, 30),
		UDim2.new(1, -160, 0, 0),
		UI.BUTTON_ACCENT,
		body
	)
	attemptButton.MouseButton1Click:Connect(handleAttemptPressed)

	feedbackLabel = Instance.new("TextLabel")
	feedbackLabel.Name = "FeedbackLabel"
	feedbackLabel.Size = UDim2.new(1, 0, 0, 30)
	feedbackLabel.Position = UDim2.new(0, 0, 0, 512)
	feedbackLabel.BackgroundTransparency = 1
	feedbackLabel.TextWrapped = true
	feedbackLabel.TextXAlignment = Enum.TextXAlignment.Left
	feedbackLabel.TextYAlignment = Enum.TextYAlignment.Top
	feedbackLabel.Font = UI.TEXT_FONT
	feedbackLabel.TextSize = UI.SMALL_TEXT_SIZE
	feedbackLabel.TextColor3 = Color3.fromRGB(225, 225, 225)
	feedbackLabel.Text = ""
	feedbackLabel.Parent = body

	firstPrestigeMissionOverlay = Instance.new("Frame")
	firstPrestigeMissionOverlay.Name = "FirstPrestigeMissionOverlay"
	firstPrestigeMissionOverlay.Size = UDim2.new(1, 0, 1, 0)
	firstPrestigeMissionOverlay.Position = UDim2.new(0, 0, 0, 0)
	firstPrestigeMissionOverlay.BackgroundColor3 = Color3.fromRGB(29, 23, 39)
	firstPrestigeMissionOverlay.BackgroundTransparency = 0.03
	firstPrestigeMissionOverlay.BorderSizePixel = 0
	firstPrestigeMissionOverlay.Visible = false
	firstPrestigeMissionOverlay.ZIndex = 20
	firstPrestigeMissionOverlay.Active = true
	firstPrestigeMissionOverlay.Parent = body

	local overlayCorner = Instance.new("UICorner")
	overlayCorner.CornerRadius = UDim.new(0, 10)
	overlayCorner.Parent = firstPrestigeMissionOverlay

	firstPrestigeMissionTitleLabel = Instance.new("TextLabel")
	firstPrestigeMissionTitleLabel.Name = "MissionTitle"
	firstPrestigeMissionTitleLabel.Size = UDim2.new(1, -16, 0, 28)
	firstPrestigeMissionTitleLabel.Position = UDim2.new(0, 8, 0, 10)
	firstPrestigeMissionTitleLabel.BackgroundTransparency = 1
	firstPrestigeMissionTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	firstPrestigeMissionTitleLabel.Font = UI.TITLE_FONT
	firstPrestigeMissionTitleLabel.TextSize = 22
	firstPrestigeMissionTitleLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	firstPrestigeMissionTitleLabel.ZIndex = 21
	firstPrestigeMissionTitleLabel.Text = "First Prestige Mission"
	firstPrestigeMissionTitleLabel.Parent = firstPrestigeMissionOverlay

	firstPrestigeMissionRequirementLabel = Instance.new("TextLabel")
	firstPrestigeMissionRequirementLabel.Name = "MissionRequirement"
	firstPrestigeMissionRequirementLabel.Size = UDim2.new(1, -16, 0, 60)
	firstPrestigeMissionRequirementLabel.Position = UDim2.new(0, 8, 0, 42)
	firstPrestigeMissionRequirementLabel.BackgroundTransparency = 1
	firstPrestigeMissionRequirementLabel.TextWrapped = true
	firstPrestigeMissionRequirementLabel.TextXAlignment = Enum.TextXAlignment.Left
	firstPrestigeMissionRequirementLabel.TextYAlignment = Enum.TextYAlignment.Top
	firstPrestigeMissionRequirementLabel.Font = UI.TEXT_FONT
	firstPrestigeMissionRequirementLabel.TextSize = UI.BODY_TEXT_SIZE
	firstPrestigeMissionRequirementLabel.TextColor3 = Color3.fromRGB(230, 230, 235)
	firstPrestigeMissionRequirementLabel.ZIndex = 21
	firstPrestigeMissionRequirementLabel.Text = ""
	firstPrestigeMissionRequirementLabel.Parent = firstPrestigeMissionOverlay

	firstPrestigeMissionProgressFrame = Instance.new("ScrollingFrame")
	firstPrestigeMissionProgressFrame.Name = "MissionProgress"
	firstPrestigeMissionProgressFrame.Size = UDim2.new(1, -16, 1, -176)
	firstPrestigeMissionProgressFrame.Position = UDim2.new(0, 8, 0, 108)
	firstPrestigeMissionProgressFrame.BackgroundTransparency = 1
	firstPrestigeMissionProgressFrame.BorderSizePixel = 0
	firstPrestigeMissionProgressFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	firstPrestigeMissionProgressFrame.ScrollBarThickness = 6
	firstPrestigeMissionProgressFrame.ScrollBarImageColor3 = Color3.fromRGB(200, 180, 140)
	firstPrestigeMissionProgressFrame.ZIndex = 21
	firstPrestigeMissionProgressFrame.Parent = firstPrestigeMissionOverlay

	firstPrestigeMissionFooterLabel = Instance.new("TextLabel")
	firstPrestigeMissionFooterLabel.Name = "MissionFooter"
	firstPrestigeMissionFooterLabel.Size = UDim2.new(1, -16, 0, 44)
	firstPrestigeMissionFooterLabel.Position = UDim2.new(0, 8, 1, -52)
	firstPrestigeMissionFooterLabel.BackgroundTransparency = 1
	firstPrestigeMissionFooterLabel.TextWrapped = true
	firstPrestigeMissionFooterLabel.TextXAlignment = Enum.TextXAlignment.Left
	firstPrestigeMissionFooterLabel.TextYAlignment = Enum.TextYAlignment.Top
	firstPrestigeMissionFooterLabel.Font = UI.TEXT_BOLD_FONT
	firstPrestigeMissionFooterLabel.TextSize = UI.SMALL_TEXT_SIZE
	firstPrestigeMissionFooterLabel.TextColor3 = Color3.fromRGB(185, 215, 255)
	firstPrestigeMissionFooterLabel.ZIndex = 21
	firstPrestigeMissionFooterLabel.Text = ""
	firstPrestigeMissionFooterLabel.Parent = firstPrestigeMissionOverlay

	firstPrestigeMissionUnlockButton = createTextButton(
		"UnlockPrestigeTuningButton",
		"UNLOCK PRESTIGE TUNING",
		UDim2.new(0, 250, 0, 34),
		UDim2.new(0, 8, 1, -92),
		UI.BUTTON_PRIMARY,
		firstPrestigeMissionOverlay
	)
	firstPrestigeMissionUnlockButton.TextSize = 14
	firstPrestigeMissionUnlockButton.ZIndex = 22
	firstPrestigeMissionUnlockButton.Visible = false
	firstPrestigeMissionUnlockButton.MouseButton1Click:Connect(handleUnlockPrestigeTuningPressed)

	PrestigeManager.onStateChanged(function(newState, context)
		if isDestroyed then
			return
		end

		latestState = newState
		local level = math.max(0, math.floor(tonumber(newState and newState.progression and newState.progression.level) or 0))
		local nextLevel = newState and newState.nextLevel
		local firstMissionUnlocked = type(nextLevel) == "table"
			and math.max(0, math.floor(tonumber(nextLevel.level) or 0)) == 1
			and nextLevel.unlocked == true
		if level > 0 then
			prePrestigeTuningMenuUnlocked = false
		elseif not firstMissionUnlocked then
			prePrestigeTuningMenuUnlocked = false
		end
		if type(context) == "table" and context.type == "debug_reset_prestige" then
			prePrestigeTuningMenuUnlocked = false
		end
		if type(context) == "table" and (context.type == "tuning_applied" or context.type == "prestige_success") then
			draftTuning = nil
		end

		if screenGui and screenGui.Enabled then
			renderState()
		end
	end)

	MissionManager.onStateChanged(function(newMissionState)
		if isDestroyed then
			return
		end

		latestMissionState = newMissionState
		if screenGui and screenGui.Enabled then
			renderState()
		end
	end)
end

function PrestigeUI.show()
	if PrestigeConfig.ENABLED ~= true then
		return
	end

	if not screenGui then
		return
	end

	latestState = PrestigeManager.getState()
	latestMissionState = MissionManager.getState()
	if latestState and latestState.progression and math.max(0, math.floor(tonumber(latestState.progression.level) or 0)) > 0 then
		prePrestigeTuningMenuUnlocked = false
	end
	draftTuning = nil
	ensureDraft(true)
	renderState()
	setFeedback("")
	screenGui.Enabled = true
	PrestigeManager.requestState()
end

function PrestigeUI.hide()
	if not screenGui then
		return
	end

	if screenGui.Enabled ~= true then
		return
	end

	screenGui.Enabled = false
	setAttemptButtonPulseEnabled(false)

	local ok, reason = saveDraftTuningIfNeeded({
		silent = true,
		autoClose = true,
	})
	if not ok and reason ~= "STATE_NOT_LOADED" then
		warn(string.format("[PrestigeUI] Failed to auto-save tuning on close: %s", tostring(reason)))
	end
end

function PrestigeUI.isOpen()
	return screenGui ~= nil and screenGui.Enabled
end

function PrestigeUI.setOnClose(callback)
	onCloseCallback = callback
end

function PrestigeUI.destroy()
	isDestroyed = true
	onCloseCallback = nil
	latestState = nil
	latestMissionState = nil
	draftTuning = nil

	disconnectSliderConnections()

	if viewportScaleConnection then
		viewportScaleConnection:Disconnect()
		viewportScaleConnection = nil
	end
	uiScaleInstance = nil

	progressionLabel = nil
	requirementLabel = nil
	readyLabel = nil
	thresholdsLabel = nil
	progressFrame = nil
	savedLabel = nil
	currentLabel = nil
	unsavedLabel = nil
	feedbackLabel = nil
	setAttemptButtonPulseEnabled(false)
	attemptButton = nil
	attemptButtonPulseTween = nil
	firstPrestigeMissionOverlay = nil
	firstPrestigeMissionTitleLabel = nil
	firstPrestigeMissionRequirementLabel = nil
	firstPrestigeMissionProgressFrame = nil
	firstPrestigeMissionFooterLabel = nil
	firstPrestigeMissionUnlockButton = nil
	prePrestigeTuningMenuUnlocked = false

	table.clear(sliders)
	table.clear(prestigeMissionRedeemingIds)

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return PrestigeUI
