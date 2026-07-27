# Grow a Keyboard — project memory

Read this first. It is the durable memory of everything decided, built, and
learned on this project. Keep it updated when big things land.

## The user & how to work with them

- **Speak Dutch** in chat replies. Code, comments, and commits stay English.
- The owner is a young Roblox player/designer ("my knife farm" and Grow a
  Garden are the reference games). Explain things simply, show progress
  visually, celebrate wins. Never dump raw logs on them.
- They work on **Windows** now (previously Mac). They sync by downloading the
  branch zip and running `rojo build` — they do NOT use git or rojo serve:
  ```powershell
  cd ~
  Remove-Item -Recurse -Force roblox-guzel-isler-claude-roblox-keyboard-tycoon-mlbshx -ErrorAction SilentlyContinue
  Invoke-WebRequest -Uri "https://github.com/3-71/roblox-guzel-isler/archive/refs/heads/claude/roblox-keyboard-tycoon-mlbshx.zip" -OutFile game.zip
  Expand-Archive game.zip -DestinationPath . -Force
  cd roblox-guzel-isler-claude-roblox-keyboard-tycoon-mlbshx
  Invoke-WebRequest -Uri "https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-windows-x86_64.zip" -OutFile rojo.zip
  Expand-Archive rojo.zip -DestinationPath . -Force
  .\rojo.exe build default.project.json -o GrowAKeyboard.rbxlx
  start GrowAKeyboard.rbxlx
  ```
  Include this block whenever you tell them to look at new work.
- They repeatedly ask to "orchestrate engines and AI models" — they want
  multi-agent fleets for big builds. Contract-first + disjoint file ownership
  + adversarial verification is the proven pattern here.
- Progress page (Dutch, keycap design) lives at
  https://claude.ai/code/artifact/c59e72d2-484d-4243-84fd-98b50379ad37 —
  republish the same scratchpad HTML file path to update it (or pass the URL
  from a new session). Keep it fresh after every milestone.
- Git: work on branch `claude/roblox-keyboard-tycoon-mlbshx`, plain
  `git push -u origin <branch>` works (user installed the Claude GitHub App).
- Open questions the user never answered: publish the game on Roblox?
  weekly "Keyboard Saturday" content cadence?

## What the game is (locked design decisions)

Tycoon/collector: each of 8 players gets a plot with a keyboard factory.
Conveyors auto-produce collectible keyboards (36 rollable + 3 secrets, 12
rarity tiers Scrap→Secret, 3 per tier). Every board has a signature layered
sound built ONLY from engine `rbxasset://` built-ins (PING/SNAP/THUMP/etc.,
pitched and layered — no external asset ids anywhere).

- Rolls: **70% factory tier / 30% luck** (GameConfig.FactoryWeightShare).
- ALL purchases are classic walk-on buy-pads. Sell zone + bulk sell.
- Showcase display stands are visual-only flex (others can't use your boards).
- Mutations roll only while ONLINE; offline production never mutates.
- Offline production capped by storage level.
- Rebirth at factory tier 6 (research-tuned for a 45-90 min first prestige);
  cost 200k × 3^rebirths; +25% sell value & +1 luck per rebirth; keeps
  display stands AND walls; grows the rebirth tower one floor.
- Pity system (tier 7+ guaranteed by 80 dry rolls), daily streak luck (+1/day
  to +5), friends-in-server sell bonus, restock stall (5 min, server-synced),
  typing races, likes, gifting, events (storm/golden hour), leaderboards.
- Typing income: every accepted keypress on the equipped board pays
  `0.5 × sell value` (GameConfig.TypingIncome.ValueFraction). Payouts batch
  through one AddMoney per second. **Balance watch-item**: at 10 presses/s
  this out-earns production ~15×; the user explicitly asked for half value —
  if they complain about economy later, tune ValueFraction first.
- Monetization: gamepasses (2x luck, +2 stands, 2x storage, VIP) + dev
  products (luck potions, luck party, cash, 3 keycrates with guaranteed
  rarity). All product ids are 0 placeholders until the game is published.
- Phase 4 "Collection Update": secrets (type T-H-O-C-K / O-O-F on equipped
  board; 15 likes given), 6 collection sets (+1 luck each), vault locking,
  Fusion Forge (3 identical → 1 starred, max 5 stars, ×1.6 value/star),
  display aging (Broken-In 30m/×1.15 → Seasoned 2h/×1.4 → Ancient 8h/×2,
  half-rate offline).
- Buyable cosmetic walls (pads, survive rebirth): wood 2.5k → stone 40k →
  neon 900k → golden castle 12M.
- Trading is EXPLICITLY planned for later — vault/wishlist warm it up.

## Architecture (details in ARCHITECTURE.md — the binding contract doc)

- Rojo 7.7.0, Luau `--!strict` everywhere, tabs, doc comments state
  constraints. `default.project.json` maps src/{server,client,shared}.
- Server: ModuleScript services with `Init()`/`Start()`, bootstrap order in
  `src/server/init.server.luau` (22 services; Data → Plot → Pad → Production
  → Inventory → Economy → ... → Secret → Sets → Fusion).
- Every remote is validated server-side (typeof checks + token buckets).
  After profile mutations: `DataService.MarkDirty(player)` + `Sync(player)`.
- DataStore safety: saveCount staleness guard, per-user save lock, doNotSave
  sessions, ForceSave for receipts, grantedReceipts idempotency. The Profile
  type in Types.luau IS the schema; add defaults in DataService.defaultProfile
  (reconcile backfills old saves).
- `RollLogic.GetEffectiveLuck` is the ONLY luck aggregator (upgrades,
  rebirths, index, sets, boosts, streak, passes, event bonus).
- World naming contracts (never rename): plot children Base / Factory
  (FactoryWall recolors, Chimney + TierOrnament rings) / Conveyor1..4 (Belt +
  BeltStart/BeltEnd attachments) / SellZone / DisplayStand1..6 (ItemAnchor) /
  Pads folder (Model per pad id, "Pad" touch part) / SpawnPad / Sign
  (SignBoard) / WallTier1..4 / RebirthFloor1..5. Hub children: HubSpawn,
  boards (Title/List/Countdown labels), RacePad, CrateStall, KeycrateShop +
  RobuxShopPad, FusionForge + FusionForgePad.
- Client: 5 controllers under src/client/Controllers (UIController ~2600
  lines: mkPanel/renderer conventions, ceremony 2.0, shop, fusion panel,
  TypeReward money popups; Sound; Effects; Event; Race).

## Validation — run ALL THREE before every commit (from repo root)

```bash
node tools/check-luau.mjs      # real Luau compiler (WASM); must print "All files compiled cleanly"
node tools/sim-economy.mjs     # runs real RollLogic/Catalog in a Luau VM; must print "SIM_OK"
~/.cargo/bin/rojo build default.project.json -o /tmp/build-test.rbxlx
```
First time: `cd tools && npm install` (installs luau-web; node_modules is
gitignored). In Claude sessions rojo lives at `~/.cargo/bin/rojo`.

## Hard-won lessons (do not relearn these)

1. **part() arity killed production once**: PlotBuilder/HubBuilder helpers
   take `part(name, size, cf, color, MATERIAL?, PARENT)` — passing the parent
   into the material slot throws at build time and the WHOLE plot vanishes
   ("base weg"). Audit arity after every world edit; verifier agents must
   check it explicitly.
2. luau-web's `loadstring` returns an error STRING instead of throwing —
   a checker must test `typeof(result) === 'function'` or it passes
   vacuously.
3. Never embed Luau sources in JS template literals (backticks in Luau
   terminate them) — concatenate strings in harnesses.
4. Agent fleets die to session limits mid-run. Their FILES often survive —
   always check the working tree before redoing work; workflows support
   `resumeFromRunId` (unchanged prompts replay from cache).
5. An `Atmosphere` instance makes the engine IGNORE classic
   `Lighting.FogColor/FogEnd` — event moods must tween the Atmosphere
   (EventController does both since the world glow-up).
6. `EconomyService.AddMoney` runs a full DataSync — never call it per
   keypress/high-frequency; batch (see EquipService typing income).
7. Rebirth wipes pads EXCEPT kinds "display" and "walls" (prestige purchases
   survive). RebirthService → PlotService.RebuildForProfile → pads replay +
   SetRebirthFloors.
8. applyVisibility() parks Transparency/CanCollide/CanTouch in attributes and
   restores them exactly — decorations must be deco'd (CanCollide/CanTouch/
   CanQuery false) or they eat Touched events when revealed.
9. The user's Studio workflow can't use rojo serve (plugin install blocked by
   script-injection permission confusion) — never depend on live sync.
10. GitHub App must be INSTALLED (github.com/settings/installations), not
    just authorized, for pushes to work.

## State (2026-07-27)

~13,000 lines of Luau; all commits pushed. Shipped: full core loop, phases
2-4 (mutations/rebirth/index/leaderboards/events/monetization/race/likes;
restock/gifting/pity/ceremony/spectacle; secrets/sets/vault/fusion/aging),
typing income, keycrate shop, rainbow keyboards, world glow-up (packing
stations, festival hub, warm lighting), buyable walls (4 tiers), rebirth
tower (5 floors). A 31-agent adversarial review fixed 14 confirmed bugs
earlier; later fleets run build → verify as standard.

## ⏸ PHASE 5 IS MID-FLIGHT — resume here

Phase 5 = THOCK MONSTER boss (user's own design: monster attacks bases,
everyone types on it + clicks weak-spot keycaps; win = +25% sell 10 min,
lose = -25%; base damage is TEMPORARY VISUALS ONLY — user confirmed both
choices via Q&A), 7-day streak calendar (day 7 = guaranteed Legendary, 48h
grace), new weather (Cold Snap frozen x6 / Static Surge glitched x10 /
Overclocked typing x2) and 6 earnable Thock Buddies (never paid).

- CONTRACTS ARE LANDED AND PUSHED (commit "Phase 5 contracts"): configs
  (GameConfig.Boss/StreakCalendar, Config/Buddies, Events+bias+typingMult,
  frozen mutation), Types/Data defaults, Remotes (BossState/ClaimCalendar/
  BuddyEquip), EconomyService.SetSellBoost/GetSellMult, hooks in
  ProductionService/EquipService. ARCHITECTURE.md "# Phase 5" holds the full
  per-slot service contracts.
- The 5-builder + 2-verifier fleet script is saved at `tools/phase5-fleet.mjs`
  (self-contained, repo paths only). It was launched once and STOPPED at the
  user's request before any builder wrote files — the working tree was clean.
- To resume: run that script with the Workflow tool (fresh run; nothing to
  salvage), fix what the verifiers find, then wire BossService + BuddyService
  into init.server.luau (integration is NOT a fleet slot), run the validation
  trio, commit, push, update the artifact page, tell the user in Dutch with
  the PowerShell block.

Idea backlog (user-approved, unbuilt): harmony meter, titles & auras,
musical boards, mod workshop, daily thock jobs, rebirth talents, seasons,
thock thief, keycap climb, MEGA-boss variant.
