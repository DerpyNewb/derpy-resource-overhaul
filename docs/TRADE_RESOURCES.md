# Trade resources: how they are placed on the map and produced

For the current mod-wide rules, see [Derpy Resource Overhaul: mechanics reference](RESOURCE_OVERHAUL_MECHANICS.md). This file preserves dated research and implementation notes; later corrections supersede earlier counts and assumptions.

Measured 2026-10-01 against the 9.0 `db.pack` and the Assembly Kit's raw start-position data.
Re-run the survey after a patch: `py tools/survey_resource_map.py` (RPFM can stay shut).

The Zharr Exchange's side of this - how the market reads production and prices it - is in
`sessions/HANDOFF_20260905_EXCHANGE_OWNERSHIP_STATS.md` §24-§25 and
`sessions/HANDOFF_20260909_EXCHANGE_TRADE_RESOURCES_AND_INTRO.md`. This doc is the game's side.

## 1. The chain, one table per link

```
start_pos_region_slot_templates     campaign + region + slot_type  -> slot_template
slot_templates.resource             slot_template                  -> the deposit (blank on 416 of 671)
slot_template_permitted_building_chains   slot_template -> chain | super_chain | chain_set (+ remove)
building_chain_sets.parent_set  +  building_chain_set_items        chain_set -> chains / superchains
building_chains.building_superchain       superchain -> every culture's chain in it
building_levels.chain                     chain -> its level keys
building_effects_junction                 level -> wh_main_effect_region_resource_<stem>_production
effect_bonus_value_resource_junction      that effect -> the resource it produces ("production")
resources_tables                          the resource: unit, trade_value, icon
resources_to_campaign_junctions           which campaigns the resource exists in
```

**The first link is not in `db.pack`.** `start_pos_region_slot_templates` has 0 rows there; it
is compiled into the start position. The readable copy is the Assembly Kit's
`assembly_kit/raw_data/db/start_pos_region_slot_templates.xml`. Changing it means rebuilding
the startpos, which no mod can do without shipping a whole map.

## 2. How a region gets a deposit

A deposit is **not a separate slot**. Each region's slots (primary, secondary, port) get a
template, and a resource region's secondary slot simply uses a resource variant of the normal
one: `wh_main_human_minor_secondary` becomes `wh_main_human_minor_secondary_iron`, and that
template's `resource` column is `res_rom_iron`. That is what `region:resource_exists()` reads.

Landmark regions use their own template (`wh_main_special_nuln_secondary_iron`, ...), which may
or may not carry a resource. 255 of 671 templates carry one.

Deposit regions per resource:

| Resource | Shown as | Immortal Empires (572 regions) | Realm of Chaos (242) | Own deposit? |
|---|---|---|---|---|
| `res_rom_iron` | Iron | 25 | 8 | yes |
| `res_rom_timber` | Timber | 25 | 8 | yes |
| `res_rom_marble` | Marble | 18 | 10 | yes |
| `res_animals` | Exotic Animals | 13 | 4 | yes |
| `res_gems` | Gemstones | 13 | 5 | yes |
| `res_rom_furs` | Furs | 13 | 4 | yes |
| `res_rom_textiles` | Pottery | 13 | 3 | yes |
| `res_dyes` | Dyes | 12 | 5 | yes |
| `res_rom_lead` | Salt | 12 | 3 | yes |
| `res_obsidian` | Carved Obsidian | 11 | 4 | yes |
| `res_rom_wine` | Wine | 11 | 1 | yes |
| `res_spices` | Spices | 11 | 4 | yes |
| `res_medicine` | Medicinal Plants | 10 | 3 | yes |
| `res_ivory` | Tusks | 6 | 5 | yes |
| `res_gold_idols` | Golden Idols | - | - | **no** - see §4 |
| `res_rom_glass` | Dwarf Beer | - | - | **no** |
| `res_trinkets` | Elven Trinkets | - | - | **no** |

**Per region:** `py tools/survey_resource_map.py --regions` writes
`Modding Files/reference/region_resources.csv` - every region in every campaign with its
deposit, every trade good some culture can produce there, and which of those need no deposit.
IE: 231 of 572 regions can produce a trade good, 50 of them something they have no deposit
for; RoC 78 of 242. The ordinary buildings of §4b are left out of the rows (they would put
Animals, Furs, Beer and Trinkets on nearly every region). Deposits differ between campaigns:
Nuln has iron in Realm of Chaos and nothing in Immortal Empires.

The prologue has 15 regions and no deposits. All 17 tradeable resources are listed in
`resources_to_campaign_junctions` for both `wh3_main_combi` and `wh3_main_chaos`.

**Deposits that are not trade goods** (`trade_value` 0): `res_gold` 15/7, the four troll
deposits, `res_savage`, `res_fortress`, `res_empire_fort`, `res_bastion`, `res_location_colony`,
and **`res_rom_oil` - which is the PASTURES deposit**, not oil: a Rome II key CA reused, icon
`resource_grain.png`, 22 IE regions, and every culture's pasture chain is what it permits. It is
not a free key for a new commodity.

## 3. What can be built on a deposit

A resource template permits a **superchain**, and the superchain holds one chain per culture.
Which one the owner sees depends on `building_chain_availability_sets` for its culture. So an
iron deposit is one slot, and the building in it is the Empire mine, the Dwarf mine, the Chaos
Dwarf mine, and so on.

Every deposit template permits at least one producer of its own resource. But **some cultures'
chains on a deposit produce none of it**, so whether a deposit produces depends on who owns it:

- **Daemons** (`dae`, `kho`, `nur`, `tze`) and **Nagash** (`dlc29_nag`): no output on any deposit.
  Their chains use the deposit for other effects.
- **Chaos Dwarfs**: gems, iron, timber, marble and obsidian produce nothing in vanilla (they feed
  armaments and raw materials instead). `CHD_TRADE_GRANT` in `gen_zharr_exchange.py` adds
  production rows for exactly those five. Chaos Dwarf gold and pastures also produce nothing.
- **Greenskins**: animals and gems produce nothing.
- **The WH1 `_military` chains** (`wh_main_EMPIRE_resource_iron_military`, timber and pastures
  variants for Empire, Bretonnia, Greenskins, Vampires, Dwarfs): alternative chains on the same
  deposit that give military effects and no trade good.

## 4. Three ways a region produces

**a. A deposit and its resource building.** The ordinary case. Output by tier comes from the
production effect, scope `building_to_building_own`; a standard culture chain tops out at 45 a
turn, and the full range is 2 to 144.

**b. An ordinary building, no deposit needed.** These are allowed in nearly every secondary slot:

| Produces | Building | Culture |
|---|---|---|
| Exotic Animals | `wh2_main_def_beasts`, `wh2_main_lzd_beasts` | Dark Elves, Lizardmen |
| Furs | `wh3_main_ksl_bears`, `wh3_dlc24_ksl_bears_mother_ostankya` | Kislev |
| Dwarf Beer | `wh_main_DWARFS_tavern` | Dwarfs |
| Elven Trinkets | `wh2_main_hef_industry`, `wh3_dlc27_hef_colony_economy_income` | High Elves |

This is why Beer and Trinkets have no deposit at all, and why
`resource_exists` is false in regions that produce them.

**c. A special template or landmark.** A region's own template permits a producer without
carrying the deposit:

- **Golden Idols come from GOLD deposits.** Tomb Kings, Lizardmen, Dwarfs and Slaanesh
  (`*_resource_gold`, plus `wh_main_special_brightstone_mine`) build on `res_gold` and produce
  Golden Idols. Nobody else's gold mine does.
- **The Wood Elf forests** (Laurelorn, Gryphon Wood, the Witchwood, Kings' Glade and ten more)
  produce Furs, Timber, Wine, Pottery and Trinkets from their own chains.
- **One-off landmarks**, by resource: Wine at Wurtbad, Pfeildorf, Skeggi, the Moot; Salt at
  Al Haikk and Dok Karaz; Iron and Marble at Hag Graef; Iron, Dyes, Spices and Pottery at
  Erengrad; Gems at the Star Tower, Dragon Fang Mount, the Bone Gulch and Darkhold; Obsidian at
  Iron Rock and the Star Tower; Medicine at Itza and Laurelorn; Beer at Karak Azorn, Karag Dromar
  and Sartosa. `wh2_main_special_peg_street_pawnshop` (Sartosa) makes five goods at once.

The survey prints the full region list for each.

## 5. Production modifiers and oddities

- **One building can produce several goods.** 27 do. Hag Graef's mines make iron and marble.
- **Some buildings consume.** The Underdeep drinking halls carry -2 to -10, scoped
  `foreign_building_to_region_own` (other regions). Only `building_to_building_own` means
  "produces here": 820 of the 833 production rows in 9.0 (it was 810 of 823 before).
- **Province-wide percentage boosts:** `wh2_main_effect_region_tradable_resource_production`,
  scope `building_to_region_provincewide`, on Kislev's `ksl_trade_order_4/5` (+30/+50, only
  while the faction has trade) and Cathay's Tiger Court `yin_2/3` (+15/+30).
- **Damage halves output, ruin zeroes it** - `value_damaged` / `value_ruined` on every row.
- **9.0 added a "disable" effect per resource** (`wh3_dlc29_effect_region_disable_resource_*`,
  bound as `bonus_value_id = disable`), used by Nagash.
- **`wh_main_DWARFS_resource_water`** carries beer production but no slot template permits it:
  dead content.
- **No production effect exists for gold or pastures.** An older note claimed `res_gold` carried
  one; the 9.0 tables have none.

## 6. Reading it at runtime

There is no `region:resource_production()`. Walk `region:slot_list()` -> `slot:has_building()`
-> `slot:building():name()` and look the key up in a map baked from §1 (the Exchange's
`EX_PRODUCTION`). Measured at 10ms for the whole IE map. `region:resource_exists(key)` answers
only "is the deposit here" - see §4 for why that is not supply.

## 7. What a new commodity would take

Of the 26 new icons in `Modding Files/source/exchange_icons/new_commodities/`:

1. **The resource row** - `resources_tables` (key, unit, `trade_value` > 0, icon path) and
   `resources_to_campaign_junctions` for each campaign.
2. **A production effect** - an `effects_tables` row, plus an `effect_bonus_value_resource_junction`
   row binding it to the resource with `bonus_value_id = production`, plus its loc.
3. **A source.** Two routes:
   - **Placing new deposits on the map** needs `start_pos_region_slot_templates`, which only a
     rebuilt startpos changes - incompatible with every other map mod. Not practical.
   - **Attaching production to buildings that already exist** - `building_effects_junction`
     rows on existing chains, the way `CHD_TRADE_GRANT` does it. No map edit, and the
     deposit can be an existing one (Brimstone on obsidian, Coal on iron) or none at all, like
     Beer and Trinkets.
4. **The Exchange side** - `PRODUCTION_STEMS`, the 17-commodity asserts in
   `gen_zharr_exchange.py`, its per-commodity text and bundles.

Untested: whether the game's own trade screen and trade agreements accept a mod-added
resource. Everything in this doc is read from data; none of it was tried in game.

## 8. Does production need a resource building?

Not a *resource* building - but in vanilla it always needs **something carrying the effect**,
and that something is always a building. Every one of the 837 production rows in 9.0 is in
`building_effects_junction`; **zero** are in effect bundles, technologies, skills, ancillaries
or traits. The building does not have to be a resource building or even be in the region:

| Scope | Rows | Meaning |
|---|---|---|
| `building_to_building_own` | 820 | a building produces in its own region (mines, but also taverns, beast pens, landmarks) |
| `foreign_building_to_region_own` | 10 | the Underdeep: a building in one region changes another's output |
| `force_to_region_own` | 3 | the Spirit of Grungni's beer hall - a **horde army's** building produces into whatever region the army stands in |
| `building_to_region_provincewide` | 4 | +% to every resource in the province (Kislev Trade Order, Cathay Tiger Court) |

So the two routes for a mod are: **production rows on chains that already exist** (proven -
`CHD_TRADE_GRANT`), or **an effect bundle on the region**, `cm:apply_effect_bundle_to_region(
bundle, region_key, 0)` with a production effect in a region scope. The call is documented;
**CA never uses a bundle for production**, so whether the engine and the trade screen honour
it is the first thing to test in game.

## 9. Guessing where a new commodity belongs

`py tools/guess_region_commodities.py` writes `Modding Files/reference/region_commodity_guesses.csv`:
every region with its signals and the commodities its rules match. A design table only.
Signals: coastal (a port slot; 134 IE regions), climate (`campaign_map_settlements`, 7 IE
regions have none), CA's AI area groups, province, starting culture
(`start_pos_regions.cultural_originator`), deposits and template keys. Each rule in `RULES`
carries its lore line. IE: 399 of 572 regions get a guess.

Found while writing them: **Ulthuan is `climate_island` throughout** (30 of 34 regions), never
mountain, so a mountain test for Ithilmar matched nothing. **The Graves of the Dragons stand on
the Plain of Bones** - The Bone Gulch in IE, Darkhold in Realm of Chaos. `check()` refuses a rule
that matches no IE region or more than 30% of them, and a signal that loads empty.

## 10. The Salted Fish test pack (Derpy Resource Overhaul)

`tools/gen_resource_overhaul.py` builds `Modding Files/Modpacks/derpy_resource_overhaul.pack`, one good
to prove a mod-added resource works before the other 25 are built. Deployed to `data/` 2026-10-01,
**not yet tested in game.** Planned as its own mod; the Exchange will detect it rather than ship a
compat pack.

**What a tradeable good touches**, found by sweeping all 1,600 vanilla tables for `res_rom_lead`
(Salt, the donor) rather than tracing outward - two of these were missing from §7:

| Table | Rows | What it is |
|---|---|---|
| `resources_tables` | 1 | the good; `trade_value` 50 like every tradeable |
| `resources_to_campaign_junctions_tables` | 2 | IE + Realm of Chaos |
| `commodities_tables` | 1 | **the price list** - only the 17 tradeables have a row; 10 per unit |
| `cai_personality_strategic_resource_values_tables` | 78 | **the AI's value of the good**, one per strategic component, cloned from Salt |
| `effects_tables` + `effect_bonus_value_resource_junction_tables` | 1 + 1 | the production effect bound to the good |
| `building_effects_junction_tables` | 120 | the source |
| loc | 4 | name, description, long description (blank, as CA), effect text |

Icons: `ui/campaign ui/effect_bundles/resource_derpy_salted_fish.png` (24px) and `_large.png`
(54px), the same pair CA ships per good.

**Source:** every chain the startpos lets into a port slot (63), minus the 16 owned by daemons, the
undead (Tomb Kings, Nagash) and Beastmen. 6 / 8 / 12 per level, half when damaged - CA's own figures
for a good made by an ordinary building (Dwarf tavern Beer, High Elf industry Trinkets). Reach: 134
of 572 IE regions and 26 of 242 Realm of Chaos regions have a port slot. The guess tool's "no
chaotic climate" condition cannot be expressed per building, so a Norscan or Chaos-Warriors port
still fishes.

**In game, check:** a port's tooltip lists "Salted Fish resource production"; the settlement
info bar shows the icon; a trade agreement lists Salted Fish and raises trade income; the
economy panel's trade tab names it. Any of those failing answers §7's open question.

**Map mods (2026-10-01).** IEE (`cr_combi_expanded`) gets its own pack,
`derpy_resource_overhaul_iee.pack`, holding only the `resources_to_campaign_junctions` row. A row
naming a campaign that is not loaded is an unresolvable foreign key and the game refuses the
whole pack, so it cannot sit in the main one. IEE does the same for CA's 18 goods in its
`!cr_vanilla` fragment. No production rows are needed for IEE: its 67 own port templates
(`cr_port_*`) all permit only CA's `wh3_main_port_core_generic` set, which the 47 chains
already cover, and `check_submod()` fails the build if a future IEE update adds a port chain we
do not.

**The Old World (2026-10-04).** `derpy_resource_overhaul_oldworld.pack` links the 37 goods to
`cr_oldworld` (Workshop 3081800026, 1,463 regions; its "devastate" variant 3813271876 reuses the
key and ships no regions, so this one pack covers both). Unlike IEE, the Old World ships its own
buildings in our slots, and `check_submod()` caught them: the Kraka Ravnvake port (and its Wood
Elf variant), Mordheim's Wood Elf settlement and a Realm of Chaos outpost. A row naming one of
those levels can only ship beside them, so the sub-pack now carries 90
`building_effects_junction` rows: production on those four chains (`submod_pool_chains()`, the
main pack's pool rules over the map's own chains), their store twins plus twins of three Old
World landmarks that make CA's iron, marble and obsidian, and store space on the outpost.
`check_submod()` now measures coverage against the rows built, and the selftest cuts each
chain's rows and expects a failure. The blanket-area guard was narrowed: it fired on Norscan
mead (all 158 Old World Norsca regions, as on IE's 31) and Athel Loren starwood (all forest);
it now flags only areas CA's maps lack, by a rule with no terrain condition, which is the Ind
incense fault it was written for. Goods placed by region name (Nuln, Sartosa, Altdorf...) now
also name the `cr_oldworld_region_*` keys, the AI script knows 78 Old World rare-good regions,
and the Map tab draws the Old World's own minimap (2048x2048). Built and deployed to `data/`,
still unseen: the Old World map crashed at startup with no derpy pack loaded (36).

**Live check, IEE turn 1 (2026-10-01), over the wh3 bridge.** Both packs load next to IEE, with no
script errors from them. The `CcoResourceRecord` reads back whole (Salted Fish, barrels, price 10,
trade value 50, icon, description). Built ports carry the effect and its text, "Salted Fish
resource production: 6 barrels", formatted exactly like CA's "Elven Trinkets resource
production: 6 chests" on High Elf industry. Checked on TEB, Kislev, Dark Elf, and a Skaven port
in an IEE-only region (`cr_combi_region_kasar`); the Tzeentch port carries nothing, as excluded.
**Still untested: the trade screen and a trade agreement.**

Three calls that look like checks and are not:
- `region:resource_exists(key)` and the settlement's CCO `ResourceList` report **map deposits
  only** - both say no for Tor Achare's Trinkets, which its industry building produces.
- `faction:trade_resource_exists(key)` returns **true for a made-up key**, and false for every
  real good the faction lacks, so a true answer means nothing.
- What works: `CcoCampaignSettlement` (settlement CQI) ->
  `BuildingSlotList.At(i).BuildingContext.EffectList.JoinString(LocalisedText, " / ")`.

**Map label (2026-10-01).** The settlement label's resource row (`resource_list` in CA's
`ui/campaign ui/city_info_bar.twui.xml`) is filled by the engine from **map deposits only**: Bay
of Blades' port makes Salted Fish and its label showed nothing (the user looked). So the main
pack overrides that file, rebuilt from the live `ui3.pack` on every run by
`gen_resource_overhaul.py`: one 24px icon per good, inserted right after `resource_list` in
`icon_holder` (a HorizontalList, so it flows beside the deposit icon), shown by
`ContextVisibilitySetter` on `BuildingSlotList.Any(BuildingContext.EffectList.Any(EffectKey ==
"<production effect>"))`. That expression was measured live first: true at Bay of Blades,
Swamp Town and Dietershafen, false at the excluded Tzeentch port and at Tor Achare. Tooltip loc
`uied_component_texts_localised_string_derpy_mr_<good>_Tooltip`. TWUI Studio's reader reports
no issue on CA's file or ours. **The one compatibility cost of the mod**: any other mod that
overrides `city_info_bar.twui.xml` wins or loses by load order (none of 68 loaded mods does
today). Re-run after any patch that touches the label.

**Trade confirmed in game (2026-10-01, IEE).** A diplomacy Trade Agreement lists Salted Fish
(the fish icon) among the traded goods on both sides. So a mod-added resource is fully accepted
by the engine: production, building tooltip, map label (our override) and trade agreements.
§7's open question is answered - yes. The Zharr Exchange does not list it, by design: its
commodity list is hardcoded and the detection hook is not built yet.

## 11. All 37 goods (2026-10-01)

Built and deployed; **not yet checked in game**. 37 goods (the first 26 plus carpets, kvas,
rhinox hides, mead, glassware, wool, porcelain, pearls, starwood, feathers, wyvern scales),
5,055 production rows, 41 lore conditions, 7 new units (`derpy_horses`, `_crates`, `_bolts`,
`_flasks`, `_rolls`, `_hides`, `_bales`, each in `commodity_unit_names` plus singular/plural
loc), 37 label icons. The first build (26 goods, all common goods on the main settlement) had
11,861 rows; moving them to economy buildings cut that.

**Where a good comes from = a building pool AND a lore condition on that building's region.**
The condition is a `building_effect_context_expressions_tables` row (v2: expression, key,
display_only_active_effects, always_show_display_text) named in the production row's
`context_requirement`. CA gates 11 of its own production rows this way (`FactionHasTrade`,
`RegionHasAdjacentDwarfFaction`). The vocabulary used, all CA-proven in that table except the
one marked:
- climate: `Region.IsEffectBundleActive("wh3_dlc20_climate_<state>_<climate>")` over the three
  states, CA's own `MountainClimate` form (`Region.ClimateKey` exists but no CA row uses it);
- `Region.HasResource`, `Region.IsOriginatingSubcultureOneOf`, `Region.RecordKeyIsOneOf`;
- area: `Region.BelongsToRegionGroup("cai_region_hint_(sub_)area_<x>")` - **documented on
  CcoCampaignModelRegion but CA only uses it on sea regions; unverified on land.** IEE puts 189
  of its 236 regions in these groups and adds Ind, Nippon and Khuresh.

| Pool | Chains | Per level | Goods |
|---|---|---|---|
| port | 47 port chains | 6/8/12 | salted fish, whale oil, sea dragon hide, rum, amber, pearls |
| farm | 17 farm/growth chains (`KIND_CHAINS`) | 6/8/12 | grain, pipeweed, olive oil, tea, plumes, black lotus, incense, salted meat, kvas, rhinox hides, mead, wool, starwood |
| industry | 19 industry/income chains | 6/8/12 | silk, jade, carpets, glassware, porcelain; the second source of coal, brimstone, brass, blackpowder |
| stables | 5 stable chains | 6/8/12 | warhorses, feathers |
| mine | the resource chains on the named deposits | 6/8/12 | coal (iron), silver, gromril, quicksilver, brimstone (obsidian), brass (Dark Lands iron), blackpowder (salt), ithilmar (Ulthuan ore) |
| settlement | every main-settlement chain (ruins, prologue, dummies dropped) | 4/6/8/10/12 | books, dragon bone, wyvern scales, ithilmar's second source (Vaul's Anvil) |

**Common goods sit on the green economy buildings, not the main settlement.** `KIND_CHAINS` is
an explicit list because `chain_category` (money/military/happiness) is too coarse to tell a
farm from a tavern. **No fallback, by the user's lore ruling:** a race with no building of a kind
makes none of those goods and gets them by trade or raiding - Chaos Dwarfs make no farm goods,
Norsca and Vampire Counts no farm or industry goods, and only Bretonnia, the Empire, High Elves,
Kislev and Norsca breed warhorses; only Bretonnia and the Empire keep eyries for feathers. One deliberate exception: Norscan mead also comes
from Norsca's main settlement (`("settlement", "nor")` pool - the jarl's hall is the mead hall).
`check()` asserts no farm/industry chain of those races creeps back in, and that every listed
chain is buildable in a secondary slot and carries a race tag.

Rare goods (sea dragon hide, gromril, ithilmar, dragon bone, black lotus, starwood, feathers,
wyvern scales) are scaled x0.5; the two single-place goods (pipeweed, books) x2. Daemons, the
undead and Beastmen make nothing. The rare eight are meant to get their own buildings later;
not built yet.

**The rules table is the spec.** Each condition is a tuple tree that `render()` turns into the
expression and `evaluate()` runs against `guess_region_commodities.signals()`. `check()` asserts
that for every IE and Realm of Chaos region, each good reaches exactly the regions that tool's
`RULES` name, so the lore table and what ships cannot drift. The selftest feeds it four wrong
rules (loosened, a dropped condition, the wrong place, an area typo) and each one fails.
IEE-only areas extend four rules (silk and tea to Ind and Nippon, black lotus to Khuresh,
incense to Ind) without touching that parity. `check_submod()` now asserts IEE's own port,
primary and deposit templates only permit chains our pools cover.

**Open: the map label with conditioned effects.** The label shows a good when any building's
`EffectList` holds its production effect. If `EffectList` also lists effects whose condition is
false, a settlement would show e.g. a Grain icon outside the farmland. Check a non-farmland
settlement (Zharr-Naggrund) in game. If it shows Grain, the label expression needs the condition
added.

## 12. The rare goods' own buildings (2026-10-01)

Built and deployed; **not yet checked in game**. Eight three-level chains, `derpy_mr_bld_<good>`,
12 tables (the template set minus units allowed and slot unlocks; **no AI score row**, so the
AI never builds them and keeps the half-rate by-products of §11). Every wide row is cloned off
`wh_main_DWARFS_industry` levels 1-3.

| Good | Built by | Icon frame |
|---|---|---|
| gromril | Dwarfs | `dwarf_gold` (chains) |
| ithilmar | High Elves | `high_elves_resource_gold` (horns) |
| dragon bone | every culture in `CULTURES` (user: whoever holds the Plain of Bones) | none - glyph alone |
| sea dragon hide | Dark Elves | `dark_elves_resource_gold` |
| black lotus | Dark Elves, Skaven | `dark_elves_resource_gold` |
| starwood | Wood Elves (also in the wef forest set) | none - glyph alone |
| feathers | Bretonnia, Empire (and the teb roster) | `empire_gold` |
| wyvern scales | Greenskins, Ogres | `wh_main_grn_resource_gold` (gear) |

**Icons, `tools/gen_building_icons.py`.** CA's resource-building icons are one flat colour,
(85,31,0) at alpha ~204 (never 255): a race frame around a solid cog with the resource cut in
as a solid glyph ringed by a transparent gap; race-neutral ones are the glyph alone, detail cut
as transparent lines. Codex draws each glyph as a black-on-white stencil (CA's generic glyphs as
the reference - painted art through edge detection gave speckle); the tool fills the CA frame's
cog and cuts the glyph in, colour and alpha read off that frame. `--check` holds size, colour
and top alpha to CA's (bicubic upscaling overshot the alpha to 208 until clamped).

**Per level, after CA's resource buildings** (`wh_main_dwf_resource_iron` 1-3, whose level rows
are cloned: 1000/2000/3000 gold, 2/3/4 turns, main settlement 1/2/3): the good 10/15/23 (CA's
20/30/45 halved - these trade at about double a common good's price), income 100/150/200
(`wh_main_effect_economy_gdp_mining`), and a lore bonus from `BONUS` - CA effects CA already puts
on buildings, at CA's scopes and values: recruit cost -20/-25/-30%, recruit rank +1/+2 from level
2, upkeep -3% at level 3, hero rank +1/+2. Damaged = half rounded away from zero, CA's rule
(`damaged()`), now on every row this pack writes.

| Good | Bonus |
|---|---|
| gromril | Ironbreakers and Hammerers |
| ithilmar | Swordmasters, Phoenix Guard, Dragon Princes (CA's High Elf iron bonus) |
| dragon bone | hero recruit rank, any owner |
| sea dragon hide | Black Ark Corsairs (CA's Dark Elf salt bonus) |
| black lotus | Dark Elves: Witch Elves (CA's medicine bonus); Skaven: Assassin rank |
| starwood | Glade Guard and Glade Riders |
| feathers | Bretonnia: Pegasus and Hippogryph Knights; Empire: Demigryphs |
| wyvern scales | Greenskins: Black Orcs and Big 'Uns; Ogres: hunters' beasts (Sabretusks, Stonehorns) |

On a building two races can build, a race's bonus is gated on the lore AND
`Region.Owner.CultureKey` (CA's `IsRegionNorsca` form), so neither sees the other's line.
`check_rare()` holds that, and that every race that can build one gets a bonus. Trap met: on a
one-race building the race gate IS the lore gate, and writing both emitted the same condition key
twice - the pack's duplicate-key refusal caught it; `check()` now does too.

**Buildable in any ordinary slot of those races, and makes nothing
outside the lore** (user ruling): there is no region lock without a startpos, so the production
row's context condition is the lock. `rare_cond()` derives it from the good's by-product
sources, adding what each pool implied (`Region.IsPort == true` for a port source - CA's own
`IsRegionPort` row - and `HasResource` for a mine source), so it cannot reach a region the lore
rule does not; `check_rare()` asserts that region by region, that every building row is gated,
and that rosters, building sets and icons exist. Rosters are every
`building_chain_availabilities` set of the culture outside the prologue, faction ones included
(Lokhir, Aislinn). The short description says where the building works.

## 13. IEE's own regions (2026-10-01)

The lore parity check covers IE and Realm of Chaos only, so IEE's 236 new regions (Ind, Nippon,
Khuresh, Khosun, the chaos wastes, and IEE's additions elsewhere) had never been measured.
`submod_signals()` now reads them from IEE's pack: areas, climate (`campaign_map_settlements`;
the 42 regions without one are sea and river), province, and a coast where a `cr_port_<tail>`
template exists. **Deposits and cultural origin live only in IEE's binary `startpos.esf`**, so
they read empty: mine-sourced and origin-gated goods are under-counted there, never over - those
need an in-game check. The normal run prints the reach per IEE area; `check_submod_reach()` fails
any good that covers every region of an IEE area of 10 or more (a rule with its terrain condition
missing), and the selftest proves it by dropping one.

It found one: Ind incense had no terrain condition and reached all 31 Ind regions, peaks and
jungle alike. Now Ind's desert, savannah and temperate regions only (9), as Araby's is
desert-only. What IEE's new areas get now:

| Area | Regions | Goods |
|---|---|---|
| Ind | 31 | tea 23, silk 16, salted fish 14, incense 9, pearls 8; and 7 Ind peaks IEE also tags Mountains of Mourn get salted meat, rhinox hides, wyvern scales |
| Khuresh | 42 | salted fish 22, black lotus 19 (jungle), pearls 16 |
| Nippon | 22 | tea 12, silk 8, porcelain 8, salted fish 6, pearls 1 |
| Khosun | 21 | the same 21 regions as northern Cathay: tea, jade, silk, porcelain |
| chaos wastes | 45 | nothing (chaotic) |

## 14. Two in-game findings (2026-10-01, IEE, Conclave turn 1, via the bridge)

**A chain is filed under ONE building set.** `CcoCampaignBuildingSlot.PossibleBuildingChainsList`
showed every race's rare building offered correctly (Karaz-a-Karak gromril, Altdorf/Couronne
feathers, Naggarond lotus and sea dragon hide, Lothern/Vaul's Anvil ithilmar) - except on the
Conclave's settlements, where none was, dragon bone included. `BuildingSetContext` on the shared
dragon bone chain answered `wh2_main_set_highelf_infrastructure`: of the 17 set rows it carried,
the game used one, so Dwarfs saw it filed under the High Elves, and Chaos Dwarf slots - whose
`PossibleBuildingSetList` holds only Chaos Dwarf sets - never offered it. Fixed as CA does it: one
chain per race (`rare_chains()`, `derpy_mr_bld_<good>_<race>` on a shared good), each in its own
race's set and rosters, which also retires the owner-culture gates of §12. `check_rare()` asserts
exactly one set per chain and one culture's rosters; the selftest adds a second set and a stolen
bonus. 27 chains. Zharr-Naggrund's tower slots take no ordinary-slot chain at all, ours or CA's.

**Dug, not smelted.** The user caught the Gold Sluice (`wh3_dlc23_chd_factory_refinery_2`) making
brass, brimstone and coal while the Mineshaft (`wh3_dlc23_chd_outpost_mine_2`) made nothing: the
refinery was in `KIND_CHAINS["industry"]` and coal's and brimstone's second sources were industry
sources, while no list held the Chaos Dwarf mines. Coal and brimstone now take a `dig` pool - the
Miners' Workshop (`factory_drills`) and the outpost Mineshaft; brass stays on the refinery,
assembly line and furnace. Dwarfs keep coal from their iron mines; their Trinket Maker no longer
makes it.

## 15. The building audit (2026-10-01)

`py tools/gen_resource_overhaul.py --audit` writes `Modding Files/reference/resource_overhaul_building_audit.md`:
every building that makes a good, by CA's in-game name per level, beside what it makes. Reading
it against the names found the pools were too coarse - `KIND_CHAINS` had held every "growth" and
"income" chain, so the Greenskin Idolz could grow grain, the Skaven Rubbish Pit make porcelain,
Kislev's Royal Barracks (Tzar Guard) breed warhorses. The pools are now chosen by building name
and description: `farm` (Fields, Windmill, Barley Field, Elf Homestead, Kislev Farmstead, Dark
Elf Manors), `hunt` (Skink Foraging Camp, Trapper's Den, Maw Pit), `teahouse` (Cathay Tea
Parlour), `inn` (Kislev Roadhouse, "sell nothing but kvas"), `craft` (weavers, Elf and Druchii
artisans, Cathay, Kislev and Skink markets), `forge` (CHD Furnace and Gunsmith, Dwarf Toolmaker),
`dig` (CHD Miners' Workshop and Mineshaft), `stables` (horse breeders incl. Kislev's Stud Farm),
`eyrie` (Bretonnia's Pegasus Aerie, Empire's Menagerie). Starwood moved to the Wood Elf
settlement (the forest gives it), Nuln's blackpowder to the city of Nuln.

Excluded by name: `NOT_A_HARBOUR` - the CHD river sluice and irrigation qanat, Nakai's port
temples; `NOT_A_MINE` - the `_military` smithies on an iron deposit (Arsenal, Black Orc Forge,
Master Swordsmith's Forge, Unholy Forge), to which CA itself gives none of the deposit's good.
Dropped altogether: Vampire Coast, Skaven, Warriors of Chaos, Greenskin, Ogre-income and Wood
Elf vineyard chains, the Cathay labour bureau, the Bretonnian cellar and the CHD gold refinery.
5,002 production rows.

## 16. Trading the goods on the Zharr Exchange (2026-10-01)

`derpy_zharr_exchange.pack` trades all 37 goods when Resource Overhaul is installed. The More
Resources packs are unchanged; the whole bridge lives in the Exchange (`docs/ZHARR_EXCHANGE.md`
§19, "Resource Overhaul' goods").

- **Detection, per good:** `common.get_localised_string("resources_onscreen_text_res_derpy_<good>")`
  is the good's name with this mod installed and `""` without it. Measured in game.
- **Supply:** the production rows are lore-gated per region, so no building-to-goods map can
  describe them. The Exchange reads one CCO expression per settlement instead:
  `BuildingSlotList.JoinString(BuildingContext.EffectList.Filter(EffectKey.StartsWith("derpy_effect_region_resource_")).JoinString(EffectKey + "=" + Value, ","), ",")`.
  `EffectList` holds only the rows whose condition holds, at their real value. Measured on IEE:
  Lothern's port reads pearls 6 and salted fish 6, Erengrad's reads amber 6 and salted fish 6,
  and all 749 regions take 0.064s.
- **Rename a good, its effect key or the `res_derpy_` prefix** and the Exchange stops seeing it.
  Regenerate `EX.MR` (`check_more_resources()` in `gen_zharr_exchange.py` fails until you do).

## 17. The AI builds the rare buildings, by script (2026-10-01)

The campaign AI scores a building only through `cai_construction_system_building_values`
(see the `wh3-ai-construction-needs-building-values-row` memory). A row there is one flat score
per chain. The rare buildings fit any ordinary slot and make nothing outside their lore regions,
so a score row would have the AI build them where they do nothing. The 27 chains therefore get
**no** score row, and `script/campaign/mod/derpy_more_resources_ai.lua` builds them for AI
factions instead.

- **Which regions.** The script carries a list, per rare good, of the regions where
  `rare_cond()` holds and a permitted slot template lets the chain in (`ai_regions()`): 172 as of
  2026-10-08 (55 Immortal Empires and Realm of Chaos, 26 IEE, 91 Old World).
  Some IEE deposits and races of origin can't be read offline. Those regions read as no, so any
  mistake leaves a building unbuilt rather than built where it does nothing.
- **When.** On `FactionTurnStart`, for AI factions only, each faction acts once every 5 turns
  (`AI_PACE`), staggered by a hash of its name. Each time it takes one action:
  1. it upgrades a rare building it owns, if the settlement tier allows the next level;
  2. otherwise, it builds level 1 in a lore region of its own with a free slot.
- **Price.** It pays CA's price per level (1,000, 2,000 and 3,000 gold, from the iron mine the
  levels are cloned from). It acts only while it holds twice the price (`AI_RESERVE`).
- **How it builds.** `cm:add_building_to_settlement` picks the slot itself. Upgrades use
  `cm:instantly_upgrade_building_in_region`. The script then looks for the building, and charges
  gold only if it is really there.
- **Checked by.** `check_ai()` and `tools/_resource_overhaul_ai_harness.lua`, which run the
  generated script under Lua 5.1. Mutation-tested against four faults: charging without
  verifying, ignoring the region list, skipping the tier check, and acting for a human.
- **Seen in game 2026-10-11 (36):** four computer factions built a rare building in one round.
  CA does use `cm:add_building_to_settlement` (corrected 2026-10-08:
  `wh3_tol_something_rotten_in_kislev.lua:637-641` adds secondary resource buildings with it, as
  this script does; also `wh3_tol_helpers.lua:33`, `wh3_dlc25_gelt_dilemmas.lua:98`).
  The script logs `derpy_mr_ai:` for every build, upgrade and failure, so the first AI turn in a
  campaign shows whether it works.

## 18. CA's four thin goods made common (2026-10-02)

CA placed Salt, Furs, Pottery and Wine on only 11-13 deposits each (section 2), against the
40-130 regions this mod's common goods reach. `CA_GOODS` in `gen_resource_overhaul.py` adds them
the same way as the mod's own goods: production rows on existing economy buildings, each gated by
a lore rule. The difference is that the rows carry **CA's own production effect**
(`wh_main_effect_region_resource_<good>_production`), so no resource, icon or loc is minted, and
the goods trade as CA's own.

| Good | Buildings | Lore rule | IE | RoC | Rows |
|---|---|---|---|---|---|
| Salt | every harbour (port pool) | temperate, savannah, desert or island coast | 69 | 9 | 111 |
| Furs | hunting lodges, farms, the Norscan hall | frozen climate; or mountains of Ogre origin | 96 | 51 | 43 |
| Pottery | craft buildings | Old World farmland, Araby or the Southern Realms, not frozen, chaotic or mountain | 94 | 45 | 26 |
| Wine | Bretonnian, Empire and High Elf farms only (`vineyard`) | temperate, savannah or island, in Bretonnia, the southern Empire, the Border Princes, Ulthuan, or Tilea and Estalia | 76 | 0 | 20 |

- **A level CA already makes the good on keeps CA's row.** Wood Elf Game Lodges
  (`wh_dlc05_wef_growth_1-3`) make Furs in vanilla. A second row on the same building and effect
  would replace CA's, so `produce()` skips it. `check()` fails on any row that lands on a key CA
  already uses, and dropping the skip makes it fail (tested by mutation).
- **The rules table is the spec, as for the mod's own goods.** `guess_region_commodities.CA_RULES`
  holds the four rules, and `check()` asserts that what ships reaches exactly those regions. The
  selftest loosens Salt and Wine and expects the check to fail.
- **Not on the map label.** CA's `resource_list` draws deposits only (section 10), and the label
  icons this mod adds are for its own 37 goods. A region making Salt from a harbour shows it in the
  building tooltip and the trade screen, not on the label.
- **The Exchange does not see these rows yet.** It reads Resource Overhaul' supply by the
  `derpy_effect_region_resource_` prefix, and CA's goods from its baked building map, so the extra
  Salt, Furs, Pottery and Wine do not move its prices.
- **Not checked in game.**

## 19. Settlement stores (2026-10-02)

Every settlement now keeps a store of each of the 54 goods (the mod's 37 plus CA's 17). The store
fills each turn with exactly what that settlement's buildings produce. Phase 1 has no UI: the
"Stores" panel is phase 2. Spec: `superpowers/specs/2026-10-02-resource-overhaul-stores-design.md`.
Plan: `superpowers/plans/2026-10-02-resource-overhaul-stores-phase1.md`.

**Built by `gen_resource_overhaul.py` (`_stores()`):**
- **54 REGION-scope pools**, `derpy_mr_store_<stem>`, cloned from CA's per-settlement
  `wh3_dlc27_sla_thralls_region`. Base space 200; under `wh_main_feature_all`.
- **Twin rows:** one per production row, on the same building level, with the same values and
  lore condition. Each carries `derpy_mr_store_<stem>_stocked` at `region_to_region_own`, bound with
  `base_amount` to a gain-only junction.
  - 5,024 twins of the mod's rows.
  - 820 twins of CA's rows, in their own table file (`..._derpy_more_resources_ca`), which the
    public repo refuses as a CA clone.
- **Space:** one `derpy_mr_store_capacity` effect bound with `maximum_mod` to all 54 pools. It sits
  on 630 main-settlement levels at +200 per settlement tier (ranked by level number, so a daemon
  chain's `_a` variant matches its twin and a level-0 `_ruins` entry gets none), stopping at +800, so space is 200 to 1,000. A
  damaged settlement keeps its space, so damage never destroys stock.

**Measured in game** (new IEE campaign, Conclave, turns 1 and 2, through the bridge):

| Question | Answer |
|---|---|
| Does a REGION pool fill from a building's twin row? | **Yes.** Falls of Doom made Coal 6 and Brimstone 6 and held 6/400 of each a turn later; Gash Kadrak 8 and 8 |
| Does `maximum_mod` raise a REGION pool's space? | **Yes.** 400 at level 2, 600 at Zharr-Naggrund |
| Does every owner have the stores? | **Yes.** The player and six AI factions (daemons, Nagash) |
| Does the CCO read list what fills each store? | **Yes**, with lore gates applied |
| What happens to stock on capture, raze or abandonment? | Capture keeps it; raze and abandon drop the pools (36) |
| Does a save from before the stores get them? | **Yes** (36): a Chaos Dwarf save from turn 2, pools at space 400 |

**A captured building keeps filling.** The Poxmakers of Nurgle filled Pearls and Salted Fish from
a harbour built by the previous owner. Production already behaves this way, and the stores follow
production.

**Raiding does nothing to the stores.** Nothing in phase 1 handles it. Raiding and sacking are
listed in the spec as ways stock is lost or taken, for the spending design.

## 20. The Stores panel (2026-10-02)

A read-only panel that shows the stores. It never shows a price; prices are the Exchange's job.
Plan: `superpowers/plans/2026-10-02-resource-overhaul-stores-phase2.md`.

**The opener.**
- **The button:** `derpy_mr_stores_button`, beside `resources_bar`. It follows the strip's end
  every 300 ms.
- **The hub:** when another Derpy mod is installed, the button joins the Derpy HUD hub as entry
  `mr`, order 4. The pack ships its own hub copy, `derpy_hub_mr.lua` (GUID prefixes DH07/DH08).

**The panel.**
- **Goods tab:** good | Held | Per turn | Space | Stored in.
  - Click a good to see the settlements that keep it: Held / Space, Per turn and a red **Full**.
- **Settlements tab:** settlement | Level | Space per good | Goods held | Fullest store.
  - Click a settlement to see its stores.
- **Lists are drawn whole:** every row is created once under `rows_holder`, which follows
  `list_box`.

**Where the numbers come from.**
- **Held and space:** the region's pooled resources, read with
  `region:pooled_resource_manager():resources()`.
- **Per turn:** the §19 CCO read of the settlement's `derpy_mr_store_*_stocked` effects.
- **Level:** `primary_slot():building():building_level()`.
- **When it updates:** on opening, and at `FactionTurnStart` for the local faction while the panel
  is open.

**Files.**
- `tools/gen_mr_ui.py` writes the five `ui/campaign ui/derpy_mr_stores_*.twui.xml` (GUID
  prefixes MR01-MR05), using its own emitter copy, `tools/gen_mr_emitter.py`.
- It also writes `script/campaign/mod/derpy_more_resources_stores.lua`: a generated layout and
  goods header in front of `Modding Files/source/resource_overhaul/stores_panel.lua`.
- **The gate is `py tools/gen_mr_ui.py --selftest`.** It checks the layout, GUIDs, art and
  sounds against CA's packs, and runs TWUI Studio's reader. It then runs
  `tools/_resource_overhaul_stores_harness.lua`, which drives the shipped script through a UI
  stub built from the generated XML.
- `gen_resource_overhaul.py --pack` refuses a stale file and runs that selftest before packing.

**How it differs from the spec.**
- **No backdrop picture.** CA's ui packs hold no storehouse or granary art, so the panel uses
  CA's panel frame.
- **File location:** the files are in `ui/campaign ui/`, not `ui/derpy_mr/`.
- **Good tooltip:** it shows the description only; "what makes it" is the drill-down.
- **Sort order:** settlements are listed by name.
- **Reopening** keeps the tab and drops the drill-down.
- **Level** is shown as `building_level()` returns it, which is right (measured below).

**In game** (IEE Conclave, turns 1-2, through the bridge and the author's play, 2026-10-02):
- **Button:** sits in the hub's column. **Speed:** the panel opens in 0.006 s.
- **Row clicks work:** `ComponentLClickUp` reaches `derpy_mr_row_<i>` through
  `list_clip > rows_holder`.
- **Level is right as returned:** Zharr-Naggrund 3 / 600, The Falls of Doom 2 / 400.
- **Capture:** a captured settlement keeps its stock. Eagle Eyries held the previous owner's
  Wyvern Scales (3/200) and keeps filling for the new owner. Raze and abandon drop the region's
  pools (measured 2026-10-11, section 36).
- **Two faults, both fixed:**
  - Tab and Back labels went blank on hover, because `SetStateText` writes the current state
    only. The label is now written to hover and standard.
  - The open tab had no selected look. It now wears CA's `button_square_large_text_selected`
    art on images 0 and 1, which the engine maps to the faction's theme skin.

## 21. Stores flows and history (2026-10-02)

This section covers phase 3. The spec is
`docs/superpowers/specs/2026-10-02-resource-overhaul-stores-flows-design.md`, and the plan is
`docs/superpowers/plans/2026-10-02-resource-overhaul-stores-phase3.md`.

**The script** is `script/campaign/mod/derpy_more_resources_flows.lua`. It is generated from
`Modding Files/source/resource_overhaul/flows.lua` behind a header that `tools/gen_mr_ui.py`
writes.

**The flows** (defaults; MCT sliders, frozen into the save at the first turn start):

| Flow | Event | Share | Lands in |
|---|---|---|---|
| Raid | `CharacterTurnStart`, army in `LAND_RAID`, on any other faction's land (no war needed, as with CA's raid gold) | 10% a turn | the raider's nearest settlement |
| Sack | `CharacterPerformsSettlementOccupationDecision`, `occupation_decision_sack` | 50% | the sacker's nearest settlement |
| Raze | the same event, `occupation_decision_raze_without_occupy` | 50% | the razer's nearest settlement |
| Trade | `FactionTurnStart`, each partner in `factions_trading_with()` | 5% a turn of the exporter's fullest store, per good the partner lacks | the partner's capital |

A share is `floor(held * pct / 100)`, but at least 1 when any is held. Floored alone, a store
under 10 never lost anything to a 10% raid: measured in game on 2026-10-02, when a raid on
6 wyvern scales took nothing. That raid was also on a faction the raider was not at war with,
which the first rule skipped while CA still paid gold. Both were changed the same day.
**Trade keeps the plain floor** (surplus only): with at-least-1 it shipped that raided scale
straight back out the same turn, since every partner's capital lacked it.

**Cases where nothing is taken:**
- the owner is a rebel, there is no owner, or the owner is the taker;
- an occupy or a loot-and-occupy (the stock already goes with the settlement);
- a trade partner with no settlements.

**Cases where stock is lost:**
- a taker with no settlements (a horde): the victim still loses the share;
- anything over the receiver's space.

**How a move is made:** two `cm:entity_add_pooled_resource_transaction` calls.
- The source gets `-n`. The receiver gets `min(n, free space)`.
- CA calls this in `wh3_campaign_grudges.lua` and `wh3_cp1_bhashiva.lua`, negative values
  included, but does not document it. `check_lua_api.py` therefore carries it in `CA_USED`.
- `entity_transfer_pooled_resource` is not used. Its behaviour at a full store was unmeasured,
  and the script now enforces the rule itself.

**Junctions:** each move books to `derpy_mr_store_<stem>_<raided|plundered|traded>`.
- Each is a junction on factor `derpy_mr_raided`, `derpy_mr_plundered` or `derpy_mr_traded`.
  That is 3 factors and 162 junctions.
- **They are two-way** (min -2147483647, max 2147483647). A junction's bounds decide which way
  stock may move: CA's `wh3_cp1_cth_relics_settlements_other` is loss-only and `_uncovered`
  gain-only. CA ships 456 two-way junctions.

**"Nearest"** is measured from the taking army's position, because the settlement may already
be null at a raze.

**Gated by the "Goods move between other factions" switch** (default on): when it is off, a
move runs only if a player's faction is on one side.

**Ledger and history:**
- Kept for human factions only.
- The ledger has six counters per good: `raided_in`, `raided_out`, `plundered_in`,
  `plundered_out`, `traded_in` and `traded_out`.
- At a human's turn start, the realm total per good goes into a 20-turn ring, and the ledger
  becomes last turn's, together with `made`.
- **Saving:**
  - It is saved as `derpy_mr_flows`, with whole numbers only, because of the decimal-comma
    locale trap.
  - The save and load callbacks go first in CA's lists.
  - Multiplayer ignores MCT and uses the defaults.

**The chart:**
- It appears on a good's drill-down. The list drops to 9 rows, and 20 bars (`derpy_mr_stores_bar`,
  GUID prefix MR06) stand on one baseline.
- A bar's tooltip reads "Turn N: X held".
- Under the bars is the line "Last turn: made +12, raided -30, traded in +5". Raids and plunder
  are netted; trade in and trade out are shown separately.
- With fewer than 2 turns recorded it reads "No history yet - check back next turn."

**Rulings pending the in-game check** (plan Task 1 moved to run with Task 7):
- `LACK_TEST = "capital"`: a partner lacks a good when its capital's store of it is empty.

**Measured in game, 2026-10-02 (IEE, Conclave, turns 3-4, script log and the bridge):**
- **A raid moves stock.** Eagle Eyries showed `derpy_mr_raided = -1` and Zharr-Naggrund
  `derpy_mr_raided = +1` on the pools' `factors()` the next turn, with `raided_in = 1` in the
  ledger. `factors()` lists only the current turn's transactions.
- **A raze reads nothing live.** "the stores of wh3_main_combi_region_venom_glade could not be
  read at the raze". The engine drops the pools before `CharacterPerformsSettlementOccupationDecision`.
  Fix: `F.on_battle` reads the contested settlement's stores on `CharacterCompletedBattle`
  (`pending_battle():contested_garrison():region()`), as CA's Bloodgrounds caches the settlement
  level on that event for the same decision. The raze then books only the receiver's side.
  An unopposed capture has no battle and still takes nothing.
- **`factions_trading_with()` returned a boolean** for some faction, once per round. Guarded.
- **No war test on raids**, and **a share is at least 1** for raids, sacks and razes (above).
  Trade keeps the plain floor.

**The Trade tab** (third tab, `derpy_mr_tab_trade`):
- Every good, most held first, with two switches per row (`derpy_mr_sw_export` /
  `derpy_mr_sw_import`, in the row file MR02): Exports stopped keeps the good home; Imports
  stopped means no partner sends it. Default everything allowed. Humans only.
- Saved in the faction's book as `stop[dir][stem] = true`.
- **A click never writes the model in multiplayer:** `F.send` sends
  `CampaignUI.TriggerCampaignScriptEvent(cqi, "dmr1|<dir>|<stem>")`, and the `UITrigger`
  listener toggles it on every machine. Singleplayer toggles directly.
- The switch's row is read off `UIComponent(UIComponent(context.component):Parent()):Id()`,
  CA's own idiom (`wh_campaign_setup.lua:2585`).

Goods you neither hold nor make sit below the rest, greyed with CA's `ui_font_inactive_grey`, with no Exports switch (nothing to send) and the Imports switch kept.

**Settlements tab icons:** up to `ICONS` (4) goods per settlement before its name, most made first, then most held; the name moves right by `ICON_PITCH` per extra icon.

**The raid plate:** a copy of CA's Labour raid plate (`CopyComponent`, measured: the text set on
the copy persists and CA's horizontal layout places it) beside the raid values above a raiding
army, `3d_ui_parent > label_<character cqi> > list_parent > stance_holder > icon_stance >
raid_holder`. Image 1 is the icon (image 0 the plate); the stores icon replaces it.
`F.raid_preview` gives the number from the same `F.raid_target` the raid uses, so the plate shows
what the raid then takes; it shows nothing before the rates are frozen, so a UI read never
freezes them on one machine. A 500 ms poll keeps it up; the tooltip lists up to ten goods.

**The capture panel** (Sack and Raze show the goods they take), read in game 2026-10-02:
- `settlement_captured > button_parent > <option id> > frame > icon_parent > [dy_income, ...]`.
  `settlement_captured:GetContextObjectId("CcoCampaignSettlement")` is the region key.
- **The option id is the `culture_settlement_occupation_options` row's `id`** (the option's
  `CcoCultureSettlementOccupationOptionRecord` Key, with the component's own name as its context
  id); `settlement_option` on that row says which decision it is. The option's label is
  translated text and the picture names lie (Norsca's `raze_serpent`, Vampire Coast's
  `sack_build_cove` are other decisions), so `gen_mr_ui.capture_kinds()` emits
  `DERPY_MR_CAPTURE_KIND` from CA's db.pack, and its check asserts the four ids read off the
  Chaos Dwarf panel.
- Occupy and Loot-and-Occupy show the whole store as kept (`F.capture_preview(..., "occupy")`, 100%; rebels' included, since the store stays with the settlement). Occupy-and-vassal, resettle and colonise show nothing.
- One value per good, each with the good's own icon, most first, up to `S.PLATES` (3); copies named `<prefix>1..3`, the tooltip lists every good. Same for the raid plate (icon in image 1).
- Tooltip lines are held to `S.TIP_CHARS` (44): CA's tooltip wraps at about 50 and split "Zharr-" from "Naggrund".
- A copy of `dy_income` (it keeps its `icon` child) holds the number; text, tooltip and icon
  persist. CA's row is full, so it wraps to a second line and the row moves up 13px.
- The number is `F.capture_preview`, the same `F.preview` / `F.share` the move uses, and nothing
  for rebels or your own settlement, as `F.on_occupation` skips them. Polled with the raid plates.
- The battle's reading was confirmed live: `F.at_battle` held Eagle Eyries' 6 wyvern scales on
  the open capture panel.

**The gate** is `py tools/gen_mr_ui.py --selftest`. It runs both harnesses
(`_resource_overhaul_stores_harness.lua` and `_resource_overhaul_flows_harness.lua`).

**The panel redesign (2026-10-02, approved off a mockup).**
- A rule under the title separates it from the tabs; everything below moved down 4px.
- Each view has its own columns, `DERPY_MR_STORES_L.VIEWS[S.view_key()]` as (x, w, align):
  words left, numbers right, ticks centred. `SetTextHAlign` aligns the headers and cells at
  runtime, and each cell is resized to its view's column. Both drill-downs share "focus".
- Column lines sit in the middle of each gap (`S.line_x`).
- Trade switches are CA's checkboxes (`S.CHECK`): ticked means allowed, empty means stopped. The
  word is in the tooltip only.
- Greyed goods sit under a "Goods you do not have (N)" section row. Their icons and checkboxes
  draw at opacity 115.
- Every other row is banded.
- Headers renamed "Space each" and "Goods". The engine shrank "Space per good" in 100px; the
  harness now checks every view's headers at `HEAD_CHAR_W` = 8.

**Wording and trade shortcuts (2026-10-02).**
- Player text says "resource", never "good": the panel, the MCT, the building tooltips and the
  store-space effect. The first tab is "Resources". Code names keep `goods`.
- Four buttons under the Trade list: Allow/Stop all exports/imports. Each sends
  `F.ALL_STOP` / `F.ALL_ALLOW` in place of a resource key, through the same `F.send` and
  UITrigger as one checkbox. `F.apply` sets every resource that way; it never toggles.
- Clicking the "Resources you do not have" row folds them away (`S.folded`). The fold lasts
  while the campaign runs and is not saved.

**In game, still to see:** the raid plate's per-good icons; the redesigned panel (checkbox
art, header alignment, bands).

## 22. Using the stores: upkeep and holding bonuses (phase 4, 2026-10-02)

Built, deployed to `data/`, seen in game 2026-10-11 (36). Spec: `superpowers/specs/2026-10-02-resource-overhaul-stores-spending-design.md` §2.
Plan, with what was measured offline and the rulings: `superpowers/plans/2026-10-02-resource-overhaul-phase4-upkeep.md`.

- **Eating:** at each owner's turn start, `F.upkeep` (in `flows.lua`) runs over every settlement. Each eats
  `2 x level` provisions with `F.draw`, the drawing rule: the fullest store first, ties by key.
  The amount is booked to the new `derpy_mr_eaten` factor and shown as "eaten" in the panel's
  last-turn line.
- **Bundles:** applied for 2 turns and renewed each turn; removed the turn their condition fails.
  - **Well fed** (growth +10): five turns' need is still held after eating.
  - **Garrison stocked** (garrison melee attack and defence +4): war materials fill a quarter of
    one store.
  - **Comforts** (public order +3): luxuries fill a quarter of one store.
- **Effects:** all CA's own, at the scopes CA's region bundles use. Sayl's region bundle is the
  donor for the garrison scope.
- **Who is skipped:**
  - Subcultures with no stores to use, `DERPY_MR_FLOWS_NO_STORES`. These are the same tokens as
    `EXCLUDE`, and `check_uses()` asserts that they match.
  - Other factions, when "Other factions use their stores" is off.
  - Everyone, when the new MCT switch "Settlements use their stores" is off.
- **Uses:** the five-use table is `gen_mr_ui.USES`, carried on `DERPY_MR_FLOWS_GOODS` as `use`.
- **Panel:** the Settlements tab's third column is now **Using**. It shows the bundles' icons,
  and the row's tooltip names them.
- **Measure in game:**
  - that the bundles show on the settlement;
  - that growth is counted with Well fed on;
  - the pass's cost over a round (booked to `F.cost.turn`).

## 23. The Stores panel's actions (phase 7, 2026-10-02)

Built, deployed to `data/`, seen in game 2026-10-11 (36). Spec §5. Plan, with the offline
measurements and the rulings: `superpowers/plans/2026-10-02-resource-overhaul-phase7-actions.md`.
Built ahead of phase 5, at the user's choice, because phase 5's open questions need the game.

- **Send here** (on each row of a settlement's drill-down):
  - The fullest **other** store sends the most whose arrival still fits; ties go to the lower
    region key.
  - 10% is lost on the way, rounded up. Nothing is sent when nothing would arrive.
  - A greyed row says why ("full", "no other settlement can send").
- **Orders** (on the Resources tab's bottom line). Each costs 200 of one use, drawn from the
  fullest stores realm-wide, lasts 5 turns, and has a 10-turn wait kept in the faction's book
  (the save):
  - **Festival**: luxuries; public order +4 in every province.
  - **Muster**: war materials; recruit rank +1 for every unit.
  - **Great Works**: building materials; construction cost -20%.
- **Sell surplus** (on a resource's drill-down):
  - Sells what the realm holds above half its space for that resource, fullest store first.
  - Price: `EX.sell_price(res)` when the Zharr Exchange is loaded and answers above 0, otherwise
    1-5 gold a unit by use.
  - The Exchange's price is per unit, about 51 for Marble, so selling with the Exchange loaded
    pays roughly 10-50 times the fixed rates.
- **One door:** every action, and every trade switch, goes through `F.request`.
  - In singleplayer it calls `F.dispatch` directly.
  - In multiplayer it sends `dmr1|<action>|<args>` through the UITrigger. `F.parse` refuses
    another mod's id and any part that is not a key; `F.dispatch` refuses a wrong part count, a
    computer faction, and actions with the MCT switch "Stores panel actions" off.
- **Booking:** three new two-way factors, `derpy_mr_moved`, `derpy_mr_spent` and `derpy_mr_sold`.
  The last-turn line shows "moved" (net, which is the loss), "spent" and "sold".
- **Greyed buttons** use `S.set_off`, which is `SetDisabled` plus the greyscale shader (the
  Exchange's `EX.set_off`). The tooltip still says why.
- **Measure in game:**
  - the three faction bundles' effects;
  - `treasury_mod` from a panel click;
  - that the shader greys these text buttons.

**Resource Vault (2026-10-02, author's screenshot).** The panel is titled "Resource Vault" (title, hub label, opener tooltip, MCT switch). The bottom-line buttons are 200x30 across the full width: CA's `button_square_large_text_*` art draws only x 27-312, y 6-42 of 339x51, so a 140px button showed a 117px face and "Allow all exports" overran it. `gen_mr_ui.check_button_faces()` now sizes every text button against that face. The hints moved to the right end of the sub-title's line.

**Measured live 2026-10-02 (Conclave, turn 4, bridge).** Store trade runs. This turn the Conclave sent 5 Brimstone and 5 Coal, 1 of each to five partners' capitals, out of Gash Kadrak's store. CA's Trade Forecast is a separate gold layer that never consumes stock. Small stores send nothing: 5% floored needs a store of 20 for 1 unit, and a partner counts as lacking only while its capital holds 0. **Bug found and fixed:** a save whose rates were frozen before a switch existed had `upkeep=nil, actions=nil`, so phases 4 and 7 never ran in it. `F.rates()` now gives a missing key its value and freezes it.

## 24. Caravans for province shipments: the test (2026-10-03)

**The question.** Phase 5's per-province switches pay from the province capital's store, so
goods have to travel from the minor settlements to the capital. The author asked whether that
travel can use real caravans, the Chaos Dwarf convoy kind: on the map, moving, interceptable.
Tested live through the bridge on IEE (Conclave, turn 2), with the throwaway pack
`derpy_caravan_test.pack` (`tools/build_caravan_test.py`, `Modding Files/source/caravan_test/`).

**CA's caravans: the DB side is open, the script side is not.**

| Question | Answer |
|---|---|
| What defines a road? | Four tables, all DB: `campaign_map_route_nodes` (key, x, y), `campaign_map_route_segments` (from, to, network, a `region_groups` key for the regions crossed), `campaign_map_route_networks` (key, campaign), `campaign_caravan_networks` (campaign group, caravan master subtype, network, default contract, factor). No map file. |
| Who gets a network? | A campaign group (`campaign_group_member_criteria_*`). A faction has ONE network: the group with the higher `priority` wins. CA's Bhashiva and OvN's Marienburg (`!scm_marienburg.pack`, priority 5, also Karl Franz and four other Empire factions at 0) both use this. |
| Which campaign? | Networks are tied to a campaign key. IEE is `cr_combi_expanded`, with its own `convoy_road_combi_expanded` and `ivory_road_combi_expanded`. The test roads were declared for `wh3_main_combi`, so neither appeared in IEE. |
| Node positions | The settlement's logical position, about 2 off: Zharr-Naggrund's node 943,630, settlement 943,628. |
| Upkeep and caps | None. A script-recruited caravan is force type `CONVOY`, 1 unit, upkeep 0; faction upkeep unchanged (2,384). |
| Recruit by script | Works: `cm:recruit_caravan(faction, item)` charged the item's 750 and left the caravan idle. |
| Send by script | **Impossible.** `set_caravan_path`, `set_caravan_auto_path` and `clear_caravan_path` are in CA's docs and absent in game, on `cm` and on `cm.game_interface`. `can_start_caravan` was false for every cargo, contract and destination, and `cm:start_caravan` returned null. |
| How the convoy panel sends one | UI context commands: `CcoCampaignCaravan.SetStartingNode` / `SetAutoPathTowardsNode(node, contract)`, then `CcoCampaignFactionCaravans.StartCaravan(caravan, contract, cargo)`. Local player only, and parameterised, the class that has hard-crashed the game from script. Not tried. |
| Limits | The Conclave had 1 caravan and 1 start node (Zharr-Naggrund). The limit is bonus value `maximum_caravans_mod`, granted by `wh3_dlc23_effect_technology_chd_convoy_mod_active_convoys` at `faction_to_faction_own_unseen`. A caravan returns to its start after arriving. |

**Ruling: CA's caravans cannot carry the shipments.** A script cannot route one, so neither
"supply the capital" orders nor AI shipments are possible; AI caravans go where CA's AI sends
them. A player-only version would need the crash-class UI calls, a caravan panel per race
(only the Chaos Dwarfs and Cathay have one) and a fight with OvN over Empire factions.

**What works instead: a scripted shipment drawn and triggered on the map.**
- **Interception: measured.** `cm:add_interactable_campaign_marker(id, info_key, x, y, 2)` at
  logical 939,664 (between Zharr-Naggrund and Sabre Mountain) drew CA's red marker with its
  tooltip ("Chaos Dwarf Patrol", the borrowed `wh3_dlc25_malakai_adventures_battle_chaos_dwarfs`
  info). Ghorth walking onto it fired `AreaEntered`, area key `derpy_ct_marker_1`, with the
  character's faction, subtype, cqi and position. It fires for the owner's own army too, so the
  listener has to check war.
- **Look: measured 2026-10-11.** `cm:add_scripted_composite_scene_to_logical_position` with CA's
  `cth_caravan` (Cathay's wagon circle, the only caravan scene in `campaign_composite_scenes`)
  draws: wagons, barrels and torches about a small settlement's footprint, and the engine keeps it
  in the save (seen after a reload). A marker's own `marker_type` is a `prefabs/campaign/<type>.bmd`
  name (35 of 52 CA types match one); `cth_caravan_circle` as a marker draws nothing but still
  fires `AreaEntered`, so the scene is what the player sees.
- **Not measured:** whether `AreaEntered` fires for AI characters. The design does not depend
  on it: AI interception is a proximity rule at turn start (an enemy army within a few hexes of
  a shipment), and a friendly army next to it escorts it.

**The shape this points to** (not yet designed or approved): each shipment is a save entry
(goods, destination, arrival turn); each turn it moves one leg along settlement-to-settlement
waypoints through adjacent regions, its marker and scene removed and re-added there; a player
army entering an enemy shipment's marker takes part of its cargo; a cap on shipments per faction
keeps the map readable. A real battle on interception, CA's caravan way (spawn a force,
`force_attack_of_opportunity`), is possible later and not part of it.

**Clean-up:** the test pack was deleted from `data/` and `Modpacks/` on 2026-10-03. Its builder
(`tools/build_caravan_test.py`) and probe (`Modding Files/source/caravan_test/`) stay as the record
and can rebuild it. The test campaign holds one idle Conclave convoy recruited by script.

## 25. Store events (phase 6, part 1, 2026-10-03)

Built, deployed to `data/`, seen in game 2026-10-11 except Siege Stores (36). Spec §4 (spending
design). The capture option ("Occupy and restore") is part 2, built as a dilemma in section 27.

| Event | Offered when | Spend | Reward |
|---|---|---|---|
| Feast | a settlement holds 100 provisions | 100 provisions there | `derpy_mr_event_feast`, public order +5 and growth +20 in its province, 5 turns |
| Siege Stores | a settlement **under siege** holds 60 provisions | 60 provisions there | `derpy_mr_event_siege`, `..._siege_defend_attrition` -100 at `region_to_force_own`, 2 turns |
| Tribute | the realm holds 50 luxuries and a neighbour is not at war with you | 50 luxuries, fullest stores first | `cm:apply_dilemma_diplomatic_bonus(you, them, 3)` |
| Arsenal | the realm holds 50 war materials and you have an army | 50 war materials | `cm:add_experience_to_units_commanded_by_character`, +1 rank, the largest army |

- **Dilemmas are DB rows**, `derpy_mr_dil_<event>`: FIRST spends and rewards, SECOND ("Keep the
  stores") does nothing. No payload rows: a payload cannot charge a REGION pool, so the flows
  script spends in `DilemmaChoiceMadeEvent`. A DB dilemma, triggered with
  `cm:trigger_dilemma_with_targets` - **not** a script-built one, whose choice listener crashes the
  game (memory). The text names its target with CA's tokens: `RegionTargetName`,
  `FirstTargetFactionNameWithIcon`, `CharacterTargetName`; `check_dilemmas()` holds each text to
  the target the script hands it.
- **Which one:** a siege first; otherwise the qualifying event offered longest ago, ties in the
  order feast, arsenal, tribute. The neighbour is the first by key, the army the largest that is
  not a garrison or a convoy - both so every machine picks the same.
- **Spacing:** one event per faction every 10 turns, counted from the offer (a decline starts it
  too). Kept in the save as `F.state.events`; the unanswered offer as `F.state.pending`.
- **Short at the answer** (the stores emptied between the offer and the click): nothing is taken
  and nothing given.
- **Computer-run factions:** no dilemma; the same deal on a 20-in-100 roll, under the "Other
  factions use their stores" switch. A failed roll starts no gap.
- **MCT:** a fourth switch, "Store events", in Using stores. Frozen like the rest.
- **Checked by** the flows harness's phase 6 section and `check_dilemmas()` (four planted faults,
  all caught). 14 mutants of the script, all caught: siege priority, the gap, decline paying, a
  failed roll starting the gap, the AI switch, both short-store guards, a garrison or convoy
  counted as an army, a neighbour at war, the bonus reversed, the switch, the pending offer not
  cleared, another dilemma's answer.
- **Seen in game 2026-10-11 (36):** each dilemma's picture and text, its target named once the
  `GEN_TARGET_MODEL` row was added; the diplomatic bonus, +5 a call on the human's side.
  **Still to see:** the siege bundle stopping siege attrition.

**Seen in game 2026-10-08 (Arsenal, a Dwarf game):** nothing under either button, and the text read
"'s army". The list under a button is drawn from payload rows only, and these dilemmas had none.
Each choice now carries `TEXT_DISPLAY` rows (`LOOKUP[<component>]`; display only, the script still
pays): the cost (`negative`, the use's icon from `gen_mr_ui.USE_ICON`) and the reward (`positive`, the
bundle's icon, or `icon` on the event) under the accept button, read off the accept line, and
"Nothing is spent" under "Keep the stores". `check_dilemmas()` holds every choice to a line, every
state to CA's four, every icon to CA's packs, and ids unique and clear of CA's; three planted faults
caught. **The blank name:** `CharacterTargetName` drew empty with the character AND the force handed
to `trigger_dilemma_with_targets`. Cause found 2026-10-11 (section 36): no `GEN_TARGET_MODEL` option row.
The Arsenal no longer uses the token: "Your largest army", which is the army the script picks.
Deployed to `data/` in `10c0547c` (with section 28).

**Part 2, the capture option, needs measuring first.** CA's Dechala row
(`culture_settlement_occupation_options`, id 1218317010) charges through
`captured_region_resource_transaction = wh3_dlc27_resource_cost_sla_thralls_occupation`, a
`resource_costs` row whose junction amount is **+1000** on `wh3_dlc27_sla_thralls_region_occupation`.
Unknown until measured: whether that column adds or takes, whether an option the captured store
cannot pay is greyed, what `required_resources` gates, and which `group` value scopes a row to a
culture. One row per building good per culture makes it ~150 rows of a 30-column table, so it is
not built blind.

## 26. Province supplies and shipments (phase 5, 2026-10-03)

Built, deployed to `data/`, seen in game 2026-10-11 (36). Spec §3 (spending design, the redesign
approved 2026-10-03); plan `superpowers/plans/2026-10-03-resource-overhaul-phase5-supplies.md`.
Replaces the per-build version of phase 5, which was never built.

**Switches.** Three per province, on a province capital's drill-down (Settlements tab, open the
capital), with "Supply the capital" as the fourth button. Lit when on.

| Switch | Paid from the capital each turn | Bundle on every settlement held in the province |
|---|---|---|
| Materials on hand | 2 building materials per settlement held there | `derpy_mr_supply_materials`: `wh_main_effect_building_construction_cost_mod` -25, `region_to_region_own` |
| Stable stocked | 2 mounts per settlement | `derpy_mr_supply_stable`: `..._recruitment_cost_cavalry` and `wh2_main_effect_lzd_monster_recruitment_cost_down` (unit set `monsters`) -15, `region_to_force_own` |
| Arms stocked | 2 war materials per settlement | `derpy_mr_supply_arms`: `..._recruitment_cost_infantry` and `..._artillery` -15, `region_to_force_own` |

- **Short:** the capital pays nothing, the switch turns itself off and the bundles go at once;
  the button's tooltip says on which turn. A capital the faction no longer holds pays nothing
  and its province loses the bundles.
- **Fixed discounts:** a DB effect value cannot follow an MCT setting, so the spec's "MCT 0-50"
  for construction was dropped.

**Shipments.** Send here is now a shipment, and so is everything Supply the capital sends.
- Taken from the sender at once, a tenth lost (as before), the rest arrives at the owner's
  second turn start after. Send here counts what is already on the road to a store against its
  free space.
- **On the map:** `cm:add_interactable_campaign_marker(id, "derpy_mr_shipment", x, y, 2, "", "")`,
  our row over CA's `cth_caravan_circle` prefab (draws nothing), named "Shipment", and CA's
  `cth_caravan` composite scene on the same spot facing the destination settlement, not one-shot so
  it can be removed (`F.mark` / `F.unmark`). **Until 2026-10-11 the marker used `food_merchant`, which
  draws Grom's troll** (reported from the game); `check_shipments` now holds the prefab to CA's
  `data.pack` and the scene key to `campaign_composite_scenes`. Seen in game: the scene moves on the
  leg change and goes on arrival and on a seizure; a shipment from an older save has no scene until
  its next leg. On leg 2 beside Altdorf the spot sits at the town's foot, half hidden by it. First turn beside the
  sender, second beside the destination, at the spot
  `cm:find_valid_spawn_location_for_character_from_settlement(faction, region, false, true, 3)`
  returns (CA's marker manager places its markers this way); the settlement's own position on
  -1. The engine keeps markers in the save: CA never re-adds one after a load.
- **Seized:** an army (not a garrison, not a hero alone) of a faction at war with the owner,
  walking in (`AreaEntered`) or standing within 3 of it at the owner's turn start. The cargo goes
  to the captor's settlement nearest it, booked as raided, as far as it has room; a captor with
  none destroys it.
- **Arrival at a lost destination:** the owner's settlement nearest it; none, and it is lost.
- **How many:** "Shipments on the road" in MCT, 1-10, default 3; a computer-run faction 1. The
  Resources tab's hint counts them; Send here's tooltip lists what is coming to that store.
- A dead faction's shipments and markers are cleared at a player's turn start.

**Supply the capital** (off by default per province): when the capital holds under 5 turns of a
switched-on supply's cost, the province's other settlements send one shipment of that use's
fullest good, enough for 10 turns; never while one is already on the road for that use.

**Computer-run factions** (under "Other factions use their stores"): a supply goes on when its
capital holds 10 turns of it, Supply the capital always runs, at most 1 shipment on the road.
Their shipments are on the map too.

**MCT:** "Province supplies" switch (Using stores), "Shipments on the road" slider (Stores).

**Checked by** the flows harness's phase 5 section and the stores harness's shipment and supply
block. 40 mutants of the two scripts, all caught. Three of the first run survived because their
tests could not fail (the capital always held less than the sender; the capital could pay with
or without the arrival; a "second settlement" that the harness faction did not have). The tests
were fixed and a redundant busy check in `F.send_here` was deleted. A fresh review then found:
a faction with no stores to use (daemons, the undead, Beastmen) was offered switches that never
paid (now `F.supply_state` refuses it); Send here said "no other settlement can send" when
shipments on the road already filled the store (now it says so); and two tests that could not
fail (a horde's seizure, a computer-run faction's click). All four fixed test-first.

**Seen in game 2026-10-11 (36):** the Food Merchant marker drew Grom's troll, so the cart is now
CA's `cth_caravan` wagon scene (section 24); a shipment on the road, its Spending tab row and its
ten escort cards; `AreaEntered` for a player army. **Still to see:**
- whether `AreaEntered` fires for an AI army (the turn-start rule covers it if not);
- each bundle's discount in the build and recruit costs, in particular `region_to_force_own` on a
  recruit cost (CA's own building uses `building_to_forces_own_regionwide`);
- the four toggles' lit art and their tooltips.

### 26b. The Spending tab (2026-10-03, asked for after phase 5)

The author expected spending in its own place, not spread over the Resource Vault. It is now a
fourth tab, **Spending**, and what it holds was **moved, not copied**:
- **Province capitals:** one row per capital the player holds (`F.capitals`), sorted by name,
  with four checkboxes: Materials, Stables, Arms, Supply capital. The capital drill-down's
  bottom-line buttons are gone.
- **On the road (n of most):** a section row, then one row per shipment of the local faction
  (good and amount, from, to, arrival turn) with a **Show** button. It closes the panel and flies
  the camera to the cart: `cm:log_to_dis`, then `cm:scroll_camera_from_current(false, 1, {x, y,
  d, 0, h})` keeping the camera's distance and height, which is CA's recipe in
  `wh3_dlc29_middenland_narrative.lua` and `wh_dlc08_monster_hunt.lua`. The Resources tab's
  shipment hint is gone.
- **Orders:** Festival, Muster, Great Works on its bottom line, moved off the Resources tab.
- Send here stays on a settlement's resource rows, and Sell on a resource's drill-down.

Checked by the stores harness's Spending block; 47 mutants of the two scripts, all caught.
**Asked for, not built yet: a drawn map tab** with a picture of the campaign map and a dot per
convoy. It needs a map image and a calibrated logical-to-pixel fit per campaign (Immortal
Empires, IEE, Realm of Chaos), so it waits until the camera jump is seen in game.

## 27. The Map tab and Restore on capture (2026-10-03)

Both built and deployed to `data/`; the Map tab seen in game 2026-10-03 (27b, 27c), Restore on
2026-10-11 (36). With these, every part of the spending
spec is built.

**The Map tab** (the fifth tab; the tabs are now 120 wide to fit before Back):
- Your settlements as tinted squares, sorted by name; a province capital's larger and named.
  Every convoy of yours is CA's `ui/campaign ui/effect_bundles/convoy_icon.png` at its current
  spot, on six dots from the settlement it left to the one it is going to.
- **No picture of the map.** It is framed on what it draws: one scale for both axes, so nothing
  is stretched, with a 40-unit minimum span so one settlement is not blown up. So it fits
  Immortal Empires, IEE, Realm of Chaos and any map mod with no calibration. **North up:**
  logical y grows northward (Kislev 789, Middenheim 720, Karak Eight Peaks 359 in CA's own
  scripts), so the screen y is flipped.
- A click on a convoy or a settlement flies the camera there (`S.look_at`, the Spending tab's
  Show) and closes the panel.
- Components: four new `.twui.xml` files (`derpy_mr_stores_mapdot` / `_mapcart` / `_mappath` /
  `_maplabel`, GUID prefixes MR07-MR10), pooled in the panel and made the first time they are
  needed; the ones past what is shown go hidden.

**Restore on capture** (the spec's "Occupy and restore", phase 6 part 2), **built as a dilemma,
not an occupation option.** Measured offline first:
- CA's cost sign is negative (the Tower seat's -300, the Hell-Forge's prices), so Dechala's
  +1000 in `captured_region_resource_transaction` ADDS thralls to the captured region, and
  `captured_region_resource_building_level_multiplier` = 1.0 scales it by level.
- An option row joins a culture through its `group`, a campaign group whose member carries a
  `campaign_group_member_criteria_subcultures` row (`wh3_dlc23_chd_chaos_occupation_decision_occupy`
  for the Chaos Dwarfs; 31 occupy groups in all). `required_resources` names a `resource_costs`
  key and CA's rows name the same key as `resource_transaction`.
- `CharacterPerformsSettlementOccupationDecision`'s `context:occupation_decision()` gives the
  picked option's id.
- **Why a dilemma:** whether `required_resources` reads the captured REGION's pool or the
  faction's is still unmeasured, and one row per building good would mean five buttons on every
  capture screen of 31 cultures. The dilemma reuses phase 6's machinery and is offered only when
  the store can pay.

What it does: occupying (`occupation_decision_occupy`) a settlement whose store holds 100
building materials offers **Restore** (`derpy_mr_dil_restore`, CA's `civilisation_up` picture).
Accepting spends the 100 from that store, fullest first, repairs every building there
(`cm:region_slot_instantly_repair_building` on each slot with a building) and gives
`derpy_mr_event_restore`, public order +5 for 5 turns. It keeps no gap and is not in the
turn-start order. Computer-run factions take it on the events' 20% roll. It is under the
"Store events" switch.

**Pending offers are now one per faction and per event,** so a Restore offered on capture does
not wipe a Feast still waiting for its answer. A save from before kept one per faction as
`{key = ...}`; that shape is still read.

**Checked by** the stores harness's Map block, the flows harness's Restore section, and 64 + 12
mutants, all caught. Three of the phase 6 mutants had gone stale, because the guards they aimed
at now appear in the new code too; they were narrowed to their own lines.

**Seen in game:**
- the Map tab: 27b and 27c; on 2026-10-11 it drew 2 dots, 1 cart and a 6-point road;
- Restore (36): offered on capture, 100 marble spent and the public order bundle on. The
  buildings were undamaged, so the repair itself is still unseen.

### 27b. Seen in game: the tabs in the corner, and CA's map under the Map tab (2026-10-03)

**What the first in-game look showed:** the Spending and Map tab buttons were drawn in the panel's
top-left corner, over the title. `S.layout` named the first three tabs by hand and never placed
the two new ones, and the engine ignores a runtime component's XML offsets. Every layout check had
passed, because each one checked the box gen_mr_ui.py hands out and not where the Lua put the
component. Nobody had looked at a picture.

**Fixed, and now checked:**
- **Tabs:** `S.layout` places every tab from `S.TAB`.
- **The harness** asserts each tab's position on the panel. On every tab it also asserts that every
  visible component directly under the panel was moved there by the script.
- **`tools/preview_resource_vault.py`** draws every tab to `.skilltree_cache/ui_preview/mr_<view>.png`
  from the shipped Lua. With `MR_DUMP` set, the harness writes each visible component's position,
  size, text, alignment and runtime image. The preview rasterises CA's art over that, clipping
  wherever a box has `clipchildren`. A preview drawn from the generator's coordinates alone would
  have drawn the tabs correctly and missed the bug.

**What the pictures showed next:**
- **Shipment rows read as supply values.** They sat under the supply headers, so "Bravo" read as a
  Materials value. The "On the road" row now carries its own headings (From / To / Arrives). With
  no province capitals listed, the supply headers go blank.
- **The map was too bare** (asked 2026-10-03: "can you not use the CA map graphic?").

**CA's map under the Map tab.**
- **The picture:** `campaign_maps/<map>/<name>_minimap.png`, CA's parchment map, is drawn under the
  dots.
- **Measured offline** by plotting settlement positions from CA's scripts:
  - It is **one pixel per logical unit, y counted up from the bottom**, on all three maps.
  - On vanilla Immortal Empires it is `wh3_main_combi_map_7` (1440x1120); on Realm of Chaos,
    `wh3_main_chaos_map_4` (1108x834). These folders are `campaigns_tables.map_name`.
  - On IEE it is `cr_combi_expanded_map_1` (1600x1120, from IEE's own pack). IEE keeps vanilla's
    coordinates and only adds land to the east.
  - CA's own `load_save_game.twui.xml` uses such a path as a twui imagepath.
- **Choosing the picture:** `cm:model():campaign_name_key()`, the campaigns table key, which CA's
  scripts compare. Any other map gets the plain black map, as before.
- **Placement:**
  - The picture sits in a `clipchildren` box the size of the map (`derpy_mr_stores_mapart`, MR11).
    It is scaled and moved so that logical (x, y) lands exactly under its dot.
  - It never zooms closer than 2 pixels per unit (`MAP_ART_ZOOM`); past that it is a blur.
  - The view is kept on the picture, so there is no blank past its edge.
  - The picture is dimmed to `#8C8C8C` so the panel's beige names read on it.
- **Made with the panel:** the box is created when the panel is built, before any dot. The engine
  draws in creation order, so CA's map is always beneath the dots.
- **Labels and colours:**
  - Every settlement is now named, province capitals first. A name that would overlap one already
    placed is left off; the dot and its tooltip stay. A name that would run past the right edge
    goes on its dot's left.
  - Dots and road are red ink (`#E0553C`), which reads on parchment and on black.
- **Checked by** the harness's map block, which covers:
  - all three pictures and their paths;
  - every dot on its pixel, with one scale;
  - the box cut to the map, the picture filling it, drawn beneath, and gone on an unknown map;
  - the zoom limit and the south-edge clamp;
  - every name placed, collisions dropped, the right-edge flip.
- **Mutation:** 13 mutants, all caught from a green baseline. Writing them found `MAP_ART_SPAN`
  could never take effect under the zoom limit, so it was deleted.

**To see in game:**
- that `SetImagePath` on a runtime component takes a `campaign_maps/...` path;
- the parchment's brightness under the names;
- the dots on the right places on your own campaign.

### 27c. Seen in game again: placement, drag, CA's markers, the pay icons (2026-10-03)

**Reported:** the map does not move when grabbed; the dots should be settlement icons; the
settlements sit in the wrong places; and the Spending tab does not show what resource each supply
uses.

**The placement, measured in the live campaign.** Measured through the wh3 bridge in the user's IEE
game: `campaign_name_key()` is `cr_combi_expanded`.
- **27b's frame was wrong vertically.** CA's minimap is drawn in **display** space, and display =
  logical x (0.668, 0.772) there. So "one pixel per logical unit" holds across and is about 13% short
  north to south, which put Zharr-Naggrund visibly south of the river it sits on.
- **Why it slipped through:** the offline check plotted script coordinates whose own noise (about
  20 units) hid the error.
- **A false lead:** sampling CA's HUD radar against the camera was also about 22px off, because the
  radar does not centre on the camera target.
- **The exact answer is the engine's own:**
  - `common.get_context_value("CampaignRadarPosition(ToVector(dx, 0, dy, 0)).x")` (and `.y`) gives
    a display point's 0-1 place on the picture. A CCO world position is (display x, height,
    display y).
  - It agreed with `CcoCampaignSettlement:Position` to 1e-6.
  - It is the function CA's own map panels place icons with (`ContextRadarIcon`).
  - `S.map_frame` reads it at the world's westmost, eastmost, southmost and northmost settlements,
    once a session, and the frame is linear.
- **Every map is covered with no measured constants.** That includes Realm of Chaos and map mods
  with a known picture. If the engine does not answer, the plain map is drawn.
- **The plain map works in display units too**, so it keeps the real map's proportions.

**Grab and drag.**
- **The picture is draggable:** `derpy_mr_map_art` is `moveable="Movable XP"`, CA's value, used
  209 times in ui3.pack.
- **Everything moves with it:** the dots, names, road and carts are made as its children, so they
  are drawn over it, cut with it and dragged with it.
- **It stays on the picture:** `S.map_hold`, on the existing 16ms poll, puts it back where it still
  covers the box.
- **On a map with no picture,** the surface is CA's clear pixel, `1x1_transparent_white.png`. CA's
  own twui files reference a `transparent_pixel.png` that is in none of its packs; the art check
  caught it.

**CA's markers.** `icon_marker_settlement.png` (24px) marks a settlement and `icon_offscreen_capital.png`
marks a province capital, at 20 and 26px.

**What each supply pays with.**
- **The model:** `F.supply_state` also returns `pay[use] = {stem, n}`, the good the payment takes
  first (the fullest, a tie by resource key, as `F.draw_realm` takes them).
- **The tab:** the good's icon sits beside its box, the pair centred, greyed with the Exchange's
  shader when the store cannot cover the price. Its tooltip reads "Paid from Coal first, the
  fullest store." or "Nothing to pay with".
- **A fault the preview caught:** every row carries these icons, and rows without supplies left
  them showing at their default spot. The tests did not catch it.

**Checked by:**
- **Harness, map:** `CampaignRadarPosition` faked with unequal x and y scales, so a logical-frame
  map fails. Dots on their places on all three maps; fallback when the engine is silent; one read a
  session; drag clamped both ways with the dots following; the markers.
- **Harness, Spending:** pay icons, greying, tooltips, and hidden on other rows. The flows harness
  covers the fullest and the tie.
- **Mutation:** 15 new mutants and 12 of 27b's, all caught; 27b's "art not flipped" target no longer
  exists.
- **Live:** the two-point frame was run against the live engine.

**Seen in game:** placement and markers are right. The drag did nothing, and the moveable flag was
not the cause: a live probe read `IsMoveable()` and `IsInteractive()` true on the picture. The
scrolling list stayed built on the Map tab with no rows. It kept the map's exact box and was made
after the map, so its interactive `list_clip` lay on top and took every grab. `S.draw` now drops the
list on the Map tab. Harness: no list on the Map tab, and the Resources tab gets it back.

**Still to see in game:** the drag itself, once nothing covers it.

### 27d. Frame, key and zoom (2026-10-04)

**Seen in game first (author's screenshot, IEE):** the drag works, and a click on a settlement flies
the camera there. Asked for next: a border round the map, a key, and zoom.

- **Frame:** `derpy_mr_map_frame`, CA's own `panel_back_border.png` (the panel's second layer,
  margin 30, clear centre), the last child of the map's box, so it is drawn over the picture and
  everything on it. It is not interactive, so the grab goes through it; `gen_mr_ui.py` asserts that.
- **Key:** on the bottom line, left of slot 3: CA's capital marker "Province capital", settlement
  marker "Settlement", convoy icon "Convoy" (`L.map_key`, `S.MAP_KEY`). Map tab only.
- **Zoom:** "Zoom out" / "Zoom in" in bottom-line slots 3-4, a step of `MAP_ZOOM_STEP` (1.5) around
  the spot in the middle of the box after any drag (`S.zoom` reads it back off the surface's place).
  The closest is `MAP_ZOOM_MAX` (3) picture pixels per pixel; the farthest is the whole picture still
  covering the box. The plain map zooms from its first framing to 3 times it, and its surface grows
  to carry every point, so a zoomed plain map drags too. The buttons grey at the limits. Reopening
  the panel or changing tab frames the map as it first was.
- **No wheel:** no mouse-wheel event reaches script (none in CA's docs or its 7,540 scripts). CA's
  own zoomable minimap, `MapImageCallback` with `zoom_min`/`zoom_max` user properties (ui3.pack),
  draws its own icons, not ours, so it was not used.
- **Checked by** the harness (frame on the box and last in it; key icons, names and places; zoom
  step, centre kept, both limits, greyed clicks change nothing, resets, plain map) and 10 mutants:
  9 caught; the 10th, a click guard, was redundant with the model's clamp and was deleted.
- Built into `Modpacks/` 2026-10-04 09:16, **not in `data/`** (the game was running).

**Seen in game (09:19): the frame sat inside the map's edge,** a strip of map showing outside the
copper line. CA's `panel_back_border.png` draws its line from its **4th pixel in** on all four sides
(the panel hides this; the panel's edge is not on anything). The frame is now `MAP_FRAME_OUT` (4)
larger than the map's box on every side and the box cuts the clear 4px off, so the line lands on the
edge. `check_map_frame()` measures the 4 off CA's file (the preview's extracted copy) on all four
sides; the harness holds the frame's box to it. Both faults planted and caught. Repacked the same morning, still
not in `data/` (game running).

**To see in game:** the frame on the edge; that it lets the drag through; zoom staying on the spot
you are looking at.

### 27e. Polish pass over every view (2026-10-04)

Every tab and both drill-downs drawn by `tools/preview_resource_vault.py` and read. The two
drill-downs (`goods_focus`, `settlement_focus`) had never been previewed; the harness now dumps both.
- **Chart (a bug):** the bars stood from the left, so with 3 turns the newest ended at x 175 while
  "Turn 5" sat at the right under nothing. The bars now stand at the right, newest last, so the latest
  turn is always over "Turn N". "Turn first" moves under the first bar and is dropped where it would
  meet "Turn N" (2 turns). A baseline (`chart_base`) runs under the bars, and a fainter line at the
  top value (`chart_grid`, `#6B583640`) ties the floating top figure to the bars it measures. Both
  lines are hidden with no history.
- **Map title:** "Where your settlements and convoys are" (was "...convoys are"; the tab draws both).
- **Looked at and left:** Goods tab's "held / space" in the Space column repeats Held, but it is
  the approved spec's format. The raw keys on the Trade tab preview (`black_lotus`) are the harness's
  missing loc; all 54 stores ship a display name.
- **Checked by:** harness asserts (newest bar ends at the chart's edge and with "Turn N"; first label
  under the first bar, kept at 3 turns and dropped at 2; both lines placed, hidden with no history),
  three mutants all caught. Deployed to `data/` 2026-10-04 with §27d's frame fix (backup in
  `%TEMP%/ro_backup_20261004`).

### 27f. Drag that stays, + and - buttons, the Exchange's slider (2026-10-04)

- **Let go, the map went back where the drag began (seen in game).** `moveable="Movable XP"` is
  CA's drag-and-drop flag: of its 209 uses in ui3.pack most are unit cards, ingredient slots and
  ancillary entries, which spring back when dropped on nothing; the map did the same. Fix: CA's
  documented `uicomponent:IsDragged()`. While it is true the 16ms poll notes where the map is; once
  let go, `S.map_hold` holds it there for `S.KEEP_TICKS` (10) frames, past the put-back. A redraw
  (a zoom) clears the hold, so a zoom right after letting go is not pulled back. **Not yet seen in
  game:** that Position() follows the drag while IsDragged is true (the design assumes it).
- **Found, not used:** CA documents `DragAndZoomCallback` ("drag around and zoom in and out ... with
  mouse wheel scroll (for maps, etc)") and `DraggableContainerCallback` (a child clipped by its
  parent, panning and zooming, user property `allowance`). Neither appears in any WH3 ui pack or in
  TWUI Studio's catalog, so how they behave is unknown. They are the route to wheel zoom, after an
  in-game probe.
- **+ and -:** round 30px buttons in the map's bottom-right corner, CA's `button_round_small_*`
  (the Close button's art) with "+" / "-" as text: CA ships plus icons but no minus. Made in the map's
  box after the frame, so drawn over the map; `L.zoom_in` / `L.zoom_out`; tooltips "Zoom in" /
  "Zoom out", "As far as it goes." at a limit.
- **The Exchange's slider** (asked): CA's event message slider - rod, 9-sliced handle with CA's
  hover brighten, frame caps and arrow buttons - ported from `gen_guilds_ui.ca_vslider` into
  `gen_mr_ui.ca_vslider` (a copy, by the two-mods-two-code-paths rule). `SLIDER_W` 18, `SLIDER_CAP`
  24, `SLIDER_PARTS` in the generated layout, so the Lua and the XML read one table. The track sits
  between the caps; the list's travel is the track less the handle.
- **Checked by:** harness (let-go hold, a late put-back undone, freed after the hold, a zoom after a
  drag kept; +/- placed, labelled, drawn over the frame; slider track, all four end parts, travel)
  and 8 mutants, all caught. Deployed to `data/` 2026-10-04 (backup `%TEMP%/ro_backup_20261004b`).

### 27g. CA's shaders on the panel's actions (2026-10-04)

Asked for: "visual effect shader to action, such as active doctrine or selecting it", based on CA's.
CA's UI shaders were counted by the state they sit on (memory `wh3-ca-ui-shader-vocabulary`):
`brighten_t0` on hover, `glow_pulse_t0` 1/2/3 on active/glow states, `red_pulse_t0` 0/0.25/1 on
"insufficient", `set_greyscale_t0` on inactive. One helper, `S.fx(c, kind)` with `S.FX`, carries them;
`S.set_off` goes through it and the old `S.shade` is gone.
- **A running order** (Festival, Muster, Great Works) glows and stays unclickable; its tooltip says
  "Running: N turns left. Ready again in M turns." `F.order_state` now returns `active`, the turns
  left of its bundle.
- **A supply's pay icon:** on and covered - glows as it pays; on but short - red pulse (CA's
  "insufficient"), it will switch itself off; off and short - grey; off and covered - plain.
- **The map:** a convoy's cart pulses; a settlement marker brightens under the mouse (its hover
  state: the same marker, `brighten_t0` 0.5; the Lua points image 1 at the marker image 0 shows).
- **Checked by:** harness (each state's shader and CA's values, a running order ignores clicks, a
  waiting one is grey not glowing, the hover image, the cart pulse) and the flows harness (active 5,
  1 on its last turn, nil after); 5 mutants, all caught. Deployed to `data/` 2026-10-04 (backup
  `%TEMP%/ro_backup_20261004c`). **To see in game:** the pulse's strength on each, and that the hover
  brighten shows on the markers.

### 27h. No + and - on a first draw; the drag flicker (2026-10-04)

**Seen in game (screenshot, Karaz-a-Karak):** no + and - buttons, and a one-frame flicker on every
drag. The script log (`script_log_041026_1053.txt`) showed the Vault loading and no errors from it;
the wh3 bridge was not connected that session, so nothing was probed live.
- **No + and -:** `S.draw_map` placed them BEFORE the map's box. They are the box's children, and
  the box's own MoveTo carried them off by however far it moved, which is the whole way on a
  session's first draw. The harness only drew the map after the box was already in place. Fixed by
  placing them after the box; the harness now moves the box away before the first Map draw. The
  "wrong order" mutant is caught.
- **The flicker replaces §27f's hold.** Holding the let-go picture after the engine's put-back
  still showed the picture back home for one frame. Now the engine never drags the picture: a clear
  **grab layer** (`derpy_mr_map_grab`, the box's size, first in the box so beneath everything) is the
  only `Movable XP` component. The picture is no longer interactive, so a press on bare map goes
  through to the grab layer, and the markers on the picture keep their own clicks (rows already
  showed clickable children inside a non-interactive holder). While the grab layer `IsDragged`,
  the poll moves the picture by the grab layer's offset from the box's corner. On release the
  engine puts back the clear layer, which nobody sees, and the poll returns it home if the engine
  does not. `S.KEEP_TICKS` / `S.map_keep` are gone.
- **Checked by:** `gen_mr_ui.py` (grab layer interactive and moveable, picture neither, grab first)
  and the harness (covers the box, beneath the picture, the picture follows, stays on release, a
  stray grab layer goes home without moving the picture, edge clamp, zoom after a drag). 5 mutants:
  4 caught; the 5th found a redundant clear, which was deleted.
- Deployed to `data/` 2026-10-04 (backup `%TEMP%/ro_backup_20261004d`). **To see in game:** that a
  press on bare map starts a drag through the non-interactive picture, and that the markers still
  click. If the press does not reach the grab layer, the wh3 bridge can read `IsDragged()` on it
  live.

### 27i. The mouse wheel over the map (2026-10-08) - DragAndZoomCallback tried and removed

**Seen in game:** the wheel over the Map tab zoomed the campaign camera under the panel, not the
Vault's map. The wheel is not a shortcut (`text/default_keys_osx.xml` has no wheel binding, so
`cm:disable_shortcut` cannot block it), and no wheel event reaches script.
- **Tried:** CA's `DragAndZoomCallback` on the grab layer (documented for "drag around and zoom in
  and out ... with mouse wheel scroll (for maps, etc)", used in no WH3 ui pack), with the poll
  reading any engine resize of the layer as a zoom step.
- **Seen in game the same morning (`script_log_081026_0935.txt`):** dragging stopped working and the
  wheel zoomed nothing. Every press reached `derpy_mr_map_grab` and the log printed it at the same
  `[550, 362]`, `[820, 448]` each time: the callback took the press away from `Movable XP` and moved
  or sized nothing a script can read. No `map wheel` line.
- **Removed:** the layer is back to `Movable XP` alone, and `gen_mr_ui.py` now asserts the callback
  is absent. Deployed to `data/` (`5bc530b4`; the broken `6d2c196b` backed up in
  `Backup/resource_overhaul_20261008_wheel_revert/`). Wheel zoom stays open; the + and - buttons are the zoom. Untried:
  `DraggableContainerCallback` (on a clipped child, user property `allowance`).

## 28. Stopping a good's CA trade export (measured 2026-10-08)

Asked: the Trade tab's Exports switch stops only the stores' shipments, while CA's trade
agreement still pays for the good. Measured live through the bridge (Old World, Overlords of
Zharrduk, one salt building at 20 barrels, trading with the Conclave):

| Test bundle on the faction | After the turn |
|---|---|
| `wh3_dlc29_effect_region_disable_resource_salt`, `faction_to_region_own`, 1 and 100 | no change, 20 barrels (bundle confirmed present). CA's 16 disable effects are dead content |
| `wh_main_effect_region_resource_salt_production`, `faction_to_region_own`, -20 | salt gone from Producing and Exports; income 465 -> 285, exactly 20 x 9 |

Trade figures move at turn start only; a mid-turn read is not a measurement. Imports cannot be
refused per good (they are the partner's exports). Memory `wh3-stop-a-trade-export-per-faction`.

**First build, WITHDRAWN the same day: a flat -1000 per good, faction-wide.** A custom bundle with
each stopped good's production effect at `faction_to_region_own`, -1000. Stop all, in game: Producing
emptied, and the Trade Forecast then listed EXPORTS of goods the faction never made (Dwarf Beer,
"Exporting: 20 kegs", value 12), income 465 -> 18,801. A production total far below zero is not
read as zero by CA's trade; the -20 row above worked only because it cancelled exactly what was
made. Never push a resource's production below zero.

**As built: exact hold rows.** Every production row (`building_to_building_own`, one of the 54
goods' production effects) gets a twin with `value`, `value_damaged` and `value_ruined` negated and
`context_requirement` = `derpy_mr_hold_<stem>[__<its own condition>]`, an expression
`(<its own condition>) && Owner.IsEffectBundleActive("derpy_mr_hold_<stem>") == true` (CA's own
building-to-owner test, `HasToZFactoryConclaveSeat`). The cancel is therefore exactly what is made,
same lore gates, same damage, never below zero. Three sets, each in a file of its own so every
production check still reads production: `_hold` (our 2,810 rows), `_hold_ca` (CA's 820, refused by
the public repo like the `_ca` twins), and the Old World submod's 33 (its 30 plus the map mod's own 3).
`F.hold_exports` now only puts the 54 hidden faction markers `derpy_mr_hold_<stem>` on and off
(`cm:apply_effect_bundle(k, f, 0)`; 0 is indefinite, CA's wrapper clamps -1 to it) and the visible
record `derpy_mr_exports_held`, which it always removes first: a save from the first build carries
a custom bundle under that key with -1000 on every good. Players only; the player's turn start
re-syncs. **Checked by** `check_hold_part` (one hold per production row, negated, own condition
then marker; main pack, CA's rows, the Old World submod), nine selftest mutants, and the flows
harness, ten mutants, eight caught, two equivalent (re-running `hold_exports` is idempotent).
The harness assumes a DB bundle applied over a custom one of the same key does NOT replace it,
which is unmeasured. Deployed to `data/` (`32e3a7c8`; backup
`Backup/resource_overhaul_20261008_hold_rows/`). **Seen 2026-10-11 (36):** Stop exports on books put
the hold bundle on and set `exports_held`; the income was not read. **Still to see:** Stop exports
of one good, end the turn: it leaves the Trade Forecast and income drops by its value only, with no other good
appearing; Allow, end the turn, and it returns. Unmeasured: whether a building effect expression
re-reads the owner's bundles at turn start (it should: CA's ToZ factory seat works the same way).

**Every scope, since the sweep (section 30).** The first hold build twinned only
`building_to_building_own` rows. CA has 13 more production rows for these goods on other scopes:
Underdeep gems/iron/marble and the beer blocker on `foreign_building_to_region_own`, the Spirit of
Grungni beer halls on `force_to_region_own`, and the Underdeep drinking halls, which CONSUME beer
(-4/-2/-10) on `foreign_building_to_region_own`. Holding beer cancelled the positive rows and left the
consumption, a total below zero: the phantom case above. Each now has a twin on its own scope
(`_hold_ca` 833 rows); `check_hold_part` no longer filters by scope, so a scope filter put back is a
count mismatch. Whether `Owner.` evaluates on a foreign-building or force scope is unmeasured; if it
does not, those twins never apply, which is the old behaviour. NOT holdable: 17 rows in
`campaign_effect_list_effect_junctions` (Aislinn's colonies, the dragonship, Throgg's dens; that table
has no condition column) and the Talabecland minister bundle (timber +24). They are positive only, so
a held good there keeps a small export, never a phantom one.

## 29. Import duty (2026-10-08)

Spec `superpowers/specs/2026-10-08-resource-overhaul-import-duty-design.md` (decisions: 10%,
everyone pays, gold to the exporter). Deployed to `data/` (`413927e5`; backup
`Backup/resource_overhaul_20261008_import_duty/`), not seen in game.
- `F.duty(faction)` at every faction's turn start, after `F.trade`: for each partner in
  `factions_trading_with()`, `floor(F.made_value(partner) x rate / 100)`, capped at the payer's
  treasury, `cm:treasury_mod(payer, -due)` then `(partner, due)`. Computers under "Other factions use
  their stores"; `F.uses_stores` gates the payer.
- `F.made_value(faction)`: one walk of every settlement's store pools, summing each
  `derpy_mr_stocked` factor x `F.price(g)` (the Exchange's price, else `SELL_RATE`); cached per
  faction per game turn.
- Booked for humans by game turn (`book.duty[turn]`, two kept); the panel shows the turn before.
- MCT "Import duty" slider 0-50, default 10 (`RATES`); an old save fills the new key in.
- Trade tab: an "Import duty" first row (CA's `income.png`), "paid N, received M" under Last turn,
  each partner in its tooltip; no row while the rate is 0. The Imports tooltips now say trade
  agreement imports carry import duty (they said "cost you nothing" for an hour).
- **Checked by** the flows harness (payment, the partner gets exactly it, ledger next turn, a
  computer pays the player, its switch, a 5-gold payer pays 5 and runs no debt, rate 0, nothing
  made) and the stores harness (row first, both ways, tooltip, no switches, hidden at 0); 7
  mutants: 6 caught, the 7th (the rate-0 early return) only skips the walk and is commented so.
  Preview `mr_trade.png` drawn and read.
- **Seen in game** (below, and 36: paid 10 then 22, received 30): the treasury moving at turn
  start by the row's figures; the Conclave's treasury rising by what you paid. **Still to see:**
  turn-start time with many factions trading.

**Seen in game the same afternoon (turn 6): "received 6128".** The duty priced goods with
`F.price`, the Exchange's market price when it is loaded: salt 818, coal 400, brass 1,930,
blackpowder 4,549 a unit (read live). One turn's 44 units came to 61,690, so the Conclave paid its
whole treasury. CA's trade pays 9 a unit (Trade Forecast "Resource value: 9" for Salt and Brimstone,
both `trade_value` 50). **Fixed:** each good carries `value` = `trade_value` x `gen_mr_ui.CA_UNIT_VALUE`
(9/50, measured) on `DERPY_MR_FLOWS_GOODS`, and `F.made_value` uses it, never `F.price`. The harness
now runs the duty with a stub Exchange at 818 and expects CA's value; putting `F.price` back is
caught. Deployed `b2db35fd` to `data/` (backup `Backup/resource_overhaul_20261008_duty_price/`). That save keeps the
6,128 windfall and the Conclave's empty treasury.

## 30. The full sweep (2026-10-08)

Six read-only reviews (flows economy, flows engine safety, the panel, the AI/hub/MCT scripts and
cross-file keys, the DB generator, the harnesses with 95 mutants), every claim re-read in the code
before fixing. Fixed, each with a harness test watched failing (20 mutants, 20 caught):

1. **Sell surplus paid 10x with the Exchange loaded.** `EX.sell_price` is a LOT's price (the
   Exchange's own note at `EX.holdings_value`); `F.price` now divides by `EX.lot`. The per-unit
   market figures in section 29 (salt 818, blackpowder 4,549) were lot prices too.
2. **Sell desynced multiplayer with the Exchange loaded:** `EX.sell_price` reads the houses' stance
   toward `EX.who()`, the LOCAL player. `F.price(g, fkey)` runs it inside `EX.with_player(seller)`.
3. **Holds missed 13 CA rows on other scopes**, beer going below zero (section 28, "Every scope").
4. **Import duty on held goods:** `F.made_value` skips a good the exporter holds.
5. **Two Restores in one turn:** the answer cannot say which settlement, so the second offer
   replaced the first and the first answer paid for and repaired the second. One Restore per
   faction per turn; a pending one from an earlier turn is stale and blocks nothing.
6. **The turn-start snapshot read display names** (loc from a turn handler, the turn-1 CTD of
   2026-09-07). `S.read_realm(faction, true)` reads none; the harness counts loc calls in a human's
   turn start and expects 0.
7. **Opening the Vault froze the settings** (single player, before the first turn start).
   `F.rates()` is now a read; `F.freeze_rates()` writes, at first tick (a new campaign fires no
   FactionTurnStart until turn 1 ends) and at every turn start. The MCT page greys every option in a
   campaign with a reason, as the Guilds' and the Exchange's do.
8. **A dilemma never issued left its offer pending and started the event gap.** CA's wrapper
   returns false in multiplayer when not issued (single player always true, an intervention):
   the offer is cleared and no gap starts.
9. **A failed siege's battle reading fed a later raze.** Any decision spends it, and it is stamped
   with its turn.
10. **Supply pay icon pulsed red while the capital could pay:** short is now the use's total.
11. **Workshop tooltip listed rare goods** after "not counting rare goods".
12. **Pay icon tie by resource key, payment by stem** (Starwood shown, Marble taken).
13. **Chart's newest bar** read as the live figure: now "Start of turn N: X held".
14. **Imports tooltip on greyed rows carried the grey markup.**
15. **Import duty row shown to factions that never pay** (no stores).

Not a bug on reading: a seized shipment shows in the owner's history as moved and lost on the road
(sent as `moved_out`, never `moved_in`). Left for decisions, not fixed: rare goods spent as bulk
by orders/supplies/events; duty one way with "Other factions use their stores" off; Restore not
offered on loot-and-occupy; our Underdeep coal/silver/brimstone rows on `building_to_building_own`
where CA scopes that building `foreign_building_to_*` (probably makes nothing for trade; look in
game). AI supply and event books: closed 2026-10-09, a dead faction's are dropped by `F.sweep` at a player's turn start (4 mutants caught, deployed `10fd5951`);
the hub's `HUB.plate` comment says wrappers must be compared by Id, but `HUB.hover` compares with
`==` and works (CA does the same, `lib_help_pages.lua:2592`); the hub is shared by four mods and
the left bar submod, so its comment is left. Deployed `b57c8802` to `data/` (backup `Backup/resource_overhaul_20261008_sweep_fixes/`).

**Decisions the same day (author).** A: a rare good is never bulk - `F.bulk(use)` is the one pick
every use-wide count and draw goes through (`F.use_total`, `F.draw`, orders, events, the supply
icon, Supply the capital), so orders, supplies, events, upkeep and the holding bonuses neither count
nor take gromril, ithilmar, dragon bone, starwood and the rest; only the Workshop does, and the
panel's goods lists leave them out. C: Restore is offered on loot-and-occupy too. D: the Underdeep
coal/silver/brimstone rows show prices in game, so `building_to_building_own` works on that
foreign-slot building; nothing to change. B (one-way duty with the other-factions switch off) is
still open. Six mutants, six caught; deployed `40797c9d` (backup
`Backup/resource_overhaul_20261008_rare_loot/`).
B, decided: **duty runs both ways wherever a player is one side**, the rule trade follows
(`F.allowed` per partner): with "Other factions use their stores" off, a computer partner now pays
the player, and two computer factions pay each other nothing. Two mutants caught; deployed
`dc14833f` (backup `Backup/resource_overhaul_20261008_duty_both_ways/`).

## 31. The recruitment draw (built 2026-10-08, seen in game 2026-10-11, 36)

Stage 1 of the Workshop expansion (spec `superpowers/specs/2026-10-08-resource-overhaul-workshop-expansion-design.md`
section 3, plan `superpowers/plans/2026-10-08-resource-overhaul-recruitment-draw.md`).

- **Trigger:** `UnitTrained`, `context:unit()` (CA reads `:faction()` there too, `corruption_swing.lua:127`).
  Reads `unit_caste()` and `get_unit_custom_battle_cost()`. CA documents the second as the *multiplayer /
  custom battle* cost, so a recruit is priced at that, not at its campaign cost.
- **Rule:** `ceil(value/100 * per100)` of the caste's use (`gen_mr_ui.CASTE_DRAW`); value >= 1200 also takes
  `ceil(value/400)` of the race's rare good (`RACE_RARE`, Dark Elf foot `black_lotus`). Lords, heroes,
  `generic`, an unreadable caste or a 0 value take nothing.
- **Shortfall:** Chaos Dwarfs Armaments (1 per 2 goods), Ogres Meat (1 per 3), Skaven Food (1 per 2), through
  the spend-only factor `derpy_mr_recruit`; then gold at 2x the cheapest good of that line, capped at the
  treasury. **Tomb Kings and Khorne get no currency**, a deviation from the spec: both are in `NO_STORES`, so they
  never draw.
- **Workshop units** bought into the mercenary pool record one free recruit per purchase
  (`works.free[unit]`); the next `UnitTrained` of that key is skipped. The army route
  (`grant_unit_to_character`, the player's and the computer's) records none since 2026-10-12 (38):
  **that call fires no `UnitTrained`** (measured 2026-10-11), so a booking there was never spent and
  made the next ordinary recruit of that unit free.
- **Panel:** "Recruits last turn" at the foot of the Spending tab, with the race's line in its tooltip.
- **Measured 2026-10-11 (36):** `UnitTrained` fires for a player recruit and for the computer (1,203 in
  one round, 75,456 gold charged, no error); it does NOT fire for `grant_unit_to_character` or
  `create_force`. `unit_caste()` and `get_unit_custom_battle_cost()` answer: Swordsmen took 4 iron; a
  shortfall took the last 3 iron and 18 gold. Still unmeasured: global recruitment and mercenaries.
  A failing read is caught by `F.guard` and charges nothing.
- Final review fix: the free recruit is booked BEFORE the grant call, so a `UnitTrained` the engine fires inside
  `grant_unit_to_character` finds it (harness stubs a re-entrant grant). Measured: that call fires no
  `UnitTrained`, so CA's own scripted gifts (custom starts, caravans, Glottkin) are not charged as recruits. Known and kept: a war machine with an odd base takes one extra
  good (each half rounds up).
- 13 + 2 + 4 mutants caught. Deployed `3fe19009` (backup of the build before it: `Backup/resource_overhaul_20261008_recruit_draw/`).

## 32. Named recipes (built 2026-10-08, seen in game 2026-10-11, 36)

Stage 2 of the Workshop expansion (plan `superpowers/plans/2026-10-08-resource-overhaul-named-recipes.md`).
`gen_resource_overhaul.WORK_RECIPES`: 18 works priced in named common goods, drawn by STEM (`rare_pick`),
never by use, so a recipe never spends a good it does not name.

- **Race resources** (once a turn, gain-only factor `derpy_mr_workshop`): Chaos Dwarfs coal/brimstone/iron
  -> 30 Armaments; Skaven grain/salted_fish -> 4 Food (the pool caps at 100); Dwarfs gold_idols/silver -> 30
  Oathgold; Vampire Coast rum/pearls -> 50 Infamy (a SCORE toward victory, not a currency). **No Ogre Meat:**
  `wh3_main_ogr_meat` is scope `MILITARY_FORCE`, out of `cm:faction_add_pooled_resource`'s reach (the same
  finding removed Ogres from stage 1's shortfall currency; Skaven's shortfall rate became 1 Food per 5 goods).
- **Army works** on the army selected on the map (`cm:get_campaign_ui_manager():get_char_selected_cqi()`,
  carried through the new `aim` action on the UITrigger door): Rations and Drill (+1 rank), Ammunition Train,
  Field Forge, Remounts, Medicine Chests (force bundles, 5 turns). A wait of 5 turns **per army, per work**.
  Medicine Chests give attrition resistance: CA has no generic post-battle casualty recovery.
- **Lord and hero works**: five traits on CA's donor `wh2_main_trait_defeated_balthasar_gelt`'s rows,
  `cm:force_add_trait`, once per character. Spice-hardened's movement -5% is the one listed penalty.
- **Works that last**: five faction bundles for good, once a campaign (stays bought if the bundle goes).
- **Computer factions** buy lasting works and conversions only, every good held twice over. Their unit
  purchases now book the free recruit before the grant (stage 1's review finding, on the AI path).
- **Panel**: a recipe's price is up to four icon-and-amount pairs from column 3 (`PRICE_PITCH` 50, row
  cells `use1-4`/`pn1-4`), short ones grey and red; every Workshop section folds on a click.
- 5 + 6 + 8 + 6 + 6 mutants caught. Deployed `e371147d` (backup `Backup/resource_overhaul_20261008_named_recipes/`).

## 33. Rare works deepened, and stage 2's review (built 2026-10-08, seen in game 2026-10-11, 36)

Stage 3 (plan `superpowers/plans/2026-10-08-resource-overhaul-rare-works-deepened.md`): 15 more CA items and
9 more units on the existing rare pricing, plus Regiments of Renown pools for four races new to the Workshop
(Vampire Counts, Cathay, Norsca). Every row passes `check_works` (faction sets via `_set_admits`, units in
`main_units`, pools owned). Lore-led: the Zombie Dragon for dragon bone (CA's own dragon graves grant it), Norsca's
Frost Wyrm and Drake Hunters' Banner, Cathay's Dragon Guard and Icon of the Spirit Dragon.
Left out: Imrik's Vine Dragon Scale (his encounter reward), the Feral Wyvern
(Waaagh-pool only), the Ogre Dragonhide Banner, and Kislev's three feather works (Winged Lancers, Phoenix Pinion, Griffon Banner):
Kislev makes no feathers and `F.lacks` ships only to a capital holding none, so an import stops at one
shipment, short of every price. `check_works` now asserts a rare work's races can make its good. CA's "Magnificent Armour of Borek Beetlebrow" shows as "Armour of
Borek Beetlebrow" in the panel (the row's name field; the item keeps CA's name).

Stage 2's final review, three findings fixed: a conversion is refused when the pool cannot take it ("full": Skaven
Food caps at 100) or the faction has no such pool ("no_pool"); Spice-hardened and Furred and Booted are a lord's
only (`lord = true`, `character_type("general")`), since their effects are `general_to_force_own`; the Workshop
redraws on `CharacterSelected`/`CharacterDeselected` and a click whose selection moved since the draw redraws
instead of buying for the old army. Deployed `aae632d2` (backup `Backup/resource_overhaul_20261008_rare_works/`).

## 34. Escort battles (built and in `data/` 2026-10-09, raid and defence seen in game 2026-10-11, 36)

Spec `superpowers/specs/2026-10-09-resource-overhaul-escort-battles-design.md`, plan
`superpowers/plans/2026-10-09-resource-overhaul-escort-battles.md`. Taking a shipment's cargo costs a
battle whenever a player is one side; computer against computer is still a free seizure.

- **The escort is rolled when the cart leaves** (`F.escort_roll`) and saved on it as CA's unit list:
  `clamp(4 + cargo x SELL_RATE / 40, 4, 12)` units at CA's Nagash power rule (turn / 10, 1-10), from
  CA's own `WH_Random_Army_Generator` templates by subculture (`gen_mr_ui.escort_templates`, 19).
  Border Princes use the Empire's; Cathay, which CA gives no template, uses ours (`ESCORT_OWN`, CA's
  tier weights). A subculture with neither has no escort and its carts are taken free.
- **Two traps in CA's library:** `generate_random_army` appends to a force it already holds on every
  call, so it runs once per key per session and later rolls use `random_army_manager:generate_force`;
  and five keys in CA's templates (`wh_main_emp_veh_steam_tank`, not `_driver`, and four more) have
  no `unit_variants` row, so they are pruned from our copy of the force (`ESCORT_DROP`).
- **Raid:** a player's army walking onto an enemy cart gets the DB dilemma `derpy_mr_dil_raid`
  ("Attack the escort" / "Let it pass"). Attack spawns the escort for the owner at the cart through
  CA's `Forced_Battle_Manager` and the player's army attacks it; a win seizes as before, a loss or a
  retreat leaves the cart. A raid that cannot start (CA's manager busy, the army gone) takes nothing.
  A human army standing by a computer's escorted cart at its turn start no longer takes it. A raider
  garrisoned or in a stance CA's manager cannot attack from (raiding, ambush, encamped) starts no
  battle; march and double time do.
- **Defence:** an enemy army by a player's cart at the player's turn start fights the player's own
  spawned escort, retreat locked; a win moves the cart on as that turn would have, a loss seizes it.
  One battle a turn start; a second threatened cart is seized as before, and so is one whose attacker
  is garrisoned or in a stance that cannot attack. A computer army that walks onto a player's escorted
  cart does not take it there; it waits for the player's turn start and fights the escort.
- **The outcome** is read in our `BattleCompleted` listener from CA's pending-battle cache, only when
  `pending_battle_cache_mf_is_involved` holds for BOTH the attacker and the escort (its cqi copied on
  `PendingBattle`, since CA's clean-up wipes it) - the attacker alone matches its other battles.
- **CA's list entry is left for CA.** Its manager arms a one-shot `BattleCompleted` handler at trigger
  time that runs after ours in the same session (before ours after a 3D battle's reload) and reads
  `forced_battles_list[active_battle]` to kill the escort and free the slot. The first build deleted
  that entry in our handler: CA's then hit a missing key, the escort stayed on the map and the slot
  stayed taken, so no escort battle could start again that campaign. Found by the final review; the
  harness stub now runs CA's handler as CA does. Our finished keys are pruned at the next human turn
  start instead.
- **A fight that never happens** (a record older than this turn, or a battle not ours once CA has
  dropped ours) is undone: escort killed through `invasion_manager`, retreat unlocked, character
  messages back on, CA's slot freed if still ours. `UnitTrained` charges nothing for the escort's
  owner while a fight is pending (the escort is not a recruit); every other faction is charged.
- **Panel:** a Spending tab shipment row opens its escort - one CA unit card a unit (60x130, the
  faction-less `unit_variants.unit_card`), the unit's name on hover. Preview `mr_escort.png`.
- **MCT:** "Escort battles" in Using stores, default on, frozen with the rest.
- **Checked:** flows harness (escort roll, raid, defence, outcome, switch, absent CA libraries),
  stores harness (the escort view), 39 mutants across the three tasks, every one caught after two
  test fixes and one redundant guard deleted (`F.defends`); then 17 more against the review fixes,
  all caught after seven survivors were pinned (garrison, march, the clear's escort and retreat, the
  same-turn and CA-key pruning rules).
- **Deployed to `data/`** (md5 `cd4b8ab7` / `209d6349` / `1160df9f`), byte-compared; the one file
  added is `ui/derpy_mr_stores_card.twui.xml`, none dropped. The pre-escort build is backed up in
  `Modding Files/Backup/resource_overhaul_20261009_escorts/`.
- **Seen in game 2026-10-11 (36)** (spec section 9): the defence battle opening at turn start with the
  player as defender; the winner read for a player attacker and a player defender; the retreat lock;
  the escort's general; the raid dilemma's text and the escort view's ten cards. `create_force` fired
  no `UnitTrained`. **Still to see:** a raid offered by `AreaEntered` itself (the test called
  `F.raid_offer`, since no army could reach the marker).

## 35. Founding rare buildings (built 2026-10-10; switched to the call that works and retested in game 2026-10-11, 35b)

Spec: `superpowers/specs/2026-10-09-resource-overhaul-founding-rare-buildings-design.md`. Plan:
`superpowers/plans/2026-10-09-resource-overhaul-founding-rare-buildings.md`. The plan's first task,
the in-game measurement (spec section 3, M1-M6), was done after tasks 2-5 (35a), because the game
and the wh3 bridge were shut that session. The bullets below are the 2026-10-10 build; 35b supersedes
the model, AI and switches bullets.

- **The gap:** 43 lore regions (IE 33, RoC 10) of seven rare goods sit on slot templates other
  regions share, so no slot offers their building (`gen_resource_overhaul.found_regions`). The map
  mods have none.
- **The row:** a settlement's stores view (Settlements tab, drill-down) of a listed region the
  player holds shows one row above the goods: the building's level name ("Bone Pickers"), "Not
  built", the price in the fourth column beside the button ("1000 gold"; under "Per turn" it read
  as income), and **Found**. Greyed with "Needs 1000 gold." / "Needs a level N settlement." /
  "Needs an empty building slot.". No row when another race's building of the same good stands
  there (a captured region gets no second one), when the actions switch is off, or for a race with
  no chain for the good.
- **The model:** `F.found_state` / `F.found` in `flows.lua`, through `F.request(fkey, "found",
  rkey)` like every other action (multiplayer-safe, humans only). Every level:
  `cm:instantly_upgrade_building_in_region`, level 1 into an empty secondary slot (35b; this build
  used `cm:add_building_to_settlement` for level 1, which placed nothing). **Gold is charged only once the building is found there afterwards**; otherwise nothing is
  charged and a log line is written. CA's price and tier: 1000 / 2000 / 3000 gold, settlement level
  1 / 2 / 3 (`LEVEL_DONOR`).
- **The AI:** `ai_regions()` adds the 43, so `derpy_more_resources_ai.lua` builds there with no new
  logic (+43 region lines, nothing else changed). Level 1 now goes through the same call as the
  player's (35b).
- **Switches:** removed 2026-10-11 once measured (35b). This build shipped `FOUND_UPGRADE = False`
  and `FOUND_SLOT_TYPE = None`.
- **Checked:** `check_found()` in `--check` and `--selftest` (three planted faults caught; 43
  regions); the flows harness founding block (placed then charged, upgrade, every refusal, not
  placed, another race's building, a Greenskin founding its own chain, region lost, computer
  faction, actions off); the stores harness row block; 18 mutants, all caught after one plan mutant
  was rewritten (it was a syntax error); preview `mr_found.png` looked at twice.
- **Deployed to `data/`** (md5 `1f0e0351` / `8af79564` / `094a16cf`), byte-compared, file lists
  unchanged. The previous build is in `Modding Files/Backup/resource_overhaul_20261010_founding/`.
- **To measure in game** (plan task 1, in order): M1 does `add_building_to_settlement` place a chain
  the slot's template does not permit, and WHEN it appears (same call / later call / next turn /
  never; the charge rule assumes the same call, and a later one makes every Found click and computer
  build free, plan task 1 step 2); never: the route is dead, pull the row; M3 does it produce;
  M5 does it survive a save and load (either no: stop); M2 does CA's browser offer its upgrade (no:
  `FOUND_UPGRADE = True`, rebuild); M4 what `slot:type()` returns for an empty secondary slot (set
  `FOUND_SLOT_TYPE`, rebuild); M6 does dismantling work. Then a real Found click, and the AI building
  one.

### 35a. Measured in game, 2026-10-10 (plan task 1)

A throwaway Immortal Empires campaign as Karl Franz, loaded with only `derpy_resource_overhaul.pack`
and `wh3_mcp_server.pack` (`derpy_founding_test_mods.txt` in the game folder, launched as
`Warhammer3.exe derpy_founding_test_mods.txt;` - UNQUOTED: the quoted form loads no mods at all).
Darkhold transferred to the player by script; every read through the wh3 bridge.

- **M1 - NO for the spec's call.** `cm:add_building_to_settlement("..._darkhold",
  "derpy_mr_bld_dragon_bone_emp_1")` placed nothing: not in the same call, not in a later call, not
  after End Turn. **Control:** the same call on The Bone Gulch, whose template
  (`wh_dlc15_special_plain_of_bones_darkhold_secondary`) permits the chain, placed it IN THE SAME
  CALL. So the call is synchronous and honours the slot template. The spec's route is dead.
- **The route that works: `cm:instantly_upgrade_building_in_region(slot, "<chain>_1")` on an
  empty, active secondary slot.** On Darkhold's slot 1 it placed the building in the same call.
  CA does the same thing in `episode_vermintide.lua` (`slot_list():item_at(1)` given an endgame
  building).
- **M3 - yes (on that route).** Darkhold's dragon bone store read 10 after one End Turn.
- **M2 - no, by proxy.** With Darkhold raised to settlement level 2, CA's own rule
  (`add_building_to_settlement(..., "_emp_2")`) refused the upgrade. At The Bone Gulch, at level 2,
  the same call upgraded it. So CA's building browser should not offer the founded building's
  upgrade: our row must (`FOUND_UPGRADE = True`). `instantly_upgrade_building_in_region` to `_2`
  worked on Darkhold. The browser itself was not looked at: the bridge cannot read it.
- **M4:** `slot:type()` is `"secondary"` for every secondary slot (`FOUND_SLOT_TYPE = "secondary"`).
  The primary is `"primary"`.
- **M5 - yes.** Saved (`derpy_founding_test`), quit to menu, Continue: Darkhold still held
  `derpy_mr_bld_dragon_bone_emp_2` on a level 2 settlement (the save that loaded was ours, not the
  turn's autosave, which predates the upgrade).
- **M6 - not measured** (dismantling from CA's browser needs the UI by hand). No design change
  rides on it.
- **The deployed build fails safely.** `DERPY_MR_FLOWS.request(me, "found", "..._tor_sethai")` in
  game: nothing built, gold unchanged (9648). No script error from our files in the session.
- **What it meant for the code (done 2026-10-11, 35b):** `F.found` must place level
  1 with `instantly_upgrade_building_in_region` on the free secondary slot (`F.found_free` returning
  that slot, the slot test no longer optional), with `FOUND_UPGRADE = True` and
  `FOUND_SLOT_TYPE = "secondary"`; and the AI script's `MR_AI.act`, which uses
  `add_building_to_settlement`, builds nothing in the 43 regions until it takes the same route there.
  Until then the Found row in `data/` never builds and never charges, and the computer factions'
  attempts there fail the same way.

### 35b. Switched and retested, 2026-10-11

- **The switch (the author's go, 2026-10-11):** `F.found` places every level with
  `cm:instantly_upgrade_building_in_region`. Level 1 goes into the slot `F.found_free` returns:
  active, empty, not working, and `type() == "secondary"`. With no such slot, `found_state` greys the
  row "slot". `FOUND_UPGRADE` and `FOUND_SLOT_TYPE` are gone from `gen_mr_ui.py` (both measured), so
  the row offers Upgrade to levels 2 and 3. The AI script's `MR_AI.act` builds level 1 the same way
  in every region (`MR_AI.free`). Nothing in the pack calls `add_building_to_settlement` any more.
- **Checked:** both harnesses now model the measured engine: `add_building_to_settlement` records
  the call and places nothing. New slot cases: an empty primary, a locked slot and one being built in
  do not count; the AI with no empty slot, or only a locked, busy or port slot, builds nothing.
  17 new mutants were all caught, each AI one on the assertion aimed at it. The 2026-10-10 list was
  re-run: 14 caught, plus 4 stale anchors on code that is gone, each re-aimed in the new list.
- **Built and deployed** to `data/`, main pack only. Four scripts changed: flows and AI, plus the
  stores script and the hub v5 copy from a parallel session's edit. The IEE and Old World packs
  matched row for row and were not redeployed. The previous build is in
  `Modding Files/Backup/resource_overhaul_20261011_founding_switch/`.
- **Retested in game:** a new Immortal Empires campaign as Karl Franz, with the same private mod
  list.
  - Tor Sethai (dragon bone, taken from Caledor): founded by the model's request. Level 1 went
    into empty secondary slot 2; gold 5000 -> 4000. The row then read "Bone Pickers | Level 1 of 3
    | 2000 gold | Upgrade". A click on its button upgraded it to `_emp_2`; gold 4000 -> 2000.
    Level 3 then greyed "gold".
  - Dragon's Death (taken from The Narj): Found clicked through the panel. Level 1 went into
    slot 1, the only active secondary; gold 7000 -> 6000. The row became Upgrade, greyed "Needs a
    level 2 settlement.".
  - Darkhold, held by the Dark Land Orcs (computer, Greenskins): `MR_AI.act` built
    `derpy_mr_bld_dragon_bone_grn_1` in the empty secondary slot and charged 1000.
  - After one turn the stores read 15 (Tor Sethai, level 2), 10 (Dragon's Death) and 10
    (Darkhold).
  - **Bridge trap:** the first two `SimulateLClick`s on the button raised no `ComponentLClickUp`
    at all: a spy on `S.click` saw nothing, and nothing was built or charged. They came in the first
    minutes after the campaign loaded. The next two, minutes later, reached every listener. The
    fault was not in our handler; the turn-one intro was probably holding input. `end_turn` also
    needed `force` while "Building upgrade available" was up.
- **Not measured:** M6, dismantling from CA's browser.

## 36. Seen in game, 2026-10-11

An Empire Immortal Empires campaign, turns 3 to 5, and a Chaos Dwarf save, driven over the wh3
bridge with the author watching (one auto-resolve was the author's own click).

- **The dilemmas' target names drew blank: fixed.** Every store event, Restore and raid dilemma
  drew its target token as nothing ("The stores of  overflow", "a shipment of ."). CA's own
  Middenland confederation dilemma, fired by the same `trigger_dilemma_with_targets` call, drew
  its faction name. The difference: two `cdir_events_dilemma_option_junctions` rows,
  `GEN_TARGET_MODEL` and `VAR_CHANCE` 100, which 49 of CA's 50 target-naming dilemmas carry and ours
  lacked. `_dilemmas` now writes both on all six; `check_dilemmas` requires them, and a planted
  removal is caught. Deployed, then seen: "The stores of Uzkulak overflow with provisions", "[flag]
  Bonerattlaz shares a border with you". It was also the 2026-10-08 Arsenal blank (section 25).
  The bridge's `read_event` shows resolved tokens (CA's dilemma read back with its flag), so a
  blank there is real.
- **Store events:** Feast (100 grain from Altdorf, bundle on), Arsenal (50 war materials, taken
  from the fullest store; every regular unit of the largest army +1 rank, the lord and hero being
  characters), Tribute (50 luxuries) and a decline (nothing spent, the offer cleared). The cost and
  reward lines draw under the buttons.
- **Tribute moves both sides.** `cm:apply_dilemma_diplomatic_bonus`, with its two factions either
  way round, moved the human's attitude to the neighbour at once (+5 a call); the computer
  neighbour's moved at its own turn (9.6 to 13.4). The argument order is not a fault.
- **Shipments:** the leg change moved the wagon scene; a shipment from before the scene arrived
  and its `F.unmark` raised no error; arrivals booked as moved.
- **Escort raid (C3):** a Separatists cart (Grunburg to Ubersreik, 108 salt, 6 escorts) offered
  to Karl Franz. Attack: CA's manager spawned the escort, the battle (auto-resolved, won) seized the
  cargo to Altdorf as raided (salt 6 to 114), and the cart, its scene, the escort force and CA's
  manager slot all cleared. An army in muster stance (it takes it when units are granted to it,
  at no movement) cannot attack: answering Attack does nothing and the cart stays, never a free
  seizure. The offer came from calling `F.raid_offer` directly: no Empire army could reach that
  marker, whose tiles by Grunburg's walls refused a teleport. `AreaEntered` itself was seen firing
  for a player army walking in, after a reload.
- **Escort defence (C4):** an Empire cart beside a Separatists army at the turn-start step. The
  escort spawned as an Empire army (7 with its general), the enemy attacked, no retreat button was
  shown, the escort won (3150 against 2029), the attacker was destroyed and the cart kept its leg.
  Retreat lock, invasion and fight record cleaned.
- **Capture panel:** every option draws our preview. Occupy and Loot & Occupy keep the whole store
  (150 marble, 26 salt at Grunburg); Sack and Raze take half (75, 13).
- **Restore on capture (C2):** occupying Grunburg with 150 marble offered Restore; accepted, 100
  marble spent and `derpy_mr_event_restore` on. Its buildings were undamaged, so the repair had
  nothing to mend.
- **Raze (C5):** razing Ubersreik sent half of its store to Helmgart as plundered (50 timber, 30
  salt), from the battle-time snapshot. The razed region's pools are gone afterwards.
- **Abandon (A3):** `cm:set_region_abandoned` on Grunburg dropped its pools; the store goes with
  the settlement. No error.
- **Save and reload (C6):** `F.state` deep-compared with a snapshot kept in the save: no
  difference (ships, sequence, supply, orders, works, pending, rates).
- **A save from before the stores (C7):** a Chaos Dwarf campaign saved at turn 2 without the mod,
  loaded with it: the rates froze, Uzkulak's pools exist (space 400), no script error.
- **Chaos Dwarfs (C9):** `conv_armaments` turned 20 coal, 20 brimstone and 20 iron into 30
  armaments (100 to 130), then refused "wait". A Bull Centaur charge (20 goods) found none in the
  stores and took 10 armaments instead of gold, with the ledger line "The forges took...". "full"
  cannot happen for armaments (no maximum).
- **Earlier the same day (turns 1 to 3, Empire):**
  - **Stores and holding bonuses (22):** Altdorf took 8 books, 6 salted fish and 6 salt, and ate 2
    salt; `derpy_mr_well_fed` came on. Helmgart read well fed, garrison stocked and comforts all on, and
    ate 2 grain; Altdorf read well fed only.
  - **Orders and sales (23):** a Festival spent 200 books, put its bundle on and started its 10-turn
    wait (5 active). Selling 200 surplus marble at 2 brought 400 gold (6,912 to 7,312).
  - **Supplies and shipments (26):** Materials on Altdorf at 2 a turn, its bundle on by turn 3 (17
    glassware, 2 spent a turn). A 90 iron shipment Helmgart to Altdorf with 10 escort units, due turn 4.
  - **Works (32, 33):** the Demigryph Regiment of Renown into the mercenary pool (0 to 1), the
    Featherfoe Torc, Rations and Drill (every unit rank 0 to 1, a second buy refused "wait"), the spice
    trait on Karl Franz, the lasting records bundle, the feathers upgrade's region bundle.
  - **Recruits (31):** Swordsmen took 4 iron (100 to 96); with 3 iron left, the next took the 3 and 18
    gold. The Spending tab read "Recruits last turn: 7 resources, 18 gold".
  - **Exports and duty (28, 29):** Stop exports on books set the hold; a Middenland trade agreement
    then paid duty 10 and received 30 on turn 2, and paid 22 on turn 3.
  - **Computer factions (17, 31):** four rare buildings in one round, among them
    Crag Halls of Findol starwood at
    Wydrioth, Temple of Skulls black lotus at Mordkin, Karak Vrag wyvern scales at Fulg; 1,203
    recruits charged 75,456 gold with no error.
- **Not measured:** the Old World pack (C8): the Old World map crashed at startup in a minimal mod
  list with no derpy pack in it (`Warhammer3.exe+0x51423F`, twice), so the crash is not ours and the
  pack is still unseen. Skaven food, Vampire Coast infamy, Dwarf oathgold and the Underdeep scopes
  (other races' campaigns). Siege Stores.
- **Left for the author:** computer factions paid about 63 gold a recruit early (1203 units,
  75,456 gold in one round) with empty stores. Fixed 2026-10-12 (38): the Workshop army route's
  never-spent free recruit, and the siege and raid dilemmas' Grom art (`food_merchant`).

## 37. Turning off the game's random dilemmas (2026-10-11)

Asked for after the in-game sweep: CA's own random dilemmas can cover the same ground as the store
events (A Noble Feast and Prosperous Harvest beside Feast; Blood Iron, Rare Metal and Hidden Stash
beside Arsenal; Caravan Raid and Shipping Ledger beside An Enemy Shipment; nothing beside Tribute,
Siege Stores or Restore). Each is gated to one culture.

- **The switch:** MCT "Turn off random dilemmas" (`random_off`), in Using stores, **default off**.
  Frozen into the save with the other switches, so it is set when a campaign starts; multiplayer
  takes the default.
- **What it does:** `F.quiet_dilemmas` at every first tick calls `cm:toggle_dilemma_generation(false)`
  when the switch is on. That is CA's one documented switch for the campaign director's dilemma
  generation, so it is all of them or none: one dilemma at a time would be a DB row per dilemma
  (`dilemmas_tables.generate` false), which cannot follow an MCT setting.
- **Why every load:** CA sets it only from `add_first_tick_callback_new`, i.e. a new game
  (`wh3_tol_helpers.lua:6`, the Tides of Lore starts), which suggests the save keeps it. Setting it
  again at each load costs nothing if so. It is never turned back ON: the setting cannot change in
  a running campaign, and a Tides of Lore start turns generation off itself.
- **Scripted dilemmas still fire:** CA's prologue turns generation off, then fires its story
  dilemmas with `cm:trigger_dilemma` (`wh3_prologue_kislev_expedition_story_panels.lua:165-208`). The
  store events are scripted the same way (`trigger_dilemma_with_targets`).
- **Which are random:** `dilemmas_tables.generate` is true on 243 of CA's 1,167 dilemmas, every one
  with a `VAR_CHANCE` row; only one of the 243 is named in CA's Lua.
- **Checked by** the flows harness: unticked, the first tick never calls it; ticked, it is called
  with false at the first tick and every load; unticking it later changes nothing; multiplayer leaves
  it alone; the MCT default matches the script's. A mutant without the call fails ("expected 1,
  got 0").
- **Not seen in game yet:** that no random dilemma comes with it on, and that the store events still
  do.

## 38. Two fixes from the in-game sweep (2026-10-12)

- **The Workshop's army route no longer books a free recruit.** `F.work_grant` books one only on the
  mercenary-pool route, where the unit is recruited later; `F.work_ai` books none. The flows harness's
  `grant_unit_to_character` stub no longer fires `UnitTrained` inside the call (the measured engine),
  and asserts both army routes leave no booking and charge the next ordinary recruit. Three mutants
  (player route books, computer route books, pool route books nothing), all caught. A save from
  before keeps any booking it already holds: at most one free recruit per earlier army-route purchase.
  **Measured 2026-10-19:** recruiting the Workshop Demigryph from CA's mercenary UI fires
  `UnitTrained` and consumes the free booking; the army grew, the pool emptied, and the booking
  cleared. The player/direct-army and AI Workshop routes also booked none. See the
  [live test](sessions/LIVE_TEST_20261019_RESOURCE_OVERHAUL.md).
- **Siege Stores and An Enemy Shipment have their own pictures.** CA's event pictures live per race,
  `ui/eventpics/<race>/<name>.png`, and `food_merchant` exists only under `grn/`, so every race drew
  Grom's troll. Siege Stores is now `besieged` (20 race folders, each race its own burning town) and
  the raid `all/ivory_road` (CA's caravan art, pinned to `all/` as CA's own rows do; the marker already
  draws CA's caravan scene). `check_dilemmas` now also fails a picture that is not drawn for every
  race (`eventpic_every_race`: pinned to a folder CA ships it in, or in at least 20 race folders), and
  the selftest plants `food_merchant`, which the old CA-uses-it check let through.
- **Built and deployed to `data/`** (md5 `26156b30` / `f88527a3` / `2d7cca28`), file lists unchanged.
  The IEE and Old World packs' byte differences from `Modpacks/` (noted 2026-10-12) were RPFM's
  per-save table headers: every row decodes identical. Backup:
  `Modding Files/Backup/resource_overhaul_20261012_free_recruit/`. Not seen in game.

## 39. Follow-up live test, 2026-10-19

Build `26156b30`, isolated Empire IE campaign through the Warhammer MCP, turns 1-5.
The October 12 recruitment fixes and both dilemma pictures were verified; food, oathgold
and infamy conversions, food overflow refusal, six panel refreshes and exact save/reload
state also passed. Three-turn soak completed with no Resource Overhaul Lua exception.
Setup, warnings, test limits and restored settings: [live record](sessions/LIVE_TEST_20261019_RESOURCE_OVERHAUL.md).

## 40. Stock reserves, import targets and forecasts, 2026-10-19

Build `86e2cdbb`, deployed locally. Automatic five-turn shared reserves and ten-turn capital targets have per-resource Keep/Target overrides in the Trade drill-down. Trade, Send here, standing shipments and Sell surplus protect outgoing stock; ordinary consumption, purchases and enemy seizure can still use it. Standing orders count net incoming quantities. Settlement and Spending tooltips show recurring-use estimates with known/unknown production and incoming cargo separately.

Offline checks, mutation checks, UI previews, five AI-enabled turn cycles, old-save Auto migration and exact policy persistence passed. No Resource Overhaul exception; four known CA Nurgle-listener warnings. Compatibility DB content is unchanged and those packs were not deployed. Preferences and temporary launch configuration were restored.

Limits: real multiplayer unverified; named-save UI inactive, so persistence used a retained engine-autosave checkpoint. Averland still had no food production and an empty food buffer; this needs production/trade-access balance, not an AI reserve exemption. Detailed evidence, changed files, hashes and test setup: [stock-target handoff](sessions/HANDOFF_20261019_RESOURCE_STOCK_TARGETS.md).

## 41. Additional processing and sustained services, 2026-10-20

Build `ddc11a09` was prepared in Modpacks, then locally deployed and [verified through Warhammer MCP](sessions/LIVE_TEST_20261020_RESOURCE_PROCESSING_SERVICES.md): all recipes/services, three real cycles, native capture cleanup and exact named-save reload passed. The user selected only priorities #3 and #4. Local brewing, meat preservation and powder mixing spend complete input batches for extra stored output; passive building production is unchanged. Optional Dwarf drinking halls, Empire civic records and Cathay tea houses consume named baskets for province bonuses. Enable/Pause controls are in each eligible settlement's Stores view. Named input demand feeds existing reserves/targets and forecasts; AI pays the same costs within a two-basket budget.

Both harnesses, 15/15 mutations, generator checks and 17 preview views pass. Saved-pack review matches all 45 DB fragments and 874 localisation rows; only four tables change semantically. Enabled main is now `ddc11a09`; the later MCP test began with Warhammer closed, and original preferences/launch settings were restored afterward. Army provisions and routes/contracts are deferred. Behavior, recipes, service costs, limitations and build review: [processing/services handoff](sessions/HANDOFF_20261020_RESOURCE_PROCESSING_SERVICES.md).


## 42. Carried army provisions (#5), 2026-10-20

Implemented as an off-by-default campaign option in build/enabled copy `cfdb364fc42cfe32553e47eff11475ab`. Original-goods cargo follows force CQI; local loading above Keep, once-per-turn meals, staged shortages and Vault controls reuse the existing flows state and request door. No extra goods, processing/services or routes.

[Implementation handoff](sessions/HANDOFF_20261020_ARMY_PROVISIONS.md) records sources, exact pack/evidence paths, 13/13 army and 15/15 economy mutations and 18 previews. [Later native verification](sessions/LIVE_TEST_20261020_ARMY_PROVISIONS.md) supersedes the initial zero-cycle blocker: six real cycles, all shortage stages/recovery, paid AI resupply, a native replenishment-floor sample, exact 446-record reload, sea travel and owner transfer pass. Actual player-driven merge, prolonged AI balance and two-machine multiplayer remain open. Default stays off. Clean turn-9 checkpoint retained; game exited and original settings restored. (Default changed later the same day: on for new campaigns, see §45.)

## 43. Army supply planning and paid AI relief, 2026-10-20

Build `8208d215`, locally deployed and MCP-verified. Eligible Auto-refill armies add their meals to their owned, unsieged land region's Keep and Target; loading may spend that army share of the reserve but not settlement, named-input or explicit Keep. AI relief sends ordinary paid carts of common provisions from other owned settlements to the region with the worst shortage, after meals and before province supplies, under the usual holds, capacity, loss, travel time and one-cart AI cap. No free food, no AI movement orders. Real carts arrived in three cultures over four owner turns; exact state/stock reload passed. General AI balance stays open. [Handoff](sessions/HANDOFF_20261020_ARMY_SUPPLY_RECOVERY.md).

## 44. Routes and contracts (#6), 2026-10-20

Build `ff9abc08`, locally deployed and MCP-verified. New carts save a duration of `clamp(ceil(distance / 40), 1, 6)` turns, a due turn and their actual gross (at most 100); old carts keep the two-turn fallback. Human buyers create recurring named-good orders (50 per buyer) from an owned or treaty-partner source: internal orders are free, partner contracts lock the ordinary category price and take escrow per dispatched batch. Delivery pays only what fits and refunds the rest; cancellation, war, destination loss, a dead party or seizure return cargo and refund through one settlement path. Native delivery, partial payment and all refund cases passed, with exact in-flight reload. Two-machine MP, long balance and native faction-death settlement stay open. [Handoff](sessions/HANDOFF_20261020_ROUTES_CONTRACTS.md).

## 45. Exchange appetites deployed, content expansion, provisions on the army bar, 2026-10-20

- Exchange `2e2c7b99` (culture, war and construction demand for the 37 optional goods, fund baskets unchanged) deployed to its Workshop folder and MCP-checked. Load still recalculates quotes, so after real turns some price steps differ from their pre-save values. [Appetites](sessions/HANDOFF_20261020_EXCHANGE_RESOURCE_APPETITES.md), [deployment](sessions/HANDOFF_20261020_ECONOMY_CONTENT_AND_EXCHANGE.md).
- Main `e1166d90`: five processing recipes (Printing, Carpet weaving, Brewing extended to Empire and Bretonnia) and six services (Village feasts, Scholars' halls, Factory mess added). Seven native AI payment cases and turns 15 to 17 passed. Same deployment handoff.
- Main `e9d7b2ac`: a Provisions button on the native army action bar for a selected own lord, its badge the army's meal need, click opens that army in the Vault. **Army provisions now default on for new campaigns**; saved campaigns keep their switch, and a saved settings record with no provisions key stays off. [Army-bar handoff](sessions/HANDOFF_20261020_ARMY_BAR_PROVISIONS.md).

## 46. Provision icon and culture coverage, 2026-10-21

- The army-bar button uses its own fork-and-plate icon, `ui/skins/default/derpy_mr_provisions.png`. [Icon handoff](sessions/HANDOFF_20261021_PROVISION_ICON.md).
- Main `2e2b64b1`: Vampire Counts and Vampire Coast keep stores but eat no settlement or army meals. Grain on farm chains and Salted Meat on hunt chains lost their geographic gates; Chaos Dwarfs, Greenskins, Warriors of Chaos, Skaven, Cathay and Norsca get Salted Meat on their primary settlement chains (8/12/16/20/24). An army at sea, or of a faction with no settlements, can Buy field rations at 10 gold each, up to two meals, once per turn; human Auto never buys. Five native cycles passed. [Handoff](sessions/HANDOFF_20261021_PROVISION_COVERAGE.md), [native test](sessions/LIVE_TEST_20261021_PROVISION_COVERAGE.md).

## 47. Essential goods and half-full starting cargo, 2026-10-21

Main `eb1bb41e`, Exchange `0865835e`, both deployed and MCP-verified. Four new goods (Hardtack, processed only; Leather; Cloth; Tools) bring the stores to 58 (41 added). Four new recipes and two new services (Builders' yards, Field hospitals) make nine recipes and eight services. Each newly tracked eligible army gets five meals once, half its ten-meal capacity, with no store or gold debit; a saved force-ID registry stops repeat grants. The Exchange counts a completed Hardtack batch as supply. [Handoff](sessions/HANDOFF_20261021_ESSENTIAL_GOODS.md), [native test](sessions/LIVE_TEST_20261021_ESSENTIAL_GOODS.md). The follow-up [service-label fix](sessions/HANDOFF_20261021_SERVICE_BENEFIT_LABELS.md), main `e75ce0c9`, shows each service's real benefit in the Settlements view. Current rules: [mechanics reference](RESOURCE_OVERHAUL_MECHANICS.md).

## 48. Rome 2 dashes and trade reach, 2026-10-22

The 3D route dots became dashes in the four owner colours (enabled main `FCBC2DCA`). Main `63406BF4`, deployed and tested in game later that day: routes avoid land hostile to either party, and an agreement whose capital-to-capital road is longer than the trade reach (new MCT setting, 6 turns of 40 hexes) or walled off by hostile land moves no goods and no duty, and draws no line; partner contracts are judged on their own road. Native CA trade income is untouched. [Rules](RESOURCE_OVERHAUL_MECHANICS.md#trade-reach-2026-10-22), [handoff](sessions/HANDOFF_20261021_TERRAIN_TRADE_ROUTES.md#update-later-2026-10-22-rome-2-dashes-enemy-land-avoidance-trade-reach).

## 49. Trade route line size and colours, 2026-10-22

Two MCT settings that stay open in a campaign: line size (small, normal, large) and line colours (default, bright, pale, colour-blind friendly). Each combination is its own scene, 579 in all, tinted and scaled in its wrapper over a white 12-direction library. The Vault Map follows the colour set and now draws an agreement on its own trade road. Main `2775CA2F` deployed and tested in game. [Settings](RESOURCE_OVERHAUL_MECHANICS.md#campaign-settings), [current handoff](sessions/HANDOFF_20261022_TRADE_ROUTES_CURRENT.md).

## 50. Traffic on the trade roads, 2026-10-22 to 2026-10-23

Main `3AE6E88B`, in `data/` and `Modpacks/`, no Workshop item. In single player, low-detail rigid vehicles drive the agreement, contract and shipment roads: the supplier's culture picks one of nine land families or 23 ship styles, at most sixteen are in view, and each carries an icon of the good it moves. Import and export carts keep opposite lanes, and every route in view gets a cart before any gets a return cart. Cargo comes from a preview of the real allocator, so a cart shows a good only where that good would move. Nearby roads share corridors on both maps, and roads with the same two ends draw one link carrying all their goods. MCT has five visibility switches for lines and traffic. Reach answers are dropped on war, diplomatic events and region changes. The vehicles are decoration: none moves stock.

Author decisions, 2026-10-23: computer-only pairs stay on the full reach rule, and the shallow-angle fork near Uzkulak is accepted. Open: a wool import switch cleared once around turn 2 of the 20-partner test with no script caller found (live check deferred), the companion campaigns, FPS with sixteen vehicles and two-machine multiplayer. [Current handoff](sessions/HANDOFF_20261022_TRADE_ROUTES_CURRENT.md), [rules](RESOURCE_OVERHAUL_MECHANICS.md#internal-shipments).

## 51. Local prices, 2026-10-24

Main `EEB009EE` (from `3AE6E88B`, by way of `AA6FB586` before the final review's fixes), in `data/` and `Modpacks/`, no Workshop item; only the flows and stores runtimes changed, the other 7,292 files are byte-identical. Every store now prices each good from its own stock: the old category price (or the Exchange's) times 25% to 175%, from turns of cover for a good the settlement uses and from fullness for any other. Prices are whole hundredths of a gold in the save; buyers pay 10% over, sellers get 10% under. Sell takes from the stores with the most to spare first, each at its own price. A partner contract charges each cart, at dispatch, the source store's buy price or what the goods would sell for at the buyer's store, whichever is more, instead of a rate fixed at creation; the second figure closes a loop the final review found (buy a full partner's goods cheap, sell them dear from your own store). Old carts convert on load. Agreement trade draws from the exporter's cheapest store and moves a good only uphill, to a partner capital whose price is at least that store's buy price. The Vault has a Price column with a tooltip, and the Sell tooltip lists the stores it draws from.

Built from the [design](superpowers/specs/2026-10-23-resource-overhaul-local-prices-and-road-trade-design.md) and [plan](superpowers/plans/2026-10-23-resource-overhaul-local-prices.md) in five reviewed tasks. Offline: both harnesses, every economy and route mutant caught, 0 literal-left sites, 22 Vault previews. Checked in game 2026-10-24 on `74088FE5`: the Price cell matches `F.quote`, a sale paid exactly the quoted 104 gold, and 279 agreement moves over four rounds were all uphill ([live check](sessions/LIVE_TEST_20261024_LOCAL_PRICES_AND_CARGO.md)). Import duty, recruitment, the Workshop and provisions are unchanged. Next: agreement cargo on the roads, the second plan. [Rules](RESOURCE_OVERHAUL_MECHANICS.md#local-prices-2026-10-24).

## 52. Agreement cargo on the roads, 2026-10-24

Main `74088FE5` (from `EEB009EE`), in `data/` and `Modpacks/`, no Workshop item; the flows, stores and route runtimes and the MCT settings file changed, the other 7,290 files are byte-identical. An agreement's goods no longer jump to the partner: each turn, what an exporter sends one partner leaves as one convoy on the road the reach check found, at 40 hexes a turn (1 turn up to the trade reach), and lands in the buyer's capital up to its free space. It turns back when the treaty ends or the buyer dies, an army at war with the exporter within 3 hexes of it at the exporter's turn start seizes it, and a dead exporter's convoys vanish. Cargo on the road counts as incoming, so a partner is not sent the same shortfall every turn. Shipments now take their road's length in hexes too; road length counts a sea or river crossing at its whole span. The Trade tab gets a Cargo on the road row, the good drill-down lists convoy cargo, and both maps draw convoy markers (the 3D map only near the camera). The turn shown is when the buyer first has the goods, a turn after the landing for a player buying from a computer.

Built from the [design](superpowers/specs/2026-10-23-resource-overhaul-local-prices-and-road-trade-design.md) and [plan](superpowers/plans/2026-10-23-resource-overhaul-agreement-cargo.md) in six reviewed tasks and a whole-plan review whose seven findings were fixed and re-reviewed. Offline: three harnesses, 219 mutants caught, 0 literal-left sites, 22 Vault previews. Checked in game the same day ([live check](sessions/LIVE_TEST_20261024_LOCAL_PRICES_AND_CARGO.md)): convoys move along their roads, land exactly, one was seized by a parked enemy army, and the convoy list is identical across a save and reload; markers draw on both maps and none through the shroud. Open: a convoy keeps the road it left on, so after a road change its 3D marker can sit off the drawn road (17 hexes once; fixed 2026-11-01, [§58](#58-a-convoy-on-its-pairs-road-of-the-day-2026-11-01)). Agreement trade took 8.4 to 10.6 s a round against 7.6 s, nearly all of it the unchanged reach search. [Rules](RESOURCE_OVERHAUL_MECHANICS.md#cargo-on-the-road-2026-10-24).

## 53. Kept reach answers, 2026-10-29

Main `E452E71B` (from `B05E0CF8`), in `data/` and `Modpacks/`, no Workshop item; only the route runtime changed, the other 7,293 files are byte-identical. The reach search (8.03 s of the computers' 8.40 s of trade in the 10-24 round 6) now runs only when its answer could have moved. No rule, answer or road changes.

- **Kept answers.** `R.reach` files each road's answer (keyed by its two ends and the reach) with the verdict of every region its walled search looked at, and gives it again while every one of them still judges the same (`R.unchanged`). A search is a function of the terrain and those verdicts, so a kept answer is the one a new search would give, and machines agree whatever each has kept. Land changing hands is just a region whose verdict is asked again, so no event has to be heard for it. Not saved: the first round after a load searches everything.
- **The road through hostile land** (the one that only decides "enemy" or "far") depends on terrain alone. It runs, as before, only when the walled search fails, and is kept for the campaign. A pair with no road even through hostile land then answers "far" without a walled search, but only if that search ran to its end: one that stopped at `R.SEARCH_CAP` (200,000 hexes, now a named value) proves nothing.
- **A region is judged once per search** instead of once per hex, so a hex costs 3 game calls instead of 5. This helps every search, including the Vault's and the road bundling's.
- **The open list is a heap in three arrays**, so a push makes no table, and the A* loop reads its fields into locals. It runs the same comparisons, so it pops the same hexes in the same order.

Measured offline with `Modding Files/Backup/reach_memo_20261029/reach_bench.lua`: the real Immortal Empires grid, a stub world of 14-hex regions held by 40 factions, 120 pairs at 240 hexes (28 far, 59 enemy, 33 open), and every game call counted.

| Round | Before | After |
|---|---|---|
| Cold (first after a load) | 9,683 ms, 2,840,726 calls | 7,391 ms, 1,738,252 calls |
| Nothing changed | 7,683 ms, 2,840,726 | 44 ms, 54,782 |
| One war changed | 7,551 ms, 2,829,940 | 120 ms, 90,198 |
| Two regions changed hands | 7,715 ms, 2,832,766 | 80 ms, 73,569 |

Every round's answers, road lengths and mid-road hexes digest-identical to the old code. The harness gained the kept-answer cases (unchanged, war on the detour, peace, another friend, no such region, a shorter reach, a changed map) and a capped-search map. `gen_mr_ui.py --selftest` gained `check_reach_mutations`: 11 mutants, all caught, with every other suite still passing. Luac, API, literal-left and undeclared checks are clean. The pre-change pack and source are in the same backup folder, beside `update_reach_memo.py`.

**In game, 2026-10-29** ([live check](sessions/LIVE_TEST_20261029_REACH_MEMO_AND_DRAG.md)), on the 10-24 fixture:

| Round | Turn handlers | Reach |
|---|---|---|
| First after a load | 6.19 s (was 12.4 to 14.5 s on 10-24) | 3.37 s (was 8.03 s) |
| Next | 4.20 s | 0.94 s |

The player's own turn start fell from 0.68 s to 0.10-0.15 s. All 119 kept answers matched a fresh search, and there were no script errors.

## 54. Map redraw while dragging, 2026-10-29

The author saw a frame skip whenever they dragged the map. The route map's 0.1 s tick ran a full refresh, about 40 ms (27 of them trade previews for the cart goods), on every camera move and every 2.5 s. Now a camera move reuses the last refresh's links, cargo and shared-stretch dedupe, and only places what is near the camera. A road's display positions are converted once, and the timed refresh waits until the camera is still. A camera-move refresh measured 3.3 ms in game, hot-loaded. Harness drag cases and `check_drag_mutations` (6 of 6 caught). Main `7A755835` (from `E452E71B`), in `data/` and `Modpacks/`, no Workshop item; only the route runtime changed, the other 7,293 files are byte-identical. Measured hot-loaded; the packed build has not been run. Update script, pre-change pack and probe in `Modding Files/Backup/drag_refresh_20261029/` (the script is on RPFM 5.3's v2 tools; the v1 names in `update_reach_memo.py` are gone). Open: the full refreshes during the computers' turns (9 to 12 s a round, one per diplomatic event) and the 2.5 s timer's full refresh with a still camera. Both were dealt with in §55. [Live check](sessions/LIVE_TEST_20261029_REACH_MEMO_AND_DRAG.md).

## 55. Route map during the computers' turns, 2026-10-30

Main `B644777C` (from `7A755835`), then `9EBB2731` (the trade-switch fix below, flows runtime only), in `data/` and `Modpacks/`, no Workshop item. Only the flows and route runtimes changed; every other file is byte-identical. No rule, trade answer or road changes. This is display work only.

Every war, diplomatic event and change of hands (`F.invalidate_reach`) used to throw away the map's drawn roads and queue a new search for each one. Each event also forced a full refresh that bundled the whole network again and worked out every cart's goods from trade previews. Now:

- **Kept roads.** `R.path` gives a shown road back unsearched while every region its search looked at still judges the same. This is the `R.reach` proof applied to the map's roads (`R.kept`, checked whenever `R.epoch` moves). A changed road keeps its old line up until the new search lands, and searches under way start again on today's verdicts.
- **Bundling.** The network is bundled again only when a road or a link changes, and at the player's turn (`R.new_turn`). A war that touches only the corridor around a road, and not the road itself, shows from the next turn.
- **Kept previews.** Cart goods previews stay in `R.plans`, and one seller is renewed every `R.PLAN_EVERY` (5) ticks, on ticks that did not refresh. Sellers no longer drawn are dropped.
- **Time budget.** A refresh works out new reach answers for `R.SHOW_BUDGET` (4 ms), and always at least one. Any left over set `R.dirty` for the next tick.
- **Pending answers.** An agreement whose answer is still to be worked out keeps its last line (`R.reach_shown`). This was found in game: every diplomatic event clears the reach answers, the agreements waiting for theirs dropped off the map, and each partial set re-bundled the network, up to 407 ms a refresh.
- **Shared stretches.** A full refresh reuses the last dedupe when `R.network` gives back its cached table.
- **Player actions (`9EBB2731`).** Any action through `F.dispatch` drops the kept previews and redraws on the next tick: trade switches, stock rules, sales and orders. This was found when the author asked about the panel's trade switches: in `B644777C` a re-allowed export took 6.3 s to come back on the carts, waiting for its seller's renewal. The map now follows a switch within 0.1 s, both ways and for the bulk buttons, where the 2.5 s timer used to set the pace.

In game ([live check](sessions/LIVE_TEST_20261030_MAP_COST.md)), on the 10-24 fixture:

| | 10-29 (`7A755835`) | This build |
|---|---|---|
| Route refreshes, computers' turns | 9.4 to 12.3 s a round | 0.74 s (61 full, 45 camera moves) |
| Network rebuilds, computers' turns | one per event | 1 (a link that changed) |
| Whole end of turn | 48.5 / 47.9 s | 33.6 s |
| Still camera, timed full refresh | 37 to 62 ms | 8.6 ms mean, 10 ms worst |

All 131 kept reach answers matched a fresh search, and every drawn line matched its answer. No script errors.

The map's own kept roads were not exercised in game, because the fixture has no contract routes, the only links without a road of their own. The terrain harness covers them. `check_map_cost_mutations`: 21 of 21 caught, with every other suite still passing.

Every switch was checked through the panel's own buttons, and its economic effect one turn later ([live check](sessions/LIVE_TEST_20261030_MAP_COST.md#trade-switches-through-the-panel-second-launch)). `B644777C` and `9EBB2731` were both run packed, the latter for two rounds of a computer-faction census, with no errors. The `F.dispatch` fix itself was measured hot-loaded. The census found that the computer factions eat, pay province supplies, ship, raid and build rare production, but buy nothing from the Workshop and run no processing this early. It also found that half their trade is lost to the 5% share rounding down. None of that changed here; §56 takes up the share and the workshop inputs.

The update scripts, pre-change packs, probe, hot-loads and raw rounds are in two folders:

- `Modding Files/Backup/map_cost_20261029/`
- `Modding Files/Backup/switch_refresh_20261030/`

Still open: the re-bundle at the player's turn start (117 ms) and when a link changes mid-round (100 to 150 ms), and `R.animate` at about 1.7 ms a tick.

## 56. Computer trade and workshop inputs, 2026-10-30

Main `55C56883` (from `9EBB2731`), in `data/` and `Modpacks/`, no Workshop item. Only the flows runtime changed; the other 7,293 files are byte-identical. These are two balance changes the author chose after the §55 census:

- **At least 1.** Agreement trade now sends `F.share(removable, pct)`: 5% of what the store can spare, rounded down, but never less than 1 while it has any to spare. With plain rounding down, 226 of the 441 computer goods with spare stock on open roads moved nothing. The player's exports follow the same rule.
- **Workshop inputs by cart (`F.economy_supply`).** A computer's open processing recipe or service sometimes cannot pay two batches from its own store. If its output is still under target, it gets a cart from the faction's fullest other store, the way army relief ships food. The cart is filled toward ten batches (`F.SHIP.ai_on`). Every short input needs a store that can close its gap or fill a whole cart, or no cart goes, because half a recipe would sit there unused. The routine runs at turn start, after relief and the province supplies, and shares their one-cart limit. The player is never sent one.

Measured in game on the 10-24 fixture, rounds 3 and 4, with nothing forced ([raw rounds](../Modding%20Files/Backup/economy_carts_20261030/census_rounds.txt)):

| | `9EBB2731` | `55C56883` |
|---|---|---|
| Convoys between computer factions, round 3 | 6 | 23 (79 units) |
| Convoys between computer factions, round 4 | 10 (34 units) | 42 (107 units) |
| Computer factions trading, round 3 / 4 | - | 19 / 28 |
| Input carts sent, round 3 / 4 | - | 0 / 0 (0.30 / 0.24 s a round) |
| Computer Workshop purchases | 0 | 0 |

No carts went because, at turn 4, the computers hold almost none of the inputs anywhere. The guard did not block them:

| Input | Shortfalls | No other store holds any |
|---|---|---|
| Cloth | 314 | 258 |
| Medicine | 170 | 168 |
| Tools | 169 | 166 |
| Leather | 161 | 157 |

So this early the cart has little to move. Whether it moves anything later in a campaign is not measured. A soak toward turn 25 for that census reached turn 13 and was stopped at the author's request. It showed no script errors from the mod, only CA's character-initiative listener warnings.

The trade-switch fix from §55 was also clicked on the packed build. Stopping the dragon bone export and allowing it again both reached the map within one 0.1 s sample.

Harness cases cover the share of 1, and the cart in each case where it must not go:
- output not wanted;
- processing off;
- a human faction;
- too little at the source;
- a second cart while one is on the road;
- half a recipe.

They also cover the cases where it must go: a full grain cart lands and the brewery runs, and a turn start sends the cart. `check_economy_mutations`: 41 of 41 caught. The update script, the pre-change pack, the census add-on and the raw rounds are in `Modding Files/Backup/economy_carts_20261030/`.

Still open: the later-game census, which covers carts and Workshop purchases once the computers hold inputs and rare goods.

## 57. The Vault's Production tab, 2026-10-31

Main `7416514A` (from `55C56883`), in `data/` and `Modpacks/`, no Workshop item. Only the stores runtime and `derpy_mr_stores_panel.twui.xml` changed; the other 7,292 files are byte-identical.

A seventh Vault tab lists every processing recipe and service the player's race has, realm-wide. Before this, they showed only inside one settlement's stores. Each recipe is one foldable section with a row per settlement that can run it or still has it ordered. A row shows:

- the settlement;
- what the recipe gives, after its icon;
- each input's amount, red where that settlement cannot spend a batch's worth (`F.economy_view` / `F.available_stock`, so every short input, not only admission's first);
- its state;
- Enable or Pause, through the settlement view's request door.

A recipe nobody can run gets one grey row, whose tooltip names the race's buildings that run it. The settlement view now uses the same state words, so an ordered recipe that is short reads `Short`, not `Paused`.

The write-up is [PRODUCTION_TAB_20261030.md](sessions/PRODUCTION_TAB_20261030.md). Not run in game: tab glyph widths, the red amounts, the Gives icons on screen, and a live Enable/Pause click are open.

## 58. A convoy on its pair's road of the day, 2026-11-01

Main `26E6BB3D` (from `7416514A`), in `data/` and `Modpacks/`, no Workshop item. Only the flows and route runtimes changed; the other 7,292 files are byte-identical. The update script and the pre-change pack are in `Modding Files/Backup/convoy_road_20261101/`.

The 10-24 live check found a convoy that kept the road it left on. The Uzkulak to Conclave road was 171 hexes when `cv_10` left and 142 a turn later, and the convoy's 3D marker sat 17 hexes off the drawn road. The fix applies one rule in two places: a convoy goes the same share of the way along its pair's road of the day.

- **The convoy** (`flows.lua`): `F.convoys_turn` calls `F.convoy_on` at the exporter's turn start, before the army check and the step. The convoy moves onto the open road the reach check gives the two capitals this turn, if that road still leaves the exporter's end. Its due turn does not change. It reads this turn's answer, the one the trade a moment later reads too, so there is usually no extra search, and the answer is the same on every machine.
- **Its marker** (`terrain_routes.lua`, `R.links`): a road can change between those turn starts, for example after a war during the computers' turns. So the 3D map already places the marker where the turn start will move it, on the agreement road it draws for the pair. The spot is kept per convoy until the pair's road, the convoy's own road or its spot changes. Working it out on every refresh cost 21 ms at 100 convoys under `lua.exe`, against a 10 ms refresh.

So an army parked by the marker during the player's turn finds the convoy there at the exporter's turn start. The Vault Map still draws convoys at their saved spot, which its scale hides. Corridor merging can still draw a road's dashes up to six tiles off the reach road.

**Checks:**

- **Flows harness:**
  - a road of the day that bends, taken from either end;
  - an army waiting at the new spot;
  - a cut-off pair, and a road from another start, both keeping the old road.
- **Route harness:**
  - the marker on the pair's road;
  - each of the four things that force a new spot;
  - a convoy bound for the viewer.
- **Mutants:** 8 new convoy mutants (96 of 96 caught) and 6 new map-cost mutants (27 of 27). Each new mutant fails on the assertion written for it.

Not seen in game.

## 59. Spoilage, 2026-11-01

Main `F75B5A2F` (from `26E6BB3D`), in `data/` and `Modpacks/`, no Workshop item. The flows, stores and MCT scripts and four tables changed (the pooled-resource factors, their junctions, the effect bundles and the loc); the other 7,287 files are byte-identical, and the four tables read back from the saved pack with the TSVs' row counts (12, 586, 98, 941). Part A of the [roads, stores and edicts design](superpowers/specs/2026-11-01-resource-overhaul-roads-stores-edicts-design.md), built from [its plan](superpowers/plans/2026-11-01-resource-overhaul-spoilage.md). The update script, the pre-change pack and the census add-on are in `Modding Files/Backup/spoilage_20261101/`.

- **The rule** (`flows.lua`, `F.spoil`): Grain loses 4% a turn and Beer and Kvas 2%, of what a store holds above a safe share of that good's space: 25%, or 50% for Grain once the faction has the Great Granary (`last_granary`). The loss is `floor(exposed * rate / 100)`. The rates and shares are one generated table, `DERPY_MR_FLOWS_SPOIL` (`gen_mr_ui.py` `SPOIL_*`).
- **When:** at the owner's turn start, after `F.provisions_turn` and before the supply carts, processing and trade. The loss books on the new `spoiled` factor (`derpy_mr_spoiled`, a junction per store).
- **Who:** the gates are one function, `F.spoils`: the MCT switch `spoilage` (on; an older save takes it on), "other factions use their stores" for computers, and a culture that keeps stores. Vampire Counts and Vampire Coast eat nothing but still spoil.
- **On screen:** a spoiling good's row in the settlement view says "Grain spoils 4% a turn above 250 held: about 6 next turn." (`F.spoil_info`, `S.spoil_sentence`); the forecast line adds "N spoils/turn" and takes it off the net, but not the cover or the stable/declining verdict, since it stops at the safe share; each good's Last turn line adds "spoiled -N". That line now drops its last parts and ends ", ..." rather than run past the chart line, which every part at once did.
- **Two calls against the design** (plan, "Where this plan differs"): the tooltip gives next turn's loss, not last turn's, because the ledger is per faction and good; and Spoiled shows per good, not as one total.

**Checks:**

- **Flows harness:** the loss at 400, 275, 274 and exactly 250 of 1,000; grain and beer spoiling and salt not; the Granary keeping grain and not beer; asking about the Granary writing nothing to the save; the switch, the computer switch, Daemons, Vampire Counts and a store with no grain pool; an older save; the turn-start order; next turn's loss, the forecast's cover and its line. The older blocks run with spoilage off (`F.spoils` stubbed), since their stock figures predate it.
- **Stores harness:** the Last turn part, a line of every part fitting with ", ...", the sentence with and without a loss due, and the settlement row carrying it.
- **Mutants:** `check_spoil_mutations`, 18 of 18 caught; `gen_mr_ui.py --selftest` 317 of 317.
- **Final review** (a fresh reviewer): the forecast had counted spoilage as a use, which showed a countdown on every full granary although spoiling stops at the safe share; it now comes off the net only. And `F.spoil` read every pool in every store of every faction to use three; it now reads the three spoiling pools (`F.pool`) and asks the gates once a faction. Both fixed test-first, with a mutant each.
- **Wording pass** (asked the same day, checked against antislop's copy rules): "for good" is gone from player text. The five permanent Workshop works read "Growth +15 Permanent" and so on, their tooltips and bundle descriptions end "Permanent.", the eight settlement upgrades' tooltips too, and the section is "Permanent works" (was "Works that last"). The Great Granary says grain is safe from spoiling up to half of each store, and the MCT tooltips for "Settlements use their stores" and "Other factions use their stores" say how spoilage follows them.

Not seen in game.

## 60. Faction-specific buffs, 2026-11-01

Main `D36973FE` (from `F75B5A2F`), replaced the same day by `4542C652` (control in place of CA's Labour-loss effect, below) and then by `B633A2AC` (§61). The flows and stores scripts and seven tables plus the loc changed (payload UI details, the three dilemma choice/option/payload tables, dilemmas, effect bundles and their effects); the other 7,284 files are byte-identical, and every table reads back from the saved pack with the TSVs' row counts. The update script and the pre-change pack are in `Modding Files/Backup/faction_buffs_20261101/`.

The author: "are the effects faction appropriate? e.g growth doesnt do anything for the chaos dwarf", then "should be faction specific buffs". Every Workshop work was offered to `("all",)`, and nothing checked an effect against the races it reached.

- **The rule** (`gen_resource_overhaul.check_reach`, called from `check_works`): each race a work, upgrade, stores bonus, service, event, order or supply reaches must get at least one working effect from it, and no Chaos Dwarf row may carry growth. "Working" is read from CA's tables: growth is dead for `NO_GROWTH` (the Chaos Dwarfs: the author's rule, and not one of their vanilla buildings grants growth, where every other settled race has 3 to 86 rows), trade income for the cultures in `factions_without_trade` (Greenskins, of our 17), and a unit-set effect for a race with no recruitable unit in the set (`unit_set_to_unit_junctions` matched on caste, category, class and record, excludes honoured). Research and upkeep reach all 17. A row of two effects may serve some races with one and others with the other (a supply).
- **What it found:** Great Granary (CHD), Grand Bazaar (Greenskins), Royal Stables (Dwarfs, Skaven, Vampire Coast), Well fed (CHD), the Feast's growth (CHD), and Stable stocked (Dwarfs, Vampire Coast). Arms stocked passes: its artillery half does nothing for six races, but its infantry half reaches all of them.
- **The fix, by the race's own work** (`not_races` on the general one, `F.work_open`): Chaos Dwarf Great Granary, Labour gained after battles +15% (CA's `wh3_dlc23_effect_force_chd_campaign_post_battle_labour` at `faction_to_force_own` 15, as its own camp bundle), keeping the grain half (`F.SPOIL.granary_works` lists both granaries); Greenskin Loot Hoard, sacking and looting income +15%; Dwarf Engineers' Yard, artillery -20%; Skaven Beast Pens and Vampire Coast Bone Yard, monsters -20% (`wh3_main_effect_recruitment_cost_def_monsters`, whose set is caste-wide despite the key).
- **Stores and events:** `RACE_USE_BUNDLES` gives a race its own bundle for a use; `F.bundle` puts on the owner's and takes off any other of the family, so a captured settlement drops its former owner's. The Chaos Dwarfs' Well fed is public order +3 in the province. The Feast is `not_races` CHD and `feast_chd`, "Full Rations", takes its place in `F.EVENT_ORDER` with its own words: public order +10 for 5 turns. `D36973FE` gave Labour loss -3 and -5 instead, on `wh3_dlc23_pooled_resource_chd_increased_labour_loss`. That effect is a display dummy: CA's `wh3_dlc23_labour_loss.lua` takes 3% of a province's Labour a turn at control 50 and up and 5 to 20% below it, so control is the lever. `4542C652` swapped both to control, and the generator selftest refuses the dummy effect.
- **Stable stocked** now carries CA's caste-wide monster effect in place of the Lizardmen one, whose set reached eight races and not Vampire Coast, plus gyrocopters for the Dwarfs: "recruit cost -15% for cavalry, monsters and gyrocopters".
- **Wording:** the Dwarf work's short line is "Artillery -20% Permanent": "Artillery cost -20% Permanent" is 203 px in the 200 px Gives column (`check_layout`). A bundle description keeps "Labour" capitalised, as CA writes it.

**Checks:** `check_reach` in `check_works`; the generator selftest breaks it six ways (the Granary's `not_races`, the Stables' Skaven, the Chaos Dwarf Granary for all, the Feast's `not_races`, no race bundle, a supply's second effect). Flows harness: the works per race, the Chaos Dwarf Granary keeping grain, Well fed swapped both ways on capture, Full Rations offered and in the turn's order, the Feast not offered to Chaos Dwarfs. `check_race_mutations` 7 of 7; `gen_mr_ui.py --selftest` 324 of 324; no duplicate keys (`check_keys`). An old save that bought the general work keeps its bundle, and can buy its race's own as well.

Seen in game on `4542C652` (2026-11-01): the Chaos Dwarf Great Granary (bought, its bundle, grain safe to half a store), Well fed swapped on a Chaos Dwarf settlement, Full Rations, the four other races' own works and bundles, and Stable stocked's effects. Not seen: the Battle Labour figure after a battle.

## 61. The Vault's wording and the turn-end close, 2026-11-01

Main `B633A2AC` (from `F75B5A2F`, in place of `4542C652`), in `data/` and `Modpacks/`, no Workshop item. The same ten files as §60 changed (the flows and stores scripts, seven tables and the loc); the other 7,284 are byte-identical, and every table reads back from the saved pack with the TSVs' row counts. Built by `Modding Files/Backup/faction_buffs_20261101/update_faction_buffs.py`.

- **The panel closes at turn end.** The author: "panel should close after ending turn". A `FactionTurnEnd` listener for the local faction calls `S.show(false)` while the Vault is open. It is a UI change on the ender's own machine only. The stores harness ends a turn with the panel open, and `check_turn_end_mutations` breaks the listener two ways.
- **The wording.** The author called the tooltips "so long, garbled and have AI slop plastered wording", rejected "Alpha has 3 Iron to spend; a batch takes 6." as more of the same, and then asked to remove the "apostrophes" in "Workshops make new resources, and services spend them for a bonus." The author's apostrophe is the comma. Every player string in `stores_panel.lua` and `flows.lua` is now one short sentence a line. No comma joins two clauses, and there are no semicolons, stat shorthand or clipped fragments. A list keeps its commas ("40 Coal, 12 Iron").
- **What that changed in shape:** the forecast tooltip covers the category under the mouse, with a line each for what the store holds, what it makes and uses, what spoils and how long it lasts. The price tooltip is three lines ("The price is 0.75 instead of 3.00." / "It is cheap because ..." / "You buy for ... and sell for ..."). The map cart reads "40 Coal, 12 Iron from Bravo to Alpha." then "It arrives on turn 14." The trade cells read "sent 15 and received 2" and "2 out and 1 in".
- **The Workshop's own texts** (`gen_resource_overhaul.WORK_RECIPES`, `WORK_UPGRADES`, `_work`) feed the Gives cell, the work tooltip and the bundle loc: "Ammunition +20% (5 turns)", "Unit (2 at most)", "Leadership +4 (movement -5%)", "once a turn" with no comma. Parentheses and not "for", because "Replenishment +10% for 5 turns" is 210 px in the 200 px Gives column. `check_layout` now measures every work's Gives, which nothing did before.

**Checks:** both harnesses; `gen_mr_ui.py --selftest` 326 of 326; `test_service_labels`'s stub `S` gained `join`, which the Production rows call since the rewrite; two mutation anchors still quoted the old wording (the cargo line's turn and the seller's pool reason) and now quote the new. Not seen in game: the close and the new wording are on `B633A2AC`, and the in-game pass was on `4542C652`.

Not done: the loc outside the panel (dilemma and event texts, bundle descriptions, the MCT page) still has clause commas.

## 62. The Vault's panel size, 2026-11-02

Main `10D516E3` (from `B633A2AC`), in `data/` and `Modpacks/`, no Workshop item. Built by `Modding Files/Backup/ui_size_20261102/update_ui_size.py`: the stores script and the MCT file changed and 52 panel files were added; the other files are byte-identical.

- **What.** The author: "implement UI size options, same as the derpy great guilds mod small medium large". MCT, section **Display**, dropdown **Panel size** (`ui_size`): Small (6/7), Medium, Large (4/3). Display only, so it is never locked or frozen into the save, and `set_is_global` keeps it each player's own in multiplayer. The panel reads it on every open.
- **How, as the Great Guilds does it.** A font cannot be changed at runtime, so each size is its own set of `.twui.xml` (`_sm`, `_lg`), built by `gen_mr_ui.sized()` from the Medium tree: every length scaled, every font one step along CA's body list (Small: body_12 to body_10, body_16 to body_12; Large: body_10 to body_12, body_12 to body_16). The HUD opener has one file at every size. The generator also emits `DERPY_MR_STORES_SIZES`: each size's factor, suffix and the whole layout table `L` at that size. `S.use_size` points `L` at it before the panel is built, so the ~100 `MoveTo` sites needed no edit; the six literal lengths outside `L` go through `S.px`. A size change destroys the panel and builds it again from the new files.
- **The screen factor** is spent on the same choice (`S.pick_size`, the Guilds' `GGUI.pick_size`): the file set nearest the size asked for times the screen past 1920x1080, among those that fit. At 1440p Small draws Medium's files and Medium draws Large's. Large is 1147x853 and fits the engine's 1600x900 floor.
- **The map's names stay body_10 at Small**, as there is no smaller body font. Their box is sized to the measured name (`S.map_names`), so `check_sizes` allows that one step and asserts the map's names are the only body_10 text.
- **What does not scale** (`gen_mr_ui.UNSCALED`): counts, ratios, map units and `MAP_FRAME_OUT`. That one is pixels of CA's border art, and a 9-slice draws its edges at the art's own size in any box, so the copper line starts 4px in at every size. Scaled to 3 at Small, it showed the map past the line in the first preview (the 2026-10-04 in-game bug again).

**Checks:** the stores harness opens the Vault at all three sizes through a stubbed MCT and checks the file set, panel size, centring, row pitch, a cell's offset, the list height, that the old panel is gone and that the opener keeps its place; `check_sizes` (font steps, every panel file created with the suffix and the opener without it); `check_size_mutations` breaks it four ways; `gen_mr_ui.py --selftest` 330 of 330. `preview_resource_vault.py` draws the list and the map at Small and Large (`size_small`, `size_large`, `_map`). Not seen in game.

## 63. Trade edicts, 2026-11-02

Part B of the [roads, stores and edicts design](superpowers/specs/2026-11-01-resource-overhaul-roads-stores-edicts-design.md), built from [its plan](superpowers/plans/2026-11-02-resource-overhaul-edicts.md) for Resource Overhaul 1.0. Shipped in the 1.0 pack, `6A09F34C` ([§67](#67-version-10-2026-11-02)). The ledger with every ruling is `.superpowers/sdd/resource-overhaul-v1/progress.md`.

- **The rule.** Three edicts, each with three options and one in force: Rations (Plenty, Normal, Rationing), Workshops (War economy, Balanced, Merchant), Roads (Open, Tolled, Closed). The middle option is the default and changes nothing. A change is a player action through `F.request` (`edict`), then that edict waits 10 turns. Saved as `F.state.edicts[faction][edict] = {o, at}`; `F.sanitize_edicts` keeps only known edicts and options on load. MCT switch **Trade edicts** (`edicts`, on), its own and not the Vault actions switch.
- **The numbers** (one generated table, `DERPY_MR_FLOWS_EDICTS`): meals 3, 2 and 1 per level; War economy makes 150% of a Blackpowder, Tools or Leather batch, rounded down; Merchant doubles the MCT trade share and raises the recruitment draw to 125%. Faction bundles carry the rest: Plenty +10 growth (`derpy_mr_edict_plenty`, Chaos Dwarfs +2 control instead, `_chd`), Rationing -2 control, War economy -10% trade income, Open +5% trade income, Closed +1 control. Merchant has no bundle, as nothing it does is an effect.
- **Closed roads** are a verdict in `R.hostile`: an owner whose Roads edict is Closed is hostile land to every road but its own. A Roads change calls `F.invalidate_reach`.
- **Computer factions** choose at their turn start, before the meals (`F.edict_turn` ahead of `F.convoys_turn`), under the same cooldown and the "other factions use their stores" switch: Rationing below 2 turns of realm food at Normal, Plenty above 15; War economy at war with the owner of a region next to theirs, Merchant with three or more partners and no war, else Balanced; Closed at war with two or more neighbours, else Tolled. Rebels never count. A human's turn start puts its bundles on, so an older save catches up.
- **On screen:** an Edicts section at the top of the Resources tab, briefed against CA's Commandments list: a beige "Edicts" section row, the three edicts with "Ready" or "Wait N turns" in column 2 and their options as buttons in columns 3 to 5, then a "Resources" section row above the goods. The option in force glows (`glow_pulse_t0`), a waiting edict's other options are greyed, and every option's tooltip lists its exact effects ("This edict can change again in N turns." while it waits).

**Calls against the plan** (each in the ledger): Vampire Counts and Vampire Coast, who eat nothing from the stores, have no Rations row and `F.edict_set` refuses their Rations, since Plenty would be growth for nothing. Goods column 2 is 96 px, not 90, because "Wait 10 turns" is 91 px; columns 3 to 5 moved 6 px. The edict button is 100 px, not 96, because the button art shows about 83% of its box. The section shows only when the faction holds a settlement. The upkeep test "switched on, they eat" now expects 47: 50 grain is 25 turns of food, so the computer eats at Plenty.

**Checks:** flows harness (the edict state, cooldown, race bundle, refusals, action gate, load and old save; meals 94/98/96, the war output, the Production tab's figure, the Merchant share and draw; every computer rule, the cooldown, a faction with no regions, a neighbour with two regions next door, rebels, the turn order, a non-eater); stores harness (the five rows, the labels, the glow, a waiting edict, the Chaos Dwarf tip, the click and the refused clicks, a pooled row's buttons sized back, no Rations row for a non-eater, the switch off); terrain harness (Closed hostile, a party not). `check_edict_mutations` 26 of 26. `check_layout` asserts the labels, buttons and wait at all three sizes. `gen_mr_ui.py --selftest` without its older mutation suites passes; those run once before the 1.0 pack, and every one of their anchors was checked fresh (two had moved with Task 3 and were updated). `check_lua_api`: the two findings it reports were there before. `check_lua_literal_left` 0, `check_lua_undeclared` 0. `check_effect_signs` and `check_effect_bundle_loc` read a pack, so they run on the 1.0 pack; `gen_resource_overhaul.py --check` already holds the edict bundles' signs (the two penalties are listed) and loc. The previews (`mr_goods`, `mr_size_small`, `mr_size_large`) draw no shaders, so the glow and the grey are unseen.

**Seen in game** on `2D334371` ([the live pass](sessions/LIVE_TEST_20261102_V1.md)): the author changed all three edicts from the panel, and computer factions chose theirs at 145 to 167 ms a round, over the plan's 10 ms (a budget set without measuring one store read; ruled, see the ledger). The rebel faction's Rations read crashed the rule once a round (`factions_trading_with()` is `false` for the rebels) and Rationing reached Well fed on half the food; both are fixed in `6A09F34C` ([§67](#67-version-10-2026-11-02)).

## 64. Tolls and blockades, 2026-11-02

Part C of the [roads, stores and edicts design](superpowers/specs/2026-11-01-resource-overhaul-roads-stores-edicts-design.md), built from [its plan](superpowers/plans/2026-11-02-resource-overhaul-tolls-blockades.md) for Resource Overhaul 1.0. Shipped in the 1.0 pack, `6A09F34C` ([§67](#67-version-10-2026-11-02)). The ledger with every ruling is `.superpowers/sdd/resource-overhaul-v1/progress.md`. The player-facing rules are in [RESOURCE_OVERHAUL_MECHANICS.md](RESOURCE_OVERHAUL_MECHANICS.md#tolls-and-blockades-2026-11-02).

- **The road's regions.** `F.road_regions(path)` reads the region under each point of a road once (`get_region_at_logical_position`) and keeps the list against that road table in `F.road_known`, which has weak keys: a road is replaced, never edited, so a new route is a new key. Owners are read live.
- **Who takes a toll.** `F.toll_takers(a, b, path)`: each owner once, in road order, leaving out the two parties, rebels, an owner whose Roads edict is Open, and an ally, vassal or client state either way round (`is_ally_vassal_or_client_state_of`, asked both ways). A Closed owner is never crossed, as `R.hostile` already routes around it.
- **How much.** `F.toll_pct(n) = min(rate * n, 15)` and each taker gets `floor(value * pct / (n * 100))`, so the 15% is a limit on the total, split evenly and rounded down. Six takers at 3% on 1000 gold pay 25 each. `F.toll_unit(price, n)` is the per-unit form the uphill test adds. `F.pay_tolls(payer, due)` pays all or nothing, in key order, and books both sides (`F.book_toll`, `F.tolls_last`), the duty book's shape: `F.book_duty` and `F.book_toll` now share `F.book_gold(field, ...)`.
- **Agreement trade.** `F.trade` is a sorted loop over partners calling `F.trade_pair(exporter, partner, sources, preview, opts)`, which returns `(stems, sources)`. Order inside a pair: reach, then the blockade, then the plan (uphill now `pd >= buy + toll per unit`), then the tolls on the plan. A plan whose tolls the exporter cannot pay is undone. The real trade sends, then charges the tolls on what the convoy actually carries (`F.cargo_value(convoy.basket, prices)`) and saves them on the convoy (`convoy.tolls`).
- **Contract carts.** `F.ship` prices the toll at the seller's local sell price and refuses a cart whose escrow plus toll is more than the buyer holds. The buyer pays, and the cart keeps `s.tolls`. Internal shipments pay none.
- **Blockades.** `F.blockade(a, b, path)`: off with the switch; the road's bounding box widened by `F.SHIP.near` (3) turns most armies away, then `dx*dx + dy*dy <= near*near` against each point, over `F.enemy_armies(a)` then `(b)`. The real trade records the blocker (`F.record_blockade`, per pair either way round, not saved); `F.blockaded(a, b)` answers for this turn or last. The duty reads it (a blockaded pair pays 0), `F.cut_off` lists the pair with `by`, `R.links` draws no line, and a contract cart returns `nil, "blockaded"`, which `routes_turn` shows as the status "Blockaded".
- **On screen.** Trade tab rows Tolls paid and Tolls received under Import duty, last turn's gold, shown above 0 or while tolls are on and the player has a partner; the tooltip has a line per faction. A cargo's tooltip adds "Tolls: 30 to Name, 12 to Name." The Trade cut off tip gives "Blockaded by Name".
- **Saved.** `convoy.tolls` and `s.tolls`, checked on load by `F.tolls_sound` (in `F.convoy_sound` and `F.sanitize_ships`). MCT: the **Tolls** slider (`toll`, 0 to 10, default 3) and the **Tolls and blockades** switch (`tolls`, on, under the stores section). An older save gets both on.

**Calls against the plan** (each in the ledger): the preview counts the tolls the round's earlier partners would have paid (`sources.toll_spent`), since a preview pays nothing and a later partner looked affordable, so the map drew a line the trade would not send. The older flows harness blocks run with the toll-takers stubbed empty, as spoilage does, since their gold figures predate tolls. The slider's tooltip and the cut-off heading are each split into two sentences, the author's rule. The record of a blockade is its own setter, called only by a real trade.

**Checks:** flows harness (the takers, the six-taker split, an ally, a vassal, a rebel, Open roads, a taker crossed twice; the trade with one and two partners, exactly enough gold for one, the preview against the real trade, the cart paid by the buyer, a convoy's and a cart's bad tolls on load; the blockade at 3 hexes and not at 4, an army off the road's corner, a neutral army, no road, the duty, the cut-off list, the contract status, cargo already on the road, the switch off); stores harness (the toll rows, their tooltips, the cargo tip, "Blockaded by"); terrain harness (a blockaded agreement draws no line). `check_toll_mutations` 14 of 14, `check_blockade_mutations` 13 of 13. The radius mutant first survived: the widened box turned away the 4-hex army before the distance test ran, so a corner case was added. `check_lua_api`: the same two findings as before. `check_lua_literal_left` 0, `check_lua_undeclared` 0 over the five scripts and the hub. The turn-time budget (200 ms a computer round) is measured at the live pass.

**Seen in game** on `2D334371` ([the live pass](sessions/LIVE_TEST_20261102_V1.md)): tolls paid and blockades recorded, 148 ms a computer round against the 200 ms budget. The enemy list's kept interfaces crashed `9CE23CAA` ([§67](#67-version-10-2026-11-02)).

## 65. Bandits on the roads, 2026-11-02

Part D of the [roads, stores and edicts design](superpowers/specs/2026-11-01-resource-overhaul-roads-stores-edicts-design.md), built from [its plan](superpowers/plans/2026-11-02-resource-overhaul-bandits-guards.md) for Resource Overhaul 1.0. Shipped in the 1.0 pack, `6A09F34C` ([§67](#67-version-10-2026-11-02)). The ledger with every ruling is `.superpowers/sdd/resource-overhaul-v1/progress.md`. The player-facing rules are in [RESOURCE_OVERHAUL_MECHANICS.md](RESOURCE_OVERHAUL_MECHANICS.md#bandits-on-the-roads-2026-11-02).

- **The hooks.** `F.road_event(faction, kind, rec, from_xy)` runs once per cargo per turn, after it moves: in `convoys_turn` after `F.convoy_step`, and in `ships_turn` after `F.ship_step` when the cart is still on the road. Off with the **Bandits on the roads** switch (`bandits`) or a **Road danger** (`road_danger`) of 0, and then nothing is computed or recorded.
- **The stretch and its threat.** `F.stretch(road, from_xy, to_xy)` reads the region under each point the cargo covered this turn, each region once, or the destination's region alone when either point is off the road. It keeps no cache: a convoy's road is unpacked into a new table every turn, so a cache keyed on it would never hit (a ponytail note names the upgrade). `F.threat(keys)` asks CA's `caravans_system():total_banditry_for_regions_by_key(keys)` in a `pcall` and uses `min(100, floor(v / #keys))` when above 0. Otherwise it averages `F.wild(region)`: 100 for abandoned, unowned or rebel land, else `max(0, min(100, max(corruption, -public_order)))`. The cargo keeps it as `rec.threat`.
- **The roll.** `F.road_roll(fkey, threat, guarded, land)`: trouble when `cm:random_number(10000, 1) <= threat * danger * (guarded and 50 or 100) / 100`. The open encounters are the ones off their 5-turn cooldown (`turn - cool[e] > 5`), less the ambush below threat 30 and the washout at sea. One is picked with `cm:random_number(#open, 1)` and its turn saved in `F.state.road_cool[faction][encounter]`. Before the roll, `F.patrol(owner, buyer, x, y)` lets a cargo pass when either side's army (not a garrison) is within `F.SHIP.near` (3), and `F.state.road_safe[faction] >= turn` lets it pass too (Part E writes that one).
- **The other choice.** `F.road_settle(faction, kind, rec, key)` is how every encounter ends that no dilemma or battle settles: the washout waits (`F.cargo_wait`, `due + 1`), the highwaymen take `min(floor(value * 20 / 100), max(0, treasury))`, and the ambush takes half (`F.cargo_lose`, rounded down per good; an emptied cargo is dropped). The value is `F.cargo_value_base`, the base price, not a local one. A human buyer robbed on a computer's convoy gets `show_message_event` with the three `derpy_mr_road_loss` strings.
- **A player's encounter.** A human in single player gets `F.road_offer`, which follows CA's `caravans:attach_battle_to_dilemma`. For an encounter that can come to a fight (`F.ROAD_FIGHT`: the ambush on FIRST, the highwaymen on SECOND) the bandits spawn first (`F.bandit_spawn`): the qb faction of the region owner's subculture (`DERPY_MR_FLOWS_BANDIT_QB`, each subculture's first `_qb1` key by name), else the Ogre Kingdoms' (`ROAD_QB_SC`), with 5, 8 or 10 units off that subculture's escort template by threat. Spawning follows CA's caravan steps (feed events muted, `force_declare_war`, `disable_movement_for_character`, `set_force_has_retreated_this_turn`). Then `trigger_dilemma_with_targets` passes the bandit force and the region. One encounter waits per faction, saved as a pending entry. A refused offer (one already waiting, no spawn point, or a dilemma the game would not show) settles the cargo instead.
- **The answer and the battle.** `F.road_answer`: the fighting choice calls `F.road_fight`, which needs `F.fight_free()` (the one battle slot that escort battles also use) and a live bandit force. It rolls the guard army off the player's escort template (`F.roll_units`, escort power for the turn, `F.escort_size` of the cargo), saves `F.state.fight` with `side = "bandit"`, mutes the character feed, locks retreat and starts the battle through `Forced_Battle_Manager` with the bandits attacking. `F.bandit_done` loses the whole cargo when the attacker won, then kills the bandits and unlocks retreat. Any other answer, or a battle that cannot start, kills the bandits and settles; Push on loses 10%. `fight_clear` and `fight_stale` clean up a battle or an answer left over from an earlier turn.
- **Guards.** `F.guards_on(fkey)`: a human's `F.state.guards[fkey]` (the Trade tab's Hire and Dismiss, action `guards`, gated by the bandits switch), a computer's `F.state.road_seen[fkey] >= turn - 1` (set whenever a stretch's threat is 30 or more). `F.guard_fee(payer, rec)` takes 5% of `F.cargo_value_base` as the cargo leaves, right after its tolls, in `F.trade_pair` and `F.ship`, and marks `rec.guarded`. A fee the treasury cannot cover leaves the cargo unguarded. `F.sanitize_road` cleans `road_cool`, `guards` and `road_seen` on load.
- **On screen.** A Road guards row on the Trade tab under Cargo on the road, while the bandits are on and the faction uses its stores: On or Off, a Hire or Dismiss button, CA's sword attribute icon, and a three-line tip. Three dilemmas, `road_ambush`, `road_highwaymen` and `road_washout`, with `all/ivory_road` and a per-dilemma `cost_icon`.
- **The fallback.** `F.ROAD_BATTLES = true`. Set false, only the washout still asks a player and the other two are settled. That is the switch for a live pass that finds the bandit battle broken.

**Calls against the plan** (each in the ledger): the switch is checked before anything is recorded. Guards need the bandits switch, not the Vault actions switch. The guards fee is 5% of the base value for every kind of cargo, since an internal shipment has no local price. A Part C regression was fixed: an exporter in debt was refused every partner even with no toll due. The washout's Wait line was reordered so the cost half reads as the cost. All three dilemmas use `all/ivory_road`, the only road picture `check_dilemmas` accepts. `F.fight_free` was split out of `F.fight_ready` so a bandit battle does not depend on the Escort battles switch. `F.roll_units` was extracted, and `F.escort_size` now counts a convoy's basket. `F.bandit_kill` always re-enables the feed. A cart-hook test was added. The guards icon is the sword, as the shield drew as a blank disc.

**Checks:** flows harness (the stretch, the wild rule, CA's figure and its fallbacks, the roll, guards, eligibility, the cooldown, patrols, the bandit factions; ambush, highwaymen and washout for a computer, the import message, an empty treasury, losses per good, an emptied basket, a shipment, the convoy hook, an arriving convoy, safe land, sea, the fee on a convoy and a cart, unaffordable guards, load; the player's offer, the battle won and lost, a decline, a stale pending encounter, one pending at a time, a second battle that cannot start, no spot for the bandits, the cart hook); stores harness (the guards row off and on, Hire and Dismiss, no row with the bandits off); terrain harness. `check_road_mutations` 25 of 25: the plan's 16 and nine more. `gen_resource_overhaul.py --check` passes `check_dilemmas` with the three road dilemmas. `check_lua_api` reports four, the same call as before: `override("retreat")` is in CA's lib (`lib_campaign_ui_overrides.lua:3901`), not its docs, and CA's caravans call it the same way. `check_lua_literal_left` 0, `check_lua_undeclared` 0 over the five scripts and the hub.

**For the live pass** (Part E's last task, on the minimal mod list with the player shield): read `total_banditry_for_regions_by_key` for a region off CA's caravan networks and one on them, and record both. Force an ambush on a player convoy (`F.road_roll` stubbed through `wh3_eval` to return "ambush" once) and answer FIRST: the battle starts, both forces are gone afterwards, next turn's upkeep holds no guard army, and the feed holds no war or destroyed message for the bandit faction. Answer a second ambush SECOND: the bandit force is gone the same turn. If either fails, set `F.ROAD_BATTLES = false`, rebuild, and record why.

**Seen in game** on `2D334371` ([the live pass](sessions/LIVE_TEST_20261102_V1.md)): the forced ambush answered FIRST was fought and won, and the bandits and the pending answer were gone afterwards; one answered SECOND halved the cargo and its bandits were gone the same turn. A real highwaymen roll on a player shipment was paid off for a fifth of its value. `F.ROAD_BATTLES` stays true. 32 ms a computer round against the 50 ms budget.

## 66. Store events, 2026-11-02

Part E of the [roads, stores and edicts design](superpowers/specs/2026-11-01-resource-overhaul-roads-stores-edicts-design.md), built from [its plan](superpowers/plans/2026-11-02-resource-overhaul-store-events-v1.md). Shipped in the 1.0 pack, `6A09F34C` ([§67](#67-version-10-2026-11-02)). The ledger with every ruling is `.superpowers/sdd/resource-overhaul-v1/progress.md`. The player-facing rules are in [RESOURCE_OVERHAUL_MECHANICS.md](RESOURCE_OVERHAUL_MECHANICS.md#scripted-opportunities).

- **The rows.** Six `gen_resource_overhaul.EVENTS` entries, each with `needs` (the switches of the parts it reads) and `human` (players only), emitted into `DERPY_MR_FLOWS_EVENTS`. `F.event_gated(faction, e)` is false when a needed switch is off or a players-only event meets a computer, and `F.event_offer` asks it beside `F.work_open`. `F.EVENT_ORDER` gains the six after `tribute`. One region bundle, `derpy_mr_event_smugglers` (control -3 for 5 turns, in `PENALTIES`). Pictures: `messenger`, `faction`, `civilisation_down`, `all/ivory_road` (twice) and `diplomacy`, each looked at in its Empire version.
- **Own offers and applies.** Each new event is offered by `F.EVENT_OFFERS[key](faction, stocks)` and settled by `F.EVENT_APPLY[key](faction, p, choice)`. `F.event_apply` now takes the choice; the older events still act on FIRST only, and both computer branches pass "FIRST". The store rule refuses an event of cost 0, since it would offer one at every store.
- **Smugglers** (`F.smuggle_offer`): provisions across every store by key first, then war materials, from `F.recurring_use` (meals, army food, supplies, named orders); short is `held < per * 2`. `n = min(100, per * 5 - held)` of the cheapest good of that use the store can hold (ties by stem), at `ceil(n * buy * 150 / PCT^2)` off `F.quote`. The answer prices again for what fits.
- **Merchant guild** (`F.guild_offer`): the common good with the highest realm fill above 75% (cross-multiplied, ties by stem). FIRST saves `F.state.sales[faction] = {stem, per = 20, left = 10}`. `F.sales_turn` runs right after `F.duty`: it quotes the fullest store, draws through `F.draw_realm` (`KIND.sell`), pays `F.gold(sold, floor(sell * 120 / 100))`, and ends after its turns or the first turn it sells fewer than 20. `F.sanitize_sales` drops an unknown, rare, broken or finished sale on load.
- **Grain rot** (`F.rot_offer`, only while `F.spoils`): the first store by key 100 or more above `floor(cap * F.spoil_safe / 100)`. FIRST pays 50 when held and loses 5%, SECOND loses 30%, both of what is there at the answer, booked as `KIND.spoil`.
- **Caravan master** (`F.caravan_offer`): any convoy or shipment of the faction at `threat >= F.ROAD.ambush_min`. FIRST pays `floor(value * 5 / 100)` of all its cargo (`F.cargo_value_base`) when held, then `F.state.road_safe[faction] = turn + 10`, which `F.road_event` reads; `F.sanitize_road` now cleans it too.
- **Toll dispute** (`F.toll_offer`): the first faction by key in last turn's tolls book with `got >= 50`. FIRST is `F.edict_set(faction, "roads", "open", true)` and `F.DIPLO_BONUS`, SECOND `-F.DIPLO_BONUS`.
- **Blockade runner** (`F.runner_offer`): the first partner by key whose `F.blockade_known` entry is this turn's. FIRST runs `F.trade_pair(..., {blockade_ok = true})` once a turn, guarded by a saved convoy to that partner with `at == turn` rather than the unsaved blockade record, and pays a tenth of what left when the treasury holds it.

**Calls against the plan** (each in the ledger): food is looked for before war materials across all stores. Without the Exchange every food has one price, so Smugglers buys the first by name, beer where a store holds it. A sale ends the first turn it cannot fill its 20, which is what the plan's own test expects. Caravan master does nothing unpaid. The runner's guard is the saved convoy. Toll dispute moves regard even if the roads were already Open.

**Checks:** flows harness (the six rows and gates, an old save's book; Smugglers' 17, 2 turns not short, the 100 limit, an unaffordable offer, the dilemma and the answer; the guild at 80% and not at 70%, three turns of sales, a sale running out, ending after its turns, its stores captured, a bad saved sale; Grain rot at 400 and not 349, both choices, an emptied store, 49 gold, spoilage off; a computer taking Smugglers and the guild and never offered Grain rot; Caravan master at 29 and 40, the 10th and 11th turns, no gold, the saved safe turn; Toll dispute at 49 and 50, the forced Open during a wait and both signs; Blockade runner offered, sending once a turn, the army gone before the answer, last turn's blockade). `check_event_mutations` 17 of 17: the plan's 12 and five more. The guild's 50% mutant would have survived the plan's tests, so the 70% case was added.

**Seen in game** on `2D334371` ([the live pass](sessions/LIVE_TEST_20261102_V1.md)): all six offered to the player and answered; each answer moved the stores, gold, safe roads, sale or convoy it says. The six cost 506 ms a computer round, 455 of it Smugglers (a whole store view per store) and the guild (every store read twice); both read none again in `6A09F34C`. The copy changed there too: Smugglers' control loss is in its red cost line, and Smugglers and Caravan Master decline with "Send them away" and "Send him away".

## 67. Version 1.0, 2026-11-02

Parts B to E (§63 to §66) ship together as the mod's version 1.0: main pack `6A09F34C034906AA3106EE2002E70A2A`, built on `10D516E3` by `Modding Files/Backup/v1_20261102/update_v1.py`, in `data/` and `Modpacks/`. Two builds came before it: `9CE23CAA72C64DB39EB014C0BEAA0172` crashed in game (below; its review is `final_pack_review_9CE23CAA.json`), and `2D334371DC18FAC3AE6AD5B58BB34E5D`, its fix, is the build [the live pass](sessions/LIVE_TEST_20261102_V1.md) played. The base is backed up beside the script. Nothing is uploaded and the public repo is not synced.

- **What changed** (`final_pack_review.json`): 21 of 7,346 payloads. Ten files: the flows, stores and route runtimes, the MCT settings, and the stores panel and its row at all three sizes (the panel's column 2 went from 90 to 96 px for "Wait 10 turns", Part B). Eleven tables: `effect_bundles`, `effect_bundles_to_effects_junctions`, `dilemmas`, the three `cdir_events_dilemma_*` tables, `campaign_payload_ui_details`, the loc, and, for the idle buildings below, `building_effects_junction` (and its hold part) and `building_effect_context_expressions`. The other 7,325 are byte-identical to the base.
- **How the script decides:** a staged file ships when its bytes differ from the pack's. A table ships when its rows differ from the pack's own RPFM export, compared as sets of named cells: the generators write columns in another order than RPFM exports them, and a line-by-line comparison flagged 19 tables, 11 of them for the column order alone. Every re-imported table is read back and must equal its TSV.
- **Checks before packing:** the full `gen_mr_ui.py --selftest`, every mutation suite (19, from economy 41/41 and convoy 96/96 to edict 26, toll 15, blockade 13, road 25 and event 17); `gen_resource_overhaul.py --check` and `--selftest`; `luac -p` on the five scripts and the MCT file; `check_lua_api` (4, all CA's `override("retreat")`, which its lib defines and its docs do not); `check_lua_literal_left` 0; `check_lua_undeclared` 0. On the built pack: `check_effect_bundle_loc` 0 findings over 113 bundles, and `check_effect_signs` 6 penalties, all deliberate: Smugglers, Rationing and War economy from this version, and the army's Hungry and Starved from before it.

**The live pass found a crash (2026-11-02), fixed in `2D334371`.** `9CE23CAA` crashed the game in 3 of 4 launches: twice at load, about 3 s after the first tick, and once in the computers' third round. The base `10D516E3` ran 2 launches clean. Both load dumps fault at `Warhammer3.exe+0x118D937`, a virtual call that CA's method binder (`+0x28189FC`) made on freed memory. The Lua value stack in the dump named the chain: `R.tick` > `R.renew_plan` > `F.trade(faction, true)` > `F.trade_pair` > `F.blockade` > `e.f:is_null_interface()`, with `e` taken from `F.enemy_cache`.

That cache kept faction and force interfaces for a whole turn. An interface is good only for the script entry that fetched it ("Character interfaces are volatile and may not be stored over time", CA's scripting docs), and `is_null_interface()` is itself a call on the dead object. The base read the cache only inside the turn start that built it. Part C's `F.blockade` reads it from the map's plan refresh and from other factions' turn starts, which are later entries.

- **The enemy list** keeps `fkey`, `cqi`, `x` and `y`. `F.blockade` answers the key. `F.captor` looks the faction and the force up again, and a force destroyed since then comes back `false`.
- **The route search queue had the same flaw.** `R.avoider`'s closure kept the two parties' interfaces and `cm:model()` for a search that runs over many 100 ms ticks. It now keeps the parties' keys and looks them up for each new owner, and `R.advance` passes the model once a call.
- **Tests.** The flows and terrain harnesses stamp a stub interface with the script entry that made it and refuse a call from a later one. Both failed on the shipped code (`flows.lua:1594`, `terrain_routes.lua:202`). A walk of `F`, `R` and `S`, through tables and upvalues, fails on any interface still held once every test has run. `check_kept_mutations` catches 6 of 6. The convoy suite's "destroyed force skipped" was re-aimed at the new lookup. The harness stubs now follow CA's `cm:get_faction`, which hands an interface argument back as it is (`lib_campaign_manager.lua:8198`).
**Seen in game** on `2D334371` ([the live pass](sessions/LIVE_TEST_20261102_V1.md)): no crash through a load, the map's refreshes and three computer rounds; every part's case, a save and a reload. It found one script error and the author found idle buildings; the final review found two more. All are fixed in `6A09F34C`, each by a test that failed first:

- **The rebel faction's edict.** `factions_trading_with()` and `factions_at_war_with()` return `false` for the rebels, not a list, and the computers' rule read them as lists once a round.
- **Resource buildings that made nothing** (the author, in game: the Goat Farm). No good drew on CA's Pastures deposit (`res_rom_oil`), so every race's pastures stood idle, and CA gives its own deposit's good to neither the Chaos Dwarf marble and timber quarries nor two Greenskin animal pens. Pastures (`PASTURES` in `gen_resource_overhaul.py`) now make Salted Meat and Leather, and Wool where Wool's own rule holds. The quarries and pens make Marble, Timber and Exotic Animals through `CA_GOODS`, on CA's own production effects; every other chain on those deposits keeps CA's row. `check_idle_chains` fails on any resource building outside `EXCLUDE` and the `_military` smithies that makes nothing; it listed 20 chains before the fix.
- **Army positions from earlier in the round** (the final review). `F.enemy_cache` is keyed by the turn number, which spans a whole round, so a turn start seized or passed cargo by where armies stood before everyone between had moved. Each faction's turn start now empties it.
- **Rationing reached Well fed on half the food** (the final review): the bar was five turns of the edict's own meals, so a Chaos Dwarf faction's +3 control outweighed Rationing's -2. Well fed is five turns of normal meals (`F.NEED`) under any edict. The export reserve still keeps five turns of the edict's meals, so Rationing can export a store below Well fed, the trade-off it should carry.
- **The store events' cost**: 506 ms a computer round, 455 of it Smugglers and the guild. `F.stocks` keeps each store's space; the guild reads it, and Smugglers works out each store's turns of use alone.
- **Copy**: see §66.

New mutants: the reset and the two offers' reads, the rebel reads, and Well fed on the edict's meals; every suite catches all of its own. **Seen in game** on `6A09F34C` ([the confirmation run](sessions/LIVE_TEST_20261102_V1.md#confirmation-run-on-6a09f34c)): three computer rounds, turns 6 to 9, with no crash and no script error from the mod. The Goat Pastures at Great Skull Lakes made Leather (0 to 6) and Salted Meat (21 to 33 after meals). The store events cost 124 ms a computer round, Smugglers 78 and the guild 14.

## 68. Version 1.0 minors, 2026-11-03

The eleven minors that version 1.0's final review and live pass left (§67) are fixed. Main pack `12441BDBDA3B32C816FD772089EFC097`, built on `10D516E3` by the same `update_v1.py`, in `data/` and `Modpacks/`. It changes 21 payloads, as `6A09F34C` did: ten files and eleven tables. Of the tables, only `dilemmas` and the loc differ from `6A09F34C`. `6A09F34C` is kept in `Modding Files/Backup/v1_20261102/`. **Not seen in game.**

- **Tolls.** A Closed realm took tolls on a contract cart's road, but spec 5.1 says only a Tolled realm charges. The trade preview counted earlier partners' tolls but not their guards' fee, so on a tight treasury a later partner previewed carts the trade then refused. A faction in debt could not send a free cart between its own settlements (`escrow + toll > treasury` with both 0): a cart that costs nothing is never refused now.
- **Bandits.** The spawn's `cm:create_force` callback read `owner:name()` off an interface fetched before it; the key is read first now. Ambush and highwaymen could roll for cargo standing at sea, and `F.road_event` now returns when the cargo's point is in no region. Ruling: all three encounters stop at sea, not only the two that fight. They are all land encounters, and the cost if wrong is no road trouble while cargo is at sea.
- **Guards.** The panel's action was a toggle, so a double click or a stale panel flipped it twice. The row now sends the state it wants (`guards,on` / `guards,off`), and any other request changes nothing.
- **Blockades.** `F.blockade_known` is saved as `F.state.blockades`, holding this turn's records and last turn's, and checked on load. A reload now shows and charges the same blockade, and the duty after a reload reads it too.
- **Blockade Runner.** It was offered when the pair would have sent nothing; the offer now previews the pair past the blockade. The answer now checks that the two still trade. After the goods get through, the pair's record for the turn is cleared, so the Trade tab and map stop showing "Blockaded".
- **Toll Dispute** is offered only while the player's roads are Tolled. It could come the turn after they were set to Open.
- **Merchant Guild** names its good. A dilemma's targets are a faction, character, force or region, never a good. `F.name_good` sets a CCO script value, `derpy_mr_guild_good_<faction cqi>`, to the good's display name and passes the player's own faction as the target. The text reads it the way CA's incidents read theirs: `{{CcoCampaignEventDilemma:ScriptObjectContext(Format("derpy_mr_guild_good_%d", PrimaryTargetFactionContext.CQI)).StringValue}}`. CA's sea encounters pass the player as their own target the same way. A context value is not saved, so the first tick sets it again for any guild offer still waiting. Ruling: the name rides a script value. If that is wrong, the sentence shows a blank where the good goes, and only the live check can show it. `gen_resource_overhaul.py`'s dilemma check asserts the prefix agrees with `F.GUILD_GOOD`.

Each fix has a test in the flows or stores harness, either watched failing first or proven by its mutant. New mutants: Closed still charging, the preview without guards, a cart refused in debt, the spawn reading the interface, a roll at sea, the toggle, any request taken, Dismiss asking on, blockades not saved, not loaded and a damaged list kept, the runner with nothing to run, past a lapsed trade and still Blockaded, the dispute with roads Open, and the guild's good not named, at the offer or after a load. Four mutants were re-aimed at the lines that changed. All 20 suites catch every mutant, 455 in all (toll 18, event 25, road 30, blockade 16, route 33, convoy 96, economy 41 and the rest). `gen_mr_ui.py`'s fast selftest, `gen_resource_overhaul.py --check` and `--selftest`, `luac -p` and `check_lua_undeclared` are clean. `check_lua_api` reports its known four, CA's `override("retreat")` (§65).

## 69. Thinner lines, smooth carts and a lighter map, 2026-11-03

Build `5CB148793A0CD6D148C90A77B1D3351C`, from the 1.0 base `10D516E3` by `Modding Files/Backup/v1_20261102/update_v1.py`: 981 payloads changed, none added, 6,365 untouched, every re-imported table read back equal. It differs from the build seen in game that day (`D93FB156`) in the terrain script alone.

**Small dashes are half as thick.** The author asked for the default lines at half size. Small, the default, now scales its dashes to 0.35 in each dash scene's vfx wrapper (`build_mr_terrain_routes.SIZES`); the cargo marker keeps 0.7. Normal and Large are unchanged. `gen_resource_overhaul.py` stages the scenes through `build_mr_terrain_routes.assets()`, which `G.pack_paths()` does not name, so `update_v1.py` now asserts the staged route assets match `assets()` before it builds. Seen in game.

**The carts stuttered.** A cart's scene rounds its hex in exactly one second. The step ran every tenth call of the 100 ms map tick, and the real tick averaged 108.7 ms, so every cart sat still for 60 to 130 ms at every hex end. Steps now follow the real clock (`R.now`, `os.clock()` in ms, which is wall time on Windows) on their own timer, `R.cart_tick` every `R.CART_MS` (15 ms; CA's real timers round it up to a frame). A step keeps its one-second beat when it comes up to `R.STEP_LATE` (250 ms) late; past that (a slow redraw, a menu) the beat starts again from the late frame instead of catching up in a burst. What a cart shows on a hex (the corner, the sea test, the scene and its key) is worked out once a step in `R.place`, so a frame between steps reads nothing from the model. Departures are looked at every `R.DEPART_EVERY` (500 ms) and a route waits `R.DEPART_GAP` (6 s) between carts, the old 60 ticks. Measured in game: 68 steps in a row came 975 to 1022 ms apart, mean 1000.0 ms.

**The carried icons twitched once the carts ran smoothly** (the author, the same evening). Since 2026-10-23 the icon alternates two scene ids and holds the outgoing one at the join while the incoming emitter makes its first frames, so the icon never blinks out. The hold was one 100 ms tick. While the cart paused at every join both icons sat on one spot; with the cart moving on, the held icon showed for a tenth of a second behind the new one, once a second. `R.ICON_HOLD` is now 40 ms, two frames at 60 fps. Not yet seen in game.

**Carts and dashes out of the camera.** The map drew carts, dashes and convoy markers inside a circle of four camera distances around the camera's target. `R.in_view` now also asks whether the point falls inside the camera's view: a frustum from `cm:get_camera_position()`'s bearing and height, the screen's shape from `core:get_screen_resolution()`, half the vertical view angle as a tangent `R.VIEW_TAN`, and `R.VIEW_MARGIN` (6 display units) of slack on every side so a pan between ticks shows nothing missing. The circle stays as the far limit, and a camera turned on the spot now counts as a move. The bearing is a compass bearing: 0 looks up the map. **`R.VIEW_TAN` was measured, not guessed**: the CCO global `WorldSpaceToScreenSpace(ToVector4(x, height, y, 1), false, false)` returns CA's own screen position for a display point (`.x`, `.y`, and `.w` the depth, negative behind the camera), read with `common.get_context_value("CcoCampaignRoot", "", ...)`. On a grid of 625 points at a close, a middle and a far zoom and with the camera turned a radian, 0.66 dropped on-screen points at the far zoom, 0.76 dropped none, and 0.8 ships. The first guess, 0.45, would have hidden everything in the outer part of each side of the screen. At 0.8 the map keeps about a tenth of the off-screen points the circle kept (15 of 172 at the middle zoom, 0 of 147 close, 55 of 181 far). The circle itself already dropped some on-screen points towards the horizon at a low camera, as it always has. Seen in game: a cart in view drawn, a cart behind the camera not drawn (the circle would have drawn it, and CA's projection put it off screen).

**The map rests in the computers' turns.** One round of computer turns ran 277 map redraws (3.5 s) because the camera follows their armies. `R.tick` now finishes queued path searches and does nothing else outside `cm:is_local_players_turn()`; a change that came in waits and is drawn at the first tick of the player's turn. Carts keep moving. Measured in game: 0 redraws in the computers' turns over two rounds. Ruling: the routes do not follow the camera during the computers' turns. If that is wrong, a player watching a computer army sees no new routes there until their own turn starts.

The timed redraw that catches what no event reports now runs every `R.STALE_EVERY` ticks (100, 10 s) instead of 25, and one seller's cart goods are renewed every `R.PLAN_EVERY` (20, 2 s) instead of 5. In the profile they cost 22 ms (up to 240) and 7.7 ms each, a frame hitch every 2.5 s and every 0.5 s.

**One read of the stores a turn start.** `F.stock` walks every pooled resource of a settlement. A dozen turn-start steps each read the same settlements again, about 7,500 walks in one computer round (2.35 s in the profile). Inside `F.on_faction_turn_start` (now a pcall around `F.turn_start`) each settlement is walked once and kept in `F.stock_cache` as plain numbers by region key, never an interface (§67). Every write to a store goes through `F.pool_add`, which drops that settlement's copy first, and the cache is dropped when the turn start ends, thrown or not. A reader gets copies, since a stock view is changed in place. `F.stock` also reads `maximum_value` once a good instead of three times. Measured in game: one round made 3,115 walks and served 4,491 reads from the copy; the next, with the copy switched off, made 7,944 walks. The rounds' total turn-start time could not be compared (the first after a load works every road out from nothing), and the round meant to time the reads themselves stalled (below).

**Three live findings fixed.**

- CA's Chaos Dwarf `qb1` logs its `create_force` and makes no army, so no bandit fight could start on Chaos Dwarf land. `F.bandit_spawn` now asks CA's Ogre bandits, the caravans' own, when a race's bandits never come; a force that is made calls back at once, so no force by the return is none at all. Seen in game: nine Ogre units at war with Astragoth on the Black Fortress's land, removed after.
- The Blockade Runner was offered for a partner whose goods had already left that turn, and its answer sent nothing. `F.runner_offer` skips such a partner. Seen in game: of eight partners blockaded that turn, the seven already sent goods were skipped and the offer named Sabreskin; the old order would have named the Conclave.
- A double click on Road guards hired and dismissed them, as the row redraws as Dismiss under the cursor. A guards click within 0.5 s of the last one is dropped. Seen in game: a double click hires once, and a later Dismiss still works.

**The stalled round was the test's.** At Thunderguts' turn a war-declared notice came up; the test's own offer-decliner pressed the diplomacy panel's hidden Cancel instead of the notice's OK, the panel closed, and no further faction turn started. The game answered every script call and logged no error. A decliner for a live test must press `button_ok_war_declared` on a war notice, never Cancel.

Each change has a harness test watched failing first. New suite `check_smooth_mutations`, 22 mutants, all caught: the beat drifting, a stall bursting, a step every call, a frame reading the map, a step keeping the last scene, a cleared map keeping the wait, the view without the bearing, the circle alone, a turn on the spot not a move, the map redrawn in the computers' turn, the icon held 100 ms, the old icon dropped, the cache not used, shared, keeping the first reader's table, kept past a write, past the turn start, past a throw, the runner after the goods, no Ogre fallback, a non-force taken as made, and the guards' double click. Two older mutants aimed at lines that moved were re-aimed (cargo view's shipment marker, the road suite's Hire). `luac -p`, `check_lua_api` (CA's `override`, four, §65), `check_lua_literal_left` and `check_lua_undeclared` (the hub's own nil-guarded `DERPY_HUB`) are clean.

**The settlement label follows 9.0.5.** The pack overrides CA's `ui/campaign ui/city_info_bar.twui.xml` to add the resource row, and `gen_resource_overhaul.py` builds that override from CA's live `ui3.pack`. Our copy dated from before 9.0.5, so it undid three of CA's changes: the settlement book indicator's new place (`dlc29_nag_book_holder`, the patch note's "reduce overlap"), the refresh events `CampaignTurnStart` and `RegionInfectionChanged`, and one visibility check. A fresh build differs from the old one in exactly those places. `update_v1.py` now ships the label through `label()`, which asserts the staged file is what `label_patch(label_vanilla())` makes. Build `5F224EB31A68CB241A294EEB801E1667` differs from `5CB14879` in the label alone, has 0 duplicate keys in 46 tables and 0 uppercase paths, and is in `data/`. Re-run the label after any patch that touches CA's file.


## 70. The open issues, translation and a cheaper end turn, 2026-11-08

Build `F10B4D5C97F3F13A50DCB022664F2AE5`, from `589C3169` by `Modding Files/Backup/ro_fixes_20261108/update_ro_fixes.py`, in the Workshop folder, not uploaded. The full record is [HANDOFF_20261108_RESOURCE_OVERHAUL_FIXES.md](sessions/HANDOFF_20261108_RESOURCE_OVERHAUL_FIXES.md).

- The Vault opener can no longer be lost for the session: `S.follow_bar` places an unplaced button.
- The edict button reads "Wartime", and the fit check uses the measured 8.6 px a letter and CA's plate. "+3% replen." reads "+3% healing".
- Every on-screen string goes through `S.T` / `F.T` and a new loc, `text/db/derpy_mr_ui.loc` (737 rows, keys `derpy_mr_ui_` + 10 hex of the English's md5). RPFM's TSV import keeps `\n` as two characters, so `T` turns it into a line break after the lookup.
- Mod Lua a computer round at turn 16 of IE: 9.2 s to 6.0 s. `F.stock_view` works out the race once, the A* loop runs on locals, and `R.journey` keeps its answers as `R.reach` does, with the same `R.unchanged` rule.
- Region upkeep, race and supply bundles are put on for good (`F.keep_bundle`) instead of again every turn, and `F.drop_bundles` takes them off when a settlement changes hands.
- Computer armies: the campaign AI does not know provisions exist; the script refills them at home and carts food to them, and a foreign campaign past about 5 turns starved. Four MCT options now answer for it, for computer factions only: fed at home (`ai_home_fed`, on), rations abroad (`ai_field_rations`, on, the at-sea purchase anywhere away from home), half rations (`ai_half_rations`, off) and more food (`ai_food`, off, a level's Normal meals a turn in the race's ration). Turn 18 of the IE fixture: 84 of 361 short before, 0 of 373 after.

Build `F524BAA9A59950895C627AF38F3B011A` supersedes `F10B4D5C` above; it adds the four options and their eight loc rows. Uploaded 2026-11-08 14:01.

## 71. Army supply lines replace the game's, 2026-11-09

Design `superpowers/specs/2026-11-08-resource-overhaul-supply-lines-design.md`, plan `superpowers/plans/2026-11-08-resource-overhaul-supply-lines.md`, ledger `.superpowers/sdd/2026-11-08-resource-overhaul-supply-lines/progress.md` (every ruling). Player-facing rules: RESOURCE_OVERHAUL_MECHANICS.md "Army supply lines". Patch notes: [PATCH_NOTES_20261109_RESOURCE_OVERHAUL.md](sessions/PATCH_NOTES_20261109_RESOURCE_OVERHAUL.md). Handoff: [HANDOFF_20261109_RO_SUPPLY_LINES.md](sessions/HANDOFF_20261109_RO_SUPPLY_LINES.md).

**Build `0D36EB30`, uploaded 2026-11-09 14:26** (Steam log, manifest 752735651436871700), in the Workshop folder and `Modpacks/`, on top of `F524BAA9` (§70). The same build gives Neferata's Lahmia and the Glottkin's Oak of Ages goods and stores (+30, +13, +1, +1 building effect rows and one Neferata building set row). The Workshop page's Army supply lines section is posted; its picture is a still (the hosted copy is the GIF's first frame, `workshop/resource_overhaul/WORKSHOP_PAGE.md`).

- **Why a cut road costs the most (author, 2026-11-09 evening).** Asked whether a cut line should cost nothing since no carts run, the author kept the rule and asked for it to be explained in CA's text style as the cost of foraging and buying locally. The bundle became "Supply Road" (CA's title case) with a description in CA's bundle voice (one paragraph: the engine reads this loc as written, so `\n` would print), and the army-bar tooltip, both MCT tooltips and the Workshop line give the reason. The text says no supplies reach a cut army, because the army still only eats what it carries: "buy what little food it can" was drafted and dropped as untrue. Harness asserts the new tooltip; removing the line fails it at `_resource_overhaul_stores_harness.lua:2607`. Also from the same talk: the search stopped at the first settlement with any road, so one enemy army on that road cut the line even when the second-nearest had a clear road. Fixed 2026-11-10 (§72).

- **The replacement.** CA's `apply_upkeep_penalty` (`wh_campaign_setup.lua`) is a global every CA listener calls by name; `F.supply_lines_install` wraps it at the first tick. `F.vanilla_charges(faction)` decides: CA's function runs when the Vanilla box is ticked, or this mod's lines cannot cover the faction (supply lines or army provisions off, or a race that eats nothing); otherwise its bundle is stripped. The same predicate zeroes this mod's distance upkeep, so a faction never pays both. Checked live: a ticked box laid CA's bundle; unticked, CA's turn-start listener stripped it through the wrapper. A script-spawned army does not reach CA's `MilitaryForceCreated` path at all.
- **CA's own gate is not ours.** `campaign_features_tables` gives `additional_army_upkeep = False` to Chaos Dwarfs, Tomb Kings, Khorne, Beastmen, Bretonnia, Warriors of Chaos, Bhashiva and Spirits of the Jungle. The author ruled that every race that eats gets this mod's lines, so `F.upkeep_exempt` keeps only CA's force-type, leader-subtype and set-piece exemptions. Khorne, Tomb Kings and Beastmen keep no stores and so still have none.
- **Settled land.** `F.state.taken[region] = {f, at}` on every `RegionFactionChangeEvent`; `F.settled` is false for `settle_turns` after. CA's custom starts (`wh2_campaign_custom_starts.lua`) transfer regions inside CA's own first tick, before our listener exists: a new IE Sisters of Twilight campaign recorded nothing and the Oak of Ages counts as settled. Confederation not checked. Fresh land is no line source and (since the 2026-11-09 live test, where an army refilled 4 to 10 meals in a settlement taken that turn) no Load source for an army that has a line.
- **Multiplayer.** `F.line_kept` / `R.supply_kept` keep searches per machine; a kept road is given again only while every region its search judged still judges the same, so it is the road a new search would find (live: kept and fresh answers identical for every army, before and after a turn). Panels and the map read enemy armies through `F.enemy_cache_ui`, which model code never reads; `F.dispatch` clears the model cache before a player action.
- **Cost.** The load sweep of 40 slots x 201 scene ids: 32 ms. A cold supply search 1-25 ms in the Astragoth fixture, a kept one under 1 ms.
- **Not reproduced.** A 2026-11-08 Workshop report of 1 s freezes after trade agreements: 11 partners, cache resets and camera pans near and zoomed out gave no frame gap over 300 ms in the player's turn (our longest call 14 ms); the computer round has `R.reach` calls up to 264 ms.

## 72. Imports and food explained, 2026-11-10

From thomasmayrhofer1's Workshop comments ("how does the mod choose what to import? do these imports cost me something? what exactly consumes my food?"); the author asked for QoL in answer. Built `de03c35b` and copied into the Workshop folder at 09:26, once the game was shut, in place of the supply-text build `e439aaf5` deployed that morning. Then `3a981e86` (the fallback) and `e50107be` (the leading-space fix), **uploaded 2026-11-10 13:38** (Steam log, manifest 5948297333835914622; published size equals the local folder) with the description's two supply lines. The uploaded `0D36EB30` it replaced is in `Backup/pre_upload_20261110_resource_overhaul/`. Antislop after-audit and fixes: `anti-slop/audit-019-2026-11-10-resource-overhaul-qol*.md`.

- **The import switch text was false.** Stopped, it said "Trade agreement imports still come in"; `F.trade_pair` sends a stopped good nothing. The tooltips now say how a partner picks a good (its cheapest store, until your capital holds the wanted amount, only uphill by 10%), that the goods are free, and that you and your partners pay import duty either way.
- **A switch also stops your own carts.** `F.ship` checks both switches on every cart, internal ones included, and the flows harness asserts it ("relief respects import hold"), so it is design, not an accident; the mechanics doc said the opposite and is corrected. The tooltips now say so. Still the author's call whether a switch *should* stop internal carts.
- **Send here did nothing under a switch.** `F.send_plan` did not check the switches, so the button stayed live and `F.ship` refused the click silently. It now returns no plan and the tooltip names the switch.
- **Food.** `F.settlement_meals(faction, level)` is the one meal formula (the forecast and the Settlements list both read it). `F.recurring_use` keeps `meals` and `supplied` beside `army_need` and `named`, and a resource's tooltip lists them; they add up to its "uses" figure.
- **Tests.** Flows and stores harness cases for each; 13 mutants, all caught by their own assertion (`mutant_qol.py`, session scratchpad).
- **A blocked supply road falls back (author, 2026-11-10).** `F.supply_line` used to return "cut" at the first source with any road. It now keeps going through the three nearest (`F.SUPPLY_TRIES`) and takes the first clear road. With all blocked it returns the nearest blocked road, so the map still draws the magenta road and names the blocker. Harness: an `s_side` source 100 hexes north, an enemy on its road sends the army to `s_old`, and a second enemy cuts both. Three mutants caught: the old first-road return, no road when all are blocked, and the last blocked road instead of the nearest.
- **The game trims a loc string's leading spaces.** In game the Settlements tooltip read "It eats 4provisions a turn": `common.get_localised_string` gave back "provisions" for the loc row " provisions" (and "and " for " and "; trailing spaces survive). Eleven panel strings start with a space, live since the 11-08 translation build. `S.T` and `F.T` now put the English text's leading whitespace back when the loc lost it. A harness case in each, whose stub trims, and two mutants, both caught (`mutant_trim.py`). Checked against the engine by swapping the fixed `S.T` into the running game: "It eats 4 provisions a turn, 2 for each settlement level."
- **Live test, 2026-11-10** (turn 17 Astragoth save, minimal mod list): bulk and per-good switch tooltips, Salted Meat's import stop and its Send here reason, the forecast breakdown ("The settlement itself eats 4 of that each turn"), and the fallback. For the fallback Khazid Irkulaz was transferred to the player: army 2969, cut on Uzkulak's road by the Slaves of Zharr, went to Khazid Irkulaz (3 turns, supplied) and the map redrew its road pale to the south-west. A scripted transfer is recorded as a capture, so the region had to be marked settled by hand.

## 73. Mortals, Mercs and Management, 2026-11-11

The author asked for this mod to be "compatible and integrated" with *Mortals, Mercs and Management* (Workshop 2815401013, `!zorbaz_kiki.pack`, prefix `cpap_`/`mmm_`, version `2.0-dev17-v5-population-forecast-relink`, file dated 2026-10-10), and skipped the design questions. The calls below are mine. Player-facing rules: RESOURCE_OVERHAUL_MECHANICS.md "Mortals, Mercs and Management". **Build `8C8FC2DF`, uploaded 2026-11-11 16:43, ManifestID 3032660704293598019**: `82EF3537` with only `derpy_more_resources_flows.lua` changed (all 8,430 other files byte-identical, compared after the RPFM save).

- **What collides.** Nothing on disk: the two packs share no file path. Six tables are shared, all with disjoint keys (`cpap*` vs `derpy_mr_*`); the mercenary rows hang off different pools. The collision is behaviour. Both mods feed every field army. Here: carried provisions, Hungry and Starved bundles, road upkeep. Kiki: a supply reserve filled from regional food at 75 food a unit, with leadership, ammunition and replacement-cost bundles, for the AI too (`mmm_supply.lua`). Kiki never touches CA's upkeep (`apply_upkeep_penalty` has zero hits in its Lua), so §71's wrapper and Kiki do not meet. Kiki knows no other mod, so the bridge lives here, on its globals, the way §55 reaches the Exchange's.
- **One feeder an army.** `F.kiki_install` wraps `cpap_supply.is_force_exempt` at the first tick, beside §71's wrapper. `F.feeds(force)` is the provisions test: switch on, a player's army or computer stores on, and `F.fed_force`. `F.fed_force` is new: `F.provision_force` without the escort clause, because that clause takes an army out for one fight and Kiki would start a supply row for it. Kiki reads the function on every call (`mmm_supply.lua:299`, every use through the table), and an exempt army is purged with its bundle at its owner's turn start (`purge_force_row`, :545). Its faction-level exemption purges rows but **not** bundles, which is why the hook is per army. Its panel hides the bar for an exempt army (`mmm_ui_military.lua:1879`). A throw in ours falls through to Kiki's rule.
- **The stores feed hungry people.** `F.kiki_relief`, in `F.turn_start` after `F.provisions_turn` and before `F.spoil`. A region whose `cpap_regions[key].food.unmet` is above 0 sends its spare provisions goods (`F.stock_view`, the keep a cart honours, drawn down good by good) into the reserve through `cpap2_engine.set_food_reserve` with reason `DERPY_RO_STORES`. It sends at most the shortfall, and never past `reserve_capacity`. Rate: 300 of Kiki's food a provision, which is 4 units a meal here × `CPAP_SUPPLY.food_per_supply` (75). Kiki's unit is `STANDARD_PERSON_TURN`, one person fed for a turn. Kiki recomputes production every turn but carries the reserve, so the reserve is the one number another mod can add to that sticks (Kiki settles it per province and spills only above capacity).
- **Order, measured.** `core.event_listeners.FactionTurnStart` has Kiki's `CPAP_FACTION_TURN_START` at 36 and our `derpy_mr_flows_turn` at 153, so Kiki counts first and the relief reads that turn's own shortfall. Its food is in the reserve for the next count. The code does not depend on the order.
- **Not bridged, deliberately.** Kiki's farmers and our buildings stay two food productions. Settlement meals stay a store sink. Kiki's population drives nothing here. Armies we feed no longer draw Kiki's regional food, which eases Kiki's famines a little; they eat goods made in the same regions instead.
- **Tests.** One flows-harness case (install and its absence, every exemption branch, the relief amounts, the keep across goods, the computer and undead gates, both call sites) and 14 mutants in `check_provision_mutations`, all caught. The selftest found two stale anchors, both real. First, the relief loop repeated the line "army reserve" aims at, so the relief line was reworded. Second, the spoil suite's "never runs" and "runs before the meals" anchor on the turn start's meal lines, so its `turn` anchor now spans the relief line. Full selftest after both: 699 mutants caught, none survived, and the generated scripts match their source. Build `8C8FC2DF` is in `Modpacks/` and the Workshop folder (no loadfast cache was present to clear).
- **Live test, 2026-11-11** (minimal list: intro skip, bridge, Kiki, this build; new IE campaign, Gelt, turns 1-3, player shielded):
  - The hook was installed at the first tick.
  - After two rounds, 298 armies were ours and 9 had Kiki rows; none had both, and no army of ours carried a `cpap_supply_*` bundle. The first tick's 4 Kiki rows were Thanquol's schemer bands, which carry no rations here.
  - The player's 8-unit army ate 2 a turn.
  - The relief ran 154 times in one round, saw 22 short regions and fed 4: the High Sentinel 8 provisions, Pahuax 2, Gor Gazan 2, Gronti Mingol 8 (13 held, keep 5). The other 18 had nothing above their keep.
  - Reikland's own count started from a reserve the relief had set, not from Kiki's cached value.
  - No `[derpy_mr_flows]` line and no Lua fault in 4.2 MB of log.
