--[[
	ReadyUI.luau

	Displays "Press [JumpKey] to Start" during READY state.
	Also owns the world-space ready buttons (Shop + Missions), both attached
	to the leaderboard billboard anchor.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JumpInput = require(script.Parent.JumpInput)
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local ReadyUI = {}
ReadyUI.__index = ReadyUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local messageLabel = nil

local shopBillboardGui = nil
local missionsBillboardGui = nil

local onShopClickCallback = nil
local onMissionsClickCallback = nil
local readyButtons = {}
local viewportConnection = nil

local function getReadyButtonLayoutConfig()
	local cfg = GameConfig.LEADERBOARD.READY_BUTTON_LAYOUT or {}

	return {
		verticalGapStuds = math.max(0, tonumber(cfg.VERTICAL_GAP_STUDS) or tonumber(cfg.GAP_STUDS) or 1.5),
		sideMarginStuds = tonumber(cfg.SIDE_MARGIN_STUDS) or tonumber(cfg.TOP_MARGIN_STUDS) or 1.5,
		columnYOffsetStuds = tonumber(cfg.COLUMN_Y_OFFSET_STUDS) or tonumber(cfg.ROW_Y_OFFSET_STUDS) or 0,
	}
end

local function getAdaptiveLayoutConfig()
	local cfg = GameConfig.LEADERBOARD.ADAPTIVE_LAYOUT or {}
	local minScale = tonumber(cfg.MIN_SCALE) or 0.70
	local maxScale = tonumber(cfg.MAX_SCALE) or 1.00
	if maxScale < minScale then
		maxScale = minScale
	end

	return {
		enabled = cfg.ENABLED ~= false,
		referenceWidth = math.max(1, tonumber(cfg.REFERENCE_WIDTH) or 1366),
		referenceHeight = math.max(1, tonumber(cfg.REFERENCE_HEIGHT) or 768),
		minScale = minScale,
		maxScale = maxScale,
		buttonMultiplier = tonumber(cfg.BUTTON_SCALE_MULTIPLIER) or 1.0,
	}
end

local function getReadyButtonScale()
	local adaptive = getAdaptiveLayoutConfig()
	if not adaptive.enabled then
		return 1
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end

	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end

	local sx = viewport.X / adaptive.referenceWidth
	local sy = viewport.Y / adaptive.referenceHeight
	local baseScale = math.clamp(math.min(sx, sy), adaptive.minScale, adaptive.maxScale)
	return math.max(0.1, baseScale * adaptive.buttonMultiplier)
end

local function getBillboardWidthStuds(billboardGui)
	local widthStuds = billboardGui.Size.X.Scale
	if widthStuds <= 0 then
		return 8
	end
	return widthStuds
end

local function getBillboardHeightStuds(billboardGui)
	local heightStuds = billboardGui.Size.Y.Scale
	if heightStuds <= 0 then
		return 8
	end
	return heightStuds
end

local function getCurrentLeaderboardBillboardSize()
	local defaultSize = GameConfig.LEADERBOARD.BILLBOARD.SIZE
	local widthStuds = defaultSize.X.Scale or 0
	local heightStuds = defaultSize.Y.Scale or 0

	local leaderboardPart = workspace:FindFirstChild(GameConfig.LEADERBOARD.PART.NAME)
	if not leaderboardPart then
		return widthStuds, heightStuds
	end

	local leaderboardGui = leaderboardPart:FindFirstChild("LeaderboardBillboardGui")
	if leaderboardGui and leaderboardGui:IsA("BillboardGui") then
		widthStuds = leaderboardGui.Size.X.Scale or widthStuds
		heightStuds = leaderboardGui.Size.Y.Scale or heightStuds
	end

	return widthStuds, heightStuds
end

local function getLeaderboardTopStudY()
	local _, heightStuds = getCurrentLeaderboardBillboardSize()
	return heightStuds * 0.5
end

local function getLeaderboardRightStudX()
	local widthStuds = getCurrentLeaderboardBillboardSize()
	return widthStuds * 0.5
end

local function layoutReadyButtons()
	local visibleButtons = {}
	for _, entry in ipairs(readyButtons) do
		if entry.billboard and entry.billboard.Enabled and entry.billboard.Parent then
			table.insert(visibleButtons, entry)
		end
	end

	if #visibleButtons == 0 then
		return
	end

	table.sort(visibleButtons, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.billboard.Name < b.billboard.Name
	end)

	local layoutCfg = getReadyButtonLayoutConfig()
	local buttonScale = getReadyButtonScale()
	local columnLeftX = getLeaderboardRightStudX() + layoutCfg.sideMarginStuds
	local cursorTopY = getLeaderboardTopStudY() + layoutCfg.columnYOffsetStuds

	for _, entry in ipairs(visibleButtons) do
		local localOffset = entry.localOffset or Vector3.new(0, 0, 0)
		local baseSize = entry.baseSize or UDim2.new(8, 0, 8, 0)
		entry.billboard.Size = UDim2.new(
			baseSize.X.Scale * buttonScale,
			0,
			baseSize.Y.Scale * buttonScale,
			0
		)
		local width = getBillboardWidthStuds(entry.billboard)
		local height = getBillboardHeightStuds(entry.billboard)
		local centerX = columnLeftX + width * 0.5
		local centerY = cursorTopY - height * 0.5
		entry.billboard.StudsOffset = Vector3.new(
			centerX + localOffset.X,
			centerY + localOffset.Y,
			entry.baseZ + localOffset.Z
		)
		cursorTopY -= height + layoutCfg.verticalGapStuds
	end
end

local function registerReadyButton(billboardGui, buttonCfg)
	if not billboardGui then
		return
	end

	local localOffset = buttonCfg.LOCAL_OFFSET or Vector3.new(0, 0, 0)
	local baseOffset = buttonCfg.STUDS_OFFSET or Vector3.new(0, 0, 0)
	local order = tonumber(buttonCfg.ROW_ORDER) or (#readyButtons + 1)

	table.insert(readyButtons, {
		billboard = billboardGui,
		order = order,
		localOffset = localOffset,
		baseZ = baseOffset.Z,
		baseSize = buttonCfg.BILLBOARD_SIZE,
	})
end

local function createReadyButtonBillboard(name, parentPart, btnCfg, onActivated)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = name
	billboard.Adornee = parentPart
	billboard.Size = btnCfg.BILLBOARD_SIZE
	billboard.StudsOffset = btnCfg.STUDS_OFFSET
	billboard.MaxDistance = GameConfig.LEADERBOARD.BILLBOARD.MAX_DISTANCE
	billboard.AlwaysOnTop = false
	billboard.Active = true
	billboard.Enabled = false
	billboard.Parent = parentPart

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = btnCfg.BG_COLOR
	bg.BackgroundTransparency = btnCfg.BG_TRANSPARENCY
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = btnCfg.CORNER_RADIUS
	bgCorner.Parent = bg

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.new(1, 0, 0.55, 0)
	iconLabel.Position = UDim2.new(0, 0, 0.05, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = btnCfg.TEXT
	iconLabel.TextScaled = true
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.Parent = bg

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 0.3, 0)
	label.Position = UDim2.new(0, 0, 0.6, 0)
	label.BackgroundTransparency = 1
	label.Text = btnCfg.LABEL
	label.TextScaled = true
	label.Font = btnCfg.LABEL_FONT
	label.TextColor3 = btnCfg.LABEL_COLOR
	label.Parent = bg

	local labelConstraint = Instance.new("UITextSizeConstraint")
	labelConstraint.MinTextSize = GameConfig.LEADERBOARD.TEXT_MIN_SIZE
	labelConstraint.MaxTextSize = GameConfig.LEADERBOARD.TEXT_MAX_SIZE
	labelConstraint.Parent = label

	local clickButton = Instance.new("TextButton")
	clickButton.Name = "ClickArea"
	clickButton.Size = UDim2.new(1, 0, 1, 0)
	clickButton.Active = true
	clickButton.BackgroundTransparency = 1
	clickButton.Text = ""
	clickButton.Parent = billboard

	clickButton.Activated:Connect(function()
		if onActivated then
			onActivated()
		end
	end)

	return billboard
end

local function isMouseOverBillboard(billboardGui)
	if not billboardGui or not billboardGui.Enabled then return false end
	local adornee = billboardGui.Adornee
	if not adornee then return false end

	local camera = workspace.CurrentCamera
	if not camera then return false end

	local worldPos = adornee.Position + billboardGui.StudsOffset
	local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
	if not onScreen then return false end

	local depth = screenPos.Z
	if depth <= 0 then return false end

	local bbSize = billboardGui.Size
	local studsW = bbSize.X.Scale
	local studsH = bbSize.Y.Scale
	local halfFOV = math.rad(camera.FieldOfView / 2)
	local pixelsPerStud = camera.ViewportSize.Y / (2 * depth * math.tan(halfFOV))
	local screenW = studsW * pixelsPerStud
	local screenH = studsH * pixelsPerStud

	local left = screenPos.X - screenW / 2
	local top = screenPos.Y - screenH / 2

	local mousePos = UserInputService:GetMouseLocation()
	return mousePos.X >= left and mousePos.X <= left + screenW
		and mousePos.Y >= top and mousePos.Y <= top + screenH
end

function ReadyUI.init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ReadyUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "ReadyMessage"
	messageLabel.Size = UDim2.new(0.4, 0, 0.1, 0)
	messageLabel.Position = UDim2.new(0.5, 0, 0.6, 0)
	messageLabel.AnchorPoint = Vector2.new(0.5, 0)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = JumpInput.getKeyLabel() .. " to Start"
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.TextScaled = true
	messageLabel.Font = Enum.Font.GothamBold
	messageLabel.TextStrokeTransparency = 0.5
	messageLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	messageLabel.Parent = screenGui

	local msgConstraint = Instance.new("UITextSizeConstraint")
	msgConstraint.MinTextSize = 16
	msgConstraint.MaxTextSize = 42
	msgConstraint.Parent = messageLabel

	local leaderboardPart = workspace:FindFirstChild(GameConfig.LEADERBOARD.PART.NAME)
	if leaderboardPart then
		shopBillboardGui = createReadyButtonBillboard(
			"ShopButtonBillboardGui",
			leaderboardPart,
			ShopConfig.READY_BUTTON,
			function()
				if onShopClickCallback then
					onShopClickCallback()
				end
			end
		)
		registerReadyButton(shopBillboardGui, ShopConfig.READY_BUTTON)

		missionsBillboardGui = createReadyButtonBillboard(
			"MissionsButtonBillboardGui",
			leaderboardPart,
			MissionConfig.READY_BUTTON,
			function()
				if onMissionsClickCallback then
					onMissionsClickCallback()
				end
			end
		)
		registerReadyButton(missionsBillboardGui, MissionConfig.READY_BUTTON)
	else
		warn("[ReadyUI] Leaderboard Part not found - ready buttons disabled.")
	end

	local camera = workspace.CurrentCamera
	if camera then
		if viewportConnection then
			viewportConnection:Disconnect()
		end
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			layoutReadyButtons()
		end)
	end
end

function ReadyUI.setOnShopClick(callback)
	onShopClickCallback = callback
end

function ReadyUI.setOnMissionsClick(callback)
	onMissionsClickCallback = callback
end

function ReadyUI.show()
	if screenGui then
		screenGui.Enabled = true
	end
end

function ReadyUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

function ReadyUI.showShopButton()
	if shopBillboardGui then
		shopBillboardGui.Enabled = true
		layoutReadyButtons()
	end
end

function ReadyUI.hideShopButton()
	if shopBillboardGui then
		shopBillboardGui.Enabled = false
		layoutReadyButtons()
	end
end

function ReadyUI.showMissionsButton()
	if missionsBillboardGui then
		missionsBillboardGui.Enabled = true
		layoutReadyButtons()
	end
end

function ReadyUI.hideMissionsButton()
	if missionsBillboardGui then
		missionsBillboardGui.Enabled = false
		layoutReadyButtons()
	end
end

function ReadyUI.isShopButtonMouseOver()
	return isMouseOverBillboard(shopBillboardGui)
end

function ReadyUI.isMissionsButtonMouseOver()
	return isMouseOverBillboard(missionsBillboardGui)
end

function ReadyUI.destroy()
	onShopClickCallback = nil
	onMissionsClickCallback = nil
	readyButtons = {}
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end

	if shopBillboardGui then
		shopBillboardGui:Destroy()
		shopBillboardGui = nil
	end

	if missionsBillboardGui then
		missionsBillboardGui:Destroy()
		missionsBillboardGui = nil
	end
end

return ReadyUI
