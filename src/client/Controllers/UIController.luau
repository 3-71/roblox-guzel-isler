--!strict
-- The entire game UI, built procedurally: money HUD, inventory (+sell),
-- collection book, live odds panel, toasts, roll celebrations, offline
-- report. Renders exclusively from the latest DataSync snapshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("GameConfig"))
local Rarities = require(Shared:WaitForChild("Config"):WaitForChild("Rarities"))
local Keyboards = require(Shared:WaitForChild("Config"):WaitForChild("Keyboards"))
local Events = require(Shared:WaitForChild("Config"):WaitForChild("Events"))
local Products = require(Shared:WaitForChild("Config"):WaitForChild("Products"))
local IndexRewards = require(Shared:WaitForChild("Config"):WaitForChild("IndexRewards"))
local RestockShop = require(Shared:WaitForChild("Config"):WaitForChild("RestockShop"))
local FactoryTiers = require(Shared:WaitForChild("Config"):WaitForChild("FactoryTiers"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local RollLogic = require(Shared:WaitForChild("RollLogic"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local KeyboardModel = require(Shared:WaitForChild("World"):WaitForChild("KeyboardModel"))

local SoundController = require(script.Parent.SoundController)

local UIController = {}

local localPlayer = Players.LocalPlayer

local PANEL_BG = Color3.fromRGB(38, 41, 50)
local PANEL_BG2 = Color3.fromRGB(50, 54, 66)
local TEXT_MAIN = Color3.fromRGB(245, 246, 250)
local TEXT_DIM = Color3.fromRGB(170, 175, 190)
local ACCENT = Color3.fromRGB(255, 205, 90)
local GOOD = Color3.fromRGB(120, 230, 140)
local BAD = Color3.fromRGB(240, 95, 95)

local profile: Types.Profile? = nil
local screenGui: ScreenGui
local openPanelName: string? = nil

-- Remote payload shapes (documented in Shared/Remotes.luau header)
type SellReportPayload = {
	count: number,
	total: number,
	bestId: string?,
	bestValue: number,
	mutationBonus: number,
}
type RestockSlotPayload = { offerId: string, stockLeft: number, price: number }
type RestockPayload = { restockAt: number, slots: { RestockSlotPayload } }
type GlobalRollPayload = {
	playerName: string,
	keyboardId: string,
	mutation: string?,
	rarityTier: number,
	plotIndex: number?,
	oddsDenominator: number,
}

local restockOfferById: { [string]: typeof(RestockShop[1]) } = {}
for _, offer in RestockShop do
	restockOfferById[offer.id] = offer
end

-- ===== tiny UI helpers =====

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

local function mkButton(parent: Instance, props: { [string]: any }, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.BorderSizePixel = 0
	b.BackgroundColor3 = PANEL_BG2
	b.Font = Enum.Font.FredokaOne
	b.TextColor3 = TEXT_MAIN
	b.TextScaled = true
	b.AutoButtonColor = true
	for k, v in props do
		(b :: any)[k] = v
	end
	b.Activated:Connect(function()
		SoundController.PlayUiClick()
		onClick()
	end)
	b.Parent = parent
	return b
end

local function abbreviate(n: number): string
	n = math.floor(n)
	if n >= 1_000_000_000_000 then
		return string.format("%.2fT", n / 1_000_000_000_000)
	elseif n >= 1_000_000_000 then
		return string.format("%.2fB", n / 1_000_000_000)
	elseif n >= 1_000_000 then
		return string.format("%.2fM", n / 1_000_000)
	elseif n >= 10_000 then
		return string.format("%.1fK", n / 1_000)
	end
	return tostring(n)
end

local function comma(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return out
end

local function formatClock(seconds: number): string
	seconds = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function isDisplayed(p: Types.Profile, uid: string): number?
	for standIndex, displayedUid in p.displayed do
		if displayedUid == uid then
			return tonumber(standIndex)
		end
	end
	return nil
end

-- ===== money HUD =====

local moneyLabel: TextLabel
local shownMoney = 0
-- Every count-up animation claims a fresh token; stale loops bail out so the
-- sell ceremony can take over the label mid-animation.
local moneyAnimToken = 0
-- Armed when the client fires a SellRequest: the generic green floater is
-- suppressed because the SellReport ceremony owns the presentation.
local expectSellReportUntil = 0

local function buildMoneyHud()
	local hud = mkFrame(screenGui, {
		Name = "MoneyHud",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(200, 48),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.1,
	})
	corner(hud, 24)
	stroke(hud, ACCENT, 2)
	moneyLabel = mkText(hud, {
		Size = UDim2.new(1, -24, 1, -12),
		Position = UDim2.fromOffset(12, 6),
		Text = "$0",
		TextColor3 = ACCENT,
	})
end

local function setMoneyText(value: number)
	moneyLabel.Text = "$" .. abbreviate(value)
end

local function animateMoney(target: number)
	local from = shownMoney
	if from == target then
		return
	end
	if target > from and os.clock() >= expectSellReportUntil then
		-- little green +$X floater
		local floater = mkText(screenGui, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 60),
			Size = UDim2.fromOffset(160, 28),
			Text = "+$" .. abbreviate(target - from),
			TextColor3 = GOOD,
		})
		TweenService:Create(floater, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0, 100),
			TextTransparency = 1,
		}):Play()
		task.delay(1.2, function()
			floater:Destroy()
		end)
	end
	shownMoney = target
	moneyAnimToken += 1
	local token = moneyAnimToken
	task.spawn(function()
		local start = os.clock()
		local duration = 0.5
		while os.clock() - start < duration do
			if token ~= moneyAnimToken then
				return -- a newer animation (e.g. the sell ceremony) took over
			end
			local alpha = (os.clock() - start) / duration
			setMoneyText(from + (target - from) * alpha)
			task.wait()
		end
		if token == moneyAnimToken then
			setMoneyText(target)
		end
	end)
end

-- ===== sell ceremony (SellReport remote) =====

local function showSellCeremony(payload: SellReportPayload)
	local total = payload.total
	if typeof(total) ~= "number" or total <= 0 then
		return
	end
	-- DataSync (fired inside AddMoney) lands just before SellReport, so the
	-- profile already holds the post-sale balance: recount from pre-sale.
	local target = if profile then profile.money else shownMoney
	local from = math.max(target - total, 0)
	shownMoney = target
	moneyAnimToken += 1
	local token = moneyAnimToken

	-- Count-up duration grows with the size of the payday (log10), 0.8..1.5s.
	local duration = math.clamp(0.8 + 0.12 * math.log10(math.max(total, 1)), 0.8, 1.5)
	task.spawn(function()
		local start = os.clock()
		local lastTick = 0
		while os.clock() - start < duration do
			if token ~= moneyAnimToken then
				return
			end
			local alpha = (os.clock() - start) / duration
			setMoneyText(from + (target - from) * alpha)
			if os.clock() - lastTick >= 0.04 then
				lastTick = os.clock()
				SoundController.PlaySellTick(alpha)
			end
			task.wait()
		end
		if token == moneyAnimToken then
			setMoneyText(target)
		end
	end)

	-- floating "+$X" under the HUD
	local floater = mkText(screenGui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 60),
		Size = UDim2.fromOffset(240, 34),
		Text = "+$" .. abbreviate(total),
		TextColor3 = GOOD,
	})
	TweenService:Create(floater, TweenInfo.new(duration + 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 104),
		TextTransparency = 1,
	}):Play()
	task.delay(duration + 0.6, function()
		floater:Destroy()
	end)

	-- Mutations earned extra: a second gold line lands after a short beat,
	-- with a louder rising sting.
	local mutationBonus = payload.mutationBonus
	if typeof(mutationBonus) == "number" and mutationBonus > 0 then
		task.delay(0.3, function()
			SoundController.PlayRevealArpeggio(3)
			local goldLine = mkText(screenGui, {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 96),
				Size = UDim2.fromOffset(280, 30),
				Text = "MUTATIONS +$" .. abbreviate(mutationBonus),
				TextColor3 = ACCENT,
			})
			TweenService:Create(goldLine, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5, 0, 0, 140),
				TextTransparency = 1,
			}):Play()
			task.delay(1.5, function()
				goldLine:Destroy()
			end)
		end)
	end
end

-- All client sell requests funnel through here so the money HUD knows a
-- SellReport ceremony is about to own the count-up presentation.
local function requestSell(mode: string, payloadArg: any)
	expectSellReportUntil = os.clock() + 2
	Remotes.SellRequest:FireServer(mode, payloadArg)
end

-- ===== boost timer pills (under the money HUD) =====

local boostsFrame: Frame

local BOOST_FALLBACK_NAMES: { [string]: string } = {
	serverLuckParty = "Server Luck Party",
}

local function boostDisplayName(key: string): string
	for _, def in Products.DevProducts do
		if def.key == key then
			return def.name
		end
	end
	return BOOST_FALLBACK_NAMES[key] or key
end

local function renderBoosts()
	local p = profile
	if not p then
		return
	end
	for _, child in boostsFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local now = os.time()
	local keys: { string } = {}
	for key, expiry in p.boosts do
		if typeof(expiry) == "number" and expiry > now then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for i, key in keys do
		local remaining = (p.boosts[key] :: number) - now
		local pill = mkFrame(boostsFrame, {
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = PANEL_BG,
			BackgroundTransparency = 0.15,
			LayoutOrder = i,
		})
		corner(pill, 12)
		stroke(pill, GOOD, 1)
		mkText(pill, {
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = `🍀 {boostDisplayName(key)} {formatClock(remaining)}`,
			TextScaled = false,
			TextSize = 14,
			TextColor3 = GOOD,
		})
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingRight = UDim.new(0, 10)
		padding.Parent = pill
	end
end

local function buildBoostPills()
	boostsFrame = mkFrame(screenGui, {
		Name = "BoostPills",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 62),
		Size = UDim2.fromOffset(620, 24),
		BackgroundTransparency = 1,
	})
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = boostsFrame

	-- 1s ticker: keeps countdowns live and drops expired pills
	task.spawn(function()
		while true do
			task.wait(1)
			local p = profile
			local hasPills = boostsFrame:FindFirstChildOfClass("Frame") ~= nil
			local hasActive = false
			if p then
				for _, expiry in p.boosts do
					if typeof(expiry) == "number" and expiry > os.time() then
						hasActive = true
						break
					end
				end
			end
			if hasActive or hasPills then
				renderBoosts()
			end
		end
	end)
end

-- ===== panel scaffolding =====

local panels: { [string]: Frame } = {}
local renderers: { [string]: () -> () } = {}

local function closeAllPanels()
	openPanelName = nil
	for _, panel in panels do
		panel.Visible = false
	end
end

local function togglePanel(name: string)
	if openPanelName == name then
		closeAllPanels()
		return
	end
	closeAllPanels()
	openPanelName = name
	local panel = panels[name]
	panel.Visible = true
	renderers[name]()
end

local function mkPanel(name: string, title: string, size: UDim2): (Frame, Frame)
	local panel = mkFrame(screenGui, {
		Name = name .. "Panel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 84, 0.5, 0),
		Size = size,
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.04,
		Visible = false,
	})
	corner(panel, 14)
	stroke(panel, PANEL_BG2, 2)

	mkText(panel, {
		Size = UDim2.new(1, -60, 0, 34),
		Position = UDim2.fromOffset(14, 8),
		Text = title,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	mkButton(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(34, 34),
		Text = "✕",
		BackgroundColor3 = BAD,
	}, closeAllPanels)

	local content = mkFrame(panel, {
		Name = "Content",
		Position = UDim2.fromOffset(10, 50),
		Size = UDim2.new(1, -20, 1, -60),
		BackgroundTransparency = 1,
	})
	panels[name] = panel
	return panel, content
end

-- ===== inventory panel =====

local invContent: Frame
local invHeader: TextLabel
local bulkTier = 3
local bulkArmed = false
local bulkButton: TextButton
local bulkTierButton: TextButton

local actionOverlay: Frame? = nil

local function closeActionOverlay()
	if actionOverlay then
		actionOverlay:Destroy()
		actionOverlay = nil
	end
end

-- Simple gift picker: one name button per OTHER player in the server.
-- Picking someone fires GiftRequest(targetUserId, uid) — server validates.
local function openGiftPicker(instance: Types.KeyboardInstance, defName: string, accent: Color3)
	closeActionOverlay()
	local panel = panels.inventory
	local overlay = mkFrame(panel, {
		Name = "ActionOverlay",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -40, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL_BG2,
		ZIndex = 5,
	})
	corner(overlay, 12)
	stroke(overlay, accent, 2)
	actionOverlay = overlay

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = overlay
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = overlay

	local title = mkText(overlay, {
		Size = UDim2.new(1, 0, 0, 28),
		Text = `Gift {defName} to…`,
		TextColor3 = accent,
		LayoutOrder = 1,
	})
	title.ZIndex = 6

	local order = 2
	local others = 0
	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end
		others += 1
		local b = mkButton(overlay, {
			Size = UDim2.new(1, 0, 0, 40),
			Text = "🎁 " .. other.Name,
			BackgroundColor3 = PANEL_BG,
			LayoutOrder = order,
		}, function()
			Remotes.GiftRequest:FireServer(other.UserId, instance.uid)
			closeActionOverlay()
		end)
		b.ZIndex = 6
		corner(b, 10)
		order += 1
	end
	if others == 0 then
		local none = mkText(overlay, {
			Size = UDim2.new(1, 0, 0, 24),
			Text = "No other players in the server.",
			TextColor3 = TEXT_DIM,
			LayoutOrder = order,
		})
		none.ZIndex = 6
		order += 1
	end
	local cancel = mkButton(overlay, {
		Size = UDim2.new(1, 0, 0, 36),
		Text = "Cancel",
		BackgroundColor3 = PANEL_BG,
		LayoutOrder = order,
	}, closeActionOverlay)
	cancel.ZIndex = 6
	corner(cancel, 10)
end

local function openActionOverlay(instance: Types.KeyboardInstance)
	closeActionOverlay()
	local p = profile
	if not p then
		return
	end
	local def = Catalog.GetKeyboard(instance.id)
	local rarity = def and Catalog.GetRarity(def.rarityTier)
	if not def or not rarity then
		return
	end
	local panel = panels.inventory
	local equipped = p.equippedUid == instance.uid
	local standIndex = isDisplayed(p, instance.uid)

	local overlay = mkFrame(panel, {
		Name = "ActionOverlay",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -40, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL_BG2,
		ZIndex = 5,
	})
	corner(overlay, 12)
	stroke(overlay, rarity.color, 2)
	actionOverlay = overlay

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = overlay
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = overlay

	local title = mkText(overlay, {
		Size = UDim2.new(1, 0, 0, 30),
		Text = def.name,
		TextColor3 = rarity.color,
		LayoutOrder = 1,
	})
	title.ZIndex = 6
	local sub = mkText(overlay, {
		Size = UDim2.new(1, 0, 0, 18),
		Text = `{rarity.name} · sells for ${abbreviate(Catalog.GetSellValue(def.id, p.upgrades.factoryTier, instance.mutation, p.rebirths))}`,
		TextColor3 = TEXT_DIM,
		LayoutOrder = 2,
	})
	sub.ZIndex = 6

	local function actionButton(order: number, text: string, color: Color3, enabled: boolean, cb: () -> ())
		local b = mkButton(overlay, {
			Size = UDim2.new(1, 0, 0, 40),
			Text = text,
			BackgroundColor3 = if enabled then color else PANEL_BG,
			TextColor3 = if enabled then Color3.new(0.1, 0.1, 0.12) else TEXT_DIM,
			LayoutOrder = order,
			Active = enabled,
		}, function()
			if enabled then
				cb()
			end
		end)
		b.ZIndex = 6
		corner(b, 10)
		return b
	end

	actionButton(3, if equipped then "Unequip" else "Equip & type!", ACCENT, true, function()
		Remotes.EquipRequest:FireServer(if equipped then nil else instance.uid)
		closeActionOverlay()
	end)

	if standIndex then
		actionButton(4, `Remove from display (stand {standIndex})`, Color3.fromRGB(236, 112, 181), true, function()
			Remotes.DisplayRequest:FireServer(standIndex, nil)
			closeActionOverlay()
		end)
	elseif (math.min(p.upgrades.displays + (if p.passes.extraStands then 2 else 0), GameConfig.MaxDisplayStands)) > 0 and not equipped then
		-- stand picker row (mirrors ShowcaseService's extraStands-pass math)
		local unlockedStands = math.min(p.upgrades.displays + (if p.passes.extraStands then 2 else 0), GameConfig.MaxDisplayStands)
		local row = mkFrame(overlay, {
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
			LayoutOrder = 4,
		})
		row.ZIndex = 6
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.Padding = UDim.new(0, 6)
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		rowLayout.Parent = row
		mkText(row, { Size = UDim2.fromOffset(74, 40), Text = "Display:", TextColor3 = TEXT_DIM })
		for i = 1, GameConfig.MaxDisplayStands do
			local unlocked = unlockedStands >= i
			local b = mkButton(row, {
				Size = UDim2.fromOffset(36, 36),
				Text = tostring(i),
				BackgroundColor3 = if unlocked then Color3.fromRGB(236, 112, 181) else PANEL_BG,
				TextColor3 = if unlocked then Color3.new(0.1, 0.1, 0.12) else TEXT_DIM,
			}, function()
				if unlocked then
					Remotes.DisplayRequest:FireServer(i, instance.uid)
					closeActionOverlay()
				end
			end)
			b.ZIndex = 6
			corner(b, 8)
		end
	end

	-- Gift: only when this instance is free (not equipped/displayed) and
	-- there is somebody else in the server to receive it.
	local othersInServer = #Players:GetPlayers() > 1
	local canGift = not equipped and standIndex == nil and othersInServer
	local giftLabel = if canGift
		then "Gift to a player"
		elseif not othersInServer then "Gift (no one else here)"
		else "Gift (unequip/undisplay first)"
	actionButton(5, giftLabel, Color3.fromRGB(120, 200, 255), canGift, function()
		openGiftPicker(instance, def.name, rarity.color)
	end)

	local canSell = not equipped and standIndex == nil
	actionButton(6, if canSell then "Sell" else "Sell (unequip/undisplay first)", BAD, canSell, function()
		requestSell("uids", { instance.uid })
		closeActionOverlay()
	end)
	actionButton(7, "Cancel", PANEL_BG, true, closeActionOverlay)
end

local function renderInventory()
	local p = profile
	if not p then
		return
	end
	closeActionOverlay()
	local grid = invContent:FindFirstChild("Grid") :: ScrollingFrame
	for _, child in grid:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	invHeader.Text = `Keyboards: {#p.keyboards} / {GameConfig.InventoryCap}`

	local sorted = table.clone(p.keyboards)
	table.sort(sorted, function(a, b)
		local defA, defB = Catalog.GetKeyboard(a.id), Catalog.GetKeyboard(b.id)
		local tierA = if defA then defA.rarityTier else 0
		local tierB = if defB then defB.rarityTier else 0
		if tierA ~= tierB then
			return tierA > tierB
		end
		return a.id < b.id
	end)

	for _, instance in sorted do
		local def = Catalog.GetKeyboard(instance.id)
		local rarity = def and Catalog.GetRarity(def.rarityTier)
		if not def or not rarity then
			continue
		end
		local tile = mkButton(grid, {
			Size = UDim2.fromOffset(118, 96),
			Text = "",
			BackgroundColor3 = PANEL_BG2,
		}, function()
			openActionOverlay(instance)
		end)
		corner(tile, 10)
		stroke(tile, rarity.color, 2)
		mkText(tile, {
			Size = UDim2.new(1, -8, 0, 34),
			Position = UDim2.fromOffset(4, 6),
			Text = def.name,
			TextColor3 = rarity.color,
		})
		local mutationDef = Catalog.GetMutation(instance.mutation)
		mkText(tile, {
			Size = UDim2.new(1, -8, 0, 20),
			Position = UDim2.fromOffset(4, 42),
			Text = if mutationDef then `{string.upper(mutationDef.name)} · {rarity.name}` else rarity.name,
			TextColor3 = if mutationDef then mutationDef.tint else TEXT_DIM,
		})
		local status = if p.equippedUid == instance.uid
			then "EQUIPPED"
			elseif isDisplayed(p, instance.uid) then "ON DISPLAY"
			else "$" .. abbreviate(Catalog.GetSellValue(def.id, p.upgrades.factoryTier, instance.mutation, p.rebirths))
		mkText(tile, {
			Size = UDim2.new(1, -8, 0, 20),
			Position = UDim2.fromOffset(4, 66),
			Text = status,
			TextColor3 = if status == "EQUIPPED" then ACCENT elseif status == "ON DISPLAY" then Color3.fromRGB(236, 112, 181) else GOOD,
		})
	end
	grid.CanvasSize = UDim2.fromOffset(0, (math.ceil(#sorted / 3) * 104) + 8)

	-- bulk bar state
	local rarity = Rarities[bulkTier]
	bulkTierButton.Text = "below " .. rarity.name
	bulkTierButton.TextColor3 = rarity.color
	if not bulkArmed then
		bulkButton.Text = "Sell all"
		bulkButton.BackgroundColor3 = PANEL_BG2
	end
end

local function bulkPreview(): (number, number)
	local p = profile
	if not p then
		return 0, 0
	end
	local count, total = 0, 0
	for _, instance in p.keyboards do
		local def = Catalog.GetKeyboard(instance.id)
		if def and def.rarityTier < bulkTier and p.equippedUid ~= instance.uid and not isDisplayed(p, instance.uid) then
			count += 1
			total += Catalog.GetSellValue(def.id, p.upgrades.factoryTier, instance.mutation, p.rebirths)
		end
	end
	return count, total
end

local function buildInventoryPanel()
	local _panel, content = mkPanel("inventory", "⌨ Inventory", UDim2.fromOffset(420, 520))
	invContent = content

	invHeader = mkText(content, {
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Keyboards: 0",
		TextColor3 = TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.Position = UDim2.fromOffset(0, 28)
	grid.Size = UDim2.new(1, 0, 1, -86)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.Parent = content
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(118, 96)
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	-- bulk sell bar
	local bar = mkFrame(content, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = PANEL_BG2,
	})
	corner(bar, 10)
	bulkTierButton = mkButton(bar, {
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.fromOffset(150, 36),
		Text = "below Membrane",
		BackgroundColor3 = PANEL_BG,
	}, function()
		bulkTier += 1
		if bulkTier > #Rarities then
			bulkTier = 2
		end
		bulkArmed = false
		renderInventory()
	end)
	corner(bulkTierButton, 8)
	bulkButton = mkButton(bar, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 6),
		Size = UDim2.fromOffset(190, 36),
		Text = "Sell all",
	}, function()
		if bulkArmed then
			requestSell("belowTier", bulkTier)
			bulkArmed = false
		else
			local count, total = bulkPreview()
			if count == 0 then
				return
			end
			bulkArmed = true
			bulkButton.Text = `Really sell {count} for ~${abbreviate(total)}?`
			bulkButton.BackgroundColor3 = BAD
			task.delay(3, function()
				if bulkArmed then
					bulkArmed = false
					bulkButton.Text = "Sell all"
					bulkButton.BackgroundColor3 = PANEL_BG2
				end
			end)
		end
	end)
	corner(bulkButton, 8)
	renderers.inventory = renderInventory
end

-- ===== collection panel =====

local collContent: Frame

-- Claim strip above the grid: one chip per Config/IndexRewards entry.
-- claimed = dim ✓ · claimable = glowing gold (click to claim) · locked = "n/m"
local function renderIndexStrip(p: Types.Profile, discovered: number)
	local strip = collContent:FindFirstChild("IndexStrip") :: Frame
	for _, child in strip:GetChildren() do
		if child:IsA("TextButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	mkText(strip, {
		Size = UDim2.fromOffset(62, 36),
		Text = "Rewards",
		TextScaled = false,
		TextSize = 14,
		TextColor3 = TEXT_DIM,
		LayoutOrder = 0,
	})
	for i, reward in IndexRewards do
		local claimed = p.indexClaimed[reward.id] == true
		local claimable = not claimed and discovered >= reward.count
		local chip = mkButton(strip, {
			Size = UDim2.fromOffset(46, 36),
			LayoutOrder = i,
			Text = if claimed then "✓" elseif claimable then "$" .. abbreviate(reward.cash) else `{discovered}/{reward.count}`,
			TextScaled = false,
			TextSize = 14,
			BackgroundColor3 = if claimable then ACCENT elseif claimed then PANEL_BG2 else Color3.fromRGB(28, 30, 36),
			TextColor3 = if claimable then Color3.new(0.1, 0.1, 0.12) else TEXT_DIM,
			Active = claimable,
			AutoButtonColor = claimable,
		}, function()
			if claimable then
				Remotes.ClaimIndexReward:FireServer(reward.id)
			end
		end)
		corner(chip, 10)
		if claimable then
			local glow = stroke(chip, ACCENT, 2)
			task.spawn(function()
				while chip.Parent and glow.Parent do
					TweenService:Create(glow, TweenInfo.new(0.8), { Transparency = 0.7 }):Play()
					task.wait(0.8)
					TweenService:Create(glow, TweenInfo.new(0.8), { Transparency = 0 }):Play()
					task.wait(0.8)
				end
			end)
		end
	end
end

local function renderCollection()
	local p = profile
	if not p then
		return
	end
	local scroll = collContent:FindFirstChild("Scroll") :: ScrollingFrame
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local discovered = 0
	for _, def in Keyboards do
		if (p.collection[def.id] or 0) > 0 then
			discovered += 1
		end
	end
	local header = collContent:FindFirstChild("Header") :: TextLabel
	header.Text = `Collection: {discovered} / {#Keyboards}`
	renderIndexStrip(p, discovered)

	local y = 0
	for tier = 1, #Rarities do
		local rarity = Rarities[tier]
		local tierHeader = mkText(scroll, {
			Position = UDim2.fromOffset(4, y),
			Size = UDim2.new(1, -8, 0, 22),
			Text = rarity.name,
			TextColor3 = rarity.color,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		tierHeader.ZIndex = 2
		y += 26
		local x = 0
		for _, def in Keyboards do
			if def.rarityTier ~= tier then
				continue
			end
			local count = p.collection[def.id] or 0
			local found = count > 0
			local tile = mkFrame(scroll, {
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(122, 64),
				BackgroundColor3 = if found then PANEL_BG2 else Color3.fromRGB(28, 30, 36),
			})
			corner(tile, 8)
			stroke(tile, rarity.color, if found then 2 else 1)
			mkText(tile, {
				Size = UDim2.new(1, -8, 0, 34),
				Position = UDim2.fromOffset(4, 4),
				Text = if found then def.name else "???",
				TextColor3 = if found then rarity.color else TEXT_DIM,
			})
			mkText(tile, {
				Size = UDim2.new(1, -8, 0, 18),
				Position = UDim2.fromOffset(4, 40),
				Text = if found then `x{count}` else "undiscovered",
				TextColor3 = TEXT_DIM,
			})
			if found and tier >= 11 then
				-- gentle pulse on godly/secret finds
				task.spawn(function()
					local uiStroke = tile:FindFirstChildOfClass("UIStroke")
					while tile.Parent and uiStroke do
						TweenService:Create(uiStroke, TweenInfo.new(1.2), { Transparency = 0.7 }):Play()
						task.wait(1.2)
						TweenService:Create(uiStroke, TweenInfo.new(1.2), { Transparency = 0 }):Play()
						task.wait(1.2)
					end
				end)
			end
			x += 130
		end
		y += 72
	end
	scroll.CanvasSize = UDim2.fromOffset(0, y + 8)
end

local function buildCollectionPanel()
	local _panel, content = mkPanel("collection", "📖 Collection", UDim2.fromOffset(440, 540))
	collContent = content
	local header = mkText(content, {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Collection: 0 / 36",
		TextColor3 = TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	header.Parent = content

	-- Index-reward claim chips live between the header and the grid.
	local strip = mkFrame(content, {
		Name = "IndexStrip",
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundTransparency = 1,
	})
	local stripLayout = Instance.new("UIListLayout")
	stripLayout.FillDirection = Enum.FillDirection.Horizontal
	stripLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stripLayout.Padding = UDim.new(0, 6)
	stripLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	stripLayout.Parent = strip

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.Position = UDim2.fromOffset(0, 72)
	scroll.Size = UDim2.new(1, 0, 1, -76)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.Parent = content
	renderers.collection = renderCollection
end

-- ===== odds panel =====

local oddsContent: Frame

local function renderOdds()
	local p = profile
	if not p then
		return
	end
	for _, child in oddsContent:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	-- Effective luck includes rebirths, index rewards, potions, passes, and
	-- any active server event (published as Workspace attributes).
	local eventLuck = 0
	local eventId = workspace:GetAttribute("ActiveEventId")
	local eventUntil = workspace:GetAttribute("ActiveEventUntil")
	if typeof(eventId) == "string" and eventId ~= "" and typeof(eventUntil) == "number" and eventUntil > os.time() then
		for _, event in Events do
			if event.id == eventId then
				eventLuck = event.luckBonus
				break
			end
		end
	end
	local pityCount = p.pity or 0
	local odds = RollLogic.GetOdds(p.upgrades.factoryTier, RollLogic.GetEffectiveLuck(p, os.time(), eventLuck), pityCount)
	for tier = 1, #Rarities do
		local rarity = Rarities[tier]
		local chance = odds[tier]
		local row = mkFrame(oddsContent, {
			Position = UDim2.fromOffset(0, (tier - 1) * 32),
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
		})
		mkText(row, {
			Size = UDim2.fromOffset(96, 28),
			Text = rarity.name,
			TextColor3 = rarity.color,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local barBg = mkFrame(row, {
			Position = UDim2.fromOffset(100, 7),
			Size = UDim2.new(1, -210, 0, 14),
			BackgroundColor3 = Color3.fromRGB(28, 30, 36),
		})
		corner(barBg, 7)
		if chance > 0 then
			local fill = mkFrame(barBg, {
				Size = UDim2.new(math.max(chance, 0.015), 0, 1, 0),
				BackgroundColor3 = rarity.color,
			})
			corner(fill, 7)
		end
		local text = if chance <= 0
			then "—"
			elseif chance >= 0.01 then string.format("%.1f%%", chance * 100)
			else `1 in {comma(math.floor(1 / chance + 0.5))}`
		mkText(row, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.fromOffset(100, 28),
			Text = text,
			TextColor3 = TEXT_DIM,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end

	-- Thock Meter: the disclosed bad-luck-protection meter (GameConfig.Pity).
	local pity = GameConfig.Pity
	local targetRarity = Rarities[pity.TargetTier]
	local ft = Catalog.GetFactoryTier(p.upgrades.factoryTier)
	local ceilingBelowTarget = ft ~= nil and ft.maxRarity < pity.TargetTier
	local meter = mkFrame(oddsContent, {
		Position = UDim2.fromOffset(0, #Rarities * 32 + 6),
		Size = UDim2.new(1, 0, 0, 74),
		BackgroundTransparency = 1,
	})
	mkText(meter, {
		Size = UDim2.new(1, 0, 0, 20),
		Text = `Pity: {math.min(pityCount, pity.HardGuarantee)}/{pity.HardGuarantee} — {targetRarity.name}+ guaranteed at {pity.HardGuarantee}`,
		TextScaled = false,
		TextSize = 15,
		TextColor3 = targetRarity.color,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local meterBg = mkFrame(meter, {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundColor3 = Color3.fromRGB(28, 30, 36),
	})
	corner(meterBg, 7)
	local fillFrac = math.clamp(pityCount / pity.HardGuarantee, 0, 1)
	if fillFrac > 0 then
		local fill = mkFrame(meterBg, {
			Size = UDim2.new(fillFrac, 0, 1, 0),
			BackgroundColor3 = if pityCount >= pity.HardGuarantee then GOOD else targetRarity.color,
		})
		corner(fill, 7)
	end
	mkText(meter, {
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, 30),
		Text = if ceilingBelowTarget
			then `The meter fills once your factory can roll {targetRarity.name} — upgrade the factory!`
			else `Every roll below {targetRarity.name} fills the meter and gently boosts these odds; a {targetRarity.name}+ roll resets it.`,
		TextScaled = false,
		TextSize = 12,
		TextWrapped = true,
		TextColor3 = TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
end

local function buildOddsPanel()
	local panel, content = mkPanel("odds", "🎲 Roll Odds", UDim2.fromOffset(380, 560))
	oddsContent = content
	mkText(panel, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -20, 0, 18),
		Text = "70% factory tier · 30% luck",
		TextColor3 = TEXT_DIM,
	})
	renderers.odds = renderOdds
end

-- ===== rebirth panel =====

local rebirthContent: Frame
local rebirthArmed = false

local function renderRebirth()
	local p = profile
	if not p then
		return
	end
	for _, child in rebirthContent:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local rebirths = p.rebirths or 0
	local cost = math.floor(GameConfig.Rebirth.BaseCost * GameConfig.Rebirth.CostMult ^ rebirths)
	local valueBonus = math.floor(rebirths * GameConfig.Rebirth.ValueBonusPerRebirth * 100)
	local tierReady = p.upgrades.factoryTier >= GameConfig.Rebirth.RequiredFactoryTier
	local canAfford = p.money >= cost

	mkText(rebirthContent, {
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 4),
		Text = `⟳ Rebirth {rebirths}`,
		TextColor3 = ACCENT,
	})
	mkText(rebirthContent, {
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 52),
		Text = `Current bonus: +{valueBonus}% sell value\n+{rebirths * GameConfig.Rebirth.LuckLevelsPerRebirth} permanent luck`,
		TextColor3 = TEXT_DIM,
	})
	mkText(rebirthContent, {
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 104),
		Text = `Next rebirth: +{math.floor(GameConfig.Rebirth.ValueBonusPerRebirth * 100)}% value, +{GameConfig.Rebirth.LuckLevelsPerRebirth} luck\nResets money, factory, and upgrade pads`,
		TextColor3 = TEXT_DIM,
	})
	mkText(rebirthContent, {
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromOffset(0, 156),
		Text = if tierReady
			then `Cost: ${abbreviate(cost)}` .. (if canAfford then "" else " (not enough money)")
			else `Requires Factory Tier {GameConfig.Rebirth.RequiredFactoryTier} (you: {p.upgrades.factoryTier})`,
		TextColor3 = if tierReady and canAfford then GOOD else BAD,
	})

	local ready = tierReady and canAfford
	local button = mkButton(rebirthContent, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(220, 52),
		Text = if rebirthArmed then "Really rebirth?" else "REBIRTH",
		BackgroundColor3 = if not ready then PANEL_BG2 elseif rebirthArmed then BAD else ACCENT,
		TextColor3 = if ready then Color3.new(0.1, 0.1, 0.12) else TEXT_DIM,
	}, function()
		if not ready then
			return
		end
		if rebirthArmed then
			rebirthArmed = false
			Remotes.RebirthRequest:FireServer()
		else
			rebirthArmed = true
			renderRebirth()
			task.delay(3, function()
				if rebirthArmed then
					rebirthArmed = false
					if openPanelName == "rebirth" then
						renderRebirth()
					end
				end
			end)
		end
	end)
	corner(button, 12)
end

local function buildRebirthPanel()
	local _panel, content = mkPanel("rebirth", "⟳ Rebirth", UDim2.fromOffset(340, 300))
	rebirthContent = content
	renderers.rebirth = renderRebirth
end

-- ===== shop panel =====

local shopContent: Frame

local function renderShop()
	local p = profile
	if not p then
		return
	end
	local scroll = shopContent:FindFirstChild("Scroll") :: ScrollingFrame
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local y = 0
	local function sectionHeader(text: string)
		local header = mkFrame(scroll, {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, -8, 0, 24),
			BackgroundTransparency = 1,
		})
		mkText(header, {
			Size = UDim2.fromScale(1, 1),
			Text = text,
			TextColor3 = TEXT_DIM,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		y += 30
	end

	-- nameColor tints the title and strokes the card (keycrates pass their
	-- rarity color); nil keeps the plain gamepass/boost look.
	local function productRow(name: string, description: string, buttonText: string, enabled: boolean, accentColor: Color3, onBuy: () -> (), nameColor: Color3?)
		local row = mkFrame(scroll, {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, -8, 0, 62),
			BackgroundColor3 = PANEL_BG2,
		})
		corner(row, 10)
		if nameColor then
			stroke(row, nameColor, 2)
		end
		mkText(row, {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -120, 0, 24),
			Text = name,
			TextColor3 = nameColor or TEXT_MAIN,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		mkText(row, {
			Position = UDim2.fromOffset(10, 32),
			Size = UDim2.new(1, -120, 0, 24),
			Text = description,
			TextColor3 = TEXT_DIM,
			TextScaled = false,
			TextSize = 13,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		local buy = mkButton(row, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(92, 40),
			Text = buttonText,
			BackgroundColor3 = if enabled then accentColor else PANEL_BG,
			TextColor3 = if enabled then Color3.new(0.1, 0.1, 0.12) else TEXT_DIM,
			Active = enabled,
		}, function()
			if enabled then
				onBuy()
			end
		end)
		corner(buy, 10)
		y += 70
	end

	sectionHeader("GAMEPASSES — permanent")
	for _, def in Products.GamePasses do
		local owned = p.passes[def.key] == true
		local configured = def.id ~= 0
		productRow(
			def.name,
			def.description,
			if owned then "OWNED" elseif configured then "Buy" else "Soon",
			configured and not owned,
			ACCENT,
			function()
				MarketplaceService:PromptGamePassPurchase(localPlayer, def.id)
			end
		)
	end

	-- Keycrates: dev products with keyboardTier, on rarity-colored cards.
	sectionHeader("KEYCRATES — guaranteed rarity")
	for _, def in Products.DevProducts do
		local keyboardTier = def.keyboardTier
		if keyboardTier == nil then
			continue
		end
		local rarity = Catalog.GetRarity(keyboardTier)
		local rarityColor = if rarity then rarity.color else GOOD
		local configured = def.id ~= 0
		productRow(def.name, def.description, if configured then "Buy" else "Soon", configured, rarityColor, function()
			MarketplaceService:PromptProductPurchase(localPlayer, def.id)
		end, rarityColor)
	end

	sectionHeader("BOOSTS & MORE")
	for _, def in Products.DevProducts do
		if def.keyboardTier ~= nil then
			continue -- rendered in the KEYCRATES section above
		end
		local configured = def.id ~= 0
		productRow(def.name, def.description, if configured then "Buy" else "Soon", configured, GOOD, function()
			MarketplaceService:PromptProductPurchase(localPlayer, def.id)
		end)
	end

	scroll.CanvasSize = UDim2.fromOffset(0, y + 8)
end

local function buildShopPanel()
	local _panel, content = mkPanel("shop", "🛒 Shop", UDim2.fromOffset(400, 480))
	shopContent = content
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.Parent = content
	renderers.shop = renderShop
end

-- ===== restock stall panel (hub Limited Crates, RestockSync remote) =====

local restockContent: Frame
local restockCountdown: TextLabel
local latestRestock: RestockPayload? = nil

local function renderRestock()
	for _, child in restockContent:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local sync = latestRestock
	if sync == nil then
		local waiting = mkFrame(restockContent, {
			Position = UDim2.fromOffset(0, 34),
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
		})
		mkText(waiting, {
			Size = UDim2.fromScale(1, 1),
			Text = "Waiting for the stall to sync…",
			TextColor3 = TEXT_DIM,
		})
		return
	end
	local p = profile
	local factoryTier = if p then math.clamp(p.upgrades.factoryTier, 1, #FactoryTiers) else 1

	local y = 34
	for slotIndex, slot in sync.slots do
		local offer = restockOfferById[slot.offerId]
		if offer == nil or typeof(slot.stockLeft) ~= "number" or typeof(slot.price) ~= "number" then
			continue
		end
		-- Contract: the charge is the offer's base cost * buyer's factory tier.
		local price = math.floor(slot.price * factoryTier)
		local soldOut = slot.stockLeft <= 0
		local rare = offer.weight <= 3
		local row = mkFrame(restockContent, {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 92),
			BackgroundColor3 = PANEL_BG2,
			BackgroundTransparency = if soldOut then 0.55 else 0,
		})
		corner(row, 10)
		if rare and not soldOut then
			stroke(row, ACCENT, 2)
		end
		mkText(row, {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -130, 0, 24),
			Text = offer.name,
			TextColor3 = if soldOut then TEXT_DIM elseif rare then ACCENT else TEXT_MAIN,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		mkText(row, {
			Position = UDim2.fromOffset(10, 34),
			Size = UDim2.new(1, -130, 0, 32),
			Text = offer.description,
			TextScaled = false,
			TextSize = 13,
			TextWrapped = true,
			TextColor3 = TEXT_DIM,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		mkText(row, {
			Position = UDim2.fromOffset(10, 68),
			Size = UDim2.new(1, -130, 0, 18),
			Text = if soldOut then "SOLD OUT" else `{slot.stockLeft} left this restock`,
			TextScaled = false,
			TextSize = 13,
			TextColor3 = if soldOut then BAD else GOOD,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local buy = mkButton(row, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(104, 44),
			Text = if soldOut then "SOLD OUT" else "$" .. abbreviate(price),
			TextScaled = false,
			TextSize = 16,
			BackgroundColor3 = if soldOut then PANEL_BG else GOOD,
			TextColor3 = if soldOut then TEXT_DIM else Color3.new(0.1, 0.1, 0.12),
			Active = not soldOut,
			AutoButtonColor = not soldOut,
		}, function()
			if not soldOut then
				Remotes.BuyRestockItem:FireServer(slotIndex)
			end
		end)
		corner(buy, 10)
		y += 100
	end

	local note = mkFrame(restockContent, {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
	})
	mkText(note, {
		Size = UDim2.fromScale(1, 1),
		Text = `Prices scale with your factory tier (x{factoryTier})`,
		TextScaled = false,
		TextSize = 12,
		TextColor3 = TEXT_DIM,
	})
end

local function buildRestockPanel()
	local _panel, content = mkPanel("restock", "🎁 Limited Crates", UDim2.fromOffset(400, 470))
	restockContent = content
	restockCountdown = mkText(content, {
		Name = "Countdown",
		Size = UDim2.new(1, 0, 0, 26),
		Text = "Restock in --:--",
		TextColor3 = ACCENT,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	-- Live "Restock in m:ss" off the wall-clock restockAt the server synced;
	-- the flip itself arrives as a fresh RestockSync from the server.
	task.spawn(function()
		while true do
			local sync = latestRestock
			if sync ~= nil then
				local remaining = sync.restockAt - os.time()
				restockCountdown.Text = if remaining > 0 then `Restock in {formatClock(remaining)}` else "Restocking…"
			end
			task.wait(1)
		end
	end)
	renderers.restock = renderRestock
end

-- ===== button rail =====

local function buildRail()
	local rail = mkFrame(screenGui, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(60, 6 * 66),
		BackgroundTransparency = 1,
	})
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.Parent = rail
	for _, entry in { { "inventory", "⌨" }, { "collection", "📖" }, { "odds", "🎲" }, { "rebirth", "⟳" }, { "shop", "🛒" }, { "restock", "🎁" } } do
		local b = mkButton(rail, {
			Size = UDim2.fromOffset(56, 56),
			Text = entry[2],
			BackgroundColor3 = PANEL_BG,
		}, function()
			togglePanel(entry[1])
		end)
		corner(b, 14)
		stroke(b, PANEL_BG2, 2)
	end
end

-- ===== toasts =====

local toastContainer: Frame

local function buildToasts()
	toastContainer = mkFrame(screenGui, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(300, 400),
		BackgroundTransparency = 1,
	})
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Parent = toastContainer
end

local function toast(kind: string, message: string)
	local children = 0
	for _, child in toastContainer:GetChildren() do
		if child:IsA("Frame") then
			children += 1
		end
	end
	if children >= 5 then
		for _, child in toastContainer:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
				break
			end
		end
	end

	local bg = if kind == "error" then Color3.fromRGB(90, 40, 45) elseif kind == "flex" then Color3.fromRGB(80, 65, 20) else PANEL_BG
	local frame = mkFrame(toastContainer, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = bg,
		BackgroundTransparency = 0.08,
	})
	corner(frame, 10)
	if kind == "flex" then
		stroke(frame, ACCENT, 2)
	end
	local lbl = mkText(frame, {
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.fromOffset(8, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = if kind == "flex" then "✨ " .. message else message,
		TextScaled = false,
		TextWrapped = true,
		TextSize = 16,
		TextColor3 = if kind == "error" then Color3.fromRGB(255, 180, 180) elseif kind == "flex" then ACCENT else TEXT_MAIN,
	})
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = frame
	task.delay(if kind == "flex" then 6 else 4, function()
		if frame.Parent then
			frame:Destroy()
		end
	end)
end

-- Top-center marquee banner for GlobalRoll spectacles (other players' huge
-- rolls), styled like the flex toast. One at a time; the newest wins.
local activeMarquee: Frame? = nil

local function marqueeToast(message: string, color: Color3)
	if activeMarquee then
		activeMarquee:Destroy()
		activeMarquee = nil
	end
	-- Very dark rarity colors (Secret) get lifted so they read on the banner.
	local textColor = if color.R + color.G + color.B < 0.6 then color:Lerp(Color3.new(1, 1, 1), 0.6) else color
	local banner = mkFrame(screenGui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -56),
		Size = UDim2.fromOffset(580, 44),
		BackgroundColor3 = Color3.fromRGB(80, 65, 20),
		BackgroundTransparency = 0.08,
		ZIndex = 9,
	})
	corner(banner, 12)
	stroke(banner, ACCENT, 2)
	local lbl = mkText(banner, {
		Size = UDim2.new(1, -20, 1, -10),
		Position = UDim2.fromOffset(10, 5),
		Text = "✨ " .. message,
		TextColor3 = textColor,
	})
	lbl.ZIndex = 9
	activeMarquee = banner
	TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 96),
	}):Play()
	task.delay(4.5, function()
		if banner.Parent == nil then
			return
		end
		TweenService:Create(banner, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -56) }):Play()
		task.delay(0.35, function()
			if activeMarquee == banner then
				activeMarquee = nil
			end
			banner:Destroy()
		end)
	end)
end

-- ===== celebration overlay =====

local celebrationQueue: { Types.CollectedPayload } = {}
local celebrating = false

-- Reveal-hold seconds by rarity tier: the highest threshold <= tier wins.
local CEREMONY_HOLD: { [number]: number } = { [1] = 0.9, [9] = 2.2, [11] = 4 }

local function ceremonyHoldFor(tier: number): number
	local bestThreshold, hold = 0, 0.9
	for threshold, seconds in CEREMONY_HOLD do
		if tier >= threshold and threshold > bestThreshold then
			bestThreshold = threshold
			hold = seconds
		end
	end
	return hold
end

-- The roll ceremony: slot-machine anticipation (decelerating name wheel in
-- rarity colors), a freeze + stroke-pulse + white-flash tell on tier 9+, then
-- the reveal card with the actual keyboard spinning in a ViewportFrame. Any
-- tap/click/keypress during the ceremony skips straight to the reveal.
local function showCelebration(payload: Types.CollectedPayload)
	local def = Catalog.GetKeyboard(payload.keyboardId)
	local rarity = def and Catalog.GetRarity(def.rarityTier)
	if not def or not rarity then
		return
	end
	local mutationDef = Catalog.GetMutation(payload.mutation)
	local titleText = if mutationDef then `{string.upper(mutationDef.name)} {def.name}!` else def.name
	local titleColor = if mutationDef then mutationDef.tint else rarity.color

	local skipped = false
	local inputConn = UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if input.UserInputType == Enum.UserInputType.Keyboard
			or input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			skipped = true
		end
	end)
	local spinConn: RBXScriptConnection? = nil

	local dim = mkFrame(screenGui, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 10,
	})
	TweenService:Create(dim, TweenInfo.new(0.2), { BackgroundTransparency = 0.45 }):Play()

	local card = mkFrame(dim, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = PANEL_BG,
		ZIndex = 11,
	})
	corner(card, 16)
	local cardStroke = stroke(card, rarity.color, 3)
	TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(360, 300),
	}):Play()

	local topLabel = mkText(card, {
		Size = UDim2.new(1, -20, 0, 26),
		Position = UDim2.fromOffset(10, 10),
		Text = "ROLLING…",
		TextColor3 = TEXT_DIM,
		ZIndex = 12,
	})
	local wheel = mkText(card, {
		Size = UDim2.new(1, -20, 0, 60),
		Position = UDim2.fromOffset(10, 110),
		Text = "",
		ZIndex = 12,
	})
	local skipHint = mkText(card, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -20, 0, 16),
		Text = "tap to skip",
		TextScaled = false,
		TextSize = 13,
		TextColor3 = TEXT_DIM,
		ZIndex = 12,
	})

	task.wait(0.25) -- let the card pop in

	-- Anticipation: rapid random keyboard names in their rarity colors,
	-- decelerating tick by tick (0.05 * 1.18^i).
	local wheelRng = Random.new()
	for i = 0, 11 do
		if skipped then
			break
		end
		local pick = Keyboards[wheelRng:NextInteger(1, #Keyboards)]
		local pickRarity = Catalog.GetRarity(pick.rarityTier)
		wheel.Text = pick.name
		wheel.TextColor3 = if pickRarity then pickRarity.color else TEXT_MAIN
		SoundController.PlaySlotTick(i)
		task.wait(0.05 * 1.18 ^ i)
	end

	-- Tier 9+ tell: the wheel freezes, the stroke pulses, then a white flash
	-- washes the screen right before the reveal.
	if def.rarityTier >= 9 and not skipped then
		TweenService:Create(
			cardStroke,
			TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true),
			{ Thickness = 6, Transparency = 0.25 }
		):Play()
		task.wait(0.45)
		local flash = mkFrame(dim, {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			ZIndex = 15,
		})
		TweenService:Create(flash, TweenInfo.new(0.08), { BackgroundTransparency = 0.1 }):Play()
		task.wait(0.1)
		TweenService:Create(flash, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		task.delay(0.35, function()
			flash:Destroy()
		end)
	end

	-- ===== reveal =====
	wheel:Destroy()
	skipHint:Destroy()
	topLabel.Text = "NEW ROLL!"
	SoundController.PlayRevealArpeggio(def.rarityTier)
	task.delay(0.4, function()
		SoundController.PlayKeyboard(payload.keyboardId, nil, payload.mutation)
	end)

	-- The actual keyboard, built client-side and slowly spun in a viewport.
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Position = UDim2.fromOffset(10, 40)
	viewport.Size = UDim2.new(1, -20, 0, 130)
	viewport.Ambient = rarity.color
	viewport.LightColor = Color3.new(1, 1, 1)
	viewport.LightDirection = Vector3.new(-1, -2, -1)
	viewport.ZIndex = 12
	viewport.Parent = card
	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport
	local model = KeyboardModel.Build(def, 1, mutationDef)
	model:PivotTo(CFrame.new())
	model.Parent = worldModel
	local camera = Instance.new("Camera")
	camera.CFrame = CFrame.lookAt(Vector3.new(3.4, 2.8, -3.8), Vector3.zero) -- 3/4 front view
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local spinAngle = 0
	spinConn = RunService.Heartbeat:Connect(function(dt)
		spinAngle += dt * 0.7
		model:PivotTo(CFrame.Angles(0, spinAngle, 0))
	end)

	mkText(card, {
		Size = UDim2.new(1, -20, 0, 46),
		Position = UDim2.fromOffset(10, 172),
		Text = titleText,
		TextColor3 = titleColor,
		ZIndex = 12,
	})
	mkText(card, {
		Size = UDim2.new(1, -20, 0, 24),
		Position = UDim2.fromOffset(10, 220),
		Text = rarity.name,
		TextColor3 = rarity.color,
		ZIndex = 12,
	})

	local p = profile
	if p then
		local discovered = 0
		for _, kbDef in Keyboards do
			if (p.collection[kbDef.id] or 0) > 0 then
				discovered += 1
			end
		end
		mkText(card, {
			Size = UDim2.new(1, -20, 0, 20),
			Position = UDim2.fromOffset(10, 248),
			Text = `{discovered}/{#Keyboards} collected`,
			TextColor3 = TEXT_DIM,
			ZIndex = 12,
		})
		if p.collection[def.id] == 1 then
			-- first one ever: scale-bounce "NEW!" badge
			local badge = mkFrame(card, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -10, 0, 8),
				Size = UDim2.fromOffset(0, 0),
				BackgroundColor3 = GOOD,
				Rotation = 8,
				ZIndex = 13,
			})
			corner(badge, 8)
			mkText(badge, {
				Size = UDim2.fromScale(1, 1),
				Text = "NEW!",
				TextColor3 = Color3.new(0.1, 0.1, 0.12),
				ZIndex = 14,
			})
			TweenService:Create(badge, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(84, 32),
			}):Play()
		end
	end

	-- confetti
	local rng = Random.new()
	for _ = 1, 30 do
		local piece = mkFrame(dim, {
			Position = UDim2.fromScale(rng:NextNumber(0.2, 0.8), -0.05),
			Size = UDim2.fromOffset(rng:NextInteger(6, 12), rng:NextInteger(6, 12)),
			BackgroundColor3 = Color3.fromHSV(rng:NextNumber(), 0.7, 1),
			Rotation = rng:NextNumber(0, 360),
			ZIndex = 12,
		})
		TweenService:Create(piece, TweenInfo.new(rng:NextNumber(1.4, 2.2), Enum.EasingStyle.Linear), {
			Position = UDim2.fromScale(rng:NextNumber(0.15, 0.85), 1.1),
			Rotation = rng:NextNumber(360, 720),
		}):Play()
	end

	task.wait(ceremonyHoldFor(def.rarityTier))
	inputConn:Disconnect()
	TweenService:Create(dim, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(card, TweenInfo.new(0.25), { Size = UDim2.fromOffset(0, 0) }):Play()
	task.wait(0.3)
	if spinConn then
		spinConn:Disconnect()
	end
	dim:Destroy()
end

local function queueCelebration(payload: Types.CollectedPayload)
	table.insert(celebrationQueue, payload)
	if celebrating then
		return
	end
	celebrating = true
	task.spawn(function()
		while #celebrationQueue > 0 do
			if #celebrationQueue > 2 then
				-- Queue collapse: play only the highest-tier roll in full and
				-- fold the rest into a single summary toast.
				local bestIndex = 1
				for index = 2, #celebrationQueue do
					if celebrationQueue[index].rarityTier > celebrationQueue[bestIndex].rarityTier then
						bestIndex = index
					end
				end
				local best = table.remove(celebrationQueue, bestIndex) :: Types.CollectedPayload
				local folded = #celebrationQueue
				table.clear(celebrationQueue)
				toast("info", `✨ +{folded} more keyboards collected while celebrating`)
				showCelebration(best)
			else
				local nextPayload = table.remove(celebrationQueue, 1) :: Types.CollectedPayload
				showCelebration(nextPayload)
			end
		end
		celebrating = false
	end)
end

-- ===== offline popup =====

local function showOfflineReport(payload: Types.OfflinePayload)
	local dim = mkFrame(screenGui, {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		ZIndex = 20,
	})
	local card = mkFrame(dim, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(360, 220),
		BackgroundColor3 = PANEL_BG,
		ZIndex = 21,
	})
	corner(card, 16)
	stroke(card, ACCENT, 2)
	mkText(card, {
		Size = UDim2.new(1, -20, 0, 36),
		Position = UDim2.fromOffset(10, 12),
		Text = "Welcome back! 🏭",
		ZIndex = 22,
	})
	local hours = math.floor(payload.secondsAway / 3600)
	local minutes = math.floor((payload.secondsAway % 3600) / 60)
	local awayText = if hours > 0 then `{hours}h {minutes}m` else `{minutes}m`
	local bestDef = if payload.bestKeyboardId then Catalog.GetKeyboard(payload.bestKeyboardId) else nil
	local bestRarity = if bestDef then Catalog.GetRarity(bestDef.rarityTier) else nil
	mkText(card, {
		Size = UDim2.new(1, -30, 0, 60),
		Position = UDim2.fromOffset(15, 52),
		Text = `Your factory made {payload.produced} keyboards\nwhile you were away ({awayText})`,
		TextColor3 = TEXT_DIM,
		ZIndex = 22,
	})
	if bestDef and bestRarity then
		mkText(card, {
			Size = UDim2.new(1, -30, 0, 26),
			Position = UDim2.fromOffset(15, 116),
			Text = `Best roll: {bestDef.name} ({bestRarity.name})`,
			TextColor3 = bestRarity.color,
			ZIndex = 22,
		})
	end
	if payload.capped then
		mkText(card, {
			Size = UDim2.new(1, -30, 0, 20),
			Position = UDim2.fromOffset(15, 144),
			Text = "⚠ Storage was full — upgrade Storage pads!",
			TextColor3 = BAD,
			ZIndex = 22,
		})
	end
	local ok = mkButton(card, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(120, 40),
		Text = "Nice!",
		BackgroundColor3 = ACCENT,
		TextColor3 = Color3.new(0.1, 0.1, 0.12),
		ZIndex = 22,
	}, function()
		dim:Destroy()
	end)
	corner(ok, 10)
end

-- ===== sell zone proximity =====

local function watchSellZone()
	task.spawn(function()
		local debounce = 0
		while true do
			local plots = workspace:FindFirstChild("Plots")
			local myPlot: Model? = nil
			if plots then
				for _, plot in plots:GetChildren() do
					if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == localPlayer.UserId then
						myPlot = plot
						break
					end
				end
			end
			local sellZone = if myPlot then myPlot:FindFirstChild("SellZone") else nil
			if sellZone and sellZone:IsA("BasePart") then
				local connection = sellZone.Touched:Connect(function(hit)
					local character = localPlayer.Character
					if character and hit:IsDescendantOf(character) and os.clock() - debounce > 1.5 then
						debounce = os.clock()
						if openPanelName ~= "inventory" then
							togglePanel("inventory")
						end
					end
				end)
				-- The plot is destroyed and rebuilt on rebirth; when this zone
				-- dies, loop around and rebind to the new plot's SellZone.
				while sellZone:IsDescendantOf(game) do
					task.wait(1)
				end
				connection:Disconnect()
			end
			task.wait(1)
		end
	end)
end

-- ===== Robux shop pad proximity (hub Keycrate Shop kiosk) =====

-- Stepping on the glowing "RobuxShopPad" in front of the hub Keycrate Shop
-- opens the Robux shop panel. Same rebind loop as watchSellZone: HubBuilder
-- rebuilds the kiosk destroy-by-name, so when this pad dies we search for
-- its replacement under Workspace.Hub.
local function watchRobuxShopPad()
	task.spawn(function()
		local debounce = 0
		while true do
			local hub = workspace:FindFirstChild("Hub")
			local pad = if hub then hub:FindFirstChild("RobuxShopPad", true) else nil
			if pad and pad:IsA("BasePart") then
				local connection = pad.Touched:Connect(function(hit)
					local character = localPlayer.Character
					if character and hit:IsDescendantOf(character) and os.clock() - debounce > 1 then
						debounce = os.clock()
						if openPanelName ~= "shop" then
							togglePanel("shop")
						end
					end
				end)
				while pad:IsDescendantOf(game) do
					task.wait(1)
				end
				connection:Disconnect()
			end
			task.wait(1)
		end
	end)
end

-- ===== typing reward floaters (TypeReward remote) =====

-- One little "+$X" per accepted keypress on the equipped keyboard, drifting
-- up from just above the hotbar with random x-jitter so rapid presses read
-- as a money shower. Deliberately cheap: labels beyond the alive cap are
-- dropped (a dense shower hides the gaps), and each label destroys itself
-- right after its ~0.7s tween.
local TYPE_FLOATER_MAX = 10
local TYPE_FLOATER_SECONDS = 0.7

local typeFloatersAlive = 0
local typeFloaterRng = Random.new()

local function showTypeReward(amount: number)
	if typeFloatersAlive >= TYPE_FLOATER_MAX then
		return
	end
	typeFloatersAlive += 1
	local jitterX = typeFloaterRng:NextInteger(-70, 70)
	local floater = mkText(screenGui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, jitterX, 1, -120),
		Size = UDim2.fromOffset(110, 24),
		Text = "+$" .. abbreviate(amount),
		TextColor3 = GOOD,
		TextScaled = false,
		TextSize = 18,
	})
	TweenService:Create(floater, TweenInfo.new(TYPE_FLOATER_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, jitterX, 1, -170),
		TextTransparency = 1,
	}):Play()
	task.delay(TYPE_FLOATER_SECONDS + 0.05, function()
		typeFloatersAlive -= 1
		floater:Destroy()
	end)
end

-- ===== wiring =====

function UIController.Start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MainUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	buildMoneyHud()
	buildBoostPills()
	buildInventoryPanel()
	buildCollectionPanel()
	buildOddsPanel()
	buildRebirthPanel()
	buildShopPanel()
	buildRestockPanel()
	buildRail()
	buildToasts()
	watchSellZone()
	watchRobuxShopPad()

	Remotes.DataSync.OnClientEvent:Connect(function(snapshot: Types.Profile)
		profile = snapshot
		animateMoney(snapshot.money)
		renderBoosts()
		if openPanelName then
			renderers[openPanelName]()
		end
	end)

	Remotes.Notify.OnClientEvent:Connect(function(kind: string, message: string)
		if typeof(kind) == "string" and typeof(message) == "string" then
			toast(kind, message)
		end
	end)

	Remotes.KeyboardCollected.OnClientEvent:Connect(function(payload: Types.CollectedPayload)
		if payload.rarityTier >= GameConfig.CelebrateMinTier or payload.mutation ~= nil then
			queueCelebration(payload)
		end
	end)

	Remotes.SellReport.OnClientEvent:Connect(function(payload: SellReportPayload)
		if typeof(payload) == "table" then
			showSellCeremony(payload)
		end
	end)

	Remotes.RestockSync.OnClientEvent:Connect(function(payload: RestockPayload)
		if typeof(payload) ~= "table" or typeof(payload.restockAt) ~= "number" or typeof(payload.slots) ~= "table" then
			return
		end
		latestRestock = payload
		if openPanelName == "restock" then
			renderRestock()
		end
	end)

	-- Other players' spectacle rolls: marquee banner + rarity-colored chat
	-- line. Own rolls are skipped — they already get the full ceremony.
	Remotes.GlobalRoll.OnClientEvent:Connect(function(payload: GlobalRollPayload)
		if typeof(payload) ~= "table"
			or typeof(payload.playerName) ~= "string"
			or typeof(payload.keyboardId) ~= "string"
		then
			return
		end
		if payload.playerName == localPlayer.Name then
			return
		end
		local def = Catalog.GetKeyboard(payload.keyboardId)
		local rarity = def and Catalog.GetRarity(def.rarityTier)
		if not def or not rarity then
			return
		end
		local mutationDef = Catalog.GetMutation(payload.mutation)
		local what = if mutationDef then `{string.upper(mutationDef.name)} {rarity.name}` else rarity.name
		local denom = if typeof(payload.oddsDenominator) == "number" then math.max(math.floor(payload.oddsDenominator), 1) else 0
		local oddsText = if denom > 0 then ` (1 in {comma(denom)})` else ""
		local message = `{payload.playerName} rolled a {what} {def.name}{oddsText}!`
		marqueeToast(message, rarity.color)
		pcall(function()
			local channels = (TextChatService :: any).TextChannels
			local general = channels.RBXGeneral
			general:DisplaySystemMessage(`<font color="#{rarity.color:ToHex()}">{message}</font>`)
		end)
	end)

	-- Per-keypress typing money: keep it feather-light, it can fire many
	-- times a second while the player hammers the equipped keyboard.
	Remotes.TypeReward.OnClientEvent:Connect(function(amount: number)
		if typeof(amount) == "number" and amount > 0 then
			showTypeReward(amount)
		end
	end)

	Remotes.OfflineReport.OnClientEvent:Connect(showOfflineReport)
end

return UIController
