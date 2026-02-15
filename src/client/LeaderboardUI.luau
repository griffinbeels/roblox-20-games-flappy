--[[
	LeaderboardUI.luau

	Scrollable global leaderboard panel shown during the READY state.
	Displays 5 entries at a time, centered on the current player's rank.
	Follows the same init()/show()/hide()/destroy() pattern as other UI modules.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local LeaderboardUI = {}

local localPlayer = Players.LocalPlayer
local screenGui = nil
local getLeaderboardPageRemote = nil

-- Row UI references
local rowFrames = {}    -- Array of 5 row frames
local rankLabels = {}   -- Array of 5 rank TextLabels
local nameLabels = {}   -- Array of 5 name TextLabels
local scoreLabels = {}  -- Array of 5 score TextLabels

-- Navigation UI references
local scrollUpButton = nil
local scrollDownButton = nil
local playerRankLabel = nil
local emptyMessage = nil

-- State
local currentStartRank = 1
local totalEntries = 0
local isLoading = false
local fetchGeneration = 0  -- incremented on each show(); stale fetches are discarded

local PAGE_SIZE = GameConfig.LEADERBOARD.PAGE_SIZE

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
	label.TextSize = props.TextSize or 14
	label.Font = props.Font or Enum.Font.GothamBold
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = props.Parent
	return label
end

--============================================================================
-- DATA FETCHING
--============================================================================

local function fetchPage(centerOnSelf, startRank)
	if not getLeaderboardPageRemote then return end

	-- Capture the current generation so we can discard stale responses
	local myGeneration = fetchGeneration

	local ok, result = pcall(function()
		return getLeaderboardPageRemote:InvokeServer(centerOnSelf, startRank)
	end)

	-- If hide()/show() was called while we were yielded, discard this response
	if myGeneration ~= fetchGeneration then return end

	if ok and result then
		currentStartRank = result.startRank or 1
		totalEntries = result.totalEntries or 0

		local entries = result.entries or {}
		local playerUserId = localPlayer.UserId

		-- Show/hide empty state
		if totalEntries == 0 then
			emptyMessage.Visible = true
			for i = 1, PAGE_SIZE do
				rowFrames[i].Visible = false
			end
		else
			emptyMessage.Visible = false

			for i = 1, PAGE_SIZE do
				if i <= #entries then
					local entry = entries[i]
					rowFrames[i].Visible = true
					rankLabels[i].Text = "#" .. entry.rank
					nameLabels[i].Text = entry.displayName
					scoreLabels[i].Text = tostring(entry.score)

					-- Highlight current player's row
					if entry.userId == playerUserId then
						rowFrames[i].BackgroundColor3 = Color3.fromRGB(255, 215, 0)
						rowFrames[i].BackgroundTransparency = 0.7
					else
						rowFrames[i].BackgroundColor3 = Color3.fromRGB(40, 35, 25)
						rowFrames[i].BackgroundTransparency = 0.5
					end
				else
					rowFrames[i].Visible = false
				end
			end
		end

		-- Update scroll button visibility
		scrollUpButton.Visible = currentStartRank > 1
		scrollDownButton.Visible = (currentStartRank + PAGE_SIZE - 1) < totalEntries

		-- Update player rank label
		if result.playerRank then
			playerRankLabel.Text = "Your Rank: #" .. result.playerRank
		else
			playerRankLabel.Text = "Play to get ranked!"
		end
	end
end

--============================================================================
-- PUBLIC API
--============================================================================

function LeaderboardUI.init()
	-- Find remote in background to avoid yielding the caller
	task.spawn(function()
		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remoteFolder then
			getLeaderboardPageRemote = remoteFolder:WaitForChild("GetLeaderboardPage", 10)
		end
	end)

	-- Create ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LeaderboardUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 5
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Container (left third of screen)
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0.28, 0, 0.55, 0)
	container.Position = UDim2.new(0.02, 0, 0.22, 0)
	container.BackgroundColor3 = Color3.fromRGB(30, 25, 15)
	container.BackgroundTransparency = 0.3
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 10)
	containerCorner.Parent = container

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 30)
	title.Position = UDim2.new(0, 0, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "LEADERBOARD"
	title.TextColor3 = Color3.fromRGB(255, 180, 50)
	title.TextSize = 18
	title.Font = Enum.Font.GothamBlack
	title.TextStrokeTransparency = 0.4
	title.TextStrokeColor3 = Color3.fromRGB(80, 50, 10)
	title.Parent = container

	-- Scroll Up Button
	scrollUpButton = Instance.new("TextButton")
	scrollUpButton.Name = "ScrollUp"
	scrollUpButton.Size = UDim2.new(1, -20, 0, 22)
	scrollUpButton.Position = UDim2.new(0, 10, 0, 40)
	scrollUpButton.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
	scrollUpButton.BackgroundTransparency = 0.5
	scrollUpButton.BorderSizePixel = 0
	scrollUpButton.Text = "▲"
	scrollUpButton.TextColor3 = Color3.fromRGB(200, 180, 140)
	scrollUpButton.TextSize = 14
	scrollUpButton.Font = Enum.Font.GothamBold
	scrollUpButton.AutoButtonColor = true
	scrollUpButton.Selectable = false
	scrollUpButton.Visible = false
	scrollUpButton.Parent = container

	local upCorner = Instance.new("UICorner")
	upCorner.CornerRadius = UDim.new(0, 4)
	upCorner.Parent = scrollUpButton

	scrollUpButton.MouseButton1Click:Connect(function()
		task.spawn(fetchPage, false, currentStartRank - PAGE_SIZE)
	end)

	-- Row area (5 rows)
	local rowAreaY = 66
	local rowHeight = 0.13 -- fraction of container height per row
	local rowGap = 4       -- pixels between rows

	for i = 1, PAGE_SIZE do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "Row_" .. i
		rowFrame.Size = UDim2.new(1, -20, rowHeight, -rowGap)
		rowFrame.Position = UDim2.new(0, 10, 0, rowAreaY + (i - 1) * (rowHeight * 300 + rowGap))
		-- Use absolute positioning to be safe
		rowFrame.Size = UDim2.new(1, -20, 0, 34)
		rowFrame.Position = UDim2.new(0, 10, 0, rowAreaY + (i - 1) * 38)
		rowFrame.BackgroundColor3 = Color3.fromRGB(40, 35, 25)
		rowFrame.BackgroundTransparency = 0.5
		rowFrame.BorderSizePixel = 0
		rowFrame.Visible = false
		rowFrame.Parent = container

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 4)
		rowCorner.Parent = rowFrame

		-- Rank label (left)
		local rankLabel = makeLabel({
			Name = "Rank",
			Size = UDim2.new(0.2, 0, 1, 0),
			Position = UDim2.new(0, 4, 0, 0),
			Text = "#1",
			TextColor3 = Color3.fromRGB(255, 180, 50),
			TextSize = 14,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = rowFrame,
		})

		-- Name label (center)
		local nameLabel = makeLabel({
			Name = "Name",
			Size = UDim2.new(0.5, 0, 1, 0),
			Position = UDim2.new(0.2, 0, 0, 0),
			Text = "Player",
			TextColor3 = Color3.fromRGB(230, 220, 200),
			TextSize = 13,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = rowFrame,
		})

		-- Score label (right)
		local scoreLabel = makeLabel({
			Name = "Score",
			Size = UDim2.new(0.25, -4, 1, 0),
			Position = UDim2.new(0.75, 0, 0, 0),
			Text = "0",
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 14,
			Font = Enum.Font.GothamBlack,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = rowFrame,
		})

		rowFrames[i] = rowFrame
		rankLabels[i] = rankLabel
		nameLabels[i] = nameLabel
		scoreLabels[i] = scoreLabel
	end

	-- Scroll Down Button
	local scrollDownY = rowAreaY + PAGE_SIZE * 38 + 4
	scrollDownButton = Instance.new("TextButton")
	scrollDownButton.Name = "ScrollDown"
	scrollDownButton.Size = UDim2.new(1, -20, 0, 22)
	scrollDownButton.Position = UDim2.new(0, 10, 0, scrollDownY)
	scrollDownButton.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
	scrollDownButton.BackgroundTransparency = 0.5
	scrollDownButton.BorderSizePixel = 0
	scrollDownButton.Text = "▼"
	scrollDownButton.TextColor3 = Color3.fromRGB(200, 180, 140)
	scrollDownButton.TextSize = 14
	scrollDownButton.Font = Enum.Font.GothamBold
	scrollDownButton.AutoButtonColor = true
	scrollDownButton.Selectable = false
	scrollDownButton.Visible = false
	scrollDownButton.Parent = container

	local downCorner = Instance.new("UICorner")
	downCorner.CornerRadius = UDim.new(0, 4)
	downCorner.Parent = scrollDownButton

	scrollDownButton.MouseButton1Click:Connect(function()
		task.spawn(fetchPage, false, currentStartRank + PAGE_SIZE)
	end)

	-- Player rank label (bottom)
	playerRankLabel = makeLabel({
		Name = "PlayerRank",
		Size = UDim2.new(1, -20, 0, 24),
		Position = UDim2.new(0, 10, 1, -32),
		Text = "Play to get ranked!",
		TextColor3 = Color3.fromRGB(200, 180, 140),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		Parent = container,
	})

	-- Empty state message
	emptyMessage = makeLabel({
		Name = "EmptyMessage",
		Size = UDim2.new(1, -20, 0, 100),
		Position = UDim2.new(0, 10, 0.3, 0),
		Text = "No scores yet",
		TextColor3 = Color3.fromRGB(180, 160, 130),
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		Parent = container,
	})
	emptyMessage.Visible = false
end

function LeaderboardUI.show()
	if not screenGui then return end
	screenGui.Enabled = true
	-- Bump generation to invalidate any in-flight fetches from a previous show/hide cycle
	fetchGeneration = fetchGeneration + 1
	-- Fetch centered on self (non-blocking to avoid yielding the caller)
	task.spawn(fetchPage, true, nil)
end

function LeaderboardUI.hide()
	if not screenGui then return end
	screenGui.Enabled = false
	-- Invalidate any in-flight fetches so they don't update UI after hide
	fetchGeneration = fetchGeneration + 1
	-- Clear any GUI focus left by scroll buttons so it can't interfere with game input
	if GuiService.SelectedObject then
		GuiService.SelectedObject = nil
	end
end

function LeaderboardUI.destroy()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	rowFrames = {}
	rankLabels = {}
	nameLabels = {}
	scoreLabels = {}
end

return LeaderboardUI
