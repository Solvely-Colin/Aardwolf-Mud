# dinv → aw-inv parity

Measured against Durel's original (18,804 lines) from a full four-part read of
its command surface, item engine, scoring engine and QoL modules. dinv's own
command names are in brackets. Current: aw-inv 3.1.0.

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
| Level-banded weights | `priority` blocks | Stored as `name@minlevel`; a flat profile is one band. `max<stat>` cap bonuses and `~slot` bans included. |
| Item scoring | `score` | Effects flat-weighted from Affect Mods; `all_phys`/3, `all_magic`/17; specificity beats rollup. |
| Best per slot | `set display` (partial) | Top scorer per wear location at level, correct multi-slot counts, class-matched profile suggestion. |
| Consumables, portals | `consume` (partial), `portal` | `use <serial>` by type; `go <query>` holds, enters, restores what it displaced. |
| Area passes | `pass` | `pass <item> <secs>`. |
| Regen ring | `regen` | `regen auto` finds one by its regeneration affect and level. |
| Backup / restore | `backup` (partial) | Both stores to a plugin file. |
| Panel, menu, per-item buttons | — | Not in dinv; this client has widgets. |

---

## Missing

### A. Small

| Feature | dinv | Status |
|---|---|---|
| Wear a computed set | `set wear` | **Done** &mdash; `/awinv wear`, hands before weapons, displaced items off first. |
| Saved outfits | `snapshot` | **Done** &mdash; `/awinv snap save\|wear\|del`. |
| Ignored containers | `ignore` | **Done** &mdash; `/awinv ignore on\|off\|list`, honoured by ranking and search. |
| Return items home | `store` | **Done** &mdash; `/awinv store <query>`, using the bag an item was last found in. |
| Auto-refresh interval | `refresh on\|off\|eager <min>` | On/off only; no period or eager mode. |
| Verbosity | `notify` | Not ported. |
| Report to channel | `report <chan> item\|set` | Not ported. |

### B. The analysis stack

| Feature | dinv | Status |
|---|---|---|
| Stat ceilings | `statBonus` | **Done** &mdash; `/awinv stats` parses the Spells Bonus row and averages per level; seeded until then. |
| Optimal set per level | `analyze` | **Done, simplified** &mdash; `/awinv analyze [step]` sweeps in the background. Ours re-ranks per level; dinv additionally anneals stat handicaps, which sharpens results when several stats sit at their ceiling. |
| Where is this item used | `usage` | **Done** &mdash; `/awinv usage <query>`, and `/awinv plan <slot>` for one slot's upgrade path. |
| What is this item worth | `compare` | **Partly** &mdash; `/awinv compare <item>` reports the levels it wins and its score; it does not re-run the sweep without the item to diff stat totals. |
| Should I bid on this | `covet` | Not ported &mdash; needs auction scraping. |

### C. Bigger subsystems

| Feature | dinv | What it needs |
|---|---|---|
| Weapon sets | `weapon <types>`, `weapon next` | Damage-type banning, dual-wield pairing (offhand ≤ ½ primary weight, waived for `soldier`), weapon-skill gating from a class/level ability table. |
| Consumable shops | `consume buy\|small\|big` | Categories with shop rooms and level-sorted items, `mapper goto`, buy N, quaff lowest or highest usable. |
| Container rules | `organize` | Per-container queries plus a sweep that files matching items automatically. |
| Priority CRUD | `priority create\|clone\|copy\|paste\|compare` | We can list, switch, set weights, delete. No cloning, clipboard sharing, or comparing two priorities' output. |

### D. Eligibility filters

**Done:** level, `heroonly` under 200, alignment restrictions (anti-good /
anti-neutral / anti-evil), ignored bags, and `~slot` bans from the profile.

**Not yet:** weapon types the class cannot wield (needs the class/level
ability table), and portal-slot items without the Portal wish (needs
`wish list` parsing).

## Deliberately not ported

- **`dbot.execute` critical sections.** dinv holds back your own typing with
  MUSHclient's `OnPluginSend` returning false, and proves the server queue is
  drained with `echo`-fence round trips. No equivalent hook exists here; our
  scan queue runs one command at a time instead.
- **Shell-out backups** (`xcopy` / `rmdir` / `rename`) — Windows-cmd specific.
- **Known dinv defects:** the `eqShield` slot typo in `set wear`, the
  `entry[2]` key bug in `priority new`, and the affect double-count that makes
  effects score twice per item but once per set.
