# Translating Derpy's Resource Overhaul

Two files in this folder:

- `english.tsv` has every line of text in the mod: the panels, tooltips, buildings, goods, effects and the MCT
  settings page. It is ready to import into RPFM.
- `changes_YYYYMMDD.tsv` lists what changed in that update, compared with the update before it. There is one
  file for each update.

Translations are welcome as separate mods that require this one.

## Make a translation

1. In RPFM, make a new pack. Its name does not matter.
2. Add a loc file named `text/db/!!derpy_ro_<language>.loc`, for example `text/db/!!derpy_ro_zh.loc`.
3. Import `english.tsv` into it (open the loc file, then Import TSV) and translate the `text` column. You can
   also translate the TSV in a spreadsheet first and import it after.
4. Save the pack and upload it with this mod as a required item.

You do not need to translate every row. Any row you leave out shows the mod's English.

## Name the loc file `!!derpy_ro_<language>.loc`

When two loc files have the same key, the game uses the file whose name comes first in alphabetical order.
The pack's name does not change this (tested in game on 2026-11-11). `!!derpy_ro_...` comes before this mod's
own `derpy_more_resources.loc` and `derpy_mr_ui.loc`, so:

- your translation wins for every key you have;
- every key you do not have yet shows the mod's English, so an update never leaves a line blank.

Do not name your file `derpy_more_resources.loc` or `derpy_mr_ui.loc`. A file with the same name replaces the
mod's whole file, and then names and descriptions added in a later update show blank until you add them.

## Keep these exactly as they are

| In the English | What it is | What to do |
|---|---|---|
| `{1}`, `{2}` | a number or a name the mod fills in | keep each one; you can move them and change their order |
| `\n` | a line break | keep it |
| `\|\|` | in a tooltip: the title before it, the text after it | keep it |
| `%n`, `%+n` | an effect's value | keep it |
| `{{Cco...}}` | a game expression | copy it unchanged |
| `[[col:...]]`, `[[/col]]`, `[[img:...]]`, `[[/img]]` | colour and icon tags | copy them unchanged |

A space at the start of a line (`" provisions"`) is put back by the mod, so you can leave it out.

Buttons, tabs and column headers have fixed widths. Keep those short.

## After an update

Open the newest `changes_` file, and any you missed since your last update. The `change` column says what to
do with each row:

| change | Meaning | What to do |
|---|---|---|
| `new` | a new line | add the key and translate it |
| `edited` | same key, new English | update your translation of that key |
| `reworded` | the sentence was reworded, so it has a new key | `old_key` is the key you translated before: copy your old translation to the new key and adjust it |
| `removed` | the line is no longer used | delete the row, or leave it; it does nothing |

Until you catch up, the changed lines show in English. Your other lines keep working.

Why a reworded sentence gets a new key: the keys that start with `derpy_mr_ui_` are made from the English
sentence itself. When the English changes, the key changes, so an old translation never shows on a sentence
whose meaning has changed.
