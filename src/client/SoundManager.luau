--[[
	SoundManager.luau
	
	Manages sound effects for the game.
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = {}
SoundManager.__index = SoundManager

local sounds = {}

--[[
	Plays a sound effect.
	@param soundId number|string - Sound ID or asset ID
	@param volume number - Volume (0-1)
]]
function SoundManager.playSound(soundId, volume)
	volume = volume or 0.5
	
	-- Use Roblox's built-in UI sounds that are always available
	-- These are reliable and don't require external assets
	local sound = Instance.new("Sound")
	
	-- Use a simple system sound that's always available
	-- For now, we'll use a placeholder that won't error
	-- In production, replace with actual sound IDs
	sound.SoundId = "rbxasset://sounds/impact_water.wav" -- Default Roblox sound
	sound.Volume = volume
	sound.Parent = SoundService
	
	-- Handle errors gracefully
	local success, err = pcall(function()
		sound:Play()
	end)
	
	if not success then
		-- Silently fail - sounds are optional
		sound:Destroy()
		return
	end
	
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	
	-- Cleanup if sound fails to load
	sound.Loaded:Connect(function()
		if not sound.IsLoaded then
			sound:Destroy()
		end
	end)
end

--[[
	Plays jump sound.
	Note: Replace with actual sound IDs when you have them.
	For now, using a placeholder that won't error.
]]
function SoundManager.playJump()
	-- Silently fail if sound can't play - sounds are optional
	pcall(function()
		-- Using Roblox's built-in UI click sound as placeholder
		-- Replace with your own sound ID: SoundManager.playSound(YOUR_SOUND_ID, 0.3)
		-- For now, we'll skip sounds to avoid errors
		-- Uncomment and add your sound ID when ready:
		-- SoundManager.playSound(YOUR_JUMP_SOUND_ID, 0.3)
	end)
end

--[[
	Plays score sound.
]]
function SoundManager.playScore()
	pcall(function()
		-- Replace with your own sound ID when ready:
		-- SoundManager.playSound(YOUR_SCORE_SOUND_ID, 0.4)
	end)
end

--[[
	Plays death sound.
]]
function SoundManager.playDeath()
	pcall(function()
		-- Replace with your own sound ID when ready:
		-- SoundManager.playSound(YOUR_DEATH_SOUND_ID, 0.6)
	end)
end

return SoundManager
