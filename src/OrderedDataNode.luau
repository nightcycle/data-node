
--!strict
local _Package = script.Parent
local _Packages = _Package.Parent
-- Services
local DataStoreService = require(_Packages:WaitForChild("MockDataStoreService")) :: DataStoreService
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
	Increment: (self: OrderedDataNode, delta: number, force: boolean?) -> (number?, boolean),
	new: (
		player: Player, 
		scope: string, 
		initialValue: number, 
		getMetadata: ((player: Player) -> {[any]: any})?
	) -> OrderedDataNode,
	GetSortedList: (self: OrderedDataNode, limit: number, isAscending: boolean) -> { [number]: SortedDataEntry },
}

-- Constants
local PAGE_LENGTH = 100
local HUGE = 2^62

-- Variables
-- References
-- Private Functions
-- Class

local OrderedDataNode = {} :: OrderedDataNode
OrderedDataNode.__index = OrderedDataNode :: any
setmetatable(OrderedDataNode, DataNode)

-- @TODO
function OrderedDataNode:GetSortedList(limit: number, isAscending: boolean)
	local pages = self.DataStore:GetSortedAsync(isAscending, PAGE_LENGTH, -HUGE, HUGE)
	
	local list: { [number]: SortedDataEntry } = {}
	local function dumpPages()
		local page = pages:GetCurrentPage()
		
		for rank: number, data in ipairs(page) do
			if #list >= limit then
				break
			end
			local key = data.key
			local value = data.value
			table.insert(list, {
				UserId = tonumber(key) :: number,
				Value = value,
			})
		end
		
		local success
		local attempts = 0
		repeat
			success = pcall(function() end)
			attempts += 1
			if not success then
				task.wait(DataNode.RETRY_DELAY)
			end
		until success or attempts > DataNode.RETRY_LIMIT
		
		if success and #list < limit then
			pages:AdvanceToNextPageAsync()
			dumpPages()
		end
	end
	dumpPages()
	
	return list
end

function OrderedDataNode:Increment(delta: number, force: boolean?)
	local metadata = if self._GetMetaData then self._GetMetaData() else nil

	if metadata then
		self.IncrementOptions:SetMetadata(metadata)
	else
		self.IncrementOptions:SetMetadata({})
	end
	

	local function increment()
		local value = self._Value
		local success, msg = pcall(function()
			local val = self.DataStore:IncrementAsync(self.Key, delta, { self.Player.UserId }, self.IncrementOptions)
			value = val
			return val
		end)
		if not success then
			warn(msg)
		end
		return value, success
	end
	
	local value, success
	
	if force then
		local attempts = 0
		repeat
			attempts += 1
			value, success = increment()
			if not success then
				task.wait(DataNode.RETRY_DELAY)
			end
		until success or attempts > DataNode.RETRY_LIMIT
		if success then
			self._Value = value
		end
	else
		local val: number? = self._Value
		if val then
			val += delta
			self._Value = val
		end

		success = true
	end
	
	if success and delta ~= 0 then
		self.OnChanged:Fire(self._Value)
	end
	
	return self._Value, success
end

function OrderedDataNode.new(
	player: Player, 
	scope: string, 
	initialValue: number,
	getMetadata: ((player: Player) -> {[any]: any})?
): OrderedDataNode
	local self: OrderedDataNode = setmetatable(DataNode.new(player, scope, initialValue, getMetadata), OrderedDataNode) :: any
	
	self.DataStore = DataStoreService:GetOrderedDataStore(DataNode.BASE_DOMAIN, scope)
	local incrementOptions = Instance.new("DataStoreIncrementOptions")
	self._Maid:GiveTask(incrementOptions)
	self.IncrementOptions = incrementOptions
	
	return self
end

return OrderedDataNode
