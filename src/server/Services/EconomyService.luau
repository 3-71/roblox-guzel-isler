--!strict
-- EconomyService — money mutations, leaderstats, and the SellRequest remote.
--
-- Contract (ARCHITECTURE.md):
--   AddMoney(player, amount)            -- floors; ignores <= 0; bumps totalEarned
--   SpendMoney(player, amount) -> bool  -- floors; false if balance is short,
--                                          so money can never go negative
--   SellRequest remote: mode "uids" (array of uids, max 50) or "belowTier"
--     (number 1..#Rarities — sells every keyboard with rarityTier < N).
--     Equipped and displayed keyboards never sell. Value comes from
--     Catalog.GetSellValue at the player's CURRENT factory tier. Every uid is
--     resolved against the server profile — nothing on the client's word.
--     Rate limit 2 requests/sec per player; excess dropped silently.
--   leaderstats.Money IntValue created on profile load, kept in sync.
--
-- Extra helper: Abbreviate(n) -> "1.2K"-style string (pad toasts reuse it).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local Rarities = require(Shared.Config.Rarities)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

local EconomyService = {}

local SELL_RATE_WINDOW = 1 -- seconds; the "per second" of the rate limit
local SELL_RATE_MAX = 2 -- contract: 2 SellRequests/sec per player
local MAX_UIDS_PER_SELL = 50 -- contract: "uids" mode cap

-- Sliding-window timestamps of recent SellRequests, per player.
local sellTimestamps: { [Player]: { number } } = {}

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
			if requested[instance.uid] and not excluded[instance.uid] then
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
			if not excluded[instance.uid] then
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
	for _, instance in removed do
		total += Catalog.GetSellValue(instance.id, factoryTier)
	end
	EconomyService.AddMoney(player, total)

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
	end)

	Remotes.SellRequest.OnServerEvent:Connect(function(player, mode, payload)
		onSellRequest(player, mode, payload)
	end)

	Players.PlayerRemoving:Connect(function(player)
		sellTimestamps[player] = nil
	end)
end

return EconomyService
