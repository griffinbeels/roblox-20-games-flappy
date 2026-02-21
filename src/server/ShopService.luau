--[[
	ShopService.luau

	Server-side persistence and validation for the cosmetic shop.
	Uses DataStoreService to persist owned items and equipped selections.

	FLOW:
	1. Client calls GetShopData → server returns { owned, equipped }
	2. Client calls ShopPurchase(itemId) → server validates, deducts currency, saves
	3. Client calls ShopEquip(itemId) → server validates ownership, saves
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local CurrencyService = require(script.Parent.CurrencyService)

local ShopService = {}
local missionReporter = nil

-- DataStore handle
local shopDataStore = nil
local dataStoreAvailable = false

local initOk, _ = pcall(function()
	shopDataStore = DataStoreService:GetDataStore(ShopConfig.DATASTORE_NAME)
	dataStoreAvailable = true
end)

if not dataStoreAvailable then
	warn("[ShopService] DataStore not available — shop data will persist in-memory only (Studio mode).")
end

-- In-memory cache: userId → { owned = {}, equipped = {} }
local cachedData = {}

local function reportMissionEvent(player, eventName, payload)
	if not missionReporter then return end
	local ok, err = pcall(function()
		missionReporter(player, eventName, payload)
	end)
	if not ok then
		warn("[ShopService] Mission reporter failed:", err)
	end
end

--[[
	Builds the set of default item IDs (auto-owned).
]]
local function getDefaultItemIds()
	local defaults = {}
	for catId, items in pairs(ShopConfig.ITEMS) do
		for _, item in ipairs(items) do
			if item.default then
				defaults[item.id] = true
			end
		end
	end
	return defaults
end

--[[
	Builds the default equipped map (each category → its default item).
]]
local function getDefaultEquipped()
	local equipped = {}
	for _, cat in ipairs(ShopConfig.CATEGORIES) do
		local def = ShopConfig.getDefault(cat.id)
		if def then
			equipped[cat.id] = def.id
		end
	end
	return equipped
end

--[[
	Reads a player's shop data from DataStore or cache.
	Merges default items into owned (not stored in DataStore).
	Fills missing equipped slots with category defaults.
	@param userId number
	@return table { owned = {}, equipped = {} }
]]
local function readShopData(userId)
	if cachedData[userId] then
		return cachedData[userId]
	end

	local stored = nil
	if dataStoreAvailable and shopDataStore then
		local ok, result = pcall(function()
			return shopDataStore:GetAsync("user_" .. userId)
		end)
		if ok and result then
			stored = result
		end
	end

	-- Start with defaults
	local data = {
		owned = getDefaultItemIds(),
		equipped = getDefaultEquipped(),
	}

	-- Merge stored data on top
	if stored then
		if stored.owned then
			for itemId, val in pairs(stored.owned) do
				data.owned[itemId] = val
			end
		end
		if stored.equipped then
			for catId, itemId in pairs(stored.equipped) do
				-- Only use stored equipped if the item is actually owned
				if data.owned[itemId] then
					data.equipped[catId] = itemId
				end
			end
		end
	end

	cachedData[userId] = data
	return data
end

--[[
	Saves a player's shop data to DataStore.
	Only saves non-default owned items (defaults are auto-merged on read).
	@param userId number
]]
local function saveShopData(userId)
	local data = cachedData[userId]
	if not data then return end

	if not dataStoreAvailable or not shopDataStore then return end

	-- Strip default items from owned before saving (they're auto-merged on read)
	local defaults = getDefaultItemIds()
	local ownedToSave = {}
	for itemId, val in pairs(data.owned) do
		if not defaults[itemId] then
			ownedToSave[itemId] = val
		end
	end

	local ok, err = pcall(function()
		shopDataStore:SetAsync("user_" .. userId, {
			owned = ownedToSave,
			equipped = data.equipped,
		})
	end)
	if not ok then
		warn("[ShopService] Failed to save shop data for user " .. userId .. ": " .. tostring(err))
	end
end

--============================================================================
-- PUBLIC API
--============================================================================

--[[
	Injects a mission reporter callback.
	Callback signature: (player, eventName, payload) -> ()
]]
function ShopService.setMissionReporter(callback)
	missionReporter = callback
end

--[[
	Grants a shop item directly (used by mission rewards).
	@param userId number
	@param itemId string
	@param options table? { autoEquip = boolean }
	@return boolean success, string? reason, table? data
]]
function ShopService.grantItem(userId, itemId, options)
	if type(userId) ~= "number" then
		return false, "Invalid user ID"
	end
	if type(itemId) ~= "string" then
		return false, "Invalid item ID"
	end

	local item = ShopConfig.getItem(itemId)
	if not item then
		return false, "Item not found"
	end

	local data = readShopData(userId)
	if data.owned[itemId] then
		return false, "Already owned", data
	end

	data.owned[itemId] = true

	local autoEquip = type(options) == "table" and options.autoEquip == true
	if autoEquip then
		local catId = ShopConfig.getCategoryForItem(itemId)
		if catId then
			data.equipped[catId] = itemId
		end
	end

	saveShopData(userId)
	return true, nil, data
end

--[[
	Initializes the ShopService.
	Creates RemoteFunctions and wires up server handlers.
]]
function ShopService.init()
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	-- GetShopData: client requests their shop state
	local getDataRemote = remoteFolder:FindFirstChild("GetShopData")
	if not getDataRemote then
		getDataRemote = Instance.new("RemoteFunction")
		getDataRemote.Name = "GetShopData"
		getDataRemote.Parent = remoteFolder
	end

	getDataRemote.OnServerInvoke = function(player)
		local data = readShopData(player.UserId)
		return { owned = data.owned, equipped = data.equipped }
	end

	-- ShopPurchase: client wants to buy an item
	local purchaseRemote = remoteFolder:FindFirstChild("ShopPurchase")
	if not purchaseRemote then
		purchaseRemote = Instance.new("RemoteFunction")
		purchaseRemote.Name = "ShopPurchase"
		purchaseRemote.Parent = remoteFolder
	end

	purchaseRemote.OnServerInvoke = function(player, itemId)
		-- Validate item exists
		if type(itemId) ~= "string" then
			return { success = false, reason = "Invalid item ID" }
		end

		local item = ShopConfig.getItem(itemId)
		if not item then
			return { success = false, reason = "Item not found" }
		end
		if item.comingSoon then
			return { success = false, reason = "Coming soon" }
		end

		local data = readShopData(player.UserId)

		-- Already owned?
		if data.owned[itemId] then
			return { success = false, reason = "Already owned" }
		end

		-- Free items
		if item.price <= 0 then
			data.owned[itemId] = true
			saveShopData(player.UserId)
			reportMissionEvent(player, "shop_purchase", {
				itemId = itemId,
				price = item.price,
				categoryId = ShopConfig.getCategoryForItem(itemId),
			})
			return {
				success = true,
				newBalance = CurrencyService.getBalance(player.UserId),
				owned = data.owned,
				equipped = data.equipped,
			}
		end

		-- Bacon purchase
		if item.currencyType == "bacon" then
			local success, newBalance = CurrencyService.spend(player.UserId, item.price)
			if not success then
				return {
					success = false,
					reason = "Insufficient funds",
					newBalance = newBalance,
				}
			end

			-- Grant the item
			data.owned[itemId] = true
			saveShopData(player.UserId)
			reportMissionEvent(player, "shop_purchase", {
				itemId = itemId,
				price = item.price,
				categoryId = ShopConfig.getCategoryForItem(itemId),
			})

			return {
				success = true,
				newBalance = newBalance,
				owned = data.owned,
				equipped = data.equipped,
			}
		end

		return { success = false, reason = "Unknown currency type" }
	end

	-- ShopEquip: client wants to equip an owned item
	local equipRemote = remoteFolder:FindFirstChild("ShopEquip")
	if not equipRemote then
		equipRemote = Instance.new("RemoteFunction")
		equipRemote.Name = "ShopEquip"
		equipRemote.Parent = remoteFolder
	end

	equipRemote.OnServerInvoke = function(player, itemId)
		if type(itemId) ~= "string" then
			return { success = false, reason = "Invalid item ID" }
		end

		local item = ShopConfig.getItem(itemId)
		if not item then
			return { success = false, reason = "Item not found" }
		end
		if item.comingSoon then
			return { success = false, reason = "Coming soon" }
		end

		local data = readShopData(player.UserId)

		-- Must own the item
		if not data.owned[itemId] then
			return { success = false, reason = "Not owned" }
		end

		-- Find the category
		local catId = ShopConfig.getCategoryForItem(itemId)
		if not catId then
			return { success = false, reason = "Category not found" }
		end

		-- No-op equip (already selected): don't re-save.
		if data.equipped[catId] == itemId then
			return {
				success = true,
				equipped = data.equipped,
				changed = false,
			}
		end

		-- Equip it
		data.equipped[catId] = itemId
		saveShopData(player.UserId)
		reportMissionEvent(player, "shop_equip", {
			itemId = itemId,
			categoryId = catId,
		})

		return {
			success = true,
			equipped = data.equipped,
			changed = true,
		}
	end

	-- Preload shop data on join so the first client request returns from cache.
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			readShopData(player.UserId)
		end)
	end)

	-- Also warm cache for any players already present (Studio edge case).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			readShopData(player.UserId)
		end)
	end
end

return ShopService
