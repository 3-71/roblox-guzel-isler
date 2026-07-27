--!strict
-- Mutations: rare modifiers rolled ON TOP of a keyboard's rarity.
-- A mutated keyboard keeps its identity but multiplies sell value, tints the
-- model, and warps the sound. `chance` values are absolute probabilities per
-- roll (the remainder is "no mutation"); events/gamepasses scale them via the
-- chanceMult argument of RollLogic.RollMutation.

export type MutationDef = {
	id: string,
	name: string,
	chance: number, -- base probability per roll
	valueMult: number, -- sell value multiplier
	tint: Color3, -- blended over body/keycap colors
	rainbow: boolean, -- animated rainbow shimmer (client-side)
	soundPitchMult: number, -- multiplies every sound layer's playbackSpeed
	extraJitter: number, -- added to the sound spec's jitter
}

local Mutations: { MutationDef } = {
	{ id = "vintage", name = "Vintage", chance = 0.05, valueMult = 3, tint = Color3.fromRGB(200, 175, 135), rainbow = false, soundPitchMult = 0.9, extraJitter = 0.02 },
	{ id = "golden", name = "Golden", chance = 0.04, valueMult = 5, tint = Color3.fromRGB(255, 200, 60), rainbow = false, soundPitchMult = 1.0, extraJitter = 0 },
	{ id = "lubed", name = "Lubed", chance = 0.02, valueMult = 8, tint = Color3.fromRGB(225, 238, 255), rainbow = false, soundPitchMult = 0.8, extraJitter = -0.02 },
	{ id = "holo", name = "Holo", chance = 0.008, valueMult = 12, tint = Color3.fromRGB(185, 130, 255), rainbow = true, soundPitchMult = 1.12, extraJitter = 0.03 },
	-- Frozen practically only drops during the Cold Snap event (its base
	-- chance is tiny; Cold Snap's mutationBias multiplies it 6x).
	{ id = "frozen", name = "Frozen", chance = 0.004, valueMult = 10, tint = Color3.fromRGB(160, 220, 255), rainbow = false, soundPitchMult = 1.3, extraJitter = -0.01 },
	{ id = "glitched", name = "Glitched", chance = 0.002, valueMult = 25, tint = Color3.fromRGB(0, 255, 140), rainbow = true, soundPitchMult = 1.0, extraJitter = 0.5 },
}

return Mutations
