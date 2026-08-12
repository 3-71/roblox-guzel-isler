--!strict
-- BossBuilder — procedural THOCK MONSTER geometry + all boss FX/sounds.
--
-- The monster reads as a CORRUPTED KEYBOARD: a cracked slab body wearing
-- rows of derelict keycaps (some missing, some crooked, THOCK spelled with a
-- glitchy zero), one glowing glitch eye + one dead cross-scratched eye,
-- keycap-cluster fists dangling from cable arms, and a frayed broken-cable
-- tail. All engine materials + rbxasset:// built-in sounds only.
--
-- Contract with BossService (the only consumer):
--   Build(cf)                    -> Model (PrimaryPart "Root" sits ON THE
--                                  GROUND at cf; front faces cf's -Z; move it
--                                  with Model:PivotTo — every part is anchored)
--   SocketCount(monster)         -> number of weak-spot sockets
--   SpawnWeakSpot(monster, i)    -> BasePart? glowing keycap at socket i with
--                                  a ClickDetector child (service connects it)
--   PlayStomp / PlayRoar / PlayWeakSpotHit / PlaySiren / PlayDeathBurst
--   ApplyPlotDamage(plot, epicenter) / ClearPlotDamage(plot)
--
-- SAFETY (owner's explicit decision): plot "damage" is TEMPORARY VISUALS
-- ONLY — smoke + crack overlays inside a "BossDamage" Model that
-- ClearPlotDamage destroys. Real plot parts are NEVER touched or edited.
--
-- Constraint: every geometry part here is pure decoration —
-- CanCollide/CanTouch/CanQuery all false (players can walk through the
-- monster; nothing eats Touched events) — EXCEPT weak-spot keycaps, which
-- keep CanQuery = true because ClickDetector clicks are mouse raycasts and
-- raycasts skip CanQuery=false parts. The body staying CanQuery=false is a
-- feature: clicks pass through the slab straight onto the weak spots.

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

local PlotBuilder = require(script.Parent.PlotBuilder)

local BossBuilder = {}

-- Engine built-in sounds (same roster the keyboard sound design uses).
local SOUNDS = {
	Thump = "rbxasset://sounds/action_jump_land.mp3",
	Rattle = "rbxasset://sounds/action_footsteps_plastic.mp3",
	Ping = "rbxasset://sounds/electronicpingshort.wav",
	Snap = "rbxasset://sounds/snap.mp3",
	Wind = "rbxasset://sounds/action_falling.mp3",
	Splash = "rbxasset://sounds/impact_water.mp3",
	Whoosh = "rbxasset://sounds/action_get_up.mp3",
}

local PALETTE = {
	slab = Color3.fromRGB(40, 42, 52),
	slabDark = Color3.fromRGB(30, 30, 38),
	bezel = Color3.fromRGB(70, 68, 80),
	hip = Color3.fromRGB(46, 44, 52),
	leg = Color3.fromRGB(58, 56, 66),
	foot = Color3.fromRGB(52, 50, 58),
	cable = Color3.fromRGB(34, 34, 40),
	capWorn1 = Color3.fromRGB(206, 198, 182),
	capWorn2 = Color3.fromRGB(180, 174, 162),
	capWorn3 = Color3.fromRGB(150, 146, 140),
	glitch = Color3.fromRGB(132, 255, 150),
	crack = Color3.fromRGB(20, 20, 26),
	deadEye = Color3.fromRGB(110, 52, 58),
	copper = Color3.fromRGB(255, 190, 110),
	weakSpot = Color3.fromRGB(255, 205, 66),
	nameRed = Color3.fromRGB(255, 86, 96),
	smoke = Color3.fromRGB(80, 78, 86),
}

local SOCKET_TOTAL = 10
local ATTR_SOCKET_COUNT = "WeakSocketCount"
local ATTR_DAMAGE_STAGE = "Stage"
local MAX_DAMAGE_STAGE = 3

local rng = Random.new()

-- ===== Small factories =====
-- part() keeps the exact PlotBuilder signature. ARITY AUDIT: every call
-- below passes all six arguments — material is ALWAYS given explicitly,
-- never the parent in the material slot (the "base weg" lesson).

local function part(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	parent: Instance
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Pure decoration: characters, Touched listeners and raycasts all ignore it.
local function deco(p: BasePart): BasePart
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	return p
end

local function ball(name: string, diameter: number, cf: CFrame, color: Color3, material: Enum.Material?, parent: Instance): Part
	local p = part(name, Vector3.new(diameter, diameter, diameter), cf, color, material, parent)
	p.Shape = Enum.PartType.Ball
	return p
end

local function playSound(parent: Instance, soundId: string, pitch: number, volume: number, rollOffMax: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.PlaybackSpeed = pitch
	sound.Volume = volume
	sound.RollOffMinDistance = 25
	sound.RollOffMaxDistance = rollOffMax or 350
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 6)
end

-- Invisible anchored holder for particles/sounds at a world position.
local function fxHolder(name: string, position: Vector3, lifetime: number): Part
	local holder = part(name, Vector3.new(1, 1, 1), CFrame.new(position), PALETTE.slab, Enum.Material.SmoothPlastic, Workspace)
	holder.Transparency = 1
	deco(holder)
	Debris:AddItem(holder, lifetime)
	return holder
end

local function socketAttachment(parentPart: BasePart, index: number, offset: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = "WeakSocket" .. tostring(index)
	attachment.Position = offset
	attachment.Parent = parentPart
end

-- Big friendly letter on a keycap face (front of the cap, toward -Z).
local function capLabel(cap: BasePart, text: string, textColor: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = textColor
	label.Parent = gui
	gui.Parent = cap
end

-- ===== The monster =====

function BossBuilder.Build(cf: CFrame): Model
	local monster = Instance.new("Model")
	monster.Name = "ThockMonster"
	monster:SetAttribute(ATTR_SOCKET_COUNT, SOCKET_TOTAL)

	-- Deterministic look so the monster is the same character every fight.
	local look = Random.new(1207)

	-- Root ON the ground at cf — BossService pivots the whole model by it.
	local root = part("Root", Vector3.new(2, 2, 2), cf, PALETTE.slab, Enum.Material.SmoothPlastic, monster)
	root.Transparency = 1
	deco(root)
	monster.PrimaryPart = root

	-- Feet + legs (front is -Z).
	for _, side in { -1, 1 } do
		local suffix = if side < 0 then "L" else "R"
		deco(part("Foot" .. suffix, Vector3.new(7, 2.4, 9), cf * CFrame.new(side * 6, 1.2, 0.5), PALETTE.foot, Enum.Material.Slate, monster))
		deco(part("Toe" .. suffix, Vector3.new(3, 2, 2.4), cf * CFrame.new(side * 6, 1.2, -4.6), PALETTE.capWorn2, Enum.Material.SmoothPlastic, monster))
		local leg = part("Leg" .. suffix, Vector3.new(5.4, 9.6, 6), cf * CFrame.new(side * 6, 8.2, 0.5), PALETTE.leg, Enum.Material.Slate, monster)
		deco(leg)
		socketAttachment(leg, if side < 0 then 8 else 9, Vector3.new(0, 0.5, -3.2))
	end
	deco(part("Hip", Vector3.new(17, 4.4, 7.5), cf * CFrame.new(0, 14.6, 0.5), PALETTE.hip, Enum.Material.Metal, monster))

	-- Cracked slab body, leaning back a touch like a haunted monolith.
	local bodyCF = cf * CFrame.new(0, 25.5, 1) * CFrame.Angles(math.rad(7), 0, 0)
	local body = part("BodySlab", Vector3.new(24, 18, 6), bodyCF, PALETTE.slab, Enum.Material.Slate, monster)
	deco(body)
	socketAttachment(body, 1, Vector3.new(-8.5, 6.5, -3))
	socketAttachment(body, 2, Vector3.new(8.5, 6.5, -3))
	socketAttachment(body, 3, Vector3.new(-8.5, -6.5, -3))
	socketAttachment(body, 4, Vector3.new(8.5, -6.5, -3))
	socketAttachment(body, 5, Vector3.new(0, 0.6, -3))
	socketAttachment(body, 10, Vector3.new(0, 9.2, 0))

	local bezel = part("BezelTop", Vector3.new(25.5, 2, 7), bodyCF * CFrame.new(0, 10, 0), PALETTE.bezel, Enum.Material.Metal, monster)
	deco(bezel)
	for _, side in { -1, 1 } do
		deco(part("BezelSide", Vector3.new(1.6, 20, 7), bodyCF * CFrame.new(side * 12.6, 0, 0), PALETTE.bezel, Enum.Material.Metal, monster))
	end

	-- Derelict keycap rows: some missing (dark sockets), some crooked, a few
	-- glitch-neon. Row 3 always spells T-H-0-C-K.
	local wornColors = { PALETTE.capWorn1, PALETTE.capWorn2, PALETTE.capWorn3 }
	local thock = { "T", "H", "0", "C", "K" }
	local rowYs = { -5.9, -1.7, 2.5, 6.7 }
	for row = 1, 4 do
		for col = 1, 5 do
			local x = -8.6 + (col - 1) * 4.3
			local y = rowYs[row]
			local isLetterRow = row == 3
			if not isLetterRow and look:NextNumber() < 0.22 then
				-- Torn-out keycap: just the dark empty socket.
				deco(part("KeySocket", Vector3.new(3.4, 3.4, 0.5), bodyCF * CFrame.new(x, y, -2.9), PALETTE.slabDark, Enum.Material.SmoothPlastic, monster))
			else
				local tilt = math.rad(look:NextNumber(-12, 12))
				local isGlitch = not isLetterRow and look:NextNumber() < 0.12
				local color = if isGlitch then PALETTE.glitch else wornColors[look:NextInteger(1, #wornColors)]
				local material = if isGlitch then Enum.Material.Neon else Enum.Material.SmoothPlastic
				local cap = part(
					"MonsterKeycap",
					Vector3.new(3.6, 3.6, 1.8),
					bodyCF * CFrame.new(x, y, -3.1) * CFrame.Angles(0, 0, tilt),
					color,
					material,
					monster
				)
				deco(cap)
				if isLetterRow then
					capLabel(cap, thock[col], if thock[col] == "0" then PALETTE.glitch else PALETTE.slabDark)
				end
			end
		end
	end

	-- Cracks: deep dark gouges + glitch light leaking out of two of them.
	for _ = 1, 3 do
		deco(part(
			"Crack",
			Vector3.new(look:NextNumber(6, 10), 0.5, 0.35),
			bodyCF * CFrame.new(look:NextNumber(-8, 8), look:NextNumber(-7, 8), -3.05) * CFrame.Angles(0, 0, look:NextNumber(0, math.pi)),
			PALETTE.crack,
			Enum.Material.Slate,
			monster
		))
	end
	for _ = 1, 2 do
		deco(part(
			"CrackGlow",
			Vector3.new(look:NextNumber(4, 7), 0.3, 0.25),
			bodyCF * CFrame.new(look:NextNumber(-9, 9), look:NextNumber(-6, 7), -3.02) * CFrame.Angles(0, 0, look:NextNumber(0, math.pi)),
			PALETTE.glitch,
			Enum.Material.Neon,
			monster
		))
	end

	-- One glitchy neon eye (lives!), one dead cross-scratched eye.
	deco(part("EyeSocket", Vector3.new(5.6, 5.6, 1.2), bodyCF * CFrame.new(-4, 5, -3.2), PALETTE.slabDark, Enum.Material.Slate, monster))
	local eye = ball("Eye", 4.2, bodyCF * CFrame.new(-4, 5, -3.6), PALETTE.glitch, Enum.Material.Neon, monster)
	deco(eye)
	local eyeLight = Instance.new("PointLight")
	eyeLight.Color = PALETTE.glitch
	eyeLight.Range = 18
	eyeLight.Brightness = 2
	eyeLight.Parent = eye
	deco(ball("Pupil", 1.6, bodyCF * CFrame.new(-4, 5, -5.2), Color3.fromRGB(20, 40, 26), Enum.Material.SmoothPlastic, monster))
	deco(part("Brow", Vector3.new(7, 1.6, 2.2), bodyCF * CFrame.new(-4, 8.2, -3.2) * CFrame.Angles(0, 0, math.rad(-14)), PALETTE.slabDark, Enum.Material.Slate, monster))
	for _, tilt in { 45, -45 } do
		deco(part("DeadEye", Vector3.new(4.4, 0.8, 0.6), bodyCF * CFrame.new(4.5, 5, -3.15) * CFrame.Angles(0, 0, math.rad(tilt)), PALETTE.deadEye, Enum.Material.SmoothPlastic, monster))
	end

	-- Shoulders + dangling cable arms ending in keycap fists.
	for _, side in { -1, 1 } do
		local suffix = if side < 0 then "L" else "R"
		deco(part("Shoulder" .. suffix, Vector3.new(6.5, 3.2, 6.5), cf * CFrame.new(side * 13.8, 33, 1.2), PALETTE.hip, Enum.Material.Metal, monster))
		deco(part("ArmCable" .. suffix, Vector3.new(1.7, 10, 1.7), cf * CFrame.new(side * 13.8, 27.5, 1.2), PALETTE.cable, Enum.Material.SmoothPlastic, monster))
		local fist = part("Fist" .. suffix, Vector3.new(4.6, 4.6, 4.6), cf * CFrame.new(side * 13.8, 21, 1.2), PALETTE.capWorn1, Enum.Material.SmoothPlastic, monster)
		deco(fist)
		socketAttachment(fist, if side < 0 then 6 else 7, Vector3.new(0, -2.4, 0))
		deco(part(
			"FistCap" .. suffix,
			Vector3.new(3.2, 3.2, 3.2),
			cf * CFrame.new(side * 13.8 + side * 1.9, 19.4, -0.1) * CFrame.Angles(0, math.rad(20 * side), math.rad(14 * side)),
			PALETTE.capWorn3,
			Enum.Material.SmoothPlastic,
			monster
		))
		deco(part(
			"FistGlitchCap" .. suffix,
			Vector3.new(2.6, 2.6, 2.6),
			cf * CFrame.new(side * 13.8 - side * 1.4, 18.8, 2.4) * CFrame.Angles(math.rad(12), 0, math.rad(-10 * side)),
			PALETTE.glitch,
			Enum.Material.Neon,
			monster
		))
	end

	-- Broken-cable tail arcing down behind, frayed copper end + sparks.
	local tailSegments = {
		{ Vector3.new(0, 10.5, 7), 40, 0 },
		{ Vector3.new(0, 8, 10), 55, 0 },
		{ Vector3.new(0.6, 5.2, 12.6), 65, 8 },
		{ Vector3.new(1.4, 2.6, 14.6), 75, 16 },
	}
	for i, segment in tailSegments do
		local offset = segment[1] :: Vector3
		local pitch = segment[2] :: number
		local yaw = segment[3] :: number
		deco(part(
			"TailSegment" .. tostring(i),
			Vector3.new(1.8, 1.8, 5),
			cf * CFrame.new(offset) * CFrame.Angles(math.rad(pitch), math.rad(yaw), 0),
			PALETTE.cable,
			Enum.Material.SmoothPlastic,
			monster
		))
	end
	for strand = 1, 3 do
		deco(part(
			"TailFray" .. tostring(strand),
			Vector3.new(0.35, 0.35, 2.4),
			cf * CFrame.new(2 + (strand - 1) * 0.4, 1 + (strand - 1) * 0.3, 16.5) * CFrame.Angles(math.rad(60 + strand * 12), math.rad(strand * 18 - 20), 0),
			PALETTE.copper,
			Enum.Material.Neon,
			monster
		))
	end
	local sparkHolder = part("TailSparks", Vector3.new(1, 1, 1), cf * CFrame.new(2.2, 1.2, 16.8), PALETTE.copper, Enum.Material.SmoothPlastic, monster)
	sparkHolder.Transparency = 1
	deco(sparkHolder)
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(PALETTE.copper, PALETTE.weakSpot)
	sparks.Lifetime = NumberRange.new(0.2, 0.5)
	sparks.Speed = NumberRange.new(3, 7)
	sparks.SpreadAngle = Vector2.new(60, 60)
	sparks.Size = NumberSequence.new(0.25)
	sparks.LightEmission = 1
	sparks.Rate = 4
	sparks.Parent = sparkHolder

	-- Name tag floating over the head.
	local nameGui = Instance.new("BillboardGui")
	nameGui.Name = "NameTag"
	nameGui.Size = UDim2.new(0, 300, 0, 50)
	nameGui.StudsOffsetWorldSpace = Vector3.new(0, 13, 0)
	nameGui.MaxDistance = 600
	nameGui.LightInfluence = 0
	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Text = "THOCK MONSTER"
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = PALETTE.nameRed
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.Parent = nameGui
	nameGui.Parent = body

	monster.Parent = Workspace
	return monster
end

function BossBuilder.SocketCount(monster: Model): number
	local count = monster:GetAttribute(ATTR_SOCKET_COUNT)
	return if typeof(count) == "number" then count else SOCKET_TOTAL
end

-- Glowing weak-spot keycap at socket `socketIndex`. Returns nil if the
-- socket doesn't exist. BossService connects the ClickDetector child.
function BossBuilder.SpawnWeakSpot(monster: Model, socketIndex: number): BasePart?
	local attachment = monster:FindFirstChild("WeakSocket" .. tostring(socketIndex), true)
	if attachment == nil or not attachment:IsA("Attachment") then
		return nil
	end

	local spot = part(
		"WeakSpot",
		Vector3.new(3.2, 3.2, 3.2),
		attachment.WorldCFrame * CFrame.new(0, 0, -0.9) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-10, 10))),
		PALETTE.weakSpot,
		Enum.Material.Neon,
		monster
	)
	-- NOT deco'd on purpose: ClickDetector clicks are raycasts, so the spot
	-- must keep CanQuery = true (the rest of the monster is CanQuery=false,
	-- which lets clicks pass through the body onto this cap).
	spot.CanCollide = false
	spot.CanTouch = false
	spot.CanQuery = true
	capLabel(spot, "!", PALETTE.slabDark)

	local light = Instance.new("PointLight")
	light.Color = PALETTE.weakSpot
	light.Range = 14
	light.Brightness = 3
	light.Parent = spot

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 90
	click.Parent = spot

	return spot
end

-- ===== FX / sounds =====

function BossBuilder.PlayStomp(monster: Model)
	local pivot = monster:GetPivot()
	local holder = fxHolder("BossStomp", pivot.Position + Vector3.new(0, 1, 0), 3)
	local dust = Instance.new("ParticleEmitter")
	dust.Color = ColorSequence.new(PALETTE.smoke)
	dust.Lifetime = NumberRange.new(0.4, 0.9)
	dust.Speed = NumberRange.new(6, 12)
	dust.SpreadAngle = Vector2.new(85, 85)
	dust.Size = NumberSequence.new(1.4)
	dust.Transparency = NumberSequence.new(0.4, 1)
	dust.Rate = 0
	dust.Parent = holder
	dust:Emit(12)
	playSound(holder, SOUNDS.Thump, 0.5, 0.9, 300)
	playSound(holder, SOUNDS.Rattle, 0.75, 0.45, 200)
end

function BossBuilder.PlayRoar(monster: Model)
	local body = monster:FindFirstChild("BodySlab")
	local target: Instance = if body ~= nil then body else monster
	playSound(target, SOUNDS.Thump, 0.32, 1, 500)
	task.delay(0.05, playSound, target, SOUNDS.Wind, 0.45, 0.9, 500)
	task.delay(0.12, playSound, target, SOUNDS.Snap, 0.5, 0.8, 400)
	task.delay(0.2, playSound, target, SOUNDS.Ping, 0.4, 0.5, 400)

	-- The glitch eye flares while it roars.
	local eye = monster:FindFirstChild("Eye")
	local light = if eye ~= nil then eye:FindFirstChildOfClass("PointLight") else nil
	if light ~= nil then
		light.Brightness = 7
		task.delay(0.5, function()
			if light.Parent ~= nil then
				light.Brightness = 2
			end
		end)
	end
end

function BossBuilder.PlayWeakSpotHit(monster: Model, at: Vector3)
	local holder = fxHolder("WeakSpotHit", at, 2.5)
	local burst = Instance.new("ParticleEmitter")
	burst.Color = ColorSequence.new(PALETTE.weakSpot)
	burst.Lifetime = NumberRange.new(0.25, 0.6)
	burst.Speed = NumberRange.new(8, 16)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Size = NumberSequence.new(0.5)
	burst.LightEmission = 0.8
	burst.Rate = 0
	burst.Parent = holder
	burst:Emit(18)
	playSound(holder, SOUNDS.Snap, 1.5, 0.9, 250)
	playSound(holder, SOUNDS.Ping, 1.8, 0.7, 250)
	local _ = monster -- kept for signature symmetry; FX are world-anchored
end

-- Two-tone global warning siren (2D — a Sound parented straight to
-- Workspace plays for everyone, no falloff).
function BossBuilder.PlaySiren()
	local low = Instance.new("Sound")
	low.SoundId = SOUNDS.Ping
	low.PlaybackSpeed = 0.55
	low.Volume = 0.7
	low.Parent = Workspace
	low:Play()
	Debris:AddItem(low, 3)
	task.delay(0.35, function()
		local high = Instance.new("Sound")
		high.SoundId = SOUNDS.Ping
		high.PlaybackSpeed = 0.9
		high.Volume = 0.7
		high.Parent = Workspace
		high:Play()
		Debris:AddItem(high, 3)
	end)
end

function BossBuilder.PlayDeathBurst(monster: Model)
	local pivot = monster:GetPivot()
	local center = pivot.Position + Vector3.new(0, 16, 0)
	local holder = fxHolder("BossDeath", center, 4)

	local gold = Instance.new("ParticleEmitter")
	gold.Color = ColorSequence.new(PALETTE.weakSpot, PALETTE.glitch)
	gold.Lifetime = NumberRange.new(0.5, 1.2)
	gold.Speed = NumberRange.new(14, 30)
	gold.SpreadAngle = Vector2.new(180, 180)
	gold.Size = NumberSequence.new(0.8)
	gold.LightEmission = 1
	gold.Rate = 0
	gold.Parent = holder
	gold:Emit(60)

	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new(PALETTE.smoke)
	smoke.Lifetime = NumberRange.new(0.8, 1.6)
	smoke.Speed = NumberRange.new(5, 10)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Size = NumberSequence.new(3)
	smoke.Transparency = NumberSequence.new(0.4, 1)
	smoke.Rate = 0
	smoke.Parent = holder
	smoke:Emit(30)

	playSound(holder, SOUNDS.Splash, 0.7, 1, 500)
	playSound(holder, SOUNDS.Thump, 0.42, 1, 500)
	task.delay(0.1, playSound, holder, SOUNDS.Whoosh, 0.55, 0.9, 500)
	for i, pitch in { 1, 1.26, 1.5, 2 } do
		task.delay(0.25 + i * 0.09, playSound, holder, SOUNDS.Ping, pitch, 0.6, 500)
	end

	-- Keycap shrapnel: real physics chunks, cleaned up by Debris. CanTouch/
	-- CanQuery stay false so the debris can never eat Touched events.
	local shrapnelColors = { PALETTE.capWorn1, PALETTE.capWorn2, PALETTE.glitch, PALETTE.weakSpot }
	for i = 1, 8 do
		local chunk = part(
			"BossShrapnel",
			Vector3.new(1.8, 1.8, 1.8),
			CFrame.new(center) * CFrame.Angles(rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi), 0),
			shrapnelColors[(i - 1) % #shrapnelColors + 1],
			Enum.Material.SmoothPlastic,
			Workspace
		)
		chunk.Anchored = false
		chunk.CanCollide = true
		chunk.CanTouch = false
		chunk.CanQuery = false
		chunk.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-28, 28), rng:NextNumber(24, 48), rng:NextNumber(-28, 28))
		Debris:AddItem(chunk, 5)
	end
end

-- ===== Temporary plot damage visuals =====
-- Everything lands inside ONE "BossDamage" Model per plot so fight-end
-- cleanup is a single Destroy. Escalates up to MAX_DAMAGE_STAGE, then
-- further calls are no-ops. NEVER touches real plot parts.

local function plotOrigin(plot: Model): CFrame
	local index = plot:GetAttribute("PlotIndex")
	if typeof(index) == "number" then
		return PlotBuilder.GetPlotCFrame(index)
	end
	-- Fallback: the plot's PrimaryPart is Base, centred 0.5 below the origin.
	return plot:GetPivot() * CFrame.new(0, 0.5, 0)
end

function BossBuilder.ApplyPlotDamage(plot: Model, epicenter: Vector3)
	local damageModel = plot:FindFirstChild("BossDamage")
	if damageModel == nil or not damageModel:IsA("Model") then
		local model = Instance.new("Model")
		model.Name = "BossDamage"
		model:SetAttribute(ATTR_DAMAGE_STAGE, 0)
		model.Parent = plot
		damageModel = model
	end
	local damage = damageModel :: Model
	local stage = damage:GetAttribute(ATTR_DAMAGE_STAGE)
	local currentStage = if typeof(stage) == "number" then stage else 0
	if currentStage >= MAX_DAMAGE_STAGE then
		return
	end
	damage:SetAttribute(ATTR_DAMAGE_STAGE, currentStage + 1)

	-- Cracks + smoke cluster on the plot edge nearest the monster.
	local origin = plotOrigin(plot)
	local localEpicenter = origin:PointToObjectSpace(epicenter)
	local half = GameConfig.PlotSize / 2 - 6
	local ex = math.clamp(localEpicenter.X, -half, half)
	local ez = math.clamp(localEpicenter.Z, -half, half)

	for _ = 1, 3 do
		deco(part(
			"CrackOverlay",
			Vector3.new(rng:NextNumber(5, 9), 0.22, rng:NextNumber(0.8, 1.6)),
			origin
				* CFrame.new(math.clamp(ex + rng:NextNumber(-10, 10), -half, half), 0.12, math.clamp(ez + rng:NextNumber(-10, 10), -half, half))
				* CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			PALETTE.crack,
			Enum.Material.Slate,
			damage
		))
	end

	local smokeHolder = part(
		"DamageSmoke",
		Vector3.new(1, 1, 1),
		origin * CFrame.new(math.clamp(ex + rng:NextNumber(-6, 6), -half, half), 1.5, math.clamp(ez + rng:NextNumber(-6, 6), -half, half)),
		PALETTE.smoke,
		Enum.Material.SmoothPlastic,
		damage
	)
	smokeHolder.Transparency = 1
	deco(smokeHolder)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new(PALETTE.smoke)
	smoke.Lifetime = NumberRange.new(1, 2)
	smoke.Speed = NumberRange.new(3, 6)
	smoke.SpreadAngle = Vector2.new(25, 25)
	smoke.Size = NumberSequence.new(1.5, 4)
	smoke.Transparency = NumberSequence.new(0.35, 1)
	smoke.Acceleration = Vector3.new(0, 4, 0)
	smoke.Rate = 6
	smoke.Parent = smokeHolder

	playSound(smokeHolder, SOUNDS.Snap, 0.7 - currentStage * 0.1, 0.7, 200)
end

function BossBuilder.ClearPlotDamage(plot: Model)
	local damage = plot:FindFirstChild("BossDamage")
	if damage ~= nil then
		damage:Destroy()
	end
end

return BossBuilder
