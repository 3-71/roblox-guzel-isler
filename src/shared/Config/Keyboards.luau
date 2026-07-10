--!strict
-- All 36 named collectible keyboards: 3 per rarity tier.
-- A production roll first picks a rarity (see Shared.RollLogic), then a
-- uniform-random keyboard within that tier.
--
-- `sound` describes the keyboard's signature key-press. Layers play together;
-- `jitter` is random +/- playbackSpeed variation per press so typing feels
-- organic. The placeholder soundIds below are engine built-ins guaranteed to
-- exist; the sound-design pass replaces/augments them per personality.
--
-- `look` drives the procedural low-poly model (Shared/World builders):
-- body/keycap colors + an accent style tag.

export type SoundLayer = {
	soundId: string,
	playbackSpeed: number,
	volume: number,
}

export type KeyboardDef = {
	id: string,
	name: string,
	rarityTier: number, -- 1..12, index into Config/Rarities
	flavor: string,
	sound: {
		layers: { SoundLayer },
		jitter: number,
	},
	look: {
		bodyColor: Color3,
		keycapColor: Color3,
		accentColor: Color3,
		style: string, -- "plain" | "retro" | "slim" | "chunky" | "split" | "crystal"
	},
}

local PING = "rbxasset://sounds/electronicpingshort.wav"

local function sound(playbackSpeed: number, volume: number): { layers: { SoundLayer }, jitter: number }
	return { layers = { { soundId = PING, playbackSpeed = playbackSpeed, volume = volume } }, jitter = 0.05 }
end

local Keyboards: { KeyboardDef } = {
	-- ============ Tier 1: Scrap ============
	{
		id = "soggy", name = "Soggy", rarityTier = 1,
		flavor = "Found in a dumpster. Smells like regret.",
		sound = sound(0.55, 0.4),
		look = { bodyColor = Color3.fromRGB(105, 100, 95), keycapColor = Color3.fromRGB(140, 135, 125), accentColor = Color3.fromRGB(90, 85, 80), style = "plain" },
	},
	{
		id = "crumb", name = "Crumb", rarityTier = 1,
		flavor = "There are chips under every single key. Not the good kind.",
		sound = sound(0.6, 0.4),
		look = { bodyColor = Color3.fromRGB(120, 115, 105), keycapColor = Color3.fromRGB(150, 145, 130), accentColor = Color3.fromRGB(170, 150, 90), style = "plain" },
	},
	{
		id = "beige_brick", name = "Beige Brick", rarityTier = 1,
		flavor = "Older than the internet. Heavier than your backpack.",
		sound = sound(0.5, 0.45),
		look = { bodyColor = Color3.fromRGB(190, 180, 155), keycapColor = Color3.fromRGB(210, 200, 175), accentColor = Color3.fromRGB(160, 150, 130), style = "retro" },
	},

	-- ============ Tier 2: Plastic ============
	{
		id = "dollar_store", name = "Dollar Store", rarityTier = 2,
		flavor = "You get what you pay for. You paid one dollar.",
		sound = sound(0.7, 0.45),
		look = { bodyColor = Color3.fromRGB(200, 200, 205), keycapColor = Color3.fromRGB(230, 230, 235), accentColor = Color3.fromRGB(255, 90, 90), style = "plain" },
	},
	{
		id = "mushy", name = "Mushy", rarityTier = 2,
		flavor = "Pressing a key feels like poking a marshmallow.",
		sound = sound(0.65, 0.4),
		look = { bodyColor = Color3.fromRGB(215, 205, 220), keycapColor = Color3.fromRGB(240, 235, 245), accentColor = Color3.fromRGB(200, 160, 220), style = "chunky" },
	},
	{
		id = "clacky_jr", name = "Clacky Jr.", rarityTier = 2,
		flavor = "It's trying its best, okay?",
		sound = sound(0.85, 0.5),
		look = { bodyColor = Color3.fromRGB(235, 235, 240), keycapColor = Color3.fromRGB(90, 90, 100), accentColor = Color3.fromRGB(80, 160, 255), style = "slim" },
	},

	-- ============ Tier 3: Membrane ============
	{
		id = "office_drone", name = "Office Drone", rarityTier = 3,
		flavor = "Has typed 4 million emails. Feels every single one.",
		sound = sound(0.75, 0.5),
		look = { bodyColor = Color3.fromRGB(60, 62, 68), keycapColor = Color3.fromRGB(95, 98, 105), accentColor = Color3.fromRGB(124, 201, 84), style = "plain" },
	},
	{
		id = "slim_jim", name = "Slim Jim", rarityTier = 3,
		flavor = "So flat it's basically a placemat.",
		sound = sound(1.0, 0.45),
		look = { bodyColor = Color3.fromRGB(220, 222, 228), keycapColor = Color3.fromRGB(245, 246, 250), accentColor = Color3.fromRGB(124, 201, 84), style = "slim" },
	},
	{
		id = "squishy", name = "Squishy", rarityTier = 3,
		flavor = "Water resistant. Sadness resistant. Nothing else resistant.",
		sound = sound(0.7, 0.5),
		look = { bodyColor = Color3.fromRGB(110, 190, 110), keycapColor = Color3.fromRGB(150, 220, 150), accentColor = Color3.fromRGB(60, 140, 70), style = "chunky" },
	},

	-- ============ Tier 4: Office ============
	{
		id = "nine_to_five", name = "Nine-to-Five", rarityTier = 4,
		flavor = "Clocks in, clacks out.",
		sound = sound(0.9, 0.55),
		look = { bodyColor = Color3.fromRGB(50, 55, 65), keycapColor = Color3.fromRGB(200, 205, 215), accentColor = Color3.fromRGB(64, 183, 173), style = "plain" },
	},
	{
		id = "boardroom", name = "Boardroom", rarityTier = 4,
		flavor = "Per my last email: clack.",
		sound = sound(0.95, 0.55),
		look = { bodyColor = Color3.fromRGB(40, 42, 50), keycapColor = Color3.fromRGB(70, 75, 85), accentColor = Color3.fromRGB(64, 183, 173), style = "slim" },
	},
	{
		id = "coffee_spill", name = "Coffee Spill", rarityTier = 4,
		flavor = "Three keys are sticky. It types faster anyway.",
		sound = sound(0.8, 0.55),
		look = { bodyColor = Color3.fromRGB(120, 85, 60), keycapColor = Color3.fromRGB(180, 140, 100), accentColor = Color3.fromRGB(90, 60, 40), style = "retro" },
	},

	-- ============ Tier 5: Clicky ============
	{
		id = "blueberry", name = "Blueberry", rarityTier = 5,
		flavor = "Loud. Proud. Banned in three libraries.",
		sound = sound(1.1, 0.6),
		look = { bodyColor = Color3.fromRGB(50, 90, 190), keycapColor = Color3.fromRGB(110, 155, 245), accentColor = Color3.fromRGB(255, 255, 255), style = "chunky" },
	},
	{
		id = "cricket", name = "Cricket", rarityTier = 5,
		flavor = "Chirps at night. Nobody knows why.",
		sound = sound(1.25, 0.55),
		look = { bodyColor = Color3.fromRGB(70, 120, 60), keycapColor = Color3.fromRGB(130, 180, 110), accentColor = Color3.fromRGB(230, 240, 160), style = "slim" },
	},
	{
		id = "typewriter", name = "Typewriter", rarityTier = 5,
		flavor = "Ding! Carriage return not included.",
		sound = sound(0.9, 0.65),
		look = { bodyColor = Color3.fromRGB(35, 35, 38), keycapColor = Color3.fromRGB(235, 230, 215), accentColor = Color3.fromRGB(180, 40, 40), style = "retro" },
	},

	-- ============ Tier 6: Mechanical ============
	{
		id = "brown_bear", name = "Brown Bear", rarityTier = 6,
		flavor = "Tactile bump like a bear's paw. Gentle but firm.",
		sound = sound(0.85, 0.65),
		look = { bodyColor = Color3.fromRGB(110, 75, 50), keycapColor = Color3.fromRGB(160, 120, 85), accentColor = Color3.fromRGB(143, 94, 221), style = "chunky" },
	},
	{
		id = "red_linear", name = "Red Linear", rarityTier = 6,
		flavor = "Smooth all the way down. Gamers rejoice.",
		sound = sound(1.0, 0.6),
		look = { bodyColor = Color3.fromRGB(30, 30, 35), keycapColor = Color3.fromRGB(55, 55, 62), accentColor = Color3.fromRGB(235, 60, 60), style = "slim" },
	},
	{
		id = "steel_plate", name = "Steel Plate", rarityTier = 6,
		flavor = "Could stop a snowball. Sounds like a vault door.",
		sound = sound(0.7, 0.7),
		look = { bodyColor = Color3.fromRGB(140, 145, 155), keycapColor = Color3.fromRGB(180, 185, 195), accentColor = Color3.fromRGB(143, 94, 221), style = "chunky" },
	},

	-- ============ Tier 7: Custom ============
	{
		id = "lubed_dream", name = "Lubed Dream", rarityTier = 7,
		flavor = "Hand-lubed switches. Sounds like butter feels.",
		sound = sound(0.8, 0.7),
		look = { bodyColor = Color3.fromRGB(245, 240, 235), keycapColor = Color3.fromRGB(255, 250, 245), accentColor = Color3.fromRGB(236, 112, 181), style = "slim" },
	},
	{
		id = "gasket_ghost", name = "Gasket Ghost", rarityTier = 7,
		flavor = "So quiet it's barely there. Then suddenly: thock.",
		sound = sound(0.65, 0.65),
		look = { bodyColor = Color3.fromRGB(225, 230, 240), keycapColor = Color3.fromRGB(250, 252, 255), accentColor = Color3.fromRGB(160, 170, 200), style = "crystal" },
	},
	{
		id = "creamsicle", name = "Creamsicle", rarityTier = 7,
		flavor = "Orange cream keycaps. Do not lick.",
		sound = sound(0.9, 0.7),
		look = { bodyColor = Color3.fromRGB(255, 170, 90), keycapColor = Color3.fromRGB(255, 245, 225), accentColor = Color3.fromRGB(236, 112, 181), style = "chunky" },
	},

	-- ============ Tier 8: Artisan ============
	{
		id = "koi_pond", name = "Koi Pond", rarityTier = 8,
		flavor = "Every keycap is a tiny pond. The koi are hand-painted.",
		sound = sound(0.75, 0.7),
		look = { bodyColor = Color3.fromRGB(50, 110, 160), keycapColor = Color3.fromRGB(120, 190, 220), accentColor = Color3.fromRGB(242, 152, 51), style = "crystal" },
	},
	{
		id = "sakura", name = "Sakura", rarityTier = 8,
		flavor = "Types in cherry blossom petals.",
		sound = sound(1.05, 0.65),
		look = { bodyColor = Color3.fromRGB(250, 215, 225), keycapColor = Color3.fromRGB(255, 240, 245), accentColor = Color3.fromRGB(230, 120, 150), style = "slim" },
	},
	{
		id = "honeycomb", name = "Honeycomb", rarityTier = 8,
		flavor = "Sweet to type on. Attracts bees.",
		sound = sound(0.95, 0.7),
		look = { bodyColor = Color3.fromRGB(240, 180, 60), keycapColor = Color3.fromRGB(255, 215, 110), accentColor = Color3.fromRGB(120, 80, 30), style = "chunky" },
	},

	-- ============ Tier 9: Legendary ============
	{
		id = "thunder", name = "Thunder", rarityTier = 9,
		flavor = "Every keystroke is a distant storm rolling in.",
		sound = sound(0.45, 0.85),
		look = { bodyColor = Color3.fromRGB(45, 50, 70), keycapColor = Color3.fromRGB(90, 100, 140), accentColor = Color3.fromRGB(250, 220, 80), style = "chunky" },
	},
	{
		id = "avalanche", name = "Avalanche", rarityTier = 9,
		flavor = "A rumble that buries entire sentences.",
		sound = sound(0.5, 0.85),
		look = { bodyColor = Color3.fromRGB(230, 240, 250), keycapColor = Color3.fromRGB(255, 255, 255), accentColor = Color3.fromRGB(140, 200, 255), style = "crystal" },
	},
	{
		id = "wildfire", name = "Wildfire", rarityTier = 9,
		flavor = "Types so fast the keycaps singe.",
		sound = sound(1.3, 0.8),
		look = { bodyColor = Color3.fromRGB(180, 60, 30), keycapColor = Color3.fromRGB(255, 130, 50), accentColor = Color3.fromRGB(255, 220, 90), style = "chunky" },
	},

	-- ============ Tier 10: Mythic ============
	{
		id = "pulstar", name = "Pulstar", rarityTier = 10,
		flavor = "Fires a laser pulse with every key. Pew.",
		sound = sound(1.5, 0.85),
		look = { bodyColor = Color3.fromRGB(25, 25, 45), keycapColor = Color3.fromRGB(70, 220, 255), accentColor = Color3.fromRGB(255, 80, 200), style = "crystal" },
	},
	{
		id = "void_whisper", name = "Void Whisper", rarityTier = 10,
		flavor = "You don't press its keys. It presses yours.",
		sound = sound(0.35, 0.8),
		look = { bodyColor = Color3.fromRGB(15, 12, 25), keycapColor = Color3.fromRGB(40, 30, 60), accentColor = Color3.fromRGB(150, 60, 255), style = "crystal" },
	},
	{
		id = "dragonscale", name = "Dragonscale", rarityTier = 10,
		flavor = "Forged from shed scales. Warm to the touch.",
		sound = sound(0.6, 0.9),
		look = { bodyColor = Color3.fromRGB(120, 20, 25), keycapColor = Color3.fromRGB(200, 60, 50), accentColor = Color3.fromRGB(255, 190, 70), style = "chunky" },
	},

	-- ============ Tier 11: Godly ============
	{
		id = "nuke", name = "Nuke", rarityTier = 11,
		flavor = "Every keystroke is a controlled detonation. Mostly controlled.",
		sound = sound(0.3, 1.0),
		look = { bodyColor = Color3.fromRGB(60, 65, 50), keycapColor = Color3.fromRGB(200, 210, 120), accentColor = Color3.fromRGB(255, 240, 100), style = "chunky" },
	},
	{
		id = "halo", name = "Halo", rarityTier = 11,
		flavor = "A choir hums softly beneath the keys.",
		sound = sound(1.2, 0.9),
		look = { bodyColor = Color3.fromRGB(250, 250, 255), keycapColor = Color3.fromRGB(255, 255, 255), accentColor = Color3.fromRGB(255, 230, 140), style = "crystal" },
	},
	{
		id = "aurora", name = "Aurora", rarityTier = 11,
		flavor = "The northern lights, bottled into keycaps.",
		sound = sound(1.0, 0.9),
		look = { bodyColor = Color3.fromRGB(30, 50, 70), keycapColor = Color3.fromRGB(120, 255, 200), accentColor = Color3.fromRGB(180, 130, 255), style = "crystal" },
	},

	-- ============ Tier 12: Secret ============
	{
		id = "the_thock", name = "THE THOCK", rarityTier = 12,
		flavor = "The perfect sound. Keyboard scientists wept.",
		sound = sound(0.5, 1.0),
		look = { bodyColor = Color3.fromRGB(20, 20, 24), keycapColor = Color3.fromRGB(35, 35, 42), accentColor = Color3.fromRGB(255, 215, 120), style = "chunky" },
	},
	{
		id = "glitch", name = "Glitch", rarityTier = 12,
		flavor = "S̷o̷u̷n̷d̷s̷ different every time. Should not exist.",
		sound = { layers = { { soundId = PING, playbackSpeed = 1.0, volume = 0.9 } }, jitter = 0.6 },
		look = { bodyColor = Color3.fromRGB(10, 10, 12), keycapColor = Color3.fromRGB(0, 255, 140), accentColor = Color3.fromRGB(255, 0, 90), style = "crystal" },
	},
	{
		id = "keyboard_zero", name = "Keyboard Zero", rarityTier = 12,
		flavor = "The first keyboard ever made. Or the last. Records disagree.",
		sound = sound(0.4, 1.0),
		look = { bodyColor = Color3.fromRGB(240, 235, 220), keycapColor = Color3.fromRGB(30, 30, 30), accentColor = Color3.fromRGB(200, 170, 90), style = "retro" },
	},
}

return Keyboards
