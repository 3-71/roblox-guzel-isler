--!strict
-- SetsService — auto-claims completed collection sets (Phase 4).
--
-- Contract (ARCHITECTURE.md):
--   CheckSets(player): for each Config/Sets SetDef not yet in
--     profile.setsClaimed, if all 6 keyboardIds are discovered
--     (profile.collection[id] > 0), set profile.setsClaimed[set.id] = true
--     and Notify ALL ("flex"). One MarkDirty + Sync covers every set claimed
--     in the same call; nothing syncs when no set completes, so calling this
--     after every collect stays cheap.
--   The permanent luck reward needs no wiring here — RollLogic.GetEffectiveLuck
--     reads profile.setsClaimed directly.
--   Called from: DataService.OnProfileLoaded (claims sets completed before
--     this update), and by InventoryService at the END of every AddKeyboard
--     via a lazy pcall require (see InventoryService — avoids a require cycle).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Remotes = require(Shared.Remotes)
local Sets = require(Shared.Config.Sets)

local DataService = require(script.Parent.DataService)

local SetsService = {}

-- Claims every newly-completed set for the player. Idempotent: already
-- claimed sets are skipped forever (setsClaimed persists in the profile).
function SetsService.CheckSets(player: Player)
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	-- Saves from before this update may predate the reconcile of setsClaimed;
	-- self-heal instead of erroring (same defensive stance as profile.passes).
	local setsClaimed = profile.setsClaimed
	if setsClaimed == nil then
		setsClaimed = {}
		profile.setsClaimed = setsClaimed
	end

	local claimedAny = false
	for _, set in Sets do
		if not setsClaimed[set.id] then
			local complete = true
			for _, keyboardId in set.keyboardIds do
				local count = profile.collection[keyboardId]
				if count == nil or count <= 0 then
					complete = false
					break
				end
			end
			if complete then
				setsClaimed[set.id] = true
				claimedAny = true
				Remotes.Notify:FireAllClients(
					"flex",
					`{player.Name} completed the {set.name} set (+{set.luckBonus} permanent luck)!`
				)
			end
		end
	end

	if claimedAny then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
end

function SetsService.Init() end

function SetsService.Start()
	-- Claim sets that were completed before this update existed (the luck
	-- starts applying on this very session's first roll).
	DataService.OnProfileLoaded(function(player, _profile)
		SetsService.CheckSets(player)
	end)
end

return SetsService
