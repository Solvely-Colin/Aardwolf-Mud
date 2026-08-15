# dinv → aw-inv parity

Where the MudForge port stands against Durel's original, from a full read
of dinv's 18,804 lines. dinv's own command names are in brackets.

## Done

| Feature | Notes |
|---|---|
| Inventory / worn / keyring / vault / container scan `[build, refresh]` | Wrapperless: rows are recognised by shape, the prompt closes a scan. dinv's `{tag}` markers are not in this client's stream. |
| Identify database `[build]` | `remove → id → wear` for worn gear, `get → id → put` for bagged, `keyring get/put` for keyring. Vault skipped (dinv marks it unsupported). Consumables identified once per name, not per object. |
| Query language `[query]` | `key value` AND'd, `\|\|` for OR, `min`/`max` prefixes, `~` negation, bare word matches name, `all` / `worn` / `carried`. |
| Find / search `[search]` | `find <query>`, plus the panel filter box. |
| Move items `[get, put]` | `get <query>` pulls matches to inventory; `put <bag> <query>` stows them. |
| Custom keywords `[keyword]` | `keyword add\|rm <word> <query>`, queryable as `kw <word>`, stored beside the identify record. |
| Forget `[forget]` | `forget <query>` drops stats so the next id re-reads them. |
| Scoring profiles `[priority]` | dinv's class defaults (psi, mage, cleric, warrior, thief, ranger, paladin) plus melee/defense. Weights editable per stat. |
| Item + set scoring `[score]` | Effects flat-weighted from Affect Mods; `all_phys`/3 and `all_magic`/17 rollups; specificity beats rollup. |
| Best per slot `[set display]` | Top identified scorer per wear location at or under level, correct multi-slot capacities. |
| Consumables + portals `[consume, portal]` | `use <serial>` picks quaff/eat/recite by type; `go <query>` holds, enters, and restores the displaced item a beat later. |
| Area passes `[pass]` | `pass <item> <secs>`. |
| Regen ring `[regen]` | `regen auto` finds one by its regeneration affect and level; worn on sleep, swapped back on waking. |
| Backup / restore `[backup]` | Both stores to a plugin file. |
| Panel + menu | Every action as a button; per-item actions by location. |

## Not yet ported

| Feature | Why it is harder |
|---|---|
| `set wear` | Needs conflict eviction (shield vs second vs hold, weapon weight rules) and ordered store-then-wear. Mechanical, just not small. |
| `analyze` (optimal set at every level) | dinv runs simulated annealing over stat handicaps, 201 times. Needs the stat-ceiling model below. |
| `statBonus` (spell-bonus ceilings) | Scrapes `stats`, keeps a moving average per level, and caps stats so eq is not wasted on what spellups already max. Drives the annealing. |
| `weapon <types>` / `weapon next` | Damage-type banning plus dual-wield pairing (offhand must weigh ≤ half the primary, unless soldier). |
| `snapshot` | Save/restore a literal worn outfit. Cheap once `set wear` exists — dinv reuses the same wear pipeline. |
| `usage`, `compare`, `covet` | All read a completed analysis. |
| `store` / `organize` | Needs "home container" tracking per item, which our invmon handling does not record yet. |
| `consume buy` | Shop rooms, `mapper goto`, restocking. |
| `ignore` | Containers excluded from scans and searches. |
| Level-banded priorities | dinv weights vary by level range; ours are flat. |

## Deliberately not ported

- The `dbot.execute` critical-section machinery. It rests on MUSHclient's
  `OnPluginSend` returning false to hold the user's own typing, which has no
  equivalent here. Our scan queue serialises one command at a time instead.
- `xcopy`/`rmdir` shell-outs for backups — Windows-cmd specific.
- Known dinv defects: the `eqShield` slot typo in `set wear`, the `entry[2]`
  key bug in `priority new`, and the affect double-count in item scoring
  (effects count twice per item, once per set).
