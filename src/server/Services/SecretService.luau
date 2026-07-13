--!strict
-- SecretService — ritual secret keyboards. Three boards in Config/Keyboards
-- carry `secret = true` and never roll (RollLogic skips them); they are
-- granted here instead:
--   the_password — type the sacred word ("THOCK") on any equipped keyboard
--   oofboard     — type the legend's cry ("OOF")
--   wholesome    — give GameConfig.Secrets.WholesomeLikes likes to other
--                  farms (LikeService counts likesGiven, calls CheckWholesome)
-- Typed rituals ride EquipService.OnTypeAccepted (already rate-limited and
-- equip-validated); each player keeps a rolling buffer of the last
-- BUFFER_MAX accepted letters, cleared on unequip and on leave. Grants go
-- through the normal InventoryService.AddKeyboard path (source "secret") so
-- the full ceremony fires, and each secret lands at most once per profile.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local EquipService = require(script.Parent.EquipService)

-- Longest ritual is 5 letters; 12 leaves slack without unbounded growth.
local BUFFER_MAX = 12

-- Typed rituals: buffer suffix -> secret keyboard id. The sequences ARE the
-- secret (not balance numbers), so they live here rather than in Config.
local SEQUENCES: { { sequence: string, keyboardId: string } } = {
	{ sequence = "THOCK", keyboardId = "the_password" },
	{ sequence = "OOF", keyboardId = "oofboard" },
}

local SecretService = {}

-- player -> rolling buffer of accepted ritual letters (uppercase A-Z/0-9)
local buffers: { [Player]: string } = {}

-- A secret may only ever be granted once per profile: check the collection
-- index AND the live inventory before adding. Returns true if a grant landed.
local function tryGrant(player: Player, keyboardId: string): boolean
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return false
	end
	if (profile.collection[keyboardId] or 0) > 0 then
		return false
	end
	for _, instance in profile.keyboards do
		if instance.id == keyboardId then
			return false
		end
	end
	-- Normal AddKeyboard path: KeyboardCollected ceremony, server flex,
	-- MarkDirty + Sync all fire in there.
	local instance = InventoryService.AddKeyboard(player, keyboardId, "secret")
	if instance == nil then
		-- Inventory at cap. Nothing is marked, so the ritual stays
		-- repeatable — the player can make room and perform it again.
		Remotes.Notify:FireClient(player, "error", "A secret stirred... but your inventory is full!")
		return false
	end
	return true
end

local function onTypeAccepted(player: Player, letter: string?)
	if letter == nil then
		return
	end
	local buffer = string.sub((buffers[player] or "") .. letter, -BUFFER_MAX)
	buffers[player] = buffer
	for _, ritual in SEQUENCES do
		if string.sub(buffer, -#ritual.sequence) == ritual.sequence then
			if tryGrant(player, ritual.keyboardId) then
				buffers[player] = "" -- fresh start after a landed ritual
			end
		end
	end
end

-- Grants the Wholesome secret once the player has given enough likes.
-- Called by LikeService right after it bumps the giver's likesGiven, and on
-- profile load (recovers a grant that missed earlier because the inventory
-- was full at the moment the threshold was crossed).
function SecretService.CheckWholesome(player: Player)
	local profile = DataService.GetProfile(player)
	if profile == nil or profile.likesGiven < GameConfig.Secrets.WholesomeLikes then
		return
	end
	tryGrant(player, "wholesome")
end

function SecretService.Init() end

function SecretService.Start()
	EquipService.OnTypeAccepted(onTypeAccepted)
	EquipService.OnUnequipped(function(player)
		buffers[player] = nil
	end)

	DataService.OnProfileLoaded(function(player, _profile)
		SecretService.CheckWholesome(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		buffers[player] = nil
	end)
end

return SecretService
