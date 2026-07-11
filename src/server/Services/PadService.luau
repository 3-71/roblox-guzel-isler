--!strict
-- PadService — buy-pad visibility + touch-to-buy purchases.
--
-- Contract (ARCHITECTURE.md + build notes):
--   BindPlot(player, plot) -- called by PlotService right after
--     PlotBuilder.Build; wires Touched ONCE on every pad's "Pad" part and
--     remembers player -> plot so RefreshPads works without PlotService
--     (requiring PlotService here would create a require cycle: PlotService
--     requires PadService).
--   RefreshPads(player) -- for every pad in Config/Pads: owned -> hidden,
--     prereq not owned -> hidden, otherwise visible (PlotBuilder.SetPadVisible).
--
-- Touch purchase flow: toucher must be the plot owner; 0.5s debounce per
-- player+pad; pad not already owned; prereq owned; cost from
-- Catalog.GetPadCost; EconomyService.SpendMoney. On success:
-- profile.pads[id] = true, upgrades field raised via math.max,
-- PlotBuilder.OnPadPurchased, RefreshPads, MarkDirty + Sync, info toast.
-- Insufficient funds -> error toast throttled to once per 2s per player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local Pads = require(Shared.Config.Pads)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)

type PadDef = Pads.PadDef

local PadService = {}

local TOUCH_DEBOUNCE_SECONDS = 0.5 -- contract: per player+pad
local ERROR_THROTTLE_SECONDS = 2 -- "not enough money" toast, per player

-- pad.kind -> the profile.upgrades field it raises (always math.max'd with
-- the current value, so out-of-order data can never downgrade a player).
local FIELD_FOR_KIND: { [string]: string } = {
	factoryTier = "factoryTier",
	conveyor = "conveyors",
	speed = "speed",
	luck = "luck",
	storage = "storage",
	display = "displays",
}

local boundPlots: { [Player]: Model } = {}
local touchDebounce: { [Player]: { [string]: number } } = {}
local lastErrorAt: { [Player]: number } = {}

-- Maps a touching part back to a Player. hit.Parent is the character for
-- limbs; accessories/tools are one level deeper, so walk up until we find
-- a character model (bounded by the shallow character hierarchy).
local function resolveToucher(hit: BasePart): Player?
	local candidate: Instance? = hit.Parent
	while candidate ~= nil and candidate ~= game do
		if candidate:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(candidate)
			if player ~= nil then
				return player
			end
		end
		candidate = candidate.Parent
	end
	return nil
end

function PadService.RefreshPads(player: Player)
	local plot = boundPlots[player]
	if plot == nil or plot.Parent == nil then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	for _, pad in Pads do
		local visible: boolean
		if profile.pads[pad.id] then
			visible = false -- owned pads disappear
		elseif pad.prereq ~= nil and not profile.pads[pad.prereq] then
			visible = false -- locked behind an unowned prereq
		else
			visible = true -- available for purchase
		end
		local ok, err = pcall(PlotBuilder.SetPadVisible, plot, pad.id, visible)
		if not ok then
			warn(`[PadService] SetPadVisible failed for "{pad.id}": {err}`)
		end
	end
end

local function onPadTouched(owner: Player, plot: Model, pad: PadDef, hit: BasePart)
	if boundPlots[owner] ~= plot then
		return -- plot torn down or rebound since this connection was made
	end
	local toucher = resolveToucher(hit)
	if toucher == nil or toucher ~= owner then
		return -- only the plot owner can buy their own pads
	end

	local now = os.clock()
	local debounces = touchDebounce[owner]
	if debounces == nil then
		debounces = {}
		touchDebounce[owner] = debounces
	end
	local lastTouch = debounces[pad.id]
	if lastTouch ~= nil and now - lastTouch < TOUCH_DEBOUNCE_SECONDS then
		return
	end
	debounces[pad.id] = now

	local profile = DataService.GetProfile(owner)
	if profile == nil then
		return
	end
	if profile.pads[pad.id] then
		return -- already owned
	end
	if pad.prereq ~= nil and not profile.pads[pad.prereq] then
		return -- prereq chain not satisfied (pad should be hidden anyway)
	end

	local cost = Catalog.GetPadCost(pad.id)
	if cost == nil then
		warn(`[PadService] No resolvable cost for pad "{pad.id}"`)
		return
	end

	if not EconomyService.SpendMoney(owner, cost) then
		local lastError = lastErrorAt[owner]
		if lastError == nil or now - lastError >= ERROR_THROTTLE_SECONDS then
			lastErrorAt[owner] = now
			Remotes.Notify:FireClient(
				owner,
				"error",
				`Not enough money! {pad.name} costs ${EconomyService.Abbreviate(cost)}.`
			)
		end
		return
	end

	profile.pads[pad.id] = true
	local field = FIELD_FOR_KIND[pad.kind]
	if field ~= nil then
		-- Dynamic field write into the strictly-typed Upgrades table.
		local upgrades = profile.upgrades :: any
		local current = upgrades[field]
		upgrades[field] = math.max(if typeof(current) == "number" then current else 0, pad.level)
	else
		warn(`[PadService] Pad "{pad.id}" has unknown kind "{pad.kind}"`)
	end

	local ok, err = pcall(PlotBuilder.OnPadPurchased, plot, pad.id)
	if not ok then
		warn(`[PadService] OnPadPurchased failed for "{pad.id}": {err}`)
	end
	PadService.RefreshPads(owner)

	DataService.MarkDirty(owner)
	DataService.Sync(owner)
	Remotes.Notify:FireClient(owner, "info", "Bought " .. pad.name .. "!")
end

-- Wires Touched on every pad of a freshly built plot. Call exactly once per
-- build (PlotService does); connections die with the plot on Destroy.
function PadService.BindPlot(player: Player, plot: Model)
	if boundPlots[player] == plot then
		return -- already wired (OnProfileLoaded replay safety)
	end
	boundPlots[player] = plot

	local padsFolder = plot:FindFirstChild("Pads")
	if padsFolder == nil then
		warn(`[PadService] Plot for {player.Name} has no Pads folder`)
		return
	end

	for _, pad in Pads do
		local padModel = padsFolder:FindFirstChild(pad.id)
		if padModel == nil then
			warn(`[PadService] Plot for {player.Name} is missing pad "{pad.id}"`)
			continue
		end

		-- The touchable surface is the pad model's "Pad" part (contract);
		-- fall back to the primary/first part if the builder nests differently.
		local touchPart: BasePart? = nil
		local named = padModel:FindFirstChild("Pad", true)
		if named ~= nil and named:IsA("BasePart") then
			touchPart = named
		elseif padModel:IsA("Model") and padModel.PrimaryPart ~= nil then
			touchPart = padModel.PrimaryPart
		else
			local anyPart = padModel:FindFirstChildWhichIsA("BasePart", true)
			if anyPart ~= nil then
				touchPart = anyPart :: BasePart
			end
		end
		if touchPart == nil then
			warn(`[PadService] Pad "{pad.id}" on {player.Name}'s plot has no touchable part`)
			continue
		end

		local padDef = pad
		touchPart.Touched:Connect(function(hit: BasePart)
			onPadTouched(player, plot, padDef, hit)
		end)
	end
end

-- ===== Lifecycle =====

function PadService.Init()
	-- Dependencies are wired via the module requires above.
end

function PadService.Start()
	Players.PlayerRemoving:Connect(function(player)
		boundPlots[player] = nil
		touchDebounce[player] = nil
		lastErrorAt[player] = nil
	end)
end

return PadService
