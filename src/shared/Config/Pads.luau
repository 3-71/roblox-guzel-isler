--!strict
-- Every buy-pad on a plot. Classic tycoon: pads appear when their
-- prerequisite is owned, and buying one applies its effect + reveals
-- the next. ALL purchases in the game go through pads.
--
-- Pad kinds:
--   "factoryTier" - upgrades profile.upgrades.factoryTier to `level`
--   "conveyor"    - unlocks conveyor number `level` (1 is free/starting)
--   "speed"       - production speed level `level` (see GameConfig.SpeedMultPerLevel)
--   "luck"        - luck level `level` (see Shared.RollLogic)
--   "storage"     - offline storage cap level `level` (see GameConfig.StorageCapPerLevel)
--   "display"     - unlocks showcase display stand number `level`
--
-- Factory tier pad costs live in Config/FactoryTiers (single source of truth);
-- their `cost` here is -1 and resolved at runtime by PadService.
--
-- Physical pad positions on the plot are owned by server/World/PlotBuilder,
-- keyed by pad id.

export type PadDef = {
	id: string,
	kind: string,
	level: number,
	name: string,
	cost: number,
	prereq: string?, -- pad id that must be owned before this pad appears
}

local Pads: { PadDef } = {}

local function add(pad: PadDef)
	table.insert(Pads, pad)
end

-- Factory tier upgrades (2..12). Chain: each requires the previous.
for tier = 2, 12 do
	add({
		id = `factory_{tier}`,
		kind = "factoryTier",
		level = tier,
		name = `Factory Tier {tier}`,
		cost = -1, -- resolved from FactoryTiers[tier].padCost
		prereq = if tier == 2 then nil else `factory_{tier - 1}`,
	})
end

-- Extra conveyors (2..4). Gated behind factory progress so plots grow with you.
add({ id = "conveyor_2", kind = "conveyor", level = 2, name = "Conveyor 2", cost = 900, prereq = "factory_2" })
add({ id = "conveyor_3", kind = "conveyor", level = 3, name = "Conveyor 3", cost = 35_000, prereq = "factory_5" })
add({ id = "conveyor_4", kind = "conveyor", level = 4, name = "Conveyor 4", cost = 1_400_000, prereq = "factory_8" })

-- Production speed (1..10): each level = faster belts (multiplicative).
-- First level cheap so it's an early purchase (~minute 2).
local speedCosts = { 150, 800, 2_600, 8_500, 28_000, 95_000, 320_000, 1_100_000, 3_800_000, 13_000_000 }
for level, cost in speedCosts do
	add({
		id = `speed_{level}`,
		kind = "speed",
		level = level,
		name = `Speed {level}`,
		cost = cost,
		prereq = if level == 1 then "factory_2" else `speed_{level - 1}`,
	})
end

-- Luck (1..10): each level shifts the 30% luck component toward high tiers.
-- Luck 1 is cheap and unlocked early — teaching the luck axis in minute 2 is
-- the #1 lesson from My Knife Farm player guides (rarity is the emotional
-- core; players who ignore luck churn).
local luckCosts = { 200, 1_400, 4_800, 16_000, 55_000, 190_000, 650_000, 2_200_000, 7_500_000, 26_000_000 }
for level, cost in luckCosts do
	add({
		id = `luck_{level}`,
		kind = "luck",
		level = level,
		name = `Luck {level}`,
		cost = cost,
		prereq = if level == 1 then "factory_2" else `luck_{level - 1}`,
	})
end

-- Offline storage cap (1..5).
local storageCosts = { 1_000, 12_000, 140_000, 1_600_000, 18_000_000 }
for level, cost in storageCosts do
	add({
		id = `storage_{level}`,
		kind = "storage",
		level = level,
		name = `Storage {level}`,
		cost = cost,
		prereq = if level == 1 then "factory_2" else `storage_{level - 1}`,
	})
end

-- Plot walls (1..4): pure cosmetic prestige — each tier replaces the picket
-- fence with a grander wall (wood -> stone -> neon steel -> golden castle).
-- Like display stands, walls SURVIVE rebirth (RebirthService keeps the pads).
local wallCosts = { 2_500, 40_000, 900_000, 12_000_000 }
local wallNames = { "Wooden Walls", "Stone Walls", "Neon Walls", "Golden Castle Walls" }
for level, cost in wallCosts do
	add({
		id = `walls_{level}`,
		kind = "walls",
		level = level,
		name = wallNames[level],
		cost = cost,
		prereq = if level == 1 then "factory_2" else `walls_{level - 1}`,
	})
end

-- Showcase display stands (1..6): the flex shelf at the front of your plot.
local displayCosts = { 500, 5_000, 50_000, 500_000, 5_000_000, 50_000_000 }
for level, cost in displayCosts do
	add({
		id = `display_{level}`,
		kind = "display",
		level = level,
		name = `Display Stand {level}`,
		cost = cost,
		prereq = if level == 1 then nil else `display_{level - 1}`,
	})
end

-- Rebirth altar: repeatable (never marked owned), appears at the factory tier
-- set in GameConfig.Rebirth.RequiredFactoryTier. Cost is dynamic
-- (BaseCost * CostMult ^ rebirths) — resolved by RebirthService, so -2 here.
add({ id = "rebirth", kind = "rebirth", level = 1, name = "⟳ REBIRTH", cost = -2, prereq = "factory_6" })

return Pads
