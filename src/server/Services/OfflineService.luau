--!strict
-- OfflineService — simulates conveyor production for the time a player was
-- away. Registered as DataService's offline processor, so it runs between
-- the raw profile load and OnProfileLoaded subscribers; DataService fires
-- the OfflineReport remote (after a short delay) when we return a payload.
--
-- Display aging (Phase 4): the processor ALSO ages every DISPLAYED instance
-- by secondsAway * GameConfig.Aging.OfflineRateMult. Because it runs before
-- OnProfileLoaded, ShowcaseService renders the correct stage on join, and the
-- login DataSync carries the new ageSeconds — no extra Sync needed here.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local RollLogic = require(Shared.RollLogic)
local Catalog = require(Shared.Catalog)
local GameConfig = require(Shared.Config.GameConfig)
local FactoryTiers = require(Shared.Config.FactoryTiers)
local Keyboards = require(Shared.Config.Keyboards)

local DataService = require(script.Parent.DataService)

local OfflineService = {}

-- One RNG per server, mirroring ProductionService's rule.
local rng = Random.new()

-- Offline storage cap for the given storage upgrade level.
local function offlineCap(storageLevel: number): number
	if storageLevel <= 0 then
		return GameConfig.OfflineCapBase
	end
	local caps = GameConfig.StorageCapPerLevel
	return caps[math.min(storageLevel, #caps)]
end

-- Pure-ish processor: mutates the given profile (keyboards + collection)
-- and returns the report payload, or nil when nothing happened. Runs before
-- the session exists, so DataService owns the MarkDirty/Sync that follow.
function OfflineService.Process(profile: Types.Profile): Types.OfflinePayload?
	local now = os.time()
	local secondsAway = now - profile.lastSeen

	-- Displayed boards keep maturing (at reduced rate) while the owner is
	-- away — including short hops below OfflineMinSeconds, which is why this
	-- runs before the early return. The profile session is born dirty, so
	-- these mutations persist on the first autosave without a MarkDirty here.
	if secondsAway > 0 then
		local displayedUids: { [string]: boolean } = {}
		for _, uid in profile.displayed do
			displayedUids[uid] = true
		end
		if next(displayedUids) ~= nil then
			local agedSeconds = secondsAway * GameConfig.Aging.OfflineRateMult
			for _, instance in profile.keyboards do
				if displayedUids[instance.uid] then
					instance.ageSeconds = (instance.ageSeconds or 0) + agedSeconds
				end
			end
		end
	end

	if secondsAway < GameConfig.OfflineMinSeconds then
		return nil
	end

	local upgrades = profile.upgrades
	local factoryTier = math.clamp(upgrades.factoryTier, 1, #FactoryTiers)
	-- Same interval math as ProductionService: per-conveyor interval shrinks
	-- with speed levels, and every unlocked conveyor produces in parallel.
	local interval = FactoryTiers[factoryTier].baseInterval
		* GameConfig.SpeedMultPerLevel ^ math.max(upgrades.speed, 0)
	if interval <= 0 then
		return nil
	end

	local conveyors = math.clamp(upgrades.conveyors, 1, GameConfig.MaxConveyors)
	local rolled = math.floor(secondsAway / interval) * conveyors

	local cap = offlineCap(upgrades.storage)
	if profile.passes ~= nil and profile.passes.doubleStorage then
		cap *= 2
	end
	local inventoryRoom = math.max(GameConfig.InventoryCap - #profile.keyboards, 0)
	local produced = math.min(rolled, cap, inventoryRoom)
	if produced <= 0 then
		return nil
	end

	-- No server event applies offline; boosts/rebirths/index still count.
	local effectiveLuck = RollLogic.GetEffectiveLuck(profile, now, 0)

	local bestValue = 0
	local bestKeyboardId: string? = nil
	for _ = 1, produced do
		local index = RollLogic.RollKeyboard(factoryTier, effectiveLuck, rng)
		local def = Keyboards[index]
		-- Mutations are ONLINE-ONLY by design (research: offline keeps the
		-- habit alive; online presence earns the multipliers).
		local instance: Types.KeyboardInstance = {
			uid = HttpService:GenerateGUID(false),
			id = def.id,
			obtainedAt = now,
			mutation = nil,
		}
		table.insert(profile.keyboards, instance)
		profile.collection[def.id] = (profile.collection[def.id] or 0) + 1
		-- "Best" = highest sell value, so a Golden mid-tier can headline.
		-- Fresh rolls carry no mutation (offline is mutation-free by design),
		-- no stars and no age, so those args stay nil.
		local value = Catalog.GetSellValue(def.id, factoryTier, nil, profile.rebirths)
		if value > bestValue then
			bestValue = value
			bestKeyboardId = def.id
		end
	end

	return {
		secondsAway = secondsAway,
		produced = produced,
		capped = rolled > produced,
		bestKeyboardId = bestKeyboardId,
	}
end

function OfflineService.Init()
	-- Init order puts DataService first, but ALL Init()s run before any
	-- Start(), so the processor is registered before any profile loads.
	DataService.SetOfflineProcessor(OfflineService.Process)
end

function OfflineService.Start()
	-- All work happens inside the processor during profile load.
end

return OfflineService
