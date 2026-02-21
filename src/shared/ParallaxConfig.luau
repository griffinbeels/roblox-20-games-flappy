--[[
	ParallaxConfig.luau

	All parallax background, scenery, and floor configuration lives here.
	Swap presets, reorder layers, or add new ones — all in one place.

	HOW TO SWAP A TEXTURE (sky or scenery):
	  1. Upload your image to Roblox as a Decal
	  2. Set TEXTURE_ID = "rbxassetid://YOUR_ID"
	  3. Set IMAGE_SIZE = {width_px, height_px}
	  The code auto-computes tiling and part sizing from the aspect ratio.
	  Tweak TILE_STUDS (sky) or TILE_WIDTH (scenery) to zoom in/out.
]]

local ParallaxConfig = {}

--============================================================================
-- SKY PRESETS
-- A single large Part behind everything that follows the player.
-- Pick one and assign it to BACKGROUND below.
--============================================================================
ParallaxConfig.SKY_PRESETS = {
	DARK_PURPLE = {
		TEXTURE_ID = "rbxassetid://116403708598360",
		IMAGE_SIZE = {300, 170},       -- Image pixel dimensions (for aspect ratio)
		TILE_STUDS = 300,              -- Width of one tile in studs (bigger = more zoomed in)
		TEXTURE_OFFSET_V = -70,        -- Shift texture vertically (+ = down, - = up)

		COLOR    = Color3.fromRGB(15, 8, 25),
		MATERIAL = Enum.Material.SmoothPlastic,
		Z        = -85,
		Y_CENTER = 20,
		FOLLOW_RATIO = 0.97,           -- 1.0 = static, lower = gentle drift
	},

	DARK_PLAIN = {
		COLOR    = Color3.fromRGB(10, 5, 20),
		MATERIAL = Enum.Material.SmoothPlastic,
		Z        = -80,
		Y_CENTER = 20,
	},
}

--============================================================================
-- LAYER PRESETS (scenery palette)
-- Horizontal bands tiled along X at different Z depths for parallax.
-- To swap a texture: change TEXTURE_ID + IMAGE_SIZE. HEIGHT auto-derives
-- from the aspect ratio. Set HEIGHT explicitly to override.
-- Z must be between the sky Z and 0 — layers behind the sky are hidden.
--============================================================================
ParallaxConfig.LAYER_PRESETS = {
	FAR_HILLS = {
		TEXTURE_ID = "rbxassetid://96979939727316",
		IMAGE_SIZE = {300, 200},

		NAME       = "Scenery_FarHills",
		Z          = -80,
		TILE_WIDTH = 300,
		DEPTH      = 2,
		Y_CENTER   = 25,
		COLOR      = Color3.fromRGB(20, 12, 25),
		MATERIAL   = Enum.Material.SmoothPlastic,
	},

	NEAR_HILLS = {
		TEXTURE_ID = "rbxassetid://122371172004434",
		IMAGE_SIZE = {200, 25},

		NAME       = "Scenery_NearHills",
		Z          = 25,
		TILE_WIDTH = 200,
		DEPTH      = 2,
		Y_CENTER   = 5,
		COLOR      = Color3.fromRGB(35, 18, 15),
		MATERIAL   = Enum.Material.SmoothPlastic,
	},

	LAVA_GLOW = {
		TEXTURE_ID = "rbxassetid://87512327478940",
		IMAGE_SIZE = {200, 15},

		NAME       = "Scenery_LavaGlow",
		Z          = -20,
		TILE_WIDTH = 200,
		DEPTH      = 1,
		Y_CENTER   = 0,
		COLOR      = Color3.fromRGB(160, 50, 5),
		MATERIAL   = Enum.Material.Neon,
		TRANSPARENCY = 0.5,
	},
}

--============================================================================
-- FLOOR PRESETS
-- Mesh mode: clones a MeshPart from ReplicatedStorage.FloorTemplates.
-- Part mode: tiled colored Parts recycled around the camera.
--
-- Supported fields:
--   MESH_ASSET_ID, MESH_TILE_STUDS (mesh mode)
--   COLOR, MATERIAL, TRANSPARENCY, TEXTURE_ID (part mode visuals)
--   TILE_WIDTH (part mode tile width along X)
--   HEIGHT (floor thickness; top is aligned to TOP_Y + TOP_OFFSET)
--   DEPTH (Z thickness for both mesh and part mode)
--   Z (visual/collider Z center)
--   TOP_Y (top surface world Y; defaults to WorldConfig.BOUNDARIES.MIN_Y)
--   TOP_OFFSET (extra vertical adjustment from TOP_Y)
--============================================================================
ParallaxConfig.FLOOR_PRESETS = {
	LAVA_MESH = {
		MESH_ASSET_ID   = 4574421847,
		MESH_TILE_STUDS = 200,
		DEPTH           = 512,
	},

	LAVA_SOLID = {
		COLOR    = Color3.fromRGB(200, 50, 0),
		MATERIAL = Enum.Material.Neon,
		TILE_WIDTH = 140,
		DEPTH = 512,
	},

	DARK_GRAY = {
		COLOR    = Color3.fromRGB(91, 91, 91),
		MATERIAL = Enum.Material.Slate,
		TILE_WIDTH = 120,
		DEPTH = 512,
	},
}

--============================================================================
-- BACKGROUND THEMES
-- Each theme bundles a sky preset + scenery layers together.
-- Used by the shop to swap the entire background as a unit.
--============================================================================
ParallaxConfig.BACKGROUND_THEMES = {
	DARK_PURPLE = {
		sky = "DARK_PURPLE",
		scenery = { "FAR_HILLS", "NEAR_HILLS" },
	},
	DARK_PLAIN = {
		sky = "DARK_PLAIN",
		scenery = {},
	},
}

--============================================================================
-- ACTIVE CONFIGURATION
-- Change these three lines to reshape the entire background.
--============================================================================
ParallaxConfig.BACKGROUND = ParallaxConfig.SKY_PRESETS.DARK_PURPLE

ParallaxConfig.SCENERY = {
	ParallaxConfig.LAYER_PRESETS.FAR_HILLS,
	ParallaxConfig.LAYER_PRESETS.NEAR_HILLS,
}

ParallaxConfig.FLOOR = ParallaxConfig.FLOOR_PRESETS.LAVA_MESH

--============================================================================
-- RUNTIME SETTERS (called by ShopManager to swap visuals)
--============================================================================

--[[
	Sets the active background theme (sky + scenery layers).
	@param themeKey string — key into BACKGROUND_THEMES
]]
function ParallaxConfig.setActiveTheme(themeKey)
	local theme = ParallaxConfig.BACKGROUND_THEMES[themeKey]
	if not theme then
		warn("[ParallaxConfig] Unknown theme: " .. tostring(themeKey))
		return
	end

	ParallaxConfig.BACKGROUND = ParallaxConfig.SKY_PRESETS[theme.sky]

	local layers = {}
	for _, layerKey in ipairs(theme.scenery) do
		local preset = ParallaxConfig.LAYER_PRESETS[layerKey]
		if preset then
			table.insert(layers, preset)
		end
	end
	ParallaxConfig.SCENERY = layers
end

--[[
	Sets the active floor preset.
	@param presetKey string — key into FLOOR_PRESETS
]]
function ParallaxConfig.setActiveFloor(presetKey)
	local preset = ParallaxConfig.FLOOR_PRESETS[presetKey]
	if not preset then
		warn("[ParallaxConfig] Unknown floor preset: " .. tostring(presetKey))
		return
	end
	ParallaxConfig.FLOOR = preset
end

return ParallaxConfig
