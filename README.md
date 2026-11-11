# Derpy Resource Overhaul

A campaign mod for **Total War: WARHAMMER III**. It adds 41 new trade goods to the
campaign map. They are made by the buildings the lore says would make them, only where the
lore puts them, and they trade through CA's own trade agreements like the vanilla goods.

It needs no map edit and no new start position. Every good is a production row on a building
the game already has, gated by a condition on the region. A port on Naggaroth's cold coast
lands Sea Dragon Hide, and a port in the jungle lands Rum and Pearls. A Dwarf hold in the
mountains digs Gromril, and the farms of the Empire grow Grain.

It also makes four of CA's own goods as common as these. Salt, Furs, Pottery and Wine sit on
only 11 to 13 deposits in vanilla. Here harbours on warm coasts make Salt, the frozen north
traps Furs, the Old World's craft houses fire Pottery and its southern farms press Wine.
These rows use CA's own production effects, so the goods are still CA's.

Until 2026-10-02 this mod was called Derpy More Resources. Its packs are now
`derpy_resource_overhaul.pack`, `derpy_resource_overhaul_iee.pack` and
`derpy_resource_overhaul_oldworld.pack`. Every in-game key is
unchanged, and so are the DB table file names inside the packs.

**Status:** on the Steam Workshop as
[Derpy's Resource Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=3833299348),
with its [IEE](https://steamcommunity.com/sharedfiles/filedetails/?id=3833299507) and
[Old World](https://steamcommunity.com/sharedfiles/filedetails/?id=3833299575) submods. Last
updated 2026-11-09 with army supply lines (see CHANGELOG.md). Tested in Immortal Empires and
Immortal Empires Expanded campaigns through a live connection to the running game. Not yet
tested: the Old World and Realm of Chaos campaigns with the trade roads, and multiplayer on
two machines.

## The goods

Salted Fish, Whale Oil, Sea Dragon Hide, Rum, Amber, Grain, Warhorses, Pipeweed, Books, Olive
Oil, Silk, Tea, Jade, Coal, Silver, Gromril, Quicksilver, Brimstone, Brass, Blackpowder,
Ithilmar, Dragon Bone, Lustrian Plumes, Black Lotus, Incense, Salted Meat, Arabyan Carpets,
Kvas, Rhinox Hides, Mead, Glassware, Wool, Porcelain, Pearls, Starwood, Griffon and Pegasus
Feathers, Wyvern Scales, and since 2026-10-21 Hardtack, Leather, Cloth and Tools.

Each good comes from one or more kinds of building:

- **Ports:** fish, whale oil, amber, rum, pearls, sea dragon hide
- **Farms:** grain, wool, olive oil, pipeweed, mead, tea
- **Hunting lodges:** plumes, rhinox hides, salted meat, leather
- **Craft houses:** silk, jade, carpets, glassware, porcelain, cloth
- **Forges and metalworks:** brass, tools
- **Mines:** silver, gromril, quicksilver, coal, brimstone, ithilmar, blackpowder saltpetre
- **Inns, teahouses, stables and eyries:** kvas, tea, warhorses, feathers
- **A few cities, by name:** Nuln's blackpowder, the great libraries' books
- **No building:** hardtack is baked from stored grain and salt

The buildings were chosen by their in-game names and descriptions, not by category: the
Kislev Roadhouse, which "sells nothing but kvas", makes Kvas, and the Cathay Tea Parlour makes
Tea. A building only makes a good where that good's condition holds for its region. The
conditions use climate, region group, deposit, the region's original race, a port, or a named
region.

**Lore over coverage.** A race with no lore basis for a good does not make it. Norsca raids,
the Chaos Dwarfs trade for their food, and the dead do not farm. Those races get the goods
by trade, and so does everyone else.

## The rare goods' own buildings

Eight goods also have a building of their own: Gromril, Ithilmar, Dragon Bone, Sea Dragon
Hide, Black Lotus, Starwood, Griffon and Pegasus Feathers, and Wyvern Scales. Each has three
levels, can be built in any ordinary slot by the races its lore names, and pays income like
CA's resource buildings. It also carries a race bonus to the units the good arms. Dwarfs get
Ironbreakers and Hammerers from Gromril, and the Empire gets Demigryph Knights from the
feathers.

The building makes **nothing** outside its good's lore regions. The condition is the lock:
without a start position there is no other way to tie a building to a place.

There are 27 building chains, one per race per good. The game files a chain under exactly one
building set, so one chain shared between races appears for only one of them.

## Stores and the Resource Vault

Every settlement keeps its own store of each good, up to 200 to 1,000 by settlement level.
Buildings fill it, and settlements eat from it: food, building materials and luxuries keep
their province's bonuses going. Raids, sacks and razes take from it. Trade partners send their
surplus to each other's capitals, and each pays the other an import duty in gold.

The Resource Vault is the mod's panel, opened from the campaign HUD. From it you set what each
settlement keeps and imports, send goods between your settlements by cart, run recurring
orders and paid contracts, sell surplus, and spend goods in the Workshop on items, units and
lasting upgrades. Recipes turn stored goods into others, and province services spend goods for
bonuses. Armies can carry food and go hungry without it. Computer factions play by the same
rules and pay the same prices. `docs/RESOURCE_OVERHAUL_MECHANICS.md` has every rule and number.

## Trade roads on the map

Every trade agreement, contract and shipment is drawn on the 3D campaign map as a dashed road
in its owner's colour. The road is a search over the installed map's own pathfinding grid, so it
goes round mountains, crosses water where ships can, and keeps off land hostile to either side.
An agreement whose road is longer than the trade reach, or that enemy land cuts off, moves no
goods and no duty. Nearby roads join into shared corridors.

Low-detail carts and boats drive the roads, in the supplier's own style, each with an icon of
the good it carries. They are decoration: the goods move on the turn, not with the carts, and
the carts show only what the economy will really send. They are drawn in single player only.

## Army supply lines

Since 2026-11-09 the mod replaces the game's own supply lines, where every army after the
first raises the upkeep of all of them. Instead each army draws on a road to the nearest
settlement its faction has held for 5 turns. An army in such land needs no road.

- **Upkeep by road length.** A one-turn road costs nothing extra. Each further turn adds 5%, up
  to 25%, the cost of keeping the carts moving. A road longer than the reach (5 turns) or cut by
  an enemy army pays the full 25%: no supplies get through, and foraging and buying from the
  locals costs the most.
- **Fresh conquests feed nobody.** A settlement taken in the last 5 turns cannot be a source,
  and a player army standing in it cannot refill there.
- **Food carts.** Send supplies puts a cart of food on the road, and Auto refill sends them on
  its own. A cart takes the road's turns to arrive, and an enemy army can seize it.
- **Blocked roads.** An enemy army on the road sends the army to the road of another of the three
  nearest settlements. Only when none of them is clear is the line cut.
- **On the map.** Each army's road is drawn pale when supplied, amber when stretched and magenta
  when cut.
- **One penalty, never two.** Races that carry no provisions (Vampire Counts, Vampire Coast, the
  daemons, and the races with no stores) keep the game's rule. So does everyone when the MCT's
  Vanilla supply lines box is ticked, or provisions or supply lines are off. Chaos Dwarfs,
  Bretonnia and Warriors of Chaos, whom the game never charged, get lines.

Every figure is an MCT setting. `docs/RESOURCE_OVERHAUL_MECHANICS.md` has the full rules.

## Other mods

- **Immortal Empires Expanded.** `derpy_resource_overhaul_iee.pack` extends the conditions to
  IEE's 236 extra regions (Ind, Khuresh, Nippon and the rest). The IEE pack itself is not
  needed to build anything here.
- **The Old World.** `derpy_resource_overhaul_oldworld.pack` links the goods to the Old World
  campaign (`cr_oldworld`, its devastate version included) and adds production and store rows
  to the buildings it adds itself: the Kraka Ravnvake port, Mordheim's Wood Elf settlement and
  a Realm of Chaos outpost. Enable it only with the Old World; like the IEE pack, the game
  refuses it when that campaign is not loaded.
- **Derpy's Grand Trade Exchange.** When both are installed, the Exchange trades all 41
  goods. It detects this mod from the goods' own names and reads each settlement's real
  production off its buildings. That bridge lives in the Exchange, not here.
- **One CA file is overridden.** `ui/campaign ui/city_info_bar.twui.xml` gains one icon per
  good on the settlement label, because the engine only shows map deposits there. Another mod
  that overrides the same file will conflict. The generator rebuilds the patch from the
  installed game's own copy, so re-run it after a game patch.
- **One CA function is wrapped.** The supply lines wrap CA's global `apply_upkeep_penalty`
  (from `wh_campaign_setup.lua`) at the first tick rather than overriding its file. Another
  mod that replaces or wraps the same function may conflict: CA's listeners call whichever
  version is the global at the time.

## Translating it

[`Modding Files/source/resource_overhaul/translation/`](Modding%20Files/source/resource_overhaul/translation/)
has every line of the mod's text as one RPFM loc TSV, a list of what changed in each update, and
a short guide: what to name the loc file so it lays over the English key by key, which markup to
keep, and what to do with each changed line after an update.

## Building it

Python 3 and Pillow. The tools read CA's data straight out of your own game install. The paths
are at the top of `tools/read_vanilla_db.py`, `tools/read_vanilla_loc.py`,
`tools/survey_resource_map.py` and `tools/gen_resource_overhaul.py`. Set them to your install.

```
py tools/gen_resource_overhaul.py              # write every TSV, the loc and the map label
py tools/gen_resource_overhaul.py --check      # build and verify, write nothing
py tools/gen_resource_overhaul.py --selftest
py tools/gen_resource_overhaul.py --audit      # what each building makes, by its in-game name
py tools/gen_resource_overhaul.py --pack       # build the .pack files (RPFM's MCP server open)
py tools/gen_mr_ui.py --selftest              # the Vault, the flows and the roads, under Lua 5.1
```

The trade roads need two more steps. `tools/build_mr_terrain_routes.py` reads every campaign
map's pathfinding grid from your install (`tools/campaign_route_paths.py`) and writes the road
script from `Modding Files/source/resource_overhaul/terrain_routes.lua`. The cart, boat and
icon scenes are written by `Modding Files/source/resource_overhaul/cart_scene_builder`, a
.NET program that compiles TheAssetEditor's ESF reader from the path in its project file; it
starts from a donor scene that is not published here.

`Modding Files/reference/resource_overhaul_building_audit.md` is the `--audit` output: every
building that makes a good, by its in-game name per level, beside what it makes.

The icons are made by `tools/gen_commodity_icons.py` and `tools/gen_building_icons.py`. Each
draws a glyph with an image model through the Codex CLI and composites it onto CA's own
resource-icon frames from your install. Those frames are CA's art, so no icon is published
here.

## What is not in this repository

Nothing of Games Workshop's or Creative Assembly's is published here:

- no icons;
- no copy of `city_info_bar.twui.xml`;
- no composite scenes (`.csc`), vehicle models or road textures;
- no built road script: it carries each campaign map's pathfinding grid, which is CA's data;
- none of the seven tables whose rows are CA's rows cloned with a new key (`resources`,
  `resources_to_campaign_junctions`, `cai_personality_strategic_resource_values`, `effects`,
  `building_chains`, `building_levels`, `building_culture_variants`).

The generator rebuilds all of them from your install. The TSVs that are here hold only this
mod's own rows: production, conditions, prices, unit names, the new chains' placement, and
the text. `tools/sync_resource_overhaul_repo.py` refuses to copy anything else into this
repository.

## How it is tested

There is no test framework. Each tool carries a `--selftest`, and `gen_resource_overhaul.py`
checks every build before writing it:

- **Conditions.** Each condition is rendered to CA's expression language for the game, and
  evaluated in Python against every region of Immortal Empires and the Realm of Chaos. The
  two must agree, region for region, with the lore rules in
  `tools/guess_region_commodities.py`. So the lore table and what ships cannot drift apart.
- **Rows.** No duplicate condition key, and every damaged value follows CA's rule (half,
  rounded away from zero).
- **Rare buildings.** Every rare chain sits in exactly one building set, its rosters belong to
  one culture, every row is gated, and no race carries another race's bonus.
- **Map mods.** A guard fails any condition with no terrain clause that blankets a whole area
  of ten or more regions that CA's maps lack (IEE's Ind, Khuresh, Nippon). Every chain a map
  mod's own port, settlement or mine slots permit must be CA's or have rows in its pack.
- **Lua harnesses.** `gen_mr_ui.py --selftest` runs the shipped Vault, flows and road scripts
  under Lua 5.1 against stubbed game objects, then the mutation suites, each mutant a plausible
  mistake in the economy, the provisions, the supply lines, the contracts or the map, and fails
  if any one survives.
- **Selftest cases.** The selftest breaks each of these on purpose (an ungated row, a second
  building set, a foreign bonus, a blanket condition) and confirms the check catches it.

## Licence and legal

The code and documentation in this repository are released under the
[MIT License](LICENSE).

This is an unofficial, fan-made mod. It is not made, endorsed or supported by Games
Workshop, Creative Assembly or SEGA.

- **No game files or assets are included.** The repository contains no art, models,
  sounds or game data files from Total War: WARHAMMER III. The mod references the game's own
  data by key at runtime, and you need your own copy of the game to use or build it.
- Warhammer and the names, places and characters of the Warhammer world are trademarks
  and/or copyright of Games Workshop Limited. Total War and Total War: WARHAMMER are
  trademarks and/or copyright of The Creative Assembly Limited and SEGA. All are used here for
  identification only.
- The MIT License covers only the original work in this repository. It grants no rights
  in any Games Workshop, Creative Assembly or SEGA property.
