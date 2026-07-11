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
	weight: number, -- selection weight
	sky: string, -- "storm" | "golden" — client lighting preset
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
}

return Events
