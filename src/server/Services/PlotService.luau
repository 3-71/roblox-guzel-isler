--!strict
-- PlotService — one plot slot per player, out of GameConfig.PlotCount.
--
-- Contract (ARCHITECTURE.md):
--   GetPlot(player) -> Model?        -- the player's plot model in Workspace
--   GetPlotOwner(plotModel) -> Player?
--   On profile load: claim the lowest free slot, PlotBuilder.Build(index,
--   player), replay owned pads visually (factory tiers ascending, then
--   conveyors, then everything else in config order), PadService.BindPlot +
--   RefreshPads (owned/locked pads hidden, available visible), then spawn
--   the player at the plot's SpawnPad via player.RespawnLocation.
--   On leave: PlotBuilder.Destroy + free the slot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local GameConfig = require(Shared.Config.GameConfig)
local Pads = require(Shared.Config.Pads)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local PadService = require(script.Parent.PadService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)

local PlotService = {}

-- Visual-only: how high above the SpawnPad an existing character is placed.
local SPAWN_HEIGHT_OFFSET = 4

local playerToPlot: { [Player]: Model } = {}
local plotToPlayer: { [Model]: Player } = {}
local playerToIndex: { [Player]: number } = {}
local indexUsed: { [number]: boolean } = {}

local function claimLowestFreeIndex(): number?
	for index = 1, GameConfig.PlotCount do
		if not indexUsed[index] then
			indexUsed[index] = true
			return index
		end
	end
	return nil
end

-- Owned pad ids in deterministic replay order: factory tiers first (the
-- Pads config lists them ascending), then conveyors, then the rest in
-- config order — so factory recolors/extensions land before lane reveals.
local function ownedPadsInReplayOrder(profile: Types.Profile): { string }
	local ordered: { string } = {}
	local function collect(predicate: (kind: string) -> boolean)
		for _, pad in Pads do
			if profile.pads[pad.id] and predicate(pad.kind) then
				table.insert(ordered, pad.id)
			end
		end
	end
	collect(function(kind)
		return kind == "factoryTier"
	end)
	collect(function(kind)
		return kind == "conveyor"
	end)
	collect(function(kind)
		return kind ~= "factoryTier" and kind ~= "conveyor"
	end)
	return ordered
end

local function spawnAtPlot(player: Player, plot: Model)
	local spawnPad = plot:FindFirstChild("SpawnPad")
	if spawnPad == nil or not spawnPad:IsA("SpawnLocation") then
		warn(`[PlotService] Plot for {player.Name} has no SpawnPad SpawnLocation`)
		return
	end
	player.RespawnLocation = spawnPad

	local character = player.Character
	if character ~= nil and character.Parent ~= nil then
		-- Character already spawned (hub / default spawn): just move it over.
		local ok, err = pcall(function()
			character:PivotTo(spawnPad.CFrame + Vector3.new(0, SPAWN_HEIGHT_OFFSET, 0))
		end)
		if not ok then
			warn(`[PlotService] Failed to move {player.Name} to their plot: {err}`)
		end
	else
		-- No character yet: spawn one now that RespawnLocation points home.
		task.spawn(function()
			if player.Parent ~= nil and playerToPlot[player] == plot then
				pcall(function()
					player:LoadCharacter()
				end)
			end
		end)
	end
end

local function setupPlot(player: Player, profile: Types.Profile)
	if playerToPlot[player] ~= nil then
		return -- OnProfileLoaded replay safety: never build twice
	end
	if player.Parent == nil then
		return -- left while the profile was loading
	end

	local index = claimLowestFreeIndex()
	if index == nil then
		-- Over-cap player (config drift or teleport burst): they recover when
		-- a plot frees up — teardownPlot retries waiting players.
		warn(`[PlotService] No free plot slot for {player.Name}`)
		Remotes.Notify:FireClient(player, "info", "All plots are full — you'll get one as soon as a spot opens!")
		return
	end

	local ok, plot = pcall(PlotBuilder.Build, index, player)
	if not ok or typeof(plot) ~= "Instance" or not plot:IsA("Model") then
		indexUsed[index] = nil
		warn(`[PlotService] PlotBuilder.Build failed for {player.Name}: {plot}`)
		return
	end
	if player.Parent == nil then
		indexUsed[index] = nil
		pcall(PlotBuilder.Destroy, plot)
		return -- left during the build
	end

	playerToPlot[player] = plot
	plotToPlayer[plot] = player
	playerToIndex[player] = index

	-- Replay the profile's existing progress visually. One bad pad must not
	-- block the rest of the plot (or the spawn), hence per-pad pcall.
	for _, padId in ownedPadsInReplayOrder(profile) do
		local applyOk, applyErr = pcall(PlotBuilder.OnPadPurchased, plot, padId)
		if not applyOk then
			warn(`[PlotService] OnPadPurchased replay failed for "{padId}": {applyErr}`)
		end
	end

	-- Wire touch-to-buy once, then let PadService apply the prereq graph:
	-- owned pads hidden, available visible, locked invisible.
	PadService.BindPlot(player, plot)
	PadService.RefreshPads(player)

	spawnAtPlot(player, plot)
end

-- Tears down and rebuilds the player's plot on the SAME slot, replaying the
-- profile's current pad ownership. Used after a rebirth resets progress:
-- the fresh build restores tier-1 factory visuals, hides conveyors 2-4, and
-- keeps whatever the profile still owns (display stands). In-flight belt
-- items and displayed models die with the old plot; production loops and
-- ShowcaseService re-resolve the new plot on their own.
function PlotService.RebuildForProfile(player: Player)
	local profile = DataService.GetProfile(player)
	local oldPlot = playerToPlot[player]
	local index = playerToIndex[player]
	if profile == nil or oldPlot == nil or index == nil then
		return
	end

	playerToPlot[player] = nil
	plotToPlayer[oldPlot] = nil
	pcall(PlotBuilder.Destroy, oldPlot)

	local ok, plot = pcall(PlotBuilder.Build, index, player)
	if not ok or typeof(plot) ~= "Instance" or not plot:IsA("Model") then
		warn(`[PlotService] Rebuild failed for {player.Name}: {plot}`)
		return
	end
	playerToPlot[player] = plot
	plotToPlayer[plot] = player

	for _, padId in ownedPadsInReplayOrder(profile) do
		local applyOk, applyErr = pcall(PlotBuilder.OnPadPurchased, plot, padId)
		if not applyOk then
			warn(`[PlotService] OnPadPurchased rebuild replay failed for "{padId}": {applyErr}`)
		end
	end

	PadService.BindPlot(player, plot)
	PadService.RefreshPads(player)
	spawnAtPlot(player, plot)
end

local function teardownPlot(player: Player)
	local plot = playerToPlot[player]
	if plot == nil then
		return
	end
	playerToPlot[player] = nil
	plotToPlayer[plot] = nil
	local index = playerToIndex[player]
	playerToIndex[player] = nil
	if index ~= nil then
		indexUsed[index] = nil
	end
	pcall(PlotBuilder.Destroy, plot)

	-- Self-heal: hand the freed slot to a loaded player still waiting for one
	-- (a waiter is exactly a loaded profile with no plot). setupPlot's own
	-- guards make a double invocation harmless.
	for _, other in Players:GetPlayers() do
		if other ~= player and playerToPlot[other] == nil then
			local profile = DataService.GetProfile(other)
			if profile ~= nil then
				task.spawn(setupPlot, other, profile)
				break
			end
		end
	end
end

-- ===== Public API =====

function PlotService.GetPlot(player: Player): Model?
	return playerToPlot[player]
end

function PlotService.GetPlotOwner(plotModel: Model): Player?
	return plotToPlayer[plotModel]
end

-- ===== Lifecycle =====

function PlotService.Init()
	-- Dependencies are wired via the module requires above.
end

function PlotService.Start()
	DataService.OnProfileLoaded(function(player, profile)
		setupPlot(player, profile)
	end)

	Players.PlayerRemoving:Connect(teardownPlot)
end

return PlotService
