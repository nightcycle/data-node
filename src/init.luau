--!strict

local _Package = script
local _Packages = _Package.Parent
-- Services
local Players = game:GetService("Players")

-- Packages
local ServiceProxy = require(_Packages:WaitForChild("ServiceProxy"))
local Maid = require(_Packages:WaitForChild("Maid"))
local TableUtil = require(_Packages:WaitForChild("TableUtil"))
local Signal = require(_Packages:WaitForChild("Signal"))

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
type NodeInvokeProcessor<V> = (userId: number, value: V) -> ()
type NodeHandlerData<V, N> = {
	Constructor: <V>(userId: number, skipRegistration: boolean) -> N,
	InvokeProcessors: {
		OnLoaded: NodeInvokeProcessor<V>,
		OnChanged: NodeInvokeProcessor<V>,
	},
}
type RegularNodeHandlerData<V> = NodeHandlerData<V, DataNode<V>>
type OrderedNodeHandlerData = NodeHandlerData<number, OrderedDataNode>
export type DataNodeService = {
	__index: DataNodeService,
	_Maid: Maid,
	_IsAlive: boolean,
	_NodeHandlers: { [string]: RegularNodeHandlerData<unknown> },
	_OrderedNodeHandlers: { [string]: OrderedNodeHandlerData },

	_Nodes: { [number]: { [string]: DataNode<any> }? },
	_OrderedNodes: { [number]: { [string]: OrderedDataNode }? },
	_OnAllDataLoadedInvoke: (userId: number) -> (),

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

	SetOnDataChangedInvoke: <V>(self: DataNodeService, path: string, onInvoke: NodeInvokeProcessor<V>) -> (),
	SetOnDataLoadedInvoke: <V>(self: DataNodeService, path: string, onInvoke: NodeInvokeProcessor<V>) -> (),

	SetOnAllDataLoadedInvoke: (self: DataNodeService, onInvoke: (userId: number) -> ()) -> (),
	GetIfAllDataLoaded: (self: DataNodeService, userId: number) -> boolean,

	ConstructDataNode: <V>(self: DataNodeService, userId: number, path: string) -> DataNode<V>,
	ConstructOrderedDataNode: (self: DataNodeService, userId: number, path: string) -> OrderedDataNode,

	GetDataNode: <V>(self: DataNodeService, userId: number, path: string) -> DataNode<V>,
	GetOrderedDataNode: (self: DataNodeService, userId: number, path: string) -> OrderedDataNode,

	GetData: <V>(self: DataNodeService, userId: number, path: string, force: boolean) -> V?,
	GetOrderedData: (self: DataNodeService, userId: number, path: string, force: boolean) -> number?,

	_RegisterUser: (self: DataNodeService, userId: number) -> (),
	_DeregisterUser: (self: DataNodeService, userId: number) -> (),

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

function DataNodeService:SetOnDataChangedInvoke<V>(path: string, onInvoke: NodeInvokeProcessor<V>): ()
	if self._NodeHandlers[path] then
		self._NodeHandlers[path].InvokeProcessors.OnChanged = onInvoke :: NodeInvokeProcessor<any>
	elseif self._OrderedNodeHandlers[path] then
		self._OrderedNodeHandlers[path].InvokeProcessors.OnChanged = onInvoke :: NodeInvokeProcessor<any>
	end
end

function DataNodeService:SetOnDataLoadedInvoke<V>(path: string, onInvoke: NodeInvokeProcessor<V>): ()
	if self._NodeHandlers[path] then
		self._NodeHandlers[path].InvokeProcessors.OnLoaded = onInvoke :: NodeInvokeProcessor<any>
	elseif self._OrderedNodeHandlers[path] then
		self._OrderedNodeHandlers[path].InvokeProcessors.OnLoaded = onInvoke :: NodeInvokeProcessor<any>
	end
end

function DataNodeService:SetOnAllDataLoadedInvoke(onInvoke: (userId: number) -> ()): ()
	self._OnAllDataLoadedInvoke = onInvoke
end

function DataNodeService:GetIfAllDataLoaded(userId: number): boolean
	for path, handler in pairs(self._NodeHandlers) do
		local node = self:GetDataNode(userId, path)
		if not node then
			return false
		end
		assert(node)
		if not node.IsLoaded then
			return false
		end
	end

	for path, handler in pairs(self._OrderedNodeHandlers) do
		local node = self:GetOrderedDataNode(userId, path)
		if not node then
			return false
		end
		assert(node)
		if not node.IsLoaded then
			return false
		end
	end

	return true
end

function DataNodeService:RegisterDataNode<V>(
	path: string,
	initialValue: V,
	getMetadata: ((userId: number) -> { [any]: any })?,
	serializer: Serializer<V>?,
	deserializer: Deserializer<V>?
): ()
	assert(self._NodeHandlers[path] == nil and self._OrderedNodeHandlers[path] == nil, `path already registered: {path}`)

	local onLoaded = self._Maid:GiveTask(Signal.new())
	local onChanged = self._Maid:GiveTask(Signal.new())

	local handler: NodeHandlerData<V, DataNode<V>> = {
		Constructor = function(userId: number, skipRegistration: boolean): DataNode<V>
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
				local nodes = (self._Nodes[userId] or {}) :: { [string]: DataNode<V> }
				nodes[path] = node
				self._Nodes[userId] = nodes
				local player = Players:GetPlayerByUserId(userId)
				if player then
					local playerMaid = self._Maid:GiveTask(Maid.new())

					if node.IsLoaded then
						onLoaded:Fire(userId, node:Get(false))
					else
						playerMaid:GiveTask(node.OnLoadComplete:Connect(function()
							onLoaded:Fire(userId, node:Get(false))
						end))
					end

					playerMaid:GiveTask(node.OnChanged:Connect(function()
						onChanged:Fire(userId, node:Get(false))
					end))
					onChanged:Fire(userId, node:Get(false))

					playerMaid.bind(player)
				end
			end
			return node
		end,
		InvokeProcessors = {
			OnLoaded = function() end,
			OnChanged = function() end,
		},
	}

	self._NodeHandlers[path] = handler :: any

	self._Maid:GiveTask(onLoaded:Connect(function(userId: number, value: V)
		handler.InvokeProcessors.OnLoaded(userId, value)
		if self:GetIfAllDataLoaded(userId) then
			self._OnAllDataLoadedInvoke(userId)
		end
	end))

	self._Maid:GiveTask(onChanged:Connect(function(userId: number, value: V)
		handler.InvokeProcessors.OnChanged(userId, value)
	end))

	for userId, _ in pairs(self._Nodes) do
		self._NodeHandlers[path].Constructor(userId, false)
	end
end

function DataNodeService:RegisterOrderedDataNode(path: string, initialValue: number, getMetadata: ((userId: number) -> { [any]: any })?): ()
	assert(self._NodeHandlers[path] == nil and self._OrderedNodeHandlers[path] == nil, `path already registered: {path}`)

	local onLoaded = self._Maid:GiveTask(Signal.new())
	local onChanged = self._Maid:GiveTask(Signal.new())

	local handler: OrderedNodeHandlerData = {
		Constructor = function(userId: number, skipRegistration: boolean): OrderedDataNode
			local node = self._Maid:GiveTask(OrderedDataNode.new(userId, self.OrderedDataStoreName, path, initialValue, getMetadata))

			if not skipRegistration then
				local orderedNodes = (self._OrderedNodes[userId] or {}) :: { [string]: OrderedDataNode }
				orderedNodes[path] = node
				self._OrderedNodes[userId] = orderedNodes

				local player = Players:GetPlayerByUserId(userId)
				if player then
					local playerMaid = self._Maid:GiveTask(Maid.new())

					if node.IsLoaded then
						onLoaded:Fire(userId, node:Get(false))
					else
						playerMaid:GiveTask(node.OnLoadComplete:Connect(function()
							onLoaded:Fire(userId, node:Get(false))
						end))
					end

					playerMaid:GiveTask(node.OnChanged:Connect(function()
						onChanged:Fire(userId, node:Get(false))
					end))
					onChanged:Fire(userId, node:Get(false))

					playerMaid.bind(player)
				end
			end
			return node
		end,
		InvokeProcessors = {
			OnLoaded = function() end,
			OnChanged = function() end,
		},
	}
	self._OrderedNodeHandlers[path] = handler

	self._Maid:GiveTask(onLoaded:Connect(function(userId: number, value: any)
		handler.InvokeProcessors.OnLoaded(userId, value)
		if self:GetIfAllDataLoaded(userId) then
			self._OnAllDataLoadedInvoke(userId)
		end
	end))

	self._Maid:GiveTask(onChanged:Connect(function(userId: number, value: any)
		handler.InvokeProcessors.OnChanged(userId, value)
	end))

	for userId, _ in pairs(self._OrderedNodes) do
		self._OrderedNodeHandlers[path].Constructor(userId, false)
	end
end

function DataNodeService:ConstructDataNode<V>(userId: number, path: string)
	return self._NodeHandlers[path].Constructor(userId, true) :: any
end

function DataNodeService:ConstructOrderedDataNode(userId: number, path: string)
	return self._OrderedNodeHandlers[path].Constructor(userId, true)
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

function DataNodeService:_RegisterUser(userId: number)
	assert(self._Nodes[userId] == nil, `userId is already registered {userId}`)
	assert(self._OrderedNodes[userId] == nil, `userId is already registered {userId}`)

	self._Nodes[userId] = {}
	self._OrderedNodes[userId] = {}
	for path, handler in pairs(self._NodeHandlers) do
		handler.Constructor(userId, false)
	end
	for path, handler in pairs(self._OrderedNodeHandlers) do
		handler.Constructor(userId, false)
	end
end

function DataNodeService:_DeregisterUser(userId: number)
	for path, node in pairs(self._Nodes[userId] or {}) do
		node:Destroy()
	end
	for path, node in pairs(self._OrderedNodes[userId] or {}) do
		node:Destroy()
	end
	self._Nodes[userId] = nil
	self._OrderedNodes[userId] = nil
end

function DataNodeService:GetData<V>(userId: number, path: string, force: boolean): V?
	local node: DataNode<V> = self:GetDataNode(userId, path)
	return node:Get(force)
end

function DataNodeService:GetOrderedData(userId: number, path: string, force: boolean): number?
	local node: OrderedDataNode = self:GetOrderedDataNode(userId, path)
	return node:Get(force)
end

function DataNodeService.new()
	local self: DataNodeService = setmetatable({}, DataNodeService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._OrderedNodeHandlers = {}
	self._NodeHandlers = {}
	self._Nodes = {}
	self._OrderedNodes = {}
	self._OnAllDataLoadedInvoke = function() end
	self.DataStoreName = "DataNode"
	self.OrderedDataStoreName = "OrderedDataNode"

	self._Maid:GiveTask(Players.PlayerAdded:Connect(function(player: Player)
		self:_RegisterUser(player.UserId)
	end))
	self._Maid:GiveTask(Players.PlayerRemoving:Connect(function(player: Player)
		self:_DeregisterUser(player.UserId)
	end))
	self._Maid:GiveTask(game.Close:Connect(function()
		for i, player in ipairs(Players:GetPlayers()) do
			self:_DeregisterUser(player.UserId)
		end
	end))
	for i, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_RegisterUser(player.UserId)
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
