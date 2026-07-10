# ⌨️ Grow a Keyboard

A Roblox tycoon where your factory produces collectible **keyboards** — from
soggy Scrap boards that tingle sadly, up to Godly keyboards that sound like
heaven. Sell, upgrade your factory with buy-pads, boost your luck, and flex
your rarest finds on display stands.

- **36 named keyboards** across **12 rarity tiers** (Scrap → Secret), each with
  its own signature key sound.
- Rolls are **70% factory tier / 30% luck** — upgrade both.
- Classic tycoon **buy-pads**: conveyors, factory tiers, speed, luck, storage,
  display stands.
- **Offline production** (capped) so there's always a pile of rolls waiting.
- Everything is code — the whole map is built procedurally at runtime.

## Play it in Roblox Studio (first-time setup)

You need [Rojo](https://rojo.space) to sync this repo into Studio.

1. **Install the Rojo Studio plugin**: in Studio, go to the Toolbox → search
   "Rojo" (by evaera/rojo-rbx) → install. Or grab it from
   https://create.roblox.com/store/asset/13916111004
2. **Install the Rojo CLI** on your computer:
   - Easiest (Windows/Mac): download the latest release from
     https://github.com/rojo-rbx/rojo/releases and put `rojo.exe` somewhere on
     your PATH.
   - Or with [Rokit](https://github.com/rojo-rbx/rokit): `rokit add rojo-rbx/rojo`
3. **Clone this repo** and from its folder run:
   ```
   rojo serve
   ```
4. In Studio: open a **new empty Baseplate**, delete the Baseplate part,
   then click the **Rojo plugin → Connect** (localhost:34872).
5. Press **Play**. Your plot builds itself, the first conveyor starts rolling
   keyboards, and the tycoon is live.

### One-shot build (no live sync)

```
rojo build default.project.json -o GrowAKeyboard.rbxlx
```

Then open `GrowAKeyboard.rbxlx` in Studio directly.

> **Note:** DataStores need a published place + "Enable Studio Access to API
> Services" (Game Settings → Security) to persist. Unpublished/offline Studio
> sessions automatically fall back to in-memory profiles — everything works,
> it just doesn't save.

## Repo layout

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system map, service APIs,
and the config files where every balance number lives.

```
src/shared   → ReplicatedStorage.Shared   (configs, roll math, remotes)
src/server   → ServerScriptService.Server (services + procedural world)
src/client   → StarterPlayerScripts       (UI, sounds, effects)
```

## Roadmap

- [x] Core tycoon loop (this repo)
- [ ] Trading UI (player ↔ player, Knife-Farm style)
- [ ] Crates / paid luck boosts (Robux products)
- [ ] Leaderboards (richest / best collection)
- [ ] More keyboards every update
