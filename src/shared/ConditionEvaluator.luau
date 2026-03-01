--[[
	ConditionEvaluator.luau

	Shared condition DSL evaluator used by missions, prestige unlocks, and
	other progression systems.

	Supported condition types:
	- compare: { type = "compare", path = "stats.best_score", op = ">=", value = 20 }
	- all:     { type = "all", conditions = { ... } }
	- any:     { type = "any", conditions = { ... } }
	- not:     { type = "not", condition = { ... } }
]]

local ConditionEvaluator = {}

local function readPath(root, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local node = root
	for part in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
		if node == nil then
			return nil
		end
	end

	return node
end

local function compare(left, right, op)
	if op == "==" then
		return left == right
	end
	if op == "~=" then
		return left ~= right
	end
	if op == "contains_key" then
		return type(left) == "table" and left[right] ~= nil
	end
	if op == "contains_value" then
		if type(left) ~= "table" then
			return false
		end
		for _, value in pairs(left) do
			if value == right then
				return true
			end
		end
		return false
	end

	if type(left) ~= "number" or type(right) ~= "number" then
		return false
	end

	if op == ">=" then return left >= right end
	if op == ">" then return left > right end
	if op == "<=" then return left <= right end
	if op == "<" then return left < right end
	return false
end

function ConditionEvaluator.readPath(context, path)
	return readPath(context, path)
end

function ConditionEvaluator.evaluate(condition, context)
	if type(condition) ~= "table" then
		return false
	end

	local conditionType = condition.type or "compare"

	if conditionType == "all" then
		local conditions = condition.conditions
		if type(conditions) ~= "table" then
			return false
		end
		for _, subCondition in ipairs(conditions) do
			if not ConditionEvaluator.evaluate(subCondition, context) then
				return false
			end
		end
		return true
	end

	if conditionType == "any" then
		local conditions = condition.conditions
		if type(conditions) ~= "table" then
			return false
		end
		for _, subCondition in ipairs(conditions) do
			if ConditionEvaluator.evaluate(subCondition, context) then
				return true
			end
		end
		return false
	end

	if conditionType == "not" then
		return not ConditionEvaluator.evaluate(condition.condition, context)
	end

	if conditionType == "compare" then
		local left = readPath(context, condition.path)
		if left == nil and condition.default ~= nil then
			left = condition.default
		end

		local right = condition.value
		if condition.valuePath then
			right = readPath(context, condition.valuePath)
		end

		return compare(left, right, condition.op or ">=")
	end

	return false
end

return ConditionEvaluator
