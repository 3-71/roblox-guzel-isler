--!strict
-- Collection sets: the 36 discoverable keyboards partitioned into 6 themed
-- sets of 6 — every non-secret keyboard id appears in EXACTLY one set.
-- Once all 6 ids of a set are discovered (profile.collection[id] > 0),
-- SetsService auto-claims it into profile.setsClaimed and the luckBonus
-- applies permanently via RollLogic.GetEffectiveLuck. Secret keyboards
-- (Config/Keyboards `secret = true`) belong to no set.
-- Reverse lookup: Catalog.GetSet(keyboardId).

export type SetDef = {
	id: string,
	name: string,
	emoji: string, -- chip icon in the collection panel's sets strip
	keyboardIds: { string }, -- exactly 6 KeyboardDef ids
	luckBonus: number, -- permanent luck levels granted once claimed
}

local Sets: { SetDef } = {
	{
		-- Clearance-aisle clunkers: every board somebody fished out of a
		-- dumpster or paid a dollar for.
		id = "bargain_bin", name = "Bargain Bin", emoji = "🛒", luckBonus = 1,
		keyboardIds = { "soggy", "crumb", "dollar_store", "mushy", "clacky_jr", "squishy" },
	},
	{
		-- The nine-to-five grind, from the ancient beige box to the boardroom.
		id = "office_life", name = "Office Life", emoji = "💼", luckBonus = 1,
		keyboardIds = { "beige_brick", "office_drone", "slim_jim", "nine_to_five", "boardroom", "coffee_spill" },
	},
	{
		-- The enthusiast bench: typewriter ancestry, the blue/brown/red
		-- switch trio, a steel plate and hand-lubed switches.
		id = "switch_lab", name = "Switch Lab", emoji = "🔧", luckBonus = 1,
		keyboardIds = { "typewriter", "blueberry", "brown_bear", "red_linear", "steel_plate", "lubed_dream" },
	},
	{
		-- Living things and sweet natural beauty, capped by the northern lights.
		id = "garden_party", name = "Garden Party", emoji = "🌸", luckBonus = 1,
		keyboardIds = { "cricket", "creamsicle", "koi_pond", "sakura", "honeycomb", "aurora" },
	},
	{
		-- Raw destructive power: weather disasters, dragonfire and worse.
		id = "storm_fire", name = "Storm & Fire", emoji = "⚡", luckBonus = 1,
		keyboardIds = { "thunder", "avalanche", "wildfire", "dragonscale", "pulstar", "nuke" },
	},
	{
		-- Ghosts, whispers and impossible boards — the endgame shelf.
		id = "hall_of_legends", name = "Hall of Legends", emoji = "👑", luckBonus = 1,
		keyboardIds = { "gasket_ghost", "void_whisper", "halo", "the_thock", "glitch", "keyboard_zero" },
	},
}

return Sets
