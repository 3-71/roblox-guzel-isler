--!strict
-- DataService — owns loading/saving player Profiles (the single source of
-- truth for all player state) and the DataSync replication channel.
--
-- Contract (ARCHITECTURE.md):
--   GetProfile(player) -> Types.Profile?  (nil until loaded)
--   MarkDirty(player)  -> schedule a save on the next autosave pass
--   Sync(player)       -> fire DataSync with the full profile snapshot
--   OnProfileLoaded(cb) -> subscribe; also replays already-loaded players
--   SetOfflineProcessor(fn) -> runs between raw load and OnProfileLoaded

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Remotes = require(Shared.Remotes)
local GameConfig = require(Shared.Config.GameConfig)

local KEY_PREFIX = "player_"
local LOAD_ATTEMPTS = 3
local SAVE_ATTEMPTS = 3
local BIND_TO_CLOSE_TIMEOUT = 25 -- Roblox grants ~30s; leave headroom
local OFFLINE_REPORT_DELAY = 3 -- give the client UI time to boot

type Session = {
	profile: Types.Profile,
	dirty: boolean,
	-- Set when the load ultimately failed: the player gets a fresh profile
	-- for this session, but we must never save it over their real data.
	doNotSave: boolean,
	saving: boolean,
}

local DataService = {}

local dataStore: GlobalDataStore? = nil
local sessions: { [Player]: Session } = {}
local loadedCallbacks: { (Player, Types.Profile) -> () } = {}
local offlineProcessor: ((Types.Profile) -> Types.OfflinePayload?)? = nil
local activeSaves = 0 -- in-flight UpdateAsync count, for BindToClose

local function keyFor(player: Player): string
	return KEY_PREFIX .. player.UserId
end

local function defaultProfile(): Types.Profile
	local now = os.time()
	return {
		money = GameConfig.StartingMoney,
		totalEarned = 0,
		keyboards = {},
		upgrades = {
			factoryTier = 1,
			conveyors = 1,
			speed = 0,
			luck = 0,
			storage = 0,
			displays = 0,
		},
		pads = {},
		displayed = {},
		collection = {},
		equippedUid = nil,
		lastSeen = now,
		firstJoin = now,
		rebirths = 0,
		indexClaimed = {},
		likesReceived = 0,
		passes = {},
		boosts = {},
		pity = 0,
	}
end

local function deepCopy(value: any): any
	local copy = {}
	for k, v in value :: { [any]: any } do
		copy[k] = if typeof(v) == "table" then deepCopy(v) else v
	end
	return copy
end

-- Fills any fields missing from a loaded save with defaults so schema
-- additions never crash old data. Unknown extra fields are kept as-is
-- (forward compatibility if a newer server version wrote them).
local function reconcile(data: { [any]: any }, template: { [any]: any })
	for k, templateValue in template do
		local existing = data[k]
		if existing == nil then
			data[k] = if typeof(templateValue) == "table" then deepCopy(templateValue) else templateValue
		elseif typeof(templateValue) == "table" and typeof(existing) == "table" then
			reconcile(existing, templateValue)
		end
	end
end

-- Reads raw saved data with retries + exponential backoff. First return
-- distinguishes "load definitely worked (nil = brand-new player)" from
-- "DataStore is failing" — the latter must not be treated as a wipe.
local function loadRaw(key: string): (boolean, any)
	local store = dataStore
	if store == nil then
		return true, nil -- in-memory fallback: everyone starts fresh
	end
	local backoff = 1
	for attempt = 1, LOAD_ATTEMPTS do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		warn(`[DataService] Load attempt {attempt}/{LOAD_ATTEMPTS} failed for {key}: {result}`)
		if attempt < LOAD_ATTEMPTS then
			task.wait(backoff)
			backoff *= 2
		end
	end
	return false, nil
end

local function saveSession(player: Player, session: Session, attempts: number): boolean
	local store = dataStore
	if store == nil or session.doNotSave then
		return false
	end
	-- Serialize saves per player so two UpdateAsync calls (autosave vs
	-- leave-save vs shutdown flush) never race on the same key.
	while session.saving do
		task.wait(0.1)
	end
	session.saving = true
	activeSaves += 1

	session.profile.lastSeen = os.time()
	local key = keyFor(player)
	local backoff = 1
	local saved = false
	for attempt = 1, attempts do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function()
				return session.profile
			end)
		end)
		if ok then
			saved = true
			break
		end
		warn(`[DataService] Save attempt {attempt}/{attempts} failed for {key}: {err}`)
		if attempt < attempts then
			task.wait(backoff)
			backoff *= 2
		end
	end
	if saved then
		session.dirty = false
	end

	session.saving = false
	activeSaves -= 1
	return saved
end

local function loadPlayer(player: Player)
	local ok, raw = loadRaw(keyFor(player))

	local profile: Types.Profile
	local doNotSave = false
	if not ok then
		-- DataStore outage: let the player play on a fresh profile, but never
		-- write it back — otherwise an outage would wipe real progress.
		profile = defaultProfile()
		doNotSave = true
		task.delay(OFFLINE_REPORT_DELAY, function()
			if player.Parent ~= nil then
				Remotes.Notify:FireClient(player, "error", "Data failed to load — this session will NOT be saved.")
			end
		end)
	elseif typeof(raw) == "table" then
		reconcile(raw, defaultProfile() :: any)
		profile = (raw :: any) :: Types.Profile
	else
		profile = defaultProfile()
	end

	if player.Parent == nil then
		return -- left while we were loading; nothing to keep or save
	end

	local session: Session = {
		profile = profile,
		dirty = true, -- persist firstJoin (and offline output) on first autosave
		doNotSave = doNotSave,
		saving = false,
	}
	sessions[player] = session

	-- Offline production mutates the profile BEFORE any subscriber sees it,
	-- so everything downstream (plot, displays, HUD) starts consistent.
	local payload: Types.OfflinePayload? = nil
	local processor = offlineProcessor
	if processor ~= nil then
		local processorOk, result = pcall(processor, profile)
		if processorOk then
			payload = result
		else
			warn(`[DataService] Offline processor failed for {player.Name}: {result}`)
		end
	end

	for _, callback in loadedCallbacks do
		local cbOk, cbErr = pcall(callback, player, profile)
		if not cbOk then
			warn(`[DataService] OnProfileLoaded callback failed for {player.Name}: {cbErr}`)
		end
	end

	DataService.Sync(player)

	if payload ~= nil then
		local report = payload
		task.delay(OFFLINE_REPORT_DELAY, function()
			if player.Parent ~= nil then
				Remotes.OfflineReport:FireClient(player, report)
			end
		end)
	end
end

-- ===== Public API =====

function DataService.GetProfile(player: Player): Types.Profile?
	local session = sessions[player]
	return if session ~= nil then session.profile else nil
end

function DataService.MarkDirty(player: Player)
	local session = sessions[player]
	if session ~= nil then
		session.dirty = true
	end
end

function DataService.Sync(player: Player)
	local session = sessions[player]
	if session ~= nil then
		-- The profile is plain data (numbers/strings/bools/tables), so it can
		-- be fired directly as the snapshot.
		Remotes.DataSync:FireClient(player, session.profile)
	end
end

function DataService.OnProfileLoaded(callback: (Player, Types.Profile) -> ())
	table.insert(loadedCallbacks, callback)
	-- Late subscribers still hear about players that loaded before them.
	for player, session in sessions do
		local ok, err = pcall(callback, player, session.profile)
		if not ok then
			warn(`[DataService] OnProfileLoaded replay failed for {player.Name}: {err}`)
		end
	end
end

function DataService.SetOfflineProcessor(fn: (Types.Profile) -> Types.OfflinePayload?)
	offlineProcessor = fn
end

-- ===== Lifecycle =====

function DataService.Init()
	-- In Studio without API access GetDataStore itself throws — pcall flips
	-- us into the in-memory fallback: profiles work, saves are skipped.
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStoreName)
	end)
	if ok then
		dataStore = result
	else
		warn(`[DataService] DataStores unavailable ({result}); using in-memory profiles`)
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session == nil then
			return
		end
		-- Drop the session first so the autosave pass can't double-write it.
		sessions[player] = nil
		saveSession(player, session, SAVE_ATTEMPTS)
	end)

	-- Autosave loop: only dirty sessions, snapshotted first because
	-- saveSession yields and sessions may gain/lose entries meanwhile.
	task.spawn(function()
		while true do
			task.wait(GameConfig.AutoSaveSeconds)
			local toSave: { { player: Player, session: Session } } = {}
			for player, session in sessions do
				if session.dirty then
					table.insert(toSave, { player = player, session = session })
				end
			end
			for _, entry in toSave do
				if sessions[entry.player] == entry.session then
					saveSession(entry.player, entry.session, 1)
				end
			end
		end
	end)

	game:BindToClose(function()
		if dataStore == nil then
			return -- in-memory mode: nothing to flush, shut down fast
		end
		-- Flush every remaining session. PlayerRemoving fires on shutdown
		-- too, so this mostly guarantees we WAIT for those in-flight saves
		-- (activeSaves) instead of letting the server kill them.
		for player, session in sessions do
			task.spawn(saveSession, player, session, SAVE_ATTEMPTS)
		end
		local deadline = os.clock() + BIND_TO_CLOSE_TIMEOUT
		task.wait(0.1)
		while activeSaves > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

return DataService
