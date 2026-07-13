--!strict
-- Grow a Keyboard — server bootstrap.
-- Builds the world, then Init()s every service synchronously (dependency
-- wiring, no yielding), then Start()s them (loops / player handling).
-- Order matters and is part of the architecture contract.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Creating remotes first so clients can WaitForChild safely.
require(ReplicatedStorage.Shared.Remotes)

local HubBuilder = require(script.World.HubBuilder)
HubBuilder.Build()

local Services = script.Services
local serviceModules = {
	require(Services.DataService),
	require(Services.PlotService),
	require(Services.PadService),
	require(Services.ProductionService),
	require(Services.InventoryService),
	require(Services.EconomyService),
	require(Services.ShowcaseService),
	require(Services.EquipService),
	require(Services.OfflineService),
	-- phase 2
	require(Services.EventService),
	require(Services.IndexService),
	require(Services.RebirthService),
	require(Services.MonetizationService),
	require(Services.LeaderboardService),
	require(Services.LikeService),
	require(Services.TypingRaceService),
	-- phase 3
	require(Services.RestockShopService),
	require(Services.GiftService),
	require(Services.StreakService),
	-- phase 4
	require(Services.SecretService),
	require(Services.SetsService),
	require(Services.FusionService),
}

for _, service in serviceModules do
	service.Init()
end

for _, service in serviceModules do
	service.Start()
end

print("[GrowAKeyboard] Server started —", #serviceModules, "services running")
