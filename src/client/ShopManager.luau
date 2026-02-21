--[[
	ShopManager.luau

	Client-side shop state cache and gameplay appliers.
	Caches owned/equipped state from server, provides purchase/equip API,
	and applies equipped items to runtime configs.

	FLOW:
	1. On init: waits for remotes, calls GetShopData, caches locally
	2. ShopUI calls purchase/equip → ShopManager calls server → updates cache
	3. GameController calls applyAllEquipped() to push equipped items into configs
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local TrailConfig = require(ReplicatedStorage.Shared.TrailConfig)
local PipeConfig = require(ReplicatedStorage.Shared.PipeConfig)
local ParallaxConfig = require(ReplicatedStorage.Shared.ParallaxConfig)

local ShopManager = {}

-- Cached state
local owned = {}      -- { [itemId] = true }
local equipped = {}   -- { [categoryId] = itemId }
local isReady = false
local isDirty = false  -- true if any equip changed since last applyAllEquipped()

-- Remotes
local getDataRemote = nil
local purchaseRemote = nil
local equipRemote = nil

-- Change listeners
local changeCallbacks = {}
local readyCallbacks = {}

--[[
	Fires all registered change callbacks.
]]
local function fireChanged()
	for _, cb in ipairs(changeCallbacks) do
		task.spawn(cb)
	end
end

--[[
	Fires all registered ready callbacks once initial shop data is loaded.
]]
local function fireReady()
	for _, cb in ipairs(readyCallbacks) do
		task.spawn(cb)
	end
	readyCallbacks = {}
end

--============================================================================
-- APPLIERS — push equipped items into runtime configs
--============================================================================

local appliers = {
	trails = function(item)
		TrailConfig.ACTIVE_STYLE = item.configKey
	end,
	pipes = function(item)
		PipeConfig.setActiveStyles(item.configKey)
	end,
	backgrounds = function(item)
		ParallaxConfig.setActiveTheme(item.configKey)
	end,
	floors = function(item)
		ParallaxConfig.setActiveFloor(item.configKey)
	end,
}

--============================================================================
-- PUBLIC API
--============================================================================

--[[
	Initializes the ShopManager.
	Waits for server-created remotes in a background thread, then fetches
	initial shop data.
]]
function ShopManager.init()
	task.spawn(function()
		local function setDefaults()
			owned = {}
			equipped = {}
			for _, cat in ipairs(ShopConfig.CATEGORIES) do
				local def = ShopConfig.getDefault(cat.id)
				if def then
					owned[def.id] = true
					equipped[cat.id] = def.id
				end
			end
		end

		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remoteFolder then
			warn("[ShopManager] Remotes folder not found — shop disabled.")
			setDefaults()
			isReady = true
			isDirty = true
			fireReady()
			fireChanged()
			return
		end

		getDataRemote = remoteFolder:WaitForChild("GetShopData", 10)
		purchaseRemote = remoteFolder:WaitForChild("ShopPurchase", 10)
		equipRemote = remoteFolder:WaitForChild("ShopEquip", 10)

		if not getDataRemote or not purchaseRemote or not equipRemote then
			warn("[ShopManager] Shop remotes not found — shop disabled.")
			setDefaults()
			isReady = true
			isDirty = true
			fireReady()
			fireChanged()
			return
		end

		-- Fetch initial data
		local ok, data = pcall(function()
			return getDataRemote:InvokeServer()
		end)

		if ok and data then
			owned = data.owned or {}
			equipped = data.equipped or {}
		else
			warn("[ShopManager] Failed to fetch shop data — using defaults.")
			setDefaults()
		end

		isReady = true
		isDirty = true -- apply on first game start
		fireReady()
		fireChanged()
	end)
end

--[[
	Returns whether the shop data has been loaded from the server.
]]
function ShopManager.isReady()
	return isReady
end

--[[
	Returns whether a given item is owned.
]]
function ShopManager.isOwned(itemId)
	return owned[itemId] == true
end

--[[
	Returns whether a given item is currently equipped.
]]
function ShopManager.isEquipped(itemId)
	local catId = ShopConfig.getCategoryForItem(itemId)
	if not catId then return false end
	return equipped[catId] == itemId
end

--[[
	Returns the button state for an item: "buy", "equip", "equipped", or "comingSoon".
]]
function ShopManager.getItemState(itemId)
	local item = ShopConfig.getItem(itemId)
	if item and item.comingSoon then
		return "comingSoon"
	end

	if not ShopManager.isOwned(itemId) then
		return "buy"
	end
	if ShopManager.isEquipped(itemId) then
		return "equipped"
	end
	return "equip"
end

--[[
	Returns the currently equipped item ID for a category.
]]
function ShopManager.getEquipped(categoryId)
	return equipped[categoryId]
end

--[[
	Purchases an item. Calls the server, updates local cache.
	@param itemId string
	@param CurrencyManager table — the CurrencyManager module (passed to avoid circular require)
	@return boolean success, string? reason
]]
function ShopManager.purchase(itemId, CurrencyManager)
	if not purchaseRemote then
		return false, "Shop not ready"
	end

	local item = ShopConfig.getItem(itemId)
	if item and item.comingSoon then
		return false, "Coming soon"
	end

	local ok, result = pcall(function()
		return purchaseRemote:InvokeServer(itemId)
	end)

	if not ok then
		return false, "Network error"
	end

	if result.success then
		owned = result.owned or owned
		equipped = result.equipped or equipped
		if result.newBalance and CurrencyManager then
			CurrencyManager.setLifetimeBalance(result.newBalance)
		end
		fireChanged()
		return true
	else
		if result.newBalance and CurrencyManager then
			CurrencyManager.setLifetimeBalance(result.newBalance)
		end
		return false, result.reason
	end
end

--[[
	Equips an owned item. Calls the server, updates local cache.
	@param itemId string
	@return boolean success, string? reason
]]
function ShopManager.equip(itemId)
	if not equipRemote then
		return false, "Shop not ready"
	end

	local item = ShopConfig.getItem(itemId)
	if item and item.comingSoon then
		return false, "Coming soon"
	end

	local ok, result = pcall(function()
		return equipRemote:InvokeServer(itemId)
	end)

	if not ok then
		return false, "Network error"
	end

	if result.success then
		equipped = result.equipped or equipped
		if result.changed ~= false then
			isDirty = true
		end
		fireChanged()
		return true
	else
		return false, result.reason
	end
end

--[[
	Registers a callback to be called when shop state changes.
	@param callback function
]]
function ShopManager.onChanged(callback)
	table.insert(changeCallbacks, callback)
end

--[[
	Registers a callback to be called once initial shop data is loaded.
	If already ready, callback is invoked asynchronously immediately.
	@param callback function
]]
function ShopManager.onReady(callback)
	if isReady then
		task.spawn(callback)
		return
	end
	table.insert(readyCallbacks, callback)
end

--[[
	Applies an authoritative server snapshot to the local cache.
	Used by systems like missions that can grant rewards outside ShopUI flows.
	@param snapshot table { owned = {}, equipped = {} }
]]
function ShopManager.applyServerSnapshot(snapshot)
	if type(snapshot) ~= "table" then return end

	if type(snapshot.owned) == "table" then
		owned = snapshot.owned
	end
	if type(snapshot.equipped) == "table" then
		equipped = snapshot.equipped
	end

	isDirty = true
	fireChanged()
end

--[[
	Blocks until shop data is ready or timeout expires.
	@param timeout number? - seconds
	@return boolean - true if ready, false if timed out
]]
function ShopManager.waitUntilReady(timeout)
	if isReady then return true end
	local deadline = timeout and (os.clock() + timeout) or nil
	while not isReady do
		if deadline and os.clock() >= deadline then
			return false
		end
		task.wait(0.05)
	end
	return true
end

--[[
	Applies all currently equipped items to runtime configs.
	Called by GameController at the start of each round and after shop close.
]]
function ShopManager.applyAllEquipped()
	for _, cat in ipairs(ShopConfig.CATEGORIES) do
		local itemId = equipped[cat.id]
		if itemId then
			local item = ShopConfig.getItem(itemId)
			local applier = appliers[cat.id]
			if item and applier then
				applier(item)
			end
		end
	end
	isDirty = false
end

--[[
	Returns whether any equip has changed since last applyAllEquipped().
]]
function ShopManager.needsRefresh()
	return isDirty
end

--[[
	Clears the dirty flag.
]]
function ShopManager.clearRefresh()
	isDirty = false
end

return ShopManager
