--[[
	LeaderboardUI.luau

	Scrollable global leaderboard rendered on a BillboardGui attached to a
	physical Part in the game world.  Fully data-driven from GameConfig.LEADERBOARD:
	columns, layout, colors, text, and positioning are all read from config.

	All entries (up to MAX_ENTRIES) are fetched at once and displayed inside a
	ScrollingFrame.  Mouse wheel scrolls on desktop, touch drag on mobile.
	The player's own row is highlighted and auto-scrolled into view on show().

	EXTENSIBILITY — adding a new column type:
	  1. Pick a type name (e.g. "badge").
	  2. Add a creator function to COLUMN_CREATORS that builds the UI element(s).
	  3. Add an updater function to COLUMN_UPDATERS that populates the element
	     from a leaderboard entry table.
	  4. Use type = "badge" in GameConfig.LEADERBOARD.COLUMNS.

	Follows the same init()/show()/hide()/destroy() pattern as other UI modules.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local LB = GameConfig.LEADERBOARD
local MissionManager = require(script.Parent.MissionManager)

local LeaderboardUI = {}

local localPlayer = Players.LocalPlayer
local billboardPart = nil
local billboardGui = nil
local getLeaderboardPageRemote = nil

-- ScrollingFrame reference
local scrollingFrame = nil

-- Row UI references (pre-created for MAX_ENTRIES rows)
local rowFrames = {}       -- rowFrames[rowIndex] = Frame
local columnElements = {}  -- columnElements[rowIndex][colIndex] = Instance (TextLabel, ImageLabel, etc.)

-- Other UI references
local playerRankLabel = nil
local emptyMessage = nil

-- State
local fetchGeneration = 0  -- incremented on each show(); stale fetches are discarded
local inputConnections = {} -- UserInputService connections for manual scroll
local scrollVelocity = 0    -- current momentum velocity (pixels/sec)
local momentumConnection = nil -- RenderStepped connection for momentum loop
local touchStartY = nil     -- tracks touch drag start for manual scroll
local touchStartCanvas = nil
local lastTouchY = nil       -- previous touch position for velocity tracking
local lastTouchTime = nil    -- previous touch timestamp for velocity tracking
local adaptiveLayoutConnection = nil
local basePartPosition = nil
local baseBillboardSize = nil

local MAX_ENTRIES = LB.MAX_ENTRIES

--============================================================================
-- IMAGE RESOLVERS
-- Convert a data value (e.g. userId) into an Image asset string.
-- To add a resolver: IMAGE_RESOLVERS.myType = function(value) return "..." end
--============================================================================

local IMAGE_RESOLVERS = {
	avatar_headshot = function(value)
		return string.format("rbxthumb://type=AvatarHeadShot&id=%s&w=150&h=150", tostring(value))
	end,
	avatar_bust = function(value)
		return string.format("rbxthumb://type=AvatarBust&id=%s&w=150&h=150", tostring(value))
	end,
	asset = function(value)
		return string.format("rbxassetid://%s", tostring(value))
	end,
}

--============================================================================
-- COLUMN TYPE REGISTRY
-- Each type has a CREATOR (builds the UI element) and an UPDATER (populates
-- it from a leaderboard entry).  To add a new type, add both functions.
--
-- Creator signature:  creator(colDef, parent, xCursor, width) -> Instance
--   colDef   = the column definition table from config
--   parent   = the row Frame
--   xCursor  = Scale X position within the row
--   width    = normalized column width (fraction of row)
--
-- Updater signature:  updater(element, colDef, entry)
--   element  = the Instance returned by the creator
--   colDef   = the column definition table from config
--   entry    = the leaderboard data row { rank, displayName, score, userId, ... }
--============================================================================

local COLUMN_CREATORS = {}
local COLUMN_UPDATERS = {}

-- "text" — TextScaled TextLabel (default column type)
COLUMN_CREATORS.text = function(colDef, parent, xCursor, width)
	local label = Instance.new("TextLabel")
	label.Name = colDef.key
	label.Size = UDim2.new(width, 0, 1, 0)
	label.Position = UDim2.new(xCursor, 0, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = colDef.color or Color3.new(1, 1, 1)
	label.Font = colDef.font or Enum.Font.GothamBold
	label.TextXAlignment = colDef.align or Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextScaled = false
	label.TextSize = LB.TEXT_MAX_SIZE -- placeholder; fetchAll() computes uniform size

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = label

	label.Parent = parent
	return label
end

COLUMN_UPDATERS.text = function(element, colDef, entry)
	local value = tostring(entry[colDef.key] or "")
	if colDef.prefix then value = colDef.prefix .. value end
	if colDef.suffix then value = value .. colDef.suffix end
	element.Text = value
end

-- "image" — ImageLabel with optional rounding and aspect ratio lock.
-- Uses IMAGE_RESOLVERS to convert data values to asset strings.
COLUMN_CREATORS.image = function(colDef, parent, xCursor, width)
	local img = Instance.new("ImageLabel")
	img.Name = colDef.key
	img.Size = UDim2.new(width, 0, 1, 0)
	img.Position = UDim2.new(xCursor, 0, 0, 0)
	img.BackgroundColor3 = colDef.bgColor or Color3.new(0, 0, 0)
	img.BackgroundTransparency = colDef.bgTransparency or 1
	img.BorderSizePixel = 0
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = ""
	img.Parent = parent

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = colDef.aspectRatio or 1
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = img

	if colDef.cornerRadius then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = colDef.cornerRadius
		corner.Parent = img
	end

	return img
end

COLUMN_UPDATERS.image = function(element, colDef, entry)
	local value = entry[colDef.key]
	if not value then
		element.Image = ""
		return
	end
	local resolver = IMAGE_RESOLVERS[colDef.imageType]
	if resolver then
		element.Image = resolver(value)
	else
		element.Image = tostring(value)
	end
end

local function getTextColumnDisplayValue(colDef, entry)
	local value = tostring(entry[colDef.key] or "")
	if colDef.prefix then value = colDef.prefix .. value end
	if colDef.suffix then value = value .. colDef.suffix end
	return value
end

local function getColumnVisibleWidthPx(element)
	if not element then
		return 0
	end

	local width = element.AbsoluteSize.X
	if not scrollingFrame then
		return width
	end

	local frameRight = scrollingFrame.AbsolutePosition.X + scrollingFrame.AbsoluteWindowSize.X
	local usesOverlayScrollbar = scrollingFrame.VerticalScrollBarInset == Enum.ScrollBarInset.None
	if usesOverlayScrollbar and scrollingFrame.AbsoluteCanvasSize.Y > scrollingFrame.AbsoluteWindowSize.Y then
		frameRight -= scrollingFrame.ScrollBarThickness
	end

	local elementLeft = element.AbsolutePosition.X
	local elementRight = elementLeft + width
	return math.max(0, math.min(elementRight, frameRight) - elementLeft)
end

local function getBestFittingRowTextSize(entries, columns, rowCount, heightLimitedSize)
	local minSize = 1
	local maxSize = math.max(minSize, math.floor(heightLimitedSize))
	local horizontalPadding = 8

	local textColumns = {}
	for colIdx, colDef in ipairs(columns) do
		local colType = colDef.type or "text"
		if colType == "text" then
			local sampleElement = columnElements[1] and columnElements[1][colIdx]
			local widthPx = getColumnVisibleWidthPx(sampleElement) - horizontalPadding
			if widthPx > 0 then
				table.insert(textColumns, {
					colIdx = colIdx,
					font = colDef.font or Enum.Font.GothamBold,
					widthPx = widthPx,
				})
			end
		end
	end

	if #textColumns == 0 then
		return maxSize
	end

	local columnTexts = {}
	for _, colInfo in ipairs(textColumns) do
		columnTexts[colInfo.colIdx] = {}
	end

	for i = 1, rowCount do
		local entry = entries[i]
		for _, colInfo in ipairs(textColumns) do
			local colDef = columns[colInfo.colIdx]
			table.insert(columnTexts[colInfo.colIdx], getTextColumnDisplayValue(colDef, entry))
		end
	end

	local function fitsAtSize(textSize)
		for _, colInfo in ipairs(textColumns) do
			local availableWidth = colInfo.widthPx
			if availableWidth <= 0 then
				return false
			end

			for _, textValue in ipairs(columnTexts[colInfo.colIdx]) do
				local bounds = TextService:GetTextSize(
					textValue,
					textSize,
					colInfo.font,
					Vector2.new(10000, 10000)
				)
				if bounds.X > availableWidth then
					return false
				end
			end
		end
		return true
	end

	local lo = minSize
	local hi = maxSize
	local best = minSize

	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if fitsAtSize(mid) then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end

	return best
end

--============================================================================
-- UI HELPERS
--============================================================================

local function makeLabel(props)
	local label = Instance.new("TextLabel")
	label.Name = props.Name or "Label"
	label.Size = props.Size
	label.Position = props.Position or UDim2.new(0, 0, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = props.Text or ""
	label.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextScaled = true

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = LB.TEXT_MIN_SIZE
	constraint.MaxTextSize = props.MaxTextSize or LB.TEXT_MAX_SIZE
	constraint.Parent = label

	label.Parent = props.Parent
	return label
end

--============================================================================
-- REMOTE RESOLUTION
-- Ensures the RemoteFunction is available before the first fetch.
--============================================================================

local function ensureRemote()
	if getLeaderboardPageRemote then return true end
	local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if remoteFolder then
		getLeaderboardPageRemote = remoteFolder:WaitForChild("GetLeaderboardPage", 10)
	end
	return getLeaderboardPageRemote ~= nil
end

local function getAdaptiveLayoutConfig()
	local cfg = LB.ADAPTIVE_LAYOUT or {}
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
	}
end

local function getViewportAdaptiveScale(camera, cfg)
	if not camera then return 1 end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end

	local sx = viewport.X / cfg.referenceWidth
	local sy = viewport.Y / cfg.referenceHeight
	return math.clamp(math.min(sx, sy), cfg.minScale, cfg.maxScale)
end

local function applyAdaptiveLayout()
	if not billboardPart or not billboardGui or not basePartPosition or not baseBillboardSize then
		return
	end

	local cfg = getAdaptiveLayoutConfig()
	local camera = workspace.CurrentCamera
	if not cfg.enabled or not camera then
		billboardGui.Size = baseBillboardSize
		billboardPart.Position = basePartPosition
		return
	end

	local scale = getViewportAdaptiveScale(camera, cfg)
	billboardGui.Size = UDim2.new(
		baseBillboardSize.X.Scale * scale,
		0,
		baseBillboardSize.Y.Scale * scale,
		0
	)

	-- Keep leaderboard anchored to its world position; do not follow camera.
	billboardPart.Position = basePartPosition
end

--============================================================================
-- DATA FETCHING
--============================================================================

local function fetchAll()
	-- Wait for the remote if it hasn't been resolved yet (fetchAll runs
	-- inside task.spawn so yielding here is safe and non-blocking to callers)
	if not ensureRemote() then return end

	local myGeneration = fetchGeneration

	local ok, result = pcall(function()
		return getLeaderboardPageRemote:InvokeServer()
	end)

	-- Discard stale responses if show()/hide() was called while yielded
	if myGeneration ~= fetchGeneration then return end

	if not ok or not result then return end

	local entries = result.entries or {}
	local totalEntries = result.totalEntries or 0
	local playerUserId = localPlayer.UserId
	local columns = LB.COLUMNS
	local rowsCfg = LB.ROWS
	local scrollCfg = LB.SCROLL
	local playerRowIndex = nil

	if totalEntries == 0 then
		emptyMessage.Visible = true
		scrollingFrame.Visible = false
	else
		emptyMessage.Visible = false
		scrollingFrame.Visible = true

		-- Compute row sizing from VISIBLE_ROWS.
		-- All Scale values start as fractions of the visible frame (1.0),
		-- then are converted to canvas-relative Scale by dividing by canvasScale.
		local N = #entries
		local visibleRows = scrollCfg.VISIBLE_ROWS
		local padTop = scrollCfg.TOP_PADDING
		local padBottom = scrollCfg.BOTTOM_PADDING
		local usableFrame = 1 - padTop - padBottom
		local rowUnitFrame = usableFrame / visibleRows
		local gapFrame = rowUnitFrame * rowsCfg.GAP_RATIO
		local rowHeightFrame = rowUnitFrame - gapFrame

		-- Canvas holds all N rows (clamp to at least 1.0)
		local canvasScale = math.max(1, padTop + N * rowUnitFrame + padBottom)
		scrollingFrame.CanvasSize = UDim2.new(0, 0, canvasScale, 0)

		-- Convert frame-relative sizes to canvas-relative Scale
		local rowHeightCanvas = rowHeightFrame / canvasScale
		local rowUnitCanvas = rowUnitFrame / canvasScale
		local topPadCanvas = padTop / canvasScale
		local rowWidth = rowsCfg.WIDTH
		local rowPadX = (1 - rowWidth) / 2

		for i = 1, MAX_ENTRIES do
			if i <= N then
				local entry = entries[i]
				local rowY = topPadCanvas + (i - 1) * rowUnitCanvas

				rowFrames[i].Size = UDim2.new(rowWidth, 0, rowHeightCanvas, 0)
				rowFrames[i].Position = UDim2.new(rowPadX, 0, rowY, 0)
				rowFrames[i].Visible = true

				-- Update each column element via its type-specific updater
				for colIdx, colDef in ipairs(columns) do
					local colType = colDef.type or "text"
					local updater = COLUMN_UPDATERS[colType]
					if updater then
						updater(columnElements[i][colIdx], colDef, entry)
					end
				end

				-- Highlight current player's row
				if entry.userId == playerUserId then
					rowFrames[i].BackgroundColor3 = rowsCfg.HIGHLIGHT_COLOR
					rowFrames[i].BackgroundTransparency = rowsCfg.HIGHLIGHT_TRANSPARENCY
					playerRowIndex = i
				else
					rowFrames[i].BackgroundColor3 = rowsCfg.BG_COLOR
					rowFrames[i].BackgroundTransparency = rowsCfg.BG_TRANSPARENCY
				end
			else
				rowFrames[i].Visible = false
			end
		end

		-- Compute uniform text size + auto-scroll (deferred so layout has settled)
		task.defer(function()
			if myGeneration ~= fetchGeneration then return end

			-- Uniform text size:
			-- 1) Start from row-height limit
			-- 2) Reduce to the largest value that still fits all loaded row text
			--    within each text column's visible pixel width.
			local framePixelH = scrollingFrame.AbsoluteWindowSize.Y
			local rowPixelH = rowHeightFrame * framePixelH
			local heightLimitedSize = math.max(
				1,
				math.floor(rowPixelH * rowsCfg.TEXT_HEIGHT_RATIO)
			)
			local textSize = getBestFittingRowTextSize(entries, columns, math.min(N, MAX_ENTRIES), heightLimitedSize)
			for i = 1, math.min(N, MAX_ENTRIES) do
				for colIdx, colDef in ipairs(columns) do
					local colType = colDef.type or "text"
					if colType == "text" then
						columnElements[i][colIdx].TextSize = textSize
					end
				end
			end

			-- Auto-scroll to player's row
			if playerRowIndex then
				local canvasH = scrollingFrame.AbsoluteCanvasSize.Y
				local frameH = framePixelH
				if canvasH > frameH then
					local rowTopFrac = topPadCanvas + (playerRowIndex - 1) * rowUnitCanvas
					local rowCenterPx = (rowTopFrac + rowHeightCanvas / 2) * canvasH
					local scrollY = math.clamp(rowCenterPx - frameH / 2, 0, canvasH - frameH)
					scrollingFrame.CanvasPosition = Vector2.new(0, scrollY)
				end
			end
		end)
	end

	if result.playerRank then
		playerRankLabel.Text = string.format(LB.PLAYER_RANK.FORMAT, result.playerRank)
	else
		playerRankLabel.Text = LB.PLAYER_RANK.DEFAULT_TEXT
	end
end

--============================================================================
-- PUBLIC API
--============================================================================

function LeaderboardUI.init()
	-- Resolve remote in background (non-blocking); fetchAll also resolves
	-- on demand if show() is called before this completes
	task.spawn(ensureRemote)

	local partCfg = LB.PART
	local bbCfg = LB.BILLBOARD
	local ctrCfg = LB.CONTAINER
	local titleCfg = LB.TITLE
	local scrollCfg = LB.SCROLL
	local rowsCfg = LB.ROWS
	local prCfg = LB.PLAYER_RANK
	local emCfg = LB.EMPTY_MESSAGE
	local padX = ctrCfg.PADDING_X
	local contentWidth = 1 - 2 * padX

	-- Anchored invisible Part as billboard anchor
	billboardPart = Instance.new("Part")
	billboardPart.Name = partCfg.NAME
	billboardPart.Size = partCfg.SIZE
	billboardPart.Position = partCfg.POSITION
	basePartPosition = partCfg.POSITION
	billboardPart.Anchored = true
	billboardPart.CanCollide = false
	billboardPart.Transparency = partCfg.TRANSPARENCY
	billboardPart.Parent = workspace

	-- BillboardGui
	billboardGui = Instance.new("BillboardGui")
	billboardGui.Name = "LeaderboardBillboardGui"
	billboardGui.Adornee = billboardPart
	billboardGui.Size = bbCfg.SIZE
	baseBillboardSize = bbCfg.SIZE
	billboardGui.MaxDistance = bbCfg.MAX_DISTANCE
	billboardGui.AlwaysOnTop = bbCfg.ALWAYS_ON_TOP
	billboardGui.Active = true
	billboardGui.Enabled = false
	billboardGui.Parent = billboardPart

	-- Container
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundColor3 = ctrCfg.BG_COLOR
	container.BackgroundTransparency = ctrCfg.BG_TRANSPARENCY
	container.BorderSizePixel = 0
	container.Parent = billboardGui

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = ctrCfg.CORNER_RADIUS
	containerCorner.Parent = container

	-- Title
	local title = makeLabel({
		Name = "Title",
		Size = UDim2.new(1, 0, titleCfg.HEIGHT, 0),
		Position = UDim2.new(0, 0, titleCfg.Y, 0),
		Text = titleCfg.TEXT,
		TextColor3 = titleCfg.COLOR,
		Font = titleCfg.FONT,
		Parent = container,
	})
	title.TextStrokeTransparency = titleCfg.STROKE_TRANSPARENCY
	title.TextStrokeColor3 = titleCfg.STROKE_COLOR

	-- ScrollingFrame (between title and player-rank label)
	local scrollHeight = scrollCfg.END_Y - scrollCfg.START_Y
	scrollingFrame = Instance.new("ScrollingFrame")
	scrollingFrame.Name = "ScrollArea"
	scrollingFrame.Size = UDim2.new(contentWidth, 0, scrollHeight, 0)
	scrollingFrame.Position = UDim2.new(padX, 0, scrollCfg.START_Y, 0)
	scrollingFrame.BackgroundTransparency = 1
	scrollingFrame.BorderSizePixel = 0
	scrollingFrame.ScrollBarThickness = scrollCfg.BAR_THICKNESS
	scrollingFrame.ScrollBarImageColor3 = scrollCfg.BAR_COLOR
	scrollingFrame.ScrollBarImageTransparency = scrollCfg.BAR_TRANSPARENCY
	scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollingFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollingFrame.ElasticBehavior = Enum.ElasticBehavior.Never
	scrollingFrame.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scrollingFrame.Visible = false
	scrollingFrame.Parent = container

	-- Pre-create MAX_ENTRIES rows inside the ScrollingFrame.
	-- Sizes/positions are placeholders — fetchAll() recomputes them from
	-- VISIBLE_ROWS and the actual entry count so that Scale coordinates
	-- stay correct relative to the dynamic CanvasSize.
	local columns = LB.COLUMNS
	local rowWidth = rowsCfg.WIDTH
	local rowPadX = (1 - rowWidth) / 2

	-- Normalize column widths so they always fit within the row
	local totalGaps = math.max(0, #columns - 1) * rowsCfg.COLUMN_GAP
	local availableWidth = 1 - rowsCfg.COLUMN_PAD_LEFT - rowsCfg.COLUMN_PAD_RIGHT - totalGaps
	local rawSum = 0
	for _, colDef in ipairs(columns) do
		rawSum = rawSum + colDef.width
	end
	local colScale = if rawSum > 0 then availableWidth / rawSum else 1

	for i = 1, MAX_ENTRIES do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "Row_" .. i
		rowFrame.Size = UDim2.new(rowWidth, 0, 0, 0)
		rowFrame.Position = UDim2.new(rowPadX, 0, 0, 0)
		rowFrame.BackgroundColor3 = rowsCfg.BG_COLOR
		rowFrame.BackgroundTransparency = rowsCfg.BG_TRANSPARENCY
		rowFrame.BorderSizePixel = 0
		rowFrame.Visible = false
		rowFrame.Parent = scrollingFrame

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = rowsCfg.CORNER_RADIUS
		rowCorner.Parent = rowFrame

		-- Auto-layout columns left to right via type-specific creators
		columnElements[i] = {}
		local xCursor = rowsCfg.COLUMN_PAD_LEFT

		for colIdx, colDef in ipairs(columns) do
			local scaledWidth = colDef.width * colScale
			local colType = colDef.type or "text"
			local creator = COLUMN_CREATORS[colType]
			if creator then
				columnElements[i][colIdx] = creator(colDef, rowFrame, xCursor, scaledWidth)
			else
				warn("LeaderboardUI: unknown column type '" .. colType .. "'")
			end
			xCursor = xCursor + scaledWidth + rowsCfg.COLUMN_GAP
		end

		rowFrames[i] = rowFrame
	end

	-- Player rank label
	playerRankLabel = makeLabel({
		Name = "PlayerRank",
		Size = UDim2.new(contentWidth, 0, prCfg.HEIGHT, 0),
		Position = UDim2.new(padX, 0, prCfg.Y, 0),
		Text = prCfg.DEFAULT_TEXT,
		TextColor3 = prCfg.COLOR,
		Font = prCfg.FONT,
		Parent = container,
	})

	-- Empty state
	emptyMessage = makeLabel({
		Name = "EmptyMessage",
		Size = UDim2.new(contentWidth, 0, emCfg.HEIGHT, 0),
		Position = UDim2.new(padX, 0, emCfg.Y, 0),
		Text = emCfg.TEXT,
		TextColor3 = emCfg.COLOR,
		Font = emCfg.FONT,
		Parent = container,
	})
	emptyMessage.Visible = false

	------------------------------------------------------------------
	-- Manual scroll input with momentum (BillboardGui does not route
	-- wheel/touch events to ScrollingFrame children natively)
	------------------------------------------------------------------

	-- Helper: scroll the canvas by a pixel delta (positive = down)
	local function scrollBy(deltaY)
		if not scrollingFrame or not scrollingFrame.Visible then return end
		local canvasH = scrollingFrame.AbsoluteCanvasSize.Y
		local frameH = scrollingFrame.AbsoluteWindowSize.Y
		if canvasH <= frameH then return end
		local pos = scrollingFrame.CanvasPosition
		local newY = math.clamp(pos.Y + deltaY, 0, canvasH - frameH)
		scrollingFrame.CanvasPosition = Vector2.new(0, newY)
	end

	-- Helper: pixel height of one row in the current layout
	local function rowPixelHeight()
		local scrollCfgLocal = LB.SCROLL
		local usable = 1 - scrollCfgLocal.TOP_PADDING - scrollCfgLocal.BOTTOM_PADDING
		local rowUnit = usable / scrollCfgLocal.VISIBLE_ROWS
		return rowUnit * scrollingFrame.AbsoluteWindowSize.Y
	end

	-- Momentum: stop any active coast
	local function stopMomentum()
		scrollVelocity = 0
		if momentumConnection then
			momentumConnection:Disconnect()
			momentumConnection = nil
		end
	end

	-- Momentum: start the deceleration loop
	local function startMomentum()
		if momentumConnection then return end -- already running
		local decay = scrollCfg.MOMENTUM_DECAY
		local threshold = scrollCfg.MOMENTUM_MIN_VELOCITY
		momentumConnection = RunService.RenderStepped:Connect(function(dt)
			if math.abs(scrollVelocity) < threshold then
				stopMomentum()
				return
			end
			scrollBy(scrollVelocity * dt)
			-- Frame-rate independent decay: decay^(dt * 60)
			scrollVelocity = scrollVelocity * decay ^ (dt * 60)
		end)
	end

	-- Mouse wheel: each tick adds a velocity impulse.
	-- Impulse is auto-calibrated so a single tick scrolls ~WHEEL_ROWS rows
	-- over the full deceleration curve, regardless of MOMENTUM_DECAY.
	table.insert(inputConnections, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		if not LeaderboardUI.isMouseOver() then return end
		local impulseScale = (1 - scrollCfg.MOMENTUM_DECAY) * 60
		local impulse = -input.Position.Z * scrollCfg.WHEEL_ROWS * rowPixelHeight() * impulseScale
		scrollVelocity = scrollVelocity + impulse
		startMomentum()
	end))

	-- Touch drag: direct scroll + velocity tracking for momentum on release
	table.insert(inputConnections, UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end
		if not LeaderboardUI.isMouseOver() then return end
		stopMomentum()
		touchStartY = input.Position.Y
		touchStartCanvas = scrollingFrame.CanvasPosition.Y
		lastTouchY = input.Position.Y
		lastTouchTime = tick()
	end))

	table.insert(inputConnections, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end
		if touchStartY == nil then return end
		local now = tick()
		local deltaY = touchStartY - input.Position.Y -- drag up = scroll down

		-- Smooth velocity tracking for momentum on release.
		-- Exponential moving average prevents spikes from tiny dt intervals.
		local dt = now - (lastTouchTime or now)
		if dt > 0.005 then -- ignore sub-5ms intervals (noise)
			local instantVelocity = (lastTouchY - input.Position.Y) / dt
			scrollVelocity = scrollVelocity * 0.7 + instantVelocity * 0.3
		end
		lastTouchY = input.Position.Y
		lastTouchTime = now

		-- Direct scroll while finger is down
		scrollingFrame.CanvasPosition = Vector2.new(0,
			math.clamp(
				touchStartCanvas + deltaY,
				0,
				math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
			)
		)
	end))

	table.insert(inputConnections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end
		if touchStartY == nil then return end
		touchStartY = nil
		touchStartCanvas = nil
		-- Launch momentum from the tracked velocity
		if math.abs(scrollVelocity) > scrollCfg.MOMENTUM_MIN_VELOCITY then
			startMomentum()
		else
			scrollVelocity = 0
		end
		lastTouchY = nil
		lastTouchTime = nil
	end))

	-- Keep leaderboard size/anchor adaptive as camera/viewport changes.
	applyAdaptiveLayout()
	if adaptiveLayoutConnection then
		adaptiveLayoutConnection:Disconnect()
	end
	adaptiveLayoutConnection = RunService.RenderStepped:Connect(function()
		applyAdaptiveLayout()
	end)
end

function LeaderboardUI.isMouseOver()
	if not billboardPart or not billboardGui or not billboardGui.Enabled then return false end
	local camera = workspace.CurrentCamera
	if not camera then return false end

	local screenPos, onScreen = camera:WorldToViewportPoint(billboardPart.Position)
	if not onScreen then return false end

	local depth = screenPos.Z
	if depth <= 0 then return false end

	-- Convert billboard stud size to screen pixels using camera FOV and depth
	local bbSize = billboardGui.Size
	local studsW = bbSize.X.Scale
	local studsH = bbSize.Y.Scale
	local halfFOV = math.rad(camera.FieldOfView / 2)
	local pixelsPerStud = camera.ViewportSize.Y / (2 * depth * math.tan(halfFOV))
	local screenW = studsW * pixelsPerStud
	local screenH = studsH * pixelsPerStud

	-- Billboard is centered on the part's screen position
	local left = screenPos.X - screenW / 2
	local top = screenPos.Y - screenH / 2

	-- GetMouseLocation returns viewport coordinates (same space as WorldToViewportPoint)
	local mousePos = UserInputService:GetMouseLocation()
	return mousePos.X >= left and mousePos.X <= left + screenW
		and mousePos.Y >= top and mousePos.Y <= top + screenH
end

function LeaderboardUI.show()
	if not billboardGui then return end
	applyAdaptiveLayout()
	billboardGui.Enabled = true
	MissionManager.reportEvent("leaderboard_opened")
	fetchGeneration = fetchGeneration + 1
	task.spawn(fetchAll)

	-- Delayed re-fetch to pick up display names that were still resolving
	-- in the background during the initial fetch (off-screen entries).
	local gen = fetchGeneration
	task.delay(LB.REFETCH_DELAY, function()
		if gen == fetchGeneration then
			fetchAll()
		end
	end)
end

function LeaderboardUI.hide()
	if not billboardGui then return end
	billboardGui.Enabled = false
	fetchGeneration = fetchGeneration + 1
end

function LeaderboardUI.destroy()
	-- Stop momentum loop
	scrollVelocity = 0
	if momentumConnection then
		momentumConnection:Disconnect()
		momentumConnection = nil
	end
	if adaptiveLayoutConnection then
		adaptiveLayoutConnection:Disconnect()
		adaptiveLayoutConnection = nil
	end

	-- Disconnect manual scroll input handlers
	for _, conn in ipairs(inputConnections) do
		conn:Disconnect()
	end
	inputConnections = {}
	touchStartY = nil
	touchStartCanvas = nil
	lastTouchY = nil
	lastTouchTime = nil

	if billboardPart then
		billboardPart:Destroy()
		billboardPart = nil
		billboardGui = nil
	end
	scrollingFrame = nil
	rowFrames = {}
	columnElements = {}
	basePartPosition = nil
	baseBillboardSize = nil
end

return LeaderboardUI
