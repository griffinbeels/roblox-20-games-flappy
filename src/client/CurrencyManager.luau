--[[
	CurrencyManager.luau

	Client-side tracking for the Bacon currency system.

	FLOW:
	1. On init: wait for server-created remotes, then request stored balance
	2. During gameplay: accumulate pendingEarned (1 per pipe pass)
	3. On game over: submit pendingEarned to server in one batch
	4. Server fires back the authoritative lifetime balance
	5. Display uses lifetimeBalance + pendingEarned for optimistic updates

	IMPORTANT: The client must NEVER create RemoteEvents — it waits for the
	server-created ones via WaitForChild. Clients cannot create replicated
	Instances in ReplicatedStorage; doing so creates local-only ghosts that
	the server never sees.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)

local CurrencyManager = {}

local lifetimeBalance = 0   -- server-confirmed total
local pendingEarned = 0     -- accumulated this run, not yet submitted
local getBalanceRemote = nil
local submitEarnedRemote = nil

--[[
	Initializes the CurrencyManager.
	Waits for server-created remotes in a background thread so it doesn't
	block other init. Once found, connects the balance listener and
	requests the initial balance.
]]
function CurrencyManager.init()
	task.spawn(function()
		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remoteFolder then
			warn("[CurrencyManager] Remotes folder not found — currency disabled.")
			return
		end

		getBalanceRemote = remoteFolder:WaitForChild("GetCurrencyBalance", 10)
		submitEarnedRemote = remoteFolder:WaitForChild("SubmitCurrencyEarned", 10)

		if not getBalanceRemote or not submitEarnedRemote then
			warn("[CurrencyManager] Currency remotes not found — currency disabled.")
			return
		end

		-- Listen for balance updates from server
		getBalanceRemote.OnClientEvent:Connect(function(balance)
			local serverBalance = balance or 0
			if serverBalance > lifetimeBalance then
				lifetimeBalance = serverBalance
			end
		end)

		-- Request initial balance now that we're connected
		getBalanceRemote:FireServer()
	end)
end

--[[
	Requests the current balance from the server.
	Safe to call before init completes (no-op if remote not found yet).
]]
function CurrencyManager.requestBalance()
	if getBalanceRemote then
		getBalanceRemote:FireServer()
	end
end

--[[
	Called when the player passes a pipe. Adds PER_PIPE to pending earnings.
]]
function CurrencyManager.earnFromPipe()
	pendingEarned = pendingEarned + CurrencyConfig.PER_PIPE
end

--[[
	Submits accumulated earnings to the server.
	Called once on game over. Resets pending after submission.
]]
function CurrencyManager.submitEarnings()
	if submitEarnedRemote and pendingEarned > 0 then
		submitEarnedRemote:FireServer(pendingEarned)
		-- Optimistically update lifetime balance
		lifetimeBalance = lifetimeBalance + pendingEarned
		pendingEarned = 0
	end
end

--[[
	Returns the optimistic display balance (lifetime + pending).
	@return number
]]
function CurrencyManager.getDisplayBalance()
	return lifetimeBalance + pendingEarned
end

--[[
	Returns the server-confirmed lifetime balance.
	@return number
]]
function CurrencyManager.getLifetimeBalance()
	return lifetimeBalance
end

--[[
	Returns the pending earnings for the current run.
	@return number
]]
function CurrencyManager.getPendingEarned()
	return pendingEarned
end

--[[
	Resets pending earnings to 0. Called at the start of a new game.
]]
function CurrencyManager.resetPending()
	pendingEarned = 0
end

--[[
	Directly sets the lifetime balance to an authoritative server value.
	Used after shop purchases where the server returns the new balance.
	@param newBalance number
]]
function CurrencyManager.setLifetimeBalance(newBalance)
	lifetimeBalance = newBalance
end

return CurrencyManager
