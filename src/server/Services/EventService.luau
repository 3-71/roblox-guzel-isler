--!strict
-- EventService — server-wide luck/mutation "weather" events. Publishes the
-- active event as Workspace attributes so every reader (production, offline,
-- client odds panel, lighting) pulls from one place:
--   ActiveEventId: string ("" = none), ActiveEventUntil: number (unix)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Events = require(Shared.Config.Events)
local Remotes = require(Shared.Remotes)

local EventService = {}

local rng = Random.new()
local active: typeof(Events[1])? = nil

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

function EventService.GetActive(): typeof(Events[1])?
	if active ~= nil then
		local expiry = workspace:GetAttribute("ActiveEventUntil")
		if typeof(expiry) == "number" and expiry > os.time() then
			return active
		end
	end
	return nil
end

function EventService.Init()
	workspace:SetAttribute("ActiveEventId", "")
	workspace:SetAttribute("ActiveEventUntil", 0)
end

function EventService.Start()
	task.spawn(function()
		while true do
			task.wait(rng:NextInteger(GameConfig.EventMinInterval, GameConfig.EventMaxInterval))

			local event = pickEvent()
			active = event
			workspace:SetAttribute("ActiveEventId", event.id)
			workspace:SetAttribute("ActiveEventUntil", os.time() + event.duration)
			Remotes.Notify:FireAllClients("event", event.name .. " — " .. event.tagline)

			task.wait(event.duration)

			active = nil
			workspace:SetAttribute("ActiveEventId", "")
			workspace:SetAttribute("ActiveEventUntil", 0)
			Remotes.Notify:FireAllClients("info", event.name .. " has ended.")
		end
	end)
end

return EventService
