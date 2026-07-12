--!strict
-- The hub "Limited Crate" stall: restocks every 5 minutes on the wall clock
-- (GameConfig.Restock). Each restock rolls GameConfig.Restock.Slots offers
-- from this table by weight; each offer has limited stock per restock.
-- Everything is CASH-priced (earned in play) — no Robux, no compliance load.
-- Rare offers appearing is server-announced, making restocks appointments.

export type RestockOffer = {
	id: string,
	name: string,
	description: string,
	weight: number, -- selection weight per restock roll
	stock: number, -- units available per appearance
	cost: number, -- cash price (scaled by buyer's factory tier: cost * tier)
	-- effect, applied by RestockShopService:
	kind: string, -- "guaranteedRoll" | "luckSurge" | "mutationCharm" | "instantCash"
	tierFloor: number?, -- guaranteedRoll: minimum rarity tier of the roll
	luckBonus: number?, -- luckSurge: bonus luck levels
	duration: number?, -- luckSurge: seconds
	mutationMult: number?, -- mutationCharm: mutation chance multiplier
	charmRolls: number?, -- mutationCharm: number of rolls it applies to
	cashMult: number?, -- instantCash: payout = cost * cashMult
}

local RestockShop: { RestockOffer } = {
	{
		id = "rare_roll", name = "Rare Crate", description = "One instant roll, guaranteed Rare or better.",
		weight = 30, stock = 3, cost = 120, kind = "guaranteedRoll", tierFloor = 5,
	},
	{
		id = "epic_roll", name = "Epic Crate", description = "One instant roll, guaranteed Epic or better!",
		weight = 10, stock = 2, cost = 600, kind = "guaranteedRoll", tierFloor = 7,
	},
	{
		id = "legendary_roll", name = "LEGENDARY CRATE", description = "One instant roll, guaranteed Legendary+!!",
		weight = 2, stock = 1, cost = 4_000, kind = "guaranteedRoll", tierFloor = 9,
	},
	{
		id = "luck_surge", name = "Luck Surge", description = "+4 luck for 10 minutes.",
		weight = 25, stock = 2, cost = 150, kind = "luckSurge", luckBonus = 4, duration = 600,
	},
	{
		id = "mutation_charm", name = "Mutation Charm", description = "5x mutation chance on your next 10 rolls.",
		weight = 12, stock = 1, cost = 350, kind = "mutationCharm", mutationMult = 5, charmRolls = 10,
	},
	{
		id = "golden_charm", name = "GOLDEN CHARM", description = "12x mutation chance on your next 5 rolls!",
		weight = 3, stock = 1, cost = 1_800, kind = "mutationCharm", mutationMult = 12, charmRolls = 5,
	},
	{
		id = "cash_pinata", name = "Cash Piñata", description = "Smash it open: pays out 3x what it costs.",
		weight = 18, stock = 2, cost = 200, kind = "instantCash", cashMult = 3,
	},
}

return RestockShop
