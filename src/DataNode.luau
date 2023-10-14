--!strict
local _Package = script.Parent
local _Packages = _Package.Parent

-- Services
local DataStoreService = require(_Packages:WaitForChild("MockDataStoreService")) :: DataStoreService
local Players = game:GetService("Players")

-- Packages
local Maid = require(_Packages:WaitForChild("Maid"))
local Signal = require(_Packages:WaitForChild("Signal"))
local CompressionUtil = require(_Packages:WaitForChild("CompressionUtil"))
local RateService = require(_Package:WaitForChild("RateService"))

-- Modules
--Types
type Table = { [any]: any }
type Signal = Signal.Signal
type Maid = Maid.Maid
export type UserId = number
export type UserIdKey = string
export type Serializer<V> = (data: V) -> (string | V)?
export type Deserializer<V> = (data: (string | V)?) -> V

-- Types
export type BaseDataNodeProperties<V> = {
	__index: BaseDataNodeProperties<V>,
	_Maid: Maid,
	_IsAlive: boolean,
	_Player: Player?,
	_UserId: number,
	_Domain: string,
	_Scope: string,
	_GetMetaData: (() -> { [any]: any })?,
	OnChanged: Signal,
	ClassName: "DataNode",
	Key: UserIdKey,
	SetOptions: DataStoreSetOptions,
}
export type BaseDataNodeFunctions<Self, V> = {
	init: (maid: Maid) -> nil,
	Destroy: (self: Self) -> nil,
	Get: (self: Self, force: boolean?) -> (V, DataStoreKeyInfo),
	Remove: (self: Self) -> (V?, DataStoreKeyInfo),
	Set: (self: Self, data: V) -> string,
	Update: (self: Self, transformer: (V?) -> V?) -> (V?, DataStoreKeyInfo),
}
type CompositeBaseDataNode<Self, V> = BaseDataNodeProperties<V> & BaseDataNodeFunctions<Self, V>
export type BaseDataNode<V> = CompositeBaseDataNode<CompositeBaseDataNode<any, V>, V>

type DataNodeProperties<V> = {
	DataStore: DataStore,
	_IsInitialized: boolean,
	_Value: V,
	_SetJobId: string?,
	_EncodedValue: (string | V)?,
	_GetKeyInfo: DataStoreKeyInfo?,
	_UpdateKeyInfo: DataStoreKeyInfo?,
	_Serialize: Serializer<V>,
	_Deserialize: Deserializer<V>,
} & BaseDataNodeProperties<V>

type DataNodeFunctions<Self, V> = {
	new: (
		userId: number,
		domain: string,
		scope: string,
		initialValue: V,
		getMetadata: ((userId: number) -> { [any]: any })?,
		serializer: Serializer<V>?,
		deserializer: Deserializer<V>?
	) -> Self,
} & BaseDataNodeFunctions<Self, V>
type CompositeDataNode<Self, V> = DataNodeProperties<V> & DataNodeFunctions<Self, V>
export type DataNode<V> = CompositeDataNode<CompositeDataNode<any, V>, V>

-- Constants
-- Variables
-- References
-- Private functions
function getByteSize(unknown: unknown?): number
	local size: number?
	if type(unknown) == "string" then
		size = unknown:len()
	elseif type(unknown) == "number" then
		size = 16
	elseif type(unknown) == "boolean" then
		size = 16
	elseif type(unknown) == "nil" then
		size = 0
	elseif type(unknown) == "table" then
		error(`you can't store a table using DataNode as it needs to estimate the byte size`)
	elseif type(unknown) == "userdata" or type(unknown) == "function" or type(unknown) == "thread" then
		error(`you can't store data of type {type(unknown)}`)
	end
	assert(size ~= nil, `type {type(unknown)} not supported`)
	return size
end
-- Class
local DataNode: DataNode<any> = {} :: any
DataNode.__index = DataNode

function DataNode:Destroy()
	if not self._IsAlive then
		return
	end

	self._IsAlive = false
	self:Set(self._Value)
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
	return nil
end

function DataNode:Remove(): (unknown?, DataStoreKeyInfo)
	local keyInfo: DataStoreKeyInfo
	local encodedFinalValue: (unknown | string)?

	local success: boolean, errorMessage: string?

	RateService:Write(`{self._Domain}/{self._Scope}`, self._UserId, function(): (boolean, number)
		success, errorMessage = pcall(function()
			encodedFinalValue, keyInfo = self.DataStore:RemoveAsync(self.Key)
		end)
		if not success then
			if errorMessage then
				warn(errorMessage)
			end
		end
		return success, 0
	end)

	assert(success, errorMessage)

	local finalData: unknown?
	if encodedFinalValue then
		self._IsInitialized = false
		finalData = self._Deserialize(encodedFinalValue)
	end

	self._EncodedValue = nil
	self._Value = nil
	self.OnChanged:Fire(self._Value)

	return finalData, keyInfo
end

function DataNode:Set(data: unknown): string
	local id: string

	local encodedData: (unknown | string)? = self._Serialize(data)
	if encodedData == self._EncodedValue and self._SetJobId ~= nil and self._IsInitialized then
		return self._SetJobId
	end

	local metadata = if self._GetMetaData then self._GetMetaData() else nil
	if metadata then
		self.SetOptions:SetMetadata(metadata)
	else
		self.SetOptions:SetMetadata({})
	end

	local success: boolean, errorMessage: string?

	RateService:Write(`{self._Domain}/{self._Scope}`, self._UserId, function(): (boolean, number)
		local size: number = getByteSize(encodedData)
		success, errorMessage = pcall(function()
			id = self.DataStore:SetAsync(self.Key, encodedData, { self._UserId }, self.SetOptions)
		end)
		if not success then
			if errorMessage then
				warn(errorMessage)
			end
		end
		return success, size
	end)

	assert(success, errorMessage)
	self._SetJobId = id
	self._Value = self._Deserialize(encodedData)
	self.OnChanged:Fire(self._Value)

	return id
end

function DataNode:Get(force: boolean?): (unknown, DataStoreKeyInfo)
	if self._IsInitialized and self._GetKeyInfo and force ~= true then
		return self._Value, self._GetKeyInfo
	end

	local encodedData: (unknown | string)?, keyInfo: DataStoreKeyInfo
	local success: boolean, errorMessage: string?

	RateService:Read(`{self._Domain}/{self._Scope}`, self._UserId, function(): (boolean, number)
		success, errorMessage = pcall(function()
			encodedData, keyInfo = self.DataStore:GetAsync(self.Key)
		end)
		if not success then
			if errorMessage then
				warn(errorMessage)
			end
		end
		return success, getByteSize(encodedData)
	end)

	assert(success, errorMessage)

	local initialEncodedData: (unknown | string)? = self._EncodedValue
	self._EncodedValue = encodedData

	if self._EncodedValue ~= nil then
		if type(self._EncodedValue) == "string" then
			self._Value = self._Deserialize(self._EncodedValue) -- self._Deserialize(Base64.Decode(self._EncodedValue))
		else
			self._Value = self._Deserialize(self._EncodedValue)
		end
	else
		self._Value = nil
	end

	self._GetKeyInfo = keyInfo

	if initialEncodedData == encodedData then
		self.OnChanged:Fire(self._Value)
	end

	return self._Value, keyInfo
end

function DataNode:Update(transformer: (unknown?) -> unknown?): (unknown?, DataStoreKeyInfo)
	local initialEncodedValue: (unknown | string)? = self._EncodedValue

	local metadata = if self._GetMetaData then self._GetMetaData() else nil

	if metadata then
		self.SetOptions:SetMetadata(metadata)
	else
		self.SetOptions:SetMetadata({})
	end

	local outputEncodedValue: (unknown | string)?
	local function transformerWrapper(rawValue: (unknown | string)?): (unknown | string)?
		local outputValue = transformer(if rawValue then self._Deserialize(rawValue) else nil)
		if outputValue then
			outputEncodedValue = self._Serialize(outputValue)
		end
		return outputEncodedValue
	end

	if self._IsInitialized and self._UpdateKeyInfo then
		local expectedValue = transformerWrapper(self._EncodedValue)
		if expectedValue == self._EncodedValue then
			return self._Value, self._UpdateKeyInfo
		end
	end

	local success: boolean, errorMessage: string?
	local retrievedEncodedValue: (unknown | string)?, keyInfo: DataStoreKeyInfo

	RateService:Transform(function(): (boolean, number, number)
		local inputSize = 0
		local outputSize = 0
		success, errorMessage = pcall(function()
			retrievedEncodedValue, keyInfo = self.DataStore:UpdateAsync(self.Key, function(input: (unknown | string)?): (unknown | string)?
				inputSize = getByteSize(input)
				local out: (unknown | string)? = transformerWrapper(input)
				outputSize = getByteSize(out)
				return out
			end)
		end)
		if not success then
			if errorMessage then
				warn(errorMessage)
			end
		end
		return success, inputSize, outputSize
	end)
	assert(success, errorMessage)

	self._EncodedValue = outputEncodedValue

	if self._EncodedValue then
		self._Value = self._Deserialize(self._EncodedValue)
	else
		self._Value = nil
	end
	self._UpdateKeyInfo = keyInfo

	if initialEncodedValue ~= outputEncodedValue then
		self.OnChanged:Fire(self._Value)
	end

	return if retrievedEncodedValue then self._Deserialize(retrievedEncodedValue) else nil, keyInfo
end

function DataNode.new(
	userId: number,
	domain: string,
	scope: string,
	initialValue: unknown,
	getMetadata: ((userId: number) -> { [any]: any })?,
	serializer: Serializer<any>?,
	deserializer: Deserializer<any>?
): DataNode<unknown>
	local maid = Maid.new()

	local onChanged = Signal.new()
	maid:GiveTask(onChanged)

	local self: DataNode<unknown> = setmetatable({}, DataNode) :: any
	self._Maid = maid
	self._IsAlive = true
	self._GetMetaData = if getMetadata
		then function()
			return getMetadata(self._UserId)
		end
		else nil

	self._Serialize = serializer or function(data: unknown?): (string | unknown)?
		if type(data) == "userdata" or type(data) == "string" then
			return CompressionUtil.Encoding.UTF8.toUTF8(CompressionUtil.Types.encode(data :: any))
		else
			return data
		end
	end

	self._Deserialize = deserializer or function(data: (string | unknown)?): unknown?
		if type(data) == "string" then
			return CompressionUtil.Types.decode(CompressionUtil.Encoding.UTF8.fromUTF8(data))
		else
			return data
		end
	end

	self.OnChanged = onChanged
	self._Domain = domain
	self._Scope = scope

	self._IsInitialized = false
	self._Value = initialValue
	self._EncodedValue = self._Serialize(initialValue)
	self._UserId = userId
	self._SetJobId = nil
	self._GetKeyInfo = nil
	self.Key = tostring(self._UserId)

	self.SetOptions = self._Maid:GiveTask(Instance.new("DataStoreSetOptions"))
	self.SetOptions:SetMetadata({})

	local dataStoreOptions = Instance.new("DataStoreOptions")
	maid:GiveTask(dataStoreOptions)

	self.DataStore = DataStoreService:GetDataStore(self._Domain, self._Scope, dataStoreOptions)

	self._Player = Players:GetPlayerByUserId(self._UserId)
	if self._Player then
		maid.bind(self._Player)
	end

	self._Value = self:Get()
	if self._Value == nil then
		self:Set(initialValue)
	end
	self._IsInitialized = true

	return self
end

return DataNode
