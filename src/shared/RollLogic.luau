--!strict
-- Pure rarity-roll math, shared by server (actual rolls) and client
-- (live odds display). The design rule from the game spec:
--   final odds = 70% factory-tier distribution + 30% luck distribution.
--
-- Factory distribution: exponential decay over rarities 1..maxRarity for
-- the current factory tier — most rolls are low tiers, the ceiling rises
-- as the factory upgrades.
-- Luck distribution: the same base weights, but each rarity is boosted
-- proportionally to (rarity - 1) * luckLevel, pushing mass toward the
-- high end without ever exceeding the factory's rarity ceiling.
--
-- Pity (GameConfig.Pity, disclosed in the odds panel): callers may pass the
-- player's rolls-since-last-TargetTier+ count as an optional trailing arg to
-- GetOdds / RollRarity / RollKeyboard. Past SoftStart, probability mass below
-- TargetTier shifts proportionally onto TargetTier+ (hard guarantee at
-- HardGuarantee rolls). When the factory's rarity ceiling is below TargetTier
-- pity is inert. Omitting the argument keeps the pre-pity behavior exactly.

local GameConfig = require(script.Parent.Config.GameConfig)
local FactoryTiers = require(script.Parent.Config.FactoryTiers)
local Rarities = require(script.Parent.Config.Rarities)
local Keyboards = require(script.Parent.Config.Keyboards)
local Mutations = require(script.Parent.Config.Mutations)
local IndexRewards = require(script.Parent.Config.IndexRewards)
local Products = require(script.Parent.Config.Products)

local RollLogic = {}

local function normalize(weights: { number }): { number }
	local total = 0
	for _, w in weights do
		total += w
	end
	local out = table.create(#weights, 0)
	if total <= 0 then
		out[1] = 1
		return out
	end
	for i, w in weights do
		out[i] = w / total
	end
	return out
end

local function baseWeights(maxRarity: number): { number }
	local weights = table.create(#Rarities, 0)
	for tier = 1, math.min(maxRarity, #Rarities) do
		local w = GameConfig.RarityDecay ^ (tier - 1)
		if tier == 12 then
			w *= GameConfig.SecretSuppression
		end
		weights[tier] = w
	end
	return weights
end

-- Applies the pity ramp to a normalized odds table IN PLACE (see header).
-- Total probability is preserved: below-TargetTier mass shrinks by `shift`
-- and the removed mass lands on TargetTier+ proportionally to current odds.
local function applyPity(odds: { number }, maxRarity: number, pityCount: number)
	local pity = GameConfig.Pity
	if maxRarity < pity.TargetTier then
		return -- ceiling below the pity target: pity is inert (contract)
	end

	local shift = math.clamp((pityCount - pity.SoftStart) * pity.RampPerRoll, 0, 1)
	if pityCount >= pity.HardGuarantee then
		shift = 1 -- hard guarantee: force tier >= TargetTier
	end
	if shift <= 0 then
		return
	end

	local below = 0
	local above = 0
	for tier, p in odds do
		if tier < pity.TargetTier then
			below += p
		else
			above += p
		end
	end
	if below <= 0 or above <= 0 then
		return -- nothing to move / nowhere to move it
	end

	local moved = below * shift
	for tier, p in odds do
		if tier < pity.TargetTier then
			odds[tier] = p * (1 - shift)
		else
			odds[tier] = p + moved * p / above
		end
	end
end

-- Returns normalized probabilities for rarity tiers 1..12. Optional pityCount
-- (rolls since the last TargetTier+ hit) engages bad-luck protection.
function RollLogic.GetOdds(factoryTier: number, luckLevel: number, pityCount: number?): { number }
	factoryTier = math.clamp(factoryTier, 1, #FactoryTiers)
	luckLevel = math.max(luckLevel, 0)

	local maxRarity = FactoryTiers[factoryTier].maxRarity
	local factoryDist = normalize(baseWeights(maxRarity))

	local luckWeights = baseWeights(maxRarity)
	for tier, w in luckWeights do
		luckWeights[tier] = w * (1 + luckLevel * GameConfig.LuckBoostPerLevel * (tier - 1))
	end
	local luckDist = normalize(luckWeights)

	local odds = table.create(#Rarities, 0)
	for tier = 1, #Rarities do
		odds[tier] = GameConfig.FactoryWeightShare * factoryDist[tier]
			+ GameConfig.LuckWeightShare * luckDist[tier]
	end

	if pityCount ~= nil then
		applyPity(odds, maxRarity, pityCount)
	end
	return odds
end

-- Rolls a rarity tier (1..12).
function RollLogic.RollRarity(factoryTier: number, luckLevel: number, rng: Random, pityCount: number?): number
	local odds = RollLogic.GetOdds(factoryTier, luckLevel, pityCount)
	local roll = rng:NextNumber()
	local cumulative = 0
	local lastPositive = 1
	for tier, p in odds do
		if p > 0 then
			lastPositive = tier
			cumulative += p
			if roll <= cumulative then
				return tier
			end
		end
	end
	-- Float rounding can leave the cumulative a hair under 1; falling back to
	-- the highest tier with real probability keeps the pity hard guarantee.
	return lastPositive
end

-- Rolls a full keyboard: rarity tier first, then uniform pick within tier.
-- Returns the keyboard's index into Config/Keyboards.
function RollLogic.RollKeyboard(factoryTier: number, luckLevel: number, rng: Random, pityCount: number?): number
	local tier = RollLogic.RollRarity(factoryTier, luckLevel, rng, pityCount)
	local candidates = {}
	for index, def in Keyboards do
		if def.rarityTier == tier then
			table.insert(candidates, index)
		end
	end
	if #candidates == 0 then
		return 1
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

-- Rolls a mutation (or nil). chanceMult scales every mutation's base chance
-- (events / boosts); total mutation probability is capped at 90%.
function RollLogic.RollMutation(rng: Random, chanceMult: number): string?
	chanceMult = math.max(chanceMult, 0)
	local total = 0
	for _, mutation in Mutations do
		total += mutation.chance * chanceMult
	end
	local cap = if total > 0.9 then 0.9 / total else 1
	local roll = rng:NextNumber()
	local cumulative = 0
	for _, mutation in Mutations do
		cumulative += mutation.chance * chanceMult * cap
		if roll <= cumulative then
			return mutation.id
		end
	end
	return nil
end

-- The hub stall's Luck Surge bonus (Config/RestockShop "luck_surge" offer),
-- resolved lazily on first use and cached. Lazy on purpose: RollLogic's
-- load-time requires stay unchanged for offline harnesses that stub module
-- resolution, and no roll ever pays the lookup unless the boost is active.
local restockLuckSurgeBonus: number? = nil
local function getRestockLuckSurgeBonus(): number
	local cached = restockLuckSurgeBonus
	if cached ~= nil then
		return cached
	end
	local bonus = 0
	local RestockShop = require(script.Parent.Config.RestockShop) :: { any }
	for _, offer in RestockShop do
		if offer.kind == "luckSurge" and typeof(offer.luckBonus) == "number" then
			bonus = offer.luckBonus
			break
		end
	end
	restockLuckSurgeBonus = bonus
	return bonus
end

-- The single source of truth for a player's total luck level. `profile` is a
-- Types.Profile (typed loosely to avoid a require cycle with consumers).
-- eventLuckBonus comes from the active server event (0 when none).
function RollLogic.GetEffectiveLuck(profile: any, now: number, eventLuckBonus: number): number
	local luck = profile.upgrades.luck

	local rebirths = profile.rebirths or 0
	luck += rebirths * GameConfig.Rebirth.LuckLevelsPerRebirth

	local claimed = profile.indexClaimed
	if claimed then
		for _, reward in IndexRewards do
			if claimed[reward.id] then
				luck += reward.luck
			end
		end
	end

	local boosts = profile.boosts
	if boosts then
		for key, expiry in boosts do
			if expiry > now then
				if key == "serverLuckParty" then
					-- granted to everyone when someone buys a Luck Party
					for _, product in Products.DevProducts do
						if product.key == "luckParty" then
							luck += product.serverLuckBonus or 0
						end
					end
				elseif key == "restock_luck" then
					-- hub stall Luck Surge (see Config/RestockShop)
					luck += getRestockLuckSurgeBonus()
				else
					for _, product in Products.DevProducts do
						if product.key == key then
							luck += product.luckBonus or 0
						end
					end
				end
			end
		end
	end

	-- Daily login streak: +LuckPerDay per consecutive day, capped.
	local streakDays = profile.streakDays or 0
	if streakDays > 0 then
		luck += math.min(streakDays * GameConfig.Streak.LuckPerDay, GameConfig.Streak.MaxLuckBonus)
	end

	if profile.passes and profile.passes.doubleLuck then
		luck *= 2
	end

	return luck + eventLuckBonus
end

return RollLogic
