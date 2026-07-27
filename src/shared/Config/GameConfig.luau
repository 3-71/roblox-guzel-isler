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
	-- Every accepted keypress on your EQUIPPED keyboard pays out a fraction of
	-- that board's current sell value (EquipService batches the payouts).
	TypingIncome = {
		ValueFraction = 0.5, -- money per click = half the board's sell value
		FlushSeconds = 1, -- batched into one AddMoney/Sync per interval
	},
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

	-- ===== Display aging =====
	-- DISPLAYED keyboards age while on a stand; a board's stage is the
	-- HIGHEST threshold it has passed (see Catalog.GetAgeStage). Stage
	-- valueMult applies in Catalog.GetSellValue.
	Aging = {
		TickSeconds = 60, -- ShowcaseService loop interval = seconds added per tick
		OfflineRateMult = 0.5, -- displayed boards age at half speed while offline
		Stages = {
			{ name = "Broken-In", seconds = 1800, valueMult = 1.15 },
			{ name = "Seasoned", seconds = 7200, valueMult = 1.4 },
			{ name = "Ancient", seconds = 28800, valueMult = 2.0 },
		},
	},

	-- ===== Fusion (see FusionService) =====
	Fusion = {
		Required = 3, -- identical duplicates consumed per fuse
		MaxStars = 5,
		ValueMultPerStar = 1.6, -- sell value *= this ^ stars
	},

	-- ===== Secrets (see SecretService) =====
	Secrets = {
		WholesomeLikes = 15, -- likesGiven needed for the Wholesome secret
	},

	-- ===== THOCK MONSTER boss (see BossService) =====
	-- A monster attacks the plots; everyone types on it to win. Base damage is
	-- TEMPORARY VISUALS ONLY — nobody ever loses items, money or progress.
	Boss = {
		MinIntervalSeconds = 2400, -- time between fights (rolled in this range)
		MaxIntervalSeconds = 3600,
		WarningSeconds = 20, -- "it's coming" siren before the fight starts
		FightSeconds = 180,
		BaseHp = 4_000, -- + HpPerPlayer * players present
		HpPerPlayer = 3_000,
		TypeDamageBase = 5, -- damage per accepted keypress near the monster...
		TypeDamagePerTier = 2, -- ...+ this * your factory tier
		DamageRadius = 70, -- studs from the monster within which typing counts
		WeakSpotCount = 3, -- glowing keycaps on the monster (click for bonus)
		WeakSpotDamage = 150, -- damage per weak-spot click (then it moves)
		WinSellMult = 1.25, -- everyone sells for +25% after a win...
		LoseSellMult = 0.75, -- ...or -25% after a loss
		EffectSeconds = 600, -- how long the win/lose multiplier lasts
	},

	-- ===== 7-day streak calendar (see StreakService) =====
	-- Sits on top of the daily streak: one claim per day, position advances
	-- 1..7 then wraps. Missing more than GraceDays days resets to day 1.
	StreakCalendar = {
		GraceDays = 2, -- 48h grace before the calendar position resets
		BoostLuckBonus = 3, -- luck granted by the "calendar_luck" boost days
		BoostSeconds = 900,
		-- One entry per day: kind "cash" (amount scales nothing — flat),
		-- "luckBoost" (calendar_luck boost) or "legendary" (guaranteed tier-9
		-- keyboard with the full ceremony).
		Rewards = {
			{ kind = "cash", amount = 2_500 },
			{ kind = "cash", amount = 10_000 },
			{ kind = "luckBoost" },
			{ kind = "cash", amount = 40_000 },
			{ kind = "luckBoost" },
			{ kind = "cash", amount = 150_000 },
			{ kind = "legendary" },
		},
	},
}

return GameConfig
