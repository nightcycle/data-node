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
type JobType = "Get" | "Set" | "Increment"
type Job = () -> (boolean, number)
type TransformJob = () -> (boolean, number, number)
type Maid = Maid.Maid
type Queue<T> = Queue.Queue<T>
type Signal = Signal.Signal
export type RateService = {
	__index: RateService,
	_Maid: Maid,
	_IsAlive: boolean,
	_OnJobComplete: Signal,
	_Jobs: { [string]: Job },
	_TransformJobs: { [string]: TransformJob },
	_ReadsUsed: number,
	_WritesUsed: number,

	_ReadDataUsed: number,
	_WriteDataUsed: number,

	_ReadQueue: Queue<string>,
	_IncrementQueue: Queue<string>,
	_WriteQueue: Queue<string>,

	Transform: (self: RateService, job: TransformJob) -> boolean,
	Read: (self: RateService, path: string, userId: number, job: Job) -> boolean,
	Write: (self: RateService, path: string, userId: number, job: Job) -> boolean,
	Destroy: (self: RateService) -> (),
	new: () -> RateService,
	init: (maid: Maid) -> nil,
}

-- Constants
local MB = 1048576
local BREATHING_ROOM = 0.95
local READS_PER_PLR_PER_MIN = math.floor(10 * BREATHING_ROOM)
local WRITES_PER_PLR_PER_MIN = math.floor(10 * BREATHING_ROOM)
local READ_THRU_PER_KEY_PER_MIN = math.floor(25 * MB * BREATHING_ROOM)
local WRITE_THRU_PER_KEY_PER_MIN = math.floor(4 * MB * BREATHING_ROOM)
-- local STORAGE_PER_KEY = math.floor(4*MB*BREATHING_ROOM)

-- Variables
-- References

-- Private Functions
function getJobId(userId: number, path: string, jobType: JobType): string
	return `{jobType}_{path}_{userId}`
end

function processJob(serviceMaid: Maid, jobId: string, jobRegistry: { [string]: Job }, job: Job, queue: Queue<string>, onJobComplete: Signal): boolean
	local maid = Maid.new()
	local jobCompleteSignal = maid:GiveTask(Signal.new())

	serviceMaid[jobId] = maid
	jobRegistry[jobId] = job

	local isSuccess = false

	queue:Add(jobId, -tick())

	maid:GiveTask(onJobComplete:Connect(function(completedJobId: string, isJobSuccess: boolean)
		if completedJobId == jobId then
			isSuccess = isJobSuccess
			jobCompleteSignal:Fire()
		end
	end))

	jobCompleteSignal:Wait()

	return isSuccess
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

function RateService:Transform(job: Job): boolean
	local jobId = HttpService:GenerateGUID(false)
	return processJob(self._Maid, jobId, self._Jobs, job, self._IncrementQueue, self._OnJobComplete)
end

function RateService:Read(path: string, userId: number, job: Job): boolean
	local jobId = getJobId(userId, path, "Get")
	return processJob(self._Maid, jobId, self._Jobs, job, self._ReadQueue, self._OnJobComplete)
end

function RateService:Write(path: string, userId: number, job: Job): boolean
	local jobId = getJobId(userId, path, "Set")
	return processJob(self._Maid, jobId, self._Jobs, job, self._WriteQueue, self._OnJobComplete)
end

function RateService.new()
	local self: RateService = setmetatable({}, RateService) :: any
	self._IsAlive = true
	self._Maid = Maid.new()
	self._Jobs = {}
	self._TransformJobs = {}

	self._ReadsUsed = 0
	self._WritesUsed = 0

	self._ReadDataUsed = 0
	self._WriteDataUsed = 0

	self._OnJobComplete = self._Maid:GiveTask(Signal.new())

	self._ReadQueue = Queue.new()
	self._ReadQueue.IsSorted = true

	self._WriteQueue = Queue.new()
	self._WriteQueue.IsSorted = true

	self._IncrementQueue = Queue.new()
	self._IncrementQueue.IsSorted = true

	local function runJob(queue: Queue<string>, getIfAvailable: () -> boolean, incrementRequests: (delta: number) -> (), incrementData: (delta: number) -> ())
		if getIfAvailable() then
			local jobId = queue:Get()
			incrementRequests(-1)
			if jobId then
				task.delay(60, function()
					incrementRequests(1)
				end)
				local job = self._Jobs[jobId]
				local jobSuccess = false
				local jobDataSize = 0
				if job then
					pcall(function()
						jobSuccess, jobDataSize = job()
					end)
				end
				incrementData(-jobDataSize)
				task.delay(60, function()
					incrementData(jobDataSize)
				end)
				self._OnJobComplete:Fire(jobId, jobSuccess)
			end
		end
	end
	local function runTransformJob(
		queue: Queue<string>,
		getIfAvailable: () -> boolean,
		incrementRequests: (readDelta: number, writeDelta: number) -> (),
		incrementData: (readDelta: number, writeDelta: number) -> ()
	)
		if getIfAvailable() then
			local jobId = queue:Get()
			incrementRequests(1, 1)
			if jobId then
				task.delay(60, function()
					incrementRequests(-1, -1)
				end)
				local job = self._TransformJobs[jobId]
				local jobSuccess = false
				local jobReadSize, jobWriteSize = 0, 0
				if job then
					pcall(function()
						jobSuccess, jobReadSize, jobWriteSize = job()
					end)
				end
				incrementData(jobReadSize, jobWriteSize)
				task.delay(60, function()
					incrementData(-jobReadSize, -jobWriteSize)
				end)
				self._OnJobComplete:Fire(jobId, jobSuccess)
			end
		end
	end
	self._Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime: number)
		local playerCount = math.max(#Players:GetPlayers(), 1)
		runJob(self._ReadQueue, function(): boolean
			local isReadEnabled = ((playerCount * READS_PER_PLR_PER_MIN) - self._ReadsUsed > 0) and (READ_THRU_PER_KEY_PER_MIN - self._ReadDataUsed > 0)
			return isReadEnabled
		end, function(delta: number): ()
			self._ReadsUsed += delta
		end, function(delta: number): ()
			self._ReadDataUsed += delta
		end)
		runJob(self._WriteQueue, function(): boolean
			local isWriteEnabled = ((playerCount * WRITES_PER_PLR_PER_MIN) - self._WritesUsed > 0) and (WRITE_THRU_PER_KEY_PER_MIN - self._WriteDataUsed > 0)
			return isWriteEnabled
		end, function(delta: number): ()
			self._WritesUsed += delta
		end, function(delta: number): ()
			self._WriteDataUsed += delta
		end)
		runTransformJob(self._IncrementQueue, function(): boolean
			local isWriteEnabled = ((playerCount * WRITES_PER_PLR_PER_MIN) - self._WritesUsed > 0) and (WRITE_THRU_PER_KEY_PER_MIN - self._WriteDataUsed > 0)
			local isReadEnabled = ((playerCount * READS_PER_PLR_PER_MIN) - self._ReadsUsed > 0) and (READ_THRU_PER_KEY_PER_MIN - self._ReadDataUsed > 0)

			return isReadEnabled and isWriteEnabled
		end, function(readDelta: number, writeDelta: number): ()
			self._WritesUsed += writeDelta
			self._ReadsUsed += readDelta
		end, function(readDelta: number, writeDelta: number): ()
			self._WriteDataUsed += writeDelta
			self._ReadDataUsed += readDelta
		end)
	end))

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
