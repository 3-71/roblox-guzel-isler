--!strict
-- TypingRaceService — the hub's periodic typing race. Every
-- GameConfig.Race.IntervalSeconds a race opens: stand on the hub's RacePad
-- during the join window, then mash your equipped keyboard while the race
-- runs. Each ACCEPTED keypress (EquipService.OnTypeAccepted — already
-- rate-limited and equip-validated) scores 1 * (1 + rarityTier / 12), so
-- rarer boards type "heavier". Winner takes
-- GameConfig.Race.BaseReward * their factory tier in cash.
--
-- Clients render everything from the RaceState remote:
--   { phase = "joining",  endsAt }                    -- join window open
--   { phase = "racing",   endsAt, scores = top-5 }    -- every ~1s while racing
--   { phase = "finished", scores = full sorted }      -- podium
--   { phase = "idle" }                                -- race cancelled (nobody joined)
-- scores entries are { name: string, score: number (1 decimal) }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local EconomyService = require(script.Parent.EconomyService)
local EquipService = require(script.Parent.EquipService)

local TypingRaceService = {}

local JOIN_RADIUS = 12 -- studs from the RacePad's center that counts as "on the pad"
local JOIN_POLL_SECONDS = 0.5
local SCORE_BROADCAST_SECONDS = 1
local PAD_WAIT_SECONDS = 10 -- tolerant startup wait for workspace.Hub.RacePad
local TOP_SCORES = 5 -- live leaderboard size while racing

type ScoreEntry = { player: Player, score: number, scoredAt: number }
type ScorePayloadEntry = { name: string, score: number }

local isRacing = false
local joined: { [Player]: boolean } = {}
local scores: { [Player]: number } = {}
-- os.clock() of each racer's last score change — ties go to whoever got there first.
local lastScoredAt: { [Player]: number } = {}

local function clearRaceState()
	isRacing = false
	table.clear(joined)
	table.clear(scores)
	table.clear(lastScoredAt)
end

-- ===== Scoring =====

-- Registered ONCE with EquipService at Start. EquipService only fires this
-- after rate-limit + equip validation, so every call is a legit keypress.
local function onTypeAccepted(player: Player)
	if not isRacing or joined[player] ~= true then
		return
	end
	local profile = DataService.GetProfile(player)
	local uid = if profile ~= nil then profile.equippedUid else nil
	if profile == nil or uid == nil then
		return -- no equipped keyboard = no score (that's fine)
	end
	local instance = InventoryService.GetKeyboard(player, uid)
	if instance == nil then
		return
	end
	local def = Catalog.GetKeyboard(instance.id)
	if def == nil then
		return
	end
	scores[player] = (scores[player] or 0) + 1 * (1 + def.rarityTier / 12)
	lastScoredAt[player] = os.clock()
end

-- Racers sorted best-first; equal scores go to whoever reached theirs first.
local function sortedEntries(): { ScoreEntry }
	local entries: { ScoreEntry } = {}
	for player, score in scores do
		table.insert(entries, {
			player = player,
			score = score,
			scoredAt = lastScoredAt[player] or math.huge,
		})
	end
	table.sort(entries, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.scoredAt < b.scoredAt
	end)
	return entries
end

local function toPayload(entries: { ScoreEntry }, limit: number): { ScorePayloadEntry }
	local payload: { ScorePayloadEntry } = {}
	for i = 1, math.min(limit, #entries) do
		local entry = entries[i]
		table.insert(payload, {
			name = entry.player.Name,
			score = math.floor(entry.score * 10 + 0.5) / 10, -- 1 decimal
		})
	end
	return payload
end

-- ===== Race cycle =====

local function runJoinWindow(pad: BasePart)
	Remotes.RaceState:FireAllClients({
		phase = "joining",
		endsAt = os.time() + GameConfig.Race.JoinWindowSeconds,
	})

	local deadline = os.clock() + GameConfig.Race.JoinWindowSeconds
	while os.clock() < deadline do
		for _, player in Players:GetPlayers() do
			if joined[player] ~= true then
				local character = player.Character
				local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
				if
					root ~= nil
					and root:IsA("BasePart")
					and (root.Position - pad.Position).Magnitude <= JOIN_RADIUS
				then
					joined[player] = true
					scores[player] = 0
					Remotes.Notify:FireClient(player, "info", "You're in the race!")
				end
			end
		end
		task.wait(JOIN_POLL_SECONDS)
	end
end

local function runRacingPhase()
	local endsAt = os.time() + GameConfig.Race.DurationSeconds
	local deadline = os.clock() + GameConfig.Race.DurationSeconds
	isRacing = true
	Remotes.RaceState:FireAllClients({
		phase = "racing",
		endsAt = endsAt,
		scores = toPayload(sortedEntries(), TOP_SCORES),
	})
	while true do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			break
		end
		task.wait(math.min(SCORE_BROADCAST_SECONDS, remaining))
		if os.clock() < deadline then
			Remotes.RaceState:FireAllClients({
				phase = "racing",
				endsAt = endsAt,
				scores = toPayload(sortedEntries(), TOP_SCORES),
			})
		end
	end
	isRacing = false
end

local function finishRace()
	local entries = sortedEntries()
	Remotes.RaceState:FireAllClients({
		phase = "finished",
		scores = toPayload(entries, #entries),
	})

	-- Winner = entries[1]. Leavers were dropped on PlayerRemoving, and a
	-- 0 score means nobody actually typed — no reward in either case.
	local winner = entries[1]
	local rewarded = false
	if winner ~= nil and winner.score > 0 and winner.player.Parent ~= nil then
		local profile = DataService.GetProfile(winner.player)
		if profile ~= nil then
			local reward = GameConfig.Race.BaseReward * profile.upgrades.factoryTier
			EconomyService.AddMoney(winner.player, reward)
			Remotes.Notify:FireAllClients(
				"flex",
				winner.player.Name .. " won the typing race! (+$" .. EconomyService.Abbreviate(reward) .. ")"
			)
			rewarded = true
		end
	end
	if not rewarded then
		Remotes.Notify:FireAllClients("info", "The typing race ended with no winner this time.")
	end
end

local function runRace(pad: BasePart)
	clearRaceState()
	runJoinWindow(pad)

	local participants = 0
	for _ in joined do
		participants += 1
	end
	if participants == 0 then
		Remotes.RaceState:FireAllClients({ phase = "idle" })
		Remotes.Notify:FireAllClients("info", "Race cancelled — nobody joined.")
		return
	end
	-- 1+ participants run (a solo race is allowed).

	runRacingPhase()
	finishRace()
end

-- ===== Pad lookup =====

-- Tolerant startup resolve of workspace.Hub.RacePad (HubBuilder parents it
-- directly under the Hub folder). Roughly PAD_WAIT_SECONDS total budget.
local function resolveRacePad(): BasePart?
	local deadline = os.clock() + PAD_WAIT_SECONDS
	local hub = Workspace:WaitForChild("Hub", PAD_WAIT_SECONDS)
	if hub == nil then
		return nil
	end
	while true do
		local pad = hub:FindFirstChild("RacePad")
		if pad ~= nil and pad:IsA("BasePart") then
			return pad
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(0.25)
	end
end

-- ===== Lifecycle =====

function TypingRaceService.Init()
	-- Dependencies are wired via the module requires above.
end

function TypingRaceService.Start()
	-- ONE callback for the whole service lifetime, guarded by isRacing + joined.
	EquipService.OnTypeAccepted(onTypeAccepted)

	Players.PlayerRemoving:Connect(function(player)
		-- Drop leavers from the race entirely (mid-race scores included).
		joined[player] = nil
		scores[player] = nil
		lastScoredAt[player] = nil
	end)

	task.spawn(function()
		local pad = resolveRacePad()
		if pad == nil then
			warn(`[TypingRaceService] workspace.Hub.RacePad not found after ~{PAD_WAIT_SECONDS}s — typing races disabled.`)
			return
		end

		while true do
			task.wait(GameConfig.Race.IntervalSeconds)
			if pad.Parent == nil then
				warn("[TypingRaceService] RacePad was removed — typing races disabled.")
				return
			end
			local ok, err = pcall(runRace, pad)
			if not ok then
				warn("[TypingRaceService] race cycle failed: " .. tostring(err))
			end
			clearRaceState()
		end
	end)
end

return TypingRaceService
