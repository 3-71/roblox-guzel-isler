--!strict
-- World-space eye candy, all local to this client: collect particles at the
-- belt end, sky beams for big rolls on your plot, and ambient sparkle on
-- high-tier keyboards displayed anywhere in the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("GameConfig"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local EffectsController = {}

local localPlayer = Players.LocalPlayer

local SPARKLE_MIN_TIER = 9
local sparkled: { [Instance]: ParticleEmitter } = {}

local function getOwnPlot(): Model?
	local plots = workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, plot in plots:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == localPlayer.UserId then
			return plot
		end
	end
	return nil
end

local function getBeltEndPosition(): Vector3?
	local plot = getOwnPlot()
	if not plot then
		return nil
	end
	local conveyor = plot:FindFirstChild("Conveyor1")
	local belt = conveyor and conveyor:FindFirstChild("Belt")
	local beltEnd = belt and belt:FindFirstChild("BeltEnd")
	if beltEnd and beltEnd:IsA("Attachment") then
		return beltEnd.WorldPosition
	end
	return nil
end

local function collectBurst(position: Vector3, color: Color3, big: boolean)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.Position = position
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Lifetime = NumberRange.new(0.3, 0.8)
	emitter.Speed = NumberRange.new(6, if big then 22 else 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(if big then 0.9 else 0.5, 0)
	emitter.LightEmission = 0.6
	emitter.Enabled = false
	emitter.Parent = holder
	holder.Parent = workspace
	emitter:Emit(if big then 40 else 14)
	Debris:AddItem(holder, 1.5)
end

local function skyBeam(position: Vector3, color: Color3)
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanTouch = false
	beam.CanQuery = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Transparency = 0.2
	beam.Size = Vector3.new(4, 120, 4)
	beam.Position = position + Vector3.new(0, 60, 0)
	beam.Parent = workspace
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 30
	light.Brightness = 3
	light.Parent = beam
	TweenService:Create(beam, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.5, 120, 0.5),
	}):Play()
	TweenService:Create(light, TweenInfo.new(2), { Brightness = 0 }):Play()
	Debris:AddItem(beam, 2.2)
end

local function sparkleLoop()
	while true do
		task.wait(5)
		local plots = workspace:FindFirstChild("Plots")
		if plots then
			pcall(function()
				-- clean up emitters whose model vanished
				for model, emitter in sparkled do
					if not model.Parent then
						sparkled[model] = nil
					end
				end
				for _, plot in plots:GetChildren() do
					for _, child in plot:GetChildren() do
						local isDisplayed = child:IsA("Model")
							and child.Parent == plot
							and string.find(child.Name, "Keyboard_") == 1
						if isDisplayed and not sparkled[child] then
							local tier = child:GetAttribute("RarityTier")
							local primary = (child :: Model).PrimaryPart
							if typeof(tier) == "number" and tier >= SPARKLE_MIN_TIER and primary then
								local rarity = Catalog.GetRarity(tier)
								local emitter = Instance.new("ParticleEmitter")
								emitter.Color = ColorSequence.new(if rarity then rarity.color else Color3.new(1, 1, 1))
								emitter.Rate = 3
								emitter.Lifetime = NumberRange.new(0.6, 1.2)
								emitter.Speed = NumberRange.new(0.5, 1.5)
								emitter.Size = NumberSequence.new(0.35, 0)
								emitter.LightEmission = 1
								emitter.Parent = primary
								sparkled[child] = emitter
							end
						end
					end
				end
			end)
		end
	end
end

-- Mutation animations: hue-cycle any part tagged Rainbow=true (holo/glitched
-- keyboards), and flicker parts of models tagged Mutation="glitched".
local function mutationAnimatorLoop()
	local rainbowParts: { [BasePart]: boolean } = {}
	local glitchModels: { [Model]: boolean } = {}
	local lastScan = 0
	local hue = 0
	while true do
		task.wait(0.1)
		hue = (hue + 0.02) % 1

		if os.clock() - lastScan > 3 then
			lastScan = os.clock()
			pcall(function()
				table.clear(rainbowParts)
				table.clear(glitchModels)
				local function scan(root: Instance)
					for _, inst in root:GetDescendants() do
						if inst:IsA("BasePart") and inst:GetAttribute("Rainbow") == true then
							rainbowParts[inst] = true
						elseif inst:IsA("Model") and inst:GetAttribute("Mutation") == "glitched" then
							glitchModels[inst] = true
						end
					end
				end
				local plots = workspace:FindFirstChild("Plots")
				if plots then
					scan(plots)
				end
				for _, player in Players:GetPlayers() do
					if player.Character then
						scan(player.Character)
					end
				end
			end)
		end

		for part in rainbowParts do
			if part.Parent then
				part.Color = Color3.fromHSV(hue, 0.65, 1)
			else
				rainbowParts[part] = nil
			end
		end
		for model in glitchModels do
			if model.Parent then
				if math.random() < 0.06 then
					local parts = model:GetChildren()
					local pick = parts[math.random(1, #parts)]
					if pick and pick:IsA("BasePart") then
						local original = pick.Transparency
						pick.Transparency = 0.8
						task.delay(0.07, function()
							if pick.Parent then
								pick.Transparency = original
							end
						end)
					end
				end
			else
				glitchModels[model] = nil
			end
		end
	end
end

function EffectsController.Start()
	Remotes.KeyboardCollected.OnClientEvent:Connect(function(payload: Types.CollectedPayload)
		local position = getBeltEndPosition()
		if not position then
			return
		end
		local rarity = Catalog.GetRarity(payload.rarityTier)
		local color = if rarity then rarity.color else Color3.new(1, 1, 1)
		local big = payload.rarityTier >= GameConfig.CelebrateMinTier
		collectBurst(position, color, big)
		if big then
			skyBeam(position, color)
		end
	end)

	task.spawn(sparkleLoop)
	task.spawn(mutationAnimatorLoop)
end

return EffectsController
