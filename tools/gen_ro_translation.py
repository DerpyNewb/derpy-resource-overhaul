"""The Resource Overhaul's translation kit: what a translator needs to start, and to keep up after an update.

Writes Modding Files/source/resource_overhaul/translation/ (README.md there is the guide, written by hand):

  english.tsv               every row of the mod's two loc files as one RPFM loc TSV, ready to import
  changes_<YYYYMMDD>.tsv    what moved since an uploaded pack, one row a key:
                              new       a key that was not there
                              edited    same key, new English (the DB text: names, effects, buildings)
                              reworded  a new key for a reworded sentence, with the old key and English beside it
                              removed   a key that is gone; its row in a translation is unused and harmless

Why the changes file: the panel text's keys are derpy_mr_ui_ + an md5 of the English (gen_mr_ui.ui_key), so a
reworded sentence gets a new key and the old translation stops matching. The English shows until it is
translated again, never a stale meaning. Two translators asked for their work to survive updates (2026-11-05,
11-10); this is the list of rows to redo, instead of a diff of 1,800 keys by hand.

Which file wins a key, measured in game 2026-11-11: the .loc whose FILE name sorts first, whatever pack holds
it. `!!tr_z.loc` in `zzz_tr_z.pack` beat `!tr_a.loc` in `!zz_tr_a.pack` and our `derpy_mr_ui.loc`; our
`derpy_mr_ui.loc` beat `zz_tr_a.loc` in `!zz_tr_a.pack`. So a translation named `!!derpy_ro_<lang>.loc` lays
over ours key by key and every row it lacks shows our English.

    py tools/gen_ro_translation.py <the pack the last upload shipped>
    py tools/gen_ro_translation.py --selftest
"""
import difflib
import io
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import read_pack_index as rpi
import read_vanilla_loc as rvl

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Modding Files", "source", "resource_overhaul")
OUT = os.path.join(SRC, "translation")
LOCS = ("loc__derpy_more_resources.tsv", "loc__derpy_mr_ui.tsv")
SUGGESTED = "text/db/!!derpy_ro_translation.loc"
HASHED = "derpy_mr_ui_"      # the keys that follow their English; only these can be "reworded"
REWORD_CUTOFF = 0.6


def tsv_rows(text):
    """(key, text, tooltip) of an RPFM loc TSV, the text left escaped as the TSV and the pack hold it."""
    rows = []
    for line in text.splitlines()[2:]:
        if line:
            key, val, tip = line.split("\t")
            rows.append((key, val, tip))
    return rows


def current():
    rows = []
    for name in LOCS:
        with io.open(os.path.join(SRC, name), encoding="utf-8") as fh:
            rows += tsv_rows(fh.read())
    keys = [k for k, _v, _t in rows]
    assert len(set(keys)) == len(keys), "a key in both loc files: which one shows would depend on the file name"
    return rows


def uploaded(pack):
    """{key: text} of every .loc in an uploaded pack."""
    out = {}
    for _path, _c, data in rpi.read(pack, ".loc"):
        out.update(rvl.parse(data))
    return out


def english_tsv(rows):
    return "key\ttext\ttooltip\n#Loc;1;%s\n" % SUGGESTED + "".join("%s\t%s\t%s\n" % r for r in rows)


def changes(old, new):
    """(change, key, english, old_key, old_english) rows. old, new: {key: English}, new in file order."""
    out = [("edited", k, v, k, old[k]) for k, v in new.items() if k in old and old[k] != v]
    pool = {old[k]: k for k in old if k not in new and k.startswith(HASHED)}
    for k, v in new.items():
        if k in old:
            continue
        hit = []
        if k.startswith(HASHED):
            # a sentence that gained or lost a line is still that sentence, however unlike the ratio says it is
            hit = sorted((o for o in pool if len(o) >= 12 and (o in v or v in o)), key=len, reverse=True)[:1] \
                or difflib.get_close_matches(v, list(pool), n=1, cutoff=REWORD_CUTOFF)
        if hit:
            out.append(("reworded", k, v, pool[hit[0]], hit[0]))
            del pool[hit[0]]
        else:
            out.append(("new", k, v, "", ""))
    paired = {r[3] for r in out if r[0] == "reworded"}
    out += [("removed", "", "", k, old[k]) for k in old if k not in new and k not in paired]
    return out


def changes_tsv(rows):
    return "change\tkey\tenglish\told_key\told_english\n" + "".join("\t".join(r) + "\n" for r in rows)


def write(pack):
    rows = current()
    diff = changes(uploaded(pack), {k: v for k, v, _t in rows})
    os.makedirs(OUT, exist_ok=True)
    files = (("english.tsv", english_tsv(rows)), ("changes_%s.tsv" % time.strftime("%Y%m%d"), changes_tsv(diff)))
    for name, text in files:
        with io.open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
    count = {c: sum(1 for r in diff if r[0] == c) for c in ("new", "edited", "reworded", "removed")}
    print("%d rows in english.tsv; since %s: %s" % (len(rows), os.path.basename(pack), count))


def selftest():
    old = {"derpy_mr_ui_aaa": "It needs %s gold.", "derpy_mr_ui_bbb": "Stop all ", "derpy_mr_ui_ccc": "Held",
           "pooled_resources_display_name_x": "Grain", "effects_description_y": "Upkeep: %+n%",
           "building_z": "Old Mill"}
    new = {"derpy_mr_ui_ddd": "It needs {1} gold.", "derpy_mr_ui_ccc": "Held",
           "pooled_resources_display_name_x": "Grain sacks", "effects_description_y": "Upkeep: %+n%",
           "derpy_mr_ui_eee": "Stop all exports", "derpy_mr_ui_fff": "Allow all imports", "building_w": "Old Mill",
           "derpy_mr_ui_hhh": "{1} has no food to spare.\\nA settlement keeps {2} turns of the food it eats first."}
    old["derpy_mr_ui_ggg"] = "{1} has no food to spare."
    got = {(r[0], r[1], r[3]) for r in changes(old, new)}
    want = {("reworded", "derpy_mr_ui_ddd", "derpy_mr_ui_aaa"),     # a sentence reworded: old key beside it
            ("reworded", "derpy_mr_ui_hhh", "derpy_mr_ui_ggg"),     # a sentence with a line added (0.37 alike)
            ("edited", "pooled_resources_display_name_x", "pooled_resources_display_name_x"),
            ("reworded", "derpy_mr_ui_eee", "derpy_mr_ui_bbb"),
            ("new", "derpy_mr_ui_fff", ""),                         # the old row is taken: one old key, one pair
            ("new", "building_w", ""),                              # a DB key is never a rewording
            ("removed", "", "building_z")}
    assert got == want, sorted(got ^ want)
    # the TSV round-trips, a line break kept as the two characters RPFM imports
    rows = [("k1", "a\\nb", "false"), ("k2", "{1} of {2}", "false")]
    assert tsv_rows(english_tsv(rows)) == rows
    rows = current()
    assert len(rows) > 1500 and all(len(r) == 3 for r in rows), len(rows)
    print("gen_ro_translation selftest ok (%d rows)" % len(rows))


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif len(sys.argv) == 2 and sys.argv[1].endswith(".pack") and os.path.isfile(sys.argv[1]):
        write(sys.argv[1])
    else:
        sys.exit(__doc__)
