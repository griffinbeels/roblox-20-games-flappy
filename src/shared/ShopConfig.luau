--[[
	ShopConfig.luau

	Single source of truth for the cosmetic shop:
	- category definitions
	- item definitions
	- mission-gated tuning unlock metadata
	- UI constants
]]

local ShopConfig = {}
local PrestigeConfig = require(script.Parent.PrestigeConfig)

ShopConfig.SHOP_TUNING_ENABLED = PrestigeConfig.ENABLED ~= true

--============================================================================
-- CATEGORIES (ordered)
--============================================================================

ShopConfig.CATEGORIES = {
	{ id = "trails",      label = "Trails",      icon = "\u{2728}" },
	{ id = "poofs",       label = "Poofs",        icon = "\u{1F4A8}" },
	{ id = "pipes",       label = "Pipes",       icon = "\u{1FAA8}" },
	{ id = "backgrounds", label = "Backgrounds", icon = "\u{1F30C}" },
	{ id = "floors",      label = "Floors",      icon = "\u{1F525}" },
}

--============================================================================
-- MISSION-GATED TUNING VALUES
--============================================================================

ShopConfig.TUNING_VALUES = {
	-- Trails tune speed cap multiplier.
	trails = { 1.00, 1.25, 1.50, 1.75, 2.00, 2.25, 2.50, 2.75, 3.00, 3.25, 3.50, 3.75, 4.00 },
	-- Floors tune gravity.
	floors = { 100, 125, 150, 175, 200, 225, 250, 275, 300, 325, 350, 375, 400 },
	-- Poofs tune jump power multiplier.
	poofs = { 0.50, 0.75, 1.00, 1.25, 1.50, 1.75, 2.00, 2.25, 2.50, 2.75, 3.00, 3.25, 3.50 },
}

-- Flexible score formula knobs for unlock challenges.
-- Challenge for tier N uses the current tier's index and the prior tier's
-- threshold (so every challenge is achievable with already-unlocked tuning).
ShopConfig.TUNING_CHALLENGES = {
	speed = {
		baseScore = 8,
		scorePerTier = 3,
		curve = 1,
	},
	gravity = {
		baseScore = 8,
		scorePerTier = 3,
		curve = 1,
	},
	jumpPower = {
		baseScore = 7,
		scorePerTier = 3,
		curve = 1,
	},
}

local function clamp01(value)
	return math.clamp(tonumber(value) or 0, 0, 1)
end

local function lerp(a, b, alpha)
	return a + (b - a) * clamp01(alpha)
end

local function lerpColor(fromColor, toColor, alpha)
	return Color3.new(
		lerp(fromColor.R, toColor.R, alpha),
		lerp(fromColor.G, toColor.G, alpha),
		lerp(fromColor.B, toColor.B, alpha)
	)
end

local function formatNumber(value, decimals, keepOneDecimalIfInteger)
	local text = string.format("%." .. tostring(decimals) .. "f", tonumber(value) or 0)
	text = text:gsub("0+$", "")
	text = text:gsub("%.$", "")
	if keepOneDecimalIfInteger and not text:find("%.") then
		text = text .. ".0"
	end
	return text
end

local function formatMultiplier(value)
	return formatNumber(value, 2, true)
end

local function formatInteger(value)
	return tostring(math.floor((tonumber(value) or 0) + 0.5))
end

local function toToken(value)
	local text = formatNumber(value, 2, false)
	text = text:gsub("%.", "_")
	if text == "" then
		return "0"
	end
	return text
end

function ShopConfig.computeChallengeScore(metricKey, tierIndex)
	local formula = ShopConfig.TUNING_CHALLENGES[metricKey] or {}
	local baseScore = tonumber(formula.baseScore) or 10
	local scorePerTier = tonumber(formula.scorePerTier) or 3
	local curve = tonumber(formula.curve) or 1
	local normalizedTier = math.max(2, math.floor(tonumber(tierIndex) or 2))
	local tierDelta = normalizedTier - 2
	local scaled = baseScore + (scorePerTier * (tierDelta ^ curve))
	return math.max(1, math.floor(scaled + 0.5))
end

local function buildUnlockMission(config)
	local scoreTarget = ShopConfig.computeChallengeScore(config.metricFormulaKey, config.tierIndex)
	local missionId = string.format("unlock_%s_tier_%02d", config.metricId, config.tierIndex)
	local progressPath = string.format(
		"stats.best_score_at_%s_%s",
		config.metricStatToken,
		toToken(config.thresholdValue)
	)

	local mission = {
		id = missionId,
		title = string.format("Unlock %s", config.unlockLabel),
		description = string.format(
			"Reach score %d at %s+ to unlock %s in the shop.",
			scoreTarget,
			config.thresholdLabel,
			config.unlockLabel
		),
		scoreTarget = scoreTarget,
		progressPath = progressPath,
		metricField = config.metricField,
		thresholdValue = tonumber(config.thresholdValue) or 0,
	}

	if type(config.requiresMissionId) == "string" and config.requiresMissionId ~= "" then
		mission.requiresMissionId = config.requiresMissionId
	end

	return mission
end

local function buildClassicTrailItems()
	return {
		{
			id = "trail_rainbow",
			name = "Rainbow Nyan Cat",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "Rainbow",
			previewColor = Color3.fromRGB(255, 100, 100),
		},
		{
			id = "trail_smoke",
			name = "Smokey",
			price = 2500,
			currencyType = "bacon",
			configKey = "Smoke",
			previewColor = Color3.fromRGB(200, 200, 200),
		},
		{
			id = "trail_more_coming_soon",
			name = "MORE SOON",
			price = 0,
			currencyType = "comingSoon",
			comingSoon = true,
			previewColor = Color3.fromRGB(230, 180, 40),
			previewIcon = "\u{1F6A7}",
		},
	}
end

local function buildClassicPoofItems()
	return {
		{
			id = "poof_glitter",
			name = "Glitter Burst",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "Glitter",
			previewColor = Color3.fromRGB(255, 212, 95),
			previewIcon = "\u{2728}",
		},
		{
			id = "poof_smoke",
			name = "Smoke Cloud",
			price = 1750,
			currencyType = "bacon",
			configKey = "Smoke",
			previewColor = Color3.fromRGB(185, 185, 185),
		},
		{
			id = "poof_more_coming_soon",
			name = "MORE SOON",
			price = 0,
			currencyType = "comingSoon",
			comingSoon = true,
			previewColor = Color3.fromRGB(230, 180, 40),
			previewIcon = "\u{1F6A7}",
		},
	}
end

local function buildClassicFloorItems()
	return {
		{
			id = "floor_lava_mesh",
			name = "Literally Lava",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "LAVA_MESH",
			previewColor = Color3.fromRGB(200, 80, 20),
		},
		{
			id = "floor_dark_gray",
			name = "Moon Floor",
			price = 2000,
			currencyType = "bacon",
			configKey = "DARK_GRAY",
			previewColor = Color3.fromRGB(91, 91, 91),
		},
		{
			id = "floor_more_coming_soon",
			name = "MORE SOON",
			price = 0,
			currencyType = "comingSoon",
			comingSoon = true,
			previewColor = Color3.fromRGB(230, 180, 40),
			previewIcon = "\u{1F6A7}",
		},
	}
end

local function buildTrailItems()
	local values = ShopConfig.TUNING_VALUES.trails
	local total = #values
	local items = {}
	local previousMissionId = nil

	local colorFrom = Color3.fromRGB(90, 180, 255)
	local colorTo = Color3.fromRGB(255, 110, 90)

	for index, speedValue in ipairs(values) do
		local alpha = if total <= 1 then 0 else (index - 1) / (total - 1)
		local previewColor = lerpColor(colorFrom, colorTo, alpha)

		local item = {
			price = 0,
			currencyType = "bacon",
			configKey = if (index % 2 == 0) then "Smoke" else "Rainbow",
			previewColor = previewColor,
			speedCapMultiplier = speedValue,
		}

		if index == 1 then
			item.id = "trail_rainbow"
			item.name = "Speed Trail " .. formatMultiplier(speedValue) .. "x"
			item.default = true
			item.configKey = "Rainbow"
		elseif index == 2 then
			item.id = "trail_smoke"
			item.name = "Speed Trail " .. formatMultiplier(speedValue) .. "x"
			item.configKey = "Smoke"
		else
			item.id = string.format("trail_speed_tier_%02d", index)
			item.name = "Speed Trail " .. formatMultiplier(speedValue) .. "x"
		end

		if index > 1 then
			local thresholdValue = values[index - 1]
			local unlockMission = buildUnlockMission({
				metricId = "speed",
				metricFormulaKey = "speed",
				metricStatToken = "speed",
				metricField = "speedCapMultiplier",
				tierIndex = index,
				thresholdValue = thresholdValue,
				thresholdLabel = "speed " .. formatMultiplier(thresholdValue) .. "x",
				unlockLabel = "Speed " .. formatMultiplier(speedValue) .. "x",
				requiresMissionId = previousMissionId,
			})
			item.requiredMissionId = unlockMission.id
			item.unlockMission = unlockMission
			previousMissionId = unlockMission.id
		end

		table.insert(items, item)
	end

	return items
end

local function buildFloorItems()
	local values = ShopConfig.TUNING_VALUES.floors
	local total = #values
	local items = {}
	local previousMissionId = nil
	local floorStyles = { "LAVA_MESH", "DARK_GRAY", "LAVA_SOLID" }

	local colorFrom = Color3.fromRGB(245, 140, 60)
	local colorTo = Color3.fromRGB(130, 130, 130)

	for index, gravityValue in ipairs(values) do
		local alpha = if total <= 1 then 0 else (index - 1) / (total - 1)
		local previewColor = lerpColor(colorFrom, colorTo, alpha)

		local item = {
			price = 0,
			currencyType = "bacon",
			configKey = floorStyles[((index - 1) % #floorStyles) + 1],
			previewColor = previewColor,
			gravity = gravityValue,
		}

		if index == 1 then
			item.id = "floor_lava_mesh"
			item.name = "Gravity Floor " .. formatInteger(gravityValue)
			item.default = true
			item.configKey = "LAVA_MESH"
		elseif index == 2 then
			item.id = "floor_dark_gray"
			item.name = "Gravity Floor " .. formatInteger(gravityValue)
			item.configKey = "DARK_GRAY"
		else
			item.id = string.format("floor_gravity_tier_%02d", index)
			item.name = "Gravity Floor " .. formatInteger(gravityValue)
		end

		if index > 1 then
			local thresholdValue = values[index - 1]
			local unlockMission = buildUnlockMission({
				metricId = "gravity",
				metricFormulaKey = "gravity",
				metricStatToken = "gravity",
				metricField = "gravity",
				tierIndex = index,
				thresholdValue = thresholdValue,
				thresholdLabel = "gravity " .. formatInteger(thresholdValue),
				unlockLabel = "Gravity " .. formatInteger(gravityValue),
				requiresMissionId = previousMissionId,
			})
			item.requiredMissionId = unlockMission.id
			item.unlockMission = unlockMission
			previousMissionId = unlockMission.id
		end

		table.insert(items, item)
	end

	return items
end

local function buildPoofItems()
	local values = ShopConfig.TUNING_VALUES.poofs
	local total = #values
	local items = {}
	local previousMissionId = nil
	local poofStyles = { "Smoke", "Glitter", "Burst" }

	local colorFrom = Color3.fromRGB(140, 210, 255)
	local colorTo = Color3.fromRGB(255, 150, 220)

	for index, jumpValue in ipairs(values) do
		local alpha = if total <= 1 then 0 else (index - 1) / (total - 1)
		local previewColor = lerpColor(colorFrom, colorTo, alpha)

		local item = {
			price = 0,
			currencyType = "bacon",
			configKey = poofStyles[((index - 1) % #poofStyles) + 1],
			previewColor = previewColor,
			jumpPowerMultiplier = jumpValue,
		}

		if index == 1 then
			item.id = "poof_smoke"
			item.name = "Jump Poof " .. formatMultiplier(jumpValue) .. "x"
			item.default = true
			item.configKey = "Smoke"
		elseif index == 2 then
			item.id = "poof_glitter"
			item.name = "Jump Poof " .. formatMultiplier(jumpValue) .. "x"
			item.configKey = "Glitter"
		else
			item.id = string.format("poof_jump_tier_%02d", index)
			item.name = "Jump Poof " .. formatMultiplier(jumpValue) .. "x"
		end

		if index > 1 then
			local thresholdValue = values[index - 1]
			local unlockMission = buildUnlockMission({
				metricId = "jump_power",
				metricFormulaKey = "jumpPower",
				metricStatToken = "jump",
				metricField = "jumpPowerMultiplier",
				tierIndex = index,
				thresholdValue = thresholdValue,
				thresholdLabel = "jump power " .. formatMultiplier(thresholdValue) .. "x",
				unlockLabel = "Jump Power " .. formatMultiplier(jumpValue) .. "x",
				requiresMissionId = previousMissionId,
			})
			item.requiredMissionId = unlockMission.id
			item.unlockMission = unlockMission
			previousMissionId = unlockMission.id
		end

		table.insert(items, item)
	end

	return items
end

--============================================================================
-- ITEMS (keyed by category id)
--============================================================================

ShopConfig.ITEMS = {
	trails = if ShopConfig.SHOP_TUNING_ENABLED then buildTrailItems() else buildClassicTrailItems(),

	poofs = if ShopConfig.SHOP_TUNING_ENABLED then buildPoofItems() else buildClassicPoofItems(),

	pipes = {
		{
			id = "pipe_neon_pillar",
			name = "Neon Pillar",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "neon_pillar",
			previewColor = Color3.fromRGB(100, 200, 255),
		},
		{
			id = "pipe_classic_green",
			name = "Flappy Pipe",
			price = 500,
			currencyType = "bacon",
			configKey = "classic_green",
			previewColor = Color3.fromRGB(0, 180, 0),
		},
		{
			id = "pipe_more_coming_soon",
			name = "MORE SOON",
			price = 0,
			currencyType = "comingSoon",
			comingSoon = true,
			previewColor = Color3.fromRGB(230, 180, 40),
			previewIcon = "\u{1F6A7}",
		},
	},

	backgrounds = {
		{
			id = "bg_dark_purple",
			name = "Lava Mountain",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "DARK_PURPLE",
			previewColor = Color3.fromRGB(15, 8, 25),
		},
		{
			id = "bg_more_coming_soon",
			name = "MORE SOON",
			price = 0,
			currencyType = "comingSoon",
			comingSoon = true,
			previewColor = Color3.fromRGB(230, 180, 40),
			previewIcon = "\u{1F6A7}",
		},
	},

	floors = if ShopConfig.SHOP_TUNING_ENABLED then buildFloorItems() else buildClassicFloorItems(),
}

--============================================================================
-- UI CONSTANTS
--============================================================================

ShopConfig.UI = {
	-- Full-screen overlay
	OVERLAY_COLOR = Color3.new(0, 0, 0),
	OVERLAY_TRANSPARENCY = 0.4,

	-- Container (centered modal)
	CONTAINER_WIDTH = 460,
	CONTAINER_HEIGHT = 520,
	CONTAINER_BG_COLOR = Color3.fromRGB(30, 25, 40),
	CONTAINER_BG_TRANSPARENCY = 0.05,
	CONTAINER_CORNER_RADIUS = UDim.new(0, 12),

	-- Header
	HEADER_HEIGHT = 50,
	TITLE_TEXT = "SHOP",
	TITLE_FONT = Enum.Font.GothamBlack,
	TITLE_COLOR = Color3.fromRGB(255, 220, 100),
	TITLE_SIZE = 28,
	TITLE_STROKE_COLOR = Color3.fromRGB(80, 50, 10),
	TITLE_STROKE_TRANSPARENCY = 0.4,
	CLOSE_BUTTON_SIZE = 36,
	CLOSE_BUTTON_COLOR = Color3.fromRGB(200, 60, 60),
	CLOSE_BUTTON_FONT = Enum.Font.GothamBlack,

	-- Balance display (in header)
	BALANCE_FONT = Enum.Font.GothamBold,
	BALANCE_COLOR = Color3.fromRGB(255, 200, 120),
	BALANCE_SIZE = 18,

	-- Category tabs
	TAB_HEIGHT = 36,
	TAB_FONT = Enum.Font.GothamBold,
	TAB_SIZE = 14,
	TAB_ACTIVE_COLOR = Color3.fromRGB(255, 200, 80),
	TAB_INACTIVE_COLOR = Color3.fromRGB(160, 150, 140),
	TAB_ACTIVE_BG = Color3.fromRGB(60, 50, 30),
	TAB_INACTIVE_BG = Color3.fromRGB(40, 35, 50),
	TAB_CORNER_RADIUS = UDim.new(0, 6),

	-- Item grid
	GRID_PADDING = UDim.new(0, 8),
	CARD_SIZE = UDim2.new(0, 130, 0, 160),

	-- Item card
	CARD_BG_COLOR = Color3.fromRGB(50, 45, 60),
	CARD_CORNER_RADIUS = UDim.new(0, 8),
	PREVIEW_SIZE = UDim2.new(0, 80, 0, 80),
	PREVIEW_CORNER_RADIUS = UDim.new(0, 6),
	PREVIEW_ICON_FONT = Enum.Font.GothamBlack,
	PREVIEW_ICON_COLOR = Color3.fromRGB(60, 40, 10),
	NAME_FONT = Enum.Font.GothamBold,
	NAME_SIZE = 13,
	NAME_COLOR = Color3.new(1, 1, 1),

	-- Action button states
	BUTTON_HEIGHT = 28,
	BUTTON_FONT = Enum.Font.GothamBold,
	BUTTON_SIZE = 13,
	BUTTON_CORNER_RADIUS = UDim.new(0, 5),
	BUY_COLOR = Color3.fromRGB(60, 170, 50),
	BUY_TEXT_COLOR = Color3.new(1, 1, 1),
	EQUIP_COLOR = Color3.fromRGB(50, 130, 220),
	EQUIP_TEXT_COLOR = Color3.new(1, 1, 1),
	EQUIPPED_COLOR = Color3.fromRGB(80, 80, 80),
	EQUIPPED_TEXT_COLOR = Color3.fromRGB(180, 180, 180),
	LOCKED_COLOR = Color3.fromRGB(70, 55, 35),
	LOCKED_TEXT_COLOR = Color3.fromRGB(245, 220, 170),
	LOCKED_TEXT = "Complete Mission",
	INSUFFICIENT_COLOR = Color3.fromRGB(100, 40, 40),
	INSUFFICIENT_TEXT_COLOR = Color3.fromRGB(160, 120, 120),
	COMING_SOON_COLOR = Color3.fromRGB(120, 95, 35),
	COMING_SOON_TEXT_COLOR = Color3.fromRGB(255, 230, 170),
	COMING_SOON_TEXT = "\u{1F6A7} MORE SOON",

	-- UIScale reference
	REFERENCE_HEIGHT = 800,
	MIN_SCALE = 0.45,
	MAX_SCALE = 1.2,
}

--============================================================================
-- READY SCREEN SHOP BUTTON
--============================================================================

ShopConfig.READY_BUTTON = {
	BILLBOARD_SIZE = UDim2.new(8, 0, 8, 0),
	STUDS_OFFSET = Vector3.new(0, 0, 0),
	ROW_ORDER = 2,
	LOCAL_OFFSET = Vector3.new(0, 0, 0),
	BG_COLOR = Color3.fromRGB(255, 200, 80),
	BG_TRANSPARENCY = 0.1,
	CORNER_RADIUS = UDim.new(0.15, 0),
	TEXT = "\u{1F6D2}",
	LABEL = "SHOP",
	LABEL_FONT = Enum.Font.GothamBlack,
	LABEL_COLOR = Color3.fromRGB(50, 35, 10),
}

--============================================================================
-- DATASTORE
--============================================================================

ShopConfig.DATASTORE_NAME = "FlappyBirdShop"

--============================================================================
-- HELPER FUNCTIONS
--============================================================================

local function cloneTable(value)
	if type(value) ~= "table" then
		return value
	end

	local output = {}
	for key, child in pairs(value) do
		output[key] = cloneTable(child)
	end
	return output
end

-- Item lookup cache (built lazily)
local _itemCache = nil
local _categoryCache = nil

local function ensureCache()
	if _itemCache then
		return
	end

	_itemCache = {}
	_categoryCache = {}
	for catId, items in pairs(ShopConfig.ITEMS) do
		for _, item in ipairs(items) do
			_itemCache[item.id] = item
			_categoryCache[item.id] = catId
		end
	end
end

function ShopConfig.getItem(itemId)
	ensureCache()
	return _itemCache[itemId]
end

function ShopConfig.getItemsByCategory(catId)
	return ShopConfig.ITEMS[catId] or {}
end

function ShopConfig.getDefault(catId)
	local items = ShopConfig.ITEMS[catId]
	if not items then
		return nil
	end

	for _, item in ipairs(items) do
		if item.default then
			return item
		end
	end

	return items[1]
end

function ShopConfig.getCategoryForItem(itemId)
	ensureCache()
	return _categoryCache[itemId]
end

function ShopConfig.getMissionLockedItems()
	local output = {}

	for _, category in ipairs(ShopConfig.CATEGORIES) do
		for _, item in ipairs(ShopConfig.getItemsByCategory(category.id)) do
			if type(item.requiredMissionId) == "string" and type(item.unlockMission) == "table" then
				table.insert(output, {
					categoryId = category.id,
					itemId = item.id,
					itemName = item.name,
					requiredMissionId = item.requiredMissionId,
					unlockMission = cloneTable(item.unlockMission),
				})
			end
		end
	end

	return output
end

return ShopConfig
