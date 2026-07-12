--!strict
-- Single source of truth for all RemoteEvents. Server requires this first
-- (creates instances); clients require it and get the same references.
--
-- Client -> Server:
--   SellRequest(mode: "uids" | "belowTier", payload: {string} | number)
--   EquipRequest(uid: string?)            -- nil unequips
--   DisplayRequest(standIndex: number, uid: string?)  -- nil clears the stand
--   TypeKeyRequest()                      -- one keypress on equipped keyboard
--
-- Server -> Client:
--   DataSync(snapshot: Types.ProfileSnapshot)   -- full-state sync after any change
--   KeyboardCollected(payload: Types.CollectedPayload)
--   OfflineReport(payload: Types.OfflinePayload)
--   Notify(kind: string, message: string)       -- "info" | "error" | "flex"
--   SoundPulse(originPart: Instance, keyboardId: string) -- replicated keypress for nearby players

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REMOTE_NAMES = {
	"SellRequest",
	"EquipRequest",
	"DisplayRequest",
	"TypeKeyRequest",
	"DataSync",
	"KeyboardCollected",
	"OfflineReport",
	"Notify",
	"SoundPulse",
	-- phase 2
	"RebirthRequest", -- client -> server: perform rebirth (validated server-side)
	"ClaimIndexReward", -- client -> server: rewardId string
	"RaceState", -- server -> client: { phase, endsAt, scores? } typing-race updates
	-- phase 3
	"GlobalRoll", -- server -> ALL clients: { playerName, keyboardId, mutation?, rarityTier, plotIndex, oddsDenominator } big-roll spectacle
	"GiftRequest", -- client -> server: (targetUserId: number, uid: string) gift a keyboard to an online player
	"SellReport", -- server -> client: { count, total, bestId, bestValue, mutationBonus } for the sell ceremony
	"BuyRestockItem", -- client -> server: slotIndex number, buy from the hub restock stall
	"RestockSync", -- server -> ALL clients: { restockAt, slots = { { offerId, stockLeft, price } } }
}

local Remotes = {}

local function getFolder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
		if not folder then
			local newFolder = Instance.new("Folder")
			newFolder.Name = "Remotes"
			newFolder.Parent = ReplicatedStorage
			folder = newFolder
		end
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

local folder = getFolder()

for _, name in REMOTE_NAMES do
	if RunService:IsServer() then
		local remote = folder:FindFirstChild(name) :: RemoteEvent?
		if not remote then
			local newRemote = Instance.new("RemoteEvent")
			newRemote.Name = name
			newRemote.Parent = folder
			remote = newRemote
		end
		Remotes[name] = remote :: RemoteEvent
	else
		Remotes[name] = folder:WaitForChild(name) :: RemoteEvent
	end
end

return Remotes :: { [string]: RemoteEvent }
