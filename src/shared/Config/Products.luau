--!strict
-- Monetization catalog. All ids default to 0 = NOT CONFIGURED: the shop
-- shows them as "coming soon" and the server grants nothing. After creating
-- the real gamepasses/developer products in the Roblox Creator Dashboard,
-- paste their ids here — no other code changes needed.

export type GamePassDef = {
	key: string,
	id: number, -- gamepass id from the Creator Dashboard (0 = disabled)
	name: string,
	description: string,
}

export type DevProductDef = {
	key: string,
	id: number, -- developer product id (0 = disabled)
	name: string,
	description: string,
	-- effect fields read by MonetizationService:
	cash: number?, -- instant cash grant
	luckBonus: number?, -- personal luck levels while active
	duration: number?, -- seconds the boost lasts
	serverLuckBonus: number?, -- luck party: bonus for EVERYONE in the server
}

local Products = {
	GamePasses = {
		{ key = "doubleLuck", id = 0, name = "2x Luck", description = "Doubles your total luck level, forever." },
		{ key = "extraStands", id = 0, name = "+2 Display Stands", description = "Two bonus display stands beyond the pads." },
		{ key = "doubleStorage", id = 0, name = "2x Offline Storage", description = "Your factory stores twice as many keyboards while you're away." },
		{ key = "vip", id = 0, name = "VIP", description = "Golden name in flex announcements + VIP tag on your plot sign." },
	} :: { GamePassDef },

	DevProducts = {
		{ key = "luckPotion", id = 0, name = "Luck Potion", description = "+5 luck levels for 30 minutes.", luckBonus = 5, duration = 1800 },
		{ key = "luckParty", id = 0, name = "LUCK PARTY", description = "+8 luck for you (30 min) and +3 for EVERYONE in the server for 5 minutes!", luckBonus = 8, duration = 1800, serverLuckBonus = 3 },
		{ key = "cashSmall", id = 0, name = "Cash Stack", description = "Instant $100,000.", cash = 100_000 },
		{ key = "cashBig", id = 0, name = "Cash Vault", description = "Instant $2,500,000.", cash = 2_500_000 },
	} :: { DevProductDef },
}

return Products
