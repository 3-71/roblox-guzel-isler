--!strict
-- TitleService — earnable titles & auras (Phase 6 item 2). Pure flex: a
-- "TitleTag" nameplate above the character's head plus a subtle particle
-- aura on the HumanoidRootPart. No gameplay stats. Titles are earned from
-- profile milestones (Config/Titles earn defs), stored forever in
-- profile.titles, and one may be equipped (profile.equippedTitle).
--
-- Contract (ARCHITECTURE.md Phase 6 item 2):
--   StatFor(profile, kind) — maps Config/Titles earn kinds to profile stats.
--     UIController keeps a display-only client twin (titleStatFor) that MUST
--     stay in lockstep with this mapping:
--       unique   = # keys in profile.collection
--       sets     = # keys in profile.setsClaimed
--       secrets  = # collection keys whose Keyboards def has secret == true
--       earned   = profile.totalEarned
--       rebirths / bossWins / raceWins / likesGiven / streakDays = same-name
--       profile fields
--   Unlock sweep on profile load + a 60s loop: newly earned -> titles[id] =
--     true + celebratory Notify, ONE MarkDirty+Sync per sweep.
--   TitleEquip remote (3/s token bucket): string-or-nil, must be owned; sets
--     profile.equippedTitle + MarkDirty/Sync + reapplies visuals.
--
-- Visuals (reapplied on CharacterAdded, removed on unequip/leave):
--   * "TitleTag" BillboardGui on the Head — title name in the def color with
--     a subtle stroke. AlwaysOnTop=false, MaxDistance 60, and offset 2.8
--     studs ABOVE the head so it never fights the engine's own name/health
--     display.
--   * One "TitleAura" ParticleEmitter on the HumanoidRootPart per aura kind
--     (sparkle/gold/fire/hearts/storm/rainbow). ENGINE textures only
--     (rbxasset:// particle sheets); Rate <= 8 on every preset so auras
--     never melt low-end devices. "rainbow" cycles hue via one small shared
--     task (no per-player loops).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Catalog)
local Remotes = require(Shared.Remotes)
local Titles = require(Shared.Config.Titles)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)

local TitleService = {}

local UNLOCK_SWEEP_SECONDS = 60 -- catches stats bumped by other services (boss wins, likes, ...)
local RAINBOW_STEP_SECONDS = 0.15 -- hue cycle cadence for "rainbow" auras
local RAINBOW_HUE_SPEED = 0.12 -- full hue loops per second

-- Nameplate: above the engine's own overhead name/health UI, close-range only.
local TAG_OFFSET = Vector3.new(0, 2.8, 0)
local TAG_MAX_DISTANCE = 60

-- Engine-shipped particle sheets (present in every client install — no
-- external asset ids, same rule as the keyboard sounds).
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"

-- ===== Aura presets =====
-- Contract: Rate <= 8 everywhere (subtle on purpose — low-end devices).

type AuraPreset = {
	texture: string,
	color: ColorSequence,
	rate: number,
	size: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: Vector2,
	acceleration: Vector3,
}

local AURA_PRESETS: { [string]: AuraPreset } = {
	sparkle = {
		texture = SPARKLE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(210, 235, 255), Color3.fromRGB(255, 255, 255)),
		rate = 6,
		size = 0.22,
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(0.4, 1),
		spread = Vector2.new(180, 180),
		acceleration = Vector3.new(0, 0.6, 0),
	},
	gold = {
		texture = SPARKLE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(255, 214, 90), Color3.fromRGB(255, 240, 180)),
		rate = 7,
		size = 0.26,
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(0.5, 1.1),
		spread = Vector2.new(180, 180),
		acceleration = Vector3.new(0, 0.9, 0),
	},
	fire = {
		texture = FIRE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(255, 150, 50), Color3.fromRGB(255, 90, 40)),
		rate = 8,
		size = 0.55,
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(1.2, 2.2),
		spread = Vector2.new(25, 25),
		acceleration = Vector3.new(0, 1.5, 0),
	},
	hearts = {
		texture = SPARKLE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(255, 120, 190), Color3.fromRGB(255, 180, 220)),
		rate = 5,
		size = 0.3,
		lifetime = NumberRange.new(1.4, 2.2),
		speed = NumberRange.new(0.5, 0.9),
		spread = Vector2.new(180, 180),
		acceleration = Vector3.new(0, 0.8, 0),
	},
	storm = {
		texture = SPARKLE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(150, 200, 255), Color3.fromRGB(230, 245, 255)),
		rate = 8,
		size = 0.2,
		lifetime = NumberRange.new(0.35, 0.7),
		speed = NumberRange.new(2.5, 4),
		spread = Vector2.new(180, 60),
		acceleration = Vector3.zero,
	},
	rainbow = {
		texture = SPARKLE_TEXTURE,
		color = ColorSequence.new(Color3.fromRGB(255, 120, 120)), -- overwritten by the hue cycler
		rate = 8,
		size = 0.28,
		lifetime = NumberRange.new(1, 1.8),
		speed = NumberRange.new(0.6, 1.2),
		spread = Vector2.new(180, 180),
		acceleration = Vector3.new(0, 0.7, 0),
	},
}

-- ===== State =====

type VisualEntry = {
	tag: BillboardGui,
	aura: ParticleEmitter?,
	titleId: string,
	rainbow: boolean,
}

local titleById: { [string]: Titles.TitleDef } = {}
local visuals: { [Player]: VisualEntry } = {}
local characterConns: { [Player]: RBXScriptConnection } = {}

-- ===== TitleEquip token bucket (contract: 3/s per player) =====

local EQUIP_RATE_PER_SECOND = 3

local equipTokens: { [Player]: { tokens: number, last: number } } = {}

local function takeEquipToken(player: Player): boolean
	local bucket = equipTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 3, last = now }
		equipTokens[player] = bucket
	end
	bucket.tokens = math.min(3, bucket.tokens + (now - bucket.last) * EQUIP_RATE_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- ===== Stat mapping =====

-- Current progress toward an earn kind, read straight off the profile.
-- UIController.titleStatFor is the display-only client twin of this mapping —
-- change BOTH or locked-card progress bars will lie.
function TitleService.StatFor(profile: Types.Profile, kind: string): number
	if kind == "unique" then
		local n = 0
		for _ in profile.collection do
			n += 1
		end
		return n
	elseif kind == "sets" then
		local n = 0
		if profile.setsClaimed ~= nil then
			for _ in profile.setsClaimed do
				n += 1
			end
		end
		return n
	elseif kind == "secrets" then
		-- Secret boards carry `secret = true` on their Keyboards def and only
		-- enter the collection via SecretService rituals.
		local n = 0
		for id in profile.collection do
			local def = Catalog.GetKeyboard(id)
			if def ~= nil and def.secret == true then
				n += 1
			end
		end
		return n
	elseif kind == "earned" then
		return profile.totalEarned
	elseif kind == "rebirths" then
		return profile.rebirths
	elseif kind == "bossWins" then
		return profile.bossWins or 0
	elseif kind == "raceWins" then
		return profile.raceWins or 0
	elseif kind == "likesGiven" then
		return profile.likesGiven or 0
	elseif kind == "streakDays" then
		return profile.streakDays or 0
	end
	return 0
end

-- The equipped title's def, or nil when nothing valid is equipped. Tolerates
-- corrupt saves (unknown or unowned equipped id -> treated as unequipped).
local function equippedDef(profile: Types.Profile): Titles.TitleDef?
	local id = profile.equippedTitle
	if id == nil then
		return nil
	end
	local def = titleById[id]
	if def == nil then
		return nil
	end
	local owned = profile.titles
	if owned == nil or owned[id] ~= true then
		return nil
	end
	return def
end

-- ===== Unlocks =====

-- Grants every newly-earned title. Idempotent — owned ids are skipped forever
-- (profile.titles persists). One MarkDirty+Sync covers all grants in a call;
-- nothing syncs when nothing unlocks, so the 60s sweep stays cheap.
function TitleService.CheckUnlocks(player: Player)
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	-- Saves from before the Phase 6 reconcile may lack the table; self-heal
	-- (same defensive stance as profile.buddies / setsClaimed).
	local owned = profile.titles
	if owned == nil then
		owned = {}
		profile.titles = owned
	end

	local unlockedAny = false
	for _, def in Titles do
		if owned[def.id] ~= true and TitleService.StatFor(profile, def.earn.kind) >= def.earn.count then
			owned[def.id] = true
			unlockedAny = true
			Remotes.Notify:FireClient(
				player,
				"flex",
				`👑 Title unlocked: {def.name}! Equip it from the Titles panel.`
			)
		end
	end

	if unlockedAny then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
end

-- ===== Visuals =====

local function removeVisuals(player: Player)
	local entry = visuals[player]
	if entry == nil then
		return
	end
	visuals[player] = nil
	entry.tag:Destroy()
	local aura = entry.aura
	if aura ~= nil then
		aura:Destroy()
	end
end

-- Builds the nameplate + aura for the player's CURRENT equipped title on the
-- CURRENT character. No-ops (leaving nothing behind) when unequipped, the
-- profile isn't loaded, or the character isn't assembled yet — CharacterAdded
-- and the equip handler both re-enter here.
local function applyVisuals(player: Player)
	removeVisuals(player)

	local profile = DataService.GetProfile(player)
	local def = if profile ~= nil then equippedDef(profile) else nil
	local character = player.Character
	if def == nil or character == nil or character.Parent == nil then
		return
	end
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if head == nil or not head:IsA("BasePart") or root == nil or not root:IsA("BasePart") then
		return
	end

	-- Belt & braces: clear strays from a previous application race (the
	-- tracked copies were destroyed above; character-scoped ones die with the
	-- character anyway).
	for _, child in head:GetChildren() do
		if child.Name == "TitleTag" then
			child:Destroy()
		end
	end
	for _, child in root:GetChildren() do
		if child.Name == "TitleAura" then
			child:Destroy()
		end
	end

	-- Nameplate: above the engine's own overhead UI, close range, never
	-- through walls (AlwaysOnTop stays false per contract).
	local tag = Instance.new("BillboardGui")
	tag.Name = "TitleTag"
	tag.Adornee = head
	tag.Size = UDim2.new(7, 0, 1.1, 0)
	tag.StudsOffsetWorldSpace = TAG_OFFSET
	tag.MaxDistance = TAG_MAX_DISTANCE
	tag.AlwaysOnTop = false
	tag.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = def.name
	label.TextScaled = true
	label.TextColor3 = def.color
	label.TextStrokeColor3 = Color3.fromRGB(40, 34, 28)
	label.TextStrokeTransparency = 0.5 -- subtle stroke per contract
	label.Parent = tag
	tag.Parent = head

	local aura: ParticleEmitter? = nil
	local preset = AURA_PRESETS[def.aura]
	if preset ~= nil then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "TitleAura"
		emitter.Texture = preset.texture
		emitter.Color = preset.color
		emitter.Rate = preset.rate -- contract: <= 8, always
		emitter.Size = NumberSequence.new(preset.size)
		emitter.Lifetime = preset.lifetime
		emitter.Speed = preset.speed
		emitter.SpreadAngle = preset.spread
		emitter.Acceleration = preset.acceleration
		emitter.LightEmission = 1
		emitter.LightInfluence = 0
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0.2),
			NumberSequenceKeypoint.new(0.75, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = root
		aura = emitter
	end

	visuals[player] = {
		tag = tag,
		aura = aura,
		titleId = def.id,
		rainbow = def.aura == "rainbow",
	}
end

-- ===== TitleEquip remote =====

local function onTitleEquip(player: Player, titleId: unknown)
	if not takeEquipToken(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if titleId ~= nil and typeof(titleId) ~= "string" then
		return -- malformed; drop silently
	end

	if titleId == nil then
		if profile.equippedTitle == nil then
			return -- nothing to do
		end
		profile.equippedTitle = nil
		Remotes.Notify:FireClient(player, "info", "Title unequipped.")
	else
		local id = titleId :: string
		local def = titleById[id]
		if def == nil then
			return -- unknown id; drop silently
		end
		local owned = profile.titles
		if owned == nil or owned[id] ~= true then
			Remotes.Notify:FireClient(player, "error", "You haven't earned that title yet — " .. def.earn.label)
			return
		end
		profile.equippedTitle = id
		Remotes.Notify:FireClient(player, "info", `👑 You are now "{def.name}"!`)
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
	applyVisuals(player)
end

-- ===== Lifecycle =====

function TitleService.Init()
	for _, def in Titles do
		titleById[def.id] = def
	end
end

function TitleService.Start()
	Remotes.TitleEquip.OnServerEvent:Connect(onTitleEquip)

	-- Reapply visuals on every respawn. The character's parts stream in after
	-- CharacterAdded fires, so wait for them off-thread.
	local function watchCharacter(player: Player)
		local old = characterConns[player]
		if old ~= nil then
			old:Disconnect()
		end
		characterConns[player] = player.CharacterAdded:Connect(function(character)
			task.spawn(function()
				character:WaitForChild("Head", 5)
				character:WaitForChild("HumanoidRootPart", 5)
				local ok, err = pcall(applyVisuals, player)
				if not ok then
					warn(`[TitleService] applyVisuals failed for {player.Name}: {err}`)
				end
			end)
		end)
	end

	Players.PlayerAdded:Connect(watchCharacter)
	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end

	-- Grants earned titles + applies visuals as soon as the profile lands
	-- (replays for already-loaded players; callbacks are pcall'd upstream).
	DataService.OnProfileLoaded(function(player, _profile)
		TitleService.CheckUnlocks(player)
		applyVisuals(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		removeVisuals(player)
		equipTokens[player] = nil
		local conn = characterConns[player]
		if conn ~= nil then
			conn:Disconnect()
			characterConns[player] = nil
		end
	end)

	-- Unlock sweep: other services bump the stats (bossWins, likesGiven, ...);
	-- this catches every change within a minute without cross-service wiring.
	task.spawn(function()
		while true do
			task.wait(UNLOCK_SWEEP_SECONDS)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(TitleService.CheckUnlocks, player)
				if not ok then
					warn(`[TitleService] CheckUnlocks sweep failed for {player.Name}: {err}`)
				end
			end
		end
	end)

	-- ONE shared hue cycler drives every "rainbow" aura (no per-player tasks).
	task.spawn(function()
		while true do
			task.wait(RAINBOW_STEP_SECONDS)
			local hue = (os.clock() * RAINBOW_HUE_SPEED) % 1
			local color = ColorSequence.new(Color3.fromHSV(hue, 0.55, 1))
			for _, entry in visuals do
				local aura = entry.aura
				if entry.rainbow and aura ~= nil and aura.Parent ~= nil then
					aura.Color = color
				end
			end
		end
	end)
end

return TitleService
