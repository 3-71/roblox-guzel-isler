--!strict
-- ProductionService — per-player conveyor production loops.
--
-- For every online player with a loaded profile, one loop runs per possible
-- conveyor lane (1..GameConfig.MaxConveyors). Locked lanes idle-poll until
-- the matching conveyor pad is purchased, so pad purchases apply live without
-- any signal from PadService. Each tick rolls a keyboard, rides a model down
-- the lane's belt, then auto-collects via InventoryService.AddKeyboard.
--
-- Effective interval (contract):
--   FactoryTiers[factoryTier].baseInterval * SpeedMultPerLevel ^ speed
-- Lane k's first production is offset by interval * (k-1)/conveyors so a
-- player's lanes don't all pop at the same instant.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local Catalog = require(Shared.Catalog)
local RollLogic = require(Shared.RollLogic)
local GameConfig = require(Shared.Config.GameConfig)
local FactoryTiers = require(Shared.Config.FactoryTiers)
local Keyboards = require(Shared.Config.Keyboards)
local Events = require(Shared.Config.Events)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local PlotService = require(script.Parent.PlotService)
local KeyboardModel = require(Shared.World.KeyboardModel)

local ProductionService = {}

-- One RNG per server, seeded once (contract).
local rng = Random.new()

-- Visual-only constants (balance numbers stay in Config).
local ITEM_SCALE = 0.8 -- belt item scale passed to KeyboardModel.Build
local BELT_HOVER = 0.4 -- studs the item floats above the belt attachments
local BOB_AMPLITUDE = 0.25 -- extra hover bob for glowing rarities
local BOB_SPEED = 6 -- radians/sec of the bob sine
local LOCKED_POLL_SECONDS = 1 -- recheck cadence for still-locked lanes
local MIN_INTERVAL = 0.05 -- safety floor so a bad config can't busy-loop

type PlayerState = {
	alive: boolean, -- flipped false on PlayerRemoving; all loops observe it
	fullNotified: boolean, -- "inventory full" toast sent once per full episode
}

local states: { [Player]: PlayerState } = {}

-- ===== Restock mutation charm (Phase 3) =====
-- RestockShopService.ConsumeCharm(player) returns the charm's mutation-chance
-- multiplier while charmed rolls remain, else nil. The service is required
-- lazily (and under pcall) at call time: it boots after ProductionService in
-- the server bootstrap order, and a top-level require here would create an
-- ordering/cycle hazard. nil / any failure => multiplier 1.

local restockShopService: any = nil

local function consumeCharmMult(player: Player): number
	if restockShopService == nil then
		local ok, service = pcall(function(): any
			local module = script.Parent:FindFirstChild("RestockShopService")
			if module ~= nil and module:IsA("ModuleScript") then
				return require(module) :: any
			end
			return nil
		end)
		if ok and typeof(service) == "table" then
			restockShopService = service
		end
	end
	if restockShopService == nil or typeof(restockShopService.ConsumeCharm) ~= "function" then
		return 1
	end
	local ok, mult = pcall(restockShopService.ConsumeCharm, player)
	if ok and typeof(mult) == "number" then
		return mult
	end
	return 1
end

-- The active server event (from Workspace attributes set by EventService),
-- or nil when none / expired.
local function getActiveEvent(): typeof(Events[1])?
	local id = workspace:GetAttribute("ActiveEventId")
	local expiry = workspace:GetAttribute("ActiveEventUntil")
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	if typeof(expiry) ~= "number" or expiry <= os.time() then
		return nil
	end
	for _, event in Events do
		if event.id == id then
			return event
		end
	end
	return nil
end

-- Effective seconds between productions on ONE conveyor.
local function effectiveInterval(upgrades: Types.Upgrades): number
	local tier = math.clamp(upgrades.factoryTier, 1, #FactoryTiers)
	local interval = FactoryTiers[tier].baseInterval
		* GameConfig.SpeedMultPerLevel ^ math.max(upgrades.speed, 0)
	return math.max(interval, MIN_INTERVAL)
end

-- Rides `model` from beltStart to beltEnd over BeltRideSeconds, then destroys
-- it and collects the keyboard. Runs in its own thread so the production loop
-- keeps ticking while items are still on the belt. The model is parented under
-- the conveyor, so plot teardown destroys it for us mid-ride; every PivotTo is
-- guarded and the model reference is always Destroy()ed at the end (idempotent).
local function rideBelt(
	player: Player,
	model: Model,
	container: Instance,
	beltStart: Attachment,
	beltEnd: Attachment,
	keyboardId: string,
	glow: boolean,
	mutation: string?
)
	local startPos = beltStart.WorldPosition + Vector3.new(0, BELT_HOVER, 0)
	local endPos = beltEnd.WorldPosition + Vector3.new(0, BELT_HOVER, 0)

	-- Face the direction of travel; fall back to identity if degenerate.
	local travel = endPos - startPos
	local startCf: CFrame
	local endCf: CFrame
	if travel.Magnitude > 0.001 then
		startCf = CFrame.lookAt(startPos, startPos + travel)
		endCf = startCf.Rotation + endPos
	else
		startCf = CFrame.new(startPos)
		endCf = CFrame.new(endPos)
	end

	model:PivotTo(startCf)
	model.Parent = container

	-- Model parts are anchored (KeyboardModel contract), so we move the whole
	-- model with PivotTo driven by a tweened CFrameValue — no RunService needed.
	local cfValue = Instance.new("CFrameValue")
	cfValue.Value = startCf
	local rideStarted = os.clock()
	local connection = cfValue.Changed:Connect(function()
		if model.Parent == nil then
			return -- plot torn down mid-ride; tween finishes harmlessly
		end
		local pivot = cfValue.Value
		if glow then
			-- Slight hover bob for glowing rarities (the PointLight itself
			-- comes from KeyboardModel.Build per its contract).
			pivot += Vector3.new(0, BOB_AMPLITUDE * math.sin((os.clock() - rideStarted) * BOB_SPEED), 0)
		end
		model:PivotTo(pivot)
	end)

	local tween = TweenService:Create(
		cfValue,
		TweenInfo.new(GameConfig.BeltRideSeconds, Enum.EasingStyle.Linear),
		{ Value = endCf }
	)
	-- The CFrameValue is never parented to the plot, so Completed always fires
	-- after BeltRideSeconds even if the player/plot vanished — no hung thread.
	local ok, err = pcall(function()
		tween:Play()
		tween.Completed:Wait()
	end)

	connection:Disconnect()
	tween:Cancel()
	cfValue:Destroy()
	model:Destroy()

	if not ok then
		warn(`[ProductionService] Belt ride failed for {player.Name}: {err}`)
		return
	end

	-- Arrival = auto-collect. AddKeyboard itself no-ops if the player left or
	-- the inventory filled while this item was in flight.
	if player.Parent ~= nil then
		InventoryService.AddKeyboard(player, keyboardId, "belt", mutation)
		-- Everyone's production feeds the hub Harmony obelisk (Phase 6).
		-- Lazy pcall: no cycle, still boots if HarmonyService is absent.
		pcall(function()
			local HarmonyService = require(script.Parent.HarmonyService) :: any
			HarmonyService.AddPoints(GameConfig.Harmony.PointsProduce)
		end)
	end
end

-- One production attempt on one lane. Skips (without erroring) whenever the
-- inventory is full or the plot/lane isn't available right now.
local function produceTick(player: Player, state: PlayerState, profile: Types.Profile, conveyorIndex: number)
	if #profile.keyboards >= GameConfig.InventoryCap then
		if not state.fullNotified then
			state.fullNotified = true
			Remotes.Notify:FireClient(player, "info", "Inventory full — sell some keyboards!")
		end
		return
	end
	state.fullNotified = false

	local plot = PlotService.GetPlot(player)
	if plot == nil or plot.Parent == nil then
		return -- plot not built yet / being torn down
	end
	local conveyor = plot:FindFirstChild("Conveyor" .. conveyorIndex)
	if conveyor == nil then
		return
	end
	local belt = conveyor:FindFirstChild("Belt")
	if belt == nil or not belt:IsA("BasePart") then
		return
	end
	local beltStart = belt:FindFirstChild("BeltStart")
	local beltEnd = belt:FindFirstChild("BeltEnd")
	if beltStart == nil or not beltStart:IsA("Attachment") then
		return
	end
	if beltEnd == nil or not beltEnd:IsA("Attachment") then
		return
	end

	local upgrades = profile.upgrades
	local factoryTier = math.clamp(upgrades.factoryTier, 1, #FactoryTiers)

	local event = getActiveEvent()
	local effectiveLuck = RollLogic.GetEffectiveLuck(profile, os.time(), if event then event.luckBonus else 0)
	-- profile.pity rides along as the 3rd arg (bad-luck protection; see
	-- GameConfig.Pity and RollLogic's pityCount parameter).
	local keyboardIndex = RollLogic.RollKeyboard(factoryTier, effectiveLuck, rng, profile.pity)
	local def = Keyboards[keyboardIndex]
	if def == nil then
		return
	end

	-- Pity counter (contract): a TargetTier+ roll resets it, anything else
	-- ramps it. MarkDirty only — no Sync per roll; AddKeyboard's Sync at
	-- collect time carries the new value to the client.
	if def.rarityTier >= GameConfig.Pity.TargetTier then
		profile.pity = 0
	else
		profile.pity += 1
	end
	DataService.MarkDirty(player)

	-- Mutation roll: active event's multiplier times any restock-stall
	-- mutation charm the player is carrying (1 when neither applies).
	local mutationMult = (if event then event.mutationMult else 1) * consumeCharmMult(player)
	-- Equipped Thock Buddy polish bonus (Phase 5). Lazy pcall-require: no
	-- cycle, and production still boots if BuddyService is absent.
	local buddyOk, buddyBonus = pcall(function()
		local BuddyService = require(script.Parent.BuddyService) :: any
		return BuddyService.GetMutationBonus(player)
	end)
	if buddyOk and typeof(buddyBonus) == "number" then
		mutationMult += buddyBonus
	end
	-- Weather bias: Cold Snap / Static Surge boost SPECIFIC mutations.
	local mutationId = RollLogic.RollMutation(rng, mutationMult, if event then event.mutationBias else nil)
	local mutationDef = Catalog.GetMutation(mutationId)
	local rarity = Catalog.GetRarity(def.rarityTier)
	local glow = (rarity ~= nil and rarity.glow) or mutationDef ~= nil

	-- Extra 3rd arg is ignored by the 2-arg KeyboardModel.Build until the
	-- mutation-aware version ships — safe either way.
	local buildOk, model = pcall(KeyboardModel.Build, def, ITEM_SCALE, mutationDef)
	if not buildOk or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(`[ProductionService] KeyboardModel.Build failed for "{def.id}": {model}`)
		return
	end

	task.spawn(rideBelt, player, model, conveyor, beltStart, beltEnd, def.id, glow, mutationId)
end

-- The per-(player, lane) driver. Locked lanes poll until unlocked; unlocked
-- lanes stagger their first production, then tick at the effective interval.
-- Upgrades are re-read from the live profile every iteration, so factory/speed/
-- conveyor pad purchases apply immediately.
local function conveyorLoop(player: Player, state: PlayerState, conveyorIndex: number)
	local staggered = false
	while state.alive and player.Parent ~= nil do
		local profile = DataService.GetProfile(player)
		if profile == nil then
			break -- session released (player leaving)
		end

		local conveyors = math.clamp(profile.upgrades.conveyors, 1, GameConfig.MaxConveyors)
		if conveyorIndex > conveyors then
			staggered = false -- re-stagger when this lane eventually unlocks
			task.wait(LOCKED_POLL_SECONDS)
			continue
		end

		local interval = effectiveInterval(profile.upgrades)
		if not staggered then
			staggered = true
			task.wait(interval * (conveyorIndex - 1) / conveyors)
			continue -- re-read the profile after the offset sleep
		end

		-- pcall so one bad tick (e.g. builder error) never kills the lane.
		local ok, err = pcall(produceTick, player, state, profile, conveyorIndex)
		if not ok then
			warn(`[ProductionService] Production tick failed for {player.Name} lane {conveyorIndex}: {err}`)
		end
		task.wait(interval)
	end
end

local function startDriver(player: Player)
	if states[player] ~= nil then
		return -- OnProfileLoaded replays already-loaded players; don't double-spawn
	end
	local state: PlayerState = { alive = true, fullNotified = false }
	states[player] = state
	for conveyorIndex = 1, GameConfig.MaxConveyors do
		task.spawn(conveyorLoop, player, state, conveyorIndex)
	end
end

function ProductionService.Init()
	-- Dependencies are wired via the module requires above.
end

function ProductionService.Start()
	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		if state ~= nil then
			state.alive = false -- every lane loop (and in-flight logic) observes this
			states[player] = nil
		end
	end)

	DataService.OnProfileLoaded(function(player, _profile)
		if player.Parent == nil then
			return
		end
		startDriver(player)
	end)
end

return ProductionService
