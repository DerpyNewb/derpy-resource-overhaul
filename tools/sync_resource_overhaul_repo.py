"""Mirror Derpy Resource Overhaul' files into repos/derpy-resource-overhaul, the public GitHub repo.

The workspace is the source of truth; the repo is a copy with the same layout, so every
tool's relative paths ("Modding Files/...", "tools/...") work from either root.
README.md, CHANGELOG.md, LICENSE, .gitignore and .gitattributes are written in the repo
itself and never touched here. The copying is sync_guilds_repo's.

    py tools/sync_resource_overhaul_repo.py            # copy every changed file into the repo
    py tools/sync_resource_overhaul_repo.py --check    # list drift, copy nothing; exit 1 on drift
    py tools/sync_resource_overhaul_repo.py --selftest

Then commit and push from inside the repo folder.

NOTHING OF CA'S OR GW'S IS PUBLISHED (the author's rule for every public repo from this
workspace, and asked again for this one: "without the copyright assets and icons"). No icons -
the goods' and buildings' icons are composited onto CA art - no copy of CA's
city_info_bar.twui.xml (the pack ships a patched one), and no TSV whose rows are CA's own rows
cloned out of db.pack with our key put in. The generator rebuilds all of those from the
player's own game install. `refused()` checks the manifest before anything is copied, and the
sync will not run while it reports anything.
"""
import os
import sys

import sync_guilds_repo as SG

ROOT = SG.ROOT
REPO = os.path.join(ROOT, "repos", "derpy-resource-overhaul")
_SRC = "Modding Files/source/resource_overhaul/"

# The tables gen_resource_overhaul.build() fills by cloning a vanilla row (dict(donor, key=...)):
# every column but the key is CA's. Ours are the rest - production rows, conditions, the new
# chains' set and roster junctions, prices, unit names and the loc.
CA_CLONES = ("resources_tables", "resources_to_campaign_junctions_tables",
             "cai_personality_strategic_resource_values_tables", "effects_tables",
             "building_chains_tables", "building_levels_tables",
             "building_culture_variants_tables", "pooled_resources_tables")
# Whole FILES that are CA rows with our key: the store twins of CA's production rows (2026-10-02).
CA_CLONE_FILES = ("building_effects_junction_tables__derpy_more_resources_ca.tsv",)

# Anything that is art, a built pack, a CA ui file or a binary game format never goes public.
REFUSED_EXT = (".png", ".dds", ".jpg", ".jpeg", ".webp", ".tga", ".pack", ".bin",
               ".loc", ".anim", ".rigid_model_v2", ".wem", ".twui.xml")


def _tsvs(root=ROOT):
    d = os.path.join(root, _SRC)
    if not os.path.isdir(d):
        return []
    return [_SRC + n for n in sorted(os.listdir(d))
            if n.endswith(".tsv") and n.split("__")[0] not in CA_CLONES and n not in CA_CLONE_FILES]


def manifest(root=ROOT):
    same = _tsvs(root) + ["tools/" + n for n in (
        "gen_resource_overhaul.py",            # the mod: every row, the loc, the IEE submod
        "gen_building_icons.py",            # the rare buildings' icons (output not published)
        "gen_commodity_icons.py",           # the goods' icons (output not published)
        "guess_region_commodities.py",      # the lore rules, checked against what ships
        "survey_resource_map.py",           # the startpos reader: slots, deposits, templates
        "read_vanilla_db.py",
        "read_vanilla_loc.py",
        "read_pack_index.py",
        "import_house_ancillaries.py",      # the RPFM client --pack uses
        "check_lua_undeclared.py",          # imported by it
        "sync_guilds_repo.py",              # this file's copying
        "sync_resource_overhaul_repo.py",
        "_resource_overhaul_ai_harness.lua",   # the AI builder's test, run by --selftest
        "gen_mr_ui.py",                     # the Stores panel's script and .twui.xml
        "gen_mr_emitter.py",                # its own copy of the XML emitter
        "_resource_overhaul_stores_harness.lua",   # the panel's test, run by gen_mr_ui --selftest
        "sync_derpy_hub.py",                # writes this pack's Derpy HUD hub copy
        "_hub_harness.lua",
        "gen_guilds_emitter.py",            # sync_derpy_hub builds the hub's .twui.xml with it
        "preview_guilds_panel.py",          # the .twui.xml reader both selftests use
    )] + ["Modding Files/reference/resource_overhaul_building_audit.md",
          "Modding Files/pack/script/campaign/mod/derpy_more_resources_ai.lua",
          "Modding Files/source/resource_overhaul/stores_panel.lua",
          "Modding Files/pack/script/campaign/mod/derpy_more_resources_stores.lua",
          "Modding Files/pack/script/campaign/mod/derpy_hub_mr.lua",
          "Modding Files/source/derpy_hub/derpy_hud_hub.lua"]
    out = [(p, p) for p in same]
    out += [("docs/TRADE_RESOURCES.md", "docs/TRADE_RESOURCES.md"),
            ("docs/sessions/HANDOFF_20261001_COMMODITY_ICONS_AND_RESOURCE_MAP.md",
             "docs/history/HANDOFF_20261001_COMMODITY_ICONS_AND_RESOURCE_MAP.md")]
    return out


def refused(m):
    """Every manifest entry that must never be published, with why."""
    bad = []
    for src, _dst in m:
        low = src.lower()
        if low.endswith(REFUSED_EXT):
            bad.append((src, "art, CA ui file or game binary"))
        elif low.endswith(".tsv") and os.path.basename(src).split("__")[0] in CA_CLONES:
            bad.append((src, "CA's rows cloned out of db.pack"))
        elif os.path.basename(src) in CA_CLONE_FILES:
            bad.append((src, "CA's rows cloned out of db.pack"))
    return bad


def _selftest():
    m = manifest()
    assert not refused(m), refused(m)
    assert any(s.endswith("building_effects_junction_tables__derpy_more_resources.tsv") for s, _ in m), \
        "our own production rows are missing from the manifest"
    assert not any("building_levels_tables" in s for s, _ in m), "a CA clone got in"
    for probe in ("ui/campaign ui/city_info_bar.twui.xml", "x/resource_derpy_amber.png",
                  _SRC + "resources_tables__derpy_more_resources.tsv",
                  _SRC + "building_effects_junction_tables__derpy_more_resources_ca.tsv",
                  _SRC + "pooled_resources_tables__derpy_more_resources.tsv"):
        assert refused([(probe, probe)]), "refused() let %s through" % probe
    print("selftest ok: %d files, nothing refused" % len(m))


if __name__ == "__main__":
    m = manifest()
    bad = refused(m)
    if bad:
        for s, why in bad:
            print("REFUSED  %s  (%s)" % (s, why))
        sys.exit(1)
    if "--selftest" in sys.argv:
        _selftest()
    elif "--check" in sys.argv:
        found = SG.drift(ROOT, REPO, m)
        for s, _d, why in found:
            print("%-22s %s" % (why, os.path.relpath(s, ROOT)))
        print("%d file(s) drift" % len(found))
        sys.exit(1 if found else 0)
    else:
        found = SG.sync(ROOT, REPO, m)
        for s, _d, why in found:
            print("%-22s %s" % (why, os.path.relpath(s, ROOT)))
        print("synced %d file(s) into %s" % (len(found), REPO))
