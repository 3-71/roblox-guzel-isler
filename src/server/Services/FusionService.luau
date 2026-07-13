--!strict
-- FusionService — fuse duplicate keyboards into starred versions (Phase 4).
--
-- Contract (ARCHITECTURE.md):
--   FuseRequest remote (keyboardId: string):
--     - rate limit: 1 request per 2s per player (excess dropped silently)
--     - keyboardId must be a string that Catalog.GetKeyboard resolves
--     - candidates: the sender's instances of that id that are unlocked
--       (vault), unequipped and undisplayed
--     - candidates group by star value (stars or 0); groups already at
--       GameConfig.Fusion.MaxStars are ignored; the LOWEST star value whose
--       group holds >= GameConfig.Fusion.Required copies is fused — three
--       0-star make a 1-star, three 1-star a 2-star, etc. Mixed-star fusing
--       is never allowed.
--     - within the chosen group the Required CHEAPEST copies (by
--       Catalog.GetSellValue with each instance's mutation/stars/ageSeconds
--       at the player's factory tier) are consumed via
--       InventoryService.RemoveKeyboards, then ONE instance of the same id
--       is added with stars + 1 (capped at MaxStars) through
--       InventoryService.AddKeyboard(player, id, "fusion", nil, stars) —
--       so the full collect ceremony (KeyboardCollected, MarkDirty+Sync)
--       fires for the result.
--     - Notify the fuser; server-wide flex when the RESULT has stars >= 3.
--
-- RemoveKeyboards and AddKeyboard each MarkDirty+Sync, so this service does
-- no data bookkeeping of its own on the happy path.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local GameConfig = require(Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

local FusionService = {}

local FUSE_COOLDOWN_SECONDS = 2 -- contract: 1 FuseRequest per 2s per player

-- os.clock() of each player's last (attempted) fuse — a 1-capacity token
-- bucket, matching GiftService's cooldown pattern.
local lastFuseAt: { [Player]: number } = {}

local function onFuseRequest(player: Player, keyboardId: unknown)
	-- Rate limit first, before any validation work; counting attempts (not
	-- just successes) keeps failed-probe spam cheap too.
	local now = os.clock()
	local last = lastFuseAt[player]
	if last ~= nil and now - last < FUSE_COOLDOWN_SECONDS then
		return
	end
	lastFuseAt[player] = now

	-- Type validation: nothing on the client's word.
	if typeof(keyboardId) ~= "string" then
		return
	end
	local def = Catalog.GetKeyboard(keyboardId)
	if def == nil then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	-- Displayed uids: values of profile.displayed, inverted for O(1) lookups.
	local displayedUids: { [string]: boolean } = {}
	for _, uid in profile.displayed do
		displayedUids[uid] = true
	end

	-- Fusable candidates of this id, grouped by star value. Locked (vault),
	-- equipped and displayed instances never enter a destructive flow, and a
	-- group already at MaxStars has nowhere left to go.
	local groups: { [number]: { Types.KeyboardInstance } } = {}
	for _, instance in profile.keyboards do
		if
			instance.id == keyboardId
			and not instance.locked
			and profile.equippedUid ~= instance.uid
			and not displayedUids[instance.uid]
		then
			local starGroup = instance.stars or 0
			if starGroup < GameConfig.Fusion.MaxStars then
				local group = groups[starGroup]
				if group == nil then
					group = {}
					groups[starGroup] = group
				end
				table.insert(group, instance)
			end
		end
	end

	-- The LOWEST star value with enough identical copies wins.
	local chosenStars: number? = nil
	for starValue = 0, GameConfig.Fusion.MaxStars - 1 do
		local group = groups[starValue]
		if group ~= nil and #group >= GameConfig.Fusion.Required then
			chosenStars = starValue
			break
		end
	end
	if chosenStars == nil then
		Remotes.Notify:FireClient(
			player,
			"error",
			`You need {GameConfig.Fusion.Required} spare {def.name}s of the same star level (unlocked, not equipped or displayed) to fuse.`
		)
		return
	end

	-- Consume the Required cheapest copies. Values are precomputed so the
	-- sort comparator stays cheap and consistent; uid breaks ties for a
	-- deterministic pick.
	local group = groups[chosenStars]
	local factoryTier = profile.upgrades.factoryTier
	local valueByUid: { [string]: number } = {}
	for _, instance in group do
		valueByUid[instance.uid] =
			Catalog.GetSellValue(instance.id, factoryTier, instance.mutation, profile.rebirths, instance.stars, instance.ageSeconds)
	end
	table.sort(group, function(a, b)
		local valueA, valueB = valueByUid[a.uid], valueByUid[b.uid]
		if valueA ~= valueB then
			return valueA < valueB
		end
		return a.uid < b.uid
	end)
	local uids: { string } = {}
	for i = 1, GameConfig.Fusion.Required do
		table.insert(uids, group[i].uid)
	end

	-- Everything below is synchronous (no yields), so the checks above cannot
	-- go stale mid-fuse. RemoveKeyboards MarkDirty+Syncs for us.
	local removed = InventoryService.RemoveKeyboards(player, uids)
	if #removed ~= GameConfig.Fusion.Required then
		-- Lost a race with another consumer of these uids: put back whatever
		-- was taken rather than vaporize it (collection counts track "ever
		-- collected" and were never decremented, so a plain re-insert is safe).
		for _, instance in removed do
			table.insert(profile.keyboards, instance)
		end
		DataService.MarkDirty(player)
		DataService.Sync(player)
		return
	end

	local resultStars = math.min(chosenStars + 1, GameConfig.Fusion.MaxStars)
	-- Mutations don't carry through the forge — the result is a clean board
	-- whose power is its stars.
	local result = InventoryService.AddKeyboard(player, keyboardId, "fusion", nil, resultStars)
	if result == nil then
		-- Should be unreachable (we just freed Required slots and the id
		-- resolved above); if AddKeyboard ever refuses, refund the inputs.
		for _, instance in removed do
			table.insert(profile.keyboards, instance)
		end
		DataService.MarkDirty(player)
		DataService.Sync(player)
		return
	end

	local starText = string.rep("★", resultStars)
	Remotes.Notify:FireClient(
		player,
		"info",
		`Fused {GameConfig.Fusion.Required}x {def.name} into a {starText} {def.name}!`
	)
	-- High-star results are a server-wide spectacle.
	if resultStars >= 3 then
		Remotes.Notify:FireAllClients("flex", `⚒ {player.Name} forged a {starText} {def.name} at the Fusion Forge!`)
	end
end

function FusionService.Init()
	-- Dependencies are wired via the module requires above.
end

function FusionService.Start()
	Remotes.FuseRequest.OnServerEvent:Connect(onFuseRequest)

	Players.PlayerRemoving:Connect(function(player)
		lastFuseAt[player] = nil
	end)
end

return FusionService
