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

return RollLogic
