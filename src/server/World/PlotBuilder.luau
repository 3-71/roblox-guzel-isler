--!strict
-- PlotBuilder — procedurally builds one player plot. Cozy low-poly: chunky
-- anchored Parts, pastel palette, no meshes.
--
-- NAMING CONTRACT (direct children of the returned Model — other systems find
-- these by exact name, never rename):
--   Base                  ground Part (also the plot Model's PrimaryPart)
--   Factory               Model; recolorable parts are named "FactoryWall",
--                         tier bumps add "TierOrnament<level>" chimney rings
--   Conveyor1..4          Model with "Belt" Part carrying "BeltStart" and
--                         "BeltEnd" Attachments (factory end / collector end)
--   SellZone              glowing green Part (client opens sell UI on touch)
--   DisplayStand1..6      Model; PrimaryPart carries the "ItemAnchor" Attachment
--   Pads                  Folder; one Model per pad id from Config/Pads, each
--                         with a "Pad" Part as its PrimaryPart (touch surface)
--   SpawnPad              SpawnLocation (Enabled=false, Neutral=true —
--                         PlotService assigns player.RespawnLocation)
--   Sign                  Model showing "<name>'s Keyboard Farm"
--                         (SetSignInfo refreshes like count + VIP styling)
--
-- Plot-local axes: -Z faces the hub (front of the plot), +Z is the back.

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local FactoryTiers = require(Shared.Config.FactoryTiers)
local Pads = require(Shared.Config.Pads)
local Catalog = require(Shared.Catalog)

local PlotBuilder = {}

-- ===== Layout constants (pure aesthetics — balance numbers live in Config/*) =====

local FENCE = 58 -- picket fence inset from plot centre
local LANE_X0 = -18 -- x of conveyor lane 1
local LANE_GAP = 12 -- spacing between conveyor lanes
local BELT_LEN = 62 -- belt length; the belt reaches into the factory mouth
local BELT_CZ = 3 -- belt part centre z
local STAND_Z = -50 -- display stands along the front edge
-- Right side stops at 36 so the sell stall owns the front-right corner.
local STAND_X = { -45, -30, -15, 12, 24, 36 }
local PAD_HEIGHT = 0.4
local PAD_DIAMETER = 7
local POP_SOUND = "rbxasset://sounds/electronicpingshort.wav"

-- Minimum open ground between the hub centre and plot front edges. HubBuilder
-- reads the resulting radius through GetRingRadius().
local HUB_CLEARANCE = 75

local PALETTE = {
	grass = Color3.fromRGB(118, 192, 94),
	fence = Color3.fromRGB(250, 246, 238),
	roof = Color3.fromRGB(154, 106, 74),
	floor = Color3.fromRGB(216, 204, 186),
	chimney = Color3.fromRGB(168, 100, 88),
	window = Color3.fromRGB(255, 240, 198),
	machine = Color3.fromRGB(94, 98, 110),
	belt = Color3.fromRGB(52, 52, 58),
	stripe = Color3.fromRGB(255, 224, 130),
	rail = Color3.fromRGB(196, 156, 110),
	arch = Color3.fromRGB(137, 180, 250),
	bin = Color3.fromRGB(92, 108, 128),
	sell = Color3.fromRGB(96, 222, 133),
	sellDark = Color3.fromRGB(38, 122, 74),
	steel = Color3.fromRGB(126, 132, 146),
	stone = Color3.fromRGB(214, 208, 196),
	stoneLight = Color3.fromRGB(236, 230, 218),
	dirt = Color3.fromRGB(205, 178, 133),
	spawn = Color3.fromRGB(196, 178, 255),
	signBoard = Color3.fromRGB(255, 244, 222),
	signText = Color3.fromRGB(92, 62, 40),
	signGold = Color3.fromRGB(209, 150, 22), -- VIP sign text (readable on cream)
	wood = Color3.fromRGB(172, 128, 86),
}

local PAD_KIND_COLORS: { [string]: Color3 } = {
	factoryTier = Color3.fromRGB(255, 199, 68), -- gold
	conveyor = Color3.fromRGB(96, 152, 255), -- blue
	speed = Color3.fromRGB(255, 152, 74), -- orange
	luck = Color3.fromRGB(112, 220, 122), -- green
	storage = Color3.fromRGB(168, 168, 178), -- grey
	display = Color3.fromRGB(255, 142, 202), -- pink
	rebirth = Color3.fromRGB(255, 245, 200), -- radiant white-gold
}

local PAD_KIND_ICONS: { [string]: string } = {
	factoryTier = "🏭",
	conveyor = "🚚",
	speed = "⚡",
	luck = "🍀",
	storage = "📦",
	display = "🖼️",
	rebirth = "🔄",
}

-- Visibility bookkeeping: original property values are parked in attributes
-- while hidden so reveals restore exactly what the builder created.
local ATTR_HIDDEN = "GAK_Hidden"
local ATTR_ORIG_TRANSPARENCY = "GAK_OrigTransparency"
local ATTR_ORIG_CANCOLLIDE = "GAK_OrigCanCollide"
local ATTR_ORIG_CANTOUCH = "GAK_OrigCanTouch"

-- ===== Small factories =====

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

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

-- Flat-lying cylinder (vertical axis). Size convention: (height, d, d).
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

-- Marks a part as pure decoration: characters, Touched listeners and raycasts
-- all ignore it.
local function deco(p: BasePart): BasePart
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	return p
end

-- Sloped prism, same argument order as part(). The top face ramps down toward
-- local -Z (front), which is exactly the chute direction on this plot.
local function wedge(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	parent: Instance
): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.Size = size
	w.CFrame = cf
	w.Color = color
	w.Material = material or Enum.Material.SmoothPlastic
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

local function abbreviate(n: number): string
	local steps = { { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, step in steps do
		local threshold = step[1] :: number
		if n >= threshold then
			local text = string.format("%.1f", n / threshold)
			text = string.gsub(text, "%.0$", "")
			return text .. (step[2] :: string)
		end
	end
	return tostring(math.floor(n + 0.5))
end

local function laneX(lane: number): number
	return LANE_X0 + (lane - 1) * LANE_GAP
end

-- ===== Visibility helpers =====

local function isVisible(root: Instance): boolean
	return root:GetAttribute(ATTR_HIDDEN) ~= true
end

local function applyVisibility(root: Instance, visible: boolean)
	root:SetAttribute(ATTR_HIDDEN, not visible)
	local instances = root:GetDescendants()
	table.insert(instances, root)
	for _, inst in instances do
		if inst:IsA("BasePart") then
			if visible then
				local storedT = inst:GetAttribute(ATTR_ORIG_TRANSPARENCY)
				local storedCC = inst:GetAttribute(ATTR_ORIG_CANCOLLIDE)
				local storedCT = inst:GetAttribute(ATTR_ORIG_CANTOUCH)
				inst.Transparency = if typeof(storedT) == "number" then storedT else 0
				inst.CanCollide = if typeof(storedCC) == "boolean" then storedCC else true
				inst.CanTouch = if typeof(storedCT) == "boolean" then storedCT else true
				inst:SetAttribute(ATTR_ORIG_TRANSPARENCY, nil)
				inst:SetAttribute(ATTR_ORIG_CANCOLLIDE, nil)
				inst:SetAttribute(ATTR_ORIG_CANTOUCH, nil)
			else
				-- Snapshot originals only on the visible->hidden edge.
				if inst:GetAttribute(ATTR_ORIG_TRANSPARENCY) == nil then
					inst:SetAttribute(ATTR_ORIG_TRANSPARENCY, inst.Transparency)
					inst:SetAttribute(ATTR_ORIG_CANCOLLIDE, inst.CanCollide)
					inst:SetAttribute(ATTR_ORIG_CANTOUCH, inst.CanTouch)
				end
				inst.Transparency = 1
				inst.CanCollide = false
				inst.CanTouch = false
			end
		elseif inst:IsA("Light") or inst:IsA("ParticleEmitter") or inst:IsA("Beam") then
			inst.Enabled = visible
		elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			inst.Enabled = visible
		end
	end
end

-- ===== Celebration effects =====

local function burst(position: Vector3, color: Color3, parent: Instance)
	local holder = Instance.new("Part")
	holder.Name = "CelebrationBurst"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(position)
	holder.Parent = parent

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Lifetime = NumberRange.new(0.35, 0.8)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.6)
	emitter.LightEmission = 0.6
	emitter.Rate = 0
	emitter.Parent = holder
	emitter:Emit(30)

	Debris:AddItem(holder, 2)
end

local function playPop(parent: Instance, pitch: number)
	local sound = Instance.new("Sound")
	sound.SoundId = POP_SOUND
	sound.PlaybackSpeed = pitch
	sound.Volume = 0.6
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 2)
end

-- ===== Ring math (single source of truth; HubBuilder reuses it) =====

local function ringRadius(): number
	local count = math.max(GameConfig.PlotCount, 1)
	-- Adjacent plot centres must be at least a full plot + spacing apart.
	local chordNeeded = (GameConfig.PlotSize + GameConfig.PlotSpacing) / (2 * math.sin(math.pi / count))
	return math.max(chordNeeded, HUB_CLEARANCE + GameConfig.PlotSize / 2)
end

-- Plot centre at ground level, -Z (front) facing the hub at the origin.
function PlotBuilder.GetPlotCFrame(plotIndex: number): CFrame
	local count = math.max(GameConfig.PlotCount, 1)
	local angle = (plotIndex - 1) / count * math.pi * 2
	local radius = ringRadius()
	local center = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	return CFrame.lookAt(center, Vector3.new(0, 0, 0))
end

function PlotBuilder.GetRingRadius(): number
	return ringRadius()
end

-- ===== Section builders (all take the plot Model + its origin CFrame) =====

local function buildBase(plot: Model, origin: CFrame): Part
	local size = GameConfig.PlotSize
	local base = part("Base", Vector3.new(size, 1, size), origin * CFrame.new(0, -0.5, 0), PALETTE.grass, Enum.Material.Grass, plot)
	return base
end

local function buildFence(plot: Model, origin: CFrame)
	local fence = Instance.new("Model")
	fence.Name = "Fence"

	local postSize = Vector3.new(0.9, 3.2, 0.9)
	-- Every post wears a little wooden cap so the fence reads hand-carved.
	local function post(cf: CFrame)
		part("FencePost", postSize, cf, PALETTE.fence, nil, fence)
		deco(part("FencePostCap", Vector3.new(1.25, 0.3, 1.25), cf * CFrame.new(0, 1.75, 0), PALETTE.rail, Enum.Material.WoodPlanks, fence))
	end
	local step = (FENCE * 2) / 6
	for i = 0, 6 do
		local t = -FENCE + i * step
		-- Front side (z = -FENCE) keeps a gate gap in the middle.
		if math.abs(t) > 12 then
			post(origin * CFrame.new(t, 1.6, -FENCE))
		end
		post(origin * CFrame.new(t, 1.6, FENCE))
		if i > 0 and i < 6 then
			post(origin * CFrame.new(-FENCE, 1.6, t))
			post(origin * CFrame.new(FENCE, 1.6, t))
		end
	end

	-- Rails: solid back and sides, split front (gate gap |x| < 10).
	part("FenceRail", Vector3.new(FENCE * 2 + 0.9, 0.5, 0.4), origin * CFrame.new(0, 2.1, FENCE), PALETTE.fence, nil, fence)
	part("FenceRail", Vector3.new(0.4, 0.5, FENCE * 2 + 0.9), origin * CFrame.new(-FENCE, 2.1, 0), PALETTE.fence, nil, fence)
	part("FenceRail", Vector3.new(0.4, 0.5, FENCE * 2 + 0.9), origin * CFrame.new(FENCE, 2.1, 0), PALETTE.fence, nil, fence)
	part("FenceRail", Vector3.new(48, 0.5, 0.4), origin * CFrame.new(-34, 2.1, -FENCE), PALETTE.fence, nil, fence)
	part("FenceRail", Vector3.new(48, 0.5, 0.4), origin * CFrame.new(34, 2.1, -FENCE), PALETTE.fence, nil, fence)

	-- Warm lantern in each corner of the yard.
	for _, cx in { -52, 52 } do
		for _, cz in { -52, 52 } do
			deco(part("LampPost", Vector3.new(0.55, 6.6, 0.55), origin * CFrame.new(cx, 3.3, cz), PALETTE.wood, Enum.Material.WoodPlanks, fence))
			local head = deco(part("LampHead", Vector3.new(1.25, 1.25, 1.25), origin * CFrame.new(cx, 7.0, cz), PALETTE.window, Enum.Material.Neon, fence))
			deco(part("LampCap", Vector3.new(1.7, 0.35, 1.7), origin * CFrame.new(cx, 7.8, cz), PALETTE.roof, Enum.Material.WoodPlanks, fence))
			local glow = Instance.new("PointLight")
			glow.Color = PALETTE.window
			glow.Range = 18
			glow.Brightness = 0.7
			glow.Parent = head
		end
	end

	fence.Parent = plot
end

local function buildFactory(plot: Model, origin: CFrame)
	local factory = Instance.new("Model")
	factory.Name = "Factory"

	local wallColor = FactoryTiers[1].color

	part("FactoryFloor", Vector3.new(54, 1, 22), origin * CFrame.new(0, 0.5, 45), PALETTE.floor, nil, factory)
	-- Recolorable shell — every "FactoryWall" gets repainted on tier bumps.
	part("FactoryWall", Vector3.new(52, 14, 2), origin * CFrame.new(0, 8, 55), wallColor, nil, factory)
	part("FactoryWall", Vector3.new(2, 14, 24), origin * CFrame.new(-25, 8, 44), wallColor, nil, factory)
	part("FactoryWall", Vector3.new(2, 14, 24), origin * CFrame.new(25, 8, 44), wallColor, nil, factory)
	-- Front wall with the conveyor mouth (opening spans x -21..21, y up to 11).
	part("FactoryWall", Vector3.new(5, 14, 2), origin * CFrame.new(-23.5, 8, 33), wallColor, nil, factory)
	part("FactoryWall", Vector3.new(5, 14, 2), origin * CFrame.new(23.5, 8, 33), wallColor, nil, factory)
	part("FactoryWall", Vector3.new(42, 4, 2), origin * CFrame.new(0, 13, 33), wallColor, nil, factory)

	part("FactoryRoof", Vector3.new(56, 1.5, 28), origin * CFrame.new(0, 15.75, 44), PALETTE.roof, Enum.Material.WoodPlanks, factory)
	-- Chimney lives on the right roof edge, clear of the keyboard deck
	-- (deck spans x -21..21) so the TierOrnament rings never clip it.
	part("Chimney", Vector3.new(4, 20, 4), origin * CFrame.new(25, 15, 52), PALETTE.chimney, nil, factory)
	part("ChimneyCap", Vector3.new(5.2, 1, 5.2), origin * CFrame.new(25, 25.5, 52), PALETTE.chimney, nil, factory)

	-- ===== THE ROOF IS A GIANT KEYBOARD =====
	-- A huge tilted keyboard deck crowns the building so the factory reads as
	-- a keyboard factory from anywhere on the map. Climbable on purpose.
	local deckCF = origin * CFrame.new(0, 18.2, 44) * CFrame.Angles(math.rad(-8), 0, 0)
	part("RoofKeyboardDeck", Vector3.new(42, 2, 19), deckCF, Color3.fromRGB(64, 68, 82), nil, factory)
	local roofKeycapColors = {
		Color3.fromRGB(255, 196, 116),
		Color3.fromRGB(150, 206, 255),
		Color3.fromRGB(255, 158, 196),
		Color3.fromRGB(164, 226, 154),
		Color3.fromRGB(236, 232, 224),
	}
	local thock = { "T", "H", "O", "C", "K" }
	for row = 1, 3 do
		for col = 1, 7 do
			local cap = part(
				"RoofKeycap",
				Vector3.new(4.6, 1.8, 4.2),
				deckCF * CFrame.new(-18 + (col - 1) * 6, 1.9, -5.6 + (row - 1) * 5),
				roofKeycapColors[(row * 7 + col) % #roofKeycapColors + 1],
				nil,
				factory
			)
			-- The middle five caps of the front row spell THOCK.
			if row == 3 and col >= 2 and col <= 6 then
				local gui = Instance.new("SurfaceGui")
				gui.Face = Enum.NormalId.Top
				gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
				gui.PixelsPerStud = 30
				gui.LightInfluence = 0
				local letter = Instance.new("TextLabel")
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = Enum.Font.FredokaOne
				letter.Text = thock[col - 1]
				letter.TextScaled = true
				letter.TextColor3 = PALETTE.signText
				letter.Parent = gui
				gui.Parent = cap
			end
		end
	end
	-- Giant spacebar under the letter rows.
	part("RoofSpacebar", Vector3.new(28, 1.8, 4.2), deckCF * CFrame.new(0, 1.9, 8.2), Color3.fromRGB(236, 232, 224), nil, factory)

	-- ===== Giant ENTER key marks the conveyor mouth =====
	local enterKey = part("EnterKey", Vector3.new(12, 5, 2.6), origin * CFrame.new(0, 13.4, 31.6), Color3.fromRGB(150, 206, 255), nil, factory)
	local enterGui = Instance.new("SurfaceGui")
	enterGui.Face = Enum.NormalId.Front
	enterGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	enterGui.PixelsPerStud = 25
	enterGui.LightInfluence = 0
	local enterLabel = Instance.new("TextLabel")
	enterLabel.BackgroundTransparency = 1
	enterLabel.Size = UDim2.fromScale(1, 1)
	enterLabel.Font = Enum.Font.FredokaOne
	enterLabel.Text = "ENTER ⏎"
	enterLabel.TextScaled = true
	enterLabel.TextColor3 = Color3.fromRGB(38, 52, 72)
	enterLabel.Parent = enterGui
	enterGui.Parent = enterKey

	-- Keycap-framed windows on the side walls (warm neon behind a cap frame).
	for _, side in { -1, 1 } do
		part("WindowFrame", Vector3.new(2.6, 5.2, 5.2), origin * CFrame.new(side * 25, 9, 40), Color3.fromRGB(236, 232, 224), nil, factory)
		local window = part("FactoryWindow", Vector3.new(2.8, 4, 4), origin * CFrame.new(side * 25, 9, 40), PALETTE.window, Enum.Material.Neon, factory)
		window.CanCollide = false
	end

	-- The machine block visible through the mouth (belts emerge under it) —
	-- styled as a key-switch: housing + glowing stem the belts slide out of.
	part("Machine", Vector3.new(34, 6, 10), origin * CFrame.new(0, 4, 40), PALETTE.machine, nil, factory)
	local stem = part("MachineStem", Vector3.new(30, 1.2, 8), origin * CFrame.new(0, 7.6, 40), Color3.fromRGB(255, 196, 116), Enum.Material.Neon, factory)
	stem.CanCollide = false

	-- Skirting boards along the wall bases + cream cornice and roof fascia so
	-- the shell reads hand-built instead of box-plain.
	deco(part("FactorySkirt", Vector3.new(0.6, 1.6, 25), origin * CFrame.new(-26.3, 0.8, 44), PALETTE.roof, Enum.Material.WoodPlanks, factory))
	deco(part("FactorySkirt", Vector3.new(0.6, 1.6, 25), origin * CFrame.new(26.3, 0.8, 44), PALETTE.roof, Enum.Material.WoodPlanks, factory))
	deco(part("FactorySkirt", Vector3.new(53, 1.6, 0.6), origin * CFrame.new(0, 0.8, 56.3), PALETTE.roof, Enum.Material.WoodPlanks, factory))
	deco(part("FactoryCornice", Vector3.new(0.7, 0.9, 25), origin * CFrame.new(-26.35, 14.3, 44), PALETTE.fence, nil, factory))
	deco(part("FactoryCornice", Vector3.new(0.7, 0.9, 25), origin * CFrame.new(26.35, 14.3, 44), PALETTE.fence, nil, factory))
	deco(part("RoofFascia", Vector3.new(57, 0.7, 0.9), origin * CFrame.new(0, 14.6, 30.2), PALETTE.fence, nil, factory))
	deco(part("RoofFascia", Vector3.new(57, 0.7, 0.9), origin * CFrame.new(0, 14.6, 57.8), PALETTE.fence, nil, factory))

	-- Side dressing per wall: steam pipe, diamond-plate vent and a glowing
	-- porthole (right side dodges the chimney at z 50..54 and window at z 40).
	for _, side in { -1, 1 } do
		local pipeZ = if side == 1 then 44 else 50
		deco(cylinder("FactoryPipe", 11, 1.2, origin * CFrame.new(side * 26.4, 6.5, pipeZ), PALETTE.steel, Enum.Material.Metal, factory))
		deco(part("FactoryVent", Vector3.new(0.9, 2.4, 3.2), origin * CFrame.new(side * 26.45, 8, 34.8), PALETTE.machine, Enum.Material.DiamondPlate, factory))
		local ring = part("Porthole", Vector3.new(0.7, 3.2, 3.2), origin * CFrame.new(side * 26.1, 9.5, 47.5), PALETTE.fence, Enum.Material.Metal, factory)
		ring.Shape = Enum.PartType.Cylinder
		deco(ring)
		local glass = part("PortholeGlass", Vector3.new(0.75, 2.2, 2.2), origin * CFrame.new(side * 26.15, 9.5, 47.5), PALETTE.window, Enum.Material.Neon, factory)
		glass.Shape = Enum.PartType.Cylinder
		deco(glass)
	end

	-- A cheerful little awning over each belt mouth (alternating colors).
	for lane = 1, GameConfig.MaxConveyors do
		local awningColor = if lane % 2 == 0 then PALETTE.arch else PALETTE.fence
		deco(part(
			"MouthAwning",
			Vector3.new(5.6, 0.3, 3.0),
			origin * CFrame.new(laneX(lane), 10.0, 31.4) * CFrame.Angles(math.rad(-14), 0, 0),
			awningColor,
			nil,
			factory
		))
	end

	factory.Parent = plot
end

local function buildConveyor(plot: Model, origin: CFrame, lane: number)
	local conveyor = Instance.new("Model")
	conveyor.Name = "Conveyor" .. tostring(lane)
	local x = laneX(lane)

	-- Wider industrial belt on a raised steel frame (still well inside the
	-- 12-stud lane pitch: outermost detail sits at ±2.75).
	local belt = part("Belt", Vector3.new(4.6, 0.7, BELT_LEN), origin * CFrame.new(x, 1.0, BELT_CZ), PALETTE.belt, nil, conveyor)

	-- Ride anchors: keyboards tween BeltStart -> BeltEnd (ProductionService).
	local beltStart = Instance.new("Attachment")
	beltStart.Name = "BeltStart"
	beltStart.Position = Vector3.new(0, 0.55, BELT_LEN / 2 - 2) -- factory-mouth end (+Z)
	beltStart.Parent = belt
	local beltEnd = Instance.new("Attachment")
	beltEnd.Name = "BeltEnd"
	beltEnd.Position = Vector3.new(0, 0.55, -(BELT_LEN / 2 - 2)) -- collector end (-Z)
	beltEnd.Parent = belt

	-- Static "animated" segment stripes.
	for z = -26, 32, 6 do
		local stripe = part("Stripe", Vector3.new(4.2, 0.12, 1.1), origin * CFrame.new(x, 1.41, z), PALETTE.stripe, nil, conveyor)
		stripe.CanCollide = false
	end

	-- Drum rollers poke out of both ends (plain X-axis cylinders).
	for _, endZ in { BELT_CZ - BELT_LEN / 2 - 0.35, BELT_CZ + BELT_LEN / 2 + 0.35 } do
		local roller = part("Roller", Vector3.new(4.8, 1.1, 1.1), origin * CFrame.new(x, 1.0, endZ), PALETTE.steel, Enum.Material.Metal, conveyor)
		roller.Shape = Enum.PartType.Cylinder
		roller.CanCollide = false
	end

	-- Dark side skirts with a glowing accent line, topped by wooden hand rails.
	for _, side in { -1, 1 } do
		part("SidePanel", Vector3.new(0.4, 1.5, BELT_LEN), origin * CFrame.new(x + side * 2.5, 0.85, BELT_CZ), PALETTE.machine, Enum.Material.Metal, conveyor)
		local glowLine = part("PanelGlow", Vector3.new(0.1, 0.18, BELT_LEN - 2), origin * CFrame.new(x + side * 2.72, 1.15, BELT_CZ), PALETTE.arch, Enum.Material.Neon, conveyor)
		glowLine.CanCollide = false
		part("Rail", Vector3.new(0.7, 0.35, BELT_LEN), origin * CFrame.new(x + side * 2.5, 1.75, BELT_CZ), PALETTE.rail, Enum.Material.WoodPlanks, conveyor)
	end

	-- Support legs under the frame.
	for z = -24, 30, 9 do
		for _, side in { -1, 1 } do
			part("Leg", Vector3.new(0.5, 0.7, 0.5), origin * CFrame.new(x + side * 1.9, 0.35, z), PALETTE.steel, Enum.Material.Metal, conveyor)
		end
	end

	-- ===== Collector packing station =====
	-- Chunky layered arch (footed posts + corner blocks), a COLLECT header
	-- board with a status lamp, and a scanner bar under the top beam.
	for _, side in { -1, 1 } do
		part("ArchPost", Vector3.new(0.9, 6.4, 0.9), origin * CFrame.new(x + side * 2.75, 3.2, -30), PALETTE.arch, nil, conveyor)
		deco(part("ArchFoot", Vector3.new(1.5, 1.1, 1.5), origin * CFrame.new(x + side * 2.75, 0.55, -30), PALETTE.machine, Enum.Material.Metal, conveyor))
		deco(part("ArchBlock", Vector3.new(1.3, 1.0, 1.3), origin * CFrame.new(x + side * 2.75, 6.4, -30), PALETTE.fence, nil, conveyor))
	end
	part("ArchTop", Vector3.new(6.4, 0.9, 0.9), origin * CFrame.new(x, 6.85, -30), PALETTE.arch, nil, conveyor)
	deco(part("Scanner", Vector3.new(5.6, 0.22, 0.22), origin * CFrame.new(x, 5.3, -30), PALETTE.stripe, Enum.Material.Neon, conveyor))
	local header = deco(part("ArchHeader", Vector3.new(7.2, 1.3, 0.9), origin * CFrame.new(x, 7.75, -30), PALETTE.fence, nil, conveyor))
	local headerGui = Instance.new("SurfaceGui")
	headerGui.Face = Enum.NormalId.Front
	headerGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	headerGui.PixelsPerStud = 30
	headerGui.LightInfluence = 0
	local headerLabel = Instance.new("TextLabel")
	headerLabel.BackgroundTransparency = 1
	headerLabel.Size = UDim2.fromScale(1, 1)
	headerLabel.Font = Enum.Font.FredokaOne
	headerLabel.Text = "📦 COLLECT"
	headerLabel.TextScaled = true
	headerLabel.TextColor3 = Color3.fromRGB(38, 52, 72)
	headerLabel.Parent = headerGui
	headerGui.Parent = header
	local lamp = deco(part("StatusLamp", Vector3.new(0.7, 0.7, 0.7), origin * CFrame.new(x, 8.75, -30), PALETTE.sell, Enum.Material.Neon, conveyor))
	local lampLight = Instance.new("PointLight")
	lampLight.Color = PALETTE.sell
	lampLight.Range = 9
	lampLight.Brightness = 0.6
	lampLight.Parent = lamp

	-- Rimmed bin: a chute wedge slides boards off the belt end into the
	-- glowing mouth while funnel guides keep them centred.
	part("Collector", Vector3.new(5.4, 2.2, 3.4), origin * CFrame.new(x, 1.1, -33.6), PALETTE.bin, nil, conveyor)
	deco(part("CollectorRim", Vector3.new(5.9, 0.4, 3.9), origin * CFrame.new(x, 2.35, -33.6), PALETTE.steel, Enum.Material.Metal, conveyor))
	deco(part("CollectorMouth", Vector3.new(4.6, 1.4, 0.2), origin * CFrame.new(x, 1.3, -31.8), PALETTE.arch, Enum.Material.Neon, conveyor))
	deco(wedge("CollectorChute", Vector3.new(4.4, 0.75, 3.6), origin * CFrame.new(x, 0.975, -29.9), PALETTE.steel, Enum.Material.Metal, conveyor))
	for _, side in { -1, 1 } do
		deco(part(
			"FunnelGuide",
			Vector3.new(0.3, 1.3, 3.4),
			origin * CFrame.new(x + side * 2.1, 1.6, -29.6) * CFrame.Angles(0, math.rad(side * 12), 0),
			PALETTE.machine,
			Enum.Material.Metal,
			conveyor
		))
	end
	-- Tiny enter-keycap perched on the bin rim.
	local binCap = deco(part("BinKeycap", Vector3.new(1.7, 0.8, 1.7), origin * CFrame.new(x + 1.7, 2.95, -34.4), PALETTE.fence, nil, conveyor))
	local capGui = Instance.new("SurfaceGui")
	capGui.Face = Enum.NormalId.Top
	capGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	capGui.PixelsPerStud = 30
	capGui.LightInfluence = 0
	local capLabel = Instance.new("TextLabel")
	capLabel.BackgroundTransparency = 1
	capLabel.Size = UDim2.fromScale(1, 1)
	capLabel.Font = Enum.Font.FredokaOne
	capLabel.Text = "⏎"
	capLabel.TextScaled = true
	capLabel.TextColor3 = PALETTE.signText
	capLabel.Parent = capGui
	capGui.Parent = binCap

	conveyor.Parent = plot
end

-- Market stall in the front-right corner, angled to face the plot centre.
-- The glowing "SellZone" pad (naming contract!) sits in front of the counter.
local function buildSellZone(plot: Model, origin: CFrame)
	local sellCF = origin * CFrame.new(46, 0, -46) * CFrame.Angles(0, math.rad(135), 0)

	-- Dark plinth under the pad grounds the glow.
	part("SellRim", Vector3.new(10.4, 0.35, 8.4), sellCF * CFrame.new(0, 0.175, -6), PALETTE.sellDark, nil, plot)
	local zone = part("SellZone", Vector3.new(9, 0.5, 7), sellCF * CFrame.new(0, 0.45, -6), PALETTE.sell, Enum.Material.Neon, plot)

	local light = Instance.new("PointLight")
	light.Color = PALETTE.sell
	light.Range = 16
	light.Brightness = 0.8
	light.Parent = zone

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(6, 0, 1.8, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "💰 SELL"
	label.TextScaled = true
	label.TextColor3 = PALETTE.sell
	label.TextStrokeColor3 = Color3.fromRGB(30, 60, 40)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = zone

	-- The stall itself: counter, four posts, striped awning, back wall,
	-- register and coin stacks (pure decoration).
	local stall = Instance.new("Model")
	stall.Name = "SellStall"

	part("Counter", Vector3.new(10, 2.2, 2.2), sellCF * CFrame.new(0, 1.1, -1.2), PALETTE.wood, Enum.Material.WoodPlanks, stall)
	part("CounterTop", Vector3.new(10.8, 0.4, 3), sellCF * CFrame.new(0, 2.4, -1.2), PALETTE.fence, Enum.Material.WoodPlanks, stall)
	deco(part("CounterTrim", Vector3.new(10.6, 0.25, 0.3), sellCF * CFrame.new(0, 2.15, -2.75), PALETTE.sell, nil, stall))
	for _, sx in { -4.8, 4.8 } do
		for _, sz in { -2.4, 1.8 } do
			part("StallPost", Vector3.new(0.7, 7, 0.7), sellCF * CFrame.new(sx, 3.5, sz), PALETTE.wood, Enum.Material.WoodPlanks, stall)
		end
	end
	part("StallBack", Vector3.new(10, 3.6, 0.5), sellCF * CFrame.new(0, 1.8, 2.0), PALETTE.wood, Enum.Material.WoodPlanks, stall)

	-- Green/cream striped awning, tilted toward the plot.
	for i = 0, 6 do
		local stripe = part(
			"AwningStripe",
			Vector3.new(1.66, 0.3, 5.8),
			sellCF * CFrame.new(-4.98 + i * 1.66, 6.95, -0.4) * CFrame.Angles(math.rad(14), 0, 0),
			if i % 2 == 0 then PALETTE.sell else PALETTE.fence,
			nil,
			stall
		)
		stripe.CanCollide = false
	end

	-- Cash register with a glowing screen + gold coin stacks on the counter.
	part("Register", Vector3.new(1.6, 1.2, 1.2), sellCF * CFrame.new(3.1, 3.2, -1.2), PALETTE.machine, Enum.Material.Metal, stall)
	local screen = part("RegisterScreen", Vector3.new(1.2, 0.7, 0.15), sellCF * CFrame.new(3.1, 3.4, -1.85), PALETTE.sell, Enum.Material.Neon, stall)
	screen.CanCollide = false
	cylinder("CoinStack", 0.5, 1.2, sellCF * CFrame.new(-2.6, 2.85, -1.1), PALETTE.signGold, Enum.Material.Metal, stall)
	cylinder("CoinStack", 0.32, 1.2, sellCF * CFrame.new(-3.6, 2.76, -1.5), PALETTE.signGold, Enum.Material.Metal, stall)

	-- Hanging board over the counter.
	local board = part("SellSign", Vector3.new(6.5, 1.6, 0.4), sellCF * CFrame.new(0, 5.1, -2.6), PALETTE.signBoard, Enum.Material.WoodPlanks, stall)
	local signGui = Instance.new("SurfaceGui")
	signGui.Face = Enum.NormalId.Front
	signGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	signGui.PixelsPerStud = 30
	signGui.LightInfluence = 0
	local signLabel = Instance.new("TextLabel")
	signLabel.BackgroundTransparency = 1
	signLabel.Size = UDim2.fromScale(1, 1)
	signLabel.Font = Enum.Font.FredokaOne
	signLabel.Text = "KEYBOARD BUY-BACK"
	signLabel.TextScaled = true
	signLabel.TextColor3 = PALETTE.sellDark
	signLabel.Parent = signGui
	signGui.Parent = board

	stall.Parent = plot
end

local function buildDisplayStand(plot: Model, origin: CFrame, standIndex: number)
	local stand = Instance.new("Model")
	stand.Name = "DisplayStand" .. tostring(standIndex)

	local x = STAND_X[standIndex] or (standIndex - 3.5) * 15
	local footCF = origin * CFrame.new(x, 0, STAND_Z)

	-- Layered plinth -> stone base -> column with a brass ring -> plate with a
	-- soft up-light and a little nameplate ledge at the front.
	cylinder("StandPlinth", 0.28, 6.6, footCF * CFrame.new(0, 0.14, 0), PALETTE.stoneLight, Enum.Material.Slate, stand)
	cylinder("StandBase", 0.5, 5, footCF * CFrame.new(0, 0.25, 0), PALETTE.stone, nil, stand)
	part("StandColumn", Vector3.new(1.7, 3.2, 1.7), footCF * CFrame.new(0, 2.1, 0), PALETTE.stoneLight, nil, stand)
	deco(cylinder("StandRing", 0.22, 2.7, footCF * CFrame.new(0, 3.5, 0), PALETTE.signGold, Enum.Material.Metal, stand))
	local plate = part("StandPlate", Vector3.new(3.6, 0.4, 3.6), footCF * CFrame.new(0, 3.9, 0), PALETTE.stoneLight, nil, stand)
	deco(part("StandLedge", Vector3.new(2.6, 0.3, 0.7), footCF * CFrame.new(0, 3.55, -2.0), PALETTE.signBoard, Enum.Material.WoodPlanks, stand))

	local upLight = Instance.new("PointLight")
	upLight.Color = PALETTE.window
	upLight.Range = 7
	upLight.Brightness = 0.5
	upLight.Parent = plate

	-- ShowcaseService pivots displayed keyboards to this anchor.
	local anchor = Instance.new("Attachment")
	anchor.Name = "ItemAnchor"
	anchor.Position = Vector3.new(0, 1, 0)
	anchor.Parent = plate

	stand.PrimaryPart = plate
	stand.Parent = plot
end

-- Pads sit near what they unlock; chained kinds share a spot because only
-- one pad of a chain is ever visible at a time (PadService prereq graph).
local function padLocalCFrame(kind: string, level: number): CFrame
	local y = PAD_HEIGHT / 2
	if kind == "factoryTier" then
		return CFrame.new(31, y, 27) -- beside the factory mouth, right
	elseif kind == "conveyor" then
		return CFrame.new(laneX(level), y, -39) -- in front of its own lane
	elseif kind == "speed" then
		return CFrame.new(-31, y, 27) -- beside the factory mouth, left
	elseif kind == "luck" then
		return CFrame.new(-40, y, 0) -- left edge, mid-plot
	elseif kind == "storage" then
		return CFrame.new(40, y, 8) -- right edge, on the way to the sell corner
	elseif kind == "rebirth" then
		return CFrame.new(0, y, 20) -- center stage, in front of the factory
	end
	return CFrame.new(30, y, -42) -- display: by the showcase row
end

local function addPadLabel(padPart: BasePart, titleText: string, costText: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(7, 0, 3, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.55)
	title.Font = Enum.Font.FredokaOne
	title.Text = titleText
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeColor3 = Color3.fromRGB(40, 40, 60)
	title.TextStrokeTransparency = 0.2
	title.Parent = gui

	local cost = Instance.new("TextLabel")
	cost.Name = "Cost"
	cost.BackgroundTransparency = 1
	cost.Position = UDim2.fromScale(0, 0.55)
	cost.Size = UDim2.fromScale(1, 0.45)
	cost.Font = Enum.Font.GothamBold
	cost.Text = costText
	cost.TextScaled = true
	cost.TextColor3 = Color3.fromRGB(190, 255, 170)
	cost.TextStrokeColor3 = Color3.fromRGB(40, 40, 60)
	cost.TextStrokeTransparency = 0.2
	cost.Parent = gui

	gui.Parent = padPart
end

local function buildPads(plot: Model, origin: CFrame)
	local padsFolder = Instance.new("Folder")
	padsFolder.Name = "Pads"

	for _, padDef in Pads do
		local padModel = Instance.new("Model")
		padModel.Name = padDef.id

		local color = PAD_KIND_COLORS[padDef.kind] or Color3.fromRGB(220, 220, 220)
		local baseCF = origin * padLocalCFrame(padDef.kind, padDef.level)

		-- Layered button: stone plinth, dark colored ring, glowing core disc.
		local rim = cylinder("PadRim", 0.35, PAD_DIAMETER + 1.8, baseCF * CFrame.new(0, -0.025, 0), PALETTE.stone, nil, padModel)
		rim.CanTouch = false
		local ring = cylinder("PadRing", 0.44, PAD_DIAMETER + 0.5, baseCF * CFrame.new(0, 0.02, 0), color:Lerp(Color3.new(0, 0, 0), 0.45), nil, padModel)
		ring.CanCollide = false
		ring.CanTouch = false
		local padPart = cylinder(
			"Pad",
			PAD_HEIGHT,
			PAD_DIAMETER - 0.8,
			baseCF * CFrame.new(0, 0.06, 0),
			color,
			Enum.Material.Neon,
			padModel
		)
		padPart.CanCollide = false -- walk onto it; PadService listens to Touched
		padPart.CanTouch = true

		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 8
		light.Brightness = 0.5
		light.Parent = padPart

		local costText: string
		if padDef.kind == "rebirth" then
			-- Dynamic cost; RebirthService keeps this label current per player.
			costText = "$" .. abbreviate(GameConfig.Rebirth.BaseCost)
		else
			local costValue = Catalog.GetPadCost(padDef.id)
			costText = if costValue ~= nil then "$" .. abbreviate(costValue) else ""
		end
		addPadLabel(padPart, (PAD_KIND_ICONS[padDef.kind] or "🛒") .. " " .. padDef.name, costText)

		padModel.PrimaryPart = padPart
		padModel.Parent = padsFolder
	end

	padsFolder.Parent = plot
end

local function buildSpawnPad(plot: Model, origin: CFrame)
	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "SpawnPad"
	spawnPad.Anchored = true
	spawnPad.Size = Vector3.new(8, 0.6, 8)
	spawnPad.CFrame = origin * CFrame.new(-36, 0.3, -42)
	spawnPad.Color = PALETTE.spawn
	spawnPad.Material = Enum.Material.SmoothPlastic
	spawnPad.TopSurface = Enum.SurfaceType.Smooth
	spawnPad.BottomSurface = Enum.SurfaceType.Smooth
	-- Disabled: PlotService points player.RespawnLocation here instead of
	-- letting the global spawn selection pick it up.
	spawnPad.Enabled = false
	spawnPad.Neutral = true
	spawnPad.Duration = 0
	spawnPad.Parent = plot
end

-- Pure eye-candy layer: dirt paths, stepping stones, giant keycap props,
-- flowers and the spawn landing ring. Everything is non-colliding decoration,
-- so walkways, Touched pads and raycasts are unaffected.
local function buildGroundDecor(plot: Model, origin: CFrame)
	local decor = Instance.new("Model")
	decor.Name = "Decor"

	-- Dirt paths: gate -> stand row, then a cross path past the spawn pad all
	-- the way to the sell corner (flat 0.05 overlays on the grass).
	deco(part("PathStrip", Vector3.new(7, 0.05, 15), origin * CFrame.new(0, 0.03, -50.5), PALETTE.dirt, Enum.Material.Ground, decor))
	deco(part("PathStrip", Vector3.new(90, 0.05, 5), origin * CFrame.new(1, 0.03, -44), PALETTE.dirt, Enum.Material.Ground, decor))

	-- Stepping stones up the centre walkway toward the rebirth pad.
	local stoneSpots = {
		Vector2.new(0, -41),
		Vector2.new(0.5, -35),
		Vector2.new(-0.5, -29),
		Vector2.new(0.4, -23),
		Vector2.new(-0.4, -17),
		Vector2.new(0.3, -11),
	}
	for i, spot in stoneSpots do
		local stoneColor = if i % 2 == 0 then PALETTE.stoneLight else PALETTE.stone
		deco(cylinder("SteppingStone", 0.06, 1.8, origin * CFrame.new(spot.X, 0.03, spot.Y), stoneColor, Enum.Material.Slate, decor))
	end

	-- Two giant fallen keycaps ("G" and "K") as landmarks off the walkways.
	local props = {
		{ x = -48, z = -16, letter = "G", color = Color3.fromRGB(236, 232, 224), text = PALETTE.signText },
		{ x = 50, z = 26, letter = "K", color = Color3.fromRGB(150, 206, 255), text = Color3.fromRGB(38, 52, 72) },
	}
	for _, prop in props do
		local cap = deco(part(
			"GiantKeycap",
			Vector3.new(4.6, 2.6, 4.6),
			origin * CFrame.new(prop.x, 1.3, prop.z) * CFrame.Angles(0, math.rad(14), 0),
			prop.color,
			nil,
			decor
		))
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Top
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 30
		gui.LightInfluence = 0
		local letter = Instance.new("TextLabel")
		letter.BackgroundTransparency = 1
		letter.Size = UDim2.fromScale(1, 1)
		letter.Font = Enum.Font.FredokaOne
		letter.Text = prop.letter
		letter.TextScaled = true
		letter.TextColor3 = prop.text
		letter.Parent = gui
		gui.Parent = cap
	end

	-- Grass tufts with a bright bloom on top, scattered off the walkways.
	local blooms = {
		{ x = -50, z = -28, color = PAD_KIND_COLORS.display },
		{ x = 30, z = -18, color = PALETTE.stripe },
		{ x = -52, z = 36, color = PAD_KIND_COLORS.speed },
	}
	for _, bloom in blooms do
		deco(part(
			"GrassTuft",
			Vector3.new(1.0, 0.8, 1.0),
			origin * CFrame.new(bloom.x, 0.35, bloom.z) * CFrame.Angles(0, math.rad(30), 0),
			Color3.fromRGB(96, 176, 74),
			Enum.Material.Grass,
			decor
		))
		deco(part(
			"Flower",
			Vector3.new(0.55, 0.55, 0.55),
			origin * CFrame.new(bloom.x, 0.95, bloom.z) * CFrame.Angles(math.rad(15), math.rad(40), 0),
			bloom.color,
			Enum.Material.Neon,
			decor
		))
	end

	-- Friendly landing ring around the spawn pad (pad itself is untouched).
	deco(cylinder("SpawnGlow", 0.14, 13.2, origin * CFrame.new(-36, 0.07, -42), PALETTE.spawn, Enum.Material.Neon, decor))
	local spawnRing = deco(cylinder("SpawnRing", 0.3, 11.6, origin * CFrame.new(-36, 0.16, -42), PALETTE.stoneLight, Enum.Material.Slate, decor))
	local spawnLight = Instance.new("PointLight")
	spawnLight.Color = PALETTE.spawn
	spawnLight.Range = 10
	spawnLight.Brightness = 0.4
	spawnLight.Parent = spawnRing

	decor.Parent = plot
end

local function buildSign(plot: Model, origin: CFrame, player: Player)
	local sign = Instance.new("Model")
	sign.Name = "Sign"

	-- Right beside the gate gap (|x| < 10), just OUTSIDE the front fence line,
	-- squared up with the fence so it reads dead straight on the approach.
	local signCF = origin * CFrame.new(15.5, 0, -59.5)
	-- Posts sit fully BEHIND the board: board is 0.6 deep centred at z 0
	-- (back face +0.3), posts are 0.8 deep centred at z 0.7 (front face +0.3).
	part("SignPost", Vector3.new(0.8, 7.4, 0.8), signCF * CFrame.new(-5.6, 3.7, 0.7), PALETTE.wood, Enum.Material.WoodPlanks, sign)
	part("SignPost", Vector3.new(0.8, 7.4, 0.8), signCF * CFrame.new(5.6, 3.7, 0.7), PALETTE.wood, Enum.Material.WoodPlanks, sign)
	deco(part("SignFoot", Vector3.new(1.3, 0.6, 1.3), signCF * CFrame.new(-5.6, 0.3, 0.7), PALETTE.wood, Enum.Material.WoodPlanks, sign))
	deco(part("SignFoot", Vector3.new(1.3, 0.6, 1.3), signCF * CFrame.new(5.6, 0.3, 0.7), PALETTE.wood, Enum.Material.WoodPlanks, sign))
	local board = part("SignBoard", Vector3.new(13.5, 3.4, 0.6), signCF * CFrame.new(0, 6.2, 0), PALETTE.signBoard, Enum.Material.WoodPlanks, sign)
	-- Little roof cap on top of the board.
	part("SignCap", Vector3.new(14.3, 0.5, 1.2), signCF * CFrame.new(0, 8.15, 0.15), PALETTE.roof, Enum.Material.WoodPlanks, sign)

	-- Front face (-Z) looks toward the hub, so visitors read it walking in.
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 30
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = player.DisplayName .. "'s Keyboard Farm"
		label.TextScaled = true
		label.TextColor3 = PALETTE.signText
		label.Parent = gui
		gui.Parent = board
	end

	sign.Parent = plot
end

-- ===== Public API =====

function PlotBuilder.Build(plotIndex: number, player: Player): Model
	local plotsFolder = getOrCreateFolder(Workspace, "Plots")
	local origin = PlotBuilder.GetPlotCFrame(plotIndex)

	local plot = Instance.new("Model")
	plot.Name = "Plot" .. tostring(plotIndex)
	plot:SetAttribute("PlotIndex", plotIndex)
	plot:SetAttribute("OwnerUserId", player.UserId)

	local base = buildBase(plot, origin)
	buildFence(plot, origin)
	buildFactory(plot, origin)
	for lane = 1, GameConfig.MaxConveyors do
		buildConveyor(plot, origin, lane)
	end
	buildSellZone(plot, origin)
	for standIndex = 1, GameConfig.MaxDisplayStands do
		buildDisplayStand(plot, origin, standIndex)
	end
	buildPads(plot, origin)
	buildSpawnPad(plot, origin)
	buildGroundDecor(plot, origin)
	buildSign(plot, origin, player)

	-- Fresh-plot visibility baseline: conveyor 1 is the free starter lane,
	-- everything upgrade-gated starts hidden. PadService refreshes pad
	-- visibility from the profile right after (returning players).
	for lane = 2, GameConfig.MaxConveyors do
		local conveyor = plot:FindFirstChild("Conveyor" .. tostring(lane))
		if conveyor ~= nil then
			applyVisibility(conveyor, false)
		end
	end
	for standIndex = 1, GameConfig.MaxDisplayStands do
		local stand = plot:FindFirstChild("DisplayStand" .. tostring(standIndex))
		if stand ~= nil then
			applyVisibility(stand, false)
		end
	end
	for _, padDef in Pads do
		if padDef.prereq ~= nil then
			PlotBuilder.SetPadVisible(plot, padDef.id, false)
		end
	end

	plot.PrimaryPart = base
	plot.Parent = plotsFolder
	return plot
end

function PlotBuilder.SetPadVisible(plot: Model, padId: string, visible: boolean)
	local padsFolder = plot:FindFirstChild("Pads")
	if padsFolder == nil then
		return
	end
	local padModel = padsFolder:FindFirstChild(padId)
	if padModel ~= nil then
		applyVisibility(padModel, visible)
	end
end

-- Replaces a pad's cost line (dynamic-cost pads like rebirth).
function PlotBuilder.SetPadLabel(plot: Model, padId: string, text: string)
	local padsFolder = plot:FindFirstChild("Pads")
	local padModel = if padsFolder then padsFolder:FindFirstChild(padId) else nil
	if padModel == nil then
		return
	end
	local label = padModel:FindFirstChild("Label", true)
	local cost = if label then label:FindFirstChild("Cost") else nil
	if cost ~= nil and cost:IsA("TextLabel") then
		cost.Text = text
	end
end

-- Refreshes the plot sign (both faces): "<name>'s Keyboard Farm", plus
-- "  ❤ <likes>" once the farm has likes, and a gold "👑 " VIP treatment.
-- LikeService calls this on every like; MonetizationService on VIP detection.
function PlotBuilder.SetSignInfo(plot: Model, ownerName: string, likes: number, vip: boolean)
	local sign = plot:FindFirstChild("Sign")
	if sign == nil then
		return
	end

	local text = ownerName .. "'s Keyboard Farm"
	if vip then
		text = "👑 " .. text
	end
	if likes > 0 then
		text = text .. "  ❤ " .. tostring(math.floor(likes))
	end
	local color = if vip then PALETTE.signGold else PALETTE.signText

	for _, inst in sign:GetDescendants() do
		if inst:IsA("TextLabel") then
			inst.Text = text
			inst.TextColor3 = color
		end
	end
end

-- Visual growth after a purchase. Idempotent, so PadService may safely replay
-- owned pads on profile load to restore factory color / lanes / stands; the
-- celebration only fires while the pad model is still visible (live purchase).
function PlotBuilder.OnPadPurchased(plot: Model, padId: string)
	local padDef = Catalog.GetPad(padId)
	if padDef == nil then
		return
	end

	local padsFolder = plot:FindFirstChild("Pads")
	local padModel: Instance? = if padsFolder ~= nil then padsFolder:FindFirstChild(padId) else nil
	local live = padModel ~= nil and isVisible(padModel)

	local kind: string = padDef.kind
	local level: number = padDef.level

	if kind == "conveyor" then
		local conveyor = plot:FindFirstChild("Conveyor" .. tostring(level))
		if conveyor ~= nil and not isVisible(conveyor) then
			applyVisibility(conveyor, true)
			local belt = conveyor:FindFirstChild("Belt")
			if live and belt ~= nil and belt:IsA("BasePart") then
				burst(belt.Position + Vector3.new(0, 3, 0), PAD_KIND_COLORS.conveyor, plot)
			end
		end
	elseif kind == "display" then
		local stand = plot:FindFirstChild("DisplayStand" .. tostring(level))
		if stand ~= nil and stand:IsA("Model") and not isVisible(stand) then
			applyVisibility(stand, true)
			local plate = stand.PrimaryPart
			if live and plate ~= nil then
				burst(plate.Position + Vector3.new(0, 2, 0), PAD_KIND_COLORS.display, plot)
			end
		end
	elseif kind == "factoryTier" then
		local tierInfo = FactoryTiers[level]
		local factory = plot:FindFirstChild("Factory")
		if tierInfo ~= nil and factory ~= nil then
			for _, inst in factory:GetDescendants() do
				if inst:IsA("BasePart") and inst.Name == "FactoryWall" then
					inst.Color = tierInfo.color
				end
			end
			-- One glowing chimney ring per tier bump — the factory visibly grows.
			local ornamentName = "TierOrnament" .. tostring(level)
			if factory:FindFirstChild(ornamentName) == nil then
				local chimney = factory:FindFirstChild("Chimney")
				if chimney ~= nil and chimney:IsA("BasePart") then
					local yOffset = -10 + 1.2 + (level - 2) * 1.6
					local ring = cylinder(ornamentName, 0.7, 6, chimney.CFrame * CFrame.new(0, yOffset, 0), tierInfo.color, Enum.Material.Neon, factory)
					ring.CanCollide = false
					if live then
						burst(ring.Position, tierInfo.color, plot)
					end
				end
			end
		end
	end

	-- Quick pop at the pad itself.
	if live and padModel ~= nil and padModel:IsA("Model") then
		local padPart = padModel.PrimaryPart
		if padPart ~= nil then
			burst(padPart.Position + Vector3.new(0, 1.5, 0), PAD_KIND_COLORS[kind] or Color3.fromRGB(255, 255, 255), plot)
			playPop(padPart, 1.4)
		end
	end
end

function PlotBuilder.Destroy(plot: Model)
	plot:Destroy()
end

return PlotBuilder
