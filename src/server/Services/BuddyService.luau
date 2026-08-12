--!strict
-- BuddyService — Thock Buddies (Phase 5): six earnable critter companions
-- (Config/Buddies — NEVER sold, never random). The equipped buddy "polishes"
-- keyboards riding the belt: its perk.mutationBonus is added to the mutation
-- chanceMult by ProductionService, which calls GetMutationBonus on EVERY
-- production roll — that function must stay yield-free and cheap (pure table
-- lookups only).
--
-- Contract (ARCHITECTURE.md Phase 5 item 4):
--   GetMutationBonus(player) -> equipped buddy's perk.mutationBonus or 0.
--   CheckUnlocks(player) -> compares profile stats (streakDays, raceWins,
--     bossWins, #setsClaimed, rebirths, likesGiven) against Config/Buddies
--     earn defs; newly earned ids get profile.buddies[id] = true + a
--     celebratory Notify + MarkDirty/Sync. Wired from
--     DataService.OnProfileLoaded and a 60s sweep loop.
--   BuddyEquip remote (buddyId: string? — nil unequips; 3/s token bucket):
--     validates ownership, sets profile.equippedBuddy, rebuilds visuals.
--
-- Visuals (BuddyBuilder models, both fully inert decorations):
--   * PERCH copy — sits on the Conveyor1 side rail of the owner's plot,
--     idle-bobbing, watching the boards ride past. Parented UNDER the plot
--     model so PlotService.RebuildForProfile (rebirth) destroys it with the
--     plot; a 5s re-resolve loop notices and re-perches. The plot is found
--     via Workspace.Plots + the OwnerUserId attribute (PlotBuilder sets it).
--   * FOLLOWER copy — hovers behind the owner around the hub via anchored
--     PivotTo lerp on Heartbeat. Plot-radius aware: parked out of sight
--     while the owner is within their own plot's radius (the perch copy is
--     the buddy "at home"). Lives in the Workspace.Buddies folder.
--   Both are destroyed on unequip and on PlayerRemoving.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Buddies = require(Shared.Config.Buddies)
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local BuddyBuilder = require(script.Parent.Parent.World.BuddyBuilder)

local BuddyService = {}

local RESOLVE_SECONDS = 5 -- perch/follower health check cadence (re-perches after plot rebuilds)
local UNLOCK_SWEEP_SECONDS = 60 -- catches stat changes made by other services (boss wins, race wins, ...)

-- Perch: buddy stands on the Conveyor1 side rail (rail centre is at belt-local
-- (±2.5, 0.75, z), rail top +0.175, feet drop 1.05 → pivot y 0.925 + 1.05).
local PERCH_LOCAL = Vector3.new(2.5, 0.925 + BuddyBuilder.FEET_DROP, -18)
-- Perch gaze target (belt-local): toward the belt centre, up-belt — so the
-- buddy watches keyboards glide toward the collector.
local PERCH_LOOK_LOCAL = Vector3.new(-2.5, 0.925 + BuddyBuilder.FEET_DROP, -10)

-- Follower: behind-right of the HumanoidRootPart (character-local; +Z = behind).
local FOLLOW_OFFSET = Vector3.new(1.7, 0, 2.8)
-- R15 root centre floats ~2.75 studs above ground; buddy pivot wants ~1.05.
local FOLLOW_DROP = 1.7
local FOLLOW_BOB_HEIGHT = 0.18
local FOLLOW_BOB_SPEED = 3 -- rad/s of the sine bob
local FOLLOW_LERP_RATE = 6 -- alpha = min(dt * rate, 1)
local SNAP_DISTANCE = 45 -- teleport instead of lerp beyond this (respawn/warp)
-- Follower hides while the owner is inside their own plot's radius.
local HOME_HIDE_RADIUS = GameConfig.PlotSize / 2 + 10
-- Hidden followers wait below the map — but ABOVE the default
-- Workspace.FallenPartsDestroyHeight (-500): the buddy's unanchored welded
-- parts hang ~1 stud under the pivot and would be culled (and the buddy
-- permanently dismembered) if parked on the kill plane.
local PARKED_CF = CFrame.new(0, -420, 0)

type PerchEntry = { model: Model, plot: Model, buddyId: string, bob: Tween? }
type FollowerEntry = { model: Model, buddyId: string, parked: boolean, phase: number }

local buddyById: { [string]: Buddies.BuddyDef } = {}
local perches: { [Player]: PerchEntry } = {}
local followers: { [Player]: FollowerEntry } = {}

local rng = Random.new()

-- ===== BuddyEquip token bucket (contract: 3/s per player) =====

local EQUIP_RATE_PER_SECOND = 3

local equipTokens: { [Player]: { tokens: number, last: number } } = {}

local function takeEquipToken(player: Player): boolean
	local bucket = equipTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 3, last = now }
		equipTokens[player] = bucket
	end
	bucket.tokens = math.min(3, bucket.tokens + (now - bucket.last) * EQUIP_RATE_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- ===== Perk lookup (hot path) =====

-- The equipped buddy's def, or nil when nothing valid is equipped. Pure table
-- lookups — safe on the production hot path. Also tolerates corrupt saves
-- (equipped id unknown or not actually owned → treated as unequipped).
local function equippedDef(profile: Types.Profile): Buddies.BuddyDef?
	local id = profile.equippedBuddy
	if id == nil then
		return nil
	end
	local def = buddyById[id]
	if def == nil then
		return nil
	end
	local owned = profile.buddies
	if owned == nil or owned[id] ~= true then
		return nil
	end
	return def
end

-- Called by ProductionService on EVERY roll (via lazy pcall). MUST NOT yield.
function BuddyService.GetMutationBonus(player: Player): number
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return 0
	end
	local def = equippedDef(profile)
	if def == nil then
		return 0
	end
	return def.perk.mutationBonus
end

-- ===== Unlocks =====

-- Grants every newly-earned buddy. Idempotent — owned ids are skipped forever
-- (profile.buddies persists). One MarkDirty+Sync covers all grants in a call;
-- nothing syncs when nothing unlocks, so the 60s sweep stays cheap.
function BuddyService.CheckUnlocks(player: Player)
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	-- Saves from before the Phase 5 reconcile may lack the table; self-heal
	-- (same defensive stance as profile.passes / setsClaimed).
	local owned = profile.buddies
	if owned == nil then
		owned = {}
		profile.buddies = owned
	end

	local setsCount = 0
	if profile.setsClaimed ~= nil then
		for _ in profile.setsClaimed do
			setsCount += 1
		end
	end
	-- Earn-kind -> current stat (Config/Buddies BuddyEarn.kind values).
	local stats: { [string]: number } = {
		streak = profile.streakDays or 0,
		raceWins = profile.raceWins or 0,
		bossWins = profile.bossWins or 0,
		sets = setsCount,
		rebirths = profile.rebirths or 0,
		likesGiven = profile.likesGiven or 0,
	}

	local unlockedAny = false
	for _, def in Buddies do
		if owned[def.id] ~= true and (stats[def.earn.kind] or 0) >= def.earn.count then
			owned[def.id] = true
			unlockedAny = true
			Remotes.Notify:FireClient(
				player,
				"flex",
				`{def.emoji} Thock Buddy unlocked: {def.name}! Equip it from the Buddies panel.`
			)
		end
	end

	if unlockedAny then
		DataService.MarkDirty(player)
		DataService.Sync(player)
	end
end

-- ===== Visuals =====

local function getBuddiesFolder(): Folder
	local existing = Workspace:FindFirstChild("Buddies")
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Buddies"
	folder.Parent = Workspace
	return folder
end

-- The owner's plot, found per contract via Workspace.Plots + the OwnerUserId
-- attribute (NOT via PlotService — keeps this service dependency-light and
-- naturally re-resolves fresh models after RebuildForProfile).
local function resolvePlot(player: Player): Model?
	local plotsFolder = Workspace:FindFirstChild("Plots")
	if plotsFolder == nil then
		return nil
	end
	for _, child in plotsFolder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == player.UserId then
			return child
		end
	end
	return nil
end

local function destroyPerch(player: Player)
	local entry = perches[player]
	if entry == nil then
		return
	end
	perches[player] = nil
	if entry.bob ~= nil then
		entry.bob:Cancel()
	end
	entry.model:Destroy()
end

local function destroyFollower(player: Player)
	local entry = followers[player]
	if entry == nil then
		return
	end
	followers[player] = nil
	entry.model:Destroy()
end

local function destroyVisuals(player: Player)
	destroyPerch(player)
	destroyFollower(player)
end

-- Perches one copy on the plot's Conveyor1 rail. Silently no-ops when the
-- plot/belt isn't built yet — the RESOLVE_SECONDS loop retries.
local function spawnPerch(player: Player, def: Buddies.BuddyDef)
	local plot = resolvePlot(player)
	if plot == nil or plot.Parent == nil then
		return
	end
	local conveyor = plot:FindFirstChild("Conveyor1")
	local belt = if conveyor ~= nil then conveyor:FindFirstChild("Belt") else nil
	if belt == nil or not belt:IsA("BasePart") then
		return
	end

	local ok, model = pcall(BuddyBuilder.Build, def)
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(`[BuddyService] BuddyBuilder.Build failed for "{def.id}": {model}`)
		return
	end

	-- The belt part carries the plot's yaw only (no tilt), so belt-local
	-- offsets with equal Y land at equal world height.
	local pos = belt.CFrame:PointToWorldSpace(PERCH_LOCAL)
	local look = belt.CFrame:PointToWorldSpace(PERCH_LOOK_LOCAL)
	model:PivotTo(CFrame.lookAt(pos, look))
	model.Name = "BuddyPerch"
	model.Parent = plot -- dies with the plot on rebirth rebuilds (by design)

	perches[player] = {
		model = model,
		plot = plot,
		buddyId = def.id,
		bob = BuddyBuilder.StartBob(model),
	}
end

-- Spawns the hub follower parked out of sight; the Heartbeat loop places it.
local function spawnFollower(player: Player, def: Buddies.BuddyDef)
	local ok, model = pcall(BuddyBuilder.Build, def)
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(`[BuddyService] BuddyBuilder.Build failed for "{def.id}": {model}`)
		return
	end
	model:PivotTo(PARKED_CF)
	model.Name = "BuddyFollower_" .. player.Name
	model.Parent = getBuddiesFolder()

	followers[player] = {
		model = model,
		buddyId = def.id,
		parked = true,
		phase = rng:NextNumber(0, math.pi * 2),
	}
end

-- Brings both copies in line with the profile: destroys stale/orphaned ones
-- (wrong buddy, destroyed model, dead plot) and spawns what's missing.
-- Cheap no-op while everything is healthy; called on load, on equip and every
-- RESOLVE_SECONDS.
local function refreshVisuals(player: Player)
	local profile = DataService.GetProfile(player)
	local def = if profile ~= nil then equippedDef(profile) else nil
	if def == nil then
		destroyVisuals(player)
		return
	end

	local perch = perches[player]
	if perch ~= nil and (perch.buddyId ~= def.id or perch.model.Parent == nil or perch.plot.Parent == nil) then
		destroyPerch(player)
		perch = nil
	end
	if perch == nil then
		spawnPerch(player, def)
	end

	local follower = followers[player]
	if follower ~= nil and (follower.buddyId ~= def.id or follower.model.Parent == nil) then
		destroyFollower(player)
		follower = nil
	end
	if follower == nil then
		spawnFollower(player, def)
	end
end

-- ===== Follower movement (Heartbeat) =====

local function updateFollowers(dt: number)
	local now = os.clock()
	for player, entry in followers do
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil

		local hide = true
		if root ~= nil and root:IsA("BasePart") then
			hide = false
			-- Plot-radius aware: at home the PERCH copy is the buddy.
			local perch = perches[player]
			if perch ~= nil and perch.plot.Parent ~= nil then
				local plotPos = perch.plot:GetPivot().Position
				if (root.Position - plotPos).Magnitude <= HOME_HIDE_RADIUS then
					hide = true
				end
			end
		end

		if hide then
			if not entry.parked then
				entry.parked = true
				entry.model:PivotTo(PARKED_CF)
			end
		else
			local rootPart = root :: BasePart
			local rootCF = rootPart.CFrame
			local look = rootCF.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			flatLook = if flatLook.Magnitude > 0.05 then flatLook.Unit else Vector3.zAxis

			local anchor = rootCF:PointToWorldSpace(FOLLOW_OFFSET)
			local bob = math.sin(now * FOLLOW_BOB_SPEED + entry.phase) * FOLLOW_BOB_HEIGHT
			local targetPos = Vector3.new(anchor.X, rootPart.Position.Y - FOLLOW_DROP + bob, anchor.Z)
			local target = CFrame.lookAt(targetPos, targetPos + flatLook)

			local current = entry.model:GetPivot()
			if entry.parked or (current.Position - targetPos).Magnitude > SNAP_DISTANCE then
				entry.parked = false
				entry.model:PivotTo(target)
			else
				entry.model:PivotTo(current:Lerp(target, math.clamp(dt * FOLLOW_LERP_RATE, 0, 1)))
			end
		end
	end
end

-- ===== BuddyEquip remote =====

local function onBuddyEquip(player: Player, buddyId: unknown)
	if not takeEquipToken(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	if buddyId ~= nil and typeof(buddyId) ~= "string" then
		return -- malformed; drop silently
	end

	if buddyId == nil then
		if profile.equippedBuddy == nil then
			return -- nothing to do
		end
		profile.equippedBuddy = nil
		Remotes.Notify:FireClient(player, "info", "Buddy unequipped.")
	else
		local id = buddyId :: string
		local def = buddyById[id]
		if def == nil then
			return -- unknown id; drop silently
		end
		local owned = profile.buddies
		if owned == nil or owned[id] ~= true then
			Remotes.Notify:FireClient(player, "error", "You haven't earned that buddy yet — " .. def.earn.label)
			return
		end
		profile.equippedBuddy = id
		Remotes.Notify:FireClient(player, "info", `{def.emoji} {def.name} is now your buddy!`)
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
	refreshVisuals(player)
end

-- ===== Lifecycle =====

function BuddyService.Init()
	for _, def in Buddies do
		buddyById[def.id] = def
	end
end

function BuddyService.Start()
	Remotes.BuddyEquip.OnServerEvent:Connect(onBuddyEquip)

	-- Grants earned buddies + spawns visuals as soon as the profile lands
	-- (replays for already-loaded players; callbacks are pcall'd upstream).
	DataService.OnProfileLoaded(function(player, _profile)
		BuddyService.CheckUnlocks(player)
		refreshVisuals(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		destroyVisuals(player)
		equipTokens[player] = nil
	end)

	RunService.Heartbeat:Connect(updateFollowers)

	-- Perch/follower health check: re-perches after plot rebuilds (rebirth)
	-- and finishes spawns that raced the plot build.
	task.spawn(function()
		while true do
			task.wait(RESOLVE_SECONDS)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(refreshVisuals, player)
				if not ok then
					warn(`[BuddyService] refreshVisuals failed for {player.Name}: {err}`)
				end
			end
		end
	end)

	-- Unlock sweep: other services bump the stats (bossWins, raceWins, ...);
	-- this catches every change within a minute without cross-service wiring.
	task.spawn(function()
		while true do
			task.wait(UNLOCK_SWEEP_SECONDS)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(BuddyService.CheckUnlocks, player)
				if not ok then
					warn(`[BuddyService] CheckUnlocks sweep failed for {player.Name}: {err}`)
				end
			end
		end
	end)
end

return BuddyService
