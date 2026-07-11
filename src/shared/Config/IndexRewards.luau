--!strict
-- Collection Index milestone rewards: discover N distinct keyboards, claim
-- cash + permanent luck levels from the collection book. `id` is the claim
-- key stored in profile.indexClaimed.

export type IndexReward = {
	id: string,
	count: number, -- distinct keyboards discovered required
	cash: number,
	luck: number, -- permanent bonus luck levels
}

local IndexRewards: { IndexReward } = {
	{ id = "index_5", count = 5, cash = 2_000, luck = 0 },
	{ id = "index_10", count = 10, cash = 8_000, luck = 1 },
	{ id = "index_15", count = 15, cash = 40_000, luck = 1 },
	{ id = "index_20", count = 20, cash = 250_000, luck = 1 },
	{ id = "index_25", count = 25, cash = 1_500_000, luck = 1 },
	{ id = "index_30", count = 30, cash = 8_000_000, luck = 2 },
	{ id = "index_36", count = 36, cash = 50_000_000, luck = 3 },
}

return IndexRewards
