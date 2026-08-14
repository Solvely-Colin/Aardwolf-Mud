# Aardwolf Mud

MUSHclient plugins for [Aardwolf](https://www.aardwolf.com/).

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
