--!strict
-- RestockShopService — the hub "Limited Crates" stall (Phase 3).
--
-- Stock is synced to the WALL CLOCK, not server uptime: the current cycle is
--   slotSeed = math.floor(os.time() / GameConfig.Restock.IntervalSeconds)
-- and the cycle's offers are rolled from Config/RestockShop by weight with
-- Random.new(slotSeed) — every server stocks the exact same slots and flips
-- them at the exact same moment. stockLeft is tracked per server per cycle.
--
-- Remotes:
--   RestockSync (server -> all on cycle change / stock change, and to each
--     player on profile load): { restockAt, slots = { { offerId, stockLeft,
--     price } } }. `price` is the offer's BASE cost — the actual charge is
--     price * buyer's upgrades.factoryTier, which the client computes from
--     its own profile snapshot.
--   BuyRestockItem (client -> server): slotIndex. Validated: rate limit,
--     integer slot in range, stock left, deliverable, affordable. Effects by
--     offer kind:
--       guaranteedRoll — instant roll with rarity >= tierFloor: rarity picked
--         from the buyer's live RollLogic.GetOdds renormalized over tiers >=
--         tierFloor (crates bypass the factory ceiling: if the buyer's
--         maxRarity < tierFloor the crate grants exactly tierFloor), uniform
--         keyboard within the tier, normal mutation roll (event mult and an
--         active charm both apply), granted via InventoryService.AddKeyboard.
--       luckSurge — profile.boosts["restock_luck"] = now + duration
--         (RollLogic.GetEffectiveLuck adds the config'd luckBonus while set).
--       mutationCharm — profile.boosts["mutation_charm"] badge + an in-memory
--         {mult, rollsLeft} counter consumed roll-by-roll via ConsumeCharm.
--       instantCash — EconomyService.AddMoney(paid cost * cashMult).
--   Rare offers (weight <= 3) get a server-wide "flex" Notify on restock.
--
-- Public API:
--   ConsumeCharm(player): number? — if the player has an active Mutation
--     Charm with rolls remaining, decrements it and returns the mutation
--     chance multiplier; nil otherwise. ProductionService calls this once per
--     production roll. (The counter is in-memory per contract: leaving the
--     server forfeits unused charm rolls; the persisted boost is UI-only.)
--
-- Also drives the CrateStall countdown: writes "Restock in m:ss" onto the
-- stall board's "Countdown" TextLabel (built by HubBuilder) every second.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local RollLogic = require(Shared.RollLogic)
local GameConfig = require(Shared.Config.GameConfig)
local RestockShop = require(Shared.Config.RestockShop)
local FactoryTiers = require(Shared.Config.FactoryTiers)
local Rarities = require(Shared.Config.Rarities)
local Keyboards = require(Shared.Config.Keyboards)
local Events = require(Shared.Config.Events)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)

local RestockShopService = {}

local BUY_RATE_WINDOW = 1 -- seconds
local BUY_RATE_MAX = 3 -- BuyRestockItem requests per window per player
local CHARM_BOOST_SECONDS = 3600 -- boosts["mutation_charm"] badge (Phase-3 contract)
local RARE_OFFER_MAX_WEIGHT = 3 -- offers this rare are server-announced (contract)

type Slot = {
	offer: RestockShop.RestockOffer,
	stockLeft: number,
}

type Charm = {
	mult: number,
	rollsLeft: number,
}

-- -1 = "no cycle yet", so the first ensureCycle() always stocks the stall.
local currentSeed = -1
local slots: { Slot } = {}
local charms: { [Player]: Charm } = {}
local buyTimestamps: { [Player]: { number } } = {}
local countdownLabel: TextLabel? = nil

-- RNG for crate contents / mutations — deliberately NOT the seeded stock RNG
-- (stock must match across servers; what players pull from crates must not).
local rng = Random.new()

-- ===== Wall-clock stock =====

-- Weighted pick of one index from `pool` (all Config weights are > 0).
local function weightedIndex(pool: { RestockShop.RestockOffer }, seededRng: Random): number
	local total = 0
	for _, offer in pool do
		total += offer.weight
	end
	local roll = seededRng:NextNumber() * total
	local cumulative = 0
	for index, offer in pool do
		cumulative += offer.weight
		if roll <= cumulative then
			return index
		end
	end
	return #pool
end

-- Rolls the cycle's slots: weighted sampling WITHOUT replacement (no
-- duplicate offers on the board), fully determined by the wall-clock seed.
local function rollSlots(seed: number): { Slot }
	local seededRng = Random.new(seed)
	local pool = table.clone(RestockShop)
	local newSlots: { Slot } = {}
	for _ = 1, math.min(GameConfig.Restock.Slots, #pool) do
		local index = weightedIndex(pool, seededRng)
		local offer = pool[index]
		table.remove(pool, index)
		table.insert(newSlots, { offer = offer, stockLeft = offer.stock })
	end
	return newSlots
end

local function restockAt(): number
	return (currentSeed + 1) * GameConfig.Restock.IntervalSeconds
end

local function buildSyncPayload(): { [string]: any }
	local slotPayload = {}
	for _, slot in slots do
		table.insert(slotPayload, {
			offerId = slot.offer.id,
			stockLeft = slot.stockLeft,
			price = slot.offer.cost,
		})
	end
	return { restockAt = restockAt(), slots = slotPayload }
end

local function broadcastSync()
	Remotes.RestockSync:FireAllClients(buildSyncPayload())
end

local function announceRareOffers()
	for _, slot in slots do
		if slot.offer.weight <= RARE_OFFER_MAX_WEIGHT then
			Remotes.Notify:FireAllClients(
				"flex",
				`🎁 {slot.offer.name} in stock at the hub — {slot.stockLeft} left!`
			)
		end
	end
end

-- Re-aligns stock with the wall clock. On a cycle flip: reroll slots, sync
-- everyone, and announce any rare offers. Returns true if a restock happened.
local function refreshCycle(): boolean
	local seed = math.floor(os.time() / GameConfig.Restock.IntervalSeconds)
	if seed == currentSeed then
		return false
	end
	currentSeed = seed
	slots = rollSlots(seed)
	broadcastSync()
	announceRareOffers()
	return true
end

-- ===== Stall countdown =====

local function findCountdownLabel(): TextLabel?
	local cached = countdownLabel
	if cached ~= nil and cached:IsDescendantOf(Workspace) then
		return cached
	end
	countdownLabel = nil
	local hub = Workspace:FindFirstChild("Hub")
	if hub == nil then
		return nil
	end
	local stall = hub:FindFirstChild("CrateStall")
	if stall == nil then
		return nil
	end
	local label = stall:FindFirstChild("Countdown", true)
	if label ~= nil and label:IsA("TextLabel") then
		countdownLabel = label
		return label
	end
	return nil
end

local function updateCountdown()
	local label = findCountdownLabel()
	if label == nil then
		return
	end
	local remaining = math.max(restockAt() - os.time(), 0)
	label.Text = string.format("Restock in %d:%02d", math.floor(remaining / 60), remaining % 60)
end

-- ===== Buying =====

-- The active server event (Workspace attributes set by EventService), or nil.
local function getActiveEvent(): typeof(Events[1])?
	local id = Workspace:GetAttribute("ActiveEventId")
	local expiry = Workspace:GetAttribute("ActiveEventUntil")
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	if typeof(expiry) ~= "number" or expiry <= os.time() then
		return nil
	end
	for _, event in Events do
		if event.id == id then
			return event
		end
	end
	return nil
end

-- Sliding-window rate limit (same pattern as EconomyService's SellRequest).
local function allowBuyRequest(player: Player): boolean
	local now = os.clock()
	local stamps = buyTimestamps[player]
	if stamps == nil then
		stamps = {}
		buyTimestamps[player] = stamps
	end
	for i = #stamps, 1, -1 do
		if now - stamps[i] > BUY_RATE_WINDOW then
			table.remove(stamps, i)
		end
	end
	if #stamps >= BUY_RATE_MAX then
		return false
	end
	table.insert(stamps, now)
	return true
end

-- Picks the crate's rarity tier: the buyer's live odds renormalized over
-- tiers >= tierFloor. GetOdds zeroes everything above the factory ceiling, so
-- the pick is naturally clamped to maxRarity; when the ceiling sits BELOW the
-- floor there is no mass to renormalize and the crate grants exactly
-- tierFloor — crates bypass the factory ceiling, that's their appeal.
local function rollGuaranteedTier(profile: Types.Profile, tierFloor: number): number
	tierFloor = math.clamp(tierFloor, 1, #Rarities)
	local factoryTier = math.clamp(profile.upgrades.factoryTier, 1, #FactoryTiers)
	local event = getActiveEvent()
	local luck = RollLogic.GetEffectiveLuck(profile, os.time(), if event then event.luckBonus else 0)
	local odds = RollLogic.GetOdds(factoryTier, luck)

	local total = 0
	for tier = tierFloor, #Rarities do
		total += odds[tier]
	end
	if total <= 0 then
		return tierFloor
	end

	local roll = rng:NextNumber() * total
	local cumulative = 0
	local lastPositive = tierFloor
	for tier = tierFloor, #Rarities do
		local p = odds[tier]
		if p > 0 then
			lastPositive = tier
			cumulative += p
			if roll <= cumulative then
				return tier
			end
		end
	end
	return lastPositive
end

-- Uniform pick among the keyboards of one rarity tier.
local function pickKeyboardInTier(tier: number): string?
	local candidates: { string } = {}
	for _, def in Keyboards do
		if def.rarityTier == tier then
			table.insert(candidates, def.id)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

local function onBuyRestockItem(player: Player, slotIndexRaw: unknown)
	if not allowBuyRequest(player) then
		return -- rate limited: drop silently
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if typeof(slotIndexRaw) ~= "number" or slotIndexRaw ~= slotIndexRaw then
		return
	end
	local slotIndex = math.floor(slotIndexRaw)
	if slotIndex ~= slotIndexRaw then
		return -- non-integer slot index: malformed
	end

	-- A buy can race the 1s loop across a restock boundary — re-align first
	-- so the purchase always comes out of the stock the player can see.
	refreshCycle()

	local slot = slots[slotIndex]
	if slot == nil then
		return
	end
	if slot.stockLeft <= 0 then
		Remotes.Notify:FireClient(player, "error", "Sold out — wait for the restock!")
		return
	end

	local offer = slot.offer
	local factoryTier = math.clamp(profile.upgrades.factoryTier, 1, #FactoryTiers)
	local cost = offer.cost * factoryTier

	-- Make sure a crate can actually be delivered BEFORE charging.
	local crateKeyboardId: string? = nil
	if offer.kind == "guaranteedRoll" then
		if #profile.keyboards >= GameConfig.InventoryCap then
			Remotes.Notify:FireClient(player, "error", "Inventory full — sell some keyboards first!")
			return
		end
		local tier = rollGuaranteedTier(profile, offer.tierFloor or 1)
		crateKeyboardId = pickKeyboardInTier(tier)
		if crateKeyboardId == nil then
			return -- no keyboard exists in that tier (bad config): don't charge
		end
	end

	if not EconomyService.SpendMoney(player, cost) then
		Remotes.Notify:FireClient(player, "error", `Not enough cash — that costs ${EconomyService.Abbreviate(cost)}!`)
		return
	end

	slot.stockLeft -= 1
	local now = os.time()

	if offer.kind == "guaranteedRoll" then
		local event = getActiveEvent()
		local mutationMult = if event then event.mutationMult else 1
		local charmMult = RestockShopService.ConsumeCharm(player)
		if charmMult ~= nil then
			mutationMult *= charmMult
		end
		local mutation = RollLogic.RollMutation(rng, mutationMult)
		-- AddKeyboard does the MarkDirty + Sync + KeyboardCollected + flex.
		local instance = InventoryService.AddKeyboard(player, crateKeyboardId :: string, "crate", mutation)
		if instance == nil then
			-- Undeliverable after all (defensive; nothing yields above): refund.
			EconomyService.AddMoney(player, cost)
			slot.stockLeft += 1
			return
		end
	elseif offer.kind == "luckSurge" then
		profile.boosts["restock_luck"] = now + (offer.duration or 0)
		DataService.MarkDirty(player)
		DataService.Sync(player)
		local minutes = math.floor((offer.duration or 0) / 60)
		Remotes.Notify:FireClient(player, "info", `{offer.name}: +{offer.luckBonus or 0} luck for {minutes} minutes!`)
	elseif offer.kind == "mutationCharm" then
		profile.boosts["mutation_charm"] = now + CHARM_BOOST_SECONDS
		charms[player] = { mult = offer.mutationMult or 1, rollsLeft = offer.charmRolls or 0 }
		DataService.MarkDirty(player)
		DataService.Sync(player)
		Remotes.Notify:FireClient(
			player,
			"info",
			`{offer.name}: {offer.mutationMult or 1}x mutation chance on your next {offer.charmRolls or 0} rolls!`
		)
	elseif offer.kind == "instantCash" then
		local payout = cost * (offer.cashMult or 0)
		EconomyService.AddMoney(player, payout)
		Remotes.Notify:FireClient(player, "info", `{offer.name} paid out ${EconomyService.Abbreviate(payout)}!`)
	else
		-- Unknown offer kind (bad config): undo the sale.
		EconomyService.AddMoney(player, cost)
		slot.stockLeft += 1
		warn(`[RestockShopService] Unknown offer kind "{offer.kind}" for offer "{offer.id}"`)
		return
	end

	broadcastSync() -- stockLeft changed for everyone
end

-- ===== Public API =====

-- Returns the active Mutation Charm's chance multiplier and consumes one of
-- its rolls; nil when no charm (or no rolls) remain. One call = one roll.
function RestockShopService.ConsumeCharm(player: Player): number?
	local charm = charms[player]
	if charm == nil then
		return nil
	end
	if charm.rollsLeft <= 0 then
		charms[player] = nil
		return nil
	end
	charm.rollsLeft -= 1
	if charm.rollsLeft <= 0 then
		charms[player] = nil -- this was the last charmed roll (still boosted)
	end
	return charm.mult
end

-- ===== Lifecycle =====

function RestockShopService.Init()
	-- Dependencies are wired via the module requires above.
end

function RestockShopService.Start()
	refreshCycle() -- stock the stall immediately

	Remotes.BuyRestockItem.OnServerEvent:Connect(onBuyRestockItem)

	DataService.OnProfileLoaded(function(player, _profile)
		if player.Parent ~= nil then
			Remotes.RestockSync:FireClient(player, buildSyncPayload())
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		charms[player] = nil
		buyTimestamps[player] = nil
	end)

	-- 1s heartbeat: flip cycles on the wall clock + tick the stall countdown.
	task.spawn(function()
		while true do
			refreshCycle()
			updateCountdown()
			task.wait(1)
		end
	end)
end

return RestockShopService
