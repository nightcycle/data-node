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
	IsLoaded: boolean,
	OnLoadComplete: Signal,
	_InitialValue: V?,
	_SetJobId: string?,
	_EncodedValue: (string | V)?,
	_GetKeyInfo: DataStoreKeyInfo?,
	_UpdateKeyInfo: DataStoreKeyInfo?,
	_RemoveKeyInfo: DataStoreKeyInfo?,
	_GetMetaData: (() -> { [any]: any })?,
	OnChanged: Signal,
	ClassName: "DataNode",
	Key: UserIdKey,
	SetOptions: DataStoreSetOptions,
}
export type BaseDataNodeFunctions<Self, V> = {
	init: (maid: Maid) -> nil,
	Destroy: (self: Self) -> nil,
	Get: (self: Self, yield: boolean) -> (V?, DataStoreKeyInfo?),
	Remove: (self: Self, yield: boolean) -> (V?, DataStoreKeyInfo?),
	Set: (self: Self, data: V, yield: boolean) -> string?,
	Update: (self: Self, transformer: (V?) -> V?, yield: boolean) -> (V?, DataStoreKeyInfo?),
	_Load: (self: Self) -> (),
}
type CompositeBaseDataNode<Self, V> = BaseDataNodeProperties<V> & BaseDataNodeFunctions<Self, V>
export type BaseDataNode<V> = CompositeBaseDataNode<CompositeBaseDataNode<any, V>, V>

type DataNodeProperties<V> = {
	DataStore: DataStore,
	_Value: V?,
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
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
	return nil
end

function DataNode:Remove(yield: boolean): (unknown?, DataStoreKeyInfo?)
	if not self.IsLoaded then
		self.OnLoadComplete:Wait()
	end

	local wasRun: boolean
	local keyInfo: DataStoreKeyInfo?
	local encodedFinalValue: (unknown | string)?

	local success: boolean, errorMessage: string?

	local function run()
		local runResult = RateService:Transform(
			function(): (boolean, number, number)
				local readSize = 0
				success, errorMessage = pcall(function()
					encodedFinalValue, keyInfo = self.DataStore:RemoveAsync(self.Key)
					readSize = getByteSize(encodedFinalValue)
				end)
				if not success then
					if errorMessage then
						warn(errorMessage)
					end
				end
				return success, readSize, 0
			end,
			yield
		)
		if yield then
			wasRun = runResult
		end
	end
	if yield then
		run()
	else
		task.spawn(run)
		wasRun = true
		success = true
		encodedFinalValue = self._EncodedValue
		keyInfo = nil
	end
	
	if wasRun then
		assert(success, errorMessage)

		local finalData: unknown? = self._Deserialize(encodedFinalValue)

		self._RemoveKeyInfo = keyInfo
		self._EncodedValue = nil
		self._Value = nil

		self.OnChanged:Fire(self._Value)
	
		return finalData, keyInfo
	end
	
	return nil, nil
end

function DataNode:Set(data: unknown, yield: boolean): string?
	if not self.IsLoaded then
		self.OnLoadComplete:Wait()
	end

	local encodedData: (unknown | string)? = self._Serialize(data)

	local id: string?
	local success: boolean, errorMessage: string?
	local wasRun: boolean
	local function run()
		do
			local metadata = if self._GetMetaData then self._GetMetaData() else nil
			if metadata then
				self.SetOptions:SetMetadata(metadata)
			else
				self.SetOptions:SetMetadata({})
			end
		end

		local runResult = RateService:Write(
			`{self._Domain}/{self._Scope}`, 
			self._UserId, 
			function(): (boolean, number)
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
			end,
			yield
		)
		if yield then
			wasRun = runResult
		end
	end

	if yield then
		run()
	else
		task.spawn(run)
		wasRun = true
		success = true
	end

	if wasRun then
		assert(success, errorMessage)

		self._SetJobId = id
		local initialEncodedValue = self._EncodedValue
		local value = self._Deserialize(encodedData)

		self._EncodedValue = encodedData
		self._Value = value
	
		if encodedData ~= initialEncodedValue then
			self.OnChanged:Fire(self._Value)
		end
	
		return id
	end

	return nil
end

function DataNode:Get(yield: boolean): (unknown?, DataStoreKeyInfo?)
	if not self.IsLoaded then
		return self._Deserialize(self._Serialize(self._InitialValue))
	end

	local encodedData: (unknown | string)?, keyInfo: DataStoreKeyInfo?
	local success: boolean, errorMessage: string?

	local wasRun: boolean
	local function run()
		local runResult = RateService:Read(
			`{self._Domain}/{self._Scope}`, 
			self._UserId, 
			function(): (boolean, number)
				success, errorMessage = pcall(function()
					encodedData, keyInfo = self.DataStore:GetAsync(self.Key)
				end)
				if not success then
					if errorMessage then
						warn(errorMessage)
					end
				end
				return success, getByteSize(encodedData)
			end
		)
		if yield then
			wasRun = runResult
		end
	end
	
	if yield then
		run()
	else
		-- task.spawn(run) -- since reads aren't being applied retroactively there's no reason to fill up the queue
		encodedData = self._EncodedValue
		keyInfo = nil
		wasRun = true
		success = true
	end

	if wasRun then
		assert(success, errorMessage)

		local initialEncodedData: (unknown | string)? = self._EncodedValue
		local value = self._Deserialize(self._EncodedValue)
	
		self._EncodedValue = encodedData
		self._Value = value
	
		self._GetKeyInfo = keyInfo
	
		if initialEncodedData ~= encodedData then
			self.OnChanged:Fire(self._Value)
		end
		return self._Value, keyInfo
	end
	return nil
end


function DataNode:_Load()
	if self.IsLoaded then return end
	RateService:Read(
		`{self._Domain}/{self._Scope}`, 
		self._UserId, 
		function(): (boolean, number)
			local size = 0
			local success, errorMessage = pcall(function()
				local encodedData, keyInfo = self.DataStore:GetAsync(self.Key)
				size = getByteSize(encodedData)

				if self._IsAlive then
					self._GetKeyInfo = keyInfo

					if encodedData == nil and self._InitialValue ~= nil then
						encodedData = self._Serialize(self._InitialValue)
					end
					self._EncodedValue = encodedData
					self._Value = self._Deserialize(encodedData)
					self.IsLoaded = true
					self.OnLoadComplete:Fire(self._Value)
					self.OnChanged:Fire(self._Value)
				end
			end)
			if not success then
				if errorMessage then
					warn(errorMessage)
				end
			end
			return success, size
		end
	)
end

function DataNode:Update(transformer: (unknown?) -> unknown?, yield: boolean): (unknown?, DataStoreKeyInfo?)
	if not self.IsLoaded then
		self.OnLoadComplete:Wait()
	end

	local success: boolean, errorMessage: string?
	local retrievedEncodedValue: (unknown | string)?, keyInfo: DataStoreKeyInfo?
	local wasRun: boolean

	local function transformerWrapper(rawValue: (unknown | string)?): (unknown | string)?
		return self._Serialize(transformer(self._Deserialize(rawValue)))
	end

	local function run()
		do
			local metadata = if self._GetMetaData then self._GetMetaData() else nil

			if metadata then
				self.SetOptions:SetMetadata(metadata)
			else
				self.SetOptions:SetMetadata({})
			end

		end
		
		local runResult = RateService:Transform(function(): (boolean, number, number)
			local inputSize = 0
			local outputSize = 0
			success, errorMessage = pcall(
				function()
					local runRetEncVal, retKeyInf = self.DataStore:UpdateAsync(self.Key, function(input: (unknown | string)?): (unknown | string)?
						inputSize = getByteSize(input)
						local out: (unknown | string)? = transformerWrapper(input)
						outputSize = getByteSize(out)
						return out
					end)
					if yield then
						retrievedEncodedValue, keyInfo = runRetEncVal, retKeyInf
					end
				end)
				if not success then
					if errorMessage then
						warn(errorMessage)
					end
				end
				return success, inputSize, outputSize
			end,
			yield
		)

		if yield then
			wasRun = runResult
		end
	end

	if yield then
		run()
	else

		task.spawn(run) -- since reads aren't being applied retroactively there's no reason to fill up the queue

		retrievedEncodedValue = transformerWrapper(self._EncodedValue)
		keyInfo = nil
		wasRun = true
		success = true
	end

	if wasRun then
		assert(success, errorMessage)

		local value = self._Deserialize(self._EncodedValue)
		local initialEncodedValue = self._EncodedValue
		self._EncodedValue = retrievedEncodedValue
		self._Value = value
		self._UpdateKeyInfo = keyInfo
	
		if initialEncodedValue ~= retrievedEncodedValue then
			self.OnChanged:Fire(value)
		end
	
		return value, keyInfo
	end

	return nil, nil
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
	self._InitialValue = initialValue
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

	self.IsLoaded = false
	self.OnLoadComplete = self._Maid:GiveTask(Signal.new())

	self._Value = initialValue
	self._EncodedValue = self._Serialize(initialValue)
	self._UserId = userId
	self._SetJobId = nil
	self._GetKeyInfo = nil
	self._RemoveKeyInfo = nil
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

	task.spawn(function()
		self:_Load()
	end)

	return self
end

return DataNode
