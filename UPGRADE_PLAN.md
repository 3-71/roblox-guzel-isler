# Grow a Keyboard — Research-Backed Upgrade Plan

Synthesized from a 5-angle web research sweep (hit-game mechanics, pacing science,
game-feel, monetization meta + compliance, discoverability). Sources: DevForum,
Roblox creator docs, GameDiscoverCo, Grow a Garden / Steal a Brainrot / PS99 /
Fisch / Sol's RNG / My Knife Farm analyses. Ranked by impact-per-effort.

## Applied already (config)

- **Faster first session**: first buy-pad reachable in ~30-45s (starter cash,
  cheaper early pads, faster tier-1 interval). Research: players decide to stay
  or leave in minutes 1-5; first core action should land within ~30s.
- **Rebirth at tier 6, not 12**: first prestige should hit in a focused first
  session (45-90 min), not days. Tier 12 is now a multi-rebirth long-term goal.
- **Mutations are online-only**: offline production keeps the habit, online
  presence earns the multipliers (Grow a Garden's exact split).

## Top 10 to build next (ranked)

1. **5-minute restock shop** (impact 5) — hub "Limited Crate" stall restocking
   on the wall clock (:00/:05/...), rare stock server-announced. THE proven
   30+ min session driver (GaG's most copied mechanic). Appointment gaming.
2. **Reveal ceremony overhaul** (5) — slot-cycle anticipation phase before
   showing the roll (decelerating name wheel, rarity-gated: 0.6s→2.5s),
   pitch-rising ticks, camera FOV punch + white flash on tier 9+, 3D keyboard
   in a ViewportFrame, "NEW! 23/36" index stamp, tap-to-skip, queue collapse.
   Arousal peaks BEFORE the reveal — currently we skip that window entirely.
3. **Shared spectacle** (5) — broadcast big rolls to ALL clients: sky beams
   over the roller's plot visible server-wide, RichText chat announcements
   with the odds number ("1 in 12,400!"), hub fireworks for tier 11+.
4. **Friend bonus + gifting** (5, small) — +10%/friend in server (cap +40%)
   sell bonus with a visible buff icon; gift duplicate keyboards hand-to-hand.
   Cheapest viral loop in the genre; safer than trading, ships sooner.
5. **Weekly drop ritual** (5, large) — "Keyboard Saturday": 1 limited keyboard
   per week, 7 days, then vaulted forever (= future trading blue chips).
   Register as Roblox Experience Events for free RSVP push notifications.
6. **Pity system** (4) — soft pity: Epic+ chance ramps after 50 dry rolls,
   hard guarantee at 80, visible "Thock Meter". Caps rage-quits, and near-pity
   players keep playing. MUST be in the odds disclosure panel (see compliance).
7. **Storm strikes on the belt** (4) — during Thock Storm, lightning VISIBLY
   strikes an in-flight keyboard and mutates it on the spot (procedural zigzag
   Neon bolts). Later: purchasable "Thock Rod" that attracts 3 strikes then
   breaks. This is GaG's core mutation theater.
8. **Rebirth = architecture, not just stats** (4) — each rebirth also grants
   +1 display stand and a visible plot ring cosmetic tier readable from the
   hub, plus a rebirth-exclusive keyboard line in the index.
9. **Sell ceremony** (4, small) — rolling cash counter with pitch-rising
   ticks, floating +$ labels at the sell zone, separate louder line for
   mutation payouts ("GOLDEN ×8 → +$44,800").
10. **Sound-test pedestal + ambient thock** (3) — hub pedestal with cinematic
    camera for typing any keyboard (built-in TikTok clip machine: #keyboardasmr
    is a huge native niche and our 36 signature sounds ARE the marketing
    asset); displayed keyboards emit quiet ghost key-ticks so the hub ring is
    a soundscape of everyone's collections.

## Monetization (compliance is a launch BLOCKER)

- Selling cash packs (or luck items) makes conveyor rolls "paid random items"
  → **numeric odds disclosure for all 36 keyboards is mandatory** (percentages
  summing to 100%, live-updating while boosts are active). Our odds panel is
  90% of the way there — add the per-keyboard details view + show odds deltas
  on luck product prompts ("Legendary: 0.5% → 1.0%").
- **PolicyService gating**: call GetPolicyInfoForPlayerAsync on join; hide
  cash packs / luck purchases for ArePaidRandomItemsRestricted users (keyboards
  stay fully earnable in play = compliant free path).
- Product ladder (Fisch-proven): Luck Potion 25-49R · Starter Pack 99R (once)
  · Luck Party 99/179/399R (2x/4x/8x server luck, 15 min, stacking, buyer
  gets hub-wide credit + fireworks) · +2 Stands 149R · 2x Storage 199R ·
  Auto-Sell 299R · 2x Cash 349R · 2x Luck 449R · VIP 699R (daily gifts, tag,
  golden leaderboard name — NO random items inside, keeps bonus-pool eligible).
- Fairness rules (regulator + player sentiment 2025-26): one currency only;
  every keyboard earnable in play (Robux buys speed + flex, never collection
  entries); no fake limited-quantity urgency on paid items.
- Read prices via MarketplaceService.GetProductInfo (not hardcoded) to unlock
  Price Optimization + Regional Pricing.

## Numbers (current targets)

- First pad ≤45s · 3-4 purchases in first 2 min · 8-12 in first 15 min.
- Factory tier waits ~1.4-1.7x the previous (t2 ~1.5min → t6 ~50min).
- Repeatable pads: 1.10-1.15x geometric costs.
- First rebirth: tier 6, 45-90 min in. Storage fills in 30-45 min early game.
- Weather cadence: minor event ~15-20 min, Thock Storm 60-90 min, Golden Hour
  2-4h; all 3-5 min long, loudly telegraphed 60s ahead.
- Values stay ≤ ~billions (K/M/B display) so prices stay legible for trading.

## Don't do

- No involuntary stealing (hype engine, not retention; churns victims;
  conflicts with cozy/flex positioning). If ever: opt-in heist event only.
- No second currency between Robux and cash. No paid-exclusive keyboards.
- No manufactured near-misses beyond honest presentation order.
- Don't push traffic before D1 ≥ 20-25% — the algorithm's cold-start window
  punishes weak first sessions and the false-negative loop is hard to escape.

## Launch checklist

- Title: keep **"Grow a Keyboard"** (Verb-a-Noun family + "keyboard" search
  spillover from Build A Keyboard); bracketed update tags weekly
  ("[🎲 NEW: Glitched]"). Fallback candidates if CTR is bad: Roll a Keyboard,
  Thock Tycoon.
- Genre: Simulation → tycoon/incremental. Description first line: "Roll,
  collect and flex 36 keyboards across 12 rarities — the thockiest tycoon on
  Roblox" + semantic keywords (collect, roll, luck, mutation, rebirth, ASMR).
- Icon: ONE Godly keyboard filling 60% of frame, rarity rim-light, radial
  gradient. 3 thumbnails: hero stand + beam; rainbow conveyor; Golden x25
  before/after. All procedurally screenshot-able from the runtime map.
- Ship a codes system (launch code "THOCK" = luck boost) → free evergreen
  coverage from RobloxDen/Gamerant-style codes pages.
- Soft launch quietly → tune D1 → then TikTok/Shorts 3-5x/week (sound-test
  pedestal clips, mutation pulls, storm footage) + micro-YouTuber outreach.
- Like prompt exactly once, at the first Epic+ pull. Monitor like ratio ≥85%.
