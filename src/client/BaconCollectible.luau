--[[
	BaconCollectible.luau

	Manages physical bacon collectibles that spawn in pipe gaps.
	Each bacon floats with a gentle bob animation, has a glow effect,
	and is collected when the player's hitbox overlaps its hitbox.

	On collection, the 3D bacon is destroyed and a screen-space emoji
	flies toward the score label (shrinking en route). The score only
	increments when the fly animation completes.

	Supports 3 display modes (configured in CurrencyConfig.COLLECTIBLE.DISPLAY):
	  "emoji" - BillboardGui with TextLabel (default)
	  "image" - BillboardGui with ImageLabel (asset ID)
	  "model" - 3D model cloned from ReplicatedStorage.CollectibleModels

	Sizing is gap-relative: visual and hitbox sizes are fractions of the pipe gap.

	LIFECYCLE:
	  spawnAtGap() -> creates anchored Part with display visual + PointLight
	  start()      -> connects Heartbeat for bobbing, collection checks, recycling
	  stop()       -> disconnects Heartbeat + cancels fly animations
	  clear()      -> destroys all active bacons + cancels fly animations
	  destroy()    -> stop + clear + destroy fly ScreenGui
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)

local BaconCollectible = {}

-- State
local activeBacons = {} -- { part, baseY, xPosition, spawnTime, collected, hitboxSize }
local updateConnection = nil
local onCollectedCallback = nil
local PlayerController = nil
local cfg = CurrencyConfig.COLLECTIBLE
local animCfg = CurrencyConfig.COLLECT_ANIMATION

-- Fly-to-score animation state
local onAnimationCompleteCallback = nil
local getTargetPositionFn = nil
local getGameSpeedScaleFn = nil
local flyScreenGui = nil
local activeFlyAnimations = {} -- { { element = GuiObject, tween = Tween } }
local pendingAnimationScoreCount = 0 -- collected bacons whose score callback has not been applied yet

--[[
	Resolves duration + easing from config so tuning can happen in CurrencyConfig.
	Supports easy knobs (CURVE_TYPE, SPEED_MULTIPLIER, scales_with_game) with legacy fallback fields.
]]
local function getCollectTweenSettings()
	local baseDuration = animCfg.DURATION or 0.5
	local baseSpeedMultiplier = animCfg.SPEED_MULTIPLIER or 1
	if baseSpeedMultiplier <= 0 then
		baseSpeedMultiplier = 1
	end

	local effectiveSpeedMultiplier = baseSpeedMultiplier
	local scalesWithGame = animCfg.scales_with_game
	if scalesWithGame == nil then
		scalesWithGame = animCfg.SCALES_WITH_GAME
	end

	if scalesWithGame and getGameSpeedScaleFn then
		local ok, gameSpeedScale = pcall(getGameSpeedScaleFn)
		if ok and type(gameSpeedScale) == "number" then
			local minScale = animCfg.GAME_SPEED_SCALE_MIN or 1
			local maxScale = animCfg.GAME_SPEED_SCALE_MAX or 1
			if minScale > maxScale then
				minScale, maxScale = maxScale, minScale
			end
			gameSpeedScale = math.clamp(gameSpeedScale, minScale, maxScale)
			effectiveSpeedMultiplier = effectiveSpeedMultiplier * gameSpeedScale
		end
	end

	if effectiveSpeedMultiplier <= 0 then
		effectiveSpeedMultiplier = 1
	end

	local duration = baseDuration / effectiveSpeedMultiplier

	local styleName = animCfg.EASING_STYLE or "Quad"
	local directionName = animCfg.EASING_DIRECTION or "Out"

	local curveType = animCfg.CURVE_TYPE
	local curvePresets = animCfg.CURVE_PRESETS
	if curveType and type(curvePresets) == "table" then
		local preset = curvePresets[curveType]
		if type(preset) == "table" then
			if type(preset.style) == "string" then
				styleName = preset.style
			end
			if type(preset.direction) == "string" then
				directionName = preset.direction
			end
		end
	end

	local easingStyle = Enum.EasingStyle[styleName] or Enum.EasingStyle.Quad
	local easingDirection = Enum.EasingDirection[directionName] or Enum.EasingDirection.Out

	return duration, easingStyle, easingDirection
end

--[[
	Creates a BillboardGui with emoji TextLabel on the given part.
]]
local function createEmojiDisplay(part, visualSize)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BaconBillboard"
	billboard.Size = UDim2.new(visualSize, 0, visualSize, 0)
	billboard.AlwaysOnTop = false
	billboard.Adornee = part
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "BaconLabel"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = cfg.DISPLAY.EMOJI
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard
end

--[[
	Creates a BillboardGui with ImageLabel on the given part.
]]
local function createImageDisplay(part, visualSize)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BaconBillboard"
	billboard.Size = UDim2.new(visualSize, 0, visualSize, 0)
	billboard.AlwaysOnTop = false
	billboard.Adornee = part
	billboard.Parent = part

	local imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "BaconImage"
	imageLabel.Size = UDim2.new(1, 0, 1, 0)
	imageLabel.BackgroundTransparency = 1
	imageLabel.Image = cfg.DISPLAY.IMAGE
	imageLabel.ScaleType = Enum.ScaleType.Fit
	imageLabel.Parent = billboard
end

--[[
	Clones a model from ReplicatedStorage.CollectibleModels and parents it to the part.
	Scales the model so its largest bounding dimension matches visualSize.
]]
local function createModelDisplay(part, visualSize)
	local modelsFolder = ReplicatedStorage:FindFirstChild("CollectibleModels")
	if not modelsFolder then
		warn("[BaconCollectible] ReplicatedStorage.CollectibleModels folder not found")
		return
	end

	local template = modelsFolder:FindFirstChild(cfg.DISPLAY.MODEL_NAME)
	if not template then
		warn("[BaconCollectible] Model not found: " .. tostring(cfg.DISPLAY.MODEL_NAME))
		return
	end

	local model = template:Clone()

	-- Scale model to fit visualSize based on its bounding box
	local cf, size = model:GetBoundingBox()
	local maxExtent = math.max(size.X, size.Y, size.Z)
	if maxExtent > 0 then
		local scaleFactor = visualSize / maxExtent
		model:ScaleTo(scaleFactor)
	end

	-- Position model at part center
	model:PivotTo(part.CFrame)
	model.Parent = part
end

--[[
	Creates the appropriate visual based on cfg.DISPLAY.MODE.
]]
local function createDisplay(part, visualSize)
	local mode = cfg.DISPLAY.MODE

	if mode == "image" and cfg.DISPLAY.IMAGE ~= "" then
		createImageDisplay(part, visualSize)
	elseif mode == "model" and cfg.DISPLAY.MODEL_NAME ~= "" then
		createModelDisplay(part, visualSize)
	else
		-- Default to emoji
		createEmojiDisplay(part, visualSize)
	end
end

--[[
	Cancels all in-flight bacon animations.
	Cancelled tweens do NOT fire the animation-complete callback.
]]
local function cancelAllFlyAnimations()
	for _, anim in ipairs(activeFlyAnimations) do
		if anim.tween then
			anim.tween:Cancel()
		end
		if anim.element and anim.element.Parent then
			anim.element:Destroy()
		end
	end
	activeFlyAnimations = {}
	pendingAnimationScoreCount = 0
end

--[[
	Fires the animation-complete callback and consumes one pending score slot.
]]
local function fireAnimationComplete()
	if pendingAnimationScoreCount > 0 then
		pendingAnimationScoreCount = pendingAnimationScoreCount - 1
	end
	if onAnimationCompleteCallback then
		onAnimationCompleteCallback()
	end
end

--[[
	Creates a viewport-space fly element at the given position.
	@param vpX number - viewport X in pixels
	@param vpY number - viewport Y in pixels
	@param size number - element size in pixels
	@return TextLabel
]]
local function createFlyElement(vpX, vpY, size)
	local element = Instance.new("TextLabel")
	element.Name = "BaconFly"
	element.AnchorPoint = Vector2.new(0.5, 0.5)
	element.Size = UDim2.new(0, size, 0, size)
	element.Position = UDim2.new(0, vpX, 0, vpY)
	element.BackgroundTransparency = 1
	element.Text = animCfg.FLY_DISPLAY
	element.TextScaled = true
	element.Font = Enum.Font.GothamBold
	element.ZIndex = 100
	element.Parent = flyScreenGui
	return element
end

--[[
	Starts a fly-to-score animation from the given world position.
	Creates a screen-space emoji that shrinks while flying to the score label.
	The initial pixel size is computed from the billboard's world size so the
	2D element matches the 3D visual exactly — no pop or jitter on collection.
	On completion, fires onAnimationCompleteCallback.
	@param worldPosition Vector3
	@param worldVisualSize number - billboard size in studs
]]
local function startFlyAnimation(worldPosition, worldVisualSize)
	-- Fallback: if no ScreenGui or target function, fire callback immediately
	if not flyScreenGui or not getTargetPositionFn then
		fireAnimationComplete()
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		fireAnimationComplete()
		return
	end

	-- Convert world position to screen coordinates.
	-- The fly ScreenGui uses IgnoreGuiInset = true, so WorldToViewportPoint
	-- coords (full-screen viewport) map directly to ScreenGui positioning.
	local vpPos, onScreen = camera:WorldToViewportPoint(worldPosition)
	if not onScreen then
		fireAnimationComplete()
		return
	end
	local startX = vpPos.X
	local startY = vpPos.Y

	-- Get target (score label AbsolutePosition — viewport coords, i.e. relative
	-- to below the top bar). Add the GUI inset so the coordinates match the fly
	-- ScreenGui which uses IgnoreGuiInset = true (origin at top of screen).
	local targetAbsPos, targetAbsSize = getTargetPositionFn()
	if not targetAbsPos then
		fireAnimationComplete()
		return
	end
	local guiInset = GuiService:GetGuiInset()
	local targetCenterX = targetAbsPos.X + targetAbsSize.X / 2 + guiInset.X + targetAbsSize.X * animCfg.TARGET_OFFSET_X
	local targetCenterY = targetAbsPos.Y + targetAbsSize.Y / 2 + guiInset.Y + targetAbsSize.Y * animCfg.TARGET_OFFSET_Y

	-- Compute initial pixel size to match the 3D billboard exactly.
	-- Uses camera FOV and depth so the 2D element appears identical to the
	-- billboard that was just destroyed — no pop or size change on collection.
	local depth = vpPos.Z
	if depth <= 0 then depth = 0.001 end
	local fovRad = math.rad(camera.FieldOfView)
	local viewportHeight = camera.ViewportSize.Y
	local pixelsPerStud = viewportHeight / (2 * depth * math.tan(fovRad / 2))
	local initialSize = math.max(worldVisualSize * pixelsPerStud, animCfg.INITIAL_SCREEN_SIZE)

	-- Create the flying element at the bacon's viewport position
	local element = createFlyElement(startX, startY, initialSize)

	-- Compute final size
	local finalSize = initialSize * animCfg.SHRINK_SCALE

	-- Tween position and size to score label
	local duration, easingStyle, easingDirection = getCollectTweenSettings()
	local tweenInfo = TweenInfo.new(
		duration,
		easingStyle,
		easingDirection
	)
	local tween = TweenService:Create(element, tweenInfo, {
		Position = UDim2.new(0, targetCenterX, 0, targetCenterY),
		Size = UDim2.new(0, finalSize, 0, finalSize),
	})

	local animEntry = { element = element, tween = tween }
	table.insert(activeFlyAnimations, animEntry)

	tween.Completed:Connect(function(playbackState)
		-- Clean up the element
		if element and element.Parent then
			element:Destroy()
		end
		-- Remove from tracking
		for i, entry in ipairs(activeFlyAnimations) do
			if entry == animEntry then
				table.remove(activeFlyAnimations, i)
				break
			end
		end
		-- Only fire callback if animation completed naturally (not cancelled)
		if playbackState == Enum.PlaybackState.Completed then
			fireAnimationComplete()
		end
	end)

	tween:Play()
end

--[[
	Stores a reference to PlayerController for position queries.
	Creates the ScreenGui used for fly-to-score animations.
	@param playerCtrl PlayerController
]]
function BaconCollectible.init(playerCtrl)
	PlayerController = playerCtrl

	-- Create ScreenGui for fly animations.
	-- IgnoreGuiInset = true so the ScreenGui origin is (0,0) at the top-left
	-- of the screen, matching both WorldToViewportPoint coords (the 3D viewport
	-- spans the full screen) and AbsolutePosition from the score label (always
	-- in screen space).
	if not flyScreenGui then
		flyScreenGui = Instance.new("ScreenGui")
		flyScreenGui.Name = "BaconFlyAnimation"
		flyScreenGui.ResetOnSpawn = false
		flyScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		flyScreenGui.IgnoreGuiInset = true
		flyScreenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	end
end

--[[
	Creates a bacon collectible at the center of a pipe gap.
	@param xPosition number - X position of the pipe pair
	@param gapY number - Y center of the gap
	@param gapSize number - Height of the gap in studs
]]
function BaconCollectible.spawnAtGap(xPosition, gapY, gapSize)
	-- Compute gap-relative sizes
	local visualSize = gapSize * cfg.GAP_FILL
	local hitboxY = gapSize * cfg.HITBOX_GAP_FILL
	local hitboxSize = Vector3.new(cfg.HITBOX_WIDTH, hitboxY, cfg.HITBOX_WIDTH)

	-- Invisible anchored part as the hitbox
	local part = Instance.new("Part")
	part.Name = "BaconCollectible"
	part.Size = hitboxSize
	part.Position = Vector3.new(xPosition, gapY, 0)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Parent = workspace

	-- Create visual based on display mode
	createDisplay(part, visualSize)

	-- PointLight for glow
	local light = Instance.new("PointLight")
	light.Color = cfg.GLOW_COLOR
	light.Brightness = cfg.GLOW_BRIGHTNESS
	light.Range = cfg.GLOW_RANGE
	light.Parent = part

	table.insert(activeBacons, {
		part = part,
		baseY = gapY,
		xPosition = xPosition,
		spawnTime = tick(),
		collected = false,
		hitboxSize = hitboxSize,
		visualSize = visualSize,
	})
end

--[[
	Registers a callback that fires immediately when a bacon is collected.
	Use for instant effects like currency. For score, use setOnAnimationComplete.
	@param callback function()
]]
function BaconCollectible.setOnCollected(callback)
	onCollectedCallback = callback
end

--[[
	Registers a callback that fires when the fly-to-score animation completes.
	Use for delayed effects like score increment.
	@param callback function()
]]
function BaconCollectible.setOnAnimationComplete(callback)
	onAnimationCompleteCallback = callback
end

--[[
	Consumes and returns unresolved animation-complete score events.
	Used at game-over snapshot so score can't lag behind collected bacon.
	@return number
]]
function BaconCollectible.consumePendingAnimationCount()
	local pending = pendingAnimationScoreCount
	pendingAnimationScoreCount = 0
	return pending
end

--[[
	Sets the function used to get the fly animation target position.
	The function should return (AbsolutePosition, AbsoluteSize) of the score label.
	@param fn function() -> (Vector2, Vector2)
]]
function BaconCollectible.setFlyTarget(fn)
	getTargetPositionFn = fn
end

--[[
	Sets the function used to get the current game speed scale.
	Expected return value is a multiplier (1.0 = base game speed).
	@param fn function() -> number
]]
function BaconCollectible.setGameSpeedScaleSource(fn)
	if type(fn) == "function" then
		getGameSpeedScaleFn = fn
	else
		getGameSpeedScaleFn = nil
	end
end

--[[
	Connects the Heartbeat loop for bobbing, collection detection, and recycling.
]]
function BaconCollectible.start()
	if updateConnection then
		updateConnection:Disconnect()
	end

	updateConnection = RunService.Heartbeat:Connect(function()
		if not PlayerController then return end

		local playerPos = PlayerController.getPosition()
		if not playerPos then return end

		local playerX = playerPos.X
		local now = tick()

		-- Player hitbox extents
		local pRadius = PlayerConfig.HITBOX_RADIUS
		local pHalfH = PlayerConfig.HITBOX_HALF_HEIGHT
		local playerMinX = playerX - pRadius
		local playerMaxX = playerX + pRadius
		local playerMinY = playerPos.Y - pHalfH
		local playerMaxY = playerPos.Y + pHalfH
		local playerMinZ = playerPos.Z - pRadius
		local playerMaxZ = playerPos.Z + pRadius

		for i = #activeBacons, 1, -1 do
			local bacon = activeBacons[i]

			if bacon.collected then
				continue
			end

			-- Bobbing animation
			local elapsed = now - bacon.spawnTime
			local newY = bacon.baseY + math.sin(elapsed * cfg.BOB_SPEED) * cfg.BOB_AMPLITUDE
			if bacon.part and bacon.part.Parent then
				bacon.part.Position = Vector3.new(bacon.xPosition, newY, 0)

				-- For model mode, re-pivot any child model to follow the part
				if cfg.DISPLAY.MODE == "model" then
					local childModel = bacon.part:FindFirstChildWhichIsA("Model")
					if childModel then
						childModel:PivotTo(bacon.part.CFrame)
					end
				end
			end

			-- Collection AABB check (uses per-bacon hitboxSize)
			if bacon.part and bacon.part.Parent then
				local bSize = bacon.hitboxSize
				local bPos = bacon.part.Position
				local bMinX = bPos.X - bSize.X / 2
				local bMaxX = bPos.X + bSize.X / 2
				local bMinY = bPos.Y - bSize.Y / 2
				local bMaxY = bPos.Y + bSize.Y / 2
				local bMinZ = bPos.Z - bSize.Z / 2
				local bMaxZ = bPos.Z + bSize.Z / 2

				local overlapX = playerMaxX > bMinX and playerMinX < bMaxX
				local overlapY = playerMaxY > bMinY and playerMinY < bMaxY
				local overlapZ = playerMaxZ > bMinZ and playerMinZ < bMaxZ

				if overlapX and overlapY and overlapZ then
					bacon.collected = true
					local flyPos = bacon.part.Position
					local flyVisualSize = bacon.visualSize
					bacon.part:Destroy()
					if onCollectedCallback then
						onCollectedCallback()
					end
					pendingAnimationScoreCount = pendingAnimationScoreCount + 1
					startFlyAnimation(flyPos, flyVisualSize)
				end
			end

			-- Recycling: remove bacons far behind the player
			if bacon.xPosition < playerX - cfg.DESPAWN_BEHIND then
				if bacon.part and bacon.part.Parent then
					bacon.part:Destroy()
				end
				table.remove(activeBacons, i)
			end
		end
	end)
end

--[[
	Disconnects the Heartbeat loop and cancels any in-flight animations.
]]
function BaconCollectible.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	cancelAllFlyAnimations()
end

--[[
	Destroys all active bacon collectibles and cancels fly animations.
]]
function BaconCollectible.clear()
	for _, bacon in ipairs(activeBacons) do
		if bacon.part and bacon.part.Parent then
			bacon.part:Destroy()
		end
	end
	activeBacons = {}
	cancelAllFlyAnimations()
end

--[[
	Full cleanup: stop update loop, destroy all bacons, and destroy fly ScreenGui.
]]
function BaconCollectible.destroy()
	BaconCollectible.stop()
	BaconCollectible.clear()
	getGameSpeedScaleFn = nil
	if flyScreenGui then
		flyScreenGui:Destroy()
		flyScreenGui = nil
	end
end

return BaconCollectible
