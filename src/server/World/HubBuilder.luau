--!strict
-- HubBuilder — the cozy central hub island everyone shares: stone plaza,
-- grass ring with low-poly trees / benches / lamps, the big "GROW A KEYBOARD"
-- sign, a giant keyboard monument, and paths radiating to every plot (same
-- ring math as PlotBuilder — plot positions come from
-- PlotBuilder.GetPlotCFrame so hub and plots can never drift apart).
--
-- Contract: parented under Workspace.Hub (Folder, created if missing), with
-- one enabled central SpawnLocation named exactly "HubSpawn". A large ground
-- disc under the whole map keeps players from falling into the void between
-- hub and plots. Call Build() once at startup, before PlotService accepts
-- players.
--
-- Phase 2 contract: three named instances live DIRECTLY under Workspace.Hub
-- (siblings of HubIsland, so workspace.Hub:FindFirstChild(name) finds them):
--   EarnedBoard / CollectionBoard   angled board Parts, each with a SurfaceGui
--                                   holding "Title" + "List" TextLabels
--                                   (LeaderboardService writes the List text)
--   RacePad                         flat glowing pad Part players stand on to
--                                   join races (TypingRaceService)
--
-- Phase 3 contract, same placement rule (direct child of Workspace.Hub):
--   CrateStall                      cozy market stall Model (posts + striped
--                                   awning + counter + crate props). Its board
--                                   carries a SurfaceGui with "Title" and
--                                   "Countdown" TextLabels — RestockShopService
--                                   writes the countdown text — plus a
--                                   BillboardGui restock hint.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)

local PlotBuilder = require(script.Parent.PlotBuilder)
local KeyboardModel = require(Shared.World.KeyboardModel)

local HubBuilder = {}

local PLAZA_RADIUS = 42
local GRASS_RADIUS = 58
local MONUMENT_KEYBOARD_ID = "blueberry" -- bright + chunky, reads well huge
local PLAZA_TOP_Y = 0.2 -- top surface of the Plaza cylinder (1.2 tall, centred at y = -0.4)
local BOARD_RADIUS = 33 -- leaderboard boards' distance from the plaza centre
local RACE_PAD_DIAMETER = 14

local PALETTE = {
	ground = Color3.fromRGB(106, 172, 88),
	grassRing = Color3.fromRGB(122, 196, 98),
	plaza = Color3.fromRGB(226, 217, 203),
	path = Color3.fromRGB(232, 210, 168),
	trunk = Color3.fromRGB(140, 100, 66),
	leaves = Color3.fromRGB(104, 180, 96),
	leavesLight = Color3.fromRGB(126, 202, 110),
	wood = Color3.fromRGB(172, 128, 86),
	lampPost = Color3.fromRGB(240, 236, 226),
	lampGlow = Color3.fromRGB(255, 230, 160),
	signBoard = Color3.fromRGB(255, 244, 222),
	signText = Color3.fromRGB(92, 62, 40),
	spawn = Color3.fromRGB(170, 226, 200),
	pedestal = Color3.fromRGB(214, 208, 196),
	boardGold = Color3.fromRGB(255, 199, 68),
	boardBlue = Color3.fromRGB(137, 180, 250),
	race = Color3.fromRGB(92, 225, 240),
	awningRed = Color3.fromRGB(226, 88, 96),
	awningCream = Color3.fromRGB(250, 244, 228),
	crateWood = Color3.fromRGB(191, 146, 97),
	crateLid = Color3.fromRGB(146, 104, 66),
}

-- Pastel keycap cubes decorating the top of the big sign.
local KEYCAP_COLORS = {
	Color3.fromRGB(255, 180, 190),
	Color3.fromRGB(255, 220, 140),
	Color3.fromRGB(160, 220, 255),
	Color3.fromRGB(180, 240, 170),
	Color3.fromRGB(220, 190, 255),
}

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

-- Horizontal unit direction toward plot i, plus the distance to its centre.
local function plotDirection(plotIndex: number): (Vector3, number)
	local center = PlotBuilder.GetPlotCFrame(plotIndex).Position
	local flat = Vector3.new(center.X, 0, center.Z)
	local distance = flat.Magnitude
	return flat / distance, distance
end

local function buildTree(hub: Model, position: Vector3, yaw: number)
	local cf = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	cylinder("TreeTrunk", 4.6, 1.3, cf * CFrame.new(0, 2.3, 0), PALETTE.trunk, Enum.Material.WoodPlanks, hub)
	part("TreeLeaves", Vector3.new(4.6, 4.6, 4.6), cf * CFrame.new(0, 6.1, 0), PALETTE.leaves, Enum.Material.Grass, hub)
	part("TreeLeaves", Vector3.new(3, 3, 3), cf * CFrame.new(0, 8.6, 0) * CFrame.Angles(0, math.rad(25), 0), PALETTE.leavesLight, Enum.Material.Grass, hub)
end

local function buildBench(hub: Model, cf: CFrame)
	part("BenchSeat", Vector3.new(5, 0.5, 1.7), cf * CFrame.new(0, 1.45, 0), PALETTE.wood, Enum.Material.WoodPlanks, hub)
	part("BenchLeg", Vector3.new(0.6, 1.2, 1.5), cf * CFrame.new(-2, 0.6, 0), PALETTE.wood, Enum.Material.WoodPlanks, hub)
	part("BenchLeg", Vector3.new(0.6, 1.2, 1.5), cf * CFrame.new(2, 0.6, 0), PALETTE.wood, Enum.Material.WoodPlanks, hub)
end

local function buildLamp(hub: Model, position: Vector3)
	local cf = CFrame.new(position)
	cylinder("LampPost", 6, 0.7, cf * CFrame.new(0, 3, 0), PALETTE.lampPost, nil, hub)
	local head = part("LampHead", Vector3.new(1.1, 1.1, 1.1), cf * CFrame.new(0, 6.4, 0), PALETTE.lampGlow, Enum.Material.Neon, hub)
	local light = Instance.new("PointLight")
	light.Color = PALETTE.lampGlow
	light.Range = 18
	light.Brightness = 0.8
	light.Parent = head
end

local function buildBigSign(hub: Model)
	-- Placed between two plot paths so it never blocks a walkway.
	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	local angle = 6.5 * step
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * 36
	local frameCF = CFrame.lookAt(Vector3.new(basePos.X, 0, basePos.Z), Vector3.new(0, 0, 0))

	-- Posts sit BEHIND the board (local +Z is away from the plaza) so the
	-- wood supports it without poking through the face.
	part("SignPost", Vector3.new(1.2, 11, 1.2), frameCF * CFrame.new(-10.8, 5.5, 1.15), PALETTE.wood, Enum.Material.WoodPlanks, hub)
	part("SignPost", Vector3.new(1.2, 11, 1.2), frameCF * CFrame.new(10.8, 5.5, 1.15), PALETTE.wood, Enum.Material.WoodPlanks, hub)
	local board = part("SignBoard", Vector3.new(24, 5.5, 1), frameCF * CFrame.new(0, 8.5, 0), PALETTE.signBoard, Enum.Material.WoodPlanks, hub)

	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 25
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = "GROW A KEYBOARD"
		label.TextScaled = true
		label.TextColor3 = PALETTE.signText
		label.Parent = gui
		gui.Parent = board
	end

	-- Keycap cubes perched on the board.
	for i = 1, 5 do
		local x = -8 + (i - 1) * 4
		local color = KEYCAP_COLORS[(i - 1) % #KEYCAP_COLORS + 1]
		part(
			"SignKeycap",
			Vector3.new(1.6, 1.6, 1.6),
			frameCF * CFrame.new(x, 12.05, 0) * CFrame.Angles(0, math.rad(i * 11), 0),
			color,
			nil,
			hub
		)
	end
end

local function buildMonument(hub: Model)
	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	local angle = 2.5 * step -- between two other paths, across from the sign
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * 30

	cylinder("MonumentBase", 1.4, 11, CFrame.new(basePos + Vector3.new(0, 0.9, 0)), PALETTE.pedestal, nil, hub)
	cylinder("MonumentColumn", 1.2, 8, CFrame.new(basePos + Vector3.new(0, 2.2, 0)), PALETTE.plaza, nil, hub)

	local def = Catalog.GetKeyboard(MONUMENT_KEYBOARD_ID)
	if def ~= nil then
		local keyboard = KeyboardModel.Build(def, 4.5)
		local pivot = CFrame.lookAt(basePos + Vector3.new(0, 4.2, 0), Vector3.new(0, 4.2, 0))
			* CFrame.Angles(math.rad(-18), 0, 0)
		keyboard:PivotTo(pivot)
		keyboard.Name = "MonumentKeyboard"
		-- KeyboardModel builds collectible-sized props with collision off;
		-- the monument is walkable scenery, so make it solid (players climb
		-- and stand on the giant keys — free photo spot).
		for _, inst in keyboard:GetDescendants() do
			if inst:IsA("BasePart") then
				inst.CanCollide = true
				inst.CanQuery = true
			end
		end
		keyboard.Parent = hub
	end
end

-- ===== Phase 2: plaza leaderboard boards + typing-race pad =====
-- These are parented DIRECTLY to the Workspace.Hub folder (not inside the
-- HubIsland model) so LeaderboardService / TypingRaceService reach them with a
-- plain workspace.Hub:FindFirstChild("EarnedBoard"/"CollectionBoard"/"RacePad").

local function getHubFolder(): Folder
	local existing = Workspace:FindFirstChild("Hub")
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Hub"
	folder.Parent = Workspace
	return folder
end

-- One big angled notice board on wooden posts, leaning back like a menu sign,
-- facing the plaza centre. Replaces any previous board of the same name.
local function buildBoard(hubFolder: Folder, name: string, titleText: string, accent: Color3, angle: number): Part
	local old = hubFolder:FindFirstChild(name)
	if old ~= nil then
		old:Destroy()
	end

	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * BOARD_RADIUS
	local footCF = CFrame.lookAt(Vector3.new(basePos.X, PLAZA_TOP_Y, basePos.Z), Vector3.new(0, PLAZA_TOP_Y, 0))

	local board = part(
		name,
		Vector3.new(14, 10, 0.8),
		footCF * CFrame.new(0, 9, 0.35) * CFrame.Angles(math.rad(12), 0, 0),
		PALETTE.signBoard,
		Enum.Material.WoodPlanks,
		hubFolder
	)

	-- Posts are parented to the board Part so the whole assembly is one unit
	-- (found, moved, or destroyed together via the contract name).
	part("BoardPost", Vector3.new(1.1, 8, 1.1), footCF * CFrame.new(-5.6, 4, 0.35), PALETTE.wood, Enum.Material.WoodPlanks, board)
	part("BoardPost", Vector3.new(1.1, 8, 1.1), footCF * CFrame.new(5.6, 4, 0.35), PALETTE.wood, Enum.Material.WoodPlanks, board)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front -- -Z face looks at the plaza centre
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 64)
	title.Font = Enum.Font.FredokaOne
	title.Text = titleText
	title.TextScaled = true
	title.TextColor3 = accent
	title.TextStrokeColor3 = PALETTE.signText
	title.TextStrokeTransparency = 0.6
	title.Parent = gui

	local list = Instance.new("TextLabel")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Position = UDim2.new(0, 20, 0, 72)
	list.Size = UDim2.new(1, -40, 1, -84)
	list.Font = Enum.Font.GothamMedium
	list.Text = "Loading..."
	list.TextSize = 22
	list.RichText = true
	list.TextWrapped = false
	list.TextXAlignment = Enum.TextXAlignment.Left
	list.TextYAlignment = Enum.TextYAlignment.Top
	list.TextColor3 = PALETTE.signText
	list.Parent = gui

	gui.Parent = board
	return board
end

local function buildRacePad(hubFolder: Folder)
	local old = hubFolder:FindFirstChild("RacePad")
	if old ~= nil then
		old:Destroy()
	end

	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	local angle = 3.5 * step -- between two paths, clear of monument / sign / spawn
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * 22

	local pad = cylinder(
		"RacePad",
		0.5,
		RACE_PAD_DIAMETER,
		CFrame.new(basePos.X, PLAZA_TOP_Y + 0.25, basePos.Z),
		PALETTE.race,
		Enum.Material.Neon,
		hubFolder
	)

	local light = Instance.new("PointLight")
	light.Color = PALETTE.race
	light.Range = 16
	light.Brightness = 0.7
	light.Parent = pad

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(16, 0, 4, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "⌨ TYPING RACE — stand here when a race starts!"
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = PALETTE.race
	label.TextStrokeColor3 = Color3.fromRGB(30, 55, 60)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = pad
end

-- ===== Phase 3: the "Limited Crates" market stall =====

-- One little wooden crate prop: box + slightly oversized lid slab.
local function buildCrate(stall: Model, cf: CFrame, size: number, boxColor: Color3)
	local box = part("Crate", Vector3.new(size, size, size), cf, boxColor, Enum.Material.WoodPlanks, stall)
	part(
		"CrateLid",
		Vector3.new(size + 0.2, 0.3, size + 0.2),
		cf * CFrame.new(0, size / 2 + 0.15, 0),
		PALETTE.crateLid,
		Enum.Material.WoodPlanks,
		box
	)
end

-- Cozy market stall for the restock shop: four posts, red/cream striped
-- awning, a counter with crate props, and the countdown board. Parented
-- DIRECTLY to Workspace.Hub as "CrateStall" (destroy-by-name rebuild, same
-- pattern as the leaderboard boards).
local function buildCrateStall(hubFolder: Folder)
	local old = hubFolder:FindFirstChild("CrateStall")
	if old ~= nil then
		old:Destroy()
	end

	local stall = Instance.new("Model")
	stall.Name = "CrateStall"

	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	local angle = 1.5 * step -- between two paths, well clear of monument/race pad
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local basePos = direction * 30
	-- Local space: -Z looks at the plaza centre (the stall's front).
	local footCF = CFrame.lookAt(Vector3.new(basePos.X, PLAZA_TOP_Y, basePos.Z), Vector3.new(0, PLAZA_TOP_Y, 0))

	-- Counter + serving top.
	local counter = part("Counter", Vector3.new(9.4, 2.4, 2.4), footCF * CFrame.new(0, 1.2, -1.6), PALETTE.wood, Enum.Material.WoodPlanks, stall)
	part("CounterTop", Vector3.new(10.2, 0.4, 3), footCF * CFrame.new(0, 2.6, -1.6), PALETTE.awningCream, Enum.Material.WoodPlanks, stall)

	-- Four corner posts holding the awning up.
	for _, x in { -4.55, 4.55 } do
		for _, z in { -2.4, 2.4 } do
			part("StallPost", Vector3.new(0.9, 8, 0.9), footCF * CFrame.new(x, 4, z), PALETTE.trunk, Enum.Material.WoodPlanks, stall)
		end
	end

	-- Striped awning: alternating red/cream planks, dipping toward the front.
	for i = 1, 6 do
		local x = -4.5 + (i - 1) * 1.8
		local color = if i % 2 == 1 then PALETTE.awningRed else PALETTE.awningCream
		part(
			"AwningStripe",
			Vector3.new(1.8, 0.3, 6.4),
			footCF * CFrame.new(x, 8.1, -0.2) * CFrame.Angles(math.rad(-14), 0, 0),
			color,
			Enum.Material.Fabric,
			stall
		)
	end

	-- Crate props: two on the counter, one big one on the ground beside it.
	buildCrate(stall, footCF * CFrame.new(-2.9, 3.7, -1.7) * CFrame.Angles(0, math.rad(15), 0), 1.8, PALETTE.crateWood)
	buildCrate(stall, footCF * CFrame.new(1.6, 3.5, -1.5) * CFrame.Angles(0, math.rad(-30), 0), 1.4, PALETTE.boardGold)
	buildCrate(stall, footCF * CFrame.new(5.6, 1.4, -2.2) * CFrame.Angles(0, math.rad(40), 0), 2.4, PALETTE.crateWood)

	-- Back board with the title + live countdown (RestockShopService writes
	-- the "Countdown" label text every second).
	local board = part("Board", Vector3.new(9.2, 5, 0.4), footCF * CFrame.new(0, 5.1, 2.35), PALETTE.signBoard, Enum.Material.WoodPlanks, stall)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front -- -Z face looks at the plaza centre
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.45, 0)
	title.Font = Enum.Font.FredokaOne
	title.Text = "🎁 LIMITED CRATES"
	title.TextScaled = true
	title.TextColor3 = PALETTE.boardGold
	title.TextStrokeColor3 = PALETTE.signText
	title.TextStrokeTransparency = 0.6
	title.Parent = gui

	local countdown = Instance.new("TextLabel")
	countdown.Name = "Countdown"
	countdown.BackgroundTransparency = 1
	countdown.Position = UDim2.new(0, 0, 0.45, 0)
	countdown.Size = UDim2.new(1, 0, 0.55, 0)
	countdown.Font = Enum.Font.FredokaOne
	countdown.Text = "Restock in --:--"
	countdown.TextScaled = true
	countdown.TextColor3 = PALETTE.signText
	countdown.TextStrokeTransparency = 1
	countdown.Parent = gui

	gui.Parent = board

	-- Floating hint above the awning.
	local minutes = math.floor(GameConfig.Restock.IntervalSeconds / 60 + 0.5)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.new(14, 0, 3.2, 0)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 6.5, 0)
	billboard.MaxDistance = 140
	billboard.LightInfluence = 0
	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Size = UDim2.fromScale(1, 1)
	hint.Font = Enum.Font.FredokaOne
	hint.Text = `Restocks every {minutes} minutes!`
	hint.TextScaled = true
	hint.TextWrapped = true
	hint.TextColor3 = PALETTE.awningRed
	hint.TextStrokeColor3 = PALETTE.signText
	hint.TextStrokeTransparency = 0.2
	hint.Parent = billboard
	billboard.Parent = board

	stall.PrimaryPart = counter
	stall.Parent = hubFolder
end

-- Builds (or rebuilds, replacing in place) the two plaza leaderboard boards
-- and returns (EarnedBoard, CollectionBoard). Build() already calls this, so
-- the boards exist by the time any service starts; calling again is safe.
function HubBuilder.BuildLeaderboards(): (Part, Part)
	local hubFolder = getHubFolder()
	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	-- Flanking the big sign (angle 6.5 * step): one board on each side.
	local earned = buildBoard(hubFolder, "EarnedBoard", "🏆 RICHEST", PALETTE.boardGold, 5.5 * step)
	local collection = buildBoard(hubFolder, "CollectionBoard", "📖 BEST COLLECTION", PALETTE.boardBlue, 7.5 * step)
	return earned, collection
end

function HubBuilder.Build(): Model
	local hubFolder = getHubFolder()
	local existing = hubFolder:FindFirstChild("HubIsland")
	if existing ~= nil then
		existing:Destroy()
	end

	local hub = Instance.new("Model")
	hub.Name = "HubIsland"

	local ringRadius = PlotBuilder.GetRingRadius()

	-- Safety ground disc under the entire map (hub + ring of plots): nobody
	-- falls into the void between hub and plots. Plot bases rest right on it.
	local groundDiameter = 2 * (ringRadius + GameConfig.PlotSize * 0.75)
	cylinder("GroundDisc", 2, groundDiameter, CFrame.new(0, -2, 0), PALETTE.ground, Enum.Material.Grass, hub)

	-- Island layers: grass ring, then the raised stone plaza.
	cylinder("GrassRing", 0.8, GRASS_RADIUS * 2, CFrame.new(0, -0.6, 0), PALETTE.grassRing, Enum.Material.Grass, hub)
	local plaza = cylinder("Plaza", 1.2, PLAZA_RADIUS * 2, CFrame.new(0, -0.4, 0), PALETTE.plaza, nil, hub)

	-- Paths radiating to each plot's front edge (shared ring math).
	for plotIndex = 1, GameConfig.PlotCount do
		local direction, distance = plotDirection(plotIndex)
		local innerR = PLAZA_RADIUS - 2
		local outerR = distance - GameConfig.PlotSize / 2 + 4 -- tuck under the plot edge
		local length = outerR - innerR
		if length > 0 then
			local mid = direction * (innerR + length / 2)
			local cf = CFrame.lookAt(
				Vector3.new(mid.X, -0.15, mid.Z),
				Vector3.new(direction.X * outerR, -0.15, direction.Z * outerR)
			)
			part("Path", Vector3.new(6, 0.5, length), cf, PALETTE.path, nil, hub)
		end
	end

	-- Cozy dressing on the grass ring, offset half a step so nothing sits on
	-- a path.
	local step = math.pi * 2 / math.max(GameConfig.PlotCount, 1)
	for i = 1, GameConfig.PlotCount do
		local angle = (i - 0.5) * step
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		buildTree(hub, direction * 51, angle)
		if i % 2 == 1 then
			local benchPos = direction * 34
			buildBench(hub, CFrame.lookAt(Vector3.new(benchPos.X, 0.2, benchPos.Z), Vector3.new(0, 0.2, 0)))
		else
			buildLamp(hub, direction * 40.5 + Vector3.new(0, 0.2, 0))
		end
	end

	buildBigSign(hub)
	buildMonument(hub)

	-- Global spawn: enabled, neutral, right at the plaza centre. Players whose
	-- plot isn't assigned yet land here.
	local hubSpawn = Instance.new("SpawnLocation")
	hubSpawn.Name = "HubSpawn"
	hubSpawn.Anchored = true
	hubSpawn.Size = Vector3.new(12, 1.1, 12)
	hubSpawn.CFrame = CFrame.new(0, 0.75, 0)
	hubSpawn.Color = PALETTE.spawn
	hubSpawn.Material = Enum.Material.SmoothPlastic
	hubSpawn.TopSurface = Enum.SurfaceType.Smooth
	hubSpawn.BottomSurface = Enum.SurfaceType.Smooth
	hubSpawn.Enabled = true
	hubSpawn.Neutral = true
	hubSpawn.Duration = 0
	hubSpawn.Parent = hub

	hub.PrimaryPart = plaza
	hub.Parent = hubFolder

	-- Phase 2/3 plaza furniture (siblings of HubIsland — see contract above).
	HubBuilder.BuildLeaderboards()
	buildRacePad(hubFolder)
	buildCrateStall(hubFolder)

	return hub
end

return HubBuilder
