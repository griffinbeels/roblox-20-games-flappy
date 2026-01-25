--[[
	GameOverUI.luau
	
	Creates and manages the game over screen UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameOverUI = {}
GameOverUI.__index = GameOverUI

local localPlayer = Players.LocalPlayer
local screenGui = nil
local frame = nil
local scoreLabel = nil
local bestLabel = nil
local leaderboardLabel = nil
local playAgainLabel = nil
local returnToHubLabel = nil

--[[
	Initializes the GameOverUI.
]]
function GameOverUI.init()
	-- Create ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GameOverUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	-- Create main frame
	frame = Instance.new("Frame")
	frame.Name = "GameOverFrame"
	frame.Size = UDim2.new(0, 400, 0, 500)
	frame.Position = UDim2.new(0.5, -200, 0.5, -250)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	frame.BorderSizePixel = 2
	frame.BorderColor3 = Color3.fromRGB(255, 255, 255)
	frame.Parent = screenGui
	
	-- Create title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 60)
	title.Position = UDim2.new(0, 0, 0, 20)
	title.BackgroundTransparency = 1
	title.Text = "Game Over"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextSize = 36
	title.Font = Enum.Font.GothamBold
	title.Parent = frame
	
	-- Create score label
	scoreLabel = Instance.new("TextLabel")
	scoreLabel.Name = "ScoreLabel"
	scoreLabel.Size = UDim2.new(1, -40, 0, 40)
	scoreLabel.Position = UDim2.new(0, 20, 0, 100)
	scoreLabel.BackgroundTransparency = 1
	scoreLabel.Text = "Score: 0"
	scoreLabel.TextColor3 = Color3.new(1, 1, 1)
	scoreLabel.TextSize = 24
	scoreLabel.Font = Enum.Font.Gotham
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Left
	scoreLabel.Parent = frame
	
	-- Create best label
	bestLabel = Instance.new("TextLabel")
	bestLabel.Name = "BestLabel"
	bestLabel.Size = UDim2.new(1, -40, 0, 40)
	bestLabel.Position = UDim2.new(0, 20, 0, 150)
	bestLabel.BackgroundTransparency = 1
	bestLabel.Text = "Best: 0"
	bestLabel.TextColor3 = Color3.new(0.8, 0.8, 0.8)
	bestLabel.TextSize = 20
	bestLabel.Font = Enum.Font.Gotham
	bestLabel.TextXAlignment = Enum.TextXAlignment.Left
	bestLabel.Parent = frame
	
	-- Create leaderboard label
	leaderboardLabel = Instance.new("TextLabel")
	leaderboardLabel.Name = "LeaderboardLabel"
	leaderboardLabel.Size = UDim2.new(1, -40, 0, 200)
	leaderboardLabel.Position = UDim2.new(0, 20, 0, 210)
	leaderboardLabel.BackgroundTransparency = 1
	leaderboardLabel.Text = "Loading leaderboard..."
	leaderboardLabel.TextColor3 = Color3.new(0.9, 0.9, 0.9)
	leaderboardLabel.TextSize = 16
	leaderboardLabel.Font = Enum.Font.Gotham
	leaderboardLabel.TextXAlignment = Enum.TextXAlignment.Left
	leaderboardLabel.TextYAlignment = Enum.TextYAlignment.Top
	leaderboardLabel.TextWrapped = true
	leaderboardLabel.Parent = frame
	
	-- Create play again label
	playAgainLabel = Instance.new("TextLabel")
	playAgainLabel.Name = "PlayAgainLabel"
	playAgainLabel.Size = UDim2.new(1, -40, 0, 40)
	playAgainLabel.Position = UDim2.new(0, 20, 1, -110)
	playAgainLabel.BackgroundColor3 = Color3.fromRGB(0, 150, 0)
	playAgainLabel.BorderSizePixel = 0
	playAgainLabel.Text = "Press E to Play Again"
	playAgainLabel.TextColor3 = Color3.new(1, 1, 1)
	playAgainLabel.TextSize = 18
	playAgainLabel.Font = Enum.Font.GothamBold
	playAgainLabel.Parent = frame
	
	-- Create return to hub label
	returnToHubLabel = Instance.new("TextLabel")
	returnToHubLabel.Name = "ReturnToHubLabel"
	returnToHubLabel.Size = UDim2.new(1, -40, 0, 40)
	returnToHubLabel.Position = UDim2.new(0, 20, 1, -60)
	returnToHubLabel.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
	returnToHubLabel.BorderSizePixel = 0
	returnToHubLabel.Text = "Press R to Return to Hub"
	returnToHubLabel.TextColor3 = Color3.new(1, 1, 1)
	returnToHubLabel.TextSize = 18
	returnToHubLabel.Font = Enum.Font.GothamBold
	returnToHubLabel.Parent = frame
end

--[[
	Shows the game over screen.
	@param score number - Final score
	@param personalBest number - Personal best score
]]
function GameOverUI.show(score, personalBest)
	if not screenGui then
		GameOverUI.init()
	end
	
	scoreLabel.Text = "Score: " .. (score or 0)
	if personalBest and personalBest > 0 then
		bestLabel.Text = "Best: " .. personalBest
	else
		bestLabel.Text = "Best: --"
	end
	
	-- Request leaderboard
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remoteFolder then
		local getLeaderboardRemote = remoteFolder:FindFirstChild("GetLeaderboard")
		if getLeaderboardRemote then
			getLeaderboardRemote:FireServer(10)
			getLeaderboardRemote.OnClientEvent:Connect(function(topPlayers)
				local leaderboardText = "Top Players:\n"
				for i, entry in ipairs(topPlayers) do
					local playerName = "Player " .. entry.userId
					local player = game.Players:GetPlayerByUserId(entry.userId)
					if player then
						playerName = player.Name
					end
					leaderboardText = leaderboardText .. i .. ". " .. playerName .. " - " .. entry.score .. "\n"
				end
				if #topPlayers == 0 then
					leaderboardText = "No scores yet!"
				end
				leaderboardLabel.Text = leaderboardText
			end)
		end
	end
	
	screenGui.Enabled = true
end

--[[
	Hides the game over screen.
]]
function GameOverUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	Cleans up the GameOverUI.
]]
function GameOverUI.destroy()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return GameOverUI
