--!strict
-- InventoryService — the single owner of profile.keyboards mutations.
--
-- Contract (ARCHITECTURE.md):
--   AddKeyboard(player, keyboardId, source) -> Types.KeyboardInstance?
--     nil at InventoryCap / unknown id / no profile. Fires KeyboardCollected
--     to the owner and a server-wide "flex" Notify for high tiers.
--   RemoveKeyboards(player, uids) -> { Types.KeyboardInstance }
--     removes & returns matches; unequips/undisplays any removed uid.
--   GetKeyboard(player, uid) -> Types.KeyboardInstance?
--
-- Every mutating call does exactly one MarkDirty + Sync (batched).

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local GameConfig = require(Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)

local InventoryService = {}

function InventoryService.AddKeyboard(player: Player, keyboardId: string, source: string, mutation: string?): Types.KeyboardInstance?
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
	local instance: Types.KeyboardInstance = {
		uid = HttpService:GenerateGUID(false),
		id = def.id,
		obtainedAt = os.time(),
		mutation = if mutationDef then mutationDef.id else nil,
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
		end
	end

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

function InventoryService.Init()
	-- Pure API service: everything happens through the functions above.
end

function InventoryService.Start()
end

return InventoryService
