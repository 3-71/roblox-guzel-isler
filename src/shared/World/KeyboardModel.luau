--!strict
-- KeyboardModel — procedural low-poly collectible keyboard, ~4 x 0.4 x 1.6
-- studs at scale 1. Body slab + keycap grid from the def's `look` spec, with
-- a distinct silhouette per style and a rarity glow (PointLight + neon accent
-- keycaps) when Rarities[def.rarityTier].glow is set.
--
-- All parts are Anchored, CanCollide/CanTouch/CanQuery = false so the model
-- is pure visual: belt rides, display stands and hand welds all just PivotTo /
-- offset from Model.PrimaryPart ("Body", pivot at the slab centre).
-- The keyboard's front (spacebar edge) faces local -Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared.Config.Rarities)

type KeyboardLook = {
	bodyColor: Color3,
	keycapColor: Color3,
	accentColor: Color3,
	style: string,
}

-- Structural subset of Config/Keyboards' KeyboardDef; width subtyping lets
-- callers pass the full def straight from Catalog.GetKeyboard.
export type KeyboardDef = {
	id: string,
	rarityTier: number,
	look: KeyboardLook,
}

local KeyboardModel = {}

function KeyboardModel.Build(def: KeyboardDef, scale: number, mutation: any?): Model
	scale = math.max(scale, 0.05)
	local look = def.look
	local style = look.style
	local rarity = Rarities[def.rarityTier]
	local glow = rarity ~= nil and rarity.glow == true

	-- Base slab dimensions (pre-scale), tweaked per style silhouette.
	local bodyW, bodyH, bodyD = 4, 0.4, 1.6
	if style == "slim" then
		bodyH = 0.22
	elseif style == "chunky" then
		bodyH = 0.6
	elseif style == "retro" then
		bodyH = 0.45
	end

	local model = Instance.new("Model")
	model.Name = "Keyboard_" .. def.id
	model:SetAttribute("KeyboardId", def.id)
	model:SetAttribute("RarityTier", def.rarityTier)

	local function newPart(className: string, size: Vector3, cf: CFrame, color: Color3): BasePart
		local p = Instance.new(className) :: BasePart
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Size = size * scale
		p.CFrame = cf
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.Parent = model
		return p
	end

	-- Offsets stay in pre-scale units; scaled once here.
	local function off(x: number, y: number, z: number): CFrame
		return CFrame.new(x * scale, y * scale, z * scale)
	end

	-- Keycap grid parameters. Tiny builds (equipped-hand scale) drop keycap
	-- count to keep the part budget low.
	local smallBuild = scale <= 0.5
	local rows = if smallBuild then 3 else 4
	local cols = if smallBuild then 5 else 8
	if style == "chunky" and not smallBuild then
		cols = 7 -- bigger bezel leaves room for fewer, fatter keys
	end
	local bezel = if style == "chunky" then 0.4 else 0.22
	local capH = if style == "slim" then 0.09 elseif style == "chunky" then 0.16 else 0.12
	local capY = bodyH / 2 + capH / 2
	local areaD = bodyD - bezel * 2
	local rowPitch = areaD / (rows + 1) -- extra row reserved for the spacebar
	local capDepth = rowPitch * 0.7

	local baseCapMaterial = if style == "crystal" then Enum.Material.Neon else Enum.Material.SmoothPlastic
	local capTransparency = if style == "crystal" then 0.15 else 0

	-- Multi-colour keycaps: every board fans hues around its keycap colour so
	-- the rows read as distinct colour bands; glowing rarities (Mechanical+)
	-- go full diagonal rainbow like a showpiece RGB board. Near-grey boards
	-- get a light/dark checkerboard instead — cheap tiers stay deliberately
	-- drab so rarity still reads at a glance.
	local capHue, capSat, capVal = look.keycapColor:ToHSV()
	local function capColor(r: number, c: number): Color3
		if glow then
			local hue = (capHue + (r - 1) / rows + (c - 1) / (cols * rows)) % 1
			return Color3.fromHSV(hue, math.max(capSat, 0.65), math.max(capVal, 0.9))
		end
		if capSat < 0.12 then
			local shade = if (r + c) % 2 == 0 then 0.07 else -0.06
			return Color3.fromHSV(capHue, capSat, math.clamp(capVal + shade, 0.05, 1))
		end
		local hue = (capHue + (r - (rows + 1) / 2) * 0.05) % 1
		local val = math.clamp(capVal + (if c % 2 == 0 then 0.05 else -0.04), 0.05, 1)
		return Color3.fromHSV(hue, capSat, val)
	end

	local function placeCap(baseCF: CFrame, x: number, z: number, width: number, accent: boolean, rowColor: Color3?)
		local cap = newPart(
			"Part",
			Vector3.new(width, capH, capDepth),
			baseCF * off(x, capY, z),
			if accent then look.accentColor else (rowColor or look.keycapColor)
		)
		cap.Name = "Keycap"
		cap.Material = if accent and glow then Enum.Material.Neon else baseCapMaterial
		cap.Transparency = capTransparency
	end

	local function placeGrid(baseCF: CFrame, gridW: number, gridCols: number)
		local pitchX = gridW / gridCols
		local capW = pitchX * 0.72
		for r = 1, rows do
			local z = areaD / 2 - (r - 0.5) * rowPitch -- back (+Z) to front
			-- Real keyboards stagger their rows; tiny builds skip it.
			local stagger = if smallBuild then 0 else (r - (rows + 1) / 2) * pitchX * 0.1
			for c = 1, gridCols do
				local x = -gridW / 2 + (c - 0.5) * pitchX + stagger
				local isEdge = not smallBuild and (c == 1 or c == gridCols)
				if isEdge then
					-- Wider modifier keys (Tab/Shift/Enter feel) on the outside
					-- columns, nudged outward into the margin.
					local shift = if c == 1 then -pitchX * 0.08 else pitchX * 0.08
					placeCap(baseCF, x + shift, z, capW * 1.22, r == 2 and c == gridCols, capColor(r, c))
				else
					placeCap(baseCF, x, z, capW, (r + c) % 5 == 0, capColor(r, c))
				end
			end
		end
	end

	local body: BasePart
	if style == "split" then
		-- Invisible full-size root keeps the pivot centred between the two
		-- visible angled halves.
		body = newPart("Part", Vector3.new(bodyW, bodyH, bodyD), CFrame.new(), look.bodyColor)
		body.Transparency = 1
		local halfW = (bodyW - 0.3) / 2
		local halfCols = math.max(2, math.floor(cols / 2))
		for side = -1, 1, 2 do
			local halfCF = off(side * (halfW / 2 + 0.15), 0, 0) * CFrame.Angles(0, -side * math.rad(9), 0)
			local half = newPart("Part", Vector3.new(halfW, bodyH, bodyD), halfCF, look.bodyColor)
			half.Name = "BodyHalf"
			placeGrid(halfCF, halfW - 0.35, halfCols)
			-- Per-half thumb bar on the spacebar row.
			placeCap(halfCF, 0, -areaD / 2 + rowPitch * 0.5, 0.7, true)
		end
	else
		body = newPart("Part", Vector3.new(bodyW, bodyH, bodyD), CFrame.new(), look.bodyColor)
		if style == "crystal" then
			body.Transparency = 0.35
		end
		local areaW = bodyW - bezel * 2

		-- Dark switch plate under the caps sells keycap depth at a glance.
		local plateColor = look.bodyColor:Lerp(Color3.new(0, 0, 0), 0.45)
		local plate = newPart("Part", Vector3.new(areaW + 0.06, 0.03, areaD + 0.06), off(0, bodyH / 2 + 0.015, 0), plateColor)
		plate.Name = "SwitchPlate"

		placeGrid(CFrame.new(), areaW, cols)
		-- Spacebar + two flanking accent keys on the front row.
		local spaceZ = -areaD / 2 + rowPitch * 0.5
		placeCap(CFrame.new(), 0, spaceZ, areaW * 0.42, false)
		placeCap(CFrame.new(), -areaW * 0.36, spaceZ, areaW * 0.13, true)
		placeCap(CFrame.new(), areaW * 0.36, spaceZ, areaW * 0.13, true)
	end
	body.Name = "Body"
	model.PrimaryPart = body

	-- ===== Detail pass (skipped on tiny builds to protect the part budget) =====
	if not smallBuild then
		-- Coiled cable stub out the back.
		local cableColor = Color3.fromRGB(45, 45, 52)
		local cable = newPart("Part", Vector3.new(0.12, 0.12, 0.5), off(bodyW * 0.3, 0, bodyD / 2 + 0.24), cableColor)
		cable.Name = "Cable"
		local plug = newPart("Part", Vector3.new(0.24, 0.24, 0.24), off(bodyW * 0.3, 0.05, bodyD / 2 + 0.5), cableColor)
		plug.Name = "CablePlug"

		-- Flip-out feet lift the rear edge.
		for _, side in { -1, 1 } do
			local foot = newPart("Part", Vector3.new(0.28, 0.14, 0.2), off(side * (bodyW / 2 - 0.4), -bodyH / 2 - 0.07, bodyD / 2 - 0.25), look.accentColor)
			foot.Name = "Foot"
		end

		-- Tiny brand badge on the top-right bezel.
		local badge = newPart("Part", Vector3.new(0.34, 0.02, 0.12), off(bodyW / 2 - 0.35, bodyH / 2 + 0.01, bodyD / 2 - 0.11), look.accentColor)
		badge.Name = "Badge"

		-- RGB light bar along the front bezel on glowing tiers.
		if glow then
			local bar = newPart("Part", Vector3.new(bodyW * 0.8, 0.05, 0.08), off(0, bodyH / 2 + 0.025, -bodyD / 2 + 0.07), look.accentColor)
			bar.Name = "LightBar"
			bar.Material = Enum.Material.Neon
		end

		-- Retro boards get the little power LED.
		if style == "retro" then
			local led = newPart("Part", Vector3.new(0.1, 0.04, 0.1), off(-bodyW / 2 + 0.35, bodyH / 2 + 0.02, bodyD / 2 - 0.11), Color3.fromRGB(255, 70, 70))
			led.Name = "PowerLED"
			led.Material = Enum.Material.Neon
		end
	end

	-- RGB underglow: glowing rarities and crystal boards float on a light rim.
	if (glow and rarity ~= nil) or style == "crystal" then
		local underColor = if glow and rarity ~= nil then rarity.color else look.accentColor
		local underglow = newPart("Part", Vector3.new(bodyW + 0.12, 0.06, bodyD + 0.12), off(0, -bodyH / 2 - 0.02, 0), underColor)
		underglow.Name = "Underglow"
		underglow.Material = Enum.Material.Neon
		underglow.Transparency = 0.25
	end

	if style == "retro" then
		-- Raised rear lip: the classic wedge profile of old boards.
		local riser = newPart(
			"WedgePart",
			Vector3.new(bodyW, 0.3, 0.32),
			off(0, bodyH / 2 + 0.15, bodyD / 2 - 0.16),
			look.bodyColor
		)
		riser.Name = "RetroRiser"
	end

	if glow and rarity ~= nil then
		local light = Instance.new("PointLight")
		light.Color = rarity.color
		light.Brightness = 1.3
		light.Range = math.clamp(4 + 5 * scale, 2, 60)
		light.Parent = body
	end

	-- Mutation pass (MutationDef from Config/Mutations, optional 3rd arg):
	-- tint every part toward the mutation color and tag the model with
	-- attributes the client animates ("Mutation"; "Rainbow" on the body).
	if mutation ~= nil and typeof(mutation) == "table" and typeof(mutation.tint) == "Color3" then
		model:SetAttribute("Mutation", mutation.id)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Color = part.Color:Lerp(mutation.tint, 0.55)
			end
		end
		if mutation.rainbow == true then
			body:SetAttribute("Rainbow", true)
		end
		local mutationLight = Instance.new("PointLight")
		mutationLight.Color = mutation.tint
		mutationLight.Range = math.clamp(4 + 4 * scale, 2, 60)
		mutationLight.Brightness = 1.2
		mutationLight.Parent = body
	end

	return model
end

return KeyboardModel
