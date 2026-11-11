# Changelog

## 2026-11-11, second update

- Works with Mortals, Mercs and Management: an army this mod feeds no longer uses that mod's army supply as well,
  so it is never fed or penalised twice.
- With Mortals, Mercs and Management installed, a settlement whose people go hungry sends the food it can spare from
  its stores to feed them.

## 2026-11-11

- Skaven Food recipe: 10 Grain + 10 Salted Fish for 4 Food.
- Wyvern Roost: upkeep -10% and melee attack +10 for your armies there.
- Thanquol's schemers and Ogre camps no longer need provisions.
- Races from other mods: settlements whose buildings make no goods grow their own food, with spare for their armies.
- Vampire variants from other mods no longer eat.
- The Settlements tooltip says when a settlement's buildings make no goods.
- Norsca's god altars now make goods like the undivided altar.
- Much shorter end-turn freezes on big maps: trade prices looked up once per faction.
- Computer factions' road searches spread over turns.
- No more map stutter every few seconds with a big trade partner.
- Translations: the history words, the Allow all and Stop all buttons and the MCT lock note can now be translated.
- No food to spare: the message now says a settlement keeps 5 turns of its own food first.
- For translators: `Modding Files/source/resource_overhaul/translation/` has every line as one TSV, a guide, and a
  list of the lines each update changed.

## 2026-11-10

- Supply road text says why a cut road costs the most: foraging and buying from the locals.
- Supply Road effect explains the road, the cart cost and the cut cost.
- Import switch tooltips explain how partners pick a good, that imports are free and that duty is paid either way.
- Fixed: Stop all imports said imports still came in.
- Trade switch tooltips say a switch also stops your own carts of that good.
- Fixed: Send here doing nothing when a trade switch stops the good.
- A blocked supply road falls back to another nearby settlement's road.
- Settlements list tooltip shows what each settlement eats a turn.
- Resource tooltips split a store's use into the settlement's meals, armies, province supplies and production.
- Fixed: missing spaces in panel text, such as "4provisions".

## 2026-11-09

- New: army supply lines, in place of the game's own.
- Each army gets a supply road from your nearest settlement.
- Armies in land you have held for 5 turns need no road.
- Roads on the map: pale when supplied, amber when stretched, magenta when cut.
- Longer road, more upkeep: +5% for each turn of road past the first, up to +25%.
- An enemy army on the road cuts it: +25% upkeep until it is clear.
- A newly taken settlement supplies no army for 5 turns.
- Send supplies: a food cart rides the road out to the army.
- Races without army provisions keep the game's own supply lines.
- Chaos Dwarfs, Bretonnia and Warriors of Chaos now have supply lines too.
- New MCT section, Army supply lines: Vanilla supply lines (off), Army supply lines (on), Supply reach in turns (5), Turns to settle new land (5), Upkeep for each turn of road (5%), Most upkeep from a road (25%).
- New MCT option under Trade route lines: Army supply roads (on).
- Neferata's Lahmia and the Glottkin's Oak of Ages now make and store goods.

## 2026-11-08 (second upload)

- Computer armies now handle their provisions. Four new MCT options: Other armies fed at home (on), Other armies buy rations abroad (on), Other armies eat half (off), Other factions make more food (off).
- Faster end turns.
- Settlement bonuses no longer reapplied every turn.
- Resource Vault button no longer goes missing on a long load.
- "War economy" edict now reads Wartime and fits its button.
- "+3% replen." now reads "+3% healing".
- Panel text can now be translated: text/db/derpy_mr_ui.loc.

## 2026-11-08

- Load fills an army to 10 turns, not 5.
- Caravans and convoys carry no provisions.
- No Smugglers in the first turns.
- Less map stutter: only new or changed trade links are redrawn.
- Provisions tooltip rewritten. "1 turn", not "1 turns".

## 2026-11-03

- Trade route lines: Small dashes half as thick.
- Carts move smoothly from hex to hex.
- Cargo icons hand over to the next hex without a ghost.
- Carts, lines and convoy markers drawn only where the camera looks.
- The map stops redrawing during the other factions' turns.
- Faster turn starts: each store read once a turn.
- Bandits now come on Chaos Dwarf land. Ogre bandits stand in.
- Blockade Runner: no offer for a partner whose goods already left.
- Road guards: a double click no longer hires and then dismisses them.
- Closed roads take no tolls.
- No road trouble at sea.
- Blockades kept after a reload.
- Blockade Runner and Toll Dispute checked again when you answer.
- The Merchant Guild names its good.
- Settlement labels updated for game patch 9.0.5.

## 2026-11-02 (version 1.0)

- Trade edicts: Rations, Workshops and Roads, three options each, 10 turns between changes.
- Tolls: 3% to each faction whose land a trade road crosses, 15% at most. Allies and Open roads go free.
- Blockades: an enemy army within 3 hexes of the road stops that partner's trade for the turn.
- Bandits, highwaymen and washed-out roads on the trade roads. MCT switch, on by default.
- Road guards on the Trade tab: 5% of the cargo, half the trouble.
- Six new store events: Smugglers, Merchant Guild, Grain Rot, Caravan Master, Toll Dispute, Blockade Runner.
- MCT Panel size: Small, Medium, Large.
- The Vault closes when you end the turn.
- Shorter tooltips, one plain sentence a line.

## 2026-11-01

- Spoilage: grain rots, beer and kvas sour above a quarter of a store's space. MCT switch, on by default.
- Great Granary keeps grain to half a store.
- Spoiled shows in Last turn, the forecasts and the settlement tooltips.
- Workshop: permanent works say Permanent. Section renamed Permanent works.
- A convoy follows its trade road when the road changes.
- Chaos Dwarf Great Granary: Labour from battles +15% in place of growth.
- Greenskins: Loot Hoard in place of the Grand Bazaar.
- Dwarfs: Engineers' Yard in place of the Royal Stables. Skaven: Beast Pens. Vampire Coast: Bone Yard.
- Chaos Dwarfs: Well fed cuts Labour loss in place of growth.
- Chaos Dwarfs: Full Rations event in place of the Feast.
- Stable stocked: cheaper monsters for every race, gyrocopters for Dwarfs.

## 2026-10-31

- Vault: Production tab. Every processing recipe and service your race has, and the settlements that run each.
- Production: each recipe's output with its icon, inputs in red where a settlement is short, Enable or Pause.
- Production: a recipe no settlement can run names the buildings that would run it.
- Settlement view: a short recipe reads Short, not Paused; one that cannot run says why.

## 2026-10-30

- Agreement trade sends at least 1 of a good while the store has any to spare.
- Computer workshops and services get a cart of their missing inputs from their own other stores.
- Wars and treaties no longer slow the computers' turns with map redraws.
- Trade switches, stock rules and sales show on the map's carts at once.

## 2026-10-29

- Faster computer turns: trade reach is worked out again only where land changed.
- No frame skip when dragging the campaign map.
- Hub button comes back if something else hid it while you were on the map.

## 2026-10-25

- Fixed: braziers, magic and the Hell-Forge fire drew as flat squares with the mod on.

## 2026-10-24

- Every store has its own price for each good: cheap when full, dear when short.
- Selling takes from the stores with the most to spare first, each at its own price.
- Partner contracts pay for each cart as it leaves, never less than the goods sell for where they land.
- Agreement trade sends a good only to a partner that pays at least 10% more for it.
- Vault: Price column, and the partner capital's price in a good's trade view.
- Agreement goods travel the road between the two capitals as a convoy, 40 hexes a turn.
- An army at war with the sender, within 3 hexes of a convoy, can seize it.
- A convoy turns back if the treaty ends or the buyer dies.
- Goods on the road count toward a partner's needs.
- Shipments take as many turns as their road is long.
- Trade tab: Cargo on the road row. Convoy markers on both maps.

## 2026-10-23

- Carts and boats drive the trade roads, in the supplier's own style: nine kinds of cart, 23 ship styles.
- Each carries an icon of the good it moves; empty returns carry none.
- A cart only shows a good that will really move.
- Import and export carts keep to opposite sides of the road.
- Up to sixteen in view; every road gets one before any road gets a second.
- Roads with the same two ends draw as one, carrying all their goods.
- Nearby roads join into shared corridors sooner.
- MCT: switches to show or hide agreements, contracts, shipments, carts and icons.
- A resource's import or export switch also stops its carts.
- Trade reach worked out faster, and again at once after a war, a peace, a diplomatic event or a settlement changing hands.

## 2026-10-22

- Trade roads drawn as dashes in four owner colours.
- Roads go round land hostile to either side.
- Trade reach (MCT, default 6 turns): an agreement whose road is too long or cut off by enemy land moves no goods and no duty.
- MCT: line size and line colours, a colour-blind friendly set among them.
- Shipments follow their saved road on the map each turn.

## 2026-10-21

- Trade roads drawn on the campaign map and in the Vault's Map tab.
- Four new goods: Hardtack, Leather, Cloth and Tools, 58 in the stores.
- Nine recipes and eight services, Builders' yards and Field hospitals among them.
- New armies start with five meals of food, half of what they can carry.
- Vampire Counts and Vampire Coast eat no meals.
- Grain on every farm, Salted Meat on every hunting lodge; six races get Salted Meat from their main settlements.
- Field rations: an army at sea or with no settlements can buy two meals, 10 gold each.
- Provisions button has its own icon.
- Fixed: the Settlements view showed the wrong benefit for some services.

## 2026-10-20

- Processing: brewing, meat preservation, powder mixing, printing and carpet weaving turn stored goods into others.
- Province services: drinking halls, civic records, tea houses, village feasts, scholars' halls, factory mess.
- Army provisions: armies carry food, load it in their own settlements and go hungry without it. On for new campaigns.
- Provisions button on the army bar.
- Computer factions send paid food carts to their hungry armies.
- Shipments take 1 to 6 turns by distance, at most 100 goods a cart.
- Recurring orders, and paid contracts with trade partners.

## 2026-10-19

- Keep and Target per resource, with automatic defaults: five turns of use kept, ten turns imported.
- Trade, Send here and supplies never take what you keep.
- Tooltips forecast how long a store lasts.

## 2026-10-12

- Fixed: a Workshop unit bought straight into an army made the next ordinary recruit of that unit free.
- Siege Stores and An Enemy Shipment dilemmas: own pictures, not Grom's troll.
- Shared mod button: hub v6, works with the left bar submod.

## 2026-10-11 (later)

- Shipments drawn as a wagon circle, not a troll.
- Fixed: store event and raid dilemmas left their settlement, faction or army name blank.
- Docs: in-game test results for stores, events, shipments, escort battles, recruit charges, duty and the Workshop.
- MCT: Turn off random dilemmas switch, default off (the game's own random dilemmas; store events still come).

## 2026-10-11

- Rare-resource buildings can be founded from the Vault in the 43 lore regions no building slot offers them (Settlements tab, a settlement's stores: Found, then Upgrade).
- Computer factions build them in those regions too.
- Records of dead factions are cleared each turn.
- Vault button hides with the other buttons off the main campaign screen.

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
