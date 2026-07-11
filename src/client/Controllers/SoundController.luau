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

local function playLayers(spec: SoundSpec, parent3D: Instance?)
	for _, layer in spec.layers do
		local sound = Instance.new("Sound")
		sound.SoundId = layer.soundId
		sound.Volume = layer.volume
		local jitter = 1 + rng:NextNumber(-spec.jitter, spec.jitter)
		sound.PlaybackSpeed = math.max(layer.playbackSpeed * jitter, 0.05)
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

function SoundController.PlayKeyboard(keyboardId: string, parent3D: Instance?)
	local def = Catalog.GetKeyboard(keyboardId)
	if def then
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

local function playCelebrationSting()
	for i, speed in { 0.8, 1.0, 1.3 } do
		task.delay(0.12 * (i - 1), function()
			local sound = Instance.new("Sound")
			sound.SoundId = STING_SOUND
			sound.Volume = 0.7
			sound.PlaybackSpeed = speed
			sound.Parent = SoundService
			sound:Play()
			Debris:AddItem(sound, 3)
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

	SoundController.PlayKeyboard(equipped.id)

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
		SoundController.PlayKeyboard(payload.keyboardId)
		if payload.rarityTier >= GameConfig.CelebrateMinTier then
			playCelebrationSting()
		end
	end)

	Remotes.SoundPulse.OnClientEvent:Connect(function(originPart: Instance?, keyboardId: string)
		if typeof(originPart) == "Instance" and originPart:IsA("BasePart") then
			SoundController.PlayKeyboard(keyboardId, originPart)
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
