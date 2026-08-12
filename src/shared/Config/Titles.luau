--!strict
-- Earnable titles + auras: a nameplate above your head and a particle aura
-- on your character. Pure flex — no gameplay stats. Every title states
-- exactly how it is earned; once earned it is stored on the profile forever
-- (stats like streaks may later dip below the threshold, the title stays).
--
-- aura kinds (TitleService renders these as ParticleEmitter presets):
--   "none" | "sparkle" | "gold" | "fire" | "hearts" | "storm" | "rainbow"
--
-- earn.kind -> profile stat (see TitleService.StatFor):
--   "rebirths" | "bossWins" | "raceWins" | "likesGiven" | "streakDays"
--   "sets" (# completed sets) | "unique" (# unique boards collected)
--   "earned" (total money ever earned) | "secrets" (# secret boards found)

export type TitleEarn = {
	kind: string,
	count: number,
	label: string, -- shown on locked cards ("Win 10 typing races")
}

export type TitleDef = {
	id: string,
	name: string,
	color: Color3, -- nameplate text color
	aura: string,
	earn: TitleEarn,
}

local Titles: { TitleDef } = {
	{
		id = "keyboard_kid",
		name = "Keyboard Kid",
		color = Color3.fromRGB(150, 206, 255),
		aura = "none",
		earn = { kind = "unique", count = 1, label = "Collect your first keyboard" },
	},
	{
		id = "dedicated",
		name = "Dedicated",
		color = Color3.fromRGB(164, 226, 154),
		aura = "none",
		earn = { kind = "streakDays", count = 7, label = "Reach a 7-day login streak" },
	},
	{
		id = "millionaire",
		name = "Millionaire",
		color = Color3.fromRGB(255, 224, 130),
		aura = "sparkle",
		earn = { kind = "earned", count = 1_000_000, label = "Earn $1M in total" },
	},
	{
		id = "collector",
		name = "Collector",
		color = Color3.fromRGB(96, 152, 255),
		aura = "sparkle",
		earn = { kind = "unique", count = 20, label = "Collect 20 different keyboards" },
	},
	{
		id = "wholesome",
		name = "Wholesome",
		color = Color3.fromRGB(255, 142, 202),
		aura = "hearts",
		earn = { kind = "likesGiven", count = 50, label = "Give 50 likes to other farms" },
	},
	{
		id = "speed_demon",
		name = "Speed Demon",
		color = Color3.fromRGB(255, 152, 74),
		aura = "storm",
		earn = { kind = "raceWins", count = 10, label = "Win 10 typing races" },
	},
	{
		id = "secret_keeper",
		name = "Secret Keeper",
		color = Color3.fromRGB(185, 130, 255),
		aura = "sparkle",
		earn = { kind = "secrets", count = 1, label = "Find any secret keyboard" },
	},
	{
		id = "monster_slayer",
		name = "Monster Slayer",
		color = Color3.fromRGB(255, 92, 92),
		aura = "fire",
		earn = { kind = "bossWins", count = 5, label = "Help defeat the THOCK MONSTER 5 times" },
	},
	{
		id = "set_master",
		name = "Set Master",
		color = Color3.fromRGB(112, 220, 122),
		aura = "sparkle",
		earn = { kind = "sets", count = 6, label = "Complete all 6 collection sets" },
	},
	{
		id = "tycoon",
		name = "Tycoon",
		color = Color3.fromRGB(255, 199, 68),
		aura = "gold",
		earn = { kind = "earned", count = 1_000_000_000, label = "Earn $1B in total" },
	},
	{
		id = "completionist",
		name = "Completionist",
		color = Color3.fromRGB(255, 245, 200),
		aura = "gold",
		earn = { kind = "unique", count = 36, label = "Collect all 36 rollable keyboards" },
	},
	{
		id = "thock_lord",
		name = "THOCK LORD",
		color = Color3.fromRGB(255, 205, 90),
		aura = "rainbow",
		earn = { kind = "rebirths", count = 5, label = "Rebirth 5 times" },
	},
}

return Titles
