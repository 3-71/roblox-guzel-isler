--!strict
-- RebirthService — the prestige loop. Reaching factory tier 12 unlocks the
-- rebirth altar pad: pay the (escalating) cost to reset money, factory and
-- most pads in exchange for a permanent sell-value multiplier and bonus luck
-- (both applied automatically via Catalog.GetSellValue / RollLogic.GetEffectiveLuck).
-- Keyboards, collection, displays, index claims, passes and boosts are KEPT.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Pads = require(Shared.Config.Pads)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local PadService = require(script.Parent.PadService)
local PlotService = require(script.Parent.PlotService)
local ShowcaseService = require(script.Parent.ShowcaseService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)

local RebirthService = {}

local debounce: { [Player]: number } = {}

function RebirthService.GetCost(rebirths: number): number
	return math.floor(GameConfig.Rebirth.BaseCost * GameConfig.Rebirth.CostMult ^ math.max(rebirths, 0))
end

local function updatePadLabel(player: Player)
	local profile = DataService.GetProfile(player)
	local plot = PlotService.GetPlot(player)
	if profile == nil or plot == nil then
		return
	end
	pcall(PlotBuilder.SetPadLabel, plot, "rebirth", "$" .. EconomyService.Abbreviate(RebirthService.GetCost(profile.rebirths)))
end

local function tryRebirth(player: Player)
	local now = os.clock()
	if debounce[player] ~= nil and now - debounce[player] < 1 then
		return
	end
	debounce[player] = now

	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if profile.upgrades.factoryTier < GameConfig.Rebirth.RequiredFactoryTier then
		Remotes.Notify:FireClient(player, "error", `Reach Factory Tier {GameConfig.Rebirth.RequiredFactoryTier} to rebirth!`)
		return
	end

	local cost = RebirthService.GetCost(profile.rebirths)
	if not EconomyService.SpendMoney(player, cost) then
		Remotes.Notify:FireClient(player, "error", `Rebirth costs ${EconomyService.Abbreviate(cost)}!`)
		return
	end

	profile.rebirths += 1
	profile.money = 0
	EconomyService.RefreshLeaderstats(player)

	-- Reset progression; keep the showcase (display stands + displayed boards).
	profile.upgrades.factoryTier = 1
	profile.upgrades.conveyors = 1
	profile.upgrades.speed = 0
	profile.upgrades.luck = 0
	profile.upgrades.storage = 0

	-- Displays AND walls survive rebirth: both are prestige purchases the
	-- player shows off, not progression to grind back.
	local keptPads: { [string]: boolean } = {}
	for _, pad in Pads do
		if (pad.kind == "display" or pad.kind == "walls") and profile.pads[pad.id] then
			keptPads[pad.id] = true
		end
	end
	profile.pads = keptPads

	DataService.MarkDirty(player)
	DataService.Sync(player)

	PlotService.RebuildForProfile(player)
	ShowcaseService.RenderAll(player)
	updatePadLabel(player)

	local bonusPercent = math.floor(profile.rebirths * GameConfig.Rebirth.ValueBonusPerRebirth * 100)
	Remotes.Notify:FireAllClients(
		"flex",
		`⟳ {player.Name} reached REBIRTH {profile.rebirths}! Their factory grew a new floor and their keyboards sell for +{bonusPercent}% forever.`
	)
end

function RebirthService.Init()
	PadService.SetRebirthHandler(tryRebirth)
end

function RebirthService.Start()
	Remotes.RebirthRequest.OnServerEvent:Connect(tryRebirth)

	-- Keep the altar's price label current for each player's own plot.
	DataService.OnProfileLoaded(function(player, _profile)
		task.spawn(function()
			local deadline = os.clock() + 15
			while os.clock() < deadline and player.Parent do
				if PlotService.GetPlot(player) ~= nil then
					updatePadLabel(player)
					return
				end
				task.wait(0.5)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		debounce[player] = nil
	end)
end

return RebirthService
