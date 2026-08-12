--!strict
-- HarmonyService — the shared "SERVER HARMONY" obelisk (Phase 6 item 1).
-- EVERY player's producing / selling / typing feeds ONE global point pool;
-- when the pool fills, the whole server gets a free weather event
-- (EventService.ForceEvent on a random GameConfig.Harmony.RewardEventIds),
-- the pool resets and the goal grows by Harmony.GoalGrowth. All state lives
-- per server session — nothing persists, no profile writes, no remotes.
--
-- Contract (ARCHITECTURE.md Phase 6 item 1):
--   AddPoints(points: number)  — global pool, no player arg. Called by
--     ProductionService (collect, +PointsProduce) and EconomyService (sell,
--     +PointsSell) via lazy pcall, and by this service's own
--     EquipService.OnTypeAccepted subscription (+PointsType per press).
--     MUST stay cheap and yield-free: it only accumulates; attributes,
--     visuals and fill checks run in a FLUSH_SECONDS batch loop.
--   State mirrors to Workspace attributes HarmonyPoints / HarmonyGoal.
--   Hype Notify at 50% and 90% (once per fill); on full: flash + particle
--     burst + chime + flex Notify + ForceEvent + reset, goal *= GoalGrowth.
--
-- World: a "HarmonyObelisk" Model, direct child of Workspace. Chunky
-- anchored low-poly build: stone pedestal (KEEPS collision — players can
-- walk up and touch it) + SEGMENTS stacked neon crystal segments that light
-- bottom-up with points/goal (dim = high Transparency) + crown gem +
-- "🤝 SERVER HARMONY" BillboardGui with a live percent readout. Everything
-- except the pedestal is deco'd (CanCollide/CanTouch/CanQuery=false) so it
-- can never eat Touched events or block raycasts (CLAUDE.md lesson 8). No
-- external asset ids — the chime is engine rbxasset:// PING, the burst uses
-- the engine default particle texture.
--
-- Placement proof (all numbers from HubBuilder.luau, step = 2π/8 = 45°):
-- angle 2.25*step (101.25°), radius 47 — a QUARTER-step slot on the grass
-- ring (grass spans r 42..58; plaza ends at r 42). Every half-step slot
-- (k+0.5)*step is taken (forge/stall/monument/racepad/kiosk/boards/sign +
-- benches r 34, lamps r 40.5, trees r 51), so quarter-steps are the free
-- lanes. Nearest neighbours of (r47, 101.25°) ≈ world (-9.2, 46.1):
--   * plot-3 path (radial at 90°, 6 wide): perpendicular distance
--     47*sin(11.25°) ≈ 9.2 > 3 (path half) + ~4.1 (base worst-case reach)
--   * 2.5-step slot (112.5°): lamp r40.5 ≈ 10.8 away, tree r51 ≈ 10.4 away
--     (canopy half 2.3), bench r34 ≈ 15.2, monument r30 ≈ 18.5 away
--   * second tree row hugs plot paths at baseAngle ± 0.17 rad, r 53.5; for
--     plot 3 (odd index) HubBuilder puts it on the MINUS side (80.3°),
--     ≈ 19 studs away. Flower patches (r45, baseAngle - 18.3°) only spawn
--     for EVEN plot indices — nearest (plot 4 → 116.7°) ≈ 12.6 away.
--   * bunting only spans EVEN half-step slots (67.5°, 157.5°, ...) — none
--     near 101.25°.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)

local EquipService = require(script.Parent.EquipService)
local EventService = require(script.Parent.EventService)

local HarmonyService = {}

local rng = Random.new()

local FLUSH_SECONDS = 0.25 -- attribute/visual batch cadence (AddPoints itself never touches instances)
local SEGMENTS = 8
local DIM_TRANSPARENCY = 0.86
local LIT_TRANSPARENCY = 0.06
local GRASS_TOP_Y = -0.2 -- HubBuilder GrassRing: 0.8 tall centred at y = -0.6
local OBELISK_RADIUS = 47
local CHIME_SOUND = "rbxasset://sounds/electronicpingshort.wav" -- engine built-in (PING)

local PALETTE = {
	stone = Color3.fromRGB(196, 190, 178), -- matches the hub pedestal family
	stoneDark = Color3.fromRGB(150, 144, 134),
	gold = Color3.fromRGB(255, 199, 68), -- HubBuilder boardGold
	teal = Color3.fromRGB(92, 225, 210),
	glow = Color3.fromRGB(255, 244, 214),
}

-- ===== Session state (never persisted) =====

local points = 0
local goal: number = GameConfig.Harmony.Goal
local dirty = true -- flush loop refreshes attributes/visuals when set
local notified50 = false -- hype notifies fire once per fill
local notified90 = false
local flashUntil = 0 -- refresh() leaves the segments fully lit until this os.clock()

-- ===== World handles (nil until Init builds the obelisk) =====

local segments: { BasePart } = {}
local gem: BasePart? = nil
local gemLight: PointLight? = nil
local burst: ParticleEmitter? = nil
local percentLabel: TextLabel? = nil
local chimes: { Sound } = {}

-- ===== Part helpers (SAME arity as HubBuilder/PlotBuilder — material 5th,
-- parent 6th; CLAUDE.md lesson 1: never pass the parent into the material
-- slot) =====

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

-- Flat-lying cylinder (vertical axis), HubBuilder convention.
local function cylinder(
	name: string,
	height: number,
	diameter: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	parent: Instance
): Part
	local p = part(name, Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, math.rad(90)), color, material, parent)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Pure decoration: never blocks movement, eats Touched, or swallows raycasts.
local function deco(p: BasePart): BasePart
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	return p
end

-- ===== Obelisk build =====

local function buildObelisk()
	local old = Workspace:FindFirstChild("HarmonyObelisk")
	if old ~= nil then
		old:Destroy()
	end
	table.clear(segments)
	table.clear(chimes)

	local model = Instance.new("Model")
	model.Name = "HarmonyObelisk"

	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	local angle = 2.25 * step -- see placement proof in the header comment
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * OBELISK_RADIUS
	-- Local space: -Z looks at the plaza centre (hub furniture convention).
	local footCF = CFrame.lookAt(Vector3.new(basePos.X, GRASS_TOP_Y, basePos.Z), Vector3.new(0, GRASS_TOP_Y, 0))

	-- Pedestal: two chunky stone tiers. These KEEP collision by design (the
	-- contract allows the base to collide — players can climb up to it).
	local base = part("PedestalBase", Vector3.new(6.8, 1.2, 6.8), footCF * CFrame.new(0, 0.6, 0), PALETTE.stone, Enum.Material.Slate, model)
	part("PedestalTop", Vector3.new(5.2, 1, 5.2), footCF * CFrame.new(0, 1.7, 0), PALETTE.stoneDark, Enum.Material.Slate, model)
	deco(cylinder("PedestalTrim", 0.25, 7.8, footCF * CFrame.new(0, 0.1, 0), PALETTE.gold, Enum.Material.Metal, model))

	-- Little tilted crystal shards leaning on the pedestal corners (deco).
	for k = 1, 3 do
		local a = k * (math.pi * 2 / 3) + 0.5
		local shardCF = footCF
			* CFrame.new(math.cos(a) * 3.1, 1, math.sin(a) * 3.1)
			* CFrame.Angles(math.rad(14), a, math.rad(-10))
		deco(part("Shard", Vector3.new(0.8, 2.2, 0.8), shardCF, PALETTE.teal, Enum.Material.Neon, model)).Transparency = 0.5
	end

	-- Crystal column: SEGMENTS tapering neon blocks, each yawed a bit for a
	-- faceted look. All deco'd; they light bottom-up with the fill fraction.
	local columnBase = 2.2 -- top of the pedestal (0.2 + 1 + 1 relative to grass)
	for i = 1, SEGMENTS do
		local width = 3.3 - (i - 1) * 0.26
		local centerY = columnBase + (i - 0.5) * 1.4
		local hue = 0.48 + (i - 1) / (SEGMENTS - 1) * 0.35 -- teal -> violet
		local seg = part(
			"Segment" .. i,
			Vector3.new(width, 1.45, width),
			footCF * CFrame.new(0, centerY, 0) * CFrame.Angles(0, math.rad((i - 1) * 24), 0),
			Color3.fromHSV(hue, 0.55, 1),
			Enum.Material.Neon,
			model
		)
		seg.Transparency = DIM_TRANSPARENCY
		deco(seg)
		table.insert(segments, seg)
	end

	-- Crown gem + light + subtle idle sparkle (engine DEFAULT particle
	-- texture — no external ids; Rate stays tiny for low-end devices).
	local crownY = columnBase + SEGMENTS * 1.4 + 0.7
	local gemPart = part("CrownGem", Vector3.new(1.7, 1.7, 1.7), footCF * CFrame.new(0, crownY, 0), PALETTE.glow, Enum.Material.Neon, model)
	gemPart.Shape = Enum.PartType.Ball
	deco(gemPart)
	gem = gemPart

	local light = Instance.new("PointLight")
	light.Color = PALETTE.teal
	light.Range = 18
	light.Brightness = 0.25
	light.Parent = gemPart
	gemLight = light

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(PALETTE.teal, PALETTE.glow)
	sparkle.LightEmission = 1
	sparkle.LightInfluence = 0
	sparkle.Size = NumberSequence.new(0.25)
	sparkle.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(0.8, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkle.Lifetime = NumberRange.new(1.5, 3)
	sparkle.Rate = 2 -- idle twinkle only; the fill celebration uses Emit()
	sparkle.Speed = NumberRange.new(0.4, 1)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = gemPart
	burst = sparkle

	-- Three pre-pitched PING chimes (engine built-in) played as an ascending
	-- arpeggio when the obelisk fills.
	for _, speed in { 1, 1.26, 1.5 } do
		local chime = Instance.new("Sound")
		chime.Name = "Chime"
		chime.SoundId = CHIME_SOUND
		chime.Volume = 0.6
		chime.PlaybackSpeed = speed
		chime.RollOffMaxDistance = 150
		chime.Parent = gemPart
		table.insert(chimes, chime)
	end

	-- Floating title + live percent readout.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.new(14, 0, 4, 0)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.MaxDistance = 140
	billboard.LightInfluence = 0
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.55, 0)
	title.Font = Enum.Font.FredokaOne
	title.Text = "🤝 SERVER HARMONY"
	title.TextScaled = true
	title.TextColor3 = PALETTE.teal
	title.TextStrokeColor3 = Color3.fromRGB(30, 55, 60)
	title.TextStrokeTransparency = 0.2
	title.Parent = billboard
	local percent = Instance.new("TextLabel")
	percent.Name = "Percent"
	percent.BackgroundTransparency = 1
	percent.Position = UDim2.new(0, 0, 0.55, 0)
	percent.Size = UDim2.new(1, 0, 0.45, 0)
	percent.Font = Enum.Font.FredokaOne
	percent.Text = "0% — produce, sell & type together!"
	percent.TextScaled = true
	percent.TextColor3 = PALETTE.glow
	percent.TextStrokeColor3 = Color3.fromRGB(30, 55, 60)
	percent.TextStrokeTransparency = 0.35
	percent.Parent = billboard
	billboard.Parent = gemPart
	percentLabel = percent

	model.PrimaryPart = base
	model.Parent = Workspace
end

-- ===== State mirror + visuals =====

-- Writes attributes and repaints segments/label from the current pool. Safe
-- when the obelisk hasn't been built (Init not run yet): attributes only.
local function refresh()
	Workspace:SetAttribute("HarmonyPoints", points)
	Workspace:SetAttribute("HarmonyGoal", goal)

	local frac = math.clamp(points / math.max(goal, 1), 0, 1)
	if os.clock() < flashUntil then
		-- Mid-celebration: keep the full-bright flash; the task.delay in
		-- celebrate() re-dirties state so the dim repaint lands afterwards.
		frac = 1
	end
	for i, seg in segments do
		if seg.Parent ~= nil then
			local segFrac = math.clamp(frac * SEGMENTS - (i - 1), 0, 1)
			seg.Transparency = DIM_TRANSPARENCY - (DIM_TRANSPARENCY - LIT_TRANSPARENCY) * segFrac
		end
	end
	local light = gemLight
	if light ~= nil then
		light.Brightness = 0.25 + 1.5 * frac
	end
	local label = percentLabel
	if label ~= nil then
		label.Text = `{math.floor(frac * 100 + 0.5)}% — produce, sell & type together!`
	end
end

-- Full-pool celebration: flash every segment bright, burst the crown gem,
-- ring the chime arpeggio, flex-Notify everyone and fire a free reward
-- event. Then reset the pool and grow the goal (session-only).
local function celebrate()
	-- Flash: everything bright for a beat (refresh() honours flashUntil, so
	-- the flush loop can't repaint dim state over it mid-celebration).
	flashUntil = os.clock() + 1.4
	for _, seg in segments do
		if seg.Parent ~= nil then
			seg.Transparency = 0
		end
	end
	local emitter = burst
	if emitter ~= nil and emitter.Parent ~= nil then
		emitter:Emit(45)
	end
	for i, chime in chimes do
		if chime.Parent ~= nil then
			task.delay((i - 1) * 0.14, function()
				if chime.Parent ~= nil then
					chime:Play()
				end
			end)
		end
	end

	Remotes.Notify:FireAllClients("flex", "🤝 HARMONY SURGE! The whole server filled the obelisk — free weather incoming!")

	local pool = GameConfig.Harmony.RewardEventIds
	if #pool > 0 then
		local eventId = pool[rng:NextInteger(1, #pool)]
		if not EventService.ForceEvent(eventId) then
			warn(`[HarmonyService] Unknown reward event id "{eventId}" — check GameConfig.Harmony.RewardEventIds`)
		end
	end

	-- Reset for the next fill (per contract: reset, then goal *= GoalGrowth;
	-- per server session only — nothing persists).
	points = 0
	goal *= GameConfig.Harmony.GoalGrowth
	notified50 = false
	notified90 = false

	task.delay(1.4, function()
		dirty = true -- let the flush loop repaint after the flash beat
	end)
end

-- Hype notifies + fill handling, run from the flush loop only (keeps
-- AddPoints yield-free and instance-free).
local function checkThresholds()
	local frac = points / math.max(goal, 1)
	if not notified50 and frac >= 0.5 and frac < 1 then
		notified50 = true
		Remotes.Notify:FireAllClients("info", "🤝 Server Harmony at 50% — keep producing, selling and typing together!")
	end
	if not notified90 and frac >= 0.9 and frac < 1 then
		notified90 = true
		Remotes.Notify:FireAllClients("flex", "🤝 Server Harmony at 90% — the obelisk is about to SURGE!")
	end
	if frac >= 1 then
		celebrate()
	end
end

-- ===== Public API =====

-- Adds to the GLOBAL pool (no player arg — harmony belongs to everyone).
-- Called from hot-ish paths (every belt collect, every sell, every accepted
-- keypress), so it only accumulates + flags; the FLUSH_SECONDS loop does all
-- instance work. Never yields, never errors on bad input.
function HarmonyService.AddPoints(pointsToAdd: number)
	if typeof(pointsToAdd) ~= "number" or pointsToAdd ~= pointsToAdd or pointsToAdd <= 0 or pointsToAdd == math.huge then
		return
	end
	points += pointsToAdd
	dirty = true
end

-- ===== Lifecycle =====

function HarmonyService.Init()
	buildObelisk()
	refresh() -- attributes exist before any client reads them
end

function HarmonyService.Start()
	-- Typing feeds harmony too (contract: +PointsType per accepted press).
	-- Callbacks are task.spawn'd by EquipService, so this stays off the
	-- typing hot path.
	EquipService.OnTypeAccepted(function(_player: Player, _letter: string?)
		HarmonyService.AddPoints(GameConfig.Harmony.PointsType)
	end)

	task.spawn(function()
		while true do
			task.wait(FLUSH_SECONDS)
			if dirty then
				dirty = false
				local ok, err = pcall(function()
					checkThresholds()
					refresh()
				end)
				if not ok then
					warn(`[HarmonyService] flush failed: {err}`)
				end
			end
		end
	end)
end

return HarmonyService
