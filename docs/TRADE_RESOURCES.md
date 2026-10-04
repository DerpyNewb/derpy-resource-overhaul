# Trade resources: how they are placed on the map and produced

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
not yet seen in game.

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
Kislev and Norsca breed warhorses and feathers. One deliberate exception: Norscan mead also comes
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
  `rare_cond()` holds: 124 across Immortal Empires, the Realm of Chaos and IEE's own regions.
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
- **Not yet seen in game.** `cm:add_building_to_settlement` has no use anywhere in CA's scripts.
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
| What happens to stock on capture, raze or abandonment? | Not observed yet |
| Does a save from before the stores get them? | Not measured yet |

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
- **Level** is shown as `building_level()` returns it. Not yet measured in game; see below.

**In game** (IEE Conclave, turns 1-2, through the bridge and the author's play, 2026-10-02):
- **Button:** sits in the hub's column. **Speed:** the panel opens in 0.006 s.
- **Row clicks work:** `ComponentLClickUp` reaches `derpy_mr_row_<i>` through
  `list_clip > rows_holder`.
- **Level is right as returned:** Zharr-Naggrund 3 / 600, The Falls of Doom 2 / 400.
- **Capture:** a captured settlement keeps its stock. Eagle Eyries held the previous owner's
  Wyvern Scales (3/200) and keeps filling for the new owner. Raze and abandon are unmeasured.
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

Built, deployed to `data/`, **not yet seen in game**. Spec: `superpowers/specs/2026-10-02-resource-overhaul-stores-spending-design.md` §2.
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

Built, deployed to `data/`, **not yet seen in game**. Spec §5. Plan, with the offline
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
- **Look: not confirmed.** `cm:add_scripted_composite_scene_to_logical_position` with CA's
  `cth_caravan` (Cathay's wagon circle, the only caravan scene in `campaign_composite_scenes`)
  was placed at the same spot with both shroud flags true. Whether it drew, and at what size,
  is still unanswered.
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

Built, deployed to `data/`, **not yet seen in game**. Spec §4 (spending design). The capture
option ("Occupy and restore") is part 2 and is not built: it needs the game measured first (below).

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
- **To see in game:** each dilemma's picture and text with its target named; the siege bundle
  stopping siege attrition; the diplomatic bonus's size.

**Part 2, the capture option, needs measuring first.** CA's Dechala row
(`culture_settlement_occupation_options`, id 1218317010) charges through
`captured_region_resource_transaction = wh3_dlc27_resource_cost_sla_thralls_occupation`, a
`resource_costs` row whose junction amount is **+1000** on `wh3_dlc27_sla_thralls_region_occupation`.
Unknown until measured: whether that column adds or takes, whether an option the captured store
cannot pay is greyed, what `required_resources` gates, and which `group` value scopes a row to a
culture. One row per building good per culture makes it ~150 rows of a 30-column table, so it is
not built blind.

## 26. Province supplies and shipments (phase 5, 2026-10-03)

Built, deployed to `data/`, **not yet seen in game**. Spec §3 (spending design, the redesign
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
  our row over CA's `food_merchant` prefab (Grom's cart), named "Shipment". First turn beside the
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

**To see in game:**
- the Food Merchant cart drawing at our marker, and its name and tooltip;
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

Both built, deployed to `data/`, **not yet seen in game**. With these, every part of the spending
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

**To see in game:**
- the Map tab: dots and labels placed sensibly, a cart on its road, a click flying there;
- Restore: offered on capture, the buildings repaired, the public order shown.

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
