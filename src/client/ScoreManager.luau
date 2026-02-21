--[[
	ScoreManager.luau

	Tracks pipes passed and communicates with server for high score persistence.

	FLOW:
	1. On init: wait for server-created remotes, then request stored personal best
	2. During gameplay: increment score locally, update local best if beaten
	3. On game over: submit final score to server (server saves if new high)
	4. Server fires back the authoritative personal best, client caches it

	IMPORTANT: The client must NEVER create RemoteEvents — it waits for the
	server-created ones via WaitForChild.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ScoreManager = {}

local currentScore = 0
local personalBest = 0
local submitScoreRemote = nil
local getPersonalBestRemote = nil

--[[
	Initializes the ScoreManager.
	Waits for server-created remotes in a background thread so it doesn't
	block other init. Once found, connects the personal best listener and
	requests the initial value.
]]
function ScoreManager.init()
	task.spawn(function()
		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remoteFolder then
			warn("[ScoreManager] Remotes folder not found — score persistence disabled.")
			return
		end

		submitScoreRemote = remoteFolder:WaitForChild("SubmitScore", 10)
		getPersonalBestRemote = remoteFolder:WaitForChild("GetPersonalBest", 10)

		if not submitScoreRemote or not getPersonalBestRemote then
			warn("[ScoreManager] Score remotes not found — score persistence disabled.")
			return
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

		-- Request initial personal best now that we're connected
		getPersonalBestRemote:FireServer()
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
function ScoreManager.increment(playSound)
	-- playSound defaults to true; pass false for silent score adjustments.
	currentScore = currentScore + 1

	-- Update personal best locally
	if currentScore > personalBest then
		personalBest = currentScore
	end

	-- Play score sound unless explicitly suppressed
	if playSound ~= false then
		local ok, SoundManager = pcall(function()
			return require(script.Parent.SoundManager)
		end)
		if ok and SoundManager then
			SoundManager.playScore()
		end
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
	Safe to call before init completes (no-op if remote not found yet).
]]
function ScoreManager.requestPersonalBest()
	if getPersonalBestRemote then
		getPersonalBestRemote:FireServer()
	end
end

return ScoreManager
