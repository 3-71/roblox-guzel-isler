--!strict
-- EventController — client-side presentation for server-wide events.
-- Watches the Workspace attributes EventService publishes (ActiveEventId /
-- ActiveEventUntil), shows a full-width banner under the money HUD with a
-- live countdown, and applies a Lighting preset per the event's `sky`
-- ("storm" / "golden" / "frost" / "static" / "overclock"). Every Lighting
-- property is snapshotted before it is touched and restored exactly when the
-- event ends. Handles joining mid-event and one event replacing another
-- while active. "static" and "overclock" additionally drive a controller-
-- owned ColorCorrectionEffect (created on demand, destroyed on restore);
-- "static" runs a subtle flicker task killed via the session counter, the
-- same way the storm thunder task is.

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

-- controller-owned ColorCorrectionEffect for the "static"/"overclock" skies.
-- We create it ourselves (so there is nothing to snapshot): tween to the
-- preset's goals on apply, tween back to neutral and destroy on restore.
local colorCorrection: ColorCorrectionEffect? = nil

-- exact pre-event value of every Lighting property we've touched
local lightingSnapshot: { [string]: any } = {}
-- same, for the hub's Atmosphere child: with an Atmosphere instance present
-- the engine IGNORES classic FogColor/FogEnd, so storm/golden moods must be
-- driven through Atmosphere properties instead (the fog goals below stay as
-- a fallback for places without the Atmosphere).
local atmosphereSnapshot: { [string]: any } = {}

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
	elseif sky == "frost" then
		-- Cold Snap: pale icy blue, dense BRIGHT haze (fog goals are the
		-- fallback for places without an Atmosphere child)
		return {
			Ambient = Color3.fromRGB(140, 168, 196),
			OutdoorAmbient = Color3.fromRGB(158, 186, 214),
			FogColor = Color3.fromRGB(210, 232, 250),
			FogEnd = 320,
		}
	elseif sky == "static" then
		-- Static Surge: dark green-black glitch mood
		return {
			Ambient = Color3.fromRGB(30, 46, 34),
			OutdoorAmbient = Color3.fromRGB(38, 58, 42),
			FogColor = Color3.fromRGB(12, 24, 16),
			FogEnd = 360,
		}
	elseif sky == "overclock" then
		-- Overclocked: hot orange heat-haze
		return {
			Ambient = Color3.fromRGB(172, 108, 56),
			OutdoorAmbient = Color3.fromRGB(190, 122, 62),
			FogColor = Color3.fromRGB(120, 52, 20),
			FogEnd = 600,
		}
	end
	return {}
end

local function atmospherePresetGoals(sky: string): { [string]: any }
	if sky == "storm" then
		return {
			Density = 0.42,
			Color = Color3.fromRGB(140, 148, 178),
			Decay = Color3.fromRGB(24, 30, 56),
			Haze = 2.6,
			Glare = 0,
		}
	elseif sky == "golden" then
		return {
			Color = Color3.fromRGB(226, 186, 128),
			Haze = 1.8,
			Glare = 0.32,
		}
	elseif sky == "frost" then
		return {
			Density = 0.5,
			Color = Color3.fromRGB(214, 236, 252),
			Decay = Color3.fromRGB(170, 205, 235),
			Haze = 3.2,
			Glare = 0.12,
		}
	elseif sky == "static" then
		return {
			Density = 0.44,
			Color = Color3.fromRGB(78, 112, 84),
			Decay = Color3.fromRGB(10, 22, 14),
			Haze = 2.4,
			Glare = 0,
		}
	elseif sky == "overclock" then
		return {
			Color = Color3.fromRGB(255, 158, 84),
			Haze = 2,
			Glare = 0.42,
		}
	end
	return {}
end

-- Goals for the controller-owned ColorCorrectionEffect. Only "static" and
-- "overclock" use it; every other sky tweens it back to neutral (see
-- CC_NEUTRAL) so one event can replace another cleanly.
local CC_NEUTRAL: { [string]: any } = {
	Brightness = 0,
	Contrast = 0,
	Saturation = 0,
	TintColor = Color3.fromRGB(255, 255, 255),
}

local function colorCorrectionGoals(sky: string): { [string]: any }
	if sky == "static" then
		-- washed-out green shift; the flicker task adds the glitch pops
		return {
			Saturation = -0.3,
			Contrast = 0.15,
			TintColor = Color3.fromRGB(205, 245, 215),
		}
	elseif sky == "overclock" then
		-- slight saturation push + warm tint
		return {
			Saturation = 0.25,
			Contrast = 0.08,
			TintColor = Color3.fromRGB(255, 234, 214),
		}
	end
	return {}
end

local function ensureColorCorrection(): ColorCorrectionEffect
	local existing = colorCorrection
	if existing and existing.Parent then
		return existing
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "EventColorCorrection"
	cc.Brightness = 0
	cc.Contrast = 0
	cc.Saturation = 0
	cc.TintColor = Color3.fromRGB(255, 255, 255)
	cc.Parent = Lighting
	colorCorrection = cc
	return cc
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

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		local atmosphereGoals = atmospherePresetGoals(def.sky)
		for prop in atmosphereGoals do
			if atmosphereSnapshot[prop] == nil then
				atmosphereSnapshot[prop] = (atmosphere :: any)[prop]
			end
		end
		local combinedAtmosphere: { [string]: any } = table.clone(atmosphereGoals)
		for prop, original in atmosphereSnapshot do
			if combinedAtmosphere[prop] == nil then
				combinedAtmosphere[prop] = original
			end
		end
		TweenService:Create(atmosphere, TRANSITION_INFO, combinedAtmosphere):Play()
	end

	local ccGoals = colorCorrectionGoals(def.sky)
	if next(ccGoals) ~= nil then
		-- unset props tween to neutral so a preceding preset's values clear
		local combinedCC: { [string]: any } = table.clone(CC_NEUTRAL)
		for prop, value in ccGoals do
			combinedCC[prop] = value
		end
		TweenService:Create(ensureColorCorrection(), TRANSITION_INFO, combinedCC):Play()
	elseif colorCorrection and colorCorrection.Parent then
		-- this sky doesn't use color correction; fade any leftover to neutral
		TweenService:Create(colorCorrection, TRANSITION_INFO, table.clone(CC_NEUTRAL)):Play()
	end
end

local function restoreLighting()
	if next(lightingSnapshot) == nil and next(atmosphereSnapshot) == nil then
		return
	end
	local goals: { [string]: any } = table.clone(lightingSnapshot)
	TweenService:Create(Lighting, TRANSITION_INFO, goals):Play()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmosphereGoals: { [string]: any } = table.clone(atmosphereSnapshot)
	if atmosphere and next(atmosphereGoals) ~= nil then
		TweenService:Create(atmosphere, TRANSITION_INFO, atmosphereGoals):Play()
	end
	if colorCorrection and colorCorrection.Parent then
		TweenService:Create(colorCorrection, TRANSITION_INFO, table.clone(CC_NEUTRAL)):Play()
	end
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
		if atmosphere and atmosphere.Parent then
			for prop, value in atmosphereGoals do
				(atmosphere :: any)[prop] = value
			end
		end
		if colorCorrection then
			colorCorrection:Destroy()
			colorCorrection = nil
		end
		table.clear(lightingSnapshot)
		table.clear(atmosphereSnapshot)
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

-- ===== static flicker ("static" preset) =====

-- Subtle glitchy brightness pops on the controller-owned ColorCorrection.
-- Same lifecycle as thunderLoop: spawned per event, killed when the session
-- counter bumps. Writes only Brightness, which no preset tweens after the
-- initial 2s transition (the first wait always outlasts it).
local function flickerLoop(mySession: number)
	while session == mySession do
		task.wait(rng:NextNumber(2.2, 5))
		if session ~= mySession then
			break
		end
		local cc = colorCorrection
		if cc == nil or cc.Parent == nil then
			continue -- effect not built yet (transition edge); retry next pass
		end
		for _ = 1, rng:NextInteger(2, 4) do
			cc.Brightness = rng:NextNumber(0.03, 0.09)
			task.wait(rng:NextNumber(0.03, 0.08))
			if session ~= mySession or cc.Parent == nil then
				break
			end
			cc.Brightness = 0
			task.wait(rng:NextNumber(0.05, 0.12))
			if session ~= mySession or cc.Parent == nil then
				break
			end
		end
		if cc.Parent ~= nil then
			cc.Brightness = 0
		end
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
		elseif def.sky == "static" then
			task.spawn(flickerLoop, session)
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
