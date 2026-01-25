--[[
	ScoreManager.luau
	
	Tracks pipes passed and communicates with server for leaderboard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ScoreManager = {}
ScoreManager.__index = ScoreManager

local currentScore = 0
local personalBest = 0
local submitScoreRemote = nil
local getPersonalBestRemote = nil

--[[
	Initializes the ScoreManager.
	Sets up RemoteEvents for server communication.
]]
function ScoreManager.init()
	-- Create RemoteEvents in ReplicatedStorage if they don't exist
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
	
	-- Listen for personal best updates from server
	getPersonalBestRemote.OnClientEvent:Connect(function(bestScore)
		personalBest = bestScore or 0
	end)
end

--[[
	Gets the current score.
	@return number - Current score
]]
function ScoreManager.getScore()
	return currentScore
end

--[[
	Gets the personal best score.
	@return number - Personal best score
]]
function ScoreManager.getPersonalBest()
	return personalBest
end

--[[
	Increments the score by 1.
]]
function ScoreManager.increment()
	currentScore = currentScore + 1
	
	-- Play score sound (optional - SoundManager may not be loaded yet)
	local success, SoundManager = pcall(function()
		return require(script.Parent.SoundManager)
	end)
	if success and SoundManager then
		SoundManager.playScore()
	end
	
	-- Send score to server
	if submitScoreRemote then
		submitScoreRemote:FireServer(currentScore)
	end
end

--[[
	Resets the score to 0.
]]
function ScoreManager.reset()
	currentScore = 0
end

--[[
	Requests personal best from server.
]]
function ScoreManager.requestPersonalBest()
	if getPersonalBestRemote then
		getPersonalBestRemote:FireServer()
	end
end

return ScoreManager
