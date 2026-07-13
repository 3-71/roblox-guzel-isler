--!strict
-- InventoryService — the single owner of profile.keyboards mutations.
--
-- Contract (ARCHITECTURE.md):
--   AddKeyboard(player, keyboardId, source, mutation?, stars?) -> Types.KeyboardInstance?
--     nil at InventoryCap / unknown id / no profile. Fires KeyboardCollected
--     to the owner and, for high tiers / huge mutations, a server-wide "flex"
--     Notify plus the GlobalRoll spectacle payload to ALL clients (Phase 3).
--     stars (Phase 4, FusionService) is stored on the instance and carried in
--     the CollectedPayload. Every successful add ends with a
--     SetsService.CheckSets pass (lazy pcall require — see checkSets below)
--     so a collect can auto-claim a completed themed set.
--   RemoveKeyboards(player, uids) -> { Types.KeyboardInstance }
--     removes & returns matches; unequips/undisplays any removed uid.
--   GetKeyboard(player, uid) -> Types.KeyboardInstance?
--   VaultRequest remote (uid: string, locked: boolean), Phase 4: toggles
--     instance.locked (stored as true or nil, never false). Locked instances
--     are excluded from selling/gifting/fusing by those flows' owners.
--     Rate limit: 3/s token bucket per player; excess dropped silently.
--
-- Every mutating call does exactly one MarkDirty + Sync (batched).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local RollLogic = require(Shared.RollLogic)
local GameConfig = require(Shared.Config.GameConfig)
local Events = require(Shared.Config.Events)

local DataService = require(script.Parent.DataService)

local InventoryService = {}

-- The active event's luck bonus, read from the Workspace attributes published
-- by EventService (0 when none/expired). Every luck read goes through
-- RollLogic.GetEffectiveLuck (contract), and this is its event input.
local function activeEventLuckBonus(): number
	local id = workspace:GetAttribute("ActiveEventId")
	local expiry = workspace:GetAttribute("ActiveEventUntil")
	if typeof(id) ~= "string" or id == "" then
		return 0
	end
	if typeof(expiry) ~= "number" or expiry <= os.time() then
		return 0
	end
	for _, event in Events do
		if event.id == id then
			return event.luckBonus
		end
	end
	return 0
end

-- The player's plot index for the GlobalRoll payload, read straight off the
-- Workspace.Plots attributes set by PlotBuilder. Deliberately NOT via a
-- PlotService require: PlotService -> PadService -> EconomyService ->
-- InventoryService would be a require cycle. 0 = plot not found (clients
-- simply skip the plot-anchored effects).
local function findPlotIndex(player: Player): number
	local plots = workspace:FindFirstChild("Plots")
	if plots ~= nil then
		for _, plot in plots:GetChildren() do
			if plot:GetAttribute("OwnerUserId") == player.UserId then
				local index = plot:GetAttribute("PlotIndex")
				if typeof(index) == "number" then
					return index
				end
			end
		end
	end
	return 0
end

-- Runs SetsService.CheckSets after a collect. SetsService is required
-- lazily inside a pcall (contract): a top-level require would work today,
-- but the soft edge guarantees AddKeyboard can never break if the module
-- is missing or not yet loaded during bootstrap — the pcall just no-ops
-- and the OnProfileLoaded pass inside SetsService catches up on join.
local setsService: any = nil

local function checkSets(player: Player)
	if setsService == nil then
		local ok, result = pcall(function()
			return require(script.Parent.SetsService) :: any
		end)
		if not ok then
			return
		end
		setsService = result
	end
	setsService.CheckSets(player)
end

function InventoryService.AddKeyboard(player: Player, keyboardId: string, source: string, mutation: string?, stars: number?): Types.KeyboardInstance?
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return nil -- player left or profile not loaded yet
	end

	local def = Catalog.GetKeyboard(keyboardId)
	if def == nil then
		warn(`[InventoryService] AddKeyboard: unknown keyboardId "{keyboardId}"`)
		return nil
	end

	if #profile.keyboards >= GameConfig.InventoryCap then
		return nil
	end

	local mutationDef = Catalog.GetMutation(mutation)
	-- stars come only from trusted server callers (FusionService), but are
	-- still sanitized: whole number, 1..MaxStars, nil for unstarred.
	local starCount: number? = nil
	if stars ~= nil and stars >= 1 then
		starCount = math.min(math.floor(stars), GameConfig.Fusion.MaxStars)
	end
	local instance: Types.KeyboardInstance = {
		uid = HttpService:GenerateGUID(false),
		id = def.id,
		obtainedAt = os.time(),
		mutation = if mutationDef then mutationDef.id else nil,
		stars = starCount,
	}
	table.insert(profile.keyboards, instance)
	profile.collection[def.id] = (profile.collection[def.id] or 0) + 1

	DataService.MarkDirty(player)
	DataService.Sync(player)

	local payload: Types.CollectedPayload = {
		keyboardId = def.id,
		uid = instance.uid,
		rarityTier = def.rarityTier,
		source = source,
		mutation = instance.mutation,
		stars = instance.stars,
	}
	Remotes.KeyboardCollected:FireClient(player, payload)

	local rarity = Catalog.GetRarity(def.rarityTier)
	if rarity ~= nil then
		-- High tiers always flex; huge mutations (holo/glitched) flex at any tier.
		local bigMutation = mutationDef ~= nil and mutationDef.valueMult >= 12
		if rarity.tier >= GameConfig.GlobalFlexMinTier or bigMutation then
			local who = if profile.passes ~= nil and profile.passes.vip then "👑 " .. player.Name else player.Name
			local what = if mutationDef then mutationDef.name .. " " .. rarity.name else rarity.name
			Remotes.Notify:FireAllClients("flex", who .. " just rolled a " .. what .. " " .. def.name .. "!")

			-- Phase-3 spectacle: the same rolls also fire GlobalRoll so EVERY
			-- client renders the sky beam / fireworks at the roller's plot and
			-- shows the "1 in N" odds line.
			local effectiveLuck = RollLogic.GetEffectiveLuck(profile, os.time(), activeEventLuckBonus())
			local odds = RollLogic.GetOdds(profile.upgrades.factoryTier, effectiveLuck)
			local tierOdd = odds[def.rarityTier] or 0
			local mutationChanceShare = if mutationDef ~= nil then mutationDef.chance else 1
			local oddsDenominator = math.max(1, math.floor(1 / math.max(tierOdd * mutationChanceShare, 1e-9) + 0.5))
			Remotes.GlobalRoll:FireAllClients({
				playerName = player.Name,
				keyboardId = def.id,
				mutation = instance.mutation,
				rarityTier = def.rarityTier,
				plotIndex = findPlotIndex(player),
				oddsDenominator = oddsDenominator,
			})
		end
	end

	-- Phase 4: this collect may have just completed a themed set.
	checkSets(player)

	return instance
end

function InventoryService.RemoveKeyboards(player: Player, uids: { string }): { Types.KeyboardInstance }
	local removed: { Types.KeyboardInstance } = {}
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return removed
	end

	local wanted: { [string]: boolean } = {}
	for _, uid in uids do
		if typeof(uid) == "string" then
			wanted[uid] = true
		end
	end
	if next(wanted) == nil then
		return removed
	end

	-- Walk backwards so table.remove doesn't skip over neighbours.
	for i = #profile.keyboards, 1, -1 do
		local instance = profile.keyboards[i]
		if wanted[instance.uid] then
			table.remove(profile.keyboards, i)
			table.insert(removed, instance)
		end
	end
	if #removed == 0 then
		return removed
	end

	-- Unequip / undisplay anything that no longer exists. ShowcaseService and
	-- EquipService re-render from the synced profile, so clearing the data
	-- here is enough — no direct call into them (avoids a hard dependency).
	local removedSet: { [string]: boolean } = {}
	for _, instance in removed do
		removedSet[instance.uid] = true
	end
	if profile.equippedUid ~= nil and removedSet[profile.equippedUid] then
		profile.equippedUid = nil
	end
	for standIndex, displayedUid in profile.displayed do
		if removedSet[displayedUid] then
			-- Setting an existing key to nil during traversal is allowed.
			profile.displayed[standIndex] = nil
		end
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
	return removed
end

function InventoryService.GetKeyboard(player: Player, uid: string): Types.KeyboardInstance?
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return nil
	end
	for _, instance in profile.keyboards do
		if instance.uid == uid then
			return instance
		end
	end
	return nil
end

-- ===== Vault (Phase 4) =====

local VAULT_RATE_PER_SECOND = 3 -- contract: 3 VaultRequests/sec per player

-- token bucket per player for VaultRequest
local vaultTokens: { [Player]: { tokens: number, last: number } } = {}

local function takeVaultToken(player: Player): boolean
	local bucket = vaultTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 3, last = now }
		vaultTokens[player] = bucket
	end
	bucket.tokens = math.min(3, bucket.tokens + (now - bucket.last) * VAULT_RATE_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function onVaultRequest(player: Player, uid: unknown, locked: unknown)
	if not takeVaultToken(player) then
		return -- rate limited: drop silently
	end
	-- Type validation: nothing on the client's word.
	if typeof(uid) ~= "string" or typeof(locked) ~= "boolean" then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	for _, instance in profile.keyboards do
		if instance.uid == uid then
			-- Store true or nil, never false — no need to persist the default.
			local newLocked: boolean? = if locked then true else nil
			if instance.locked ~= newLocked then
				instance.locked = newLocked
				DataService.MarkDirty(player)
				DataService.Sync(player)
			end
			return
		end
	end
	-- Unowned uid: silently ignored (client UI only offers owned instances).
end

function InventoryService.Init()
	-- Pure API service plus the VaultRequest remote (connected in Start).
end

function InventoryService.Start()
	Remotes.VaultRequest.OnServerEvent:Connect(onVaultRequest)

	Players.PlayerRemoving:Connect(function(player)
		vaultTokens[player] = nil
	end)
end

return InventoryService
