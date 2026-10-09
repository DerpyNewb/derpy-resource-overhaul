"""Mirror The Great Guilds' files into repos/derpy-great-guilds, the public GitHub repo.

The workspace is the source of truth; the repo is a copy with the same layout, so every
tool's relative paths ("Modding Files/pack/...", "tools/...") work from either root.
README.md, CHANGELOG.md, docs/DEVELOPMENT.md and .gitignore are written in the repo
itself and never touched here.

    py tools/sync_guilds_repo.py            # copy every changed file into the repo
    py tools/sync_guilds_repo.py --check    # list drift, copy nothing; exit 1 on drift
    py tools/sync_guilds_repo.py --selftest

Then commit and push from inside the repo folder.
"""
import filecmp
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.join(ROOT, "repos", "derpy-great-guilds")

_MOD = "Modding Files/pack/script/campaign/mod/"
_UI = "Modding Files/pack/ui/campaign ui/"

# (workspace path, repo path). A folder entry copies every file directly inside it.
# ponytail: no deletion - a file dropped from here stays in the repo until removed by hand.
MANIFEST = [(p, p) for p in [
    _MOD + "zzz_derpy_guilds.lua",
    _MOD + "zzz_derpy_guilds_ai.lua",
    _MOD + "zzz_derpy_guilds_ui.lua",
    _MOD + "zzz_derpy_guilds_bounty_data.lua",
    "Modding Files/pack/script/mct/settings/derpy_great_guilds.lua",
    _UI + "derpy_gg_panel.twui.xml",
    _UI + "derpy_gg_card.twui.xml",
    _UI + "derpy_gg_row.twui.xml",
    _UI + "derpy_gg_list.twui.xml",
    _UI + "derpy_gg_frow.twui.xml",
    _UI + "derpy_gg_opener.twui.xml",
    # THE DERPY HUD HUB: this pack's copy, its source and the tool that writes the copies.
    _MOD + "derpy_hub_gg.lua",
    _UI + "derpy_hub_gg.twui.xml",
    _UI + "derpy_hub_plate_gg.twui.xml",
    "Modding Files/source/derpy_hub/derpy_hud_hub.lua",
    "tools/_hub_harness.lua",
    "tools/sync_derpy_hub.py",
    # Each race's own panel and card (gen_guilds_ui.FRAMES) - text, naming CA art by path.
    *[_UI + "derpy_gg_%s_%s.twui.xml" % (kind, race)
      for race in ("brt", "cth", "def", "dwf", "emp", "hef", "ksl", "skv")
      for kind in ("panel", "card")],
    # The same files at MCT's Small and Large panel sizes (gen_guilds_ui.SIZES). Their resized
    # CA art (derpy_gg_sized, ui/skins/*/derpy_gg_*) is art, so it stays out with the rest.
    *[_UI + "derpy_gg_%s%s_%s.twui.xml" % (kind, race, sfx)
      for sfx in ("sm", "lg")
      for race in ("", "_brt", "_cth", "_def", "_dwf", "_emp", "_hef", "_ksl", "_skv")
      for kind in ("panel", "card")],
    *[_UI + "derpy_gg_%s_%s.twui.xml" % (kind, sfx)
      for sfx in ("sm", "lg") for kind in ("row", "list", "frow")],
    # NO ART. The icons (derpy_gg_icons, and CA's originals in source/guild_icons) and the
    # panel grounds (derpy_gg_bg) are all derived from Creative Assembly's art, so none of
    # it goes into the public repo - the user's call, 2026-09-23. It ships in the pack only.
    "Modding Files/source/great_guilds",
    "tools/_guilds_harness.lua",
    "tools/_guilds_bounty_harness.lua",
    "tools/mutate_guilds.py",
    "tools/gen_great_guilds.py",
    "tools/gen_guilds_ui.py",
    "tools/gen_guilds_emitter.py",
    "tools/check_guilds_ui.py",
    "tools/check_guilds_anchor.py",
    "tools/preview_guilds_panel.py",
    "tools/import_great_guilds.py",
    "tools/make_guild_icons.py",
    "tools/make_guild_backgrounds.py",
    "tools/make_guild_bundle_icons.py",
    "tools/read_pack_index.py",
    "tools/read_vanilla_cache.py",
    "tools/read_vanilla_db.py",
    "tools/read_vanilla_loc.py",
    "tools/rpfm_client.py",
]] + [
    ("docs/superpowers/specs/2026-09-10-great-guilds-design.md",
     "docs/design/2026-09-10-great-guilds-design.md"),
    ("docs/superpowers/specs/2026-09-23-great-guilds-flavours-design.md",
     "docs/design/2026-09-23-great-guilds-flavours-design.md"),
    ("docs/superpowers/plans/2026-09-10-great-guilds-ladder.md",
     "docs/plans/2026-09-10-great-guilds-ladder.md"),
    ("docs/superpowers/plans/2026-09-10-great-guilds-panel.md",
     "docs/plans/2026-09-10-great-guilds-panel.md"),
    ("docs/superpowers/plans/2026-09-10-great-guilds-ai.md",
     "docs/plans/2026-09-10-great-guilds-ai.md"),
    ("docs/superpowers/plans/2026-09-12-great-guilds-notices.md",
     "docs/plans/2026-09-12-great-guilds-notices.md"),
    ("docs/superpowers/plans/2026-09-23-great-guilds-flavours.md",
     "docs/plans/2026-09-23-great-guilds-flavours.md"),
    ("docs/sessions/HANDOFF_20260910_GREAT_GUILDS_DESIGN.md",
     "docs/history/HANDOFF_20260910_GREAT_GUILDS_DESIGN.md"),
    ("docs/sessions/HANDOFF_20260916_GUILDS_LEAD_FLICKER_RIVALRY_FLOOR_AND_SAVE_LOAD.md",
     "docs/history/HANDOFF_20260916_GUILDS_LEAD_FLICKER_RIVALRY_FLOOR_AND_SAVE_LOAD.md"),
    ("docs/sessions/HANDOFF_20260923_GUILDS_AUDIT_BUILDING_EARN_AND_LOG_TAB.md",
     "docs/history/HANDOFF_20260923_GUILDS_AUDIT_BUILDING_EARN_AND_LOG_TAB.md"),
    ("docs/sessions/HANDOFF_20260923_GUILDS_FLAVOURS.md",
     "docs/history/HANDOFF_20260923_GUILDS_FLAVOURS.md"),
    ("docs/sessions/HANDOFF_20260924_GUILDS_UI_SCALE.md",
     "docs/history/HANDOFF_20260924_GUILDS_UI_SCALE.md"),
    ("docs/sessions/HANDOFF_20260924_GUILDS_GENERIC_AI_MP.md",
     "docs/history/HANDOFF_20260924_GUILDS_GENERIC_AI_MP.md"),
    ("docs/superpowers/specs/2026-09-24-great-guilds-brt-cth-ksl-design.md",
     "docs/design/2026-09-24-great-guilds-brt-cth-ksl-design.md"),
    ("docs/sessions/HANDOFF_20260924_GUILDS_BRT_CTH_KSL.md",
     "docs/history/HANDOFF_20260924_GUILDS_BRT_CTH_KSL.md"),
    ("docs/superpowers/specs/2026-09-24-great-guilds-def-hef-design.md",
     "docs/design/2026-09-24-great-guilds-def-hef-design.md"),
    ("docs/sessions/HANDOFF_20260924_GUILDS_DEF_HEF_GATE.md",
     "docs/history/HANDOFF_20260924_GUILDS_DEF_HEF_GATE.md"),
    ("docs/sessions/HANDOFF_20260924_GUILDS_BUILDING_LINE_LEDGER.md",
     "docs/history/HANDOFF_20260924_GUILDS_BUILDING_LINE_LEDGER.md"),
    ("docs/sessions/HANDOFF_20260925_GUILDS_MP_MCT.md",
     "docs/history/HANDOFF_20260925_GUILDS_MP_MCT.md"),
    ("docs/sessions/HANDOFF_20260925_GUILDS_QOL.md",
     "docs/history/HANDOFF_20260925_GUILDS_QOL.md"),
    ("docs/sessions/HANDOFF_20261001_HUD_HUB_PLAN.md",
     "docs/history/HANDOFF_20261001_HUD_HUB_PLAN.md"),
    ("docs/superpowers/specs/2026-09-27-great-guilds-bounties-v2-design.md",
     "docs/design/2026-09-27-great-guilds-bounties-v2-design.md"),
    ("docs/superpowers/plans/2026-09-27-great-guilds-bounties-v2.md",
     "docs/plans/2026-09-27-great-guilds-bounties-v2.md"),
    ("docs/sessions/HANDOFF_20260927_GUILDS_BOUNTIES_V2.md",
     "docs/history/HANDOFF_20260927_GUILDS_BOUNTIES_V2.md"),
    ("docs/sessions/HANDOFF_20260928_GUILDS_BAR_AND_REACHABLE_JOBS.md",
     "docs/history/HANDOFF_20260928_GUILDS_BAR_AND_REACHABLE_JOBS.md"),
    ("docs/superpowers/specs/2026-09-29-great-guilds-ai-bounties-design.md",
     "docs/design/2026-09-29-great-guilds-ai-bounties-design.md"),
    ("docs/superpowers/plans/2026-09-29-great-guilds-ai-bounties.md",
     "docs/plans/2026-09-29-great-guilds-ai-bounties.md"),
    ("docs/sessions/HANDOFF_20260929_GUILDS_AI_BOUNTIES.md",
     "docs/history/HANDOFF_20260929_GUILDS_AI_BOUNTIES.md"),
    ("docs/superpowers/specs/2026-09-29-great-guilds-service-pools-and-races-design.md",
     "docs/design/2026-09-29-great-guilds-service-pools-and-races-design.md"),
    ("docs/superpowers/plans/2026-09-29-great-guilds-service-pools-stage1.md",
     "docs/plans/2026-09-29-great-guilds-service-pools-stage1.md"),
    ("docs/sessions/HANDOFF_20260929_GUILDS_POOLS_STAGE1.md",
     "docs/history/HANDOFF_20260929_GUILDS_POOLS_STAGE1.md"),
    ("docs/superpowers/plans/2026-09-29-great-guilds-stage2-race-mechanics.md",
     "docs/plans/2026-09-29-great-guilds-stage2-race-mechanics.md"),
    ("docs/sessions/HANDOFF_20260929_GUILDS_STAGE2_RACES.md",
     "docs/history/HANDOFF_20260929_GUILDS_STAGE2_RACES.md"),
    ("docs/sessions/HANDOFF_20260929_GUILDS_LOGIC_AUDIT.md",
     "docs/history/HANDOFF_20260929_GUILDS_LOGIC_AUDIT.md"),
    ("docs/sessions/HANDOFF_20260930_GUILDS_PANEL_POLISH.md",
     "docs/history/HANDOFF_20260930_GUILDS_PANEL_POLISH.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_UI_POLISH_PREVIEW.md",
     "docs/history/HANDOFF_20261004_GUILDS_UI_POLISH_PREVIEW.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_GLOW_PULSE.md",
     "docs/history/HANDOFF_20261004_GUILDS_GLOW_PULSE.md"),
    ("docs/superpowers/specs/2026-10-04-great-guilds-halls-design.md",
     "docs/design/2026-10-04-great-guilds-halls-design.md"),
    ("docs/superpowers/plans/2026-10-04-great-guilds-halls-stage1.md",
     "docs/plans/2026-10-04-great-guilds-halls-stage1.md"),
    ("docs/superpowers/plans/2026-10-04-great-guilds-halls-stage2.md",
     "docs/plans/2026-10-04-great-guilds-halls-stage2.md"),
    ("docs/superpowers/specs/2026-10-04-great-guilds-temple-guild-design.md",
     "docs/design/2026-10-04-great-guilds-temple-guild-design.md"),
    ("docs/superpowers/plans/2026-10-04-great-guilds-temple-guild.md",
     "docs/plans/2026-10-04-great-guilds-temple-guild.md"),
    ("docs/superpowers/specs/2026-10-05-great-guilds-skaven-design.md",
     "docs/design/2026-10-05-great-guilds-skaven-design.md"),
    ("docs/superpowers/plans/2026-10-05-great-guilds-skaven.md",
     "docs/plans/2026-10-05-great-guilds-skaven.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_DOCS_PUSH_AND_HALLS_BRAINSTORM.md",
     "docs/history/HANDOFF_20261004_GUILDS_DOCS_PUSH_AND_HALLS_BRAINSTORM.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_HALLS_STAGE1.md",
     "docs/history/HANDOFF_20261004_GUILDS_HALLS_STAGE1.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_HALLS_STAGE2.md",
     "docs/history/HANDOFF_20261004_GUILDS_HALLS_STAGE2.md"),
    ("docs/sessions/HANDOFF_20261004_GUILDS_TEMPLE.md",
     "docs/history/HANDOFF_20261004_GUILDS_TEMPLE.md"),
    ("docs/sessions/HANDOFF_20261005_GUILDS_SKAVEN.md",
     "docs/history/HANDOFF_20261005_GUILDS_SKAVEN.md"),
    ("docs/sessions/HANDOFF_20261007_GUILDS_TEXT_HUMANIZE_CODEX.md",
     "docs/history/HANDOFF_20261007_GUILDS_TEXT_HUMANIZE_CODEX.md"),
    ("docs/sessions/CODEX_GUILDS_TEXT_REPORT_20261007.md",
     "docs/history/CODEX_GUILDS_TEXT_REPORT_20261007.md"),
    ("docs/sessions/HANDOFF_20261007_GUILDS_TEXT_HUMANIZE_CLAUDE.md",
     "docs/history/HANDOFF_20261007_GUILDS_TEXT_HUMANIZE_CLAUDE.md"),
    ("docs/superpowers/specs/2026-10-09-great-guilds-temple-lore-design.md",
     "docs/design/2026-10-09-great-guilds-temple-lore-design.md"),
    ("docs/superpowers/plans/2026-10-09-great-guilds-temple-lore.md",
     "docs/plans/2026-10-09-great-guilds-temple-lore.md"),
    ("anti-slop/audit-001-2026-10-09.md", "docs/history/ANTISLOP_AUDIT_001_20261009.md"),
    ("anti-slop/audit-001-fixlog.md", "docs/history/ANTISLOP_AUDIT_001_FIXLOG.md"),
]


def pairs(root=ROOT, repo=REPO, manifest=None):
    """Every (source file, destination file), folders expanded one level.

    `manifest` defaults to this file's; sync_iron_court_repo.py passes its own.
    """
    out = []
    for src, dst in (manifest or MANIFEST):
        s, d = os.path.join(root, src), os.path.join(repo, dst)
        if os.path.isdir(s):
            for name in sorted(os.listdir(s)):
                if os.path.isfile(os.path.join(s, name)):
                    out.append((os.path.join(s, name), os.path.join(d, name)))
        else:
            out.append((s, d))
    return out


def drift(root=ROOT, repo=REPO, manifest=None):
    """[(src, dst, why)] for every file the repo does not hold byte for byte."""
    out = []
    for s, d in pairs(root, repo, manifest):
        if not os.path.isfile(s):
            out.append((s, d, "missing in workspace"))
        elif not os.path.isfile(d):
            out.append((s, d, "new"))
        elif not filecmp.cmp(s, d, shallow=False):
            out.append((s, d, "changed"))
    return out


def sync(root=ROOT, repo=REPO, manifest=None):
    found = drift(root, repo, manifest)
    for s, d, why in found:
        if why == "missing in workspace":
            continue
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(s, d)
    return found


def _selftest():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root, repo = os.path.join(tmp, "ws"), os.path.join(tmp, "repo")
        for s, _d in pairs(root, repo):
            os.makedirs(os.path.dirname(s), exist_ok=True)
        # One real file per manifest entry is enough to prove the mapping.
        for src, _dst in MANIFEST:
            p = os.path.join(root, src)
            if not os.path.splitext(src)[1]:
                os.makedirs(p, exist_ok=True)
                p = os.path.join(p, "a.png")
            with open(p, "w") as f:
                f.write(src)
        assert all(w == "new" for _s, _d, w in drift(root, repo))
        sync(root, repo)
        assert drift(root, repo) == [], "a synced repo still drifts"
        target = os.path.join(repo, "docs", "history",
                              "HANDOFF_20260910_GREAT_GUILDS_DESIGN.md")
        assert os.path.isfile(target), "a remapped doc did not land at its repo path"
        with open(os.path.join(root, "tools", "gen_great_guilds.py"), "a") as f:
            f.write("x")
        assert [w for _s, _d, w in drift(root, repo)] == ["changed"]
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    elif "--check" in sys.argv:
        found = drift()
        for s, _d, why in found:
            print("%-22s %s" % (why, os.path.relpath(s, ROOT)))
        print("%d file(s) drift" % len(found))
        sys.exit(1 if found else 0)
    else:
        found = sync()
        for s, _d, why in found:
            print("%-22s %s" % (why, os.path.relpath(s, ROOT)))
        print("synced %d file(s) into %s" % (len(found), REPO))
