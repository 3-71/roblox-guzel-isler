--!strict
-- Thock Buddies: earnable critters that perch on your conveyor, polish the
-- keyboards that ride past (a small mutation-chance bonus) and follow you
-- around the hub. NEVER sold for Robux and never random — every buddy states
-- exactly how to earn it (see BuddyService.CheckUnlocks for the earn kinds).
--
-- perk.mutationBonus is ADDED to the mutation chanceMult while the buddy is
-- equipped (ProductionService asks BuddyService.GetMutationBonus).

export type BuddyEarn = {
	kind: string, -- "streak" | "raceWins" | "bossWins" | "sets" | "rebirths" | "likesGiven"
	count: number,
	label: string, -- shown in the buddy panel ("Win 3 typing races")
}

export type BuddyDef = {
	id: string,
	name: string,
	emoji: string,
	bodyColor: Color3,
	accentColor: Color3,
	perk: { mutationBonus: number },
	earn: BuddyEarn,
}

local Buddies: { BuddyDef } = {
	{
		id = "crumb",
		name = "Crumb",
		emoji = "🐹",
		bodyColor = Color3.fromRGB(222, 184, 135),
		accentColor = Color3.fromRGB(255, 240, 210),
		perk = { mutationBonus = 0.10 },
		earn = { kind = "streak", count = 7, label = "Reach a 7-day login streak" },
	},
	{
		id = "sparky",
		name = "Sparky",
		emoji = "⚡",
		bodyColor = Color3.fromRGB(120, 130, 150),
		accentColor = Color3.fromRGB(255, 224, 130),
		perk = { mutationBonus = 0.15 },
		earn = { kind = "raceWins", count = 3, label = "Win 3 typing races" },
	},
	{
		id = "frosty",
		name = "Frosty",
		emoji = "🐧",
		bodyColor = Color3.fromRGB(40, 48, 66),
		accentColor = Color3.fromRGB(160, 220, 255),
		perk = { mutationBonus = 0.20 },
		earn = { kind = "bossWins", count = 3, label = "Help defeat the THOCK MONSTER 3 times" },
	},
	{
		id = "karl",
		name = "Keycap Karl",
		emoji = "🧢",
		bodyColor = Color3.fromRGB(236, 232, 224),
		accentColor = Color3.fromRGB(96, 152, 255),
		perk = { mutationBonus = 0.15 },
		earn = { kind = "sets", count = 1, label = "Complete any collection set" },
	},
	{
		id = "phoenix",
		name = "Phoenix",
		emoji = "🐦",
		bodyColor = Color3.fromRGB(255, 120, 60),
		accentColor = Color3.fromRGB(255, 200, 60),
		perk = { mutationBonus = 0.25 },
		earn = { kind = "rebirths", count = 3, label = "Rebirth 3 times" },
	},
	{
		id = "goldie",
		name = "Goldie",
		emoji = "🐝",
		bodyColor = Color3.fromRGB(255, 200, 60),
		accentColor = Color3.fromRGB(60, 50, 30),
		perk = { mutationBonus = 0.10 },
		earn = { kind = "likesGiven", count = 30, label = "Give 30 likes to other farms" },
	},
}

return Buddies
