--!strict
local _Package = script.Parent
local _Packages = _Package.Parent
-- Services
local DataStoreService = require(_Packages:WaitForChild("MockDataStoreService")) :: DataStoreService
-- local RunService = game:GetService("RunService")
-- Packages
local Maid = require(_Packages:WaitForChild("Maid"))
local Signal = require(_Packages:WaitForChild("Signal"))
local CompressionUtil = require(_Packages:WaitForChild("CompressionUtil"))
-- local NetworkUtil = require(_Packages:WaitForChild("NetworkUtil"))
-- Modules
--Types
type Table = {[any]: any}
type Signal = Signal.Signal
type Maid = Maid.Maid
export type UserId = number
export type UserIdKey = string
export type Serializer<V> = (data: V) -> string
export type Deserializer<V> = (data: string) -> V

-- Types
export type BaseDataNodeProperties<V> = {
	__index: BaseDataNodeProperties<V>,
	_Maid: Maid,
	_IsAlive: boolean,
	_GetMetaData: (() -> {[any]: any})?, 
	RETRY_LIMIT: number,
	RETRY_DELAY: number,
	BASE_DOMAIN: string,
	OnChanged: Signal,
	ClassName: "DataNode",
	Key: UserIdKey,
	Player: Player,
	SetOptions: DataStoreSetOptions,
}
export type BaseDataNodeFunctions<Self, V> = {
	init: (maid: Maid) -> nil,
	Destroy: (self: Self) -> nil,
	Get: (self: Self, force: boolean?) -> (V, boolean),
	Set: (self: Self, data: V, force: boolean?) -> boolean,
	Update: (self: Self, transformer: (V) -> V, force: boolean?) -> (V?, boolean),
	Remove: (self: Self) -> nil,
}
type CompositeBaseDataNode<Self, V> = BaseDataNodeProperties<V> & BaseDataNodeFunctions<Self, V>
export type BaseDataNode<V> = CompositeBaseDataNode<CompositeBaseDataNode<any, V>, V>

-- Constants
-- Variables
-- References
-- Class
type DataNodeProperties<V> = {
	DataStore: DataStore,
	_Value: V,
	_EncodedValue: string?,
	_Serialize: Serializer<V>,
	_Deserialize: Deserializer<V>,
} & BaseDataNodeProperties<V>

type DataNodeFunctions<Self, V> = {
	new: (player: Player, scope: string, initialValue: V, getMetadata: ((player: Player) -> {[any]: any})?, serializer: Serializer<V>?, deserializer: Deserializer<V>?) -> Self,
} & BaseDataNodeFunctions<Self, V>
type CompositeDataNode<Self, V> = DataNodeProperties<V> & DataNodeFunctions<Self, V>
export type DataNode<V> = CompositeDataNode<CompositeDataNode<any, V>, V>

--Constants
-- Variables
-- References
-- Private Functions
-- Class

local DataNode: DataNode<any> = {} :: any
DataNode.__index = DataNode
DataNode.RETRY_LIMIT = 10
DataNode.RETRY_DELAY = 0.5
DataNode.BASE_DOMAIN = "DataNodeBase"


function DataNode:Destroy()
	if not self._IsAlive then
		return
	end
	
	self._IsAlive = false
	self:Set(self._Value, true)
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
	return nil
end

function DataNode:Set(data: any, force: boolean?)
	local initialValue = self._EncodedValue
	local function set()
		local success, errorMessage = pcall(function()
			self.DataStore:SetAsync(self.Key, self._Serialize(data), { self.Player.UserId }, self.SetOptions)
		end)
		if not success then
			warn(errorMessage)
		end
		return success
	end

	local metadata = if self._GetMetaData then self._GetMetaData() else nil

	if metadata then
		self.SetOptions:SetMetadata(metadata)
	else
		self.SetOptions:SetMetadata({})
	end
	
	local success
	if force then
		local attempts = 0
		repeat
			attempts += 1
			success = set()
			if not success then
				task.wait(DataNode.RETRY_DELAY)
			end
		until success or attempts > DataNode.RETRY_LIMIT
	else
		success = true
	end
		if data then
			if type(data) == "string" then
				self._EncodedValue = self._Serialize(data) -- Base64.Encode(self._Serialize(data))
			else
				self._EncodedValue = self._Serialize(data)
			end
		else
			self._EncodedValue = nil
		end
		if self._EncodedValue then
			if type(self._EncodedValue) == "string" then
				self._Value = self._Deserialize(self._EncodedValue) -- self._Deserialize(Base64.Decode(self._EncodedValue))
			else
					self._Value = self._Deserialize(self._EncodedValue)
			end
		else
			self._Value = nil
		end
	if initialValue ~= data then
		self.OnChanged:Fire(self._Value)
	end
	return success
end

function DataNode:Update(transformer: (any) -> any, force: boolean?)
	
	local metadata = if self._GetMetaData then self._GetMetaData() else nil

	if metadata then
		self.SetOptions:SetMetadata(metadata)
	else
		self.SetOptions:SetMetadata({})
	end
	
	local initialValue = self._EncodedValue
	local function transformerWrapper(rawValue: any)
		 return self._Serialize(transformer(self._Deserialize(rawValue)))
	end
	local function update()
		local value = self._EncodedValue
		local success, msg = pcall(function()
			value = self.DataStore:UpdateAsync(self.Key, transformerWrapper)
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
			value, success = update()
			if not success then
				task.wait(DataNode.RETRY_DELAY)
			end
		until success or attempts > DataNode.RETRY_LIMIT
		if success then
			self._EncodedValue = value
		end
	else
		value = transformerWrapper(initialValue)
		if value then
			if type(value) == "string" then
				self._EncodedValue = self._Serialize(value) -- Base64.Encode(self._Serialize(value))
			else
				self._EncodedValue = self._Serialize(value)
			end
		else
			self._EncodedValue = nil
		end
	end
		if self._EncodedValue then
			if type(self._EncodedValue) == "string" then
				self._Value = self._Deserialize(self._EncodedValue) -- self._Deserialize(Base64.Decode(self._EncodedValue))
			else
					self._Value = self._Deserialize(self._EncodedValue)
			end
		else
			self._Value = nil
		end
	if initialValue ~= value then
		self.OnChanged:Fire(self._Value)
	end
	return self._Value, success
end

function DataNode:Get(force: boolean?): (any, boolean)
	if self._Value ~= nil and not force then
		return self._Value, true
	end
	
	local function get()
		local data
		local success, msg = pcall(function()
			data = self.DataStore:GetAsync(self.Key)
		end)
		if not success then
			warn(msg)
		end
		return data, success
	end
	
	local data, success
	local attempts = 0
	repeat
		attempts += 1
		data, success = get()
		if not success then
			task.wait(DataNode.RETRY_DELAY)
		end
	until success or attempts > DataNode.RETRY_LIMIT
	
	if success then
		self._EncodedValue = data
		if self._EncodedValue then
			if type(self._EncodedValue) == "string" then
				self._Value = self._Deserialize(self._EncodedValue) -- self._Deserialize(Base64.Decode(self._EncodedValue))
			else
					self._Value = self._Deserialize(self._EncodedValue)
			end
		else
			self._Value = nil
		end
	end
	
	return self._Value, success
end

function DataNode.new(player: Player, scope: string, initialValue: any, getMetadata: ((player: Player) -> {[any]: any})?, serializer: Serializer<any>?, deserializer: Deserializer<any>?)
	local maid = Maid.new()
	
	local dataStoreOptions = Instance.new("DataStoreOptions")
	maid:GiveTask(dataStoreOptions)
	
	local setOptions = Instance.new("DataStoreSetOptions")
	setOptions:SetMetadata({})
	maid:GiveTask(setOptions)
	
	local onChanged = Signal.new()
	maid:GiveTask(onChanged)
	maid.bind(player)


	local self: DataNode<any> = setmetatable({
		_Maid = maid,
		_IsAlive = true,
		_GetMetaData = if getMetadata then function()
			return getMetadata(player)
		end else nil,
		_Serialize = if serializer then
			function(v: any)
				return if type(v) ~= "number" then CompressionUtil.Types.encode(serializer(v)) else v
			end
		else function(v: any) return v end,
		_Deserialize = if deserializer then 
			function(v: any)
				local out: any
				local success, _msg = pcall(function()
					out = deserializer(CompressionUtil.Types.decode(v))
				end)
				return if success then out else v	end
		else function(v: any) return v end,
		OnChanged = onChanged,
		DataStore =  DataStoreService:GetDataStore(DataNode.BASE_DOMAIN, scope, dataStoreOptions),
		_Value = initialValue,
		Key = tostring(player.UserId),
		SetOptions = setOptions,
		Player = player,
	}, DataNode) :: any
	
	-- if RunService:IsRunning() then
	-- 	local updateEvent = NetworkUtil.getRemoteEvent(scope .. "_" .. UPDATE_SUFFIX, player)
	-- 	maid:GiveTask(updateEvent)
		
	-- 	maid:GiveTask(onChanged:Connect(function(v: any)
	-- 		updateEvent:FireClient(player, v)
	-- 	end))
		
	-- 	local getFunction = NetworkUtil.getRemoteFunction(scope .. "_" .. GET_SUFFIX, player)
	-- 	maid:GiveTask(getFunction)
	-- 	getFunction.OnServerInvoke = function(plr: Player)
	-- 		if player.UserId == plr.UserId then
	-- 			return self._Value
	-- 		end
	-- 		error("Bad player")
	-- 	end
	-- else
	-- 	local updateEvent = NetworkUtil.getBindableEvent(scope .. "_" .. UPDATE_SUFFIX)
	-- 	maid:GiveTask(updateEvent)
		
	-- 	maid:GiveTask(onChanged:Connect(function(v: any)
	-- 		updateEvent:Fire(v)
	-- 	end))
		
	-- 	local getFunction = NetworkUtil.getBindableFunction(scope .. "_" .. GET_SUFFIX)
	-- 	maid:GiveTask(getFunction)
	-- 	getFunction.OnInvoke = function()
	-- 		return self._Value
	-- 	end
	-- end
	
	self._Value = self:Get(true)
	if self._Value == nil then self._Value = initialValue end
	return self
end

return DataNode