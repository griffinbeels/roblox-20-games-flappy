--[[
	ReadyUI.luau
	
	Displays "Press Space to Jump" message when player is ready to start.
]]

local Players = game:GetService("Players")

local ReadyUI = {}
ReadyUI.__index = ReadyUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local messageLabel = nil

--[[
	Initializes the ReadyUI.
]]
function ReadyUI.init()
	-- Create ScreenGui (hidden by default)
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ReadyUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	-- Create message label
	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "ReadyMessage"
	messageLabel.Size = UDim2.new(0, 400, 0, 100)
	messageLabel.Position = UDim2.new(0.5, -200, 0.6, 0)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = "Press SPACE to Start"
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.TextSize = 36
	messageLabel.Font = Enum.Font.GothamBold
	messageLabel.TextStrokeTransparency = 0.5
	messageLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	messageLabel.Parent = screenGui
	
	-- Create subtitle
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(0, 400, 0, 40)
	subtitle.Position = UDim2.new(0.5, -200, 0.6, 80)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Jump to stay in the air!"
	subtitle.TextColor3 = Color3.new(0.8, 0.8, 0.8)
	subtitle.TextSize = 20
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextStrokeTransparency = 0.7
	subtitle.TextStrokeColor3 = Color3.new(0, 0, 0)
	subtitle.Parent = screenGui
end

--[[
	Shows the ready UI.
]]
function ReadyUI.show()
	if screenGui then
		screenGui.Enabled = true
	end
end

--[[
	Hides the ready UI.
]]
function ReadyUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	Cleans up the ReadyUI.
]]
function ReadyUI.destroy()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return ReadyUI
