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
	6. Client requests all leaderboard entries via GetLeaderboardPage RemoteFunction
	7. Server returns full cached leaderboard (no DataStore reads per request)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local LeaderboardService = {}
local missionReporter = nil
local getPersonalBestRemoteRef = nil

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

local function reportMissionEvent(player, eventName, payload)
	if not missionReporter then return end
	local ok, err = pcall(function()
		missionReporter(player, eventName, payload)
	end)
	if not ok then
		warn("[LeaderboardService] Mission reporter failed:", err)
	end
end

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

	-- Phase 1: Fetch all entries from the OrderedDataStore (userId + score only)
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
						displayName = nil, -- resolved in phase 2
					})
				end
			end

			if collected >= maxEntries or pages.IsFinished then
				break
			end

			pages:AdvanceToNextPageAsync()
		end
	end)

	if not ok then
		warn("[LeaderboardService] Failed to refresh leaderboard cache: " .. tostring(err))
		return
	end

	-- Commit cache immediately so data is available for client requests.
	-- Display names may be nil — OnServerInvoke resolves priority names
	-- on demand and uses fallbacks for the rest.
	leaderboardCache = newCache
	rebuildRankIndex()

	-- Phase 2: Resolve all display names in parallel (non-blocking).
	-- Each GetNameFromUserIdAsync is an HTTP roundtrip (~50-200ms).
	-- Spawning them all at once turns N sequential calls into ~1 round.
	-- Results update entries in-place and populate displayNameCache.
	for _, entry in ipairs(newCache) do
		if not entry.displayName then
			task.spawn(function()
				entry.displayName = resolveDisplayName(entry.userId)
			end)
		end
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
	Injects a mission reporter callback.
	Callback signature: (player, eventName, payload) -> ()
]]
function LeaderboardService.setMissionReporter(callback)
	missionReporter = callback
end

--[[
	Debug-only helper: resets a player's personal best and removes them from leaderboard caches/stores.
	@param playerOrUserId Player|number
	@return boolean success, string? err
]]
function LeaderboardService.debugResetPlayer(playerOrUserId)
	local userId = nil
	local player = nil
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		player = playerOrUserId
		userId = player.UserId
	else
		userId = tonumber(playerOrUserId)
		if userId then
			player = Players:GetPlayerByUserId(userId)
		end
	end

	if not userId then
		return false, "Invalid player/userId"
	end

	if dataStoreAvailable and scoresDataStore then
		local ok, err = pcall(function()
			scoresDataStore:RemoveAsync("user_" .. userId)
		end)
		if not ok then
			warn("[LeaderboardService] Failed to reset personal best for user " .. userId .. ": " .. tostring(err))
			return false, tostring(err)
		end
	end

	if rankedDataStore then
		pcall(function()
			rankedDataStore:RemoveAsync("user_" .. userId)
		end)
	end

	cachedBests[userId] = 0
	for i = #leaderboardCache, 1, -1 do
		if leaderboardCache[i].userId == userId then
			table.remove(leaderboardCache, i)
			break
		end
	end
	rebuildRankIndex()

	if player and getPersonalBestRemoteRef then
		getPersonalBestRemoteRef:FireClient(player, 0)
	end

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
	getPersonalBestRemoteRef = getPersonalBestRemote

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
		reportMissionEvent(player, "score_submitted", {
			score = score,
			best = best,
		})
	end)

	-- Load leaderboard cache BEFORE creating GetLeaderboardPage remote.
	-- refreshLeaderboardCache blocks only on the DataStore fetch (fast);
	-- display name resolution is non-blocking (runs in parallel background
	-- tasks). The client's WaitForChild blocks until the remote is created
	-- below, guaranteeing the cache has entries (names may still be loading).
	refreshLeaderboardCache()

	-- GetLeaderboardPage: client requests a page of leaderboard entries.
	-- Resolves display names for entries visible to the requesting player
	-- on demand, using fallback names for off-screen entries still loading.
	local getLeaderboardPageRemote = remoteFolder:FindFirstChild("GetLeaderboardPage")
	if not getLeaderboardPageRemote then
		getLeaderboardPageRemote = Instance.new("RemoteFunction")
		getLeaderboardPageRemote.Name = "GetLeaderboardPage"
		getLeaderboardPageRemote.Parent = remoteFolder
	end

	local visibleRadius = math.floor(GameConfig.LEADERBOARD.SCROLL.VISIBLE_ROWS / 2)

	getLeaderboardPageRemote.OnServerInvoke = function(player)
		local playerUserId = player.UserId
		local playerRank = playerRankIndex[playerUserId]

		-- Determine the priority window (entries the client will see on screen)
		local priorityStart, priorityEnd
		if playerRank then
			priorityStart = math.max(1, playerRank - visibleRadius)
			priorityEnd = math.min(#leaderboardCache, playerRank + visibleRadius)
		else
			-- Unranked player: leaderboard starts scrolled to the top
			priorityStart = 1
			priorityEnd = math.min(#leaderboardCache, visibleRadius * 2 + 1)
		end

		-- Ensure priority entries have resolved display names.
		-- resolveDisplayName checks displayNameCache first (instant if the
		-- background task already resolved it), so this only blocks for
		-- names that genuinely haven't been fetched yet.
		for i = priorityStart, priorityEnd do
			local e = leaderboardCache[i]
			if e and not e.displayName then
				e.displayName = resolveDisplayName(e.userId)
			end
		end

		local entries = {}
		for i, e in ipairs(leaderboardCache) do
			table.insert(entries, {
				rank = i,
				displayName = e.displayName or ("Player_" .. e.userId),
				score = e.score,
				userId = e.userId,
			})
		end

		return {
			entries = entries,
			playerRank = playerRank,
			totalEntries = #leaderboardCache,
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

	-- Start periodic refresh for subsequent updates
	task.spawn(function()
		while true do
			task.wait(GameConfig.LEADERBOARD.CACHE_REFRESH_INTERVAL)
			refreshLeaderboardCache()
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
		{ name = "xXFlappyGodXx",     score = 312 },
		{ name = "OofMaster9000",      score = 287 },
		{ name = "PipeQueen99",        score = 256 },
		{ name = "BloxBirdPro",        score = 231 },
		{ name = "NoobSlayer_Flap",    score = 200 },
		{ name = "RobuxRichie",        score = 189 },
		{ name = "FlapJack_YT",        score = 175 },
		{ name = "ii_BirdBoy",         score = 163 },
		{ name = "ObbyKing2024",       score = 150 },
		{ name = "MegaFlapper",        score = 142 },
		{ name = "GapDodger",          score = 133 },
		{ name = "xX_PipeDream_Xx",    score = 127 },
		{ name = "FlappyPhoenix",      score = 118 },
		{ name = "SkyDiver_Pro",       score = 112 },
		{ name = "BirdNerd42",         score = 105 },
		{ name = "WingsOfSteel",       score = 100 },
		{ name = "TiltedTowers_Fan",   score = 94 },
		{ name = "PipeSurvivor",       score = 89 },
		{ name = "FlutterKing",        score = 83 },
		{ name = "OofInPeace",         score = 78 },
		{ name = "CasualCarl",         score = 73 },
		{ name = "BloxBirdie",         score = 68 },
		{ name = "NeverGiveUp99",      score = 64 },
		{ name = "FlapAttack",         score = 59 },
		{ name = "PixelPigeon",        score = 55 },
		{ name = "TurboFlapper",       score = 52 },
		{ name = "LuckyLucy",          score = 48 },
		{ name = "GravityHater",       score = 45 },
		{ name = "PipeNightmare",      score = 42 },
		{ name = "BirdBrain_lol",      score = 40 },
		{ name = "gg_ez_flap",         score = 37 },
		{ name = "RobloxRookie",       score = 35 },
		{ name = "JumpSpammer",        score = 32 },
		{ name = "FlapOrDie",          score = 30 },
		{ name = "NewbieNate",         score = 28 },
		{ name = "WingClipperX",       score = 26 },
		{ name = "PipeDreamer",        score = 24 },
		{ name = "FlappyNoob123",      score = 23 },
		{ name = "AngryBloxBird",      score = 21 },
		{ name = "TryHardTim",         score = 19 },
		{ name = "SkyFaller",          score = 17 },
		{ name = "GapMisser",          score = 15 },
		{ name = "OofEveryTime",       score = 13 },
		{ name = "AlmostMadeIt",       score = 11 },
		{ name = "PanicFlapper",       score = 10 },
		{ name = "GroundPounder",      score = 8 },
		{ name = "OneMoreTry",         score = 7 },
		{ name = "PlsHelpMe",          score = 5 },
		{ name = "FirstTimer_lol",     score = 4 },
		{ name = "LiterallyMe",        score = 3 },
		{ name = "Oops_I_Died",        score = 2 },
		{ name = "TouchedAPipe",       score = 1 },
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
