--!strict
-- StreakService — daily login streak. Every consecutive UTC day online adds
-- GameConfig.Streak.LuckPerDay bonus luck (capped at MaxLuckBonus); missing a
-- day resets the streak to day 1. The bonus itself is applied inside
-- RollLogic.GetEffectiveLuck, so every roll and the odds panel pick it up
-- automatically — this service only maintains the counter and the welcome
-- toast.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)

local StreakService = {}

local SECONDS_PER_DAY = 86_400

function StreakService.Init() end

function StreakService.Start()
	DataService.OnProfileLoaded(function(player, profile)
		local today = os.time() // SECONDS_PER_DAY

		if profile.streakLastDay == today then
			return -- already counted today (server hop / rejoin)
		end

		if profile.streakLastDay == today - 1 then
			profile.streakDays += 1
		else
			profile.streakDays = 1
		end
		profile.streakLastDay = today

		DataService.MarkDirty(player)
		DataService.Sync(player)

		local bonus = math.min(profile.streakDays * GameConfig.Streak.LuckPerDay, GameConfig.Streak.MaxLuckBonus)
		local capped = profile.streakDays * GameConfig.Streak.LuckPerDay >= GameConfig.Streak.MaxLuckBonus
		-- Small delay so the toast lands after the client UI is up.
		task.delay(4, function()
			if player.Parent ~= nil then
				local cappedNote = if capped then " (max!)" else ""
				Remotes.Notify:FireClient(
					player,
					"info",
					`🔥 Daily streak: day {profile.streakDays} — +{bonus} luck today{cappedNote}!`
				)
			end
		end)
	end)
end

return StreakService
