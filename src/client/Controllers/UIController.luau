--!strict
-- The entire game UI, built procedurally: money HUD, inventory (+sell),
-- collection book, live odds panel, toasts, roll celebrations, offline
-- report. Renders exclusively from the latest DataSync snapshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("GameConfig"))
local Rarities = require(Shared:WaitForChild("Config"):WaitForChild("Rarities"))
local Keyboards = require(Shared:WaitForChild("Config"):WaitForChild("Keyboards"))
local Events = require(Shared:WaitForChild("Config"):WaitForChild("Events"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local RollLogic = require(Shared:WaitForChild("RollLogic"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

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

local function animateMoney(target: number)
	local from = shownMoney
	if from == target then
		return
	end
	if target > from then
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
	task.spawn(function()
		local start = os.clock()
		local duration = 0.5
		while os.clock() - start < duration do
			local alpha = (os.clock() - start) / duration
			moneyLabel.Text = "$" .. abbreviate(from + (target - from) * alpha)
			task.wait()
		end
		moneyLabel.Text = "$" .. abbreviate(target)
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
	elseif p.upgrades.displays > 0 and not equipped then
		-- stand picker row
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
			local unlocked = p.upgrades.displays >= i
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

	local canSell = not equipped and standIndex == nil
	actionButton(5, if canSell then "Sell" else "Sell (unequip/undisplay first)", BAD, canSell, function()
		Remotes.SellRequest:FireServer("uids", { instance.uid })
		closeActionOverlay()
	end)
	actionButton(6, "Cancel", PANEL_BG, true, closeActionOverlay)
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
			Remotes.SellRequest:FireServer("belowTier", bulkTier)
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
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.Position = UDim2.fromOffset(0, 28)
	scroll.Size = UDim2.new(1, 0, 1, -32)
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
	local odds = RollLogic.GetOdds(p.upgrades.factoryTier, RollLogic.GetEffectiveLuck(p, os.time(), eventLuck))
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
end

local function buildOddsPanel()
	local panel, content = mkPanel("odds", "🎲 Roll Odds", UDim2.fromOffset(380, 480))
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

-- ===== button rail =====

local function buildRail()
	local rail = mkFrame(screenGui, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(60, 3 * 66),
		BackgroundTransparency = 1,
	})
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.Parent = rail
	for _, entry in { { "inventory", "⌨" }, { "collection", "📖" }, { "odds", "🎲" } } do
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

-- ===== celebration overlay =====

local celebrationQueue: { Types.CollectedPayload } = {}
local celebrating = false

local function showCelebration(payload: Types.CollectedPayload)
	local def = Catalog.GetKeyboard(payload.keyboardId)
	local rarity = def and Catalog.GetRarity(def.rarityTier)
	if not def or not rarity then
		return
	end
	local mutationDef = Catalog.GetMutation(payload.mutation)
	local titleText = if mutationDef then `{string.upper(mutationDef.name)} {def.name}!` else def.name
	local titleColor = if mutationDef then mutationDef.tint else rarity.color

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
	stroke(card, rarity.color, 3)
	TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(340, 170),
	}):Play()

	task.delay(0.18, function()
		mkText(card, {
			Size = UDim2.new(1, -20, 0, 40),
			Position = UDim2.fromOffset(10, 14),
			Text = "NEW ROLL!",
			TextColor3 = TEXT_DIM,
			ZIndex = 12,
		})
		mkText(card, {
			Size = UDim2.new(1, -20, 0, 56),
			Position = UDim2.fromOffset(10, 56),
			Text = titleText,
			TextColor3 = titleColor,
			ZIndex = 12,
		})
		mkText(card, {
			Size = UDim2.new(1, -20, 0, 30),
			Position = UDim2.fromOffset(10, 118),
			Text = rarity.name,
			TextColor3 = rarity.color,
			ZIndex = 12,
		})
	end)

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

	task.wait(2.2)
	TweenService:Create(dim, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(card, TweenInfo.new(0.25), { Size = UDim2.fromOffset(0, 0) }):Play()
	task.wait(0.3)
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
			local next = table.remove(celebrationQueue, 1) :: Types.CollectedPayload
			showCelebration(next)
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
				sellZone.Touched:Connect(function(hit)
					local character = localPlayer.Character
					if character and hit:IsDescendantOf(character) and os.clock() - debounce > 1.5 then
						debounce = os.clock()
						if openPanelName ~= "inventory" then
							togglePanel("inventory")
						end
					end
				end)
				return
			end
			task.wait(1)
		end
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
	buildRail()
	buildInventoryPanel()
	buildCollectionPanel()
	buildOddsPanel()
	buildToasts()
	watchSellZone()

	Remotes.DataSync.OnClientEvent:Connect(function(snapshot: Types.Profile)
		profile = snapshot
		animateMoney(snapshot.money)
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

	Remotes.OfflineReport.OnClientEvent:Connect(showOfflineReport)
end

return UIController
