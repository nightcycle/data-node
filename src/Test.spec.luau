--!strict
local _Package = script.Parent
local _Packages = _Package.Parent

-- Services
-- Packages
local Package = require(_Package)
local Maid = require(_Packages:WaitForChild("Maid"))
-- Modules
-- Types
-- Constants
local TEST_USER_ID = 1
local INITIAL_VALUE = 123
local PATH = "A/B/C/D"
-- Variables
-- References
-- Private functions
-- Class
return function()
	local maid = Maid.new()


	describe("data-node", function()
		describe("registration", function()
			it("call", function()
				Package.init(maid)
				Package:RegisterDataNode(PATH, INITIAL_VALUE)
				Package:RegisterUser(TEST_USER_ID)

			end)
		end)
	end)
	maid:Destroy()
end
