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

-- Returns normalized probabilities for rarity tiers 1..12.
function RollLogic.GetOdds(factoryTier: number, luckLevel: number): { number }
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
	return odds
end

-- Rolls a rarity tier (1..12).
function RollLogic.RollRarity(factoryTier: number, luckLevel: number, rng: Random): number
	local odds = RollLogic.GetOdds(factoryTier, luckLevel)
	local roll = rng:NextNumber()
	local cumulative = 0
	for tier, p in odds do
		cumulative += p
		if roll <= cumulative then
			return tier
		end
	end
	return 1
end

-- Rolls a full keyboard: rarity tier first, then uniform pick within tier.
-- Returns the keyboard's index into Config/Keyboards.
function RollLogic.RollKeyboard(factoryTier: number, luckLevel: number, rng: Random): number
	local tier = RollLogic.RollRarity(factoryTier, luckLevel, rng)
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

	if profile.passes and profile.passes.doubleLuck then
		luck *= 2
	end

	return luck + eventLuckBonus
end

return RollLogic
