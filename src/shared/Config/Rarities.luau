--!strict
-- The 12 rarity tiers of Grow a Keyboard, ordered worst -> best.
-- baseValue is the sell price of a keyboard in this tier BEFORE the
-- factory-tier value multiplier (see FactoryTiers.valueMult).

export type Rarity = {
	id: string,
	name: string,
	tier: number,
	color: Color3,
	baseValue: number,
	-- Visual flair on conveyor / display / notifications
	glow: boolean, -- emits light on the belt
	beam: boolean, -- celebration beam + server-wide flex feed when rolled
}

local Rarities: { Rarity } = {
	{ id = "scrap", name = "Scrap", tier = 1, color = Color3.fromRGB(125, 125, 125), baseValue = 3, glow = false, beam = false },
	{ id = "plastic", name = "Plastic", tier = 2, color = Color3.fromRGB(198, 198, 198), baseValue = 8, glow = false, beam = false },
	{ id = "membrane", name = "Membrane", tier = 3, color = Color3.fromRGB(124, 201, 84), baseValue = 21, glow = false, beam = false },
	{ id = "office", name = "Office", tier = 4, color = Color3.fromRGB(64, 183, 173), baseValue = 55, glow = false, beam = false },
	{ id = "clicky", name = "Clicky", tier = 5, color = Color3.fromRGB(72, 133, 237), baseValue = 145, glow = false, beam = false },
	{ id = "mechanical", name = "Mechanical", tier = 6, color = Color3.fromRGB(143, 94, 221), baseValue = 380, glow = true, beam = false },
	{ id = "custom", name = "Custom", tier = 7, color = Color3.fromRGB(236, 112, 181), baseValue = 1_000, glow = true, beam = false },
	{ id = "artisan", name = "Artisan", tier = 8, color = Color3.fromRGB(242, 152, 51), baseValue = 2_650, glow = true, beam = false },
	{ id = "legendary", name = "Legendary", tier = 9, color = Color3.fromRGB(250, 204, 60), baseValue = 7_000, glow = true, beam = true },
	{ id = "mythic", name = "Mythic", tier = 10, color = Color3.fromRGB(232, 61, 61), baseValue = 18_500, glow = true, beam = true },
	{ id = "godly", name = "Godly", tier = 11, color = Color3.fromRGB(170, 240, 255), baseValue = 49_000, glow = true, beam = true },
	{ id = "secret", name = "Secret", tier = 12, color = Color3.fromRGB(24, 24, 30), baseValue = 130_000, glow = true, beam = true },
}

return Rarities
