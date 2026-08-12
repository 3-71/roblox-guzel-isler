--!strict
-- BuddyBuilder — procedural cute low-poly Thock Buddy critters (Phase 5).
-- A buddy is a ~2-stud chunky critter: boxy body in the def's bodyColor,
-- stubby feet / ears / tail in the accentColor, and the def's emoji face on
-- a front SurfaceGui. No external assets anywhere — plain parts only.
--
-- Contract (consumed by BuddyService):
--   Build(def: BuddyDef) -> Model
--     PrimaryPart is an INVISIBLE ANCHORED "Root" at the buddy's centre; all
--     visual parts are UNANCHORED, WeldConstraint'ed to Root and fully inert
--     (CanCollide/CanTouch/CanQuery false — buddies must never eat Touched
--     events or block raycasts; hard-won project lesson). Because only Root
--     is anchored, tweening Root.CFrame carries the whole critter, and
--     Model:PivotTo works as usual.
--     The feet soles sit FEET_DROP studs below the pivot: place a buddy on a
--     surface with PivotTo(surfaceCFrame + Vector3.new(0, FEET_DROP, 0)).
--   StartBob(model) -> Tween?
--     Gentle infinite idle bob around the model's CURRENT pivot (perched
--     copies only — the hub follower gets its bob mixed into BuddyService's
--     Heartbeat lerp instead). Caller owns the tween: Cancel() it before
--     destroying the model.
--   FEET_DROP: number — pivot-to-sole distance in studs (see above).

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Buddies = require(Shared.Config.Buddies)

local BuddyBuilder = {}

-- Pivot sits at the body centre; feet bottoms are 1.05 studs below it.
BuddyBuilder.FEET_DROP = 1.05

local BOB_HEIGHT = 0.22 -- studs of idle hover
local BOB_SECONDS = 1.4 -- one up-or-down leg of the bob

-- Same signature as the PlotBuilder/HubBuilder helper — part(name, size, cf,
-- color, MATERIAL?, PARENT). Parent stays the LAST argument; never pass it
-- into the material slot (the arity bug that once wiped whole plots).
-- Buddy variant: unanchored + fully inert decoration.
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
	p.Anchored = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weldTo(root: BasePart, p: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = p
	weld.Parent = p
end

-- Builds the critter at the world origin (identity CFrame); the caller
-- PivotTo's it into place. Local -Z is the buddy's face direction.
function BuddyBuilder.Build(def: Buddies.BuddyDef): Model
	local model = Instance.new("Model")
	model.Name = "Buddy_" .. def.id
	model:SetAttribute("BuddyId", def.id)

	-- Invisible anchored core every visual part welds onto.
	local root = part("Root", Vector3.new(0.4, 0.4, 0.4), CFrame.new(), def.bodyColor, nil, model)
	root.Anchored = true
	root.Transparency = 1
	model.PrimaryPart = root

	-- Chunky body.
	local body = part("Body", Vector3.new(1.7, 1.5, 1.4), CFrame.new(0, 0.05, 0), def.bodyColor, nil, model)
	weldTo(root, body)

	-- Face plate (accent) carrying the emoji SurfaceGui on its front (-Z).
	local face = part("Face", Vector3.new(1.15, 0.95, 0.14), CFrame.new(0, 0.2, -0.72), def.accentColor, nil, model)
	weldTo(root, face)
	local faceGui = Instance.new("SurfaceGui")
	faceGui.Face = Enum.NormalId.Front
	faceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	faceGui.PixelsPerStud = 50
	faceGui.LightInfluence = 0
	local faceLabel = Instance.new("TextLabel")
	faceLabel.BackgroundTransparency = 1
	faceLabel.Size = UDim2.fromScale(1, 1)
	faceLabel.Font = Enum.Font.FredokaOne
	faceLabel.Text = def.emoji
	faceLabel.TextScaled = true
	faceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	faceLabel.Parent = faceGui
	faceGui.Parent = face

	-- Stubby feet, poking forward a little.
	for _, side in { -1, 1 } do
		local foot = part(
			"Foot",
			Vector3.new(0.55, 0.4, 0.75),
			CFrame.new(side * 0.42, -0.85, -0.12),
			def.accentColor,
			nil,
			model
		)
		weldTo(root, foot)
	end

	-- Tiny ear nubs.
	for _, side in { -1, 1 } do
		local ear = part(
			"Ear",
			Vector3.new(0.35, 0.4, 0.35),
			CFrame.new(side * 0.52, 0.9, 0.05),
			def.accentColor,
			nil,
			model
		)
		weldTo(root, ear)
	end

	-- Tail nub on the back (+Z).
	local tail = part("Tail", Vector3.new(0.45, 0.45, 0.45), CFrame.new(0, -0.35, 0.78), def.accentColor, nil, model)
	weldTo(root, tail)

	return model
end

-- Starts the perched idle bob: Root.CFrame eases up BOB_HEIGHT and back,
-- forever (reverses = true). Call AFTER the final PivotTo — the loop is
-- anchored to the pivot at call time. Returns nil when the model has no
-- PrimaryPart (defensive; Build always sets one).
function BuddyBuilder.StartBob(model: Model): Tween?
	local root = model.PrimaryPart
	if root == nil then
		return nil
	end
	local info = TweenInfo.new(BOB_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tween = TweenService:Create(root, info, { CFrame = root.CFrame * CFrame.new(0, BOB_HEIGHT, 0) })
	tween:Play()
	return tween
end

return BuddyBuilder
