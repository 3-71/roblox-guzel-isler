--!strict
-- BossService — the THOCK MONSTER world boss (GameConfig.Boss).
--
-- Cycle: every Boss.Min..MaxIntervalSeconds (only with >= 1 player online) a
-- warning siren runs for WarningSeconds, then the monster spawns on the open
-- ground between the hub and the plot ring and slowly stomps toward the
-- nearest occupied plot (anchored PivotTo lerp — it NEVER overlaps a plot's
-- buildings: its distance from the map centre is clamped at the plot edge).
--
-- Damage the players deal:
--   * every ACCEPTED keypress (EquipService.OnTypeAccepted — already
--     rate-limited + equip-validated) within Boss.DamageRadius of the monster
--     deals TypeDamageBase + TypeDamagePerTier * factoryTier
--   * Boss.WeakSpotCount glowing keycaps with server-side ClickDetectors deal
--     WeakSpotDamage per click, then relocate to another socket
--     (per-player click token bucket so autoclickers can't melt the boss)
--
-- Damage the monster deals: TEMPORARY VISUALS ONLY (owner's explicit
-- decision) — while it is near a plot, BossBuilder piles smoke + crack
-- overlays into that plot's "BossDamage" Model, and fight-end cleanup
-- destroys every BossDamage Model on the map. Real plot parts, inventories,
-- money and profiles are NEVER touched — the only profile write in this file
-- is bossWins += 1 for players who dealt damage to a defeated monster.
--
-- Win  (hp <= 0):  EconomyService.SetSellBoost(WinSellMult, EffectSeconds)
-- Lose (timeout):  EconomyService.SetSellBoost(LoseSellMult, EffectSeconds)
--
-- Clients render everything from the BossState remote:
--   { phase = "warning"|"fight"|"won"|"lost"|"idle", hp, maxHp, endsAt }
-- broadcast on every phase change; hp updates are throttled to ~2/s.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local EquipService = require(script.Parent.EquipService)
local PlotService = require(script.Parent.PlotService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)
local BossBuilder = require(script.Parent.Parent.World.BossBuilder)

local BossService = {}

-- ===== Tuning local to this service (balance numbers live in GameConfig) =====
local TICK_SECONDS = 0.15 -- movement/FX loop cadence
local WALK_SPEED = 4 -- studs/s toward the nearest occupied plot
local STOMP_PERIOD = 1.4 -- seconds per footfall (bob + stomp sound)
local ROAR_MIN_SECONDS = 7
local ROAR_MAX_SECONDS = 13
local DAMAGE_TICK_SECONDS = 2.5 -- how often near-plot visual damage escalates
local NEAR_PLOT_RADIUS = GameConfig.PlotSize / 2 + 22 -- "near a plot" (from plot centre)
local EDGE_MARGIN = 16 -- monster half-depth + fence: keeps it off plot buildings
local HUB_KEEPOUT_RADIUS = 68 -- it never wades into the hub plaza either
local HP_BROADCAST_SECONDS = 0.5 -- throttle: max ~2 hp updates/s
local STATE_REBROADCAST_SECONDS = 3 -- keep-alive resend for mid-fight joiners
local SIREN_PERIOD_SECONDS = 4
local RESULT_LINGER_SECONDS = 5 -- won/lost banner time before the idle reset
local WALK_OFF_SECONDS = 4 -- victory lap length when the monster wins
local CLICK_RATE_PER_SECOND = 5 -- weak-spot click token bucket
local EMPTY_SERVER_POLL_SECONDS = 30

-- ===== State (all server-side) =====
local phase = "idle" -- "idle" | "warning" | "fight" | "won" | "lost"
local monster: Model? = nil
local monsterPos = Vector3.zero
local hp = 0
local maxHp = 0
local stateEndsAt = 0 -- os.time() the current phase resolves (client countdowns)
local damagers: { [Player]: number } = {}
local weakSpotSockets: { [BasePart]: number } = {} -- live weak spot -> socket index
local clickBuckets: { [Player]: { tokens: number, last: number } } = {}
local hpDirty = false
local lastHpBroadcast = 0

local rng = Random.new()

-- ===== Broadcasting =====

local function broadcastState(toPlayer: Player?)
	local payload = { phase = phase, hp = hp, maxHp = maxHp, endsAt = stateEndsAt }
	if toPlayer ~= nil then
		Remotes.BossState:FireClient(toPlayer, payload)
	else
		Remotes.BossState:FireAllClients(payload)
	end
end

-- ===== Damage bookkeeping =====

local function applyDamage(player: Player, amount: number)
	if phase ~= "fight" or hp <= 0 then
		return
	end
	hp = math.max(0, hp - amount)
	damagers[player] = (damagers[player] or 0) + amount
	hpDirty = true
end

-- Registered ONCE with EquipService at Start: an accepted keypress within
-- DamageRadius of the monster is a hit (EquipService already validated the
-- rate limit + equipped keyboard, so every call is a legit press).
local function onTypeAccepted(player: Player, _letter: string?)
	if phase ~= "fight" then
		return
	end
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end
	if (root.Position - monsterPos).Magnitude > GameConfig.Boss.DamageRadius then
		return
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	applyDamage(player, GameConfig.Boss.TypeDamageBase + GameConfig.Boss.TypeDamagePerTier * profile.upgrades.factoryTier)
end

local function takeClickToken(player: Player): boolean
	local bucket = clickBuckets[player]
	local now = os.clock()
	if bucket == nil then
		bucket = { tokens = CLICK_RATE_PER_SECOND, last = now }
		clickBuckets[player] = bucket
	end
	bucket.tokens = math.min(CLICK_RATE_PER_SECOND, bucket.tokens + (now - bucket.last) * CLICK_RATE_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- ===== Weak spots =====

local function pickFreeSocket(currentMonster: Model): number?
	local total = BossBuilder.SocketCount(currentMonster)
	local used: { [number]: boolean } = {}
	for _, socketIndex in weakSpotSockets do
		used[socketIndex] = true
	end
	local free: { number } = {}
	for socketIndex = 1, total do
		if not used[socketIndex] then
			table.insert(free, socketIndex)
		end
	end
	if #free == 0 then
		return nil
	end
	return free[rng:NextInteger(1, #free)]
end

local spawnWeakSpotAt: (Model, number) -> () -- forward declaration (click relocation calls it)

local function onWeakSpotClicked(spot: BasePart, clicker: Player)
	if phase ~= "fight" then
		return
	end
	local socketIndex = weakSpotSockets[spot]
	if socketIndex == nil then
		return -- already consumed by a same-frame click
	end
	if not takeClickToken(clicker) then
		return
	end
	-- ClickDetector.MaxActivationDistance caps the click range client-side;
	-- re-check on the server so exploited clients can't snipe cross-map.
	local character = clicker.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") or (root.Position - monsterPos).Magnitude > 120 then
		return
	end
	if DataService.GetProfile(clicker) == nil then
		return
	end

	applyDamage(clicker, GameConfig.Boss.WeakSpotDamage)

	-- Consume + relocate: this keycap pops, another socket lights up.
	weakSpotSockets[spot] = nil
	local currentMonster = monster
	if currentMonster ~= nil and currentMonster.Parent ~= nil then
		BossBuilder.PlayWeakSpotHit(currentMonster, spot.Position)
		spot:Destroy()
		if hp > 0 then
			local nextSocket = pickFreeSocket(currentMonster)
			if nextSocket ~= nil then
				spawnWeakSpotAt(currentMonster, nextSocket)
			end
		end
	else
		spot:Destroy()
	end
end

spawnWeakSpotAt = function(currentMonster: Model, socketIndex: number)
	local spot = BossBuilder.SpawnWeakSpot(currentMonster, socketIndex)
	if spot == nil then
		return
	end
	weakSpotSockets[spot] = socketIndex
	local click = spot:FindFirstChildOfClass("ClickDetector")
	if click ~= nil then
		click.MouseClick:Connect(function(clicker: Player)
			onWeakSpotClicked(spot, clicker)
		end)
	end
end

-- ===== Plot lookups =====

type PlotEntry = { plot: Model, position: Vector3 }

local function occupiedPlots(): { PlotEntry }
	local entries: { PlotEntry } = {}
	for _, player in Players:GetPlayers() do
		local plot = PlotService.GetPlot(player)
		if plot ~= nil and plot.Parent ~= nil then
			local pivot = plot:GetPivot()
			table.insert(entries, { plot = plot, position = Vector3.new(pivot.Position.X, 0, pivot.Position.Z) })
		end
	end
	return entries
end

local function nearestPlotPosition(from: Vector3): Vector3?
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, entry in occupiedPlots() do
		local distance = (entry.position - Vector3.new(from.X, 0, from.Z)).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			best = entry.position
		end
	end
	return best
end

-- ===== Cleanup (every exit path funnels through here) =====

local function clearAllPlotDamage()
	-- Iterate the Plots folder rather than online players: an owner who left
	-- mid-fight must not leave smoking cracks behind on their old plot.
	local plotsFolder = Workspace:FindFirstChild("Plots")
	if plotsFolder ~= nil then
		for _, plot in plotsFolder:GetChildren() do
			if plot:IsA("Model") then
				pcall(BossBuilder.ClearPlotDamage, plot)
			end
		end
	end
end

local function cleanupFight()
	table.clear(weakSpotSockets)
	local currentMonster = monster
	monster = nil
	if currentMonster ~= nil then
		currentMonster:Destroy()
	end
	clearAllPlotDamage()
	table.clear(damagers)
	hpDirty = false
end

-- ===== Fight phases =====

local function runWarningPhase()
	phase = "warning"
	hp = 0
	maxHp = 0
	stateEndsAt = os.time() + GameConfig.Boss.WarningSeconds
	broadcastState(nil)
	Remotes.Notify:FireAllClients("event", "⚠️ THE THOCK MONSTER IS COMING! Grab your keyboard and get ready to TYPE!")

	local deadline = os.clock() + GameConfig.Boss.WarningSeconds
	while os.clock() < deadline do
		BossBuilder.PlaySiren()
		-- Rebroadcast each siren beat so just-connected clients get the
		-- warning too (their first PlayerAdded send may have been dropped).
		broadcastState(nil)
		task.wait(math.min(SIREN_PERIOD_SECONDS, math.max(deadline - os.clock(), 0.1)))
	end
end

-- The movement/FX loop. Returns "won" | "lost" | "abandoned".
local function runFightLoop(currentMonster: Model, maxRadius: number, initialFaceDir: Vector3): string
	local deadline = os.clock() + GameConfig.Boss.FightSeconds
	local faceDir = initialFaceDir
	local bobTime = 0
	local lastStompIndex = 0
	local nextRoarAt = os.clock() + rng:NextNumber(3, 6)
	local nextDamageTickAt = os.clock() + DAMAGE_TICK_SECONDS

	while true do
		task.wait(TICK_SECONDS)
		if hp <= 0 then
			return "won"
		end
		if os.clock() >= deadline then
			return "lost"
		end
		if #Players:GetPlayers() == 0 or currentMonster.Parent == nil then
			return "abandoned"
		end

		-- Steer toward the nearest occupied plot, clamped inside the ring of
		-- open ground (never onto plot buildings, never into the hub plaza).
		local target = nearestPlotPosition(monsterPos)
		if target ~= nil then
			local delta = target - Vector3.new(monsterPos.X, 0, monsterPos.Z)
			if delta.Magnitude > 2 then
				local moveDir = delta.Unit
				monsterPos += moveDir * WALK_SPEED * TICK_SECONDS
				local flat = Vector3.new(monsterPos.X, 0, monsterPos.Z)
				if flat.Magnitude > maxRadius then
					monsterPos = flat.Unit * maxRadius
				elseif flat.Magnitude > 0.01 and flat.Magnitude < HUB_KEEPOUT_RADIUS then
					monsterPos = flat.Unit * HUB_KEEPOUT_RADIUS
				end
				local blended = faceDir:Lerp(moveDir, math.min(1, TICK_SECONDS * 2.5))
				if blended.Magnitude > 0.01 then
					faceDir = Vector3.new(blended.X, 0, blended.Z).Unit
				end
			end
		end

		-- Stompy waddle: bob + roll, footfall sound at each cycle.
		bobTime += TICK_SECONDS
		local bobY = math.abs(math.sin(math.pi * bobTime / STOMP_PERIOD)) * 1.1
		local roll = math.sin(math.pi * bobTime / STOMP_PERIOD) * math.rad(3)
		local stompIndex = math.floor(bobTime / STOMP_PERIOD)
		if stompIndex > lastStompIndex then
			lastStompIndex = stompIndex
			BossBuilder.PlayStomp(currentMonster)
		end
		local pivotPos = monsterPos + Vector3.new(0, bobY, 0)
		currentMonster:PivotTo(CFrame.lookAt(pivotPos, pivotPos + faceDir) * CFrame.Angles(0, 0, roll))

		if os.clock() >= nextRoarAt then
			BossBuilder.PlayRoar(currentMonster)
			nextRoarAt = os.clock() + rng:NextNumber(ROAR_MIN_SECONDS, ROAR_MAX_SECONDS)
		end

		-- Temporary visual damage on plots the monster looms over.
		if os.clock() >= nextDamageTickAt then
			nextDamageTickAt = os.clock() + DAMAGE_TICK_SECONDS
			for _, entry in occupiedPlots() do
				if (entry.position - Vector3.new(monsterPos.X, 0, monsterPos.Z)).Magnitude <= NEAR_PLOT_RADIUS then
					pcall(BossBuilder.ApplyPlotDamage, entry.plot, monsterPos)
				end
			end
		end

		-- Throttled hp rebroadcast (~2/s max). The time-based fallback also
		-- catches clients whose UI connected mid-fight (a RemoteEvent fired
		-- at a still-loading client is dropped, so PlayerAdded alone is not
		-- enough — see the client-world verifier finding).
		if hpDirty and os.clock() - lastHpBroadcast >= HP_BROADCAST_SECONDS then
			hpDirty = false
			lastHpBroadcast = os.clock()
			broadcastState(nil)
		elseif os.clock() - lastHpBroadcast >= STATE_REBROADCAST_SECONDS then
			lastHpBroadcast = os.clock()
			broadcastState(nil)
		end
	end
end

local function resolveWin(currentMonster: Model)
	local config = GameConfig.Boss
	phase = "won"
	hp = 0
	stateEndsAt = os.time() + config.EffectSeconds
	EconomyService.SetSellBoost(config.WinSellMult, config.EffectSeconds)

	-- The ONLY profile write in a boss fight: credit everyone who fought.
	for player, dealt in damagers do
		if dealt > 0 and player.Parent ~= nil then
			local profile = DataService.GetProfile(player)
			if profile ~= nil then
				profile.bossWins += 1
				DataService.MarkDirty(player)
				DataService.Sync(player)
			end
		end
	end

	broadcastState(nil)
	local bonusPercent = math.floor((config.WinSellMult - 1) * 100 + 0.5)
	local minutes = math.floor(config.EffectSeconds / 60 + 0.5)
	Remotes.Notify:FireAllClients(
		"flex",
		`🎉 THOCK MONSTER DEFEATED! Everyone sells for +{bonusPercent}% for {minutes} minutes!`
	)

	clearAllPlotDamage()
	BossBuilder.PlayDeathBurst(currentMonster)
	task.wait(1.4) -- let the burst read before the body vanishes
end

local function resolveLoss(currentMonster: Model)
	local config = GameConfig.Boss
	phase = "lost"
	stateEndsAt = os.time() + config.EffectSeconds
	EconomyService.SetSellBoost(config.LoseSellMult, config.EffectSeconds)
	broadcastState(nil)
	local penaltyPercent = math.floor((1 - config.LoseSellMult) * 100 + 0.5)
	local minutes = math.floor(config.EffectSeconds / 60 + 0.5)
	Remotes.Notify:FireAllClients(
		"info",
		`💀 The THOCK MONSTER stomped off victorious... -{penaltyPercent}% sell value for {minutes} minutes.`
	)
	clearAllPlotDamage()

	-- Victory lap: it roars once and stomps off the map before despawning.
	BossBuilder.PlayRoar(currentMonster)
	local flat = Vector3.new(monsterPos.X, 0, monsterPos.Z)
	local awayDir = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, 1)
	local bobTime = 0
	local lastStompIndex = 0
	local walkOffDeadline = os.clock() + WALK_OFF_SECONDS
	while os.clock() < walkOffDeadline and currentMonster.Parent ~= nil do
		task.wait(TICK_SECONDS)
		monsterPos += awayDir * WALK_SPEED * 1.6 * TICK_SECONDS
		bobTime += TICK_SECONDS
		local bobY = math.abs(math.sin(math.pi * bobTime / STOMP_PERIOD)) * 1.1
		local stompIndex = math.floor(bobTime / STOMP_PERIOD)
		if stompIndex > lastStompIndex then
			lastStompIndex = stompIndex
			BossBuilder.PlayStomp(currentMonster)
		end
		local pivotPos = monsterPos + Vector3.new(0, bobY, 0)
		currentMonster:PivotTo(CFrame.lookAt(pivotPos, pivotPos + awayDir))
	end
end

local function runBossCycle()
	runWarningPhase()

	local playerCount = #Players:GetPlayers()
	if playerCount == 0 then
		return -- everyone left during the warning; the finally-block resets to idle
	end

	local config = GameConfig.Boss
	maxHp = config.BaseHp + config.HpPerPlayer * playerCount
	hp = maxHp
	table.clear(damagers)

	-- Spawn on the open ground between hub and plots, headed for a random
	-- occupied plot (or a random direction on an all-hub server).
	local ringRadius = PlotBuilder.GetRingRadius()
	local maxRadius = math.max(ringRadius - GameConfig.PlotSize / 2 - EDGE_MARGIN, HUB_KEEPOUT_RADIUS)
	local plots = occupiedPlots()
	local angle
	if #plots > 0 then
		local picked = plots[rng:NextInteger(1, #plots)]
		angle = math.atan2(picked.position.Z, picked.position.X)
	else
		angle = rng:NextNumber(0, math.pi * 2)
	end
	local spawnRadius = math.clamp((HUB_KEEPOUT_RADIUS + maxRadius) / 2, HUB_KEEPOUT_RADIUS, maxRadius)
	monsterPos = Vector3.new(math.cos(angle) * spawnRadius, 0, math.sin(angle) * spawnRadius)

	local initialTarget = nearestPlotPosition(monsterPos)
	local initialFaceDir = Vector3.new(0, 0, -1)
	if initialTarget ~= nil then
		local delta = initialTarget - monsterPos
		if delta.Magnitude > 0.01 then
			initialFaceDir = Vector3.new(delta.X, 0, delta.Z).Unit
		end
	end

	local currentMonster = BossBuilder.Build(CFrame.lookAt(monsterPos, monsterPos + initialFaceDir))
	monster = currentMonster
	for _ = 1, config.WeakSpotCount do
		local socketIndex = pickFreeSocket(currentMonster)
		if socketIndex ~= nil then
			spawnWeakSpotAt(currentMonster, socketIndex)
		end
	end

	phase = "fight"
	stateEndsAt = os.time() + config.FightSeconds
	broadcastState(nil)
	BossBuilder.PlayRoar(currentMonster)
	Remotes.Notify:FireAllClients("event", "👾 THOCK MONSTER ATTACK! Type near it and smash its golden keycaps!")

	local result = runFightLoop(currentMonster, maxRadius, initialFaceDir)

	if result == "won" then
		resolveWin(currentMonster)
	elseif result == "lost" then
		resolveLoss(currentMonster)
	end
	-- "abandoned" (empty server / monster externally removed): no boost, no
	-- banners — straight to cleanup.

	cleanupFight()

	if result == "won" or result == "lost" then
		task.wait(RESULT_LINGER_SECONDS) -- let the result banner read
	end
end

-- ===== Lifecycle =====

function BossService.Init()
	-- Dependencies are wired via the module requires above.
end

function BossService.Start()
	-- ONE callback for the whole service lifetime, guarded by phase.
	EquipService.OnTypeAccepted(onTypeAccepted)

	Players.PlayerAdded:Connect(function(player: Player)
		-- Mid-fight joiners get the current state immediately (regular hp
		-- rebroadcasts only fire while damage is coming in).
		if phase ~= "idle" then
			broadcastState(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		damagers[player] = nil -- can't sync a saved-and-gone profile
		clickBuckets[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(rng:NextInteger(GameConfig.Boss.MinIntervalSeconds, GameConfig.Boss.MaxIntervalSeconds))
			if #Players:GetPlayers() == 0 then
				-- The interval elapsed on an empty server. Hold, then restart
				-- a FRESH interval so a lone joiner isn't ambushed seconds
				-- after walking in.
				repeat
					task.wait(EMPTY_SERVER_POLL_SECONDS)
				until #Players:GetPlayers() > 0
				continue
			end

			local ok, err = pcall(runBossCycle)
			if not ok then
				warn("[BossService] boss cycle failed: " .. tostring(err))
				pcall(cleanupFight)
			end

			-- Always land back on a clean broadcasted idle, even after errors.
			phase = "idle"
			hp = 0
			maxHp = 0
			stateEndsAt = 0
			broadcastState(nil)
		end
	end)
end

return BossService
