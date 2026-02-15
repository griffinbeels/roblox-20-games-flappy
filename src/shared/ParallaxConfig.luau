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

--============================================================================
-- SKY PRESETS
-- A single large Part behind everything that follows the player.
-- Pick one and assign it to BACKGROUND below.
--============================================================================
local SKY_PRESETS = {
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
local LAYER_PRESETS = {
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
-- Part mode: a single large colored Part that follows the player.
--============================================================================
local FLOOR_PRESETS = {
	LAVA_MESH = {
		MESH_ASSET_ID   = 4574421847,
		MESH_TILE_STUDS = 200,
	},

	LAVA_SOLID = {
		COLOR    = Color3.fromRGB(200, 50, 0),
		MATERIAL = Enum.Material.Neon,
	},

	DARK_GRAY = {
		COLOR    = Color3.fromRGB(91, 91, 91),
		MATERIAL = Enum.Material.Slate,
	},
}

--============================================================================
-- ACTIVE CONFIGURATION
-- Change these three lines to reshape the entire background.
--============================================================================
return {
	BACKGROUND = SKY_PRESETS.DARK_PURPLE,

	SCENERY = {
		LAYER_PRESETS.FAR_HILLS,
		LAYER_PRESETS.NEAR_HILLS,
	},

	FLOOR = FLOOR_PRESETS.LAVA_MESH,
}
