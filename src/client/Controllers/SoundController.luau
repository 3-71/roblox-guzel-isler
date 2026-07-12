--!strict
-- All keyboard audio on the client: collect sounds, replicated typing from
-- other players (SoundPulse), and the local typing loop for the equipped
-- keyboard (play instantly, then tell the server so others hear it too).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("GameConfig"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local SoundController = {}

local rng = Random.new()
local currentProfile: Types.Profile? = nil

local STING_SOUND = "rbxasset://sounds/electronicpingshort.wav"

type SoundSpec = {
	layers: { { soundId: string, playbackSpeed: number, volume: number } },
	jitter: number,
}

local function playLayers(spec: SoundSpec, parent3D: Instance?, pitchMult: number?, extraJitter: number?)
	local totalJitter = math.max(spec.jitter + (extraJitter or 0), 0)
	for _, layer in spec.layers do
		local sound = Instance.new("Sound")
		sound.SoundId = layer.soundId
		sound.Volume = layer.volume
		local jitter = 1 + rng:NextNumber(-totalJitter, totalJitter)
		sound.PlaybackSpeed = math.max(layer.playbackSpeed * (pitchMult or 1) * jitter, 0.05)
		if parent3D then
			sound.RollOffMaxDistance = GameConfig.TypeSoundRange
			sound.RollOffMinDistance = 8
			sound.Parent = parent3D
		else
			sound.Parent = SoundService
		end
		sound:Play()
		Debris:AddItem(sound, 6)
	end
end

function SoundController.PlayKeyboard(keyboardId: string, parent3D: Instance?, mutation: string?)
	local def = Catalog.GetKeyboard(keyboardId)
	if not def then
		return
	end
	local mutationDef = Catalog.GetMutation(mutation)
	if mutationDef then
		playLayers(def.sound, parent3D, mutationDef.soundPitchMult, mutationDef.extraJitter)
	else
		playLayers(def.sound, parent3D)
	end
end

function SoundController.PlayUiClick()
	local sound = Instance.new("Sound")
	sound.SoundId = STING_SOUND
	sound.Volume = 0.25
	sound.PlaybackSpeed = 1.6 + rng:NextNumber(-0.05, 0.05)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- One PING at the given volume/pitch: the building block for the ceremony
-- sounds below (slot ticks, sell ticks, reveal arpeggio).
local function playPing(volume: number, playbackSpeed: number)
	local sound = Instance.new("Sound")
	sound.SoundId = STING_SOUND
	sound.Volume = volume
	sound.PlaybackSpeed = math.max(playbackSpeed, 0.05)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- Ceremony slot-wheel tick: rises one semitone per swap (i = swap index).
function SoundController.PlaySlotTick(i: number)
	playPing(0.12, 0.8 * 2 ^ (i / 12))
end

-- Sell count-up tick: pitch rises with progress (0..1) through the payout.
function SoundController.PlaySellTick(progress: number)
	progress = math.clamp(progress, 0, 1)
	playPing(0.3, 1 + 1.2 * progress)
end

-- Reveal arpeggio: one rising note per rarity tier (capped at 8), staggered
-- 0.07s apart, volume ramping 0.4 -> 0.9 into the final note.
function SoundController.PlayRevealArpeggio(tier: number)
	local notes = math.clamp(math.floor(tier), 1, 8)
	for k = 1, notes do
		local volume = 0.4 + 0.5 * (k - 1) / math.max(notes - 1, 1)
		task.delay(0.07 * (k - 1), function()
			playPing(volume, 2 ^ ((k * 3) / 12))
		end)
	end
end

-- client-side throttle mirroring the server's rate limit
local lastTypeSent = 0

local function onTypingInput()
	if UserInputService:GetFocusedTextBox() then
		return
	end
	local profile = currentProfile
	if not profile or not profile.equippedUid then
		return
	end
	local equipped: Types.KeyboardInstance? = nil
	for _, instance in profile.keyboards do
		if instance.uid == profile.equippedUid then
			equipped = instance
			break
		end
	end
	if not equipped then
		return
	end

	SoundController.PlayKeyboard(equipped.id, nil, equipped.mutation)

	local now = os.clock()
	if now - lastTypeSent >= 1 / GameConfig.TypeRateLimitPerSecond then
		lastTypeSent = now
		Remotes.TypeKeyRequest:FireServer()
	end
end

function SoundController.Start()
	Remotes.DataSync.OnClientEvent:Connect(function(snapshot: Types.Profile)
		currentProfile = snapshot
	end)

	Remotes.KeyboardCollected.OnClientEvent:Connect(function(payload: Types.CollectedPayload)
		-- Ceremony-worthy rolls are scored by the reveal ceremony instead:
		-- UIController drives PlaySlotTick per wheel swap, PlayRevealArpeggio
		-- at the reveal, then PlayKeyboard 0.4s later. Everything else gets
		-- its collect sound immediately.
		if payload.rarityTier >= GameConfig.CelebrateMinTier or payload.mutation ~= nil then
			return
		end
		SoundController.PlayKeyboard(payload.keyboardId, nil, payload.mutation)
	end)

	Remotes.SoundPulse.OnClientEvent:Connect(function(originPart: Instance?, keyboardId: string, mutation: string?)
		if typeof(originPart) == "Instance" and originPart:IsA("BasePart") then
			SoundController.PlayKeyboard(keyboardId, originPart, mutation)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard
			or input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			onTypingInput()
		end
	end)
end

return SoundController
