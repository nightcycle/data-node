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

-- Types
-- Constants
-- Variables
-- References
-- Private Functions
-- Class
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
	_NodeConstructors: {[string]: <V>(player: Player) -> ()},
	_OrderedNodeConstructors: {[string]: (player: Player) -> ()},
	_Nodes: {[Player]: {[string]: DataNode<any>}},
	_OrderedNodes: {[Player]: {[string]: OrderedDataNode}},

	RegisterDataNode: <V>(self: DataNodeService, path: string, initialValue: V, getMetadata: ((player: Player) -> {[any]: any})?, serializer: Serializer<V>?, deserializer: Deserializer<V>?) -> (),
	RegisterOrderedDataNode: (self: DataNodeService, path: string, initialValue: number, getMetadata: ((player: Player) -> {[any]: any})?) -> (),

	GetPlayerDataNode: <V>(self: DataNodeService, player: Player, path: string) -> DataNode<V>,
	GetPlayerOrderedDataNode: <V>(self: DataNodeService, player: Player, path: string) -> OrderedDataNode,
	
	GetPlayerData: <V>(self: DataNodeService, player: Player, path: string, force: boolean) -> V,
	GetPlayerOrderedData: (self: DataNodeService, player: Player, path: string, force: boolean) -> number,
	
	Destroy: (self: DataNodeService) -> (),
	new: () -> DataNodeService,
	init: (maid: Maid) -> nil
}

-- Class
local CurrentDataNodeService: DataNodeService = nil :: any
local DataNodeService = {} :: DataNodeService
DataNodeService.__index = DataNodeService

function DataNodeService:Destroy()
	if not self._IsAlive then return end
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


function DataNodeService:RegisterDataNode<V>(path: string, initialValue: V, getMetadata: ((player: Player) -> {[any]: any})?, serializer: Serializer<V>?, deserializer: Deserializer<V>?): ()
	self._NodeConstructors[path] = function(player: Player): ()
		local node = self._Maid:GiveTask(DataNode.new(
			player, 
			path, 
			if type(initialValue) == "table" then TableUtil.deepCopy(initialValue) else initialValue, 
			getMetadata,
			serializer,
			deserializer
		))
		self._Nodes[player] = self._Nodes[player] or {}
		self._Nodes[player][path] = node
	end
	for i, player in ipairs(Players:GetPlayers()) do
		self._NodeConstructors[path](player)
	end
end

function DataNodeService:RegisterOrderedDataNode(path: string, initialValue: number, getMetadata: ((player: Player) -> {[any]: any})?): ()
	self._OrderedNodeConstructors[path] = function(player: Player): ()
		local node = self._Maid:GiveTask(OrderedDataNode.new(
			player, 
			path, 
			initialValue, 
			getMetadata
		))
		self._OrderedNodes[player] = self._OrderedNodes[player] or {}
		self._OrderedNodes[player][path] = node
	end
	for i, player in ipairs(Players:GetPlayers()) do
		self._NodeConstructors[path](player)
	end
end

function DataNodeService:GetPlayerDataNode<V>(player: Player, path: string): DataNode<V>
	local playerNodes = self._Nodes[player]
	assert(playerNodes, `player is not registered: {player.Name}`)
	local node = playerNodes[path]
	assert(node, `missing node for player {player.Name} at path {path}`)
	return node
end

function DataNodeService:GetPlayerOrderedDataNode<V>(player: Player, path: string): OrderedDataNode
	local playerNodes = self._OrderedNodes[player]
	assert(playerNodes, `player is not registered: {player.Name}`)
	local node = playerNodes[path]
	assert(node, `missing ordered node for player {player.Name} at path {path}`)
	return node
end

function DataNodeService:GetPlayerData<V>(player: Player, path: string, force: boolean): V
	local node: DataNode<V> = self:GetPlayerDataNode(player, path)
	return node:Get(force)
end

function DataNodeService:GetPlayerOrderedData(player: Player, path: string, force: boolean): number
	local node: OrderedDataNode = self:GetPlayerOrderedDataNode(player, path)
	return node:Get(force)
end

function DataNodeService.new()

	local self: DataNodeService = setmetatable({}, DataNodeService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._NodeConstructors = {}
	self._OrderedNodeConstructors = {}
	self._Nodes = {}
	self._OrderedNodes = {}

	local function cleanPlayer(player: Player)
		self._Nodes[player] = nil
		self._OrderedNodes[player] = nil
	end

	self._Maid:GiveTask(Players.PlayerRemoving:Connect(cleanPlayer))
	self._Maid:GiveTask(game.Close:Connect(function()
		for i, player in ipairs(Players:GetPlayers()) do
			cleanPlayer(player)
		end
	end))

	if CurrentDataNodeService ~= nil then
		 CurrentDataNodeService:Destroy()
		 CurrentDataNodeService = nil :: any
	end
	CurrentDataNodeService = self

	return self
end

function DataNodeService.init(maid: Maid)
	maid:GiveTask(DataNodeService.new())
	return nil
end

return ServiceProxy(function()
	return CurrentDataNodeService or DataNodeService
end)