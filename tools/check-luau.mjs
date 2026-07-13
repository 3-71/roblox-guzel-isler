// Syntax/compile-checks every .luau file passed as argument (or under src/).
// Uses luau-web (real Luau compiler in WASM) — catches syntax errors incl.
// Luau type-annotation syntax. Does not typecheck against Roblox globals.
import { LuauState } from 'luau-web';
import { readFileSync, readdirSync, statSync } from 'fs';
import { join } from 'path';

const state = await LuauState.createAsync();

function collect(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) collect(p, out);
    else if (p.endsWith('.luau') || p.endsWith('.lua')) out.push(p);
  }
  return out;
}

const args = process.argv.slice(2);
const files = args.length ? args : collect('src');
let failed = 0;
for (const f of files) {
  const src = readFileSync(f, 'utf8');
  // loadstring compiles the chunk (syntax check) without running it.
  // Success -> function; compile error -> error STRING (it does not throw).
  const result = state.loadstring(src, f);
  if (typeof result === 'function') {
    console.log(`OK   ${f}`);
  } else {
    failed++;
    console.log(`FAIL ${f}\n     ${String(result).split('\n').slice(0, 4).join('\n     ')}`);
  }
}
console.log(failed ? `\n${failed} file(s) failed` : '\nAll files compiled cleanly');
process.exit(failed ? 1 : 0);
