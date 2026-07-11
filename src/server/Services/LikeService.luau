--!strict
-- LikeService — visitors hold a ProximityPrompt on a plot's sign to "like"
-- the farm. One like per (liker, owner) pair per server session; the count
-- persists on the owner's profile (likesReceived) and shows on the sign via
-- PlotBuilder.SetSignInfo.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local PlotBuilder = require(script.Parent.Parent.World.PlotBuilder)

local PLOT_WAIT_SECONDS = 15 -- plot builds on the same OnProfileLoaded event
local PROMPT_NAME = "LikePrompt"

local LikeService = {}

-- liker -> set of owners already liked this server session. Entries are
-- cleared when either side leaves, so a rejoin allows a fresh like.
local likedOwners: { [Player]: { [Player]: boolean } } = {}
local warnedNoSignHelper = false

-- Sign text refresh is shipped by the world builder; pcall so a missing or
-- failing helper never blocks the like itself.
local function refreshSign(owner: Player, profile: Types.Profile)
	local plot = PlotService.GetPlot(owner)
	if plot == nil then
		return
	end
	local setSignInfo = (PlotBuilder :: any).SetSignInfo
	local ok = pcall(setSignInfo, plot, owner.DisplayName, profile.likesReceived, profile.passes.vip == true)
	if not ok and not warnedNoSignHelper then
		warnedNoSignHelper = true
		warn("[LikeService] PlotBuilder.SetSignInfo unavailable/failed; sign like counts will not refresh")
	end
end

local function onLike(liker: Player, owner: Player)
	if liker == owner then
		return -- your own farm doesn't count
	end
	if liker.Parent == nil or owner.Parent == nil then
		return
	end
	local profile = DataService.GetProfile(owner)
	if profile == nil then
		return
	end

	local set = likedOwners[liker]
	if set ~= nil and set[owner] then
		Remotes.Notify:FireClient(liker, "error", "You already liked this farm!")
		return
	end
	if set == nil then
		set = {}
		likedOwners[liker] = set
	end
	set[owner] = true

	profile.likesReceived += 1
	DataService.MarkDirty(owner)
	DataService.Sync(owner)

	Remotes.Notify:FireClient(owner, "info", liker.Name .. " liked your farm! ❤")
	Remotes.Notify:FireClient(liker, "info", "You liked " .. owner.DisplayName .. "'s farm!")
	refreshSign(owner, profile)
end

local function findSignPart(plot: Model): BasePart?
	local sign = plot:FindFirstChild("Sign")
	if sign == nil then
		return nil
	end
	local board = sign:FindFirstChild("SignBoard", true)
	if board ~= nil and board:IsA("BasePart") then
		return board
	end
	return sign:FindFirstChildWhichIsA("BasePart", true)
end

local watchPlot: (owner: Player) -> ()

local function attachPrompt(owner: Player, plot: Model)
	local signPart = findSignPart(plot)
	if signPart == nil then
		warn(`[LikeService] Plot for {owner.Name} has no Sign part; like prompt skipped`)
		return
	end
	if signPart:FindFirstChild(PROMPT_NAME) ~= nil then
		return -- replay safety: already wired
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Like this farm!"
	prompt.ObjectText = owner.DisplayName
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 12
	prompt.Triggered:Connect(function(byPlayer: Player)
		onLike(byPlayer, owner)
	end)

	-- Plot rebuilds (rebirth) destroy the prompt with the old plot; re-poll
	-- so the fresh sign gets one too.
	prompt.Destroying:Connect(function()
		if owner.Parent ~= nil then
			task.defer(watchPlot, owner)
		end
	end)

	prompt.Parent = signPart
end

-- The plot builds on the same OnProfileLoaded event we subscribe to, so poll
-- briefly rather than racing it (same pattern as ShowcaseService).
watchPlot = function(owner: Player)
	task.spawn(function()
		local deadline = os.clock() + PLOT_WAIT_SECONDS
		while os.clock() < deadline and owner.Parent ~= nil do
			local plot = PlotService.GetPlot(owner)
			local profile = DataService.GetProfile(owner)
			if plot ~= nil and profile ~= nil then
				attachPrompt(owner, plot)
				-- Persisted like counts show on the sign right away.
				refreshSign(owner, profile)
				return
			end
			task.wait(0.5)
		end
	end)
end

-- ===== Lifecycle =====

function LikeService.Init() end

function LikeService.Start()
	DataService.OnProfileLoaded(function(player, _profile)
		watchPlot(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		likedOwners[player] = nil
		for _, set in likedOwners do
			set[player] = nil
		end
	end)
end

return LikeService
