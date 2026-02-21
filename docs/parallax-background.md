# Parallax Background System

> **Code:** `src/client/ParallaxBackground.luau`
> **Config:** `src/shared/ParallaxConfig.luau` (sky presets, layer presets, floor presets)

## Overview

The parallax background system creates layered depth behind the gameplay area. It exploits Roblox's 3D perspective to achieve parallax **for free** — objects placed at different Z depths naturally appear to scroll at different speeds because the camera is at Z=50 looking toward Z=0.

No per-frame scroll-speed math is needed. The only per-frame work is:
1. Moving the sky backdrop to follow the player (so its edges never show)
2. Recycling scenery tiles around the player's current position (so tiles are infinite)
3. Recycling floor tiles (mesh or part mode)

## Coordinate System

```
Z axis (depth):
  Z=50   Camera position (Constants.CAMERA.OFFSET_Z)
  Z=0    Player position (gameplay plane)
  Z=-20  Near scenery (Scenery_LavaGlow)
  Z=25   Mid scenery (Scenery_NearHills)
  Z=-80  Far scenery (Scenery_FarHills)
  Z=-85  Sky backdrop (BACKGROUND)

Y axis (vertical):
  Y=50   Top of play area (BOUNDARIES.MAX_Y)
  Y=20   Camera look-at height / sky center
  Y=0    Floor surface (BOUNDARIES.MIN_Y)
  Y=-100 Floor part center (extends to Y=-200)

X axis (horizontal):
  Player moves continuously in +X direction.
  Camera follows at playerX + OFFSET_X (10 studs ahead).
```

**Important:** Scenery layer Z values must be between the sky Z and 0. Layers behind the opaque sky Part are hidden.

## Architecture: Three Systems

### 1. Sky Backdrop (`BG_Sky`)

A single large Part (2400 x 400 x 1 studs) placed at the configured Z depth. It follows the player's X position every frame (with optional drift via `FOLLOW_RATIO`) so its edges never enter the camera view.

**Config:** `ParallaxConfig.luau` → `SKY_PRESETS` (pick one for `BACKGROUND`)
```lua
BACKGROUND = {
    TEXTURE_ID = "rbxassetid://...",      -- Tiling texture image
    IMAGE_SIZE = {300, 170},              -- Pixel dimensions (for aspect ratio)
    TILE_STUDS = 300,                     -- Width of one tile in studs

    COLOR    = Color3.fromRGB(15, 8, 25), -- Part base color
    MATERIAL = Enum.Material.SmoothPlastic,
    Z        = -85,                       -- Z depth
    Y_CENTER = 20,                        -- Vertical center

    TEXTURE_OFFSET_V = -70,              -- Shift texture vertically
    FOLLOW_RATIO = 0.97,                 -- 1.0 = static, lower = gentle drift
}
```

The sky always uses a tiling `Texture` instance (not Decal). If `TILE_STUDS` is omitted, it defaults to the full Part width (single stretch). If `IMAGE_SIZE` is provided, the tile height is auto-computed from the aspect ratio.

**Sky drift:** `FOLLOW_RATIO` < 1.0 makes the sky lag slightly behind the player, creating gentle parallax drift. The drift is clamped to `SKY_MAX_DRIFT` (600 studs) so the sky edges never become visible on long runs.

### 2. Scenery Layers (`SCENERY`)

An array of Part configs, each defining a horizontal band tiled along X at a specific Z depth. Parallax comes entirely from Z positioning — objects further from the camera appear to scroll slower.

**Config:** `ParallaxConfig.luau` → `LAYER_PRESETS` (pick from palette into `SCENERY` array)

Each entry:
```lua
{
    TEXTURE_ID = "rbxassetid://...",    -- Optional Decal image (uploaded as Decal)
    IMAGE_SIZE = {300, 200},            -- Pixel dimensions (auto-derives HEIGHT)

    NAME       = "Scenery_FarHills",   -- Part name in workspace
    Z          = -80,                   -- Z depth (more negative = slower parallax)
    TILE_WIDTH = 300,                   -- Width of each tile along X
    DEPTH      = 2,                     -- Part Z-thickness (default 1)
    Y_CENTER   = 25,                    -- Vertical center of the Part
    COLOR      = Color3.fromRGB(...),   -- Part base color
    MATERIAL   = Enum.Material.SmoothPlastic,
}
```

**Height auto-compute:** If `IMAGE_SIZE` is provided, the Part height is derived from `TILE_WIDTH * (imageHeight / imageWidth)`. Set `HEIGHT` explicitly to override.

**Current layers:**

| Layer | Z | Tile Width | Purpose |
|-------|---|------------|---------|
| `Scenery_FarHills` | -80 | 300 | Distant mountain silhouettes |
| `Scenery_NearHills` | 25 | 200 | Closer rocky hills |

#### Perspective-Correct Tile Count

The camera at Z=50 sees a wider world-X range for objects at deeper Z depths. The system accounts for this:

```
distance_to_layer = CAMERA_Z - layerZ      (e.g. 50 - (-80) = 130)
view_scale = distance / CAMERA_Z            (e.g. 130 / 50 = 2.6)
visible_half_width = BASE_VIEW_HALF_WIDTH * view_scale   (70 * 2.6 = 182 studs)
tiles_per_side = ceil(visible_half_width / tile_width) + 1
```

#### Tile Recycling

Tiles are keyed by grid index (`gridX`). Each frame, the system computes which grid indices are needed around `playerX + CAMERA_OFFSET_X`, creates missing tiles, and destroys tiles that are no longer needed. The `lastCenterGX` optimization skips processing when the camera hasn't moved to a new grid cell.

#### Texture Handling

When `TEXTURE_ID` is set:
- The Part's `Transparency` is forced to `1` (fully invisible)
- A `Decal` is applied to the `Back` face (facing +Z toward the camera)
- Transparent areas of the Decal image show through to layers behind

When `TEXTURE_ID` is not set:
- The Part renders with its `COLOR`, `MATERIAL`, and `TRANSPARENCY` as a solid colored block

**Important:** Image asset IDs must be **Decal** asset IDs (uploaded via Creator Hub as Decals). Scenery uses `Decal` instances which stretch to fill the Part face. To swap a texture: change `TEXTURE_ID` and `IMAGE_SIZE` — the height auto-derives from the aspect ratio.

### 3. Floor

Two modes:

**Mesh mode**: Tiles clones of a MeshPart from `ReplicatedStorage.FloorTemplates`. Each tile is scaled to `MESH_TILE_STUDS` studs and recycled around the camera.

**Part mode** (fallback): Recycles solid floor tiles around the camera (same infinite-grid model as scenery). Used when `MESH_ASSET_ID` is not set or the template isn't found.

In both modes, a transparent collider (`FloorCollider`) tracks player X for stable floor raycasts/collision while visuals remain world-anchored for proper leftward motion.

**Config:** `ParallaxConfig.luau` → `FLOOR_PRESETS` (pick one for `FLOOR`)
```lua
FLOOR = {
    MESH_ASSET_ID = 4574421847,  -- Asset ID of MeshPart in FloorTemplates
    MESH_TILE_STUDS = 200,       -- World size of each tile
    DEPTH = 512,                 -- Z thickness
    TOP_OFFSET = 0,              -- Vertical tweak from top surface baseline
}
```

## Public API

| Method | Description |
|--------|-------------|
| `init(playerCtrl)` | Creates sky, scenery, and floor. Call once. |
| `start()` | Begins Heartbeat loop (sky following, tile recycling) |
| `stop()` | Disconnects Heartbeat loop (called on game over) |
| `reset()` | Repositions everything around current player position |
| `destroy()` | Cleans up all Parts from workspace |

## How to Swap a Texture

1. Upload your image to Roblox as a **Decal** at [create.roblox.com](https://create.roblox.com)
2. Set `TEXTURE_ID = "rbxassetid://YOUR_ID"` in the preset
3. Set `IMAGE_SIZE = {width_px, height_px}` — height auto-derives from the aspect ratio
4. Tweak `TILE_STUDS` (sky) or `TILE_WIDTH` (scenery) to zoom in/out

## How to Add a New Scenery Layer

1. Add a preset to `LAYER_PRESETS` in `ParallaxConfig.luau`
2. Reference it in the `SCENERY` array (add/remove = one line)
3. Choose a Z value between the sky Z and 0
4. The system handles tile creation, recycling, and perspective scaling automatically

## Known Issues / Future Work

- Scenery tiles are flat Part rectangles with Decals. More complex geometry (MeshParts from marketplace) could replace them.
- The `BASE_VIEW_HALF_WIDTH` (70 studs) is an approximation. If the camera FOV changes or the window is very wide, tiles might not fully cover the edges.
- Scenery Decals stretch to fill the Part face. If your source image has a different aspect ratio than the Part, the image will be distorted. Using `IMAGE_SIZE` with auto-computed height avoids this.
