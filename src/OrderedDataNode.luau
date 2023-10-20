--!strict
local _Package = script.Parent
local _Packages = _Package.Parent
-- Services
local DataStoreService = require(_Packages:WaitForChild("MockDataStoreService")) :: DataStoreService
local RateService = require(_Package:WaitForChild("RateService"))

-- Packages
-- Modules
local DataNode = require(_Package:WaitForChild("DataNode"))
-- Types
export type SortedDataEntry = {
	UserId: number,
	Value: number,
}
type Processor<V> = (val: V) -> V
export type OrderedDataNode = DataNode.BaseDataNode<number> & {
	ClassName: "OrderedDataNode",
	DataStore: OrderedDataStore,
	IncrementOptions: DataStoreIncrementOptions,
	_Value: number?,
	Increment: (self: OrderedDataNode, delta: number, yield: boolean) -> number?,
	new: (userId: number, domain: string, scope: string, initialValue: number, getMetadata: ((userId: number) -> { [any]: any })?) -> OrderedDataNode,
}

-- Constants

-- Variables
-- References
-- Private Functions
-- Class

local OrderedDataNode = {} :: OrderedDataNode
OrderedDataNode.__index = OrderedDataNode :: any
setmetatable(OrderedDataNode, DataNode)

function OrderedDataNode:Increment(delta: number, yield: boolean): number?
	if not self.IsLoaded then
		self.OnLoadComplete:Wait()
	end

	local value: number?
	local wasRun: boolean
	local success: boolean, errorMessage: string?

	local function run()
		do
			local metadata = if self._GetMetaData then self._GetMetaData() else nil

			if metadata then
				self.IncrementOptions:SetMetadata(metadata)
			else
				self.IncrementOptions:SetMetadata({})
			end
		end

		local runResult = RateService:Transform(
			`{self._Domain}/{self._Scope}`,
			self.Key,
			function(): (boolean, number, number)
				local runValue: number?
				success, errorMessage = pcall(function()
					assert(self._IsAlive, `increment failed: node {self._Scope} for user {self._UserId} is dead`)
					runValue = self.DataStore:IncrementAsync(self.Key, delta, { self._UserId }, self.IncrementOptions)
				end)
				if not success then
					if errorMessage then
						warn(errorMessage)
					end
				end
				if yield then
					value = runValue
				end
				return success, 16, 16
			end,
			yield
		)
		if yield then
			wasRun = runResult
		end
	end
	local initialValue = self._EncodedValue
	assert(type(initialValue) == "number")
	
	if yield then
		run()
	else
		task.spawn(run)
		if initialValue then
			value = initialValue + delta
		end
		wasRun = true
		success = true
	end

	if wasRun then
		assert(success, errorMessage)

		self._EncodedValue = value
		self._Value = value
	
		if delta ~= 0 then
			self.OnChanged:Fire(value)
		end
	
		return value
	end

	return nil
end

function OrderedDataNode.new(
	userId: number,
	domain: string,
	scope: string,
	initialValue: number,
	getMetadata: ((userId: number) -> { [any]: any })?
): OrderedDataNode
	local base = DataNode.new(userId, domain, scope, initialValue, getMetadata)

	local self: OrderedDataNode = setmetatable(base, OrderedDataNode) :: any

	self._Domain = domain
	self._Scope = scope

	self.DataStore = DataStoreService:GetOrderedDataStore(self._Domain, self._Scope)
	self.IncrementOptions = self._Maid:GiveTask(Instance.new("DataStoreIncrementOptions"))

	task.spawn(function()
		self:_Load()
	end)

	return self
end

return OrderedDataNode
