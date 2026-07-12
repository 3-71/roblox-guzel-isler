--!strict
-- Lookup helpers over the config tables. Use these instead of re-scanning
-- the config arrays.

local Rarities = require(script.Parent.Config.Rarities)
local Keyboards = require(script.Parent.Config.Keyboards)
local FactoryTiers = require(script.Parent.Config.FactoryTiers)
local Pads = require(script.Parent.Config.Pads)
local Mutations = require(script.Parent.Config.Mutations)
local Sets = require(script.Parent.Config.Sets)
local GameConfig = require(script.Parent.Config.GameConfig)

local Catalog = {}

local keyboardById: { [string]: typeof(Keyboards[1]) } = {}
local discoverableCount = 0
for _, def in Keyboards do
	keyboardById[def.id] = def
	if not def.secret then
		discoverableCount += 1
	end
end

local padById: { [string]: typeof(Pads[1]) } = {}
for _, pad in Pads do
	padById[pad.id] = pad
end

local setByKeyboardId: { [string]: typeof(Sets[1]) } = {}
for _, set in Sets do
	for _, keyboardId in set.keyboardIds do
		setByKeyboardId[keyboardId] = set
	end
end

function Catalog.GetKeyboard(id: string): typeof(Keyboards[1])?
	return keyboardById[id]
end

function Catalog.GetRarity(tier: number): typeof(Rarities[1])?
	return Rarities[tier]
end

function Catalog.GetFactoryTier(tier: number): typeof(FactoryTiers[1])?
	return FactoryTiers[tier]
end

function Catalog.GetPad(id: string): typeof(Pads[1])?
	return padById[id]
end

-- Resolves a pad's real cost (factoryTier pads defer to FactoryTiers).
function Catalog.GetPadCost(id: string): number?
	local pad = padById[id]
	if not pad then
		return nil
	end
	if pad.kind == "factoryTier" then
		local ft = FactoryTiers[pad.level]
		return if ft then ft.padCost else nil
	end
	return pad.cost
end

function Catalog.GetMutation(id: string?): typeof(Mutations[1])?
	if not id then
		return nil
	end
	for _, mutation in Mutations do
		if mutation.id == id then
			return mutation
		end
	end
	return nil
end

-- The Aging stage a displayed keyboard has reached: the HIGHEST stage whose
-- `seconds` threshold ageSeconds has passed (see GameConfig.Aging.Stages).
-- nil below the first threshold, or when ageSeconds is nil (never displayed).
function Catalog.GetAgeStage(ageSeconds: number?): typeof(GameConfig.Aging.Stages[1])?
	if not ageSeconds then
		return nil
	end
	local reached: typeof(GameConfig.Aging.Stages[1])? = nil
	for _, stage in GameConfig.Aging.Stages do
		if ageSeconds >= stage.seconds then
			reached = stage
		end
	end
	return reached
end

-- The collection set containing this keyboard (see Config/Sets). nil for
-- secret keyboards — they belong to no set.
function Catalog.GetSet(keyboardId: string): typeof(Sets[1])?
	return setByKeyboardId[keyboardId]
end

-- Non-secret keyboard count: the denominator of the collection book's
-- "N/36" header (secret boards render in their own row).
function Catalog.CountDiscoverable(): number
	return discoverableCount
end

-- Sell value of one keyboard for a player at the given factory tier.
-- mutation (MutationDef id), rebirths, fusion stars and display-aging
-- ageSeconds are optional multipliers; every nil is skipped, so pre-phase-4
-- call sites behave identically.
function Catalog.GetSellValue(keyboardId: string, factoryTier: number, mutation: string?, rebirths: number?, stars: number?, ageSeconds: number?): number
	local def = keyboardById[keyboardId]
	if not def then
		return 0
	end
	local rarity = Rarities[def.rarityTier]
	local ft = FactoryTiers[math.clamp(factoryTier, 1, #FactoryTiers)]
	local value = rarity.baseValue * ft.valueMult

	local mutationDef = Catalog.GetMutation(mutation)
	if mutationDef then
		value *= mutationDef.valueMult
	end
	if rebirths and rebirths > 0 then
		value *= 1 + rebirths * GameConfig.Rebirth.ValueBonusPerRebirth
	end
	if stars and stars > 0 then
		value *= GameConfig.Fusion.ValueMultPerStar ^ stars
	end
	local ageStage = Catalog.GetAgeStage(ageSeconds)
	if ageStage then
		value *= ageStage.valueMult
	end
	return math.floor(value)
end

return Catalog
