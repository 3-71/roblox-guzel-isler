--!strict
-- GiftService — player-to-player keyboard gifting (Phase 3).
--
-- Contract (ARCHITECTURE.md):
--   GiftRequest remote (targetUserId: number, uid: string):
--     - rate limit: 1 request per 2s per sender (excess dropped silently)
--     - target must be online in this server with a loaded profile and room
--       in their inventory (GameConfig.InventoryCap)
--     - uid must be owned by the sender, not equipped, not on display
--     - transfer moves THE SAME instance table (uid/id/mutation/obtainedAt
--       preserved): InventoryService.RemoveKeyboards(sender, {uid}) then
--       append to the target's profile.keyboards + collection bump +
--       KeyboardCollected(source = "gift") to the target
--     - Notify both players; server-wide flex for tier >= GlobalFlexMinTier
--
-- RemoveKeyboards already MarkDirty+Syncs the sender; this service only has
-- to MarkDirty+Sync the target after appending.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local GameConfig = require(Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

local GiftService = {}

local GIFT_COOLDOWN_SECONDS = 2 -- contract: 1 GiftRequest per 2s per sender

-- os.clock() of each sender's last (attempted) gift.
local lastGiftAt: { [Player]: number } = {}

local function onGiftRequest(sender: Player, targetUserId: unknown, uid: unknown)
	-- Rate limit first, before any validation work; counting attempts (not
	-- just successes) keeps failed-probe spam cheap too.
	local now = os.clock()
	local last = lastGiftAt[sender]
	if last ~= nil and now - last < GIFT_COOLDOWN_SECONDS then
		return
	end
	lastGiftAt[sender] = now

	-- Type validation: nothing on the client's word.
	if typeof(targetUserId) ~= "number" or targetUserId ~= targetUserId then
		return -- not a number / NaN
	end
	if targetUserId ~= math.floor(targetUserId) then
		return -- user ids are integers
	end
	if typeof(uid) ~= "string" then
		return
	end

	local senderProfile = DataService.GetProfile(sender)
	if senderProfile == nil then
		return
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil or target == sender then
		Remotes.Notify:FireClient(sender, "error", "That player isn't in this server.")
		return
	end
	local targetProfile = DataService.GetProfile(target)
	if targetProfile == nil then
		Remotes.Notify:FireClient(sender, "error", `{target.Name} isn't ready to receive gifts yet.`)
		return
	end
	if #targetProfile.keyboards >= GameConfig.InventoryCap then
		Remotes.Notify:FireClient(sender, "error", `{target.Name}'s inventory is full!`)
		return
	end

	-- The gifted keyboard: owned by the sender, not equipped, not on display.
	local instance = InventoryService.GetKeyboard(sender, uid)
	if instance == nil then
		Remotes.Notify:FireClient(sender, "error", "You don't own that keyboard.")
		return
	end
	if senderProfile.equippedUid == uid then
		Remotes.Notify:FireClient(sender, "error", "Unequip that keyboard before gifting it.")
		return
	end
	for _, displayedUid in senderProfile.displayed do
		if displayedUid == uid then
			Remotes.Notify:FireClient(sender, "error", "Take that keyboard off display before gifting it.")
			return
		end
	end

	local def = Catalog.GetKeyboard(instance.id)
	if def == nil then
		return -- corrupt instance; never transfer something we can't resolve
	end

	-- Transfer. Everything below is synchronous (no yields), so the checks
	-- above cannot go stale mid-transfer. RemoveKeyboards MarkDirty+Syncs the
	-- sender for us.
	local removed = InventoryService.RemoveKeyboards(sender, { uid })
	if #removed == 0 then
		return -- lost a race with another consumer of this uid
	end
	local gifted = removed[1]

	-- Append THE SAME instance table: uid/id/mutation/obtainedAt all survive
	-- the transfer (the uid stays globally unique because it just left the
	-- sender's profile).
	table.insert(targetProfile.keyboards, gifted)
	targetProfile.collection[gifted.id] = (targetProfile.collection[gifted.id] or 0) + 1
	DataService.MarkDirty(target)
	DataService.Sync(target)

	local payload: Types.CollectedPayload = {
		keyboardId = gifted.id,
		uid = gifted.uid,
		rarityTier = def.rarityTier,
		source = "gift",
		mutation = gifted.mutation,
	}
	Remotes.KeyboardCollected:FireClient(target, payload)

	Remotes.Notify:FireClient(sender, "info", `You gifted {def.name} to {target.Name}!`)
	Remotes.Notify:FireClient(target, "info", `{sender.Name} gifted you {def.name}!`)

	-- Big gifts are a server-wide spectacle, same threshold as big rolls.
	local rarity = Catalog.GetRarity(def.rarityTier)
	if rarity ~= nil and rarity.tier >= GameConfig.GlobalFlexMinTier then
		local mutationDef = Catalog.GetMutation(gifted.mutation)
		local what = if mutationDef then mutationDef.name .. " " .. rarity.name else rarity.name
		Remotes.Notify:FireAllClients(
			"flex",
			`{sender.Name} gifted a {what} {def.name} to {target.Name}!`
		)
	end
end

function GiftService.Init()
	-- Dependencies are wired via the module requires above.
end

function GiftService.Start()
	Remotes.GiftRequest.OnServerEvent:Connect(onGiftRequest)

	Players.PlayerRemoving:Connect(function(player)
		lastGiftAt[player] = nil
	end)
end

return GiftService
