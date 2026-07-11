--!strict
-- LeaderboardService — global "Top Earned" / "Top Collection" boards on the
-- hub, backed by two OrderedDataStores:
--   GAK_Earned_v1      key = userId, value = floor(profile.totalEarned)
--   GAK_Collection_v1  key = userId, value = sum of rarityTier^2 over the
--                      player's distinct discovered keyboards
--
-- Each server writes its online players' scores on profile load and on the
-- save cadence; the global top LeaderboardSize entries are read every
-- LeaderboardRefreshSeconds and rendered as RichText lines onto the hub's
-- EarnedBoard / CollectionBoard "List" labels (parts shipped by HubBuilder).
-- Everything DataStore-facing is pcall'ed; in Studio without API access the
-- boards say so instead of erroring.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Catalog = require(Shared.Catalog)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)

local EARNED_STORE_NAME = "GAK_Earned_v1"
local COLLECTION_STORE_NAME = "GAK_Collection_v1"
local BOARD_WAIT_SECONDS = 10 -- HubBuilder runs first; this is just slack
local UNAVAILABLE_TEXT = "Leaderboards unavailable in Studio"

local LeaderboardService = {}

local earnedStore: OrderedDataStore? = nil
local collectionStore: OrderedDataStore? = nil

local earnedList: TextLabel? = nil
local collectionList: TextLabel? = nil

-- userId -> username. GetNameFromUserIdAsync is rate-limited and names are
-- stable enough for a board; cache for the server's lifetime.
local nameCache: { [number]: string } = {}

type TopEntry = { key: string, value: number }

-- ===== Formatting =====

local function abbreviate(n: number): string
	local steps = { { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, step in steps do
		local threshold = step[1] :: number
		if n >= threshold then
			local text = string.format("%.1f", n / threshold)
			text = string.gsub(text, "%.0$", "")
			return text .. (step[2] :: string)
		end
	end
	return tostring(math.floor(n + 0.5))
end

local function escapeRichText(text: string): string
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

local function formatMoney(value: number): string
	return "$" .. abbreviate(value)
end

local function formatPoints(value: number): string
	return abbreviate(value) .. " pts"
end

-- ===== Scores =====

-- Collection score: every distinct keyboard ever found is worth its rarity
-- tier squared, so one Mythic outweighs a pile of commons.
local function collectionScore(profile: Types.Profile): number
	local score = 0
	for keyboardId, count in profile.collection do
		if count > 0 then
			local def = Catalog.GetKeyboard(keyboardId)
			if def ~= nil then
				score += def.rarityTier ^ 2
			end
		end
	end
	return math.floor(score + 0.5)
end

-- Writes both of one player's scores. Yields (SetAsync) — call from a task.
local function writeScores(player: Player)
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end
	local key = tostring(player.UserId)
	local earned = math.max(math.floor(profile.totalEarned), 0)
	local collection = collectionScore(profile)

	local eStore = earnedStore
	if eStore ~= nil then
		local ok, err = pcall(function()
			eStore:SetAsync(key, earned)
		end)
		if not ok then
			warn(`[LeaderboardService] Earned score write failed for {player.Name}: {err}`)
		end
	end
	local cStore = collectionStore
	if cStore ~= nil then
		local ok, err = pcall(function()
			cStore:SetAsync(key, collection)
		end)
		if not ok then
			warn(`[LeaderboardService] Collection score write failed for {player.Name}: {err}`)
		end
	end
end

-- ===== Reads / rendering =====

local function resolveName(userId: number): string
	local cached = nameCache[userId]
	if cached ~= nil then
		return cached
	end
	local online = Players:GetPlayerByUserId(userId)
	if online ~= nil then
		nameCache[userId] = online.Name
		return online.Name
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		nameCache[userId] = name
		return name
	end
	-- Lookup failed (throttled / offline user gone): don't cache, retry later.
	return "Player " .. tostring(userId)
end

local function fetchTop(store: OrderedDataStore): { TopEntry }?
	local ok, result = pcall(function()
		local pages = store:GetSortedAsync(false, GameConfig.LeaderboardSize)
		return pages:GetCurrentPage()
	end)
	if not ok or typeof(result) ~= "table" then
		return nil
	end
	return result :: { TopEntry }
end

local function renderBoard(label: TextLabel, top: { TopEntry }, formatValue: (number) -> string)
	local lines: { string } = {}
	for rank, entry in top do
		local userId = tonumber(entry.key)
		local name = if userId ~= nil then resolveName(userId) else tostring(entry.key)
		local value = if typeof(entry.value) == "number" then entry.value else 0
		table.insert(lines, `<b>{rank}.</b> {escapeRichText(name)} — {formatValue(value)}`)
	end
	if #lines == 0 then
		table.insert(lines, "No scores yet — go grow some keyboards!")
	end
	label.RichText = true
	label.Text = table.concat(lines, "\n")
end

local function setBoardText(text: string)
	local eLabel = earnedList
	if eLabel ~= nil then
		eLabel.RichText = false
		eLabel.Text = text
	end
	local cLabel = collectionList
	if cLabel ~= nil then
		cLabel.RichText = false
		cLabel.Text = text
	end
end

-- Boards may still be assembling when we start; poll briefly. The board part
-- (EarnedBoard/CollectionBoard) may sit directly under Workspace.Hub or be
-- nested in the hub island model, and its SurfaceGui holds the "List" label.
local function findListLabel(hub: Instance, boardName: string, deadline: number): TextLabel?
	while os.clock() < deadline do
		local board = hub:FindFirstChild(boardName) or hub:FindFirstChild(boardName, true)
		if board ~= nil then
			local list = board:FindFirstChild("List", true)
			if list ~= nil and list:IsA("TextLabel") then
				return list
			end
		end
		task.wait(0.5)
	end
	return nil
end

local function renderLoop()
	local hub = Workspace:WaitForChild("Hub", BOARD_WAIT_SECONDS)
	if hub == nil then
		warn("[LeaderboardService] workspace.Hub not found; leaderboard rendering skipped")
		return
	end

	local deadline = os.clock() + BOARD_WAIT_SECONDS
	earnedList = findListLabel(hub, "EarnedBoard", deadline)
	collectionList = findListLabel(hub, "CollectionBoard", deadline)
	if earnedList == nil and collectionList == nil then
		warn("[LeaderboardService] Hub EarnedBoard/CollectionBoard missing; leaderboard rendering skipped")
		return
	end
	if earnedList == nil or collectionList == nil then
		warn("[LeaderboardService] One hub leaderboard board is missing; rendering the other only")
	end

	if earnedStore == nil and collectionStore == nil then
		-- Init couldn't reach DataStores at all (Studio without API access).
		setBoardText(UNAVAILABLE_TEXT)
		return
	end

	local everRendered = false
	while true do
		local anyOk = false

		local eStore, eLabel = earnedStore, earnedList
		if eStore ~= nil and eLabel ~= nil then
			local top = fetchTop(eStore)
			if top ~= nil then
				renderBoard(eLabel, top, formatMoney)
				anyOk = true
			end
		end

		local cStore, cLabel = collectionStore, collectionList
		if cStore ~= nil and cLabel ~= nil then
			local top = fetchTop(cStore)
			if top ~= nil then
				renderBoard(cLabel, top, formatPoints)
				anyOk = true
			end
		end

		if anyOk then
			everRendered = true
		elseif not everRendered then
			-- Reads consistently failing before ever succeeding = no DataStore
			-- access (Studio); say so instead of leaving the boards blank.
			setBoardText(UNAVAILABLE_TEXT)
		end

		task.wait(GameConfig.LeaderboardRefreshSeconds)
	end
end

-- ===== Lifecycle =====

function LeaderboardService.Init()
	-- In Studio without API access GetOrderedDataStore itself throws — the
	-- pcall flips us into the "boards say unavailable, writes skipped" mode.
	local okEarned, earned = pcall(function()
		return DataStoreService:GetOrderedDataStore(EARNED_STORE_NAME)
	end)
	if okEarned then
		earnedStore = earned
	end
	local okCollection, collection = pcall(function()
		return DataStoreService:GetOrderedDataStore(COLLECTION_STORE_NAME)
	end)
	if okCollection then
		collectionStore = collection
	end
	if earnedStore == nil or collectionStore == nil then
		warn("[LeaderboardService] OrderedDataStores unavailable; leaderboard score writes disabled")
	end
end

function LeaderboardService.Start()
	-- Fresh score right after load (OnProfileLoaded callbacks must not yield,
	-- and SetAsync does — hence the task).
	DataService.OnProfileLoaded(function(player, _profile)
		task.spawn(writeScores, player)
	end)

	-- Save-cadence rewrite for everyone online (totalEarned/collection move
	-- constantly while playing).
	task.spawn(function()
		while true do
			task.wait(GameConfig.AutoSaveSeconds)
			for _, player in Players:GetPlayers() do
				if player.Parent ~= nil and DataService.GetProfile(player) ~= nil then
					writeScores(player)
				end
			end
		end
	end)

	task.spawn(renderLoop)
end

return LeaderboardService
