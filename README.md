# Aardwolf Mud

MUSHclient and MudForge plugins for [Aardwolf](https://www.aardwolf.com/).

## Aardwolf Inventory (MudForge)

`aw-inv.lua` (v2.0.0) is a ground-up MudForge rewrite of Durel's Inventory
Manager (dinv). It captures Aardwolf's tagged data commands (`eqdata`,
`invdata`, `keyring data`, `vault data`), indexes every item by serial, and
shows worn, carried, container, keyring and vault contents in one searchable
panel with flags and serial numbers. `{invmon}` activity triggers a debounced
rescan so the panel follows looting on its own.

On top of that core sit the ported dinv features:

- **Identify database** — `/awinv id missing` walks your gear through `id
  <serial>` one item at a time and stores every stat the box reports, keyed
  by serial. `/awinv backup` and `/awinv restore` keep the stores safe.
- **Scoring and best-in-slot** — stat-weight profiles (`/awinv prio`), item
  scores in the panel, and a **best** view showing the top identified scorer
  per wear location at or under your level: dinv's analyze, as a panel tab.
- **Consumables & portals** — a **use** view grouping potions, pills,
  scrolls, food, portals and boats; `/awinv use <serial>` quaffs, eats or
  recites by type, `/awinv go <serial>` holds a portal and enters it.
- **Regen ring** — `/awinv regen <serial>`: typing `sleep` wears the ring
  first, and whatever it displaced is re-worn when you wake.

Type `/awinv` for the full command list. Requires the Aardwolf Core plugin
(GMCP + tag handling) from the
[aardwolf-mudforge](https://github.com/SeanStoves/aardwolf-mudforge) suite.

`dist/aw-inv.json` is the installable MudForge plugin blob built from the
same source.

## Boot Promotion Tracker

<img width="814" height="225" alt="image" src="https://github.com/user-attachments/assets/561de7db-cb97-462e-860f-b5afe8c2f372" />


`Boot_Promotion_Tracker.xml` (v1.9) tracks Boot Lyceum clan promotion requirements
(per [aardwolfboot.com/promotion-guide](https://aardwolfboot.com/promotion-guide)):
days in clan, QP earned, campaigns (gquest wins count 1:1), and goals completed —
across all four tiers (Neophyte→Acolyte through Ascendant→Savant).

It's fully self-seeding: type `whois` and every stat syncs from the game's own
ledger (Qp Earned, Campaigns Done, Gquests Won, Quests Complete); `score` syncs
goals. GMCP keeps QP live between checks, and campaign completions / your GQ wins
are counted as they happen. A draggable miniwindow shows live progress bars.

### Install

1. Copy `Boot_Promotion_Tracker.xml` into `MUSHclient/worlds/plugins/`.
2. In MUSHclient: **File → Plugins → Add**, select the file.
3. Set your clan induction date (the only manual input):
   `promo set joined YYYY-MM-DD`

### Commands

| Command | What it does |
| --- | --- |
| `promo` | progress report |
| `promo note` | draft promotion-request text for the board |
| `promo rank <1-4>` | which promotion tier to track |
| `promo hide` / `promo show` | toggle the progress window |
| `promo sync` | re-check the GMCP link |
| `promo help` | full command list |

To update: overwrite the file in `worlds/plugins`, then **Plugins → Reinstall**.
