--[[
	ScoreManager.luau

	Tracks pipes passed and communicates with server for high score persistence.

	FLOW:
	1. On init: request stored personal best from server, cache locally
	2. During gameplay: increment score locally, update local best if beaten
	3. On game over: submit final score to server (server saves if new high)
	4. Server fires back the authoritative personal best, client caches it
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ScoreManager = {}

local currentScore = 0
local personalBest = 0
local submitScoreRemote = nil
local getPersonalBestRemote = nil

--[[
	Initializes the ScoreManager.
	Sets up RemoteEvents and requests the stored personal best from the server.
]]
function ScoreManager.init()
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	submitScoreRemote = remoteFolder:FindFirstChild("SubmitScore")
	if not submitScoreRemote then
		submitScoreRemote = Instance.new("RemoteEvent")
		submitScoreRemote.Name = "SubmitScore"
		submitScoreRemote.Parent = remoteFolder
	end

	getPersonalBestRemote = remoteFolder:FindFirstChild("GetPersonalBest")
	if not getPersonalBestRemote then
		getPersonalBestRemote = Instance.new("RemoteEvent")
		getPersonalBestRemote.Name = "GetPersonalBest"
		getPersonalBestRemote.Parent = remoteFolder
	end

	-- Listen for personal best responses from server
	getPersonalBestRemote.OnClientEvent:Connect(function(bestScore)
		local serverBest = bestScore or 0
		-- Only accept server value if it's higher (avoids overwriting a
		-- locally-tracked best that hasn't been confirmed by server yet)
		if serverBest > personalBest then
			personalBest = serverBest
		end
	end)
end

--[[
	Gets the current score.
	@return number
]]
function ScoreManager.getScore()
	return currentScore
end

--[[
	Gets the personal best score.
	@return number
]]
function ScoreManager.getPersonalBest()
	return personalBest
end

--[[
	Increments the score by 1.
	Updates local personal best if beaten.
	Does NOT send to server — that happens once on game over via submitFinalScore().
]]
function ScoreManager.increment()
	currentScore = currentScore + 1

	-- Update personal best locally
	if currentScore > personalBest then
		personalBest = currentScore
	end

	-- Play score sound
	local ok, SoundManager = pcall(function()
		return require(script.Parent.SoundManager)
	end)
	if ok and SoundManager then
		SoundManager.playScore()
	end
end

--[[
	Submits the final score to the server for persistence.
	Called once on game over. The server will save it to DataStore if it's
	a new high score, and fire back the authoritative personal best.
]]
function ScoreManager.submitFinalScore()
	if submitScoreRemote and currentScore > 0 then
		submitScoreRemote:FireServer(currentScore)
	end
end

--[[
	Resets the score to 0 for a new game.
	Does NOT reset personalBest — that persists across games.
]]
function ScoreManager.reset()
	currentScore = 0
end

--[[
	Requests personal best from server.
	Used on initial load to fetch the stored high score.
]]
function ScoreManager.requestPersonalBest()
	if getPersonalBestRemote then
		getPersonalBestRemote:FireServer()
	end
end

return ScoreManager
