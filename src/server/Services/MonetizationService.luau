--!strict
-- MonetizationService — gamepasses and developer products (Config/Products).
--
-- Gamepasses: on profile load, each configured pass (id ~= 0) is checked via
-- UserOwnsGamePassAsync and cached into profile.passes[key]. A persisted true
-- is never clobbered by a failed/negative check — passes only ever turn on.
-- PromptGamePassPurchaseFinished flips the pass immediately on in-game buys.
-- Pass EFFECTS are consumed elsewhere (doubleLuck in RollLogic.GetEffectiveLuck,
-- doubleStorage in OfflineService, extraStands in ShowcaseService, vip in
-- InventoryService/PlotBuilder).
--
-- Dev products: MarketplaceService.ProcessReceipt grants cash
-- (EconomyService.AddMoney) or timed boosts (profile.boosts[key] = expiry,
-- consumed by RollLogic.GetEffectiveLuck). The Luck Party product also gives
-- every online player a short serverLuckParty boost. Receipts are idempotent
-- within this server via an in-memory PurchaseId set; any grant failure
-- returns NotProcessedYet so Roblox retries later.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Products = require(Shared.Config.Products)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local MonetizationService = {}

-- How long everyone else's boost lasts when someone starts a Luck Party.
-- (The buyer's own longer boost uses the product's `duration` field.)
local SERVER_LUCK_PARTY_SECONDS = 300

-- Lookups by Roblox id; unconfigured entries (id == 0) never resolve.
local passById: { [number]: Products.GamePassDef } = {}
for _, def in Products.GamePasses do
	if def.id ~= 0 then
		passById[def.id] = def
	end
end

local productById: { [number]: Products.DevProductDef } = {}
for _, def in Products.DevProducts do
	if def.id ~= 0 then
		productById[def.id] = def
	end
end

-- PurchaseIds already granted this server session (idempotency: Roblox may
-- call ProcessReceipt again for the same receipt after a slow response).
local processedPurchases: { [string]: boolean } = {}

-- ===== Gamepasses =====

-- Checks ownership of every configured pass and caches positives on the
-- profile. Yields (web call), so callers must task.spawn it.
local function refreshPassOwnership(player: Player, profile: Types.Profile)
	local changed = false
	for _, def in Products.GamePasses do
		-- Already known owned (this session or persisted): nothing to check,
		-- and a failed pcall must never turn a true back off.
		if def.id ~= 0 and profile.passes[def.key] ~= true then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
			end)
			if ok and owns == true then
				profile.passes[def.key] = true
				changed = true
			elseif not ok then
				warn(`[MonetizationService] UserOwnsGamePassAsync failed for {player.Name} / {def.key}: {owns}`)
			end
		end
	end
	if changed and DataService.GetProfile(player) == profile then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
end

local function onGamePassPurchaseFinished(player: Player, gamePassId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	local def = passById[gamePassId]
	if def == nil then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if profile.passes[def.key] ~= true then
		profile.passes[def.key] = true
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
	Remotes.Notify:FireClient(player, "info", `Thanks for buying {def.name}!`)
end

-- ===== Developer products =====

-- Applies a product's effect to the buyer. No yields — the profile cannot
-- change out from under us between validation and grant.
local function applyProductEffect(buyer: Player, profile: Types.Profile, def: Products.DevProductDef)
	local now = os.time()

	local cash = def.cash
	if cash ~= nil and cash > 0 then
		EconomyService.AddMoney(buyer, cash)
	end

	local luckBonus = def.luckBonus
	local duration = def.duration
	if luckBonus ~= nil and duration ~= nil then
		profile.boosts[def.key] = now + duration
	end

	local serverLuckBonus = def.serverLuckBonus
	if serverLuckBonus ~= nil then
		-- Luck Party: everyone online (buyer included) gets the server boost.
		for _, other in Players:GetPlayers() do
			local otherProfile = DataService.GetProfile(other)
			if otherProfile ~= nil then
				otherProfile.boosts.serverLuckParty = now + SERVER_LUCK_PARTY_SECONDS
				DataService.MarkDirty(other)
				DataService.Sync(other)
			end
		end
		Remotes.Notify:FireAllClients("flex", `{buyer.Name} started a LUCK PARTY! +{serverLuckBonus} luck for everyone!`)
	end
end

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	if typeof(receiptInfo) ~= "table" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)
	if processedPurchases[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Buyer must be in THIS server with a loaded profile; otherwise let
	-- Roblox retry the receipt (on their next join, possibly elsewhere).
	local buyer = if typeof(receiptInfo.PlayerId) == "number"
		then Players:GetPlayerByUserId(receiptInfo.PlayerId)
		else nil
	if buyer == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = DataService.GetProfile(buyer)
	if profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local def = productById[receiptInfo.ProductId]
	if def == nil then
		-- Unknown/unconfigured product: nothing to grant, but returning
		-- NotProcessedYet forever would put the receipt in a retry loop.
		warn(`[MonetizationService] Receipt for unknown product id {receiptInfo.ProductId}; granting nothing`)
		processedPurchases[purchaseId] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local ok, err = pcall(applyProductEffect, buyer, profile, def)
	if not ok then
		warn(`[MonetizationService] Failed to grant {def.key} to {buyer.Name}: {err}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	processedPurchases[purchaseId] = true
	DataService.MarkDirty(buyer)
	DataService.Sync(buyer)
	Remotes.Notify:FireClient(buyer, "info", `Thanks for buying {def.name}!`)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ===== Lifecycle =====

function MonetizationService.Init()
	-- Dependencies are wired via the module requires above.
end

function MonetizationService.Start()
	DataService.OnProfileLoaded(function(player, profile)
		-- UserOwnsGamePassAsync yields; never block the load pipeline.
		task.spawn(refreshPassOwnership, player, profile)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
		onGamePassPurchaseFinished(player, gamePassId, wasPurchased)
	end)

	MarketplaceService.ProcessReceipt = processReceipt
end

return MonetizationService
