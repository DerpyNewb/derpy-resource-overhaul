# Derpy Resource Overhaul

A campaign mod for **Total War: WARHAMMER III**. It adds 37 new trade goods to the
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
`derpy_resource_overhaul.pack` and `derpy_resource_overhaul_iee.pack`. Every in-game key is
unchanged, and so are the DB table file names inside the packs.

**Status:** not on the Steam Workshop yet. Tested in an Immortal Empires Expanded campaign
through a live connection to the running game. A Salted Fish surplus traded in a vanilla
trade agreement, and the rare buildings were offered to the right races.

## The goods

Salted Fish, Whale Oil, Sea Dragon Hide, Rum, Amber, Grain, Warhorses, Pipeweed, Books, Olive
Oil, Silk, Tea, Jade, Coal, Silver, Gromril, Quicksilver, Brimstone, Brass, Blackpowder,
Ithilmar, Dragon Bone, Lustrian Plumes, Black Lotus, Incense, Salted Meat, Arabyan Carpets,
Kvas, Rhinox Hides, Mead, Glassware, Wool, Porcelain, Pearls, Starwood, Griffon and Pegasus
Feathers, Wyvern Scales.

Each good comes from one or more kinds of building:

- **Ports** - fish, whale oil, amber, rum, pearls, sea dragon hide
- **Farms** - grain, wool, olive oil, pipeweed, mead, tea
- **Hunting lodges** - plumes, rhinox hides, salted meat
- **Craft houses** - silk, jade, carpets, glassware, porcelain
- **Forges** - brass
- **Mines** - silver, gromril, quicksilver, coal, brimstone, ithilmar, blackpowder saltpetre
- **Inns, teahouses, stables and eyries** - kvas, tea, warhorses, feathers
- **A few cities, by name** - Nuln's blackpowder, the great libraries' books

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

## Other mods

- **Immortal Empires Expanded.** `derpy_resource_overhaul_iee.pack` extends the conditions to
  IEE's 236 extra regions (Ind, Khuresh, Nippon and the rest). The IEE pack itself is not
  needed to build anything here.
- **Derpy's Grand Trade Exchange.** When both are installed, the Exchange trades all 37
  goods. It detects this mod from the goods' own names and reads each settlement's real
  production off its buildings. That bridge lives in the Exchange, not here.
- **One CA file is overridden.** `ui/campaign ui/city_info_bar.twui.xml` gains one icon per
  good on the settlement label, because the engine only shows map deposits there. Another mod
  that overrides the same file will conflict. The generator rebuilds the patch from the
  installed game's own copy, so re-run it after a game patch.

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
```

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
- **IEE.** A guard fails any condition that blankets a whole IEE area of ten or more regions.
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
