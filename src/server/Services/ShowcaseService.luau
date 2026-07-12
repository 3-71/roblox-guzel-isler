--!strict
-- Showcase: display stands at the front of each plot. Owners put keyboards
-- on stands via DisplayRequest; visitors can look (nameplate + model) but
-- deliberately cannot interact — flexing only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local PlotService = require(script.Parent.PlotService)
local KeyboardModel = require(Shared.World.KeyboardModel)

local ShowcaseService = {}

-- player -> standIndex -> displayed model
local displayedModels: { [Player]: { [number]: Model } } = {}

local function getStandAnchor(plot: Model, standIndex: number): Attachment?
	local stand = plot:FindFirstChild("DisplayStand" .. tostring(standIndex))
	if not stand then
		return nil
	end
	local anchor = stand:FindFirstChild("ItemAnchor", true)
	return if anchor and anchor:IsA("Attachment") then anchor else nil
end

local function clearStandVisual(player: Player, standIndex: number)
	local models = displayedModels[player]
	if models and models[standIndex] then
		models[standIndex]:Destroy()
		models[standIndex] = nil
	end
end

local function renderStand(player: Player, profile: Types.Profile, standIndex: number)
	clearStandVisual(player, standIndex)

	local uid = profile.displayed[tostring(standIndex)]
	if not uid then
		return
	end
	-- skip dangling references (keyboard sold/traded away)
	local instance = InventoryService.GetKeyboard(player, uid)
	if not instance then
		profile.displayed[tostring(standIndex)] = nil
		return
	end
	local def = Catalog.GetKeyboard(instance.id)
	if not def then
		return
	end
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end
	local anchor = getStandAnchor(plot, standIndex)
	if not anchor then
		return
	end

	local mutationDef = Catalog.GetMutation(instance.mutation)
	local ok, model = pcall(KeyboardModel.Build, def :: any, 0.7, mutationDef)
	if not ok or typeof(model) ~= "Instance" then
		return
	end
	-- tilted toward visitors for style
	model:PivotTo(anchor.WorldCFrame * CFrame.new(0, 0.4, 0) * CFrame.Angles(math.rad(-30), math.rad(180), 0))

	local rarity = Catalog.GetRarity(def.rarityTier)
	local primary = model.PrimaryPart
	if primary and rarity then
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(160, 54)
		gui.StudsOffset = Vector3.new(0, 2.2, 0)
		gui.MaxDistance = 45
		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.fromScale(1, 0.6)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.FredokaOne
		nameLabel.TextScaled = true
		nameLabel.TextColor3 = rarity.color
		nameLabel.TextStrokeTransparency = 0.3
		nameLabel.Text = def.name
		nameLabel.Parent = gui
		local rarityLabel = Instance.new("TextLabel")
		rarityLabel.Position = UDim2.fromScale(0, 0.6)
		rarityLabel.Size = UDim2.fromScale(1, 0.4)
		rarityLabel.BackgroundTransparency = 1
		rarityLabel.Font = Enum.Font.GothamBold
		rarityLabel.TextScaled = true
		rarityLabel.TextColor3 = rarity.color
		rarityLabel.TextTransparency = 0.15
		rarityLabel.TextStrokeTransparency = 0.5
		rarityLabel.Text = rarity.name
		rarityLabel.Parent = gui
		gui.Parent = primary
	end

	model.Parent = plot
	displayedModels[player] = displayedModels[player] or {}
	displayedModels[player][standIndex] = model
end

function ShowcaseService.RenderAll(player: Player)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	for standIndex = 1, GameConfig.MaxDisplayStands do
		renderStand(player, profile, standIndex)
	end
end

-- token bucket per player for DisplayRequest (model builds + full syncs are
-- too heavy to run at remote-spam speed)
local displayTokens: { [Player]: { tokens: number, last: number } } = {}

local function takeDisplayToken(player: Player): boolean
	local bucket = displayTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 3, last = now }
		displayTokens[player] = bucket
	end
	bucket.tokens = math.min(3, bucket.tokens + (now - bucket.last) * GameConfig.DisplayRateLimitPerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function onDisplayRequest(player: Player, standIndex: unknown, uid: unknown)
	if not takeDisplayToken(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	if typeof(standIndex) ~= "number" or standIndex ~= math.floor(standIndex) then
		return
	end
	if standIndex < 1 or standIndex > GameConfig.MaxDisplayStands then
		return
	end
	-- extraStands gamepass: +2 stands beyond the pad-purchased count, clamped
	-- to the plot's physical maximum.
	local bonusStands = if profile.passes.extraStands then 2 else 0
	local unlockedStands = math.min(profile.upgrades.displays + bonusStands, GameConfig.MaxDisplayStands)
	if unlockedStands < standIndex then
		Remotes.Notify:FireClient(player, "error", "That display stand is locked — buy its pad first!")
		return
	end

	if uid == nil then
		profile.displayed[tostring(standIndex)] = nil
	else
		if typeof(uid) ~= "string" then
			return
		end
		local instance = InventoryService.GetKeyboard(player, uid)
		if not instance then
			return
		end
		if profile.equippedUid == uid then
			Remotes.Notify:FireClient(player, "error", "Unequip that keyboard before displaying it.")
			return
		end
		-- if already on another stand, move it (clear the old stand first)
		for otherIndex, displayedUid in profile.displayed do
			if displayedUid == uid and otherIndex ~= tostring(standIndex) then
				profile.displayed[otherIndex] = nil
				local otherNumber = tonumber(otherIndex)
				if otherNumber then
					renderStand(player, profile, otherNumber)
				end
			end
		end
		profile.displayed[tostring(standIndex)] = uid
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
	renderStand(player, profile, standIndex)
end

function ShowcaseService.Init() end

function ShowcaseService.Start()
	Remotes.DisplayRequest.OnServerEvent:Connect(onDisplayRequest)

	-- Render persisted displays once the plot exists (plot builds on the same
	-- OnProfileLoaded event; poll briefly rather than racing it).
	DataService.OnProfileLoaded(function(player, _profile)
		task.spawn(function()
			local deadline = os.clock() + 15
			while os.clock() < deadline and player.Parent do
				if PlotService.GetPlot(player) then
					ShowcaseService.RenderAll(player)
					return
				end
				task.wait(0.5)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- models live under the plot (destroyed with it); just drop references
		displayedModels[player] = nil
		displayTokens[player] = nil
	end)
end

return ShowcaseService
