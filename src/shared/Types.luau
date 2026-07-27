--!strict
-- Shared type definitions. The Profile shape here IS the DataStore schema —
-- change it only alongside DataService's migration/reconcile logic.

export type KeyboardInstance = {
	uid: string, -- unique per instance (for equipping/display/future trading)
	id: string, -- KeyboardDef id from Config/Keyboards
	obtainedAt: number, -- unix time
	mutation: string?, -- MutationDef id from Config/Mutations (nil = normal)
	-- vault: locked instances are excluded from selling/gifting/fusing
	locked: boolean?,
	stars: number?, -- fusion stars 1..GameConfig.Fusion.MaxStars (nil = unstarred)
	ageSeconds: number?, -- display aging accrued on a stand (see GameConfig.Aging)
}

export type Upgrades = {
	factoryTier: number, -- 1..12
	conveyors: number, -- 1..4
	speed: number, -- 0..10
	luck: number, -- 0..10
	storage: number, -- 0..5
	displays: number, -- 0..6
	walls: number, -- 0..4 cosmetic wall tier (survives rebirth, like displays)
}

export type Profile = {
	money: number,
	totalEarned: number,
	keyboards: { KeyboardInstance },
	upgrades: Upgrades,
	pads: { [string]: boolean }, -- purchased pad ids
	-- standIndex (1..6) -> keyboard uid shown on that display stand
	displayed: { [string]: string },
	-- keyboardId -> how many ever collected (drives the collection book)
	collection: { [string]: number },
	equippedUid: string?,
	lastSeen: number,
	firstJoin: number,
	rebirths: number,
	-- IndexReward ids already claimed (see Config/IndexRewards)
	indexClaimed: { [string]: boolean },
	-- completed collection-set ids, auto-claimed by SetsService (see Config/Sets)
	setsClaimed: { [string]: boolean },
	likesReceived: number,
	-- likes this player GAVE to other farms (drives the Wholesome secret;
	-- see GameConfig.Secrets)
	likesGiven: number,
	-- gamepass key -> owned (cached on join; see Config/Products)
	passes: { [string]: boolean },
	-- dev-product boost key -> unix expiry time
	boosts: { [string]: number },
	-- rolls since the last Epic+ (pity system; see GameConfig.Pity)
	pity: number,
	-- newest ~50 finalized dev-product PurchaseIds (receipt idempotency across
	-- sessions; see MonetizationService.processReceipt)
	grantedReceipts: { string },
	-- daily login streak (StreakService): consecutive days + last counted
	-- UTC day number (os.time() // 86400)
	streakDays: number,
	streakLastDay: number,
	-- 7-day streak calendar (StreakService): current position 1..7 (0 = never
	-- claimed) + UTC day number of the last claim
	calendarDay: number,
	calendarLastClaim: number,
	-- THOCK MONSTER fights this player helped win (BossService; buddy unlocks)
	bossWins: number,
	-- typing races won (TypingRaceService; buddy unlocks)
	raceWins: number,
	-- owned Thock Buddies: BuddyDef id -> true (see Config/Buddies)
	buddies: { [string]: boolean },
	equippedBuddy: string?,
	-- monotonic write counter (DataService staleness guard)
	saveCount: number,
}

-- Payload of the DataSync remote: the full profile snapshot the client renders from.
export type ProfileSnapshot = Profile

-- KeyboardCollected remote payload
export type CollectedPayload = {
	keyboardId: string,
	uid: string,
	rarityTier: number,
	source: string, -- "belt" | "offline"
	mutation: string?, -- MutationDef id (nil = normal)
	stars: number?, -- fusion stars on the new instance (nil = unstarred)
}

-- OfflineReport remote payload
export type OfflinePayload = {
	secondsAway: number,
	produced: number, -- how many keyboards were produced while away
	capped: boolean, -- true if storage cap was hit
	bestKeyboardId: string?,
}

return nil
