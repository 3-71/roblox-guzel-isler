export const meta = {
  name: 'phase5-fleet',
  description: 'Build Phase 5 (Thock Monster boss, streak calendar, new weather skies, Thock Buddies) with 5 builders per the ARCHITECTURE.md ownership, then verify',
  phases: [{ title: 'Build' }, { title: 'Verify' }],
}

const REPO = '/home/user/roblox-guzel-isler'

const COMMON = `You are one builder in a 5-agent fleet implementing "Phase 5 — Thock Monster, Streak Calendar, New Weather, Thock Buddies" of the Roblox tycoon "Grow a Keyboard" (repo: ${REPO}, Luau --!strict, tabs, doc comments state constraints).

MANDATORY FIRST STEPS: read ${REPO}/CLAUDE.md (project memory: style, hard-won lessons) and ${REPO}/ARCHITECTURE.md — especially "# Phase 5" (YOUR binding contract; the shared contracts listed there are ALREADY LANDED — consume them, never edit shared files or another slot's files).

Style: ModuleScript services with Init()/Start(); every remote handler validates types + token-buckets; after profile mutations call DataService.MarkDirty(player) + DataService.Sync(player). Sounds: engine rbxasset:// built-ins only, layered/pitched. World helpers: part(name, size, cf, color, MATERIAL?, PARENT) — parent in the material slot once destroyed every plot; audit arity on every call you write. Pure decoration parts: CanCollide/CanTouch/CanQuery = false.

VALIDATE before finishing (all three, from ${REPO}):
1. node tools/check-luau.mjs   -> "All files compiled cleanly"
2. node tools/sim-economy.mjs  -> "SIM_OK"
3. ~/.cargo/bin/rojo build default.project.json -o /tmp/build-p5.rbxlx

Do NOT run git commands. Do NOT edit init.server.luau. Return a compact summary: files, public API, behavior, validation results, anything the integrator must wire.`

phase('Build')
const SLOTS = [
  { key: 'boss', prompt: `${COMMON}\n\nYOUR SLOT: "boss" — Services/BossService.luau (NEW) + World/BossBuilder.luau (NEW), exactly per ARCHITECTURE.md Phase 5 item 1. The owner (a kid) explicitly decided: damage to player bases is TEMPORARY VISUALS ONLY (smoke/cracks in a "BossDamage" Model per plot, destroyed at fight end) — never touch real plot parts, inventories, money or profiles beyond bossWins. Make the monster READ as a corrupted keyboard monster: cracked slab body, dangling keycap fists, one glitchy neon eye, broken-cable tail; stomp/roar with pitched rbxasset sounds; glowing weak-spot keycaps with server-side ClickDetectors that relocate after each click. PlotBuilder.GetPlotCFrame/GetRingRadius exist if you need plot positions (read PlotBuilder's public functions; do not edit it).` },
  { key: 'calendar', prompt: `${COMMON}\n\nYOUR SLOT: "calendar" — Services/StreakService.luau (EDIT), exactly per ARCHITECTURE.md Phase 5 item 2. Read the existing streak logic first and keep it fully intact; the calendar is additive. Legendary grant: uniform-random non-secret tier-9 def, InventoryService.AddKeyboard(player, id, "calendar"); verify AddKeyboard's cap behavior and fall back to cash = that board's sell value + Notify so the claim never silently fails.` },
  { key: 'weather', prompt: `${COMMON}\n\nYOUR SLOT: "weather" — src/client/Controllers/EventController.luau (EDIT), exactly per ARCHITECTURE.md Phase 5 item 3. Read the existing storm/golden presets + snapshot/restore + thunder task first and mirror those mechanics exactly (session counter kills stale tasks; Atmosphere presets required — classic fog is ignored while an Atmosphere exists). Add skies: "frost" (pale icy blue, dense bright haze), "static" (dark green-black + subtle ColorCorrection flicker task), "overclock" (hot orange, saturation push). Keep every existing preset byte-compatible.` },
  { key: 'buddies', prompt: `${COMMON}\n\nYOUR SLOT: "buddies" — Services/BuddyService.luau (NEW) + World/BuddyBuilder.luau (NEW) + Services/TypingRaceService.luau (EDIT: winner gets profile.raceWins += 1), exactly per ARCHITECTURE.md Phase 5 item 4. Buddies are cute low-poly critters (~2 studs: chunky body, stubby feet, emoji face on a SurfaceGui, tiny idle bob tween). One perches beside the owner's Conveyor1 (find the owner's plot via Workspace.Plots + OwnerUserId attribute; re-resolve every ~5s so plot rebuilds re-perch it), one follows the owner in the hub area (anchored PivotTo lerp on Heartbeat, behind the character). Clean up on unequip/leave. GetMutationBonus must be cheap (no yields) — ProductionService calls it on every roll.` },
  { key: 'client', prompt: `${COMMON}\n\nYOUR SLOT: "client" — src/client/Controllers/UIController.luau (EDIT), exactly per ARCHITECTURE.md Phase 5 item 5 (boss HP bar + warning/result banners from BossState; 📅 7-day calendar panel with ClaimCalendar; 🐹 buddy panel with BuddyEquip and earn-progress on locked cards). Read the file's mkPanel/renderer/hotbar conventions first and follow them. CRITICAL PRESERVE: everything already there (shop/keycrates, fusion panel, TypeReward popups, vault/star badges, sets strip, secrets row) stays fully intact.` },
]

const buildResults = await parallel(SLOTS.map(s => () =>
  agent(s.prompt, { label: `build:${s.key}`, phase: 'Build' })
))

// Barrier: verifiers must see the FINAL combined state of all five slots.
phase('Verify')
const VERIFY_COMMON = `You are an adversarial verifier on "Grow a Keyboard" (repo: ${REPO}). Five builders just implemented Phase 5 (see ARCHITECTURE.md "# Phase 5" for the binding contracts, and CLAUDE.md for hard-won lessons). Find CONCRETE breakage with evidence (file:line), not style nits. Read the diffs (git diff + git status for new files) and the consumers you need. You may not edit anything. Return "CLEAN" or "ISSUES" plus a numbered list, each with a one-line fix suggestion.`

const verifyResults = await parallel([
  () => agent(`${VERIFY_COMMON}\n\nYOUR SCOPE: server correctness. Check: BossService (damage window enforced server-side, BossState throttled, plot damage strictly inside a "BossDamage" Model + destroyed at fight end, bossWins MarkDirty/Sync, SetSellBoost args, no require cycles, monster cleanup on empty server), StreakService calendar (day math incl. grace reset, double-claim guard, token bucket, legendary cap fallback, boosts key "calendar_luck"), BuddyService (BuddyEquip validation, GetMutationBonus non-yielding and 0-safe, unlock sweep MarkDirty/Sync, visual cleanup on leave/rebuild), TypingRaceService raceWins increment, and that no slot edited shared contract files or init.server.luau.`, { label: 'verify:server', phase: 'Verify' }),
  () => agent(`${VERIFY_COMMON}\n\nYOUR SCOPE: client + world. Check: EventController new presets reuse snapshot/restore + session-counter task cleanup and keep storm/golden intact (Atmosphere handled — classic fog alone is dead); UIController additions follow existing conventions and did NOT break existing panels (grep the features listed in the prompt: shop, fusion, TypeReward, vault badges, sets strip); BossBuilder/BuddyBuilder part-helper arity (material slot vs parent slot on EVERY call), decoration parts CanCollide/CanTouch/CanQuery=false, ClickDetector weak spots server-side, monster path clamped off plots, buddy perch/follower cleanup. Also: BossState payload shape matches what UIController reads.`, { label: 'verify:client-world', phase: 'Verify' }),
])

return {
  build: SLOTS.map((s, i) => ({ slot: s.key, result: buildResults[i] ?? 'AGENT DIED — check files on disk' })),
  verify: { server: verifyResults[0] ?? 'VERIFIER DIED', clientWorld: verifyResults[1] ?? 'VERIFIER DIED' },
}
