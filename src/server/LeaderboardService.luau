--[[
	LeaderboardService.luau
	
	Server-side service for global leaderboard and per-player best scores.
	Uses DataStoreService to persist scores.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

-- Try to get DataStore, but handle case when not available (Studio testing)
local scoresDataStore = nil
local leaderboardDataStore = nil
local dataStoreAvailable = false

local success, _ = pcall(function()
	scoresDataStore = DataStoreService:GetDataStore("FlappyBirdScores")
	leaderboardDataStore = DataStoreService:GetDataStore("FlappyBirdLeaderboard")
	dataStoreAvailable = true
end)

if not dataStoreAvailable then
	warn("DataStore not available - running in Studio mode. Leaderboard features will work in-memory only.")
end

local globalLeaderboard = {} -- In-memory cache of top players
local MAX_LEADERBOARD_SIZE = 100

--[[
	Retries a DataStore operation with exponential backoff.
	@param func function - Function to retry
	@param maxRetries number - Maximum number of retries
	@return any - Result of the function
]]
local function retryDataStore(func, maxRetries)
	maxRetries = maxRetries or 3
	local retries = 0
	
	while retries < maxRetries do
		local success, result = pcall(func)
		if success then
			return result
		end
		
		retries = retries + 1
		if retries < maxRetries then
			wait(math.pow(2, retries)) -- Exponential backoff
		end
	end
	
	warn("DataStore operation failed after " .. maxRetries .. " retries")
	return nil
end

--[[
	Gets a player's personal best score.
	@param userId number - User ID of the player
	@return number - Personal best score, or 0 if not found
]]
function LeaderboardService.getPlayerBest(userId)
	if not dataStoreAvailable or not scoresDataStore then
		-- In Studio mode, return 0
		return 0
	end
	
	local success, bestScore = retryDataStore(function()
		return scoresDataStore:GetAsync("user_" .. userId)
	end)
	
	if success and bestScore then
		return bestScore
	end
	
	return 0
end

--[[
	Updates a player's personal best score if the new score is higher.
	@param userId number - User ID of the player
	@param score number - New score
	@return boolean - True if score was updated
]]
function LeaderboardService.updatePlayerBest(userId, score)
	if not dataStoreAvailable or not scoresDataStore then
		-- In Studio mode, still update in-memory leaderboard
		LeaderboardService.updateGlobalLeaderboard(userId, score)
		return true
	end
	
	local currentBest = LeaderboardService.getPlayerBest(userId)
	
	if score > currentBest then
		retryDataStore(function()
			scoresDataStore:SetAsync("user_" .. userId, score)
		end)
		
		-- Update global leaderboard
		LeaderboardService.updateGlobalLeaderboard(userId, score)
		
		return true
	end
	
	return false
end

--[[
	Updates the global leaderboard with a new score.
	@param userId number - User ID of the player
	@param score number - Score to add/update
]]
function LeaderboardService.updateGlobalLeaderboard(userId, score)
	-- Add or update entry
	local found = false
	for i, entry in ipairs(globalLeaderboard) do
		if entry.userId == userId then
			if score > entry.score then
				entry.score = score
				found = true
				break
			else
				return -- Score not higher, no update needed
			end
		end
	end
	
	if not found then
		table.insert(globalLeaderboard, {userId = userId, score = score})
	end
	
	-- Sort by score (descending)
	table.sort(globalLeaderboard, function(a, b)
		return a.score > b.score
	end)
	
	-- Keep only top N
	if #globalLeaderboard > MAX_LEADERBOARD_SIZE then
		for i = MAX_LEADERBOARD_SIZE + 1, #globalLeaderboard do
			globalLeaderboard[i] = nil
		end
	end
	
	-- Save to DataStore (if available)
	if dataStoreAvailable and leaderboardDataStore then
		retryDataStore(function()
			leaderboardDataStore:SetAsync("top_players", globalLeaderboard)
		end)
	end
end

--[[
	Gets the top N players from the global leaderboard.
	@param n number - Number of players to get
	@return table - Array of {userId, score} entries
]]
function LeaderboardService.getTopPlayers(n)
	n = n or 10
	local result = {}
	
	for i = 1, math.min(n, #globalLeaderboard) do
		table.insert(result, globalLeaderboard[i])
	end
	
	return result
end

--[[
	Loads the global leaderboard from DataStore.
]]
function LeaderboardService.loadLeaderboard()
	if not dataStoreAvailable or not leaderboardDataStore then
		-- In Studio mode, start with empty leaderboard
		globalLeaderboard = {}
		return
	end
	
	local success, data = retryDataStore(function()
		return leaderboardDataStore:GetAsync("top_players")
	end)
	
	if success and data then
		globalLeaderboard = data
	else
		globalLeaderboard = {}
	end
end

--[[
	Initializes the LeaderboardService.
]]
function LeaderboardService.init()
	LeaderboardService.loadLeaderboard()
	
	-- Set up RemoteEvents
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end
	
	local submitScoreRemote = remoteFolder:FindFirstChild("SubmitScore")
	if submitScoreRemote then
		submitScoreRemote.OnServerEvent:Connect(function(player, score)
			local userId = player.UserId
			LeaderboardService.updatePlayerBest(userId, score)
		end)
	end
	
	local getPersonalBestRemote = remoteFolder:FindFirstChild("GetPersonalBest")
	if getPersonalBestRemote then
		getPersonalBestRemote.OnServerEvent:Connect(function(player)
			local userId = player.UserId
			local best = LeaderboardService.getPlayerBest(userId)
			getPersonalBestRemote:FireClient(player, best)
		end)
	end
	
	local getLeaderboardRemote = remoteFolder:FindFirstChild("GetLeaderboard")
	if not getLeaderboardRemote then
		getLeaderboardRemote = Instance.new("RemoteEvent")
		getLeaderboardRemote.Name = "GetLeaderboard"
		getLeaderboardRemote.Parent = remoteFolder
	end
	
	getLeaderboardRemote.OnServerEvent:Connect(function(player, n)
		n = n or 10
		local topPlayers = LeaderboardService.getTopPlayers(n)
		getLeaderboardRemote:FireClient(player, topPlayers)
	end)
end

return LeaderboardService
