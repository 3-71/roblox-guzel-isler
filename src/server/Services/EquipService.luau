--!strict
-- Equipping: hold a keyboard from your inventory and type on it — the sound
-- is the flex. Handles the held visual (welded to the hand) and relays
-- typing pulses to nearby players (the sender's client plays its own sound
-- locally; SoundPulse goes to everyone else in range).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local KeyboardModel = require(Shared.World.KeyboardModel)

local EquipService = {}

local heldModels: { [Player]: Model } = {}
local characterConns: { [Player]: RBXScriptConnection } = {}
-- token buckets per player for TypeKeyRequest / EquipRequest
local typeTokens: { [Player]: { tokens: number, last: number } } = {}
local equipTokens: { [Player]: { tokens: number, last: number } } = {}
-- subscribers to accepted typing keypresses (see OnTypeAccepted)
local typeAcceptedCallbacks: { (Player) -> () } = {}

local rng = Random.new()

local function destroyHeld(player: Player)
	local model = heldModels[player]
	if model then
		model:Destroy()
		heldModels[player] = nil
	end
end

local function attachHeld(player: Player)
	destroyHeld(player)
	local profile = DataService.GetProfile(player)
	local uid = profile and profile.equippedUid
	if not profile or not uid then
		return
	end
	local instance = InventoryService.GetKeyboard(player, uid)
	if not instance then
		profile.equippedUid = nil
		return
	end
	local def = Catalog.GetKeyboard(instance.id)
	local character = player.Character
	if not def or not character then
		return
	end
	local hand = (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")) :: BasePart?
	if not hand then
		return
	end

	local mutationDef = Catalog.GetMutation(instance.mutation)
	local ok, model = pcall(KeyboardModel.Build, def :: any, 0.45, mutationDef)
	if not ok or typeof(model) ~= "Instance" then
		return
	end
	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return
	end

	-- held flat in front of the hand, like a tray of pure thock
	local offset = CFrame.new(0, -0.6, -1.1) * CFrame.Angles(math.rad(15), 0, 0)
	model:PivotTo(hand.CFrame * offset)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = primary
	weld.Parent = primary
	-- weld every other part to the primary so the model stays rigid
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= primary then
			local w = Instance.new("WeldConstraint")
			w.Part0 = primary
			w.Part1 = part
			w.Parent = part
		end
	end

	model.Name = "HeldKeyboard"
	model.Parent = character
	heldModels[player] = model
end

local function takeEquipToken(player: Player): boolean
	local bucket = equipTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 4, last = now }
		equipTokens[player] = bucket
	end
	bucket.tokens = math.min(4, bucket.tokens + (now - bucket.last) * GameConfig.EquipRateLimitPerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function onEquipRequest(player: Player, uid: unknown)
	if not takeEquipToken(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end

	-- No-op requests skip model rebuilds and full-profile syncs entirely —
	-- EXCEPT re-equipping the same uid with no held visual, which repairs a
	-- failed/missing hand attach.
	if uid == nil and profile.equippedUid == nil then
		return
	end
	if uid == profile.equippedUid and heldModels[player] ~= nil then
		return
	end

	if uid == nil then
		profile.equippedUid = nil
		destroyHeld(player)
	else
		if typeof(uid) ~= "string" then
			return
		end
		local instance = InventoryService.GetKeyboard(player, uid)
		if not instance then
			return
		end
		for _, displayedUid in profile.displayed do
			if displayedUid == uid then
				Remotes.Notify:FireClient(player, "error", "Take that keyboard off its display stand first!")
				return
			end
		end
		profile.equippedUid = uid
		attachHeld(player)
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
end

local function takeTypeToken(player: Player): boolean
	local bucket = typeTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 4, last = now }
		typeTokens[player] = bucket
	end
	bucket.tokens = math.min(4, bucket.tokens + (now - bucket.last) * GameConfig.TypeRateLimitPerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function onTypeKeyRequest(player: Player)
	if not takeTypeToken(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile or not profile.equippedUid then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local model = heldModels[player]
	local primary = model and model.PrimaryPart
	if not root or not model or not primary then
		return
	end
	local instance = InventoryService.GetKeyboard(player, profile.equippedUid :: string)
	if not instance then
		return
	end

	-- typing visual: flicker a random keycap to neon for a beat
	local parts = model:GetChildren()
	for _ = 1, 2 do
		local candidate = parts[rng:NextInteger(1, #parts)]
		if candidate and candidate:IsA("BasePart") and candidate ~= primary then
			local originalMaterial = candidate.Material
			candidate.Material = Enum.Material.Neon
			task.delay(0.08, function()
				if candidate.Parent then
					candidate.Material = originalMaterial
				end
			end)
		end
	end

	-- relay to everyone else in earshot; sender already played it locally
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if otherRoot and (otherRoot.Position - root.Position).Magnitude <= GameConfig.TypeSoundRange then
				Remotes.SoundPulse:FireClient(other, primary, instance.id, instance.mutation)
			end
		end
	end

	for _, callback in typeAcceptedCallbacks do
		task.spawn(callback, player)
	end
end

-- Fired after a TypeKeyRequest passes rate limiting + equip validation.
-- Used by TypingRaceService to count race keypresses.
function EquipService.OnTypeAccepted(callback: (Player) -> ())
	table.insert(typeAcceptedCallbacks, callback)
end

function EquipService.Init() end

function EquipService.Start()
	Remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	Remotes.TypeKeyRequest.OnServerEvent:Connect(onTypeKeyRequest)

	DataService.OnProfileLoaded(function(player, _profile)
		if characterConns[player] then
			return
		end
		characterConns[player] = player.CharacterAdded:Connect(function()
			task.wait(0.3) -- let limbs/hand exist
			attachHeld(player)
		end)
		if player.Character then
			attachHeld(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		destroyHeld(player)
		local conn = characterConns[player]
		if conn then
			conn:Disconnect()
			characterConns[player] = nil
		end
		typeTokens[player] = nil
		equipTokens[player] = nil
	end)
end

return EquipService
