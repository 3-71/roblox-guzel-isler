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
	-- Research-tuned: first buy-pad should be reachable within ~30-45s of
	-- spawning (players decide to stay in minutes 1-5).
	StartingMoney = 60,

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
	EquipRateLimitPerSecond = 4, -- server-side cap on EquipRequest
	DisplayRateLimitPerSecond = 3, -- server-side cap on DisplayRequest

	-- ===== Data =====
	DataStoreName = "GrowAKeyboard_v1",
	AutoSaveSeconds = 60,

	-- ===== Rebirth =====
	-- Research-tuned: first prestige should land in a focused first session
	-- (45-90 min), so it unlocks at tier 6; tier 12 is a multi-rebirth goal.
	Rebirth = {
		RequiredFactoryTier = 6,
		BaseCost = 200_000,
		CostMult = 3.0, -- cost = BaseCost * CostMult ^ rebirths
		ValueBonusPerRebirth = 0.25, -- +25% sell value per rebirth, permanent
		LuckLevelsPerRebirth = 1,
	},

	-- ===== Events (see Config/Events) =====
	EventMinInterval = 480, -- seconds between event rolls
	EventMaxInterval = 900,

	-- ===== Typing race =====
	Race = {
		IntervalSeconds = 360, -- time between races
		JoinWindowSeconds = 15,
		DurationSeconds = 30,
		BaseReward = 2_500, -- scaled by winner's factory tier
	},

	-- ===== Leaderboards =====
	LeaderboardRefreshSeconds = 60,
	LeaderboardSize = 25,

	-- ===== Pity (bad-luck protection; disclosed in the odds panel) =====
	Pity = {
		TargetTier = 7, -- an Epic+ ("custom" tier) roll resets the counter
		SoftStart = 50, -- rolls without TargetTier+ before odds start ramping
		RampPerRoll = 0.02, -- extra share moved to TargetTier+ per roll past SoftStart
		HardGuarantee = 80, -- roll number at which TargetTier+ is guaranteed
	},

	-- ===== Friends-in-server bonus =====
	FriendBonusPerFriend = 0.10, -- +10% sell value per friend in the server
	FriendBonusCap = 0.40,

	-- ===== Hub restock stall (see Config/RestockShop) =====
	Restock = {
		IntervalSeconds = 300, -- wall-clock aligned: restocks at :00/:05/:10...
		Slots = 3,
	},

	-- ===== Daily login streak =====
	Streak = {
		LuckPerDay = 1, -- bonus luck levels per consecutive day online
		MaxLuckBonus = 5, -- cap: a 5+ day streak grants +5 luck
	},
}

return GameConfig
