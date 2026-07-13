// Runs the game's actual shared modules (RollLogic, configs, Catalog) in a
// real Luau VM (luau-web) with tiny Roblox shims, then:
//  1. asserts odds are a valid distribution at every factory tier / luck level
//  2. asserts luck monotonically boosts high tiers
//  3. simulates income to sanity-check pad-cost pacing
import { LuauState } from 'luau-web';
import { readFileSync } from 'fs';

const state = await LuauState.createAsync();
const read = (p) => readFileSync(`src/shared/${p}`, 'utf8')
  .replace(/^--!strict\s*\n/, '')
  .replace(/require\(script[.\w()":\s]*?\.(\w+)\)/g, 'fakeRequire("$1")')
  .replace(/require\(script\)/g, 'nil');

const MODS = [
  ['GameConfig', 'Config/GameConfig.luau'],
  ['Rarities', 'Config/Rarities.luau'],
  ['FactoryTiers', 'Config/FactoryTiers.luau'],
  ['Keyboards', 'Config/Keyboards.luau'],
  ['Mutations', 'Config/Mutations.luau'],
  ['IndexRewards', 'Config/IndexRewards.luau'],
  ['Products', 'Config/Products.luau'],
  ['Pads', 'Config/Pads.luau'],
  ['Sets', 'Config/Sets.luau'],
  ['Catalog', 'Catalog.luau'],
  ['RollLogic', 'RollLogic.luau'],
];
let harness = [
  'Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end }',
  'local modules = {}',
  'function fakeRequire(name)',
  '  assert(modules[name] ~= nil, "missing module: " .. name)',
  '  return modules[name]',
  'end',
].join('\n') + '\n';
for (const [name, path] of MODS) {
  harness += 'modules["' + name + '"] = (function()\n' + read(path) + '\nend)()\n';
}
harness += "\n\nlocal RollLogic = modules.RollLogic\nlocal Catalog = modules.Catalog\nlocal FactoryTiers = modules.FactoryTiers\nlocal Rarities = modules.Rarities\nlocal Keyboards = modules.Keyboards\nlocal GameConfig = modules.GameConfig\nlocal Pads = modules.Pads\n\nlocal out = {}\nlocal function say(s) table.insert(out, s) end\n\n-- 1. distribution validity\nfor tier = 1, 12 do\n  for _, luck in { 0, 5, 10 } do\n    local odds = RollLogic.GetOdds(tier, luck)\n    local sum = 0\n    for r = 1, 12 do\n      assert(odds[r] >= 0, \"negative odds\")\n      sum = sum + odds[r]\n    end\n    assert(math.abs(sum - 1) < 1e-9, \"odds don't sum to 1: \" .. sum)\n    local maxR = FactoryTiers[tier].maxRarity\n    for r = maxR + 1, 12 do\n      assert(odds[r] == 0, \"rolled above factory ceiling\")\n    end\n  end\nend\nsay(\"odds: valid distribution at all 12 tiers x luck {0,5,10}, ceiling respected\")\n\n-- 2. luck monotonicity on the top reachable tier\nfor tier = 2, 12 do\n  local maxR = FactoryTiers[tier].maxRarity\n  local prev = -1\n  for luck = 0, 10 do\n    local odds = RollLogic.GetOdds(tier, luck)\n    assert(odds[maxR] >= prev, \"luck not monotonic\")\n    prev = odds[maxR]\n  end\nend\nsay(\"luck: monotonically increases top-tier odds at every factory tier\")\n\n-- keyboard pool sanity: 3 discoverable per tier (secret = true never rolls)\nlocal perTier = {}\nfor _, def in ipairs(Keyboards) do if not def.secret then perTier[def.rarityTier] = (perTier[def.rarityTier] or 0) + 1 end end\nfor t = 1, 12 do assert(perTier[t] == 3, \"tier \" .. t .. \" has \" .. tostring(perTier[t])) end\nsay(\"keyboards: exactly 3 discoverable per rarity tier (36 total)\")\n\n-- 3. pacing: expected income vs next factory pad cost\nlocal rngState = 42\nlocal rng = {\n  NextNumber = function() rngState = (1103515245 * rngState + 12345) % 2^31; return rngState / 2^31 end,\n  NextInteger = function(_, a, b) rngState = (1103515245 * rngState + 12345) % 2^31; return a + rngState % (b - a + 1) end,\n}\n\nsay(\"\")\nsay((\"%-6s %-12s %-12s %-14s\"):format(\"tier\", \"EV/keyboard\", \"income/min\", \"mins->next\"))\nfor tier = 1, 12 do\n  local odds = RollLogic.GetOdds(tier, 3) -- modest luck level\n  local ev = 0\n  for r = 1, 12 do\n    ev = ev + odds[r] * Rarities[r].baseValue\n  end\n  ev = ev * FactoryTiers[tier].valueMult\n  local interval = FactoryTiers[tier].baseInterval * GameConfig.SpeedMultPerLevel ^ 3 -- speed 3\n  local conveyors = math.min(1 + math.floor(tier / 3), 4)\n  local perMin = ev / interval * 60 * conveyors\n  local nextCost = tier < 12 and FactoryTiers[tier + 1].padCost or 0\n  local mins = tier < 12 and nextCost / perMin or 0\n  say((\"%-6d %-12.1f %-12.0f %-14.1f\"):format(tier, ev, perMin, mins))\nend\n\nreturn table.concat(out, \"\\n\")\n"

const loaded = state.loadstring(harness, 'sim');
if (typeof loaded !== 'function') {
  console.log('SIM_COMPILE_FAIL:', String(loaded).slice(0, 400));
  process.exit(1);
}
try {
  const result = await loaded();
  console.log(String(result));
  console.log('\nSIM_OK');
} catch (e) {
  console.log('SIM_RUN_FAIL:', String(e.message || e).slice(0, 600));
  process.exit(1);
}
