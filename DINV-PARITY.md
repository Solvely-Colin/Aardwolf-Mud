# dinv → aw-inv parity

Measured against Durel's original (18,804 lines) from a full four-part read of
its command surface, item engine, scoring engine and QoL modules. dinv's own
command names are in brackets. Current: aw-inv 2.5.0.

---

## Working

| Feature | dinv | Notes |
|---|---|---|
| Scan inventory / worn / keyring / containers | `build`, `refresh` | Rows recognised by shape; the prompt closes a scan. `{tag}` wrappers are not in this client's stream. |
| Identify database | `build` | `remove → id → wear` worn, `get → id → put` bagged, `keyring get/put` keyring. Vault skipped. Consumables identified once per name. |
| Query language | `query` | `key value` AND'd, `\|\|` OR, `min`/`max`, `~` negate, bare word = name, `all` / `worn` / `carried`. |
| Find, filter | `search` | `find <query>` + the panel's filter box. |
| Move items | `get`, `put` | `get <query>`, `put <bag> <query>`. |
| Custom keywords | `keyword` | `keyword add\|rm <word> <query>`, queried as `kw <word>`. |
| Forget stats | `forget` | `forget <query>`. |
| Scoring profiles | `priority` (partial) | dinv's seven class defaults + melee/defense. List, switch, edit weights, delete. |
| Item scoring | `score` | Effects flat-weighted from Affect Mods; `all_phys`/3, `all_magic`/17; specificity beats rollup. |
| Best per slot | `set display` (partial) | Top scorer per wear location at level, correct multi-slot counts, class-matched profile suggestion. |
| Consumables, portals | `consume` (partial), `portal` | `use <serial>` by type; `go <query>` holds, enters, restores what it displaced. |
| Area passes | `pass` | `pass <item> <secs>`. |
| Regen ring | `regen` | `regen auto` finds one by its regeneration affect and level. |
| Backup / restore | `backup` (partial) | Both stores to a plugin file. |
| Panel, menu, per-item buttons | — | Not in dinv; this client has widgets. |

---

## Missing

### A. Small — a session each

| Feature | dinv | What it needs |
|---|---|---|
| Wear a computed set | `set wear` | Conflict eviction (shield vs second vs hold; offhand weight ≤ ½ primary) and ordered store-then-wear — hands first, so Gloves of Dexterity grant dual wield before weapons go on. |
| Saved outfits | `snapshot` | Capture worn `{slot → serial}`, restore it. Nearly free once `set wear` exists — dinv reuses the same wear pipeline. |
| Ignored containers | `ignore` | A flag per container, honoured by scan, search, get/put and set building. |
| Return items home | `store` | Needs per-item "home container" — the bag it was last taken from. We see the `{invmon}` events that carry it; we just don't record them. |
| Auto-refresh interval | `refresh on\|off\|eager <min>` | We have on/off only, no period and no eager mode. |
| Verbosity | `notify` | none / light / standard / all. |
| Report to channel | `report <chan> item\|set` | Format an item or set summary and send it. |

### B. The analysis stack — the big one, in dependency order

| Feature | dinv | What it needs |
|---|---|---|
| Stat ceilings | `statBonus` | Scrape `stats`, parse the `Spells Bonus` row, keep a per-level moving average, compute `ceiling = min(200, level − 10×tier) − spellBonus`. **Everything below depends on this.** dinv ships a 211-row fallback table for a fresh install. |
| Optimal set per level | `analyze` | Simulated annealing over stat handicaps: build a set, find which stats are over the ceiling, lower those weights by `1/intensity`, rebuild, keep the best. 201 levels × intensity 8. |
| Where is this item used | `usage` | Pure lookup over a completed analysis. |
| What is this item worth | `compare` | Remove it, re-run the analysis, diff per level. |
| Should I bid on this | `covet` | Same, for an auction item identified via `bid <n>`. |

### C. Bigger subsystems

| Feature | dinv | What it needs |
|---|---|---|
| Weapon sets | `weapon <types>`, `weapon next` | Damage-type banning, dual-wield pairing (offhand ≤ ½ primary weight, waived for `soldier`), weapon-skill gating from a class/level ability table. |
| Consumable shops | `consume buy\|small\|big` | Categories with shop rooms and level-sorted items, `mapper goto`, buy N, quaff lowest or highest usable. |
| Container rules | `organize` | Per-container queries plus a sweep that files matching items automatically. |
| Level-banded weights | `priority` blocks | dinv's weights vary by level range (sanctuary worth 50 at level 10, 10 by level 100). Ours are flat. |
| Priority CRUD | `priority create\|clone\|copy\|paste\|compare` | We can list, switch, set weights, delete. No cloning, clipboard sharing, or comparing two priorities' output. |

### D. Filters we do not yet apply when ranking

dinv rejects items the character cannot actually use. We currently rank on
level alone.

- Alignment: `anti-good` / `anti-neutral` / `anti-evil` against your alignment
- `heroonly` unless base level ≥ 200
- Weapon types the class cannot wield at this level
- Portal-slot items without the Portal wish (needs `wish list` parsing)
- Priority slot bans (`~head`, `~second`) and damtype bans

---

## Deliberately not ported

- **`dbot.execute` critical sections.** dinv holds back your own typing with
  MUSHclient's `OnPluginSend` returning false, and proves the server queue is
  drained with `echo`-fence round trips. No equivalent hook exists here; our
  scan queue runs one command at a time instead.
- **Shell-out backups** (`xcopy` / `rmdir` / `rename`) — Windows-cmd specific.
- **Known dinv defects:** the `eqShield` slot typo in `set wear`, the
  `entry[2]` key bug in `priority new`, and the affect double-count that makes
  effects score twice per item but once per set.
