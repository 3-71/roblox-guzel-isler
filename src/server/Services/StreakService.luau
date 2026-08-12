--!strict
-- StreakService — daily login streak + the Phase-5 7-day streak calendar.
--
-- Streak (unchanged): every consecutive UTC day online adds
-- GameConfig.Streak.LuckPerDay bonus luck (capped at MaxLuckBonus); missing a
-- day resets the streak to day 1. The bonus itself is applied inside
-- RollLogic.GetEffectiveLuck, so every roll and the odds panel pick it up
-- automatically — this service only maintains the counter and the welcome
-- toast.
--
-- Streak calendar (Phase 5 contract, ARCHITECTURE.md item 2): sits on top of
-- the streak. ClaimCalendar remote (2/s token bucket, no payload): one claim
-- per UTC day; the position advances 1..7 then wraps. Missing more than
-- GameConfig.StreakCalendar.GraceDays days resets the position to day 1.
-- Rewards per GameConfig.StreakCalendar.Rewards:
--   cash      -> EconomyService.AddMoney
--   luckBoost -> profile.boosts.calendar_luck = os.time() + BoostSeconds
--                (consumed by RollLogic.GetEffectiveLuck, landed contract)
--   legendary -> uniform-random NON-SECRET tier-9 def via
--                InventoryService.AddKeyboard(player, id, "calendar") — full
--                ceremony. At inventory cap AddKeyboard returns nil: fall
--                back to cash equal to that board's sell value + Notify, so
--                the claim never silently fails. Day-7 legendary flexes
--                server-wide.
-- Every claim ends with DataService.MarkDirty + Sync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Catalog)
local GameConfig = require(Shared.Config.GameConfig)
local Keyboards = require(Shared.Config.Keyboards)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)

local StreakService = {}

local SECONDS_PER_DAY = 86_400
local LEGENDARY_TIER = 9 -- calendar day-7 grants a uniform-random tier-9 board

local rng = Random.new()

-- All non-secret tier-9 defs (uniform pick pool for the day-7 reward).
-- Built once at load; the Keyboards config is static.
local legendaryPool: { typeof(Keyboards[1]) } = {}
for _, def in Keyboards do
	if def.rarityTier == LEGENDARY_TIER and not def.secret then
		table.insert(legendaryPool, def)
	end
end

-- ===== ClaimCalendar token bucket (contract: 2/s per player) =====

local CLAIM_RATE_PER_SECOND = 2

local claimTokens: { [Player]: { tokens: number, last: number } } = {}

local function takeClaimToken(player: Player): boolean
	local bucket = claimTokens[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = 2, last = now }
		claimTokens[player] = bucket
	end
	bucket.tokens = math.min(2, bucket.tokens + (now - bucket.last) * CLAIM_RATE_PER_SECOND)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Grants the day-7 legendary. Returns the Notify line for the claimer.
-- Never silently fails: at inventory cap (AddKeyboard -> nil) the player gets
-- the board's sell value as cash instead, at their current tier/rebirths —
-- exactly what selling it would have paid.
local function grantLegendary(player: Player, profile: Types.Profile): string
	if #legendaryPool == 0 then
		-- Config regression guard (3 tier-9 boards ship in Keyboards.luau).
		warn("[StreakService] no non-secret tier-9 keyboards in Catalog — paying rarity base value instead")
		local rarity = Catalog.GetRarity(LEGENDARY_TIER)
		local fallback = if rarity then rarity.baseValue else 7_000
		EconomyService.AddMoney(player, fallback)
		return `📅 Day 7 reward: 💰{fallback}!`
	end

	local def = legendaryPool[rng:NextInteger(1, #legendaryPool)]
	local instance = InventoryService.AddKeyboard(player, def.id, "calendar")
	if instance == nil then
		-- Inventory cap (the id is known-valid and the profile is loaded):
		-- fall back to the board's sell value so the claim still pays out.
		local value = Catalog.GetSellValue(def.id, profile.upgrades.factoryTier, nil, profile.rebirths)
		EconomyService.AddMoney(player, value)
		return `📅 Inventory full — your calendar Legendary {def.name} was sold for 💰{value} instead!`
	end

	-- Day-7 legendary flexes server-wide (AddKeyboard's own tier-9 flex +
	-- GlobalRoll spectacle also fire — this line credits the calendar).
	Remotes.Notify:FireAllClients(
		"flex",
		`📅 {player.Name} completed the 7-day streak calendar and claimed a LEGENDARY {def.name}!`
	)
	return `📅 Day 7 reward: LEGENDARY {def.name}! ⭐`
end

local function onClaimCalendar(player: Player)
	if not takeClaimToken(player) then
		return -- rate limited: drop silently
	end
	local profile = DataService.GetProfile(player)
	if profile == nil then
		return
	end

	local today = os.time() // SECONDS_PER_DAY
	if profile.calendarLastClaim == today then
		Remotes.Notify:FireClient(player, "error", "📅 Already claimed today — come back tomorrow!")
		return
	end
	if today - profile.calendarLastClaim > GameConfig.StreakCalendar.GraceDays then
		profile.calendarDay = 0 -- out of grace: position resets to day 1
	end
	profile.calendarDay = (profile.calendarDay % 7) + 1
	profile.calendarLastClaim = today

	-- Position is committed before granting so the Syncs inside
	-- AddMoney/AddKeyboard already carry the new calendar state.
	local reward = GameConfig.StreakCalendar.Rewards[profile.calendarDay]
	local line: string
	if reward.kind == "cash" then
		local amount = reward.amount or 0
		EconomyService.AddMoney(player, amount)
		line = `📅 Day {profile.calendarDay} reward: 💰{amount}!`
	elseif reward.kind == "luckBoost" then
		profile.boosts.calendar_luck = os.time() + GameConfig.StreakCalendar.BoostSeconds
		local minutes = GameConfig.StreakCalendar.BoostSeconds // 60
		line = `📅 Day {profile.calendarDay} reward: +{GameConfig.StreakCalendar.BoostLuckBonus} luck for {minutes} minutes! 🍀`
	else -- "legendary" (day 7)
		line = grantLegendary(player, profile)
	end

	DataService.MarkDirty(player)
	DataService.Sync(player)
	Remotes.Notify:FireClient(player, "info", line)
end

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

	Remotes.ClaimCalendar.OnServerEvent:Connect(onClaimCalendar)

	Players.PlayerRemoving:Connect(function(player)
		claimTokens[player] = nil
	end)
end

return StreakService
