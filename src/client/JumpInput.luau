--[[
	JumpInput.luau

	Single source of truth for what constitutes a "jump" input.
]]

local UserInputService = game:GetService("UserInputService")

local JumpInput = {}

-- Returns true if the given InputObject is a jump input.
function JumpInput.isJump(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.Space
		or input.KeyCode == Enum.KeyCode.ButtonA
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Returns the display label for the jump key on the current device.
function JumpInput.getKeyLabel(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "TAP"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "A"
	end
	return "SPACE"
end

return JumpInput
