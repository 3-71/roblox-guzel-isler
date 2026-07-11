--!strict
-- EventController — client-side presentation for server-wide events.
-- Watches the Workspace attributes EventService publishes (ActiveEventId /
-- ActiveEventUntil), shows a full-width banner under the money HUD with a
-- live countdown, and applies a Lighting preset per the event's `sky`
-- ("storm" / "golden"). Every Lighting property is snapshotted before it is
-- touched and restored exactly when the event ends. Handles joining
-- mid-event and one event replacing another while active.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Events = require(Shared:WaitForChild("Config"):WaitForChild("Events"))

local EventController = {}

local localPlayer = Players.LocalPlayer

local INK = Color3.fromRGB(24, 26, 34) -- dark text on the colored banner

local TRANSITION_SECONDS = 2
local TRANSITION_INFO = TweenInfo.new(TRANSITION_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BANNER_Y = 92 -- just below the money HUD + boost pills
local BANNER_HIDDEN_Y = -70
local THUNDER_SOUND = "rbxasset://sounds/action_jump_land.mp3"

local rng = Random.new()

local screenGui: ScreenGui
local banner: Frame
local nameLabel: TextLabel
local taglineLabel: TextLabel
local countdownLabel: TextLabel

-- bumped on every state change; kills stale countdown/thunder/restore tasks
local session = 0
local activeEventId: string? = nil
local bannerShown = false

-- exact pre-event value of every Lighting property we've touched
local lightingSnapshot: { [string]: any } = {}

-- ===== helpers =====

local function findEvent(id: string): typeof(Events[1])?
	for _, event in Events do
		if event.id == id then
			return event
		end
	end
	return nil
end

local function formatClock(seconds: number): string
	seconds = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- ===== lighting presets =====

local function presetGoals(sky: string): { [string]: any }
	if sky == "storm" then
		return {
			Ambient = Color3.fromRGB(48, 52, 72),
			OutdoorAmbient = Color3.fromRGB(58, 62, 88),
			FogColor = Color3.fromRGB(24, 30, 56),
			FogEnd = 400,
		}
	elseif sky == "golden" then
		return {
			Ambient = Color3.fromRGB(150, 118, 72),
			OutdoorAmbient = Color3.fromRGB(168, 132, 86),
			ClockTime = 17,
		}
	end
	return {}
end

local function applyLighting(def: typeof(Events[1]))
	local goals = presetGoals(def.sky)
	-- snapshot anything we haven't touched yet (never overwrite an original)
	for prop in goals do
		if lightingSnapshot[prop] == nil then
			lightingSnapshot[prop] = (Lighting :: any)[prop]
		end
	end
	-- if a previous event touched properties this one doesn't, tween those
	-- back to their originals in the same transition
	local combined: { [string]: any } = table.clone(goals)
	for prop, original in lightingSnapshot do
		if combined[prop] == nil then
			combined[prop] = original
		end
	end
	TweenService:Create(Lighting, TRANSITION_INFO, combined):Play()
end

local function restoreLighting()
	if next(lightingSnapshot) == nil then
		return
	end
	local goals: { [string]: any } = table.clone(lightingSnapshot)
	TweenService:Create(Lighting, TRANSITION_INFO, goals):Play()
	local mySession = session
	task.delay(TRANSITION_SECONDS + 0.1, function()
		-- only finalize if no new event started while we were restoring;
		-- otherwise the snapshot (still holding the originals) stays live
		if session ~= mySession then
			return
		end
		for prop, value in goals do
			(Lighting :: any)[prop] = value
		end
		table.clear(lightingSnapshot)
	end)
end

-- ===== thunder (storm preset) =====

local function thunderLoop(mySession: number)
	while session == mySession do
		task.wait(rng:NextInteger(15, 30))
		if session ~= mySession then
			break
		end
		local sound = Instance.new("Sound")
		sound.SoundId = THUNDER_SOUND
		sound.PlaybackSpeed = 0.3
		sound.Volume = 0.5
		sound.Parent = SoundService
		sound:Play()
		Debris:AddItem(sound, 10)
	end
end

-- ===== banner =====

local function buildBanner()
	banner = Instance.new("Frame")
	banner.Name = "EventBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, BANNER_HIDDEN_Y)
	banner.Size = UDim2.new(1, -20, 0, 56)
	banner.BorderSizePixel = 0
	banner.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
	banner.BackgroundTransparency = 0.06
	banner.Visible = false
	banner.Parent = screenGui
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, 14)
	uiCorner.Parent = banner
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = INK
	uiStroke.Thickness = 2
	uiStroke.Transparency = 0.5
	uiStroke.Parent = banner

	local function label(props: { [string]: any }): TextLabel
		local t = Instance.new("TextLabel")
		t.BorderSizePixel = 0
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = INK
		t.TextScaled = true
		for k, v in props do
			(t :: any)[k] = v
		end
		t.Parent = banner
		return t
	end

	nameLabel = label({
		Position = UDim2.fromOffset(16, 4),
		Size = UDim2.new(0, 260, 1, -8),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	countdownLabel = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 4),
		Size = UDim2.new(0, 96, 1, -8),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	taglineLabel = label({
		Position = UDim2.fromOffset(284, 8),
		Size = UDim2.new(1, -404, 1, -16),
		Text = "",
		TextWrapped = true,
		TextTransparency = 0.2,
	})
end

local function showBanner(def: typeof(Events[1]))
	banner.BackgroundColor3 = def.color
	nameLabel.Text = def.name
	taglineLabel.Text = def.tagline
	countdownLabel.Text = ""
	banner.Visible = true
	if not bannerShown then
		bannerShown = true
		banner.Position = UDim2.new(0.5, 0, 0, BANNER_HIDDEN_Y)
		TweenService:Create(banner, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0, BANNER_Y),
		}):Play()
	end
end

local function hideBanner()
	if not bannerShown then
		return
	end
	bannerShown = false
	local mySession = session
	TweenService:Create(banner, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0.5, 0, 0, BANNER_HIDDEN_Y),
	}):Play()
	task.delay(0.45, function()
		if session == mySession then
			banner.Visible = false
		end
	end)
end

-- ===== state machine =====

local recheck: () -> ()

local function countdownLoop(mySession: number)
	while session == mySession do
		local untilAttr = workspace:GetAttribute("ActiveEventUntil")
		local remaining = if typeof(untilAttr) == "number" then untilAttr - os.time() else 0
		countdownLabel.Text = formatClock(remaining)
		if remaining <= 0 then
			-- safety: end locally even if the attribute-clear signal is late
			recheck()
			break
		end
		task.wait(0.5)
	end
end

recheck = function()
	local id = workspace:GetAttribute("ActiveEventId")
	local untilTime = workspace:GetAttribute("ActiveEventUntil")
	local def: typeof(Events[1])? = nil
	if typeof(id) == "string" and id ~= "" and typeof(untilTime) == "number" and untilTime > os.time() then
		def = findEvent(id)
	end

	if def then
		if activeEventId == def.id then
			return -- same event, nothing to change
		end
		activeEventId = def.id
		session += 1
		applyLighting(def)
		showBanner(def)
		task.spawn(countdownLoop, session)
		if def.sky == "storm" then
			task.spawn(thunderLoop, session)
		end
	else
		if activeEventId == nil then
			return
		end
		activeEventId = nil
		session += 1
		hideBanner()
		restoreLighting()
	end
end

function EventController.Start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "EventUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	buildBanner()

	workspace:GetAttributeChangedSignal("ActiveEventId"):Connect(recheck)
	workspace:GetAttributeChangedSignal("ActiveEventUntil"):Connect(recheck)
	recheck() -- handle joining mid-event
end

return EventController
