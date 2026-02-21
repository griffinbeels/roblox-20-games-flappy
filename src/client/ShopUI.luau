--[[
	ShopUI.luau

	Modal shop overlay with category tabs and item grid.
	Follows the GameOverUI modal pattern (full-screen dimming + centered container).

	Lifecycle: init() → show() / hide() → destroy()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local ShopManager = require(script.Parent.ShopManager)
local CurrencyManager = require(script.Parent.CurrencyManager)
local MissionManager = require(script.Parent.MissionManager)

local ShopUI = {}

local localPlayer = Players.LocalPlayer
local screenGui = nil
local onCloseCallback = nil
local activeCategory = nil

-- UI references for dynamic updates
local tabButtons = {}      -- { [catId] = TextButton }
local cardFrames = {}      -- { [catId] = { [itemId] = Frame } }
local actionButtons = {}   -- { [itemId] = TextButton }
local balanceLabel = nil
local gridContainer = nil
local categoryFrames = {}  -- { [catId] = ScrollingFrame }

-- UIScale
local uiScaleInstance = nil
local viewportScaleConnection = nil
local changeConnection = nil

local UI = ShopConfig.UI

local function updateUIScale()
	if not uiScaleInstance then return end
	local viewportHeight = workspace.CurrentCamera.ViewportSize.Y
	local scale = math.clamp(viewportHeight / UI.REFERENCE_HEIGHT, UI.MIN_SCALE, UI.MAX_SCALE)
	uiScaleInstance.Scale = scale
end

--[[
	Updates the balance display text.
]]
local function updateBalance()
	if not balanceLabel then return end
	local uiCfg = CurrencyConfig.UI
	balanceLabel.Text = string.format(uiCfg.FORMAT, uiCfg.ICON, CurrencyManager.getLifetimeBalance())
end

--[[
	Updates all action button states based on current shop state.
]]
local function refreshButtons()
	updateBalance()

	local balance = CurrencyManager.getLifetimeBalance()

	for itemId, btn in pairs(actionButtons) do
		local state = ShopManager.getItemState(itemId)
		local item = ShopConfig.getItem(itemId)

		if state == "comingSoon" then
			btn.Text = UI.COMING_SOON_TEXT
			btn.BackgroundColor3 = UI.COMING_SOON_COLOR
			btn.TextColor3 = UI.COMING_SOON_TEXT_COLOR
			btn.AutoButtonColor = false
			btn.TextSize = math.max(10, UI.BUTTON_SIZE - 2)
		elseif state == "equipped" then
			btn.Text = "Equipped"
			btn.BackgroundColor3 = UI.EQUIPPED_COLOR
			btn.TextColor3 = UI.EQUIPPED_TEXT_COLOR
			btn.AutoButtonColor = false
			btn.TextSize = UI.BUTTON_SIZE
		elseif state == "equip" then
			btn.Text = "Equip"
			btn.BackgroundColor3 = UI.EQUIP_COLOR
			btn.TextColor3 = UI.EQUIP_TEXT_COLOR
			btn.AutoButtonColor = true
			btn.TextSize = UI.BUTTON_SIZE
		elseif state == "buy" then
			if item and balance >= item.price then
				local uiCfg = CurrencyConfig.UI
				btn.Text = uiCfg.ICON .. " " .. item.price
				btn.BackgroundColor3 = UI.BUY_COLOR
				btn.TextColor3 = UI.BUY_TEXT_COLOR
				btn.AutoButtonColor = true
				btn.TextSize = UI.BUTTON_SIZE
			else
				local uiCfg = CurrencyConfig.UI
				btn.Text = uiCfg.ICON .. " " .. (item and item.price or "?")
				btn.BackgroundColor3 = UI.INSUFFICIENT_COLOR
				btn.TextColor3 = UI.INSUFFICIENT_TEXT_COLOR
				btn.AutoButtonColor = false
				btn.TextSize = UI.BUTTON_SIZE
			end
		end
	end
end

--[[
	Switches the visible category grid.
]]
local function switchCategory(catId)
	activeCategory = catId

	-- Update tab highlights
	for id, tab in pairs(tabButtons) do
		if id == catId then
			tab.BackgroundColor3 = UI.TAB_ACTIVE_BG
			tab.TextColor3 = UI.TAB_ACTIVE_COLOR
		else
			tab.BackgroundColor3 = UI.TAB_INACTIVE_BG
			tab.TextColor3 = UI.TAB_INACTIVE_COLOR
		end
	end

	-- Show/hide category grids
	for id, frame in pairs(categoryFrames) do
		frame.Visible = (id == catId)
	end
end

--[[
	Creates a single item card.
	@return Frame, TextButton (actionButton)
]]
local function createItemCard(item, parent)
	local card = Instance.new("Frame")
	card.Name = "Card_" .. item.id
	card.Size = UI.CARD_SIZE
	card.BackgroundColor3 = UI.CARD_BG_COLOR
	card.BorderSizePixel = 0
	card.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UI.CARD_CORNER_RADIUS
	corner.Parent = card

	-- Preview square
	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.Size = UI.PREVIEW_SIZE
	preview.AnchorPoint = Vector2.new(0.5, 0)
	preview.Position = UDim2.new(0.5, 0, 0, 8)
	preview.BackgroundColor3 = item.previewColor or Color3.new(0.5, 0.5, 0.5)
	preview.BorderSizePixel = 0
	preview.Parent = card

	local previewCorner = Instance.new("UICorner")
	previewCorner.CornerRadius = UI.PREVIEW_CORNER_RADIUS
	previewCorner.Parent = preview

	if item.previewIcon then
		local previewIcon = Instance.new("TextLabel")
		previewIcon.Name = "PreviewIcon"
		previewIcon.Size = UDim2.new(1, 0, 1, 0)
		previewIcon.BackgroundTransparency = 1
		previewIcon.Text = item.previewIcon
		previewIcon.TextScaled = true
		previewIcon.Font = UI.PREVIEW_ICON_FONT
		previewIcon.TextColor3 = UI.PREVIEW_ICON_COLOR
		previewIcon.Parent = preview
	end

	-- Name label
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Size = UDim2.new(1, -10, 0, 18)
	nameLabel.AnchorPoint = Vector2.new(0.5, 0)
	nameLabel.Position = UDim2.new(0.5, 0, 0, 92)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = item.name
	nameLabel.Font = UI.NAME_FONT
	nameLabel.TextSize = UI.NAME_SIZE
	nameLabel.TextColor3 = UI.NAME_COLOR
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Action button
	local btn = Instance.new("TextButton")
	btn.Name = "ActionButton"
	btn.Size = UDim2.new(1, -16, 0, UI.BUTTON_HEIGHT)
	btn.AnchorPoint = Vector2.new(0.5, 1)
	btn.Position = UDim2.new(0.5, 0, 1, -8)
	btn.BackgroundColor3 = UI.BUY_COLOR
	btn.BorderSizePixel = 0
	btn.Text = "Buy"
	btn.Font = UI.BUTTON_FONT
	btn.TextSize = UI.BUTTON_SIZE
	btn.TextColor3 = UI.BUY_TEXT_COLOR
	btn.AutoButtonColor = true
	btn.Parent = card

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UI.BUTTON_CORNER_RADIUS
	btnCorner.Parent = btn

	-- Click handler
	btn.MouseButton1Click:Connect(function()
		local state = ShopManager.getItemState(item.id)
		if state == "buy" then
			local balance = CurrencyManager.getLifetimeBalance()
			if balance >= item.price then
				ShopManager.purchase(item.id, CurrencyManager)
			end
		elseif state == "equip" then
			ShopManager.equip(item.id)
		end
		-- "equipped"/"comingSoon" states: do nothing (button is disabled)
	end)

	return card, btn
end

--============================================================================
-- PUBLIC API
--============================================================================

--[[
	Initializes the ShopUI (creates all GUI objects, hidden by default).
]]
function ShopUI.init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShopUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 10  -- above ReadyUI
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Full-screen dimming overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = UI.OVERLAY_COLOR
	overlay.BackgroundTransparency = UI.OVERLAY_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.Parent = screenGui

	-- Block clicks through overlay
	overlay.Active = true

	-- Container
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

	-- UIScale
	uiScaleInstance = Instance.new("UIScale")
	uiScaleInstance.Parent = container
	updateUIScale()

	viewportScaleConnection = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateUIScale()
	end)

	--------------------------------------------------------------------
	-- Header: title + balance + close button
	--------------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, UI.HEADER_HEIGHT)
	header.BackgroundTransparency = 1
	header.Parent = container

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.4, 0, 1, 0)
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

	-- Balance display
	balanceLabel = Instance.new("TextLabel")
	balanceLabel.Name = "Balance"
	balanceLabel.Size = UDim2.new(0.35, 0, 1, 0)
	balanceLabel.AnchorPoint = Vector2.new(0.5, 0)
	balanceLabel.Position = UDim2.new(0.55, 0, 0, 0)
	balanceLabel.BackgroundTransparency = 1
	balanceLabel.Text = ""
	balanceLabel.Font = UI.BALANCE_FONT
	balanceLabel.TextSize = UI.BALANCE_SIZE
	balanceLabel.TextColor3 = UI.BALANCE_COLOR
	balanceLabel.Parent = header

	-- Close button
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
	closeBtn.AutoButtonColor = true
	closeBtn.Parent = header

	local closeBtnCorner = Instance.new("UICorner")
	closeBtnCorner.CornerRadius = UDim.new(0, 6)
	closeBtnCorner.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		ShopUI.hide()
		if onCloseCallback then
			onCloseCallback()
		end
	end)

	--------------------------------------------------------------------
	-- Category tabs
	--------------------------------------------------------------------
	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.Size = UDim2.new(1, -20, 0, UI.TAB_HEIGHT)
	tabBar.AnchorPoint = Vector2.new(0.5, 0)
	tabBar.Position = UDim2.new(0.5, 0, 0, UI.HEADER_HEIGHT + 4)
	tabBar.BackgroundTransparency = 1
	tabBar.Parent = container

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tabLayout.Padding = UDim.new(0, 6)
	tabLayout.Parent = tabBar

	for _, cat in ipairs(ShopConfig.CATEGORIES) do
		local tab = Instance.new("TextButton")
		tab.Name = "Tab_" .. cat.id
		tab.Size = UDim2.new(0, 100, 1, 0)
		tab.BackgroundColor3 = UI.TAB_INACTIVE_BG
		tab.BorderSizePixel = 0
		tab.Text = cat.label
		tab.Font = UI.TAB_FONT
		tab.TextSize = UI.TAB_SIZE
		tab.TextColor3 = UI.TAB_INACTIVE_COLOR
		tab.AutoButtonColor = true
		tab.Parent = tabBar

		local tabCorner = Instance.new("UICorner")
		tabCorner.CornerRadius = UI.TAB_CORNER_RADIUS
		tabCorner.Parent = tab

		tabButtons[cat.id] = tab

		tab.MouseButton1Click:Connect(function()
			switchCategory(cat.id)
		end)
	end

	--------------------------------------------------------------------
	-- Item grid area (one ScrollingFrame per category)
	--------------------------------------------------------------------
	local gridTop = UI.HEADER_HEIGHT + UI.TAB_HEIGHT + 12
	local gridHeight = UI.CONTAINER_HEIGHT - gridTop - 10

	for _, cat in ipairs(ShopConfig.CATEGORIES) do
		local scroll = Instance.new("ScrollingFrame")
		scroll.Name = "Grid_" .. cat.id
		scroll.Size = UDim2.new(1, -20, 0, gridHeight)
		scroll.AnchorPoint = Vector2.new(0.5, 0)
		scroll.Position = UDim2.new(0.5, 0, 0, gridTop)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.ScrollBarImageColor3 = Color3.fromRGB(200, 180, 140)
		scroll.Visible = false
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0) -- auto-set by UIGridLayout
		scroll.Parent = container

		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UI.CARD_SIZE
		grid.CellPadding = UDim2.new(0, 8, 0, 8)
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = scroll

		categoryFrames[cat.id] = scroll
		cardFrames[cat.id] = {}

		-- Create cards for each item
		local items = ShopConfig.getItemsByCategory(cat.id)
		for idx, item in ipairs(items) do
			local card, btn = createItemCard(item, scroll)
			card.LayoutOrder = idx
			cardFrames[cat.id][item.id] = card
			actionButtons[item.id] = btn
		end

		-- Auto-size canvas
		grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			scroll.CanvasSize = UDim2.new(0, 0, 0, grid.AbsoluteContentSize.Y + 10)
		end)
		-- Initial canvas size
		task.defer(function()
			scroll.CanvasSize = UDim2.new(0, 0, 0, grid.AbsoluteContentSize.Y + 10)
		end)
	end

	-- Subscribe to shop state changes
	changeConnection = nil
	ShopManager.onChanged(function()
		refreshButtons()
	end)

	-- Select first category by default
	if #ShopConfig.CATEGORIES > 0 then
		switchCategory(ShopConfig.CATEGORIES[1].id)
	end
end

--[[
	Shows the shop modal.
]]
function ShopUI.show()
	if not screenGui then return end
	refreshButtons()
	screenGui.Enabled = true
	MissionManager.reportEvent("shop_opened")
end

--[[
	Hides the shop modal.
]]
function ShopUI.hide()
	if not screenGui then return end
	screenGui.Enabled = false
end

--[[
	Returns whether the shop is currently open.
]]
function ShopUI.isOpen()
	return screenGui ~= nil and screenGui.Enabled
end

--[[
	Sets the callback for when the shop is closed.
	@param callback function
]]
function ShopUI.setOnClose(callback)
	onCloseCallback = callback
end

--[[
	Cleans up the ShopUI.
]]
function ShopUI.destroy()
	onCloseCallback = nil
	tabButtons = {}
	cardFrames = {}
	actionButtons = {}
	categoryFrames = {}
	balanceLabel = nil

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

return ShopUI
