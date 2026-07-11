--!strict
-- RaceController — renders the hub typing race from RaceState payloads:
--   "joining"  -> banner with live join countdown
--   "racing"   -> compact top-right scoreboard (top 5) + countdown
--   "finished" -> podium toast (top 3, gold/silver/bronze) for 6s
--   "idle"     -> remove everything
-- All UI procedural, in its own ScreenGui, matching the game's cozy styling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local RaceController = {}

local localPlayer = Players.LocalPlayer

local PANEL_BG = Color3.fromRGB(38, 41, 50)
local PANEL_BG2 = Color3.fromRGB(50, 54, 66)
local TEXT_MAIN = Color3.fromRGB(245, 246, 250)
local TEXT_DIM = Color3.fromRGB(170, 175, 190)
local GOLD = Color3.fromRGB(255, 205, 90)

local MEDALS = {
	{ emoji = "🥇", color = Color3.fromRGB(255, 215, 0) },
	{ emoji = "🥈", color = Color3.fromRGB(192, 192, 192) },
	{ emoji = "🥉", color = Color3.fromRGB(205, 127, 50) },
}

type ScoreEntry = { name: string, score: number }

local screenGui: ScreenGui
local session = 0 -- bumped on every phase change; kills stale countdown loops
local currentPhase = "idle"
local joinBanner: Frame? = nil
local scoreboard: Frame? = nil
local podium: Frame? = nil
local raceEndsAt = 0

-- ===== tiny UI helpers (mirrors UIController's patterns) =====

local function corner(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function stroke(inst: Instance, color: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = inst
	return s
end

local function mkFrame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = PANEL_BG
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

local function mkText(parent: Instance, props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BorderSizePixel = 0
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextColor3 = TEXT_MAIN
	t.TextScaled = true
	for k, v in props do
		(t :: any)[k] = v
	end
	t.Parent = parent
	return t
end

local function sanitizeScores(raw: any): { ScoreEntry }
	local out: { ScoreEntry } = {}
	if typeof(raw) == "table" then
		for _, entry in raw :: { any } do
			if typeof(entry) == "table" and typeof(entry.name) == "string" and typeof(entry.score) == "number" then
				table.insert(out, { name = entry.name, score = entry.score })
			end
		end
	end
	return out
end

local function clearAll()
	session += 1
	currentPhase = "idle"
	if joinBanner then
		joinBanner:Destroy()
		joinBanner = nil
	end
	if scoreboard then
		scoreboard:Destroy()
		scoreboard = nil
	end
	if podium then
		podium:Destroy()
		podium = nil
	end
end

-- ===== joining banner =====

local function showJoining(endsAt: number)
	clearAll()
	currentPhase = "joining"
	local mySession = session

	local banner = mkFrame(screenGui, {
		Name = "RaceJoinBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -60),
		Size = UDim2.fromOffset(560, 46),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.06,
	})
	corner(banner, 12)
	stroke(banner, GOLD, 2)
	joinBanner = banner

	local label = mkText(banner, {
		Position = UDim2.fromOffset(10, 5),
		Size = UDim2.new(1, -20, 1, -10),
		Text = "⌨ TYPING RACE starting — get on the race pad!",
		TextColor3 = GOLD,
	})
	TweenService:Create(banner, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 152),
	}):Play()

	task.spawn(function()
		while session == mySession and banner.Parent do
			local remaining = math.max(endsAt - os.time(), 0)
			label.Text = `⌨ TYPING RACE starting — get on the race pad! ({remaining}s)`
			task.wait(0.25)
		end
	end)
end

-- ===== racing scoreboard =====

local function renderScores(entries: { ScoreEntry })
	local board = scoreboard
	if not board then
		return
	end
	local rows = board:FindFirstChild("Rows") :: Frame
	for _, child in rows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i, entry in entries do
		if i > 5 then
			break
		end
		local isMe = entry.name == localPlayer.Name
		local color = if isMe then GOLD else TEXT_MAIN
		local row = mkFrame(rows, {
			Size = UDim2.new(1, 0, 0, 26),
			LayoutOrder = i,
			BackgroundColor3 = Color3.fromRGB(80, 65, 20),
			BackgroundTransparency = if isMe then 0.35 else 1,
		})
		corner(row, 8)
		mkText(row, {
			Position = UDim2.fromOffset(6, 2),
			Size = UDim2.fromOffset(22, 22),
			Text = tostring(i),
			TextScaled = false,
			TextSize = 14,
			TextColor3 = if isMe then GOLD else TEXT_DIM,
		})
		mkText(row, {
			Position = UDim2.fromOffset(30, 2),
			Size = UDim2.new(1, -92, 0, 22),
			Text = entry.name,
			TextScaled = false,
			TextSize = 14,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		mkText(row, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 2),
			Size = UDim2.fromOffset(52, 22),
			Text = string.format("%.1f", entry.score),
			TextScaled = false,
			TextSize = 14,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end
end

local function showRacing(endsAt: number, entries: { ScoreEntry })
	raceEndsAt = endsAt
	if currentPhase ~= "racing" or scoreboard == nil then
		clearAll()
		currentPhase = "racing"
		local mySession = session

		local board = mkFrame(screenGui, {
			Name = "RaceScoreboard",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 150),
			Size = UDim2.fromOffset(240, 190),
			BackgroundColor3 = PANEL_BG,
			BackgroundTransparency = 0.06,
		})
		corner(board, 12)
		stroke(board, PANEL_BG2, 2)
		scoreboard = board

		mkText(board, {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.fromOffset(120, 26),
			Text = "⌨ RACE",
			TextColor3 = GOLD,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local timer = mkText(board, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 6),
			Size = UDim2.fromOffset(80, 26),
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		local rows = mkFrame(board, {
			Name = "Rows",
			Position = UDim2.fromOffset(8, 38),
			Size = UDim2.new(1, -16, 1, -46),
			BackgroundTransparency = 1,
		})
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 3)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = rows

		task.spawn(function()
			while session == mySession and board.Parent do
				local remaining = math.max(raceEndsAt - os.time(), 0)
				timer.Text = `{remaining}s`
				task.wait(0.25)
			end
		end)
	end
	renderScores(entries)
end

-- ===== podium =====

local function showFinished(entries: { ScoreEntry })
	clearAll()
	currentPhase = "finished"
	local shown = math.min(#entries, 3)
	local height = 56 + math.max(shown, 1) * 40 + 12

	local card = mkFrame(screenGui, {
		Name = "RacePodium",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.04,
		ClipsDescendants = true,
	})
	corner(card, 14)
	stroke(card, GOLD, 2)
	podium = card

	mkText(card, {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 34),
		Text = "🏁 TYPING RACE — RESULTS",
		TextColor3 = GOLD,
	})
	if shown == 0 then
		mkText(card, {
			Position = UDim2.fromOffset(10, 56),
			Size = UDim2.new(1, -20, 0, 34),
			Text = "Nobody scored this time 😅",
			TextColor3 = TEXT_DIM,
		})
	end
	for i = 1, shown do
		local entry = entries[i]
		local medal = MEDALS[i]
		local row = mkFrame(card, {
			Position = UDim2.fromOffset(12, 56 + (i - 1) * 40),
			Size = UDim2.new(1, -24, 0, 34),
			BackgroundColor3 = PANEL_BG2,
		})
		corner(row, 10)
		mkText(row, {
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -80, 0, 26),
			Text = `{medal.emoji} {entry.name}`,
			TextColor3 = medal.color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		mkText(row, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 4),
			Size = UDim2.fromOffset(64, 26),
			Text = string.format("%.1f", entry.score),
			TextColor3 = medal.color,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end

	TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(330, height),
	}):Play()

	task.delay(6, function()
		if card.Parent then
			card:Destroy()
		end
		if podium == card then
			podium = nil
		end
	end)
end

-- ===== wiring =====

function RaceController.Start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaceUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	Remotes.RaceState.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.phase) ~= "string" then
			return
		end
		local phase = payload.phase :: string
		if phase == "joining" and typeof(payload.endsAt) == "number" then
			showJoining(payload.endsAt)
		elseif phase == "racing" and typeof(payload.endsAt) == "number" then
			showRacing(payload.endsAt, sanitizeScores(payload.scores))
		elseif phase == "finished" then
			showFinished(sanitizeScores(payload.scores))
		elseif phase == "idle" then
			clearAll()
		end
	end)
end

return RaceController
