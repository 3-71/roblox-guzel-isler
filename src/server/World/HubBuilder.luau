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

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)

local PlotBuilder = require(script.Parent.PlotBuilder)
local KeyboardModel = require(script.Parent.KeyboardModel)

local HubBuilder = {}

local PLAZA_RADIUS = 42
local GRASS_RADIUS = 58
local MONUMENT_KEYBOARD_ID = "blueberry" -- bright + chunky, reads well huge

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

	part("SignPost", Vector3.new(1.2, 8, 1.2), frameCF * CFrame.new(-10.8, 4, 0), PALETTE.wood, Enum.Material.WoodPlanks, hub)
	part("SignPost", Vector3.new(1.2, 8, 1.2), frameCF * CFrame.new(10.8, 4, 0), PALETTE.wood, Enum.Material.WoodPlanks, hub)
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
		keyboard.Parent = hub
	end
end

function HubBuilder.Build(): Model
	local hubFolder = Workspace:FindFirstChild("Hub")
	if hubFolder == nil or not hubFolder:IsA("Folder") then
		local folder = Instance.new("Folder")
		folder.Name = "Hub"
		folder.Parent = Workspace
		hubFolder = folder
	end
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
	return hub
end

return HubBuilder
