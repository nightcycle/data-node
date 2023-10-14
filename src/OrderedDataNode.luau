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
	_Value: number,
	Increment: (self: OrderedDataNode, delta: number) -> number,
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

function OrderedDataNode:Increment(delta: number)
	local metadata = if self._GetMetaData then self._GetMetaData() else nil

	if metadata then
		self.IncrementOptions:SetMetadata(metadata)
	else
		self.IncrementOptions:SetMetadata({})
	end

	local value: number

	RateService:Transform(function(): (boolean, number, number)
		value = self.DataStore:IncrementAsync(self.Key, delta, { self._UserId }, self.IncrementOptions)
		return true, 16, 16
	end)

	if value then
		self._Value = value
		if delta ~= 0 then
			self.OnChanged:Fire(self._Value)
		end
	end
	return self._Value
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

	return self
end

return OrderedDataNode
