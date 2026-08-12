--!strict
-- EconomyService — money mutations, leaderstats, and the SellRequest remote.
--
-- Contract (ARCHITECTURE.md):
--   AddMoney(player, amount)            -- floors; ignores <= 0; bumps totalEarned
--   SpendMoney(player, amount) -> bool  -- floors; false if balance is short,
--                                          so money can never go negative
--   SellRequest remote: mode "uids" (array of uids, max 50) or "belowTier"
--     (number 1..#Rarities — sells every keyboard with rarityTier < N).
--     Equipped, displayed and vault-locked (instance.locked, Phase 4)
--     keyboards never sell, in either mode. Value comes from
--     Catalog.GetSellValue at the player's CURRENT factory tier, including
--     the instance's fusion stars and display-aging ageSeconds (Phase 4).
--     Every uid is resolved against the server profile — nothing on the
--     client's word. Rate limit 2 requests/sec per player; excess dropped
--     silently.
--   leaderstats.Money IntValue created on profile load, kept in sync.
--
-- Phase 3:
--   Friends-in-server bonus: sell totals are multiplied by
--   1 + min(FriendBonusPerFriend * friendsInServer, FriendBonusCap), floored.
--   Friendships are cached per online pair (pcall IsFriendsWith once per
--   pair, both directions), invalidated on leave.
--   SellReport remote fired to the seller after every successful sell:
--   { count, total, bestId, bestValue, mutationBonus } (sell ceremony data).
--
-- Extra helper: Abbreviate(n) -> "1.2K"-style string (pad toasts reuse it).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local Rarities = require(Shared.Config.Rarities)
local GameConfig = require(Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

local EconomyService = {}

local SELL_RATE_WINDOW = 1 -- seconds; the "per second" of the rate limit
local SELL_RATE_MAX = 2 -- contract: 2 SellRequests/sec per player
local MAX_UIDS_PER_SELL = 50 -- contract: "uids" mode cap

-- Sliding-window timestamps of recent SellRequests, per player.
local sellTimestamps: { [Player]: { number } } = {}

-- ===== Friends-in-server bonus =====

-- friendsWith[a][b] = whether a and b are Roblox friends. Symmetric (both
-- directions cached from ONE IsFriendsWith web call per pair), entries only
-- ever reference online players (cleaned on leave).
local friendsWith: { [Player]: { [Player]: boolean } } = {}

-- Number of the player's friends currently in this server.
local function friendCount(player: Player): number
	local map = friendsWith[player]
	if map == nil then
		return 0
	end
	local count = 0
	for other, isFriend in map do
		if isFriend and other.Parent ~= nil then
			count += 1
		end
	end
	return count
end

-- Pairs whose IsFriendsWith web call is in flight, keyed "loUserId:hiUserId".
-- Guards the contract's ONE web call per pair: refreshFriendships runs from
-- both PlayerAdded and OnProfileLoaded, which overlap before the first call
-- resolves (the cache is only written after the pcall returns).
local pendingPairs: { [string]: boolean } = {}

local function pairKey(a: Player, b: Player): string
	local lo = math.min(a.UserId, b.UserId)
	local hi = math.max(a.UserId, b.UserId)
	return lo .. ":" .. hi
end

-- Resolves one (a, b) pair via IsFriendsWith and caches both directions.
-- Yields (web call), so it always runs inside task.spawn; a pcall failure
-- caches "not friends" — the bonus only ever under-counts, never errors.
local function cachePair(a: Player, b: Player)
	local mapA = friendsWith[a]
	if mapA == nil or mapA[b] ~= nil then
		return -- a left, or this pair was already checked
	end
	local key = pairKey(a, b)
	if pendingPairs[key] then
		return -- this pair is already being resolved; it caches both directions
	end
	pendingPairs[key] = true
	local ok, result = pcall(function()
		return a:IsFriendsWith(b.UserId)
	end)
	pendingPairs[key] = nil
	local isFriend = ok and result == true
	-- Re-fetch: either player may have left during the web call.
	mapA = friendsWith[a]
	if mapA ~= nil then
		mapA[b] = isFriend
	end
	local mapB = friendsWith[b]
	if mapB ~= nil then
		mapB[a] = isFriend
	end
end

-- Ensures `player` has a cache map and every online pair involving them is
-- (being) resolved. Idempotent: already-cached pairs are skipped, so calling
-- from both PlayerAdded and OnProfileLoaded is safe.
local function refreshFriendships(player: Player)
	if player.Parent == nil then
		return
	end
	if friendsWith[player] == nil then
		friendsWith[player] = {}
	end
	for _, other in Players:GetPlayers() do
		if other ~= player then
			if friendsWith[other] == nil then
				friendsWith[other] = {}
			end
			task.spawn(cachePair, player, other)
		end
	end
end

-- ===== Number formatting =====

local ABBREV_STEPS = {
	{ value = 1e12, suffix = "T" },
	{ value = 1e9, suffix = "B" },
	{ value = 1e6, suffix = "M" },
	{ value = 1e3, suffix = "K" },
}

-- 1234 -> "1.2K", 1000 -> "1K", 3_400_000 -> "3.4M", 999 -> "999".
function EconomyService.Abbreviate(amount: number): string
	local rounded = math.floor(amount + 0.5)
	for _, step in ABBREV_STEPS do
		if math.abs(rounded) >= step.value then
			local text = string.format("%.1f", rounded / step.value)
			text = string.gsub(text, "%.0$", "")
			return text .. step.suffix
		end
	end
	return tostring(rounded)
end

-- ===== Leaderstats =====

local function refreshLeaderstats(player: Player, profile: Types.Profile)
	if player.Parent == nil then
		return
	end
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats == nil then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		leaderstats = folder
	end
	local money = leaderstats:FindFirstChild("Money")
	if money == nil then
		local value = Instance.new("IntValue")
		value.Name = "Money"
		value.Parent = leaderstats
		money = value
	end
	if money:IsA("IntValue") then
		money.Value = math.floor(profile.money)
	end
end

-- ===== Money API =====

-- Re-syncs leaderstats.Money from the profile without changing balances
-- (AddMoney ignores 0, so post-rebirth resets need this explicit path).
function EconomyService.RefreshLeaderstats(player: Player)
	local profile = DataService.GetProfile(player)
	if profile ~= nil then
		refreshLeaderstats(player, profile)
	end
end

-- ===== Server-wide sell multiplier (THOCK MONSTER win/lose aftermath) =====
-- BossService sets it; every sell and typing payout reads it. Reverts to 1
-- automatically when the window expires — no cleanup timer needed.

local sellBoostMult = 1
local sellBoostUntil = 0

function EconomyService.SetSellBoost(mult: number, seconds: number)
	if typeof(mult) ~= "number" or mult ~= mult or mult <= 0 then
		return
	end
	sellBoostMult = math.clamp(mult, 0.1, 10)
	sellBoostUntil = os.clock() + math.max(seconds, 0)
end

function EconomyService.GetSellMult(): number
	if os.clock() >= sellBoostUntil then
		return 1
	end
	return sellBoostMult
end

function EconomyService.AddMoney(player: Player, amount: number)
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount == math.huge then
		return -- NaN/inf can never enter the economy
	end
	local floored = math.floor(amount)
	if floored <= 0 then
		return
	end
	profile.money += floored
	profile.totalEarned += floored
	refreshLeaderstats(player, profile)
	DataService.MarkDirty(player)
	DataService.Sync(player)
end

function EconomyService.SpendMoney(player: Player, amount: number): boolean
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return false
	end
	if typeof(amount) ~= "number" or amount ~= amount then
		return false
	end
	local floored = math.floor(amount)
	if floored < 0 then
		return false
	end
	if profile.money < floored then
		return false
	end
	if floored > 0 then
		profile.money -= floored
		refreshLeaderstats(player, profile)
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
	return true
end

-- ===== SellRequest =====

-- True if this request fits in the sliding window (and records it).
local function allowSellRequest(player: Player): boolean
	local now = os.clock()
	local stamps = sellTimestamps[player]
	if stamps == nil then
		stamps = {}
		sellTimestamps[player] = stamps
	end
	for i = #stamps, 1, -1 do
		if now - stamps[i] > SELL_RATE_WINDOW then
			table.remove(stamps, i)
		end
	end
	if #stamps >= SELL_RATE_MAX then
		return false
	end
	table.insert(stamps, now)
	return true
end

local function onSellRequest(player: Player, mode: unknown, payload: unknown)
	if not allowSellRequest(player) then
		return -- rate limited: drop silently (contract)
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	-- Equipped or displayed keyboards are never sellable, in either mode.
	-- Vault-locked instances (Phase 4) are checked per-instance below.
	local excluded: { [string]: boolean } = {}
	if profile.equippedUid ~= nil then
		excluded[profile.equippedUid] = true
	end
	for _, displayedUid in profile.displayed do
		excluded[displayedUid] = true
	end

	local toSell: { string } = {}
	if mode == "uids" then
		if typeof(payload) ~= "table" then
			return
		end
		local list = payload :: { unknown }
		local count = #list
		if count == 0 or count > MAX_UIDS_PER_SELL then
			return
		end
		local requested: { [string]: boolean } = {}
		for i = 1, count do
			local uid = list[i]
			if typeof(uid) ~= "string" then
				return -- malformed payload: reject the whole request
			end
			requested[uid] = true
		end
		-- Resolve against the server profile: only uids we actually own count.
		for _, instance in profile.keyboards do
			if requested[instance.uid] and not excluded[instance.uid] and not instance.locked then
				table.insert(toSell, instance.uid)
			end
		end
	elseif mode == "belowTier" then
		if typeof(payload) ~= "number" or payload ~= payload then
			return
		end
		local tier = math.floor(payload)
		if tier < 1 or tier > #Rarities then
			return
		end
		for _, instance in profile.keyboards do
			if not excluded[instance.uid] and not instance.locked then
				local def = Catalog.GetKeyboard(instance.id)
				if def ~= nil and def.rarityTier < tier then
					table.insert(toSell, instance.uid)
				end
			end
		end
	else
		return
	end

	if #toSell == 0 then
		return
	end

	-- Value what was ACTUALLY removed (single source of truth), at the
	-- player's current factory tier. RemoveKeyboards and AddMoney each do
	-- their own MarkDirty + Sync — correctness over minimal traffic.
	local removed = InventoryService.RemoveKeyboards(player, toSell)
	if #removed == 0 then
		return
	end
	local factoryTier = profile.upgrades.factoryTier
	local total = 0
	local bestId: string? = nil
	local bestValue = 0
	local mutationBonus = 0
	for _, instance in removed do
		local value =
			Catalog.GetSellValue(instance.id, factoryTier, instance.mutation, profile.rebirths, instance.stars, instance.ageSeconds)
		total += value
		if bestId == nil or value > bestValue then
			bestId = instance.id
			bestValue = value
		end
		if instance.mutation ~= nil then
			-- Extra earned from the mutation vs the same keyboard unmutated
			-- (stars/age kept equal on both sides so the delta is pure mutation).
			local baseValue =
				Catalog.GetSellValue(instance.id, factoryTier, nil, profile.rebirths, instance.stars, instance.ageSeconds)
			mutationBonus += value - baseValue
		end
	end

	-- Friends-in-server bonus (Phase 3 contract).
	local bonus = math.min(GameConfig.FriendBonusPerFriend * friendCount(player), GameConfig.FriendBonusCap)
	total = math.floor(total * (1 + bonus))

	-- THOCK MONSTER aftermath: server-wide +25% / -25% window (Phase 5).
	total = math.floor(total * EconomyService.GetSellMult())

	EconomyService.AddMoney(player, total)

	-- Selling feeds the hub Harmony obelisk (Phase 6). One transaction = one
	-- bump, however large the bulk. Lazy pcall: no cycle, optional service.
	pcall(function()
		local HarmonyService = require(script.Parent.HarmonyService) :: any
		HarmonyService.AddPoints(GameConfig.Harmony.PointsSell)
	end)

	-- Sell ceremony data for the seller's client (Phase 3 contract).
	Remotes.SellReport:FireClient(player, {
		count = #removed,
		total = total,
		bestId = bestId,
		bestValue = bestValue,
		mutationBonus = mutationBonus,
	})

	local noun = if #removed == 1 then "keyboard" else "keyboards"
	Remotes.Notify:FireClient(player, "info", `Sold {#removed} {noun} for ${EconomyService.Abbreviate(total)}`)
end

-- ===== Lifecycle =====

function EconomyService.Init()
	-- Dependencies are wired via the module requires above.
end

function EconomyService.Start()
	DataService.OnProfileLoaded(function(player, profile)
		refreshLeaderstats(player, profile)
		refreshFriendships(player)
	end)

	Remotes.SellRequest.OnServerEvent:Connect(function(player, mode, payload)
		onSellRequest(player, mode, payload)
	end)

	Players.PlayerAdded:Connect(refreshFriendships)

	Players.PlayerRemoving:Connect(function(player)
		sellTimestamps[player] = nil
		friendsWith[player] = nil
		for _, map in friendsWith do
			map[player] = nil
		end
	end)
end

return EconomyService
