# Grow a Keyboard — Architecture

A Roblox tycoon: your plot's factory conveyors auto-produce **named collectible
keyboards** (36 keyboards across 12 rarity tiers, each with a signature key
sound). Sell keyboards at your sell zone, step on buy-pads to upgrade
(factory tier, conveyors, speed, luck, storage, display stands), collect and
flex rarer, better-sounding keyboards. Cozy low-poly, all geometry procedural.

## Ground rules (all code)

- Language: Luau, `--!strict` at the top of every file. Files end in `.luau`.
- No external packages. No `wait()` — use `task.wait()`, `task.spawn()`, etc.
- Server never trusts the client. Every remote handler validates types,
  ownership, ranges, and rate limits before acting.
- All state lives server-side in the player's Profile (see `src/shared/Types.luau`).
  After ANY profile mutation, the owning service fires `DataSync` with the full
  snapshot (small enough at our scale; no delta protocol).
- Config/balance numbers live ONLY in `src/shared/Config/*` — never inline.
- Shared modules are required via `ReplicatedStorage.Shared`.
- Instance names & hierarchy created by builders are part of the contract —
  other systems find things by these exact names.

## Rojo layout

| Path | Roblox location |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

## Shared modules (DONE — do not restructure, only consume)

- `Config/GameConfig` — global tunables.
- `Config/Rarities` — 12 tiers, colors, base sell values, glow/beam flags.
- `Config/Keyboards` — 36 keyboard defs: rarity, sound layers, look spec.
- `Config/FactoryTiers` — 12 factory tiers: pad cost, maxRarity, valueMult, baseInterval.
- `Config/Pads` — every buy-pad: id, kind, level, cost, prereq chain.
- `RollLogic` — pure odds math: `GetOdds(factoryTier, luck)`, `RollKeyboard(factoryTier, luck, rng) -> keyboardIndex`.
- `Catalog` — lookups: `GetKeyboard(id)`, `GetRarity(tier)`, `GetFactoryTier(tier)`, `GetPad(id)`, `GetPadCost(id)`, `GetSellValue(keyboardId, factoryTier)`.
- `Remotes` — RemoteEvent registry (server creates, client waits). Names + payloads documented in the file header.
- `Types` — Profile schema and remote payload types.

## Server (`src/server`)

`init.server.luau` bootstraps: requires every service, calls `Service.Init()`
on all (synchronous, no yielding, wire dependencies), then `Service.Start()`
on all (may spawn loops), in this order:

`DataService → PlotService → PadService → ProductionService → InventoryService → EconomyService → ShowcaseService → EquipService → OfflineService`

Each service is a ModuleScript in `src/server/Services/` returning a table with
`Init()` and `Start()`. Cross-service calls go through the required module
directly (e.g. `DataService.GetProfile(player)`).

### Service APIs (contract — implement exactly)

**DataService** (`Services/DataService.luau`)
- `GetProfile(player: Player): Types.Profile?` — nil until loaded.
- `MarkDirty(player: Player)` — schedule a save.
- `Sync(player: Player)` — fire `DataSync` remote with the profile snapshot.
- `OnProfileLoaded(callback: (Player, Types.Profile) -> ())` — services subscribe; fired after load (and after offline processing hook below). Callbacks also run for players already loaded when subscribed.
- Handles: DataStore load/save with retry, default profile + reconcile of missing fields, save on leave with `player.UserId` keyed `UpdateAsync`, autosave every `GameConfig.AutoSaveSeconds`, `game:BindToClose` flush, in-Studio fallback (no DataStore access → in-memory profile, `pcall` everything).
- `SetOfflineProcessor(fn: (Types.Profile) -> Types.OfflinePayload?)` — called by OfflineService; DataService runs it between raw load and `OnProfileLoaded`, and fires the `OfflineReport` remote if a payload is returned.

**PlotService** (`Services/PlotService.luau`)
- Assigns each joining player a free plot (of `GameConfig.PlotCount`), builds it via `World/PlotBuilder.Build(plotIndex, player)`, tears down + frees on leave.
- `GetPlot(player: Player): Model?` — the player's plot model in Workspace.
- `GetPlotOwner(plotModel: Model): Player?`
- Spawns the player at their plot's spawn pad (sets `player.RespawnLocation`).

**PadService** (`Services/PadService.luau`)
- On profile load: shows/hides pad models on the player's plot per `Config/Pads` prereq graph (owned pads hidden, available pads visible, locked pads invisible).
- Touch handler on each pad: validate toucher is plot owner, has the money (`Catalog.GetPadCost`), pad's prereq owned, not already owned → deduct money, set `profile.pads[id] = true`, apply effect to `profile.upgrades` (factoryTier/conveyors/speed/luck/storage/displays = pad.level, always `math.max` with current), call `PlotBuilder.OnPadPurchased(plot, padId)` for visual growth, refresh pad visibility, `MarkDirty` + `Sync`, notify.
- Debounce per player-pad (0.5s) so touch doesn't double-fire.

**ProductionService** (`Services/ProductionService.luau`)
- Per online player with a loaded profile: a production loop per unlocked conveyor. Interval = `FactoryTiers[tier].baseInterval * GameConfig.SpeedMultPerLevel ^ speed`.
- Each production: `RollLogic.RollKeyboard`, build a belt item via `World/KeyboardModel.Build(def, scale)`, animate it riding the conveyor (TweenService along the belt from PlotBuilder's `BeltStart`/`BeltEnd` attachments), after `GameConfig.BeltRideSeconds` auto-collect: `InventoryService.AddKeyboard(player, keyboardId, "belt")`.
- Respects `GameConfig.InventoryCap` (production pauses at cap; notify once).
- One `Random.new()` per server, seeded once.

**InventoryService** (`Services/InventoryService.luau`)
- `AddKeyboard(player, keyboardId: string, source: string): Types.KeyboardInstance?` — creates uid (`HttpService:GenerateGUID(false)`), appends to profile, bumps `profile.collection[keyboardId]`, fires `KeyboardCollected` remote, server-wide flex `Notify("flex", ...)` if tier ≥ `GameConfig.GlobalFlexMinTier`, `MarkDirty` + `Sync`. Returns nil if at `InventoryCap`.
- `RemoveKeyboards(player, uids: {string}): {Types.KeyboardInstance}` — removes & returns matches; unequips/undisplays any removed uid.
- `GetKeyboard(player, uid: string): Types.KeyboardInstance?`

**EconomyService** (`Services/EconomyService.luau`)
- `AddMoney(player, amount: number)` / `SpendMoney(player, amount: number): boolean` (validates balance; updates `totalEarned` on add).
- Handles `SellRequest` remote: mode `"uids"` (array of uids, max 50) or `"belowTier"` (number 1..12 — sells every keyboard with rarityTier < N that is not equipped and not displayed). Value via `Catalog.GetSellValue` at the player's CURRENT factory tier. Rate limit: 2 requests/sec per player.
- Physical sell zone: touching the plot's `SellZone` part sells nothing by itself but opens the client sell UI (client detects touch locally; no server work).
- Money leaderstats (`leaderstats.Money` IntValue) kept in sync for the playerlist.

**ShowcaseService** (`Services/ShowcaseService.luau`)
- Handles `DisplayRequest(standIndex, uid?)`: validate stand unlocked (`upgrades.displays >= standIndex`), uid owned (or nil to clear), not equipped; update `profile.displayed[tostring(standIndex)]`, then place/remove a keyboard model + rarity-colored nameplate on the stand via `World/KeyboardModel.Build` at the plot's `DisplayStand{N}` anchor. Visual only for visitors — no interaction surface.
- Rebuilds displays from profile on load/respawn of plot.

**EquipService** (`Services/EquipService.luau`)
- Handles `EquipRequest(uid?)`: validate ownership; sets `profile.equippedUid`; welds a small keyboard model (`World/KeyboardModel.Build` at 0.5 scale) to the character's left hand; removes on unequip/death (rebuild on respawn).
- Handles `TypeKeyRequest`: rate limit `GameConfig.TypeRateLimitPerSecond`; if equipped, fire `SoundPulse(handleModelPrimaryPart, keyboardId)` to all players within `GameConfig.TypeSoundRange` (including sender) — clients render the actual sound.

**OfflineService** (`Services/OfflineService.luau`)
- Registers the offline processor with `DataService.SetOfflineProcessor`.
- Processor: given loaded profile, `secondsAway = now - lastSeen`; if ≥ `GameConfig.OfflineMinSeconds`, simulate production: perConveyorInterval as in ProductionService, `produced = min(floor(secondsAway / interval) * conveyors, cap - roomUsed…, cap, InventoryCap - #keyboards)` where cap = `OfflineCapBase` or `StorageCapPerLevel[storage]`. Roll each keyboard with RollLogic (same odds), append directly to profile + collection, return `OfflinePayload`.

### World builders (`src/server/World/`)

**PlotBuilder** (`World/PlotBuilder.luau`)
- `Build(plotIndex: number, player: Player): Model` — builds the full plot at its world position: ground, low-poly factory building (recolored by factory tier), 4 conveyor lanes (3 hidden until unlocked), sell zone counter, 6 display stands (hidden until unlocked), all buy-pads (cylinder pads with billboard label: name + cost), spawn pad. Parented to `Workspace.Plots`.
- Naming contract inside the returned Model: `Base`, `Factory`, `Conveyor1..4` (each with `Belt` part + `BeltStart`/`BeltEnd` attachments), `SellZone` (part), `DisplayStand1..6` (each with `ItemAnchor` attachment), `Pads` folder with one Model per pad id, `SpawnPad` (SpawnLocation, Neutral=false + team-free via RespawnLocation), `Sign` (player name).
- `OnPadPurchased(plot: Model, padId: string)` — visual growth: reveal conveyor N, reveal display stand N, recolor/extend factory on factoryTier pads, small celebration particles.
- `SetPadVisible(plot: Model, padId: string, visible: boolean)`
- `Destroy(plot: Model)`

**KeyboardModel** (`World/KeyboardModel.luau`)
- `Build(def: KeyboardDef, scale: number): Model` — procedural low-poly keyboard: body slab + keycap grid using `look` colors/style, rarity glow (PointLight + slight neon keycaps) per `Rarities[def.rarityTier].glow`. PrimaryPart set, all parts Anchored + CanCollide false.

**HubBuilder** (`World/HubBuilder.luau`)
- `Build()` — central hub island: ground, cozy decorations, big "Grow a Keyboard" sign, global spawn for players whose plot isn't ready yet, paths toward the 8 plots arranged in a ring. Parented to `Workspace.Hub`. Called once at startup before PlotService accepts players.

## Client (`src/client`)

`init.client.luau` requires and starts controllers in `src/client/Controllers/`:
`UIController → SoundController → EffectsController`.
Each controller: table with `Start()`.

**UIController** — ALL UI built procedurally (no .rbxmx). ScreenGui with:
- Money HUD (top): animated count-up, abbreviated numbers (1.2K, 3.4M, 1B).
- Inventory button + panel: scrolling grid of owned keyboards grouped by rarity (color-coded tiles: name, rarity, sell value), actions per tile: Equip/Unequip, Display (pick stand), Sell. Bulk bar: "Sell all below [rarity dropdown]" → `SellRequest("belowTier", n)`.
- Collection book button + panel: all 36 keyboards; undiscovered = dark silhouette + "???", discovered shows count. Progress header "23/36".
- Odds panel (small, toggle): live `RollLogic.GetOdds` for your current tier/luck, listing each rarity % (this is the pity/transparency display).
- Toasts (Notify remote): info/error small; "flex" messages styled with rarity color. Big center celebration for own rolls ≥ `CelebrateMinTier` (KeyboardCollected remote).
- Offline popup (OfflineReport remote): "While you were away: +N keyboards (best: X)".
- Sell zone proximity: when local character touches own plot's `SellZone`, auto-open inventory panel on the Sell tab.
- Renders exclusively from the latest `DataSync` snapshot (single `currentProfile` state + re-render).

**SoundController** — plays keyboard signature sounds:
- `KeyboardCollected` → play that keyboard's sound layers (from Catalog) at collect + rarity sting for celebrates.
- `SoundPulse(part, keyboardId)` → 3D: play layers parented to the part with jitter.
- Local typing: when equipped, any keyboard keypress (UserInputType.Keyboard, gameProcessed false) plays the sound locally immediately (with jitter) AND fires `TypeKeyRequest` (throttled client-side to the same rate limit) so others hear it.
- Implements layers: for each `SoundLayer` create Sound (PlaybackSpeed ±jitter), play, destroy after.

**EffectsController** — collect pop particles at belt end (listens KeyboardCollected + finds own plot), rarity beam to sky on ≥ `CelebrateMinTier` rolls on your plot, subtle sparkle on displayed high-tier keyboards (client-side ParticleEmitters on own + others' display stands via `Workspace.Plots` scanning).

## File ownership (for parallel work — do NOT edit files outside your set)

1. Data: `Services/DataService.luau`, `Services/OfflineService.luau`
2. World: `World/PlotBuilder.luau`, `World/KeyboardModel.luau`, `World/HubBuilder.luau`
3. Production: `Services/ProductionService.luau`, `Services/InventoryService.luau`
4. Economy: `Services/PadService.luau`, `Services/EconomyService.luau`, `Services/PlotService.luau`
5. Showcase: `Services/ShowcaseService.luau`, `Services/EquipService.luau`
6. Client: everything under `src/client/`
7. Sound design: `Config/Keyboards.luau` sound specs only (verified asset IDs)

`init.server.luau` is written at integration time.

## Verification

- `rojo build default.project.json -o build.rbxlx` must succeed.
- `luau-analyze` (with Roblox type defs) must pass on all `src/**` files.

---

# Phase 2 — Mutations, Rebirth, Index, Leaderboards, Events, Monetization, Race, Likes

New shared contracts (DONE — consume, don't restructure): `Config/Mutations`,
`Config/IndexRewards`, `Config/Events`, `Config/Products`, `GameConfig.Rebirth/
Race/Event*/Leaderboard*`, `Types` additions (KeyboardInstance.mutation;
Profile.rebirths/indexClaimed/likesReceived/passes/boosts), Remotes additions
(`RebirthRequest`, `ClaimIndexReward`, `RaceState`),
`RollLogic.RollMutation(rng, chanceMult)`, `RollLogic.GetEffectiveLuck(profile,
now, eventLuckBonus)`, `Catalog.GetMutation(id?)`,
`Catalog.GetSellValue(keyboardId, factoryTier, mutation?, rebirths?)`,
`Config/Pads` rebirth pad (kind "rebirth", cost -2 = dynamic, repeatable).

Cross-cutting rules:
- EVERY luck read goes through `RollLogic.GetEffectiveLuck(profile, os.time(), eventLuckBonus)`.
  The active event is published by EventService as Workspace attributes
  `ActiveEventId: string` ("" = none) and `ActiveEventUntil: number`; readers
  look up luckBonus/mutationMult in Config/Events themselves.
- EVERY sell-value read passes the instance's mutation and profile.rebirths.
- Mutations: production + offline rolls call `RollLogic.RollMutation(rng, mult)`
  where mult = active event's mutationMult (default 1). InventoryService.AddKeyboard
  gains an optional `mutation: string?` parameter stored on the instance;
  KeyboardCollected payload gains `mutation: string?`.
- DataService default profile + reconcile must cover the new Profile fields
  (rebirths=0, indexClaimed={}, likesReceived=0, passes={}, boosts={}).

### New/changed server services (Init/Start pattern, appended to bootstrap order)

**RebirthService** — handles the plot's rebirth pad (PadService special-cases
kind "rebirth": never marks owned, delegates to `RebirthService.OnPadTouched(player)`)
AND the `RebirthRequest` remote (UI button). Validates factoryTier == 12 and
money >= `GameConfig.Rebirth.BaseCost * CostMult ^ rebirths`. Effect: deduct
cost, rebirths += 1, reset money to 0, upgrades.factoryTier/conveyors/speed/
luck/storage back to base (1/1/0/0/0; displays KEPT), clear profile.pads
EXCEPT display pads, keep keyboards/collection/displayed/equipped. Rebuild plot
visuals (PlotService exposes `PlotService.RebuildForProfile(player)` — new
public function that re-applies pad visuals + PadService.RefreshPads). Server-wide
flex Notify + celebration. Updates the rebirth pad's cost label per player.

**IndexService** — `ClaimIndexReward` remote: validate reward id exists,
not already claimed, distinct-discovered count (#keys of profile.collection)
>= reward.count; then EconomyService.AddMoney(cash), profile.indexClaimed[id]=true,
MarkDirty+Sync, Notify. (Luck bonus applies automatically via GetEffectiveLuck.)

**LeaderboardService** — OrderedDataStores `GAK_Earned_v1` and `GAK_Collection_v1`
(collection score = sum over discovered ids of rarityTier^2). Writes each
player's scores on save cadence (subscribe OnProfileLoaded + a 60s loop, pcall
everything, skip in Studio fallback). Reads top `GameConfig.LeaderboardSize`
every `LeaderboardRefreshSeconds` and renders onto the hub's leaderboard
boards (SurfaceGui text lists — boards built by HubBuilder additions:
`HubBuilder.BuildLeaderboards(): (Part, Part)` returning the two board parts,
called from LeaderboardService.Start via a new hub lookup `workspace.Hub:FindFirstChild("EarnedBoard"/"CollectionBoard")`).

**EventService** — loop: wait random(EventMinInterval..EventMaxInterval), pick
weighted event from Config/Events, set Workspace attributes, Notify ALL
("event", name .. " — " .. tagline), after duration clear attributes + Notify
end. Expose `EventService.GetActive(): (EventDef?, number)` for server readers
(ProductionService/OfflineService use it for luckBonus + mutationMult; offline
uses none).

**MonetizationService** — on profile load: for each gamepass with id ~= 0,
pcall MarketplaceService:UserOwnsGamePassAsync -> profile.passes[key]. Connect
PromptGamePassPurchaseFinished to re-check. ProcessReceipt for dev products:
resolve by id, grant cash (EconomyService.AddMoney) or boosts
(profile.boosts[key] = os.time() + duration; luckParty also sets
boosts.serverLuckParty on EVERY online player's profile for 300s), MarkDirty+
Sync, return PurchaseGranted (ProductPurchaseDecision.PurchaseGranted; NotProcessedYet on any failure).
Gamepass effects consumed elsewhere: doubleLuck (GetEffectiveLuck — done),
doubleStorage (OfflineService cap *2), extraStands (ShowcaseService allows
standIndex <= upgrades.displays + 2 and UI shows them), vip (InventoryService
flex prefix "👑 " + gold sign tag via PlotBuilder attribute).

**TypingRaceService** — loop every `GameConfig.Race.IntervalSeconds`: broadcast
RaceState {phase="joining", endsAt}; players join by standing on the hub race
pad (HubBuilder addition: `RacePad` part in Workspace.Hub) during the window;
then phase="racing" {endsAt}: count each ACCEPTED TypeKeyRequest (EquipService
exposes `EquipService.OnTypeAccepted(callback: (Player) -> ())` — new hook,
fired after rate-limit+equip validation) for joined players; score = presses *
(1 + equippedRarityTier/12). phase="finished" {scores}: winner gets
`BaseReward * factoryTier` cash, server flex. RaceState fired to all on every
phase change and each ~1s with live top scores while racing.

**LikeService** — ProximityPrompt on each plot's Sign ("Like this farm!",
HoldDuration 0.3). Triggered: visitor (not owner, once per (visitor, owner)
pair per server session) -> owner profile.likesReceived += 1, MarkDirty+Sync,
Notify owner, update sign text via PlotBuilder helper (sign shows
"<name>'s Keyboard Farm  ❤ N").

### World additions (PlotBuilder/HubBuilder edits)

- PlotBuilder: rebirth pad position (near factory center, distinct gold/white
  look), pad label refresh helper `PlotBuilder.SetPadLabel(plot, padId, text)`,
  sign like-count + VIP tag helpers, mutation-aware `KeyboardModel` calls pass through.
- KeyboardModel.Build(def, scale, mutation: MutationDef?) — optional 3rd param:
  tint body/keycaps toward mutation.tint (Color3:Lerp 0.55), rainbow flag adds
  a client-agnostic shimmer part tagged via attribute "Rainbow" (EffectsController
  animates hue on it), glitched adds flicker attribute. Sets attribute
  "Mutation" = id on the model.
- HubBuilder: two leaderboard boards (named EarnedBoard / CollectionBoard) +
  RacePad (named RacePad) on the plaza.

### Client additions

- UIController: mutation name+color on inventory/collection tiles and
  celebration card ("GOLDEN Thunder!" prefix in mutation tint); rebirth panel
  (rail button ⟳ visible at factory tier 12: shows cost, bonus preview, big
  button -> RebirthRequest); index claim buttons in collection book (claimable
  glow -> ClaimIndexReward); shop panel (rail button 🛒) listing gamepasses +
  dev products from Config/Products (id==0 -> "Coming soon" disabled;
  otherwise MarketplaceService:PromptGamePassPurchase / PromptProductPurchase);
  boost timers shown under money HUD; likes count on own plot already visible
  in world (no UI needed).
- New `Controllers/EventController.luau`: watches Workspace attributes,
  full-width event banner (name/tagline/countdown, event color), Lighting
  presets ("storm": dark ambient + fog + occasional thunder sound via
  rbxasset built-ins; "golden": warm ambient, ClockTime 17) with smooth
  tween in/out and full restore.
- New `Controllers/RaceController.luau`: RaceState UI — join hint banner,
  countdown, live top-3 while racing, podium toast at finish.
- SoundController: applies mutation soundPitchMult/extraJitter when playing
  (KeyboardCollected payload + SoundPulse gain optional mutation field;
  equipped local typing reads mutation from the equipped instance).
- EffectsController: hue-cycles parts with attribute "Rainbow"; flickers
  models with attribute "Mutation" == "glitched".

---

# Phase 3 — Restock shop, spectacle, gifting, pity, ceremony (research-driven)

Shared contracts (DONE): Remotes `GlobalRoll`/`GiftRequest`/`SellReport`/
`BuyRestockItem`/`RestockSync` (payloads in Remotes.luau header), `Types.Profile.pity`,
`GameConfig.Pity/FriendBonus*/Restock`, `Config/RestockShop`,
**KeyboardModel moved to `src/shared/World/`** (client ViewportFrames can build it).

**RestockShopService** (NEW) — stall stock synced to wall clock:
`slotSeed = math.floor(os.time() / Restock.IntervalSeconds)`; roll Slots offers
by weight (seeded Random.new(slotSeed) so all servers stock identically),
track stockLeft per slot per cycle. Fire `RestockSync` to all on cycle change
(1s loop) + to joining players. `BuyRestockItem(slotIndex)`: validate slot,
stockLeft > 0, cost = offer.cost * profile.upgrades.factoryTier, SpendMoney,
apply effect: guaranteedRoll → roll rarity clamped ≥ tierFloor (uniform pick in
allowed tiers weighted by base odds renormalized), AddKeyboard with normal
mutation roll; luckSurge → profile.boosts["restock_luck"] = now + duration
(extend RollLogic.GetEffectiveLuck: a boosts key "restock_luck" with a future
expiry adds the luckBonus of the RestockShop luck_surge offer — one small
config lookup, keep it data-driven); mutationCharm → profile.boosts["mutation_charm"] =
now + 3600 AND in-memory charm counter {mult, rollsLeft} consumed by
ProductionService (expose `RestockShopService.ConsumeCharm(player): number?`
returning the mult while rolls remain); instantCash → AddMoney(cost * cashMult).
Rare offers (weight ≤ 3) appearing → Notify all ("flex", "🎁 LEGENDARY CRATE
in stock at the hub — 1 left!"). Stall world geometry: hub "CrateStall"
(HubBuilder addition) with SurfaceGui countdown "Restock in m:ss" (client
EffectsController or a small stall script — put countdown text updates in
RestockShopService via the List label pattern).

**Pity** — ProductionService: after each roll, if rolled tier >= Pity.TargetTier
then profile.pity = 0 else profile.pity += 1 (MarkDirty; no Sync per roll —
piggyback on AddKeyboard's Sync). Pass pity to RollLogic.GetOdds via new
optional 4th arg: `GetOdds(factoryTier, luck, pityCount?)` — when
pityCount > SoftStart, move `min((pityCount-SoftStart)*RampPerRoll, 1)` of the
below-TargetTier probability mass proportionally onto tiers >= TargetTier
(respecting maxRarity ceiling: if ceiling < TargetTier, pity is inert);
at pityCount >= HardGuarantee force tier >= min(TargetTier, maxRarity).
RollKeyboard gains the same optional arg. Odds panel shows the Thock Meter
(pity/HardGuarantee) — disclosed per Roblox paid-random policy.

**Spectacle** — InventoryService: for tier >= GlobalFlexMinTier OR mutation
valueMult >= 12, ALSO fire `GlobalRoll` to all clients with
{ playerName, keyboardId, mutation, rarityTier, plotIndex (plot attribute),
oddsDenominator = round(1 / (tierOdd * (mutationChance or 1))) }.
EffectsController: on GlobalRoll, render the sky beam + burst at that plot
(find plot by PlotIndex attribute) for EVERYONE; tier 11+ adds hub fireworks
(neon parts launched up + Emit burst at apex). Chat announce via
TextChatService:DisplaySystemMessage (RichText, rarity color, odds number)
in RaceController? No — new thin client controller NOT needed: UIController
handles the chat message + a marquee toast.

**Gifting + friend bonus** — GiftService (NEW): `GiftRequest(targetUserId, uid)`:
rate limit 1/2s; target = Players:GetPlayerByUserId, online + loaded profile +
inventory room; uid owned by sender, not equipped, not displayed; remove from
sender (InventoryService.RemoveKeyboards), append same instance (keep uid &
mutation) to target profile + collection bump + KeyboardCollected(source="gift")
to target; Notify both + server flex for tier >= 9 gifts. EconomyService:
friend bonus — cache `player:IsFriendsWith(other.UserId)` pairs (pcall, on
join vs each online player, both directions, invalidate on leave); sell total
*= 1 + min(FriendBonusPerFriend * friendsInServer, FriendBonusCap); include
the bonus amount in SellReport. EconomyService fires `SellReport` to the
seller after every successful sell (count, total, bestId, bestValue,
mutationBonus = extra earned from mutations vs base).

**Ceremony overhaul** (client) — UIController showCelebration: slot-cycle
anticipation (decelerating name wheel: task.wait(0.05 * 1.18^i), names in
rarity colors), duration by tier {5=0.9, 9=2.2, 11=4} (lookup w/ fallback),
tier 9+ freeze-then-flash tell (UIStroke pulse), 3D keyboard ViewportFrame
(KeyboardModel.Build client-side from Shared.World, WorldModel, slow spin via
RunService.RenderStepped, rarity Ambient), "NEW!" badge for first-time
collection entries + "23/36" ticker, tap/keypress skips to reveal, queue
collapse (>2 queued → highest-tier full ceremony + one summary toast).
SoundController: slot-tick per swap (PlaybackSpeed 0.8 * 2^(i/12)), reveal
arpeggio scaled by tier (k=1..min(tier,8), 2^((k*3)/12), 0.07s stagger),
then PlayKeyboard(id, nil, mutation) 0.4s later. Sell ceremony: on SellReport,
count-up cash ticks with rising pitch + floating "+$X" at sell zone +
separate gold line for mutationBonus.

### Phase-3 ownership
1. restock: Config already done; RestockShopService (NEW), HubBuilder edit (CrateStall), RollLogic edit (GetOdds/RollKeyboard pity arg + GetEffectiveLuck restock_luck key)
2. social-server: GiftService (NEW), InventoryService edit (GlobalRoll), EconomyService edit (friend bonus + SellReport), ProductionService edit (pity counter + charm consume)
3. client-ceremony: UIController edits (ceremony, sell ceremony, gift action in inventory overlay, Thock Meter in odds panel, restock stall UI panel via RestockSync + chat announce for GlobalRoll), SoundController edits
4. client-effects: EffectsController edits (GlobalRoll beams/fireworks for all)
5. init.server.luau: RestockShopService + GiftService (integration/main loop)

### Phase-2 file ownership (parallel build)

1. mutations-core: ProductionService, OfflineService, InventoryService edits (+KeyboardCollected payload), SoundController edits
2. progression: RebirthService (new), IndexService (new), PadService edit (rebirth kind), PlotService edit (RebuildForProfile), DataService edit (default profile + reconcile only)
3. world: PlotBuilder edits, KeyboardModel mutation param, HubBuilder additions (boards + race pad)
4. services-social: LeaderboardService (new), LikeService (new), EventService (new)
5. monetization: MonetizationService (new)
6. race: TypingRaceService (new), EquipService edit (OnTypeAccepted hook)
7. client-ui: UIController edits, EventController (new), RaceController (new), EffectsController edits
8. init.server.luau / init.client.luau service list updates: integration (owner: main loop)

---

# Phase 4 — Collection Update: secrets, sets, vault, fusion, aging

Shared contracts (DONE — consume, don't restructure):
`Types.KeyboardInstance.locked/stars/ageSeconds`,
`Types.Profile.likesGiven/setsClaimed`, `Types.CollectedPayload.stars`,
Remotes `VaultRequest`/`FuseRequest`, `GameConfig.Aging/Fusion/Secrets`,
`Config/Sets` (all 36 discoverable ids partitioned into 6 themed sets of 6),
`Config/Keyboards` secret boards (`secret = true`: `the_password`, `oofboard`,
`wholesome` — never roll, no set, excluded from the 36-counter),
`RollLogic.RollKeyboard` skips secret defs, `RollLogic.GetEffectiveLuck` adds
claimed-set luckBonus, `Catalog.GetSellValue(keyboardId, factoryTier,
mutation?, rebirths?, stars?, ageSeconds?)` (nil-safe: old call sites
unchanged), `Catalog.GetAgeStage(ageSeconds?)`, `Catalog.GetSet(keyboardId)`,
`Catalog.CountDiscoverable()`.

Cross-cutting rules:
- EVERY sell-value read for an owned instance now passes the instance's
  `stars` and `ageSeconds` (the extra args are nil-safe; flows you don't own
  keep working untouched, but flows you DO own must pass them).
- LOCKED (vaulted) instances are excluded from every destructive flow:
  selling (both modes), gifting, fusion inputs. Equip/display stay allowed.
- DataService default profile + reconcile must cover the new Profile fields
  (likesGiven=0, setsClaimed={}). KeyboardInstance.locked/stars/ageSeconds
  are optional — old saved instances need no reconcile.
- Secret grants use the normal `InventoryService.AddKeyboard` path so the
  full ceremony (KeyboardCollected, flex, MarkDirty+Sync) fires.

### New/changed server services (Init/Start pattern, appended to bootstrap order)

**SecretService** (NEW — `Services/SecretService.luau`) — ritual-typed secret
boards. EquipService change: `TypeKeyRequest` gains an optional `letter`
argument — the client sends the pressed key's single character when it is A-Z;
the server validates `typeof(letter) == "string"`, `#letter == 1`, alphabetic,
then uppercases it (anything invalid is treated as nil; the press still counts
for typing sounds/races). `EquipService.OnTypeAccepted` callbacks now receive
`(player, letter: string?)` — TypingRaceService ignores the new argument.
SecretService subscribes to OnTypeAccepted and keeps a per-player rolling
buffer of accepted letters (max 12 chars, cleared on unequip and on leave).
When the buffer ends with `"THOCK"` → grant `the_password`; `"OOF"` → grant
`oofboard` — once each; skip when the id is already in `profile.collection`.
Grants go through `InventoryService.AddKeyboard(player, id, "secret")`.
Public: `SecretService.CheckWholesome(player)` — grants `wholesome` (same
once-only rule) when `profile.likesGiven >= GameConfig.Secrets.WholesomeLikes`.
LikeService edit: after incrementing the OWNER's likesReceived, ALSO bump the
LIKER's `profile.likesGiven` (+MarkDirty+Sync the giver), then call
`SecretService.CheckWholesome(giver)`.

**SetsService** (NEW — `Services/SetsService.luau`) — auto-claims completed
collection sets. Public: `SetsService.CheckSets(player)` — for each
`Config/Sets` SetDef not yet in `profile.setsClaimed`: if all 6 keyboardIds
are discovered (`profile.collection[id]` and `> 0`), set
`profile.setsClaimed[set.id] = true`, Notify ALL ("flex",
`<player> completed the <name> set (+1 permanent luck)!`), MarkDirty+Sync.
The luck applies automatically via `RollLogic.GetEffectiveLuck` — no other
wiring. Called from: `DataService.OnProfileLoaded` subscription (claims sets
completed before this update), and by InventoryService at the END of
`AddKeyboard` via a lazy pcall-require of SetsService (avoids a require
cycle; if the module isn't loaded yet the pcall just no-ops).

**Vault** (InventoryService edit) — `InventoryService.Start` connects
`VaultRequest(uid, locked)` (rate limit: 3/s token bucket per player):
validate uid owned, `typeof(locked) == "boolean"`, set `instance.locked`
(store `true` or nil — don't persist `false`), MarkDirty+Sync. Consumers:
EconomyService sell flows (BOTH modes — "uids" skips locked uids, "belowTier"
never selects them), GiftService rejects locked uids, FusionService never
picks locked inputs.

**FusionService** (NEW — `Services/FusionService.luau`) — handles
`FuseRequest(keyboardId)` (rate limit: 1 per 2s per player). Validate
keyboardId is a string and `Catalog.GetKeyboard` resolves it. Candidates:
the sender's instances of that id that are unlocked, unequipped, undisplayed.
Group candidates by star value (`stars or 0`), ignore groups at
`GameConfig.Fusion.MaxStars`, and pick the LOWEST star value whose group has
`>= GameConfig.Fusion.Required` — fusing three 0-star makes a 1-star, three
1-star a 2-star, etc.; mixed-star fusing is never allowed. Within the chosen
group remove the `Required` cheapest (by `Catalog.GetSellValue` with the
instance's mutation/stars/ageSeconds at the player's factory tier) via
`InventoryService.RemoveKeyboards`, then add one instance of the same id with
`stars + 1` (cap MaxStars): `InventoryService.AddKeyboard` gains an optional
5th argument `stars: number?` stored on the new instance —
`AddKeyboard(player, keyboardId, source, mutation?, stars?)`; the
`KeyboardCollected` payload carries the new `stars` field; source `"fusion"`.
Notify the fuser; server-wide flex when the RESULT has stars >= 3.

**Aging** (ShowcaseService + OfflineService edits) — displayed keyboards age.
`ShowcaseService.Start` gains a loop every `GameConfig.Aging.TickSeconds`:
for each online player's DISPLAYED instances, `ageSeconds += TickSeconds`
(init nil → TickSeconds), MarkDirty; compare `Catalog.GetAgeStage` before vs
after — ONE Sync per player per tick only if any instance crossed a stage
boundary, otherwise stay silent (no Sync spam). When a displayed instance's
stage changes, re-render its stand: the nameplate gains a gold
`" · <stage name>"` suffix. `KeyboardModel.Build` gains an optional 4th
argument `ageStage: number?` (index into `GameConfig.Aging.Stages`, nil =
none): tint the body toward warm bronze by `ageStage * 0.12` lerp, and add a
soft gold PointLight at the final stage (Ancient). OfflineService edit: the
offline processor adds `secondsAway * GameConfig.Aging.OfflineRateMult` to
every DISPLAYED instance's ageSeconds (before the OnProfileLoaded rebuild, so
stands render the right stage on join).

### World additions (HubBuilder edit)

- **FusionForge** — `HubBuilder.Build` adds a "FusionForge" Model as a direct
  child of `Workspace.Hub` (idempotent: skip if it already exists): a chunky
  low-poly machine — hopper, lever, chimney — with a BillboardGui
  "⚒ FUSION FORGE — fuse 3 duplicates!". Visual/landmark only; fusion is
  driven entirely from the inventory UI.

### Client additions (UIController edits)

- Inventory tiles: a ★ row showing the instance's stars, and a 🔒 badge when
  locked. Action overlay per tile gains a "Lock"/"Unlock" toggle (fires
  `VaultRequest(uid, locked)`) and a "Fuse 3 duplicates" button — enabled when
  the player owns >= 3 fusable copies of that id (unlocked, unequipped,
  undisplayed, same star group below MaxStars — mirror the server rule);
  fires `FuseRequest(keyboardId)`.
- Collection book: secrets render in a separate "???" row — dark silhouette
  until discovered; discovered shows the name plus a "SECRET" tag. The
  progress header's denominator comes from `Catalog.CountDiscoverable()`
  (secrets don't count toward "N/36").
- Sets strip in the collection panel: one chip per `Config/Sets` entry
  showing `emoji + discovered/6`, rendered gold once `setsClaimed[set.id]`.
- Display nameplates: the age-stage suffix arrives from the server — the
  client does NO aging math.

### Phase-4 ownership (parallel build — do NOT edit files outside your set)

1. secrets-server: SecretService (NEW), EquipService edit (letter arg +
   OnTypeAccepted signature), LikeService edit (likesGiven + CheckWholesome)
2. sets-vault: SetsService (NEW), InventoryService edits (VaultRequest,
   CheckSets call, AddKeyboard stars arg), EconomyService + GiftService
   locked exclusions
3. aging-fusion: FusionService (NEW), ShowcaseService aging loop + stand
   re-render, OfflineService aging, KeyboardModel ageStage/star visuals
4. world: HubBuilder edit (FusionForge)
5. client: UIController edits
6. init.server.luau wiring (SecretService/SetsService/FusionService appended
   to the bootstrap order): integration

# Live-ops additions (landed alongside Phase 4 contracts)

## Typing income (EquipService)
Every ACCEPTED TypeKeyRequest (rate limit 10/s) on the equipped keyboard pays
`floor(GetSellValue(id, factoryTier, mutation, rebirths, stars, ageSeconds)
* GameConfig.TypingIncome.ValueFraction)`. Payouts accrue in EquipService and
flush through `EconomyService.AddMoney` once per `TypingIncome.FlushSeconds`
(AddMoney runs a full DataSync — never call it per keypress). The client is
told the per-press amount immediately via the `TypeReward` remote (server ->
client, amount: number) for the floating "+$" popup. Flush also runs on
PlayerRemoving, before the profile saves.

## Robux keycrates (Products/MonetizationService/HubBuilder/UIController)
Dev products with `keyboardTier: number?` grant a uniform-random NON-secret
keyboard of exactly that rarity tier through InventoryService.AddKeyboard
(normal ceremony fires). If the grant cannot land (inventory cap) the receipt
still consumes: fall back to cash = that board's sell value + Notify. Hub has
a "Keycrate Shop" kiosk with a touch pad named `RobuxShopPad` (client opens
the Robux shop panel on touch).
