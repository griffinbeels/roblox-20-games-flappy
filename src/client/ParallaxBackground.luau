--[[
	ParallaxBackground.luau

	Layered background using natural 3D parallax — objects at deeper Z depths
	appear to scroll slower because the camera is at Z=50. No scroll-speed math
	needed. Per-frame work: sky following, scenery tile recycling, floor tiles.

	Config: src/shared/ParallaxConfig.luau
	Docs:   docs/parallax-background.md
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local CameraConfig = require(ReplicatedStorage.Shared.CameraConfig)
local ParallaxConfig = require(ReplicatedStorage.Shared.ParallaxConfig)

local ParallaxBackground = {}

local updateConnection = nil
local PlayerController = nil

-- Sky backdrop (follows player so edges never show)
local skyPart = nil
local skyFollowRatio = 1.0
local skyFixedY = 0
local skyFixedZ = 0

-- Floor state
local floorPart = nil
local meshFloorTemplate = nil
local meshOriginalSize = nil
local meshWorldTileSize = 0
local meshScaledHeight = 0
local meshTiles = {}
local meshTilesPerSide = 0
local meshTilesPerSideZ = 0
local meshFloorCollider = nil
local meshLastCenterGX = -9999

-- Scenery tile state
local sceneryState = {}

-- Sizing constants
local SKY_WIDTH = 2400
local SKY_HEIGHT = 400
local SKY_MAX_DRIFT = SKY_WIDTH * 0.25
local FLOOR_WIDTH = 1200
local FLOOR_HEIGHT = WorldConfig.FLOOR.HEIGHT
local FLOOR_Y = WorldConfig.FLOOR.Y_POSITION

-- Camera
local CAMERA_Z = CameraConfig.OFFSET_Z
local CAMERA_OFFSET_X = CameraConfig.OFFSET_X
local BASE_VIEW_HALF_WIDTH = 70

--============================================================================
-- HELPERS
--============================================================================

--- Derives part height from IMAGE_SIZE aspect ratio, or uses explicit HEIGHT.
local function computeLayerHeight(config, tileWidth)
	if config.HEIGHT then return config.HEIGHT end
	if config.IMAGE_SIZE then
		local imgW, imgH = config.IMAGE_SIZE[1], config.IMAGE_SIZE[2]
		return tileWidth * (imgH / imgW)
	end
	return 30
end

--- Tiles needed per side for a layer at layerZ (perspective-correct).
local function computeTilesPerSide(layerZ, tileWidth)
	local dist = CAMERA_Z - layerZ
	local viewScale = dist / CAMERA_Z
	local halfWidth = BASE_VIEW_HALF_WIDTH * viewScale
	return math.ceil(halfWidth / tileWidth) + 1
end

--============================================================================
-- FLOOR HELPERS
--============================================================================

local function loadMeshTemplate(assetId)
	local folder = ReplicatedStorage:FindFirstChild("FloorTemplates")
	if not folder then
		warn("[ParallaxBackground] ReplicatedStorage.FloorTemplates folder not found")
		return nil
	end
	local template = folder:FindFirstChild(tostring(assetId))
	if not template then
		warn("[ParallaxBackground] No template found for asset ID: " .. tostring(assetId))
		return nil
	end
	return template
end

local function tileKey(gx, gz)
	return gx .. "," .. gz
end

local function createMeshTile(gridX, gridZ)
	local tile = meshFloorTemplate:Clone()
	tile.Name = "FloorMeshTile"
	tile.Anchored = true
	tile.CanCollide = false
	tile.CastShadow = false
	tile.Size = Vector3.new(meshWorldTileSize, meshScaledHeight, meshWorldTileSize)
	tile.Position = Vector3.new(gridX * meshWorldTileSize, -(meshScaledHeight / 2), gridZ * meshWorldTileSize)
	tile.Parent = workspace
	return tile
end

local function updateMeshFloor(playerX)
	if not meshFloorTemplate then return end

	if meshFloorCollider then
		meshFloorCollider.Position = Vector3.new(playerX, FLOOR_Y, 0)
	end

	local centerGX = math.floor(playerX / meshWorldTileSize + 0.5)
	if centerGX == meshLastCenterGX then return end
	meshLastCenterGX = centerGX

	local needed = {}
	for gx = centerGX - meshTilesPerSide, centerGX + meshTilesPerSide do
		for gz = -meshTilesPerSideZ, meshTilesPerSideZ do
			local key = tileKey(gx, gz)
			needed[key] = true
			if not meshTiles[key] then
				meshTiles[key] = createMeshTile(gx, gz)
			end
		end
	end
	for key, tile in pairs(meshTiles) do
		if not needed[key] then
			tile:Destroy()
			meshTiles[key] = nil
		end
	end
end

--============================================================================
-- SCENERY HELPERS
--============================================================================

local function createSceneryTile(config, gridX, tileWidth, height)
	local part = Instance.new("Part")
	part.Name = config.NAME or "Scenery"
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Size = Vector3.new(tileWidth, height, config.DEPTH or 1)
	part.Color = config.COLOR or Color3.fromRGB(20, 20, 30)
	part.Material = config.MATERIAL or Enum.Material.SmoothPlastic
	part.Transparency = config.TRANSPARENCY or 0
	part.Position = Vector3.new(gridX * tileWidth, config.Y_CENTER or 10, config.Z or -20)
	part.Parent = workspace

	if config.TEXTURE_ID and config.TEXTURE_ID ~= "" then
		part.Transparency = 1
		local decal = Instance.new("Decal")
		decal.Name = "SceneryDecal"
		decal.Face = Enum.NormalId.Back
		decal.Texture = config.TEXTURE_ID
		decal.Color3 = config.TEXTURE_COLOR or Color3.new(1, 1, 1)
		decal.Transparency = config.TEXTURE_TRANSPARENCY or 0
		decal.Parent = part
	end

	return part
end

local function updateSceneryLayer(state, playerX)
	local tileWidth = state.tileWidth
	local tilesPerSide = state.tilesPerSide

	local viewCenterX = playerX + CAMERA_OFFSET_X
	local centerGX = math.floor(viewCenterX / tileWidth + 0.5)

	if centerGX == state.lastCenterGX then return end
	state.lastCenterGX = centerGX

	local needed = {}
	for gx = centerGX - tilesPerSide, centerGX + tilesPerSide do
		needed[gx] = true
		if not state.tiles[gx] then
			state.tiles[gx] = createSceneryTile(state.config, gx, tileWidth, state.height)
		end
	end

	for gx, tile in pairs(state.tiles) do
		if not needed[gx] then
			tile:Destroy()
			state.tiles[gx] = nil
		end
	end
end

--============================================================================
-- PUBLIC API
--============================================================================

function ParallaxBackground.init(playerCtrl)
	PlayerController = playerCtrl

	local initialX = 0
	if PlayerController then
		local pos = PlayerController.getPosition()
		if pos then initialX = pos.X end
	end

	local bgConfig = ParallaxConfig.BACKGROUND or {}
	local floorConfig = ParallaxConfig.FLOOR

	-- Sky backdrop
	skyFixedY = bgConfig.Y_CENTER or 20
	skyFixedZ = bgConfig.Z or -80
	skyFollowRatio = bgConfig.FOLLOW_RATIO or 1.0

	skyPart = Instance.new("Part")
	skyPart.Name = "BG_Sky"
	skyPart.Size = Vector3.new(SKY_WIDTH, SKY_HEIGHT, 1)
	skyPart.Position = Vector3.new(initialX, skyFixedY, skyFixedZ)
	skyPart.Color = bgConfig.COLOR or Color3.fromRGB(15, 10, 30)
	skyPart.Material = bgConfig.MATERIAL or Enum.Material.SmoothPlastic
	skyPart.Transparency = 0
	skyPart.Anchored = true
	skyPart.CanCollide = false
	skyPart.CastShadow = false
	skyPart.Parent = workspace

	-- Sky texture (always tiling Texture — TILE_STUDS defaults to SKY_WIDTH for a single stretch)
	if bgConfig.TEXTURE_ID and bgConfig.TEXTURE_ID ~= "" then
		local tileU = bgConfig.TILE_STUDS or SKY_WIDTH
		local tileV = tileU
		if bgConfig.IMAGE_SIZE then
			local imgW, imgH = bgConfig.IMAGE_SIZE[1], bgConfig.IMAGE_SIZE[2]
			tileV = tileU * (imgH / imgW)
		end

		local tex = Instance.new("Texture")
		tex.Name = "SkyTexture"
		tex.Face = Enum.NormalId.Back
		tex.Texture = bgConfig.TEXTURE_ID
		tex.Color3 = bgConfig.TEXTURE_COLOR or Color3.new(1, 1, 1)
		tex.Transparency = bgConfig.TEXTURE_TRANSPARENCY or 0
		tex.StudsPerTileU = tileU
		tex.StudsPerTileV = tileV
		tex.OffsetStudsU = bgConfig.TEXTURE_OFFSET_U or 0
		tex.OffsetStudsV = bgConfig.TEXTURE_OFFSET_V or 0
		tex.Parent = skyPart
	end

	-- Scenery layers
	sceneryState = {}
	local sceneryConfigs = ParallaxConfig.SCENERY or {}
	for _, config in ipairs(sceneryConfigs) do
		local tileWidth = config.TILE_WIDTH or 200
		local layerZ = config.Z or -20
		local height = computeLayerHeight(config, tileWidth)
		local state = {
			config = config,
			tiles = {},
			tileWidth = tileWidth,
			height = height,
			tilesPerSide = computeTilesPerSide(layerZ, tileWidth),
			lastCenterGX = -9999,
		}
		table.insert(sceneryState, state)
		updateSceneryLayer(state, initialX)
	end

	-- Floor (mesh or Part mode)
	local meshAssetId = floorConfig.MESH_ASSET_ID
	if meshAssetId and meshAssetId ~= "" then
		meshFloorTemplate = loadMeshTemplate(meshAssetId)
		if meshFloorTemplate then
			meshOriginalSize = meshFloorTemplate.Size
			meshWorldTileSize = floorConfig.MESH_TILE_STUDS or 200
			local scaleXZ = meshWorldTileSize / meshOriginalSize.X
			meshScaledHeight = meshOriginalSize.Y * scaleXZ
			meshTilesPerSide = math.ceil(80 / meshWorldTileSize) + 1
			meshTilesPerSideZ = math.ceil(256 / meshWorldTileSize) + 1
			meshLastCenterGX = -9999

			meshFloorCollider = Instance.new("Part")
			meshFloorCollider.Name = "FloorLayer"
			meshFloorCollider.Size = Vector3.new(FLOOR_WIDTH, FLOOR_HEIGHT, 512)
			meshFloorCollider.Position = Vector3.new(initialX, FLOOR_Y, 0)
			meshFloorCollider.Transparency = 1
			meshFloorCollider.CanCollide = true
			meshFloorCollider.Anchored = true
			meshFloorCollider.CastShadow = false
			meshFloorCollider.Parent = workspace

			updateMeshFloor(initialX)
		else
			meshAssetId = nil
		end
	end

	if not meshAssetId or meshAssetId == "" or not meshFloorTemplate then
		floorPart = Instance.new("Part")
		floorPart.Name = "FloorLayer"
		floorPart.Size = Vector3.new(FLOOR_WIDTH, FLOOR_HEIGHT, 512)
		floorPart.Position = Vector3.new(initialX, FLOOR_Y, 0)
		floorPart.Color = floorConfig.COLOR or Color3.fromRGB(91, 91, 91)
		floorPart.Material = floorConfig.MATERIAL or Enum.Material.Slate
		floorPart.Transparency = floorConfig.TRANSPARENCY or 0
		floorPart.Anchored = true
		floorPart.CanCollide = true
		floorPart.CastShadow = false
		floorPart.Parent = workspace
	end
end

function ParallaxBackground.start()
	if updateConnection then
		updateConnection:Disconnect()
	end

	updateConnection = RunService.Heartbeat:Connect(function()
		if not PlayerController then return end
		local playerPos = PlayerController.getPosition()
		if not playerPos then return end

		-- Sky follows player X with gentle drift, clamped so edges never show
		if skyPart and skyPart.Parent then
			local skyX = playerPos.X * skyFollowRatio
			local drift = playerPos.X - skyX
			skyX = playerPos.X - math.clamp(drift, -SKY_MAX_DRIFT, SKY_MAX_DRIFT)
			skyPart.Position = Vector3.new(skyX, skyFixedY, skyFixedZ)
		end

		-- Floor follows player X (Part mode only)
		if floorPart and floorPart.Parent then
			floorPart.Position = Vector3.new(playerPos.X, FLOOR_Y, 0)
		end

		-- Mesh floor tile recycling
		if meshFloorTemplate then
			updateMeshFloor(playerPos.X)
		end

		-- Scenery tile recycling
		for _, state in ipairs(sceneryState) do
			updateSceneryLayer(state, playerPos.X)
		end
	end)
end

function ParallaxBackground.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

function ParallaxBackground.reset()
	meshLastCenterGX = -9999
	if PlayerController then
		local playerPos = PlayerController.getPosition()
		if playerPos then
			if skyPart then
				skyPart.Position = Vector3.new(playerPos.X, skyFixedY, skyFixedZ)
			end
			if floorPart then
				floorPart.Position = Vector3.new(playerPos.X, FLOOR_Y, 0)
			end
			if meshFloorTemplate then
				updateMeshFloor(playerPos.X)
			end
			for _, state in ipairs(sceneryState) do
				state.lastCenterGX = -9999
				updateSceneryLayer(state, playerPos.X)
			end
		end
	end
end

function ParallaxBackground.destroy()
	ParallaxBackground.stop()

	if skyPart then
		skyPart:Destroy()
		skyPart = nil
	end

	if floorPart then
		floorPart:Destroy()
		floorPart = nil
	end

	for key, tile in pairs(meshTiles) do
		tile:Destroy()
	end
	meshTiles = {}

	if meshFloorCollider then
		meshFloorCollider:Destroy()
		meshFloorCollider = nil
	end

	meshFloorTemplate = nil
	meshOriginalSize = nil
	meshLastCenterGX = -9999

	for _, state in ipairs(sceneryState) do
		for _, tile in pairs(state.tiles) do
			tile:Destroy()
		end
	end
	sceneryState = {}
end

return ParallaxBackground
