--!strict
-- EventService — server-wide luck/mutation "weather" events. Publishes the
-- active event as Workspace attributes so every reader (production, offline,
-- client odds panel, lighting) pulls from one place:
--   ActiveEventId: string ("" = none), ActiveEventUntil: number (unix)
--
-- Events start two ways: the random weather loop, or ForceEvent (Harmony
-- obelisk reward). A generation counter lets a forced event replace a
-- running one cleanly — the older event's scheduled end becomes a no-op.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Events = require(Shared.Config.Events)
local Remotes = require(Shared.Remotes)

local EventService = {}

local rng = Random.new()
local active: typeof(Events[1])? = nil
local generation = 0

local function pickEvent(): typeof(Events[1])
	local totalWeight = 0
	for _, event in Events do
		totalWeight += event.weight
	end
	local roll = rng:NextNumber() * totalWeight
	local cumulative = 0
	for _, event in Events do
		cumulative += event.weight
		if roll <= cumulative then
			return event
		end
	end
	return Events[1]
end

local function startEvent(event: typeof(Events[1]))
	generation += 1
	local myGeneration = generation
	active = event
	workspace:SetAttribute("ActiveEventId", event.id)
	workspace:SetAttribute("ActiveEventUntil", os.time() + event.duration)
	Remotes.Notify:FireAllClients("event", event.name .. " — " .. event.tagline)

	task.delay(event.duration, function()
		if generation ~= myGeneration then
			return -- a newer event replaced this one; its own timer rules
		end
		active = nil
		workspace:SetAttribute("ActiveEventId", "")
		workspace:SetAttribute("ActiveEventUntil", 0)
		Remotes.Notify:FireAllClients("info", event.name .. " has ended.")
	end)
end

function EventService.GetActive(): typeof(Events[1])?
	if active ~= nil then
		local expiry = workspace:GetAttribute("ActiveEventUntil")
		if typeof(expiry) == "number" and expiry > os.time() then
			return active
		end
	end
	return nil
end

-- Starts the given event immediately (HarmonyService reward). Returns false
-- for unknown ids. Replaces any running event.
function EventService.ForceEvent(eventId: string): boolean
	for _, event in Events do
		if event.id == eventId then
			startEvent(event)
			return true
		end
	end
	return false
end

function EventService.Init()
	workspace:SetAttribute("ActiveEventId", "")
	workspace:SetAttribute("ActiveEventUntil", 0)
end

function EventService.Start()
	task.spawn(function()
		while true do
			task.wait(rng:NextInteger(GameConfig.EventMinInterval, GameConfig.EventMaxInterval))
			-- Never stomp a still-running (possibly forced) event.
			if EventService.GetActive() == nil then
				startEvent(pickEvent())
			end
		end
	end)
end

return EventService
