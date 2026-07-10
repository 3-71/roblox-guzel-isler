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
