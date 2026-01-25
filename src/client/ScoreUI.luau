--[[
	ScoreUI.luau
	
	Creates and manages the score display UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScoreManager = require(script.Parent.ScoreManager)

local ScoreUI = {}
ScoreUI.__index = ScoreUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local scoreLabel = nil
local bestLabel = nil
local updateConnection = nil

--[[
	Initializes the ScoreUI.
]]
function ScoreUI.init()
	-- Create ScreenGui (hidden by default)
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ScoreUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false -- Start hidden
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	-- Create score label
	scoreLabel = Instance.new("TextLabel")
	scoreLabel.Name = "ScoreLabel"
	scoreLabel.Size = UDim2.new(0, 200, 0, 50)
	scoreLabel.Position = UDim2.new(0.5, -100, 0, 20)
	scoreLabel.BackgroundTransparency = 1
	scoreLabel.Text = "Score: 0"
	scoreLabel.TextColor3 = Color3.new(1, 1, 1)
	scoreLabel.TextSize = 24
	scoreLabel.Font = Enum.Font.GothamBold
	scoreLabel.Parent = screenGui
	
	-- Create personal best label
	bestLabel = Instance.new("TextLabel")
	bestLabel.Name = "BestLabel"
	bestLabel.Size = UDim2.new(0, 200, 0, 30)
	bestLabel.Position = UDim2.new(0.5, -100, 0, 70)
	bestLabel.BackgroundTransparency = 1
	bestLabel.Text = "Best: 0"
	bestLabel.TextColor3 = Color3.new(0.8, 0.8, 0.8)
	bestLabel.TextSize = 18
	bestLabel.Font = Enum.Font.Gotham
	bestLabel.Parent = screenGui
end

--[[
	Starts updating the score display.
]]
function ScoreUI.start()
	if updateConnection then
		return
	end
	
	local RunService = game:GetService("RunService")
	updateConnection = RunService.Heartbeat:Connect(function()
		if scoreLabel then
			scoreLabel.Text = "Score: " .. ScoreManager.getScore()
		end
		if bestLabel then
			local best = ScoreManager.getPersonalBest()
			if best > 0 then
				bestLabel.Text = "Best: " .. best
			else
				bestLabel.Text = ""
			end
		end
	end)
end

--[[
	Stops updating the score display.
]]
function ScoreUI.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Shows the score UI.
]]
function ScoreUI.show()
	if screenGui then
		screenGui.Enabled = true
	end
end

--[[
	Hides the score UI.
]]
function ScoreUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	Cleans up the ScoreUI.
]]
function ScoreUI.destroy()
	ScoreUI.stop()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return ScoreUI
