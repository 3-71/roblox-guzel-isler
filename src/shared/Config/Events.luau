--!strict
-- Server-wide luck/mutation events ("weather"). EventService rolls one at a
-- random interval, sets Workspace attributes ActiveEventId/ActiveEventUntil,
-- and everything else (roll math, lighting, banners) reads those attributes.

export type EventDef = {
	id: string,
	name: string,
	tagline: string,
	duration: number, -- seconds
	luckBonus: number, -- added to effective luck for everyone
	mutationMult: number, -- multiplies all mutation chances
	mutationBias: { [string]: number }?, -- extra per-mutation-id multiplier (Cold Snap -> frozen x6)
	typingMult: number?, -- multiplies typing income while active (Overclocked)
	weight: number, -- selection weight
	sky: string, -- "storm" | "golden" | "frost" | "static" | "overclock" — client lighting preset
	color: Color3, -- banner color
}

local Events: { EventDef } = {
	{
		id = "thock_storm",
		name = "THOCK STORM",
		tagline = "The skies rumble... luck surges for everyone!",
		duration = 240,
		luckBonus = 5,
		mutationMult = 1.5,
		weight = 3,
		sky = "storm",
		color = Color3.fromRGB(120, 160, 255),
	},
	{
		id = "golden_hour",
		name = "GOLDEN HOUR",
		tagline = "Everything glimmers — mutation chances tripled!",
		duration = 240,
		luckBonus = 2,
		mutationMult = 3,
		weight = 2,
		sky = "golden",
		color = Color3.fromRGB(255, 200, 60),
	},
	{
		id = "cold_snap",
		name = "COLD SNAP",
		tagline = "Brrr... the only time FROZEN keyboards drop (x6)!",
		duration = 240,
		luckBonus = 1,
		mutationMult = 1,
		mutationBias = { frozen = 6 },
		weight = 2,
		sky = "frost",
		color = Color3.fromRGB(160, 220, 255),
	},
	{
		id = "static_surge",
		name = "STATIC SURGE",
		tagline = "⚡ GLITCHED chance x10 — drop everything and roll!",
		duration = 180,
		luckBonus = 0,
		mutationMult = 1,
		mutationBias = { glitched = 10 },
		weight = 1,
		sky = "static",
		color = Color3.fromRGB(0, 255, 140),
	},
	{
		id = "overclocked",
		name = "OVERCLOCKED",
		tagline = "Every keypress pays DOUBLE — type like the wind!",
		duration = 150,
		luckBonus = 3,
		mutationMult = 2,
		typingMult = 2,
		weight = 1,
		sky = "overclock",
		color = Color3.fromRGB(255, 120, 80),
	},
}

return Events
