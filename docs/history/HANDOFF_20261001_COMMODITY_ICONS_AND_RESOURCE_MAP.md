# Handoff 2026-10-01: new commodity icons, and how trade resources reach the map

Two pieces of work for the Zharr Exchange's "more commodities" idea. **Icons only and research
only** - no pack was built, nothing deployed, no DB row or key minted for any new commodity.

## 1. What was built

| Thing | Where |
|---|---|
| 26 commodity icons, 54x54 + 24x24 + 1254 raw | `Modding Files/source/exchange_icons/new_commodities/{large,small,raw}/` |
| Icon generator, Codex-driven | `tools/gen_commodity_icons.py` (`--resize`, `--check`, `--selftest`, names to redo) |
| Map/production survey | `tools/survey_resource_map.py` (`--selftest`) |
| Reference doc | `docs/TRADE_RESOURCES.md` |
| README section | `Modding Files/source/exchange_icons/README.md` "New commodities" |

The 26: amber, black_lotus, blackpowder, books, brass, brimstone, coal, dragon_bone, grain,
gromril, incense, ithilmar, jade, lustrian_plumes, olive_oil, pipeweed, quicksilver, rum,
salted_fish, salted_meat, sea_dragon_hide, silk, silver, tea, warhorses, whale_oil.
User excluded Warpstone and Madcap Mushrooms (faction-specific); Slaves left out (overlaps CHD Labour).

## 2. How the icons are made

`codex.exe` bundled in the VS Code ChatGPT extension, logged in with ChatGPT, `image_generation`
feature on, no API key. One `codex exec` per icon, 4 in parallel, ~6 min for 12. Style reference
= a strip of CA's 16 `_large` commodity icons passed with `-i`. Codex returns a 1254x1254 RGBA
with real alpha; the script copies it from `~/.codex/generated_images` using the path in Codex's
last message (`-o`).

Post-processing, every number fitted to the median of CA's seventeen at that size:

| | CA 54 | ours 54 | CA 24 | ours 24 |
|---|---|---|---|---|
| halo alpha 1/2/3 px out | 202/52/5 | 199/38/3 | 164/30/1 | 167/29/1 |
| object share of frame | 0.72 | 0.74 | 0.83 | 0.85 |
| saturation / brightness | 110/114 | 110/114 | 95/118 | 94/118 |

`SIZES` holds margin 0.16/0.08, saturation x0.69/x0.59, brightness x1.00/x1.13; halo = alpha
GaussianBlur(1.0) x3 in pure black underneath. `--check` re-measures and exits 1 on drift;
proven by running it on untoned icons (it failed).

## 3. Corrections found the hard way

- **Codex `-s workspace-write` generates nothing on this machine** - the unelevated Windows
  sandbox refuses "split writable root sets" and blocks the shell, the `-i` read AND the image
  tool. `-s read-only` works; let Codex only draw and copy the file yourself. (memory:
  codex-headless-image-generation)
- **"Fill" counted with the halo cannot tell a clipped halo from a roomy one** - the first fit
  chose margin 0 at 24px, which crops the halo at the frame. Fit the margin on the OBJECT's
  extent (opaque, non-black pixels) instead.
- **`res_rom_oil` is the PASTURES deposit**, not an unused key - I told the user otherwise and
  corrected it in the README. 22 IE regions, icon `resource_grain.png`.
- **9.0 counts moved**: 833 production rows, 820 `building_to_building_own` (notes said 823/810).
- **No gold or pastures production effect exists in 9.0.** `gen_zharr_exchange.py:378` still
  says they do - left untouched, flagged to the user.
- One colour factor for all icons dulls the reddest: Silk went crimson -> dusty rose.

## 4. Do not re-derive

- The table chain region -> slot template -> deposit -> permitted chains -> production effect ->
  resource is `docs/TRADE_RESOURCES.md` §1. `start_pos_region_slot_templates` is 0 rows in
  db.pack; read the Assembly Kit XML (`assembly_kit/raw_data/db/`).
- A deposit is the secondary slot's template variant (`..._secondary_iron`), not its own slot.
- Golden Idols come from `res_gold` deposits (TMB/LZD/DWF/SLA only). Beer and Trinkets have no
  deposit: Dwarf tavern and HEF industry are ordinary buildings allowed in ~366 templates.
- The five CHD deposits producing nothing in vanilla are exactly `CHD_TRADE_GRANT`'s five.
- A new commodity cannot get new map deposits without shipping a startpos; attach production
  rows to existing chains instead (§7 of the doc).

## 4b. Added later the same day

- `tools/guess_region_commodities.py` -> `Modding Files/reference/region_commodity_guesses.csv`:
  lore rules placing the 26 commodities by coast, climate, area, province, origin culture and
  deposit. `check()` bounds every rule (1 to 30% of IE) - it caught Ithilmar at 0 (Ulthuan is
  all `climate_island`). `docs/TRADE_RESOURCES.md` §9.
- Production needs a building in vanilla (837 of 837 rows in `building_effects_junction`, none
  in bundles/techs/skills/items), but not a resource building and not in the region - see §8.
  Region effect bundle route is documented API, never used by CA for production: untested.

## 5. Open

- **Test in game first:** a region effect bundle carrying a production effect - does it
  produce, and does the trade screen list it? Decides whether the region guesses can be used
  directly or must become building rows.

- Whether the game's trade screen / trade agreements accept a mod-added resource - untested.
  **Test pack built and in `data/`**: `derpy_more_resources.pack`, Salted Fish on port chains
  (`tools/gen_more_resources.py`, `docs/TRADE_RESOURCES.md` §10). Planned as its own mod.
  **Verified in IEE 2026-10-01**: production, tooltip, map label and Trade Agreement all work.
- Visual pairs at 24px: Rum vs Quicksilver (both bottles), Silk vs Tea (both red), thin Dragon
  Bone and Salted Fish. `py tools/gen_commodity_icons.py <names>` redraws.
- The stale comment at `gen_zharr_exchange.py:378`.
- DONE: per-region listing, `survey_resource_map.py --regions` ->
  `Modding Files/reference/region_resources.csv`. Spot-checked against the live-measured
  regions in memory (Martek iron, Karag Dromar beer, Tor Achare). "Ordinary" must be counted
  over templates WITHOUT that good's deposit - counting all templates called every iron mine
  ordinary (22 iron deposit templates > the threshold of 20).
