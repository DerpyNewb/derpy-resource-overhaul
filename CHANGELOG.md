# Changelog

## 2026-10-09 (night)

- Escort battles: shipments travel with an escort sized by cargo and turn, from each race's own army lists.
- Raid: walking onto an enemy shipment asks first, then fights its escort; win and the cargo is yours.
- Defence: an enemy army by your shipment at turn start fights its escort; retreat locked.
- Spending tab: click a shipment to see its escort as unit cards.
- MCT: Escort battles switch, default on.

## 2026-10-09 (evening)

- Fixed: the Resource Vault button could do nothing when another mod's click script has an
  error. Its click listener now runs first.
- Vault tables have a frame, and Workshop sections fold.

## 2026-10-09

- Fixed: a war machine took one resource too many when its draw split unevenly.
- Wood Elf items name who can carry them (Hail of Doom Arrow, Bow of Loren).
- Kislev's feather works removed: Kislev makes no feathers and trade brings too few.
- Text: one word for resources throughout, clearer tooltips, Workshop title and tab tooltips updated.
- Rare-resource buildings: description no longer repeats itself.

## 2026-10-08

- Trade tab: stopping a good's exports also stops CA's trade agreement export of it.
- Import duty: each turn trade partners pay each other a share of what they make (MCT 0-50, default 10).
- Trade tab: an Import duty row, paid and received per partner.
- Rare resources are kept for the Workshop: orders, supplies, events and upkeep no longer use them.
- Restore is offered on loot-and-occupy too.
- Recruiting takes resources from your stores, by unit type and worth, for any mod's units.
- Recruiting: elite units also take your race's rare resource.
- Recruiting: a shortfall is paid in Armaments (Chaos Dwarfs) or Food (Skaven), then gold.
- MCT: Recruits use the stores, and how much each recruit takes.
- Spending tab: Recruits last turn.
- Workshop: convert stores into Armaments, Food, Oathgold or Infamy.
- Workshop: army works for the selected army (ammunition, armour, replenishment, attrition, a rank).
- Workshop: traits for the selected lord or hero.
- Workshop: works that last (growth, research, trade income, upkeep, cavalry cost).
- Workshop: each recipe shows up to four priced resources; sections fold.
- Workshop: 15 more CA items and 9 more units.
- Workshop: Vampire Counts, Cathay and Norsca.
- Fixed: Sell surplus paid ten times over with the Exchange installed.
- Fixed: Sell surplus could desync multiplayer with the Exchange installed.
- Fixed: holding beer could list exports the faction never made.
- Fixed: import duty charged on held goods.
- Fixed: two Restores in one turn paid for the wrong settlement.
- Fixed: opening the Resource Vault before the first turn froze the settings.
- Fixed: an event never issued blocked the next one.
- Fixed: a failed siege's spoils carried over to a later raze.
- Fixed: supply pay icon pulsed red while the capital could pay.
- Fixed: Workshop tooltip, chart's newest bar, Imports tooltip and Import duty row text.
- MCT options are greyed in a campaign, with the reason.

## 2026-10-04

- The Old World compatibility pack: `derpy_resource_overhaul_oldworld.pack`.
- Goods placed by region name also work on the Old World's regions.
- AI builds rare-good buildings in the Old World's regions.
- Map tab: the Old World's own campaign map.
- Map tab: CA's panel border, a key and Zoom in/out buttons.
- Resource Vault: CA's glows on running orders, paying supplies and convoys; short supplies pulse red.
- Resource Vault: the map stays where it is dragged.
- Charts: bars line up under their turn, with a baseline and top line.
- Fixed: +/- buttons missing on a first draw.
- Fixed: map flicker while dragging.

## 2026-10-03

- Province supplies: Materials on hand, Stable stocked, Arms stocked, paid each turn from the capital.
- Supply the capital: a standing order per province, off by default.
- Send here is now a shipment: two turns on the road, a cart on the map, can be seized by enemy armies.
- Store events: Feast, Siege Stores, Tribute, Arsenal.
- Restore on capture: spend building materials to repair a captured settlement.
- Resource Vault: a Spending tab with the province supplies, shipments on the road and the orders.
- Spending tab: each supply shows the resource it pays with, greyed when the capital cannot pay.
- Resource Vault: a Map tab with CA's campaign map, settlement markers and convoys; click to fly there.
- Map tab: drag to move the map.
- Fixed: Spending and Map tab buttons drawn over the title.
- Fixed: settlements placed too far south on the Map tab.
- Fixed: the Map tab could not be dragged.

## 2026-10-02

- Fixed: in a campaign started before this update, eating, bonuses and panel actions stayed off.
- The Stores panel is now the Resource Vault.
- Wider bottom-line buttons; hints moved beside the sub-title.
- Stores panel: Send here moves a resource from another settlement (10% lost on the way).
- Stores panel: Festival, Muster and Great Works orders, paid with 200 of your stores.
- Stores panel: Sell surplus, at the Zharr Exchange's price when it is installed.
- MCT: Stores panel actions.
- Settlements eat provisions each turn: 2 per settlement level.
- Well fed (+growth), Garrison stocked and Comforts (+public order) from well-stocked stores.
- Stores panel: a Using column on Settlements; "eaten" in last turn's changes.
- MCT: Settlements use their stores; Other factions use their stores.
- "Goods" renamed "Resources" everywhere the player reads it.
- Trade tab: Allow all / Stop all buttons for exports and imports.
- Trade tab: click "Resources you do not have" to hide or show them.
- Stores panel redesign: a line under the title, per-tab columns, Trade checkboxes, row bands.
- Trade tab: a "Goods you do not have" heading over the greyed goods.
- Stores panel: a Trade tab to stop each good's exports or imports.
- Raiding army shows the goods its raid takes, with a tooltip per good.
- Settlement Captured: Sack and Raze show the goods they take.
- Trade tab: goods you neither hold nor make are greyed and listed last.
- Settlements tab: icons of each settlement's goods before its name.
- Settlement Captured: Occupy shows the stores it keeps.
- Shorter tooltips on the raid and capture values; names line up on Settlements.
- Raid and capture values: one per good, with that good's icon (up to three).
- Stores panel: column lines; Trade switches line up under their headers.
- Raids take from any faction's land, not only at war.
- Small stores lose at least 1 to a raid, sack or raze.
- Trade sends only whole shares; single units no longer bounce between partners.
- Fixed: razing took no goods.
- Fixed: a trade error for some factions each turn.
- Raids, sacks and razes carry off a share of a settlement's stores.
- Trade agreements move goods a partner lacks into its capital each turn.
- Stores panel: a 20-turn chart and last turn's changes for each good.
- MCT settings for the four shares.
- A Stores panel: every settlement's stores, by good or by settlement.
- Every settlement keeps a store of each good.
- Stores fill each turn from its buildings.
- Space grows with settlement level.
- Renamed to Derpy Resource Overhaul. New pack names, same keys.
- Salt, Furs, Pottery and Wine made common, on CA's own effects.
- Wine only from Bretonnian, Empire and High Elf farms.

## 2026-10-01

- First public source.
- 37 goods, made on existing buildings under lore conditions.
- 8 rare goods with their own three-level buildings, one chain per race (27).
- Immortal Empires Expanded submod.
- Map label icon per good.
- Trades on Derpy's Grand Trade Exchange when both are installed.
