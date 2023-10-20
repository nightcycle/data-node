--!strict
local _Package = script.Parent
local _Packages = _Package.Parent

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

-- Packages
local Maid = require(_Packages:WaitForChild("Maid"))
local ServiceProxy = require(_Packages:WaitForChild("ServiceProxy"))
local Queue = require(_Packages:WaitForChild("Queue"))
local Signal = require(_Packages:WaitForChild("Signal"))

-- Modules
-- Types
type JobType = "Get" | "Set" | "Transform"
type Job = () -> (boolean, number, number?)
type SimpleJob = () -> (boolean, number)
type ComplexJob = () -> (boolean, number, number)
type Maid = Maid.Maid
type Queue<T> = Queue.Queue<T>
type Signal = Signal.Signal
export type RateService = {
	__index: RateService,
	_Maid: Maid,
	_IsAlive: boolean,
	_OnExpressJobComplete: Signal,
	_OnExpressJobUpdate: Signal,
	_OnJobComplete: Signal,
	_OnJobUpdate: Signal,
	_LastRead: {[string]: number?},
	_LastWrite: {[string]: number?},

	_Jobs: {[string]: Job?},

	_JobTagRegistry: {[string]: string},

	_TransformJobs: { [string]: ComplexJob? },
	_ExpressJobs: { [string]: Job? },
	_ExpressTransformJobs: { [string]: ComplexJob? },
	_ReadsUsed: number,
	_WritesUsed: number,

	_ReadDataUsed: number,
	_WriteDataUsed: number,

	_WriteQueue: Queue<string>,
	_TransformQueue: Queue<string>,
	_ReadExpressQueue: Queue<string>,
	_TransformExpressQueue: Queue<string>,
	_GlobalTransformQueue: Queue<string>,
	_WriteExpressQueue: Queue<string>,

	Transform: (self: RateService, name: string, key: string, job: ComplexJob, isExpress: boolean) -> boolean,
	Read: (self: RateService, name: string, key: string, job: SimpleJob) -> boolean,
	Write: (self: RateService, name: string, key: string, job: SimpleJob, isExpress: boolean) -> boolean,
	_RegisterJob: (self: RateService, name: string,	key: string, job: Job, jobType: JobType, isExpress: boolean) -> boolean,
	Destroy: (self: RateService) -> (),
	new: () -> RateService,
	init: (maid: Maid) -> nil,
}

-- Constants
local MB = 1048576
local BREATHING_ROOM = 0.9
local READS_PER_PLR_PER_MIN = math.floor(10 * BREATHING_ROOM)
local WRITES_PER_PLR_PER_MIN = math.floor(10 * BREATHING_ROOM)
local READ_THRU_PER_KEY_PER_MIN = math.floor(25 * MB * BREATHING_ROOM)
local WRITE_THRU_PER_KEY_PER_MIN = math.floor(4 * MB * BREATHING_ROOM)
local READ_COOLDOWN = 5/BREATHING_ROOM
local WRITE_COOLDOWN = 6/BREATHING_ROOM
local LOCAL_EPOCH = tick()
local NON_EXPRESS_PROPORTION = 0.25
local COOLDOWN_TAG_PRUNE = math.max(READ_COOLDOWN, WRITE_COOLDOWN)*10

-- local STORAGE_PER_KEY = math.floor(4*MB*BREATHING_ROOM)

-- Variables
-- References

-- Private Functions
function checkCooldown(
	tag: string, 
	registry: {[string]: number?}, 
	cooldown: number, 
	isExpress: boolean
): boolean
	local lastUsage = registry[tag]
	cooldown = if isExpress then cooldown / NON_EXPRESS_PROPORTION else cooldown
	if lastUsage then
		local currentUsage = tick()
		if currentUsage - lastUsage > cooldown then
			currentUsage += 1/15
			return true
		end
		return false
	end
	return true
end

function getRegistryTag(name: string, key: string): string
	return `{name}_{key}`
end

function getJobId(key: string, name: string, jobType: JobType): string
	return `{jobType}_{getRegistryTag(name, key)}`
end


-- Class
local CurrentRateService: RateService = nil :: any
local RateService = {} :: RateService
RateService.__index = RateService

function RateService:Destroy()
	if not self._IsAlive then
		return
	end
	self._IsAlive = false
	if CurrentRateService == self then
		CurrentRateService = nil :: any
	end
	self._Maid:Destroy()
	local t: any = self
	for k, v in pairs(t) do
		t[k] = nil
	end
	setmetatable(t, nil)
end


function RateService:_RegisterJob(
	name: string, 
	key: string,
	job: Job,
	jobType: JobType,
	isExpress: boolean
): boolean
	local maid = self._Maid:GiveTask(Maid.new())

	local queue: Queue<string>?
	local globalQueue: Queue<string>?
	local onJobUpdate: Signal = if isExpress then self._OnExpressJobUpdate else self._OnJobUpdate
	local onJobComplete: Signal = if isExpress then self._OnExpressJobComplete else self._OnJobComplete
	local jobRegistry: {[string]: Job?}?
	local jobId: string

	local tag = getRegistryTag(name, key)
	if jobType == "Set" then
		if isExpress then 
			queue = self._WriteExpressQueue 
			jobRegistry = self._ExpressJobs
		else 
			queue = self._WriteQueue
			jobRegistry = self._Jobs
		end
		jobId = getJobId(key, name, jobType)
	elseif jobType == "Get" then
		queue = self._ReadExpressQueue
		jobId = getJobId(key, name, jobType)
		jobRegistry = self._ExpressJobs
	elseif jobType == "Transform" then
		if isExpress then 
			queue = self._TransformExpressQueue
			jobRegistry = self._ExpressTransformJobs
		else 
			queue = self._TransformQueue 
			jobRegistry = self._TransformJobs
		end
		jobId = HttpService:GenerateGUID()
		globalQueue = self._GlobalTransformQueue
	end

	self._JobTagRegistry[jobId] = tag

	assert(queue ~= nil)
	assert(jobRegistry ~= nil)

	local jobCompleteSignal = Signal.new()

	local isSuccess = false
	local isUpdated = false
	local message: string?

	local fullPriority = -(LOCAL_EPOCH-tick())

	if queue:Has(jobId) then
		queue:Remove(jobId)
	end
	onJobUpdate:Fire(jobId)

	jobRegistry[jobId] = job
	if globalQueue then
		globalQueue:Add(jobId, fullPriority)
	end
	queue:Add(jobId, fullPriority)

	maid:GiveTask(onJobUpdate:Connect(function(updatedJobId: string)
		if updatedJobId == jobId then
			isUpdated = true
		end
	end))

	maid:GiveTask(onJobComplete:Connect(function(completedJobId: string, isJobSuccess: boolean, jobMessage: string?)
		if completedJobId == jobId then
			isSuccess = isJobSuccess
			message = jobMessage
			jobCompleteSignal:Fire()
		end
	end))

	jobCompleteSignal:Wait()

	maid:Destroy()

	if not isUpdated then
		jobRegistry[jobId] = nil

		if not isSuccess then
			if message then
				error(message)
			end
		end
	end

	return not isUpdated
end

function RateService:Transform(name: string, key: string, job: SimpleJob,isExpress: boolean): boolean
	return self:_RegisterJob(
		name,	
		key,
		job, 
		"Transform",
		isExpress
	)
end

function RateService:Read(name: string, key: string, job: SimpleJob): boolean
	return self:_RegisterJob(
		name,	
		key,
		job, 
		"Get",
		true
	)
end

function RateService:Write(name: string, key: string, job: SimpleJob, isExpress: boolean): boolean
	return self:_RegisterJob(
		name,	
		key,
		job, 
		"Set",
		isExpress
	)
end

function RateService.new()
	local self: RateService = setmetatable({}, RateService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._Jobs = {}
	
	self._TransformJobs = {}
	self._ExpressJobs = {}
	self._ExpressTransformJobs = {}

	self._LastRead = {}
	self._LastWrite = {}

	self._JobTagRegistry = {}

	self._ReadsUsed = 0
	self._WritesUsed = 0

	self._ReadDataUsed = 0
	self._WriteDataUsed = 0

	self._OnExpressJobComplete = self._Maid:GiveTask(Signal.new())
	self._OnExpressJobUpdate = self._Maid:GiveTask(Signal.new())
	self._OnJobComplete = self._Maid:GiveTask(Signal.new())
	self._OnJobUpdate = self._Maid:GiveTask(Signal.new())

	-- an express job should clear all relevant non-express jobs
	self._OnExpressJobUpdate:Connect(function(...)
		self._OnJobUpdate:Fire(...)
	end)

	-- self._ReadQueue = Queue.new()
	-- self._ReadQueue.IsSorted = true

	self._WriteQueue = Queue.new()
	self._WriteQueue.IsSorted = true

	self._TransformQueue = Queue.new()
	self._TransformQueue.IsSorted = true

	self._ReadExpressQueue = Queue.new()
	self._ReadExpressQueue.IsSorted = true

	self._WriteExpressQueue = Queue.new()
	self._WriteExpressQueue.IsSorted = true

	self._TransformExpressQueue = Queue.new()
	self._TransformExpressQueue.IsSorted = true

	self._GlobalTransformQueue = Queue.new()
	self._GlobalTransformQueue.IsSorted = true

	do
		local playerCount = math.max(#Players:GetPlayers(), 1)

		local function getIfExpressReadAvailable(isExpress: boolean): boolean
			local weight = if isExpress then 1 else NON_EXPRESS_PROPORTION
			local isReadEnabled = ((weight*playerCount * READS_PER_PLR_PER_MIN) - self._ReadsUsed > 0) 
			and (READ_THRU_PER_KEY_PER_MIN - self._ReadDataUsed > 0)
	
			if isExpress then
				return isReadEnabled
			else
				return isReadEnabled and self._ReadExpressQueue:IsEmpty() and self._TransformExpressQueue:IsEmpty()
			end
		end
	
		local function getIfExpressWriteAvailable(isExpress: boolean): boolean
			local weight = if isExpress then 1 else NON_EXPRESS_PROPORTION
			local isWriteEnabled = ((weight*playerCount * WRITES_PER_PLR_PER_MIN) - self._WritesUsed > 0) 
			and (WRITE_THRU_PER_KEY_PER_MIN - self._WriteDataUsed > 0)
	
			if isExpress then
				return isWriteEnabled
			else
				return isWriteEnabled and self._WriteExpressQueue:IsEmpty() and self._TransformExpressQueue:IsEmpty()
			end
		end
	
		local function runJob(
			queue: Queue<string>,
			isRead: boolean,
			isWrite: boolean,
			isExpress: boolean,
			jobRegistry: {[string]: Job?}
		)

			if (isRead == false or getIfExpressReadAvailable(isExpress) == true) and (isWrite == false or getIfExpressWriteAvailable(isExpress) == true) then
				local isNextInGlobalQueue = false
				do
					if queue == self._TransformQueue or queue == self._TransformExpressQueue then
						if queue:Peek() == self._GlobalTransformQueue:Peek() then
							isNextInGlobalQueue = true
						else
							return
						end
					end
				end
				local tag: string?

				do
					local nextJobId = queue:Peek()
					if nextJobId then
						tag = self._JobTagRegistry[nextJobId]
						if tag then
							if isWrite and isRead then
								if not (
									checkCooldown(
										tag, 
										self._LastWrite,
										WRITE_COOLDOWN,
										isExpress
									) and checkCooldown(
										tag, 
										self._LastRead,
										READ_COOLDOWN,
										isExpress
									)
								) then
									return
								else
									self._LastRead[tag] = tick() + 1/10
									self._LastWrite[tag] = tick() + 1/10
								end
							elseif isRead then
								if not checkCooldown(
										tag, 
										self._LastRead,
										READ_COOLDOWN,
										isExpress
									)
								then
									return
								else
									self._LastRead[tag] = tick() + 1/10
								end
							elseif isWrite then
								if not checkCooldown(
									tag, 
									self._LastWrite,
									WRITE_COOLDOWN,
									isExpress
								) then
									return
								else
									self._LastWrite[tag] = tick() + 1/10
								end
							end
						else
							queue:Get()
							error(`tag missing for job {nextJobId}`)
						end
					end
				end

				local jobId = queue:Get()
				if jobId then
					do
						assert(tag ~= nil, `bad tag for jobId {jobId}`)
						if isNextInGlobalQueue then
							self._GlobalTransformQueue:Get()
						end

						if isRead then
							self._ReadsUsed += 1
						end

						if isWrite then
							self._WritesUsed += 1
						end
						
						task.delay(60, function()
							if isRead then
								self._ReadsUsed -= 1
							end
							if isWrite then
								self._WritesUsed -= 1
							end
						end)	
					end
	
					local jobReadSize: number?, jobWriteSize: number?
					local jobSuccess: boolean = false
					local message: string?
	
					do
						local job = jobRegistry[jobId]
						assert(job, `job missing for {jobId} ({tag})`)
						local runSuccess: boolean
						runSuccess, message = pcall(function()
							local s, d1, d2 = job()
							jobSuccess = s
							if isRead and isWrite then
								jobReadSize = d1
								jobWriteSize = d2
							elseif isRead then
								jobReadSize = d1
								jobWriteSize = 0
							else --isWrite
								jobWriteSize = d1
								jobReadSize = 0
							end
						end)
						if runSuccess == false then
							jobSuccess = false
						end
					end
	
					assert(jobReadSize and jobWriteSize, `missing job size data for {tag}: {message}`)
					do
						if isRead then
							self._ReadDataUsed += jobReadSize
						end
						if isWrite then
							self._WriteDataUsed += jobWriteSize
						end
	
						task.delay(60, function()
							if isRead then
								self._ReadDataUsed -= jobReadSize
							end
							if isWrite then
								self._WriteDataUsed -= jobWriteSize
							end
						end)
					end
	
					if isExpress then
						self._OnExpressJobComplete:Fire(jobId, jobSuccess, message)
					else
						self._OnJobComplete:Fire(jobId, jobSuccess, message)						
					end
				end
			end
		end

		local lastPrune = tick()
		
		self._Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime: number)
			playerCount = math.max(#Players:GetPlayers(), 1)
			
			runJob(
				self._TransformExpressQueue,
				true,
				true,
				true,
				self._ExpressTransformJobs
			)
			runJob(
				self._ReadExpressQueue,
				true,
				false,
				true,
				self._ExpressJobs
			)
			runJob(
				self._WriteExpressQueue,
				false,
				true,
				true,
				self._ExpressJobs
			)
			runJob(
				self._TransformQueue,
				true,
				true,
				false,
				self._TransformJobs
			)
			-- runJob(
			-- 	self._ReadQueue,
			-- 	true,
			-- 	false,
			-- 	false,
			-- 	self._Jobs
			-- )
			runJob(
				self._WriteQueue,
				false,
				true,
				false,
				self._Jobs
			)

			local current = tick()
			if current - lastPrune > COOLDOWN_TAG_PRUNE then
				print(`pruning job tags`)
				local function getIfActiveJob(jobId: string)
					local queues = {self._WriteQueue, self._ReadExpressQueue, self._WriteExpressQueue, self._TransformExpressQueue, self._TransformQueue}
					for i, queue in ipairs(queues) do
						if queue:Has(jobId) then return true end
					end
					return false
				end
				
				for jobId, tag in pairs(self._JobTagRegistry) do
					local readTick = self._LastRead[tag] or 0
					local writeTick = self._LastWrite[tag] or 0
					local mostRecentRun = math.max(readTick, writeTick)
					if mostRecentRun < lastPrune then
						if not getIfActiveJob(jobId) then
							self._LastRead[tag] = nil
							self._LastWrite[tag] = nil
							self._JobTagRegistry[jobId] = nil
						end
					end
				end
				lastPrune = tick()

			end
		end))
	end
	

	if CurrentRateService ~= nil then
		CurrentRateService:Destroy()
		CurrentRateService = nil :: any
	end
	CurrentRateService = self

	return self
end

function RateService.init(maid: Maid)
	print(`booting {script.Name}`)
	maid:GiveTask(RateService.new())
	return nil
end

return ServiceProxy(function()
	return CurrentRateService or RateService
end)
