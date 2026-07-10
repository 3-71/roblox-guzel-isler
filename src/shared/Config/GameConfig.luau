--!strict
-- Global tunables for Grow a Keyboard.

local GameConfig = {
	GameName = "Grow a Keyboard",

	-- ===== Plots =====
	PlotCount = 8, -- max players per server, one plot each
	PlotSize = 120, -- studs, square
	PlotSpacing = 40, -- gap between plots around the hub

	-- ===== Production =====
	-- Effective interval = FactoryTiers[tier].baseInterval * (SpeedMultPerLevel ^ speedLevel)
	SpeedMultPerLevel = 0.90, -- each speed level: 10% faster
	BeltRideSeconds = 4, -- how long a keyboard rides the belt before auto-collect
	MaxConveyors = 4,

	-- ===== Rolls (see Shared.RollLogic) =====
	FactoryWeightShare = 0.7, -- "70% tier"
	LuckWeightShare = 0.3, -- "30% luck"
	RarityDecay = 0.45, -- each rarity tier is ~2.2x rarer than the previous
	LuckBoostPerLevel = 0.12, -- how hard each luck level pushes toward high tiers
	SecretSuppression = 0.15, -- extra rarity multiplier on tier 12 (Secret) rolls

	-- ===== Inventory / storage =====
	InventoryCap = 400, -- hard cap on owned keyboards (bulk-sell exists!)
	OfflineCapBase = 20, -- offline production storage at storage level 0
	StorageCapPerLevel = { 40, 70, 110, 170, 250 }, -- offline cap at storage level 1..5
	OfflineMinSeconds = 120, -- ignore tiny hops between servers

	-- ===== Economy =====
	StartingMoney = 0,

	-- ===== Showcase =====
	MaxDisplayStands = 6,

	-- ===== Notifications =====
	-- Rolls at or above this rarity tier get a server-wide flex message.
	GlobalFlexMinTier = 9,
	-- Rolls at or above this tier get a local celebration (beam, big toast).
	CelebrateMinTier = 6,

	-- ===== Typing / sounds =====
	TypeRateLimitPerSecond = 10, -- server-side cap on TypeKeyRequest
	TypeSoundRange = 60, -- studs other players can hear your typing from

	-- ===== Data =====
	DataStoreName = "GrowAKeyboard_v1",
	AutoSaveSeconds = 60,
}

return GameConfig
