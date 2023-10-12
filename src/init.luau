--!strict
local _Package = script
local _Packages = _Package.Parent
-- Services
local Players = game:GetService("Players")

-- Packages
local ServiceProxy = require(_Packages:WaitForChild("ServiceProxy"))
local Maid = require(_Packages:WaitForChild("Maid"))
local TableUtil = require(_Packages:WaitForChild("TableUtil"))

-- Modules
local DataNode = require(_Package:WaitForChild("DataNode"))
local OrderedDataNode = require(_Package:WaitForChild("OrderedDataNode"))
local RateService = require(_Package:WaitForChild("RateService"))

-- Types
type Maid = Maid.Maid
export type DataNode<V> = DataNode.DataNode<V>
export type OrderedDataNode = OrderedDataNode.OrderedDataNode
export type Serializer<V> = DataNode.Serializer<V>
export type Deserializer<V> = DataNode.Deserializer<V>
export type DataNodeService = {
	__index: DataNodeService,
	_Maid: Maid,
	_IsAlive: boolean,
	_NodeConstructors: { [string]: <V>(userId: number, skipRegistration: boolean) -> DataNode<V>},
	_OrderedNodeConstructors: { [string]: (userId: number, skipRegistration: boolean) -> OrderedDataNode },
	_Nodes: { [number]: { [string]: DataNode<any> } },
	_OrderedNodes: { [number]: { [string]: OrderedDataNode } },

	DataStoreName: string,
	OrderedDataStoreName: string,

	RegisterDataNode: <V>(
		self: DataNodeService,
		path: string,
		initialValue: V,
		getMetadata: ((userId: number) -> { [any]: any })?,
		serializer: Serializer<V>?,
		deserializer: Deserializer<V>?
	) -> (),
	RegisterOrderedDataNode: (self: DataNodeService, path: string, initialValue: number, getMetadata: ((userId: number) -> { [any]: any })?) -> (),

	BorrowDataNode: <V>(self: DataNodeService, userId: number, path: string, processor: ((node: DataNode<V>) -> DataNode<V>)) -> (),
	BorrowOrderedDataNode: (self: DataNodeService, userId: number, path: string,  processor: ((node: OrderedDataNode) -> OrderedDataNode)) -> (),

	GetDataNode: <V>(self: DataNodeService, userId: number, path: string) -> DataNode<V>,
	GetOrderedDataNode: (self: DataNodeService, userId: number, path: string) -> OrderedDataNode,

	GetData: <V>(self: DataNodeService, userId: number, path: string, force: boolean) -> V,
	GetOrderedData: (self: DataNodeService, userId: number, path: string, force: boolean) -> number,

	RegisterUser: (self: DataNodeService, userId: number) -> (),
	DeregisterUser: (self: DataNodeService, userId: number) -> (),

	Destroy: (self: DataNodeService) -> (),
	new: () -> DataNodeService,
	init: (maid: Maid) -> nil,
}

-- Constants
-- Variables
-- References
-- Private Functions
-- Class
-- Types

-- Class
local CurrentDataNodeService: DataNodeService = nil :: any
local DataNodeService = {} :: DataNodeService
DataNodeService.__index = DataNodeService

function DataNodeService:Destroy()
	if not self._IsAlive then
		return
	end
	self._IsAlive = false
	if CurrentDataNodeService == self then
		CurrentDataNodeService = nil :: any
	end
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
end

function DataNodeService:RegisterDataNode<V>(
	path: string,
	initialValue: V,
	getMetadata: ((userId: number) -> { [any]: any })?,
	serializer: Serializer<V>?,
	deserializer: Deserializer<V>?
): ()
	self._NodeConstructors[path] = function<G>(userId: number, skipRegistration: boolean): DataNode<G>
		local node = self._Maid:GiveTask(
			DataNode.new(
				userId,
				self.DataStoreName,
				path,
				if type(initialValue) == "table" then TableUtil.deepCopy(initialValue) else initialValue,
				getMetadata,
				serializer,
				deserializer
			)
		)
		if not skipRegistration then
			self._Nodes[userId] = self._Nodes[userId] or {}
			self._Nodes[userId][path] = node
		end
		return node
	end
	for userId, _ in pairs(self._Nodes) do
		self._NodeConstructors[path](userId, false)
	end
end

function DataNodeService:RegisterOrderedDataNode(path: string, initialValue: number, getMetadata: ((userId: number) -> { [any]: any })?): ()
	self._OrderedNodeConstructors[path] = function(userId: number, skipRegistration: boolean): OrderedDataNode
		local node = self._Maid:GiveTask(OrderedDataNode.new(userId, self.OrderedDataStoreName, path, initialValue, getMetadata))
	
		if not skipRegistration then
			self._OrderedNodes[userId] = self._OrderedNodes[userId] or {}
			self._OrderedNodes[userId][path] = node
		end
		return node
	end
	for userId, _ in pairs(self._OrderedNodes) do
		self._OrderedNodeConstructors[path](userId, false)
	end
end

function DataNodeService:BorrowDataNode<V>(userId: number, path: string, processor: ((node: DataNode<V>) -> DataNode<V>))
	local node = self._NodeConstructors[path](userId, true)
	processor(node)
	node:Destroy()
end

function DataNodeService:BorrowOrderedDataNode(userId: number, path: string, processor: ((node: OrderedDataNode) -> OrderedDataNode))
	local node = self._OrderedNodeConstructors[path](userId, true)
	processor(node)
	node:Destroy()
end

function DataNodeService:GetDataNode<V>(userId: number, path: string): DataNode<V>
	local playerNodes = self._Nodes[userId]
	assert(playerNodes, `player is not registered: {userId}`)
	local node = playerNodes[path]
	assert(node, `missing node for player {userId} at path {path}`)
	return node
end

function DataNodeService:GetOrderedDataNode(userId: number, path: string): OrderedDataNode
	local playerNodes = self._OrderedNodes[userId]
	assert(playerNodes, `player is not registered: {userId}`)
	local node = playerNodes[path]
	assert(node, `missing ordered node for player {userId} at path {path}`)
	return node
end

function DataNodeService:RegisterUser(userId: number)
	assert(self._Nodes[userId] == nil, `userId is already registered {userId}`)
	assert(self._OrderedNodes[userId] == nil, `userId is already registered {userId}`)

	self._Nodes[userId] = {}
	self._OrderedNodes[userId] = {}
	for path, constructor in pairs(self._NodeConstructors) do
		constructor(userId, false)
	end
	for path, constructor in pairs(self._OrderedNodeConstructors) do
		constructor(userId, false)
	end
end

function DataNodeService:DeregisterUser(userId: number)
	for path, node in pairs(self._Nodes[userId] or {}) do
		node:Destroy()
	end
	for path, node in pairs(self._OrderedNodes[userId] or {}) do
		node:Destroy()
	end
	self._Nodes[userId] = nil
	self._OrderedNodes[userId] = nil
end

function DataNodeService:GetData<V>(userId: number, path: string, force: boolean): V
	local node: DataNode<V> = self:GetDataNode(userId, path)
	return node:Get()
end

function DataNodeService:GetOrderedData(userId: number, path: string, force: boolean): number
	local node: OrderedDataNode = self:GetOrderedDataNode(userId, path)
	return node:Get()
end

function DataNodeService.new()
	local self: DataNodeService = setmetatable({}, DataNodeService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._NodeConstructors = {}
	self._OrderedNodeConstructors = {}
	self._Nodes = {}
	self._OrderedNodes = {}

	self.DataStoreName = "DataNode"
	self.OrderedDataStoreName = "OrderedDataNode"

	self._Maid:GiveTask(Players.PlayerAdded:Connect(function(player: Player)
		self:RegisterUser(player.UserId)
	end))
	self._Maid:GiveTask(Players.PlayerRemoving:Connect(function(player: Player)
		self:DeregisterUser(player.UserId)
	end))
	self._Maid:GiveTask(game.Close:Connect(function()
		for i, player in ipairs(Players:GetPlayers()) do
			self:DeregisterUser(player.UserId)
		end
	end))
	for i, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:RegisterUser(player.UserId)
		end)
	end

	if CurrentDataNodeService ~= nil then
		CurrentDataNodeService:Destroy()
		CurrentDataNodeService = nil :: any
	end
	CurrentDataNodeService = self

	return self
end

function DataNodeService.init(maid: Maid)
	maid:GiveTask(RateService.new())
	maid:GiveTask(DataNodeService.new())
	return nil
end

return ServiceProxy(function()
	return CurrentDataNodeService or DataNodeService
end)
