--!strict
-- The 12 factory tiers. Your factory tier is the main progression spine:
-- it determines which rarities you can roll (the "70%" part of rolls),
-- multiplies sell value, and sets the look of your factory building.
--
-- padCost is the price of the buy-pad that upgrades you INTO this tier
-- (tier 1 is free / starting). Balancing lives here — tune freely.

export type FactoryTier = {
	tier: number,
	name: string,
	padCost: number,
	-- Highest rarity tier this factory can roll (clamped to 12).
	maxRarity: number,
	-- Sell-value multiplier applied to every keyboard sold while at this tier.
	valueMult: number,
	-- Base seconds between productions per conveyor (before speed upgrades).
	baseInterval: number,
	-- Accent color for the factory building / machine visuals.
	color: Color3,
}

local FactoryTiers: { FactoryTier } = {
	{ tier = 1, name = "Cardboard Workshop", padCost = 0, maxRarity = 2, valueMult = 1.0, baseInterval = 4.5, color = Color3.fromRGB(170, 140, 100) },
	{ tier = 2, name = "Garage Setup", padCost = 120, maxRarity = 3, valueMult = 1.3, baseInterval = 5.8, color = Color3.fromRGB(150, 150, 155) },
	{ tier = 3, name = "Backroom Bench", padCost = 550, maxRarity = 4, valueMult = 1.7, baseInterval = 5.6, color = Color3.fromRGB(124, 201, 84) },
	{ tier = 4, name = "Small Assembly", padCost = 2_400, maxRarity = 5, valueMult = 2.2, baseInterval = 5.4, color = Color3.fromRGB(64, 183, 173) },
	{ tier = 5, name = "Clack Factory", padCost = 10_000, maxRarity = 6, valueMult = 2.9, baseInterval = 5.2, color = Color3.fromRGB(72, 133, 237) },
	{ tier = 6, name = "Switch Works", padCost = 42_000, maxRarity = 7, valueMult = 3.8, baseInterval = 5.0, color = Color3.fromRGB(143, 94, 221) },
	{ tier = 7, name = "Custom Lab", padCost = 170_000, maxRarity = 8, valueMult = 5.0, baseInterval = 4.7, color = Color3.fromRGB(236, 112, 181) },
	{ tier = 8, name = "Artisan Atelier", padCost = 700_000, maxRarity = 9, valueMult = 6.5, baseInterval = 4.4, color = Color3.fromRGB(242, 152, 51) },
	{ tier = 9, name = "Thock Foundry", padCost = 2_900_000, maxRarity = 10, valueMult = 8.5, baseInterval = 4.1, color = Color3.fromRGB(250, 204, 60) },
	{ tier = 10, name = "Mythic Forge", padCost = 12_000_000, maxRarity = 11, valueMult = 11.0, baseInterval = 3.8, color = Color3.fromRGB(232, 61, 61) },
	{ tier = 11, name = "Celestial Plant", padCost = 50_000_000, maxRarity = 12, valueMult = 14.5, baseInterval = 3.5, color = Color3.fromRGB(170, 240, 255) },
	{ tier = 12, name = "The Keyboard Singularity", padCost = 210_000_000, maxRarity = 12, valueMult = 19.0, baseInterval = 3.2, color = Color3.fromRGB(24, 24, 30) },
}

return FactoryTiers
