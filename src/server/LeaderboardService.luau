--[[
	LeaderboardService.luau

	Server-side service for per-player best scores and global leaderboard.
	Uses DataStoreService to persist scores across sessions.
	Uses OrderedDataStore for ranked global leaderboard with server-side cache.

	FLOW:
	1. On player join → client requests personal best via GetPersonalBest remote
	2. Server reads from DataStore (or in-memory cache), returns to client
	3. On game over → client submits final score via SubmitScore remote
	4. Server checks if score > stored best, saves to DataStore if so
	5. Server fires back the (possibly updated) personal best to client
	6. Client requests leaderboard page via GetLeaderboardPage RemoteFunction
	7. Server returns cached leaderboard slice (no DataStore reads per request)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local LeaderboardService = {}

-- DataStore handles
local scoresDataStore = nil
local rankedDataStore = nil
local dataStoreAvailable = false

local initSuccess, _ = pcall(function()
	scoresDataStore = DataStoreService:GetDataStore("FlappyBirdScores")
	dataStoreAvailable = true
end)

pcall(function()
	rankedDataStore = DataStoreService:GetOrderedDataStore("FlappyBirdRanked")
end)

if not dataStoreAvailable then
	warn("[LeaderboardService] DataStore not available — scores will persist in-memory only (Studio mode).")
end

-- In-memory cache: userId → best score
-- Populated on first fetch, updated on new high score.
-- Avoids redundant DataStore reads within a session.
local cachedBests = {}

-- Global leaderboard cache (sorted descending by score)
local leaderboardCache = {}   -- Array: {userId, score, displayName}
local playerRankIndex = {}    -- Map: userId -> rank (1-based)
local displayNameCache = {}   -- Map: userId -> displayName (persistent)

--[[
	Resolves a display name for a userId, using cache first.
	@param userId number
	@return string
]]
local function resolveDisplayName(userId)
	if displayNameCache[userId] then
		return displayNameCache[userId]
	end

	local name = "Player_" .. userId
	local ok, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and result then
		name = result
	end

	displayNameCache[userId] = name
	return name
end

--[[
	Rebuilds the playerRankIndex map from the leaderboardCache array.
]]
local function rebuildRankIndex()
	playerRankIndex = {}
	for i, entry in ipairs(leaderboardCache) do
		playerRankIndex[entry.userId] = i
	end
end

--[[
	Updates the leaderboard cache in-place after a new high score.
	@param userId number
	@param score number
]]
local function updateCacheInPlace(userId, score)
	-- Remove old entry for this user (if exists)
	for i = #leaderboardCache, 1, -1 do
		if leaderboardCache[i].userId == userId then
			table.remove(leaderboardCache, i)
			break
		end
	end

	-- Find correct sorted position (descending by score)
	local insertPos = #leaderboardCache + 1
	for i, entry in ipairs(leaderboardCache) do
		if score > entry.score then
			insertPos = i
			break
		end
	end

	-- Trim if at max
	if insertPos > GameConfig.LEADERBOARD.MAX_ENTRIES then
		rebuildRankIndex()
		return
	end

	local displayName = resolveDisplayName(userId)
	table.insert(leaderboardCache, insertPos, {
		userId = userId,
		score = score,
		displayName = displayName,
	})

	-- Trim to max entries
	while #leaderboardCache > GameConfig.LEADERBOARD.MAX_ENTRIES do
		table.remove(leaderboardCache)
	end

	rebuildRankIndex()
end

--[[
	Refreshes the leaderboard cache from the OrderedDataStore.
]]
local function refreshLeaderboardCache()
	if not rankedDataStore then
		return
	end

	local maxEntries = GameConfig.LEADERBOARD.MAX_ENTRIES
	local newCache = {}
	local collected = 0

	local ok, err = pcall(function()
		local pages = rankedDataStore:GetSortedAsync(false, math.min(maxEntries, 100))

		while true do
			local entries = pages:GetCurrentPage()
			for _, entry in ipairs(entries) do
				if collected >= maxEntries then
					break
				end

				-- Keys are "user_123" format
				local userIdStr = string.match(entry.key, "user_(%d+)")
				if userIdStr then
					local userId = tonumber(userIdStr)
					collected = collected + 1
					table.insert(newCache, {
						userId = userId,
						score = entry.value,
						displayName = resolveDisplayName(userId),
					})
				end
			end

			if collected >= maxEntries or pages.IsFinished then
				break
			end

			pages:AdvanceToNextPageAsync()
		end
	end)

	if ok then
		leaderboardCache = newCache
		rebuildRankIndex()
	else
		warn("[LeaderboardService] Failed to refresh leaderboard cache: " .. tostring(err))
	end
end

--[[
	Reads a player's best score.
	Checks in-memory cache first, then DataStore.
	@param userId number
	@return number - Best score (0 if none)
]]
local function readPlayerBest(userId)
	-- Return cached value if we already fetched this session
	if cachedBests[userId] ~= nil then
		return cachedBests[userId]
	end

	-- Try DataStore
	if dataStoreAvailable and scoresDataStore then
		local ok, result = pcall(function()
			return scoresDataStore:GetAsync("user_" .. userId)
		end)
		if ok and result then
			cachedBests[userId] = result
			return result
		end
	end

	-- No stored score
	cachedBests[userId] = 0
	return 0
end

--[[
	Saves a new high score for a player.
	Uses UpdateAsync for atomicity — two servers can never overwrite each
	other's higher score, even if the same player is on multiple devices.
	@param userId number
	@param score number
	@return boolean - True if a new high score was saved
]]
local function savePlayerBest(userId, score)
	local currentBest = readPlayerBest(userId)

	if score <= currentBest then
		return false
	end

	if dataStoreAvailable and scoresDataStore then
		local ok, err = pcall(function()
			scoresDataStore:UpdateAsync("user_" .. userId, function(oldValue)
				oldValue = oldValue or 0
				if score > oldValue then
					return score
				end
				return nil -- Return nil = don't update
			end)
		end)
		if not ok then
			warn("[LeaderboardService] Failed to save score for user " .. userId .. ": " .. tostring(err))
		end
	end

	-- Also write to the ranked OrderedDataStore
	if rankedDataStore then
		pcall(function()
			rankedDataStore:SetAsync("user_" .. userId, score)
		end)
	end

	-- Update local cache to the highest known value
	cachedBests[userId] = math.max(score, currentBest)

	-- Update leaderboard cache in-place for near-instant visibility
	updateCacheInPlace(userId, score)

	return true
end

--[[
	Initializes the LeaderboardService.
	Creates RemoteEvents/RemoteFunctions and wires up server handlers.
	Starts periodic leaderboard cache refresh.
]]
function LeaderboardService.init()
	-- Ensure Remotes folder exists
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	-- GetPersonalBest: client requests their stored high score
	local getPersonalBestRemote = remoteFolder:FindFirstChild("GetPersonalBest")
	if not getPersonalBestRemote then
		getPersonalBestRemote = Instance.new("RemoteEvent")
		getPersonalBestRemote.Name = "GetPersonalBest"
		getPersonalBestRemote.Parent = remoteFolder
	end

	getPersonalBestRemote.OnServerEvent:Connect(function(player)
		local best = readPlayerBest(player.UserId)
		getPersonalBestRemote:FireClient(player, best)
	end)

	-- SubmitScore: client sends final score after game over
	local submitScoreRemote = remoteFolder:FindFirstChild("SubmitScore")
	if not submitScoreRemote then
		submitScoreRemote = Instance.new("RemoteEvent")
		submitScoreRemote.Name = "SubmitScore"
		submitScoreRemote.Parent = remoteFolder
	end

	submitScoreRemote.OnServerEvent:Connect(function(player, score)
		if type(score) ~= "number" or score < 0 then
			return -- Ignore invalid data
		end

		savePlayerBest(player.UserId, score)

		-- Always fire back the current best so client stays in sync
		local best = cachedBests[player.UserId] or 0
		getPersonalBestRemote:FireClient(player, best)
	end)

	-- GetLeaderboardPage: client requests a page of leaderboard entries
	local getLeaderboardPageRemote = remoteFolder:FindFirstChild("GetLeaderboardPage")
	if not getLeaderboardPageRemote then
		getLeaderboardPageRemote = Instance.new("RemoteFunction")
		getLeaderboardPageRemote.Name = "GetLeaderboardPage"
		getLeaderboardPageRemote.Parent = remoteFolder
	end

	getLeaderboardPageRemote.OnServerInvoke = function(player, centerOnSelf, startRank)
		local PAGE_SIZE = GameConfig.LEADERBOARD.PAGE_SIZE

		if centerOnSelf then
			local rank = playerRankIndex[player.UserId]
			if rank then
				startRank = math.max(1, rank - math.floor(PAGE_SIZE / 2))
			else
				startRank = 1 -- unranked: show top entries
			end
		end

		-- Clamp
		startRank = math.clamp(startRank or 1, 1, math.max(1, #leaderboardCache - PAGE_SIZE + 1))

		-- Slice entries
		local entries = {}
		for i = startRank, math.min(startRank + PAGE_SIZE - 1, #leaderboardCache) do
			local e = leaderboardCache[i]
			table.insert(entries, {
				rank = i,
				displayName = e.displayName,
				score = e.score,
				userId = e.userId,
			})
		end

		return {
			entries = entries,
			playerRank = playerRankIndex[player.UserId],
			totalEntries = #leaderboardCache,
			startRank = startRank,
		}
	end

	-- PopulateTestData: debug remote for command bar (Studio only)
	local populateTestRemote = Instance.new("RemoteEvent")
	populateTestRemote.Name = "PopulateTestData"
	populateTestRemote.Parent = remoteFolder

	populateTestRemote.OnServerEvent:Connect(function(player)
		LeaderboardService.populateTestData()
	end)

	local clearLeaderboardRemote = Instance.new("RemoteEvent")
	clearLeaderboardRemote.Name = "ClearLeaderboard"
	clearLeaderboardRemote.Parent = remoteFolder

	clearLeaderboardRemote.OnServerEvent:Connect(function(player)
		LeaderboardService.clearLeaderboard()
	end)

	-- Start periodic leaderboard cache refresh
	task.spawn(function()
		while true do
			refreshLeaderboardCache()
			task.wait(GameConfig.LEADERBOARD.CACHE_REFRESH_INTERVAL)
		end
	end)
end

--============================================================================
-- TEST DATA (call from command bar or server script)
--============================================================================

--[[
	Adds a single test entry to the leaderboard cache AND persists to DataStore.
	@param name string - Display name
	@param score number - Score value
	@param fakeUserId number? - Optional fake userId (auto-generated if nil)
]]
function LeaderboardService.addTestEntry(name, score, fakeUserId)
	fakeUserId = fakeUserId or (1000000 + #leaderboardCache + math.random(1, 99999))
	displayNameCache[fakeUserId] = name
	updateCacheInPlace(fakeUserId, score)

	-- Persist to OrderedDataStore
	if rankedDataStore then
		local ok, err = pcall(function()
			rankedDataStore:SetAsync("user_" .. fakeUserId, score)
		end)
		if not ok then
			warn("[LeaderboardService] Failed to persist test entry " .. name .. ": " .. tostring(err))
		end
	end
end

--[[
	Populates the leaderboard with default test data (persisted to DataStore).
	From command bar: game.ReplicatedStorage.Remotes.PopulateTestData:FireServer()
]]
function LeaderboardService.populateTestData()
	local testUsers = {
		{ name = "xXDragonSlayerXx", score = 200 },
		{ name = "PipeQueen99",      score = 100 },
		{ name = "FlappyMaster",     score = 80 },
		{ name = "BirdBrain42",      score = 79 },
		{ name = "SkyDiver_Pro",     score = 78 },
		{ name = "CasualCarl",       score = 50 },
		{ name = "NewbieNate",       score = 40 },
		{ name = "LuckyLucy",        score = 30 },
		{ name = "TryHardTim",       score = 20 },
		{ name = "JustStarted",      score = 10 },
		{ name = "OneMoreTry",       score = 5 },
		{ name = "AlmostGotIt",      score = 4 },
		{ name = "Oops",             score = 3 },
		{ name = "FirstTimer",       score = 2 },
		{ name = "LiterallyMe",     score = 1 },
	}

	for i, user in ipairs(testUsers) do
		LeaderboardService.addTestEntry(user.name, user.score, 1000000 + i)
	end

	print("[LeaderboardService] Populated " .. #testUsers .. " test entries (persisted to DataStore).")
end

--[[
	Clears ALL entries from the ranked OrderedDataStore and the in-memory cache.
	From command bar: game.ReplicatedStorage.Remotes.ClearLeaderboard:FireServer()
]]
function LeaderboardService.clearLeaderboard()
	local removed = 0

	-- Clear from OrderedDataStore
	if rankedDataStore then
		-- Read all keys from the store and remove them
		local ok, err = pcall(function()
			local pages = rankedDataStore:GetSortedAsync(false, 100)
			while true do
				local entries = pages:GetCurrentPage()
				for _, entry in ipairs(entries) do
					pcall(function()
						rankedDataStore:RemoveAsync(entry.key)
					end)
					removed = removed + 1
				end
				if pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
		end)
		if not ok then
			warn("[LeaderboardService] Error during clear: " .. tostring(err))
		end
	end

	-- Clear in-memory cache
	leaderboardCache = {}
	playerRankIndex = {}

	print("[LeaderboardService] Cleared leaderboard (" .. removed .. " entries removed from DataStore).")
end

return LeaderboardService
