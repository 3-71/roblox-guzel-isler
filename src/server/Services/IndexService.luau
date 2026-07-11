--!strict
-- IndexService — collection-book milestone rewards. Discover N distinct
-- keyboards, claim cash; the permanent luck part of each claimed reward is
-- applied automatically inside RollLogic.GetEffectiveLuck.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local IndexRewards = require(Shared.Config.IndexRewards)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local IndexService = {}

local rewardById: { [string]: typeof(IndexRewards[1]) } = {}
for _, reward in IndexRewards do
	rewardById[reward.id] = reward
end

-- simple per-player rate limit (3/sec)
local lastClaim: { [Player]: number } = {}

local function discoveredCount(collection: { [string]: number }): number
	local count = 0
	for _, timesFound in collection do
		if timesFound > 0 then
			count += 1
		end
	end
	return count
end

local function onClaim(player: Player, rewardId: unknown)
	local now = os.clock()
	if lastClaim[player] ~= nil and now - lastClaim[player] < 1 / 3 then
		return
	end
	lastClaim[player] = now

	if typeof(rewardId) ~= "string" then
		return
	end
	local reward = rewardById[rewardId]
	if reward == nil then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if profile.indexClaimed[reward.id] then
		return
	end
	if discoveredCount(profile.collection) < reward.count then
		Remotes.Notify:FireClient(player, "error", `Discover {reward.count} keyboards to claim that reward!`)
		return
	end

	profile.indexClaimed[reward.id] = true
	if reward.cash > 0 then
		EconomyService.AddMoney(player, reward.cash)
	end
	DataService.MarkDirty(player)
	DataService.Sync(player)

	local luckNote = if reward.luck > 0 then ` and +{reward.luck} permanent luck` else ""
	Remotes.Notify:FireClient(player, "info", `Index reward claimed: ${reward.cash}{luckNote}!`)
end

function IndexService.Init() end

function IndexService.Start()
	Remotes.ClaimIndexReward.OnServerEvent:Connect(onClaim)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastClaim[player] = nil
	end)
end

return IndexService
