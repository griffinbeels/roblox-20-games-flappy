--[[
	ShopConfig.luau

	Single source of truth for the cosmetic shop: categories, items, UI constants.
	Adding new items or categories requires only edits to this file.

	ITEM FIELDS:
	  id          (string)  — unique identifier
	  name        (string)  — display name
	  price       (number)  — cost in currency (0 = free)
	  currencyType(string)  — "bacon" (future: "robux")
	  default     (bool?)   — true = auto-owned, never needs purchase
	  comingSoon  (bool?)   — true = non-purchasable placeholder item
	  configKey   (string)  — key into the runtime config for this category
	  previewColor(Color3)  — colored square preview in the shop card
	  previewIcon (string?) — optional emoji/icon shown in preview square

	CATEGORY FIELDS:
	  id    (string)  — unique identifier, matches key in ITEMS table
	  label (string)  — display name for tab
	  icon  (string)  — emoji or short text for tab
]]

local ShopConfig = {}

--============================================================================
-- CATEGORIES (ordered — tab order in UI)
--============================================================================

ShopConfig.CATEGORIES = {
	{ id = "trails",      label = "Trails",      icon = "\u{2728}" },  -- sparkles
	{ id = "pipes",       label = "Pipes",       icon = "\u{1FAA8}" }, -- rock
	{ id = "backgrounds", label = "Backgrounds", icon = "\u{1F30C}" }, -- milky way
	{ id = "floors",      label = "Floors",      icon = "\u{1F525}" }, -- fire
}

--============================================================================
-- ITEMS (keyed by category id)
--============================================================================

ShopConfig.ITEMS = {
	trails = {
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
			price = 250,
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
	},

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
			price = 50,
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
		-- {
		-- 	id = "bg_dark_plain",
		-- 	name = "Dark Plain",
		-- 	price = 20,
		-- 	currencyType = "bacon",
		-- 	configKey = "DARK_PLAIN",
		-- 	previewColor = Color3.fromRGB(10, 5, 20),
		-- },
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

	floors = {
		{
			id = "floor_lava_mesh",
			name = "Literally Lava",
			price = 0,
			currencyType = "bacon",
			default = true,
			configKey = "LAVA_MESH",
			previewColor = Color3.fromRGB(200, 80, 20),
		},
		-- {
		-- 	id = "floor_lava_solid",
		-- 	name = "Lava Solid",
		-- 	price = 15,
		-- 	currencyType = "bacon",
		-- 	configKey = "LAVA_SOLID",
		-- 	previewColor = Color3.fromRGB(200, 50, 0),
		-- },
		{
			id = "floor_dark_gray",
			name = "Moon Floor",
			price = 100,
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
	},
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
	-- ReadyUI stacks ready buttons vertically to the right of the leaderboard.
	-- STUDS_OFFSET is treated as legacy fallback (Z only by default).
	BILLBOARD_SIZE = UDim2.new(8, 0, 8, 0),    -- studs (same coordinate space as leaderboard)
	STUDS_OFFSET = Vector3.new(0, 0, 0),
	ROW_ORDER = 2, -- higher order appears lower in the right-side stack
	LOCAL_OFFSET = Vector3.new(0, 0, 0),
	BG_COLOR = Color3.fromRGB(255, 200, 80),
	BG_TRANSPARENCY = 0.1,
	CORNER_RADIUS = UDim.new(0.15, 0),
	TEXT = "\u{1F6D2}",    -- shopping cart emoji
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

-- Item lookup cache (built lazily)
local _itemCache = nil
local _categoryCache = nil

local function ensureCache()
	if _itemCache then return end
	_itemCache = {}
	_categoryCache = {}
	for catId, items in pairs(ShopConfig.ITEMS) do
		for _, item in ipairs(items) do
			_itemCache[item.id] = item
			_categoryCache[item.id] = catId
		end
	end
end

--[[
	Returns the item table for a given itemId, or nil.
]]
function ShopConfig.getItem(itemId)
	ensureCache()
	return _itemCache[itemId]
end

--[[
	Returns the array of items for a category id.
]]
function ShopConfig.getItemsByCategory(catId)
	return ShopConfig.ITEMS[catId] or {}
end

--[[
	Returns the default item for a category (the one with default=true).
]]
function ShopConfig.getDefault(catId)
	local items = ShopConfig.ITEMS[catId]
	if not items then return nil end
	for _, item in ipairs(items) do
		if item.default then
			return item
		end
	end
	return items[1] -- fallback to first item
end

--[[
	Returns the category id for a given itemId.
]]
function ShopConfig.getCategoryForItem(itemId)
	ensureCache()
	return _categoryCache[itemId]
end

return ShopConfig
