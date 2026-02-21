--[[
	CurrencyService.luau

	Server-side service for the Bacon currency system.
	Uses DataStoreService to persist lifetime balances across sessions.

	WRITE OPTIMIZATION:
	- Earned currency is buffered in-memory and flushed in batches.
	- Spending still uses UpdateAsync for authoritative validation.
	- Pending earned currency is merged into spend transactions so users can
	  immediately spend newly earned bacon without waiting for a flush.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)

local CurrencyService = {}

local missionReporter = nil
local isInitialized = false

-- DataStore handle
local currencyDataStore = nil
local dataStoreAvailable = false

local initOk, _ = pcall(function()
	currencyDataStore = DataStoreService:GetDataStore(CurrencyConfig.DATASTORE_NAME)
	dataStoreAvailable = true
end)

if not dataStoreAvailable then
	warn("[CurrencyService] DataStore not available - balances will persist in-memory only (Studio mode).")
end

-- In-memory cache
local cachedBalances = {} -- userId -> lifetime balance including pending deltas
local pendingDeltas = {}  -- userId -> earned amount not flushed to DataStore yet
local flushScheduled = {} -- userId -> true while debounce timer is active

local function reportMissionEvent(player, eventName, payload)
	if not missionReporter then return end
	local ok, err = pcall(function()
		missionReporter(player, eventName, payload)
	end)
	if not ok then
		warn("[CurrencyService] Mission reporter failed:", err)
	end
end

--============================================================================
-- DATA HELPERS
--============================================================================

local function keyForUser(userId)
	return "user_" .. userId
end

--[[
	Reads a player's lifetime balance.
	Checks in-memory cache first, then DataStore.
]]
local function readBalance(userId)
	if cachedBalances[userId] ~= nil then
		return cachedBalances[userId]
	end

	if dataStoreAvailable and currencyDataStore then
		local ok, result = pcall(function()
			return currencyDataStore:GetAsync(keyForUser(userId))
		end)
		if ok and result then
			cachedBalances[userId] = result
			return result
		end
	end

	cachedBalances[userId] = 0
	return 0
end

--[[
	Flushes pending earned delta for a user in one UpdateAsync call.
	Returns true on success/no-op, false if the write fails.
]]
local function flushPendingDelta(userId)
	local delta = pendingDeltas[userId] or 0
	if delta <= 0 then
		return true
	end

	-- Optimistically clear; restore on failure.
	pendingDeltas[userId] = 0

	if not dataStoreAvailable or not currencyDataStore then
		return true
	end

	local ok, err = pcall(function()
		currencyDataStore:UpdateAsync(keyForUser(userId), function(oldValue)
			oldValue = oldValue or 0
			return oldValue + delta
		end)
	end)

	if ok then
		return true
	end

	warn("[CurrencyService] Failed to flush pending currency for user " .. userId .. ": " .. tostring(err))
	pendingDeltas[userId] = (pendingDeltas[userId] or 0) + delta
	return false
end

local function scheduleFlush(userId, delaySeconds)
	if flushScheduled[userId] then
		return
	end

	flushScheduled[userId] = true
	local delayTime = delaySeconds or CurrencyConfig.SAVE_DEBOUNCE_DELAY or 2

	task.delay(delayTime, function()
		flushScheduled[userId] = nil
		flushPendingDelta(userId)
	end)
end

--============================================================================
-- BALANCE MUTATIONS
--============================================================================

--[[
	Adds currency to a player's lifetime balance.
	Mutation is immediate in cache, batched to DataStore.
	@param userId number
	@param amount number - must be > 0
	@return number - new optimistic balance
]]
local function addCurrency(userId, amount)
	local currentBalance = readBalance(userId)
	local newBalance = currentBalance + amount

	cachedBalances[userId] = newBalance
	pendingDeltas[userId] = (pendingDeltas[userId] or 0) + amount
	scheduleFlush(userId, CurrencyConfig.SAVE_DEBOUNCE_DELAY)

	return newBalance
end

--[[
	Spends currency from a player's lifetime balance.
	Pending earned delta is merged into the same UpdateAsync transaction.
	@param userId number
	@param amount number - must be > 0
	@return boolean success, number newBalance
]]
local function spendCurrency(userId, amount)
	local currentBalance = readBalance(userId)
	if currentBalance < amount then
		return false, currentBalance
	end

	local optimisticNewBalance = currentBalance - amount
	local pendingSnapshot = pendingDeltas[userId] or 0
	pendingDeltas[userId] = 0

	if dataStoreAvailable and currencyDataStore then
		local actualBalance = optimisticNewBalance
		local didSpend = false

		local ok, err = pcall(function()
			currencyDataStore:UpdateAsync(keyForUser(userId), function(oldValue)
				oldValue = oldValue or 0
				local available = oldValue + pendingSnapshot
				if available < amount then
					actualBalance = available
					return nil -- no write, insufficient funds
				end
				actualBalance = available - amount
				didSpend = true
				return actualBalance
			end)
		end)

		if not ok then
			warn("[CurrencyService] Failed to spend currency for user " .. userId .. ": " .. tostring(err))
			pendingDeltas[userId] = (pendingDeltas[userId] or 0) + pendingSnapshot
			return false, (cachedBalances[userId] or currentBalance)
		end

		local pendingAfter = pendingDeltas[userId] or 0
		if not didSpend then
			-- Transaction was canceled, so pending snapshot still needs to flush later.
			pendingDeltas[userId] = pendingAfter + pendingSnapshot
			cachedBalances[userId] = actualBalance + pendingAfter
			return false, cachedBalances[userId]
		end

		cachedBalances[userId] = actualBalance + pendingAfter
		return true, cachedBalances[userId]
	end

	-- Studio/no-DataStore fallback
	cachedBalances[userId] = optimisticNewBalance
	pendingDeltas[userId] = 0
	return true, optimisticNewBalance
end

--============================================================================
-- PUBLIC API
--============================================================================

function CurrencyService.getBalance(userId)
	return readBalance(userId)
end

function CurrencyService.spend(userId, amount)
	return spendCurrency(userId, amount)
end

function CurrencyService.add(userId, amount)
	return addCurrency(userId, amount)
end

--[[
	Injects a mission reporter callback.
	Callback signature: (player, eventName, payload) -> ()
]]
function CurrencyService.setMissionReporter(callback)
	missionReporter = callback
end

--============================================================================
-- INIT
--============================================================================

function CurrencyService.init()
	if isInitialized then
		return
	end
	isInitialized = true

	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	-- GetCurrencyBalance: client requests their stored balance
	local getBalanceRemote = remoteFolder:FindFirstChild("GetCurrencyBalance")
	if not getBalanceRemote then
		getBalanceRemote = Instance.new("RemoteEvent")
		getBalanceRemote.Name = "GetCurrencyBalance"
		getBalanceRemote.Parent = remoteFolder
	end

	getBalanceRemote.OnServerEvent:Connect(function(player)
		local balance = readBalance(player.UserId)
		getBalanceRemote:FireClient(player, balance)
	end)

	-- SubmitCurrencyEarned: client sends amount earned this run on game over
	local submitEarnedRemote = remoteFolder:FindFirstChild("SubmitCurrencyEarned")
	if not submitEarnedRemote then
		submitEarnedRemote = Instance.new("RemoteEvent")
		submitEarnedRemote.Name = "SubmitCurrencyEarned"
		submitEarnedRemote.Parent = remoteFolder
	end

	submitEarnedRemote.OnServerEvent:Connect(function(player, amount)
		if type(amount) ~= "number" then return end
		if amount <= 0 then return end
		if amount ~= math.floor(amount) then return end
		if amount > CurrencyConfig.MAX_SUBMIT_PER_RUN then
			warn("[CurrencyService] Rejected suspicious submit from user " .. player.UserId .. ": " .. amount)
			return
		end

		local newBalance = addCurrency(player.UserId, amount)
		getBalanceRemote:FireClient(player, newBalance)
		reportMissionEvent(player, "bacon_earned", {
			amount = amount,
			newBalance = newBalance,
		})
	end)

	-- SpendCurrency: RemoteFunction for shop integration
	local spendRemote = remoteFolder:FindFirstChild("SpendCurrency")
	if not spendRemote then
		spendRemote = Instance.new("RemoteFunction")
		spendRemote.Name = "SpendCurrency"
		spendRemote.Parent = remoteFolder
	end

	spendRemote.OnServerInvoke = function(player, amount, reason)
		if type(amount) ~= "number" then
			return { success = false, newBalance = readBalance(player.UserId) }
		end
		if amount <= 0 or amount ~= math.floor(amount) then
			return { success = false, newBalance = readBalance(player.UserId) }
		end

		local success, newBalance = spendCurrency(player.UserId, amount)
		return { success = success, newBalance = newBalance }
	end

	-- Periodic flush for durability.
	task.spawn(function()
		while true do
			task.wait(CurrencyConfig.SAVE_FLUSH_INTERVAL or 20)
			for userId, delta in pairs(pendingDeltas) do
				if delta > 0 then
					flushPendingDelta(userId)
					task.wait(CurrencyConfig.SAVE_FLUSH_SPREAD_DELAY or 0)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		flushScheduled[player.UserId] = nil
		flushPendingDelta(player.UserId)
		cachedBalances[player.UserId] = nil
		pendingDeltas[player.UserId] = nil
	end)

	game:BindToClose(function()
		for userId in pairs(cachedBalances) do
			flushPendingDelta(userId)
		end
	end)
end

return CurrencyService
