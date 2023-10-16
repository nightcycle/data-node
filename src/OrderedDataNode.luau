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
	Increment: (self: OrderedDataNode, delta: number, force: boolean) -> number?,
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

function OrderedDataNode:Increment(delta: number, force: boolean): number?
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
			function(): (boolean, number, number)
				local runValue: number?
				success, errorMessage = pcall(function()
					runValue = self.DataStore:IncrementAsync(self.Key, delta, { self._UserId }, self.IncrementOptions)
				end)
				if not success then
					if errorMessage then
						warn(errorMessage)
					end
				end
				if force then
					value = runValue
				end
				return success, 16, 16
			end,
			force
		)
		if force then
			wasRun = runResult
		end
	end
	local initialValue = self._Value

	if force then
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
