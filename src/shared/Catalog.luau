--!strict
-- Lookup helpers over the config tables. Use these instead of re-scanning
-- the config arrays.

local Rarities = require(script.Parent.Config.Rarities)
local Keyboards = require(script.Parent.Config.Keyboards)
local FactoryTiers = require(script.Parent.Config.FactoryTiers)
local Pads = require(script.Parent.Config.Pads)

local Catalog = {}

local keyboardById: { [string]: typeof(Keyboards[1]) } = {}
for _, def in Keyboards do
	keyboardById[def.id] = def
end

local padById: { [string]: typeof(Pads[1]) } = {}
for _, pad in Pads do
	padById[pad.id] = pad
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

-- Sell value of one keyboard for a player at the given factory tier.
function Catalog.GetSellValue(keyboardId: string, factoryTier: number): number
	local def = keyboardById[keyboardId]
	if not def then
		return 0
	end
	local rarity = Rarities[def.rarityTier]
	local ft = FactoryTiers[math.clamp(factoryTier, 1, #FactoryTiers)]
	return math.floor(rarity.baseValue * ft.valueMult)
end

return Catalog
