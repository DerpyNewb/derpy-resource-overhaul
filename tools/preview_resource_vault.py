# -*- coding: utf-8 -*-
"""Render the Resource Vault panel to one PNG per tab, with the game shut.

WHY. The Spending and Map tabs shipped on 2026-10-03 with both tabs drawn in the panel's top
corner, over the title: every numeric check passed, because each checked a box it was given,
and nobody had looked at a picture. This draws the picture.

WHAT IS REAL. The positions, sizes, text, alignment, images set at runtime and visibility are
the SHIPPED Lua's own: tools/_resource_overhaul_stores_harness.lua runs the generated stores
script against components built from our .twui.xml files, and with MR_DUMP set it writes every
visible component at each point named in TABS, where that tab holds its most telling demo
contents. A box with clipchildren cuts what is inside it, as the engine's does. The ART is CA's
(the campaign minimaps out of data_maps.pack, or IEE's own pack), rasterised by TWUI Studio
through preview_guilds_panel.py's helpers.

WHAT IS NOT. Glyphs are Segoe UI, so widths are close, not exact; the world is the harness's
demo (two or three settlements at made-up positions). A component the script never moves is
drawn where the stub left it, which is the bug this exists to show.

    py tools/preview_resource_vault.py              # .skilltree_cache/ui_preview/mr_<tab>.png
    py tools/preview_resource_vault.py --selftest   # every tab dumped, no tab on anything else
"""
import importlib.util
import io
import math
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import preview_guilds_panel as PG                                    # noqa: E402

PREFIX = "derpy_mr_stores_"
TABS = ("goods", "goods_focus", "settlements", "settlement_focus", "trade", "spending", "escort", "workshop", "workshop_focus", "workshop_folded", "map",
        "map_wh3_main_combi", "map_cr_combi_expanded", "map_wh3_main_chaos")
# Where a campaign's minimap is: CA's data_maps.pack, or the map mod's own pack (IEE).
MAP_PACKS = (os.path.join(PG.GAME, "data_maps.pack"),
             os.path.join(os.path.dirname(os.path.dirname(PG.GAME)), "..", "workshop", "content", "1142710",
                          "3007996493", "!cr_immortal_empires_expanded.pack"))
SCREEN = (1920, 1080)
FONT = "C:/Windows/Fonts/segoeui.ttf"


def _gen():
    spec = importlib.util.spec_from_file_location("gen_mr_ui", os.path.join(ROOT, "tools", "gen_mr_ui.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def snapshot():
    """{tab: [component dicts in drawing order]} from the harness's MR_DUMP."""
    gen = _gen()
    out = tempfile.mkdtemp()
    os.environ["MR_DUMP"] = out.replace(os.sep, "/")
    try:
        code, text = gen.run_harness()
    finally:
        del os.environ["MR_DUMP"]
    if code != 0 or "harness ok" not in text:
        raise SystemExit("the stores harness failed:\n" + text)
    got = {}
    for tab in TABS:
        rows = []
        for line in io.open(os.path.join(out, tab + ".tsv"), encoding="utf-8"):
            f = line.rstrip("\n").split("\t")
            rows.append(dict(depth=int(f[0]), file=f[1], xid=f[2], name=f[3], x=float(f[4]), y=float(f[5]),
                             w=None if f[6] == "nil" else float(f[6]), h=None if f[7] == "nil" else float(f[7]),
                             text=f[8], img=f[9] or None, tip=f[10], parent=f[11], halign=f[12] or None,
                             rot=float(f[13]) if len(f) > 13 and f[13] else 0.0))
        got[tab] = rows
    return got


def _docs():
    """(file, component id) -> (component, standard state), for every one of our files."""
    model, _r = PG._studio()
    out = {}
    for fn in PG.our_files(PREFIX):
        d = model.Document(io.open(os.path.join(PG.OURS, fn), encoding="utf-8").read())
        for c in d.components:
            out[(fn[:-len(".twui.xml")], c.get("id", c.tag))] = (c, d.state(c))
    return out


def art_path(p):
    """Where a picture is on disk: CA's ui art in PG.UI, a campaign minimap beside it."""
    if p.startswith("ui/"):
        return os.path.join(PG.UI, os.path.relpath(p, "ui").replace("/", os.sep))
    return os.path.join(PG.CACHE, p.replace("/", os.sep))


def fetch_maps(paths):
    """The campaign minimaps the dumps name, out of MAP_PACKS, once. Returns those not found."""
    from read_pack_index import read
    from read_vanilla_loc import _decompress
    missing = []
    for p in paths:
        dest = art_path(p)
        if os.path.isfile(dest):
            continue
        data = b""
        for pk in MAP_PACKS:
            if os.path.isfile(pk):
                for _p, comp, blob in read(pk, p):
                    data = _decompress(blob) if comp else blob
            if data:
                break
        if data[:4] != b"\x89PNG":
            missing.append(p)
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        io.open(dest, "wb").write(data)
    return missing


def _rgba(hexs, default=(255, 248, 215, 255)):
    if not hexs or not hexs.startswith("#") or len(hexs) != 9:
        return default
    return tuple(int(hexs[i:i + 2], 16) for i in (1, 3, 5, 7))


def render(tab, comps, docs, path=None):
    from PIL import Image, ImageDraw, ImageFont
    from pathlib import Path
    _model, rendering = PG._studio()
    canvas = Image.new("RGBA", SCREEN, (40, 36, 30, 255))
    fonts = {}

    def font(size):
        if size not in fonts:
            fonts[size] = ImageFont.truetype(FONT, size)
        return fonts[size]

    # THE CLIP STACK: what is inside a clipchildren box draws on that box's own layer, cut to the
    # box and laid on the layer below when the box's last child is drawn.
    stack = [(-1, None, canvas)]

    def close_to(depth):
        while len(stack) > 1 and stack[-1][0] >= depth:
            _d, (x, y, w, h), layer = stack.pop()
            cut = Image.new("RGBA", SCREEN, (0, 0, 0, 0))
            box = (int(x), int(y), int(x + w), int(y + h))
            cut.paste(layer.crop(box), box[:2])
            stack[-1][2].alpha_composite(cut)

    for c in comps:
        close_to(c["depth"])
        comp, st = docs.get((c["file"], c["xid"]), (None, None))
        if st is None:
            continue
        target = stack[-1][2]
        draw = ImageDraw.Draw(target)
        w = c["w"] if c["w"] is not None else float(st.get("width") or 0)
        h = c["h"] if c["h"] is not None else float(st.get("height") or 0)
        images = {}
        box = comp.child("componentimages")
        if box is not None:
            for n in box.children:
                images[n.get("this")] = n.get("imagepath")
        metrics = st.child("imagemetrics")
        for i, n in enumerate(metrics.children if metrics is not None else ()):
            p = c["img"] if i == 0 and c["img"] else images.get(n.get("componentimage"))
            if not p or not os.path.isfile(art_path(p)):
                continue
            xw, xh = float(st.get("width") or w), float(st.get("height") or h)
            iw, ih = float(n.get("width") or xw), float(n.get("height") or xh)
            if abs(iw - xw) < 1 and abs(ih - xh) < 1:
                iw, ih, ox, oy = w, h, 0, 0
            else:
                ox, oy = (w - iw) / 2, (h - ih) / 2
            img = rendering.raster(Path(art_path(p)), max(1, int(iw)), max(1, int(ih)), n)
            # SetImageRotation turns image 0 clockwise in radians (CA's lib_text_pointers); PIL's
            # rotate is counter-clockwise in degrees, about the centre, as the engine pivots by default
            if i == 0 and c.get("rot"):
                img = img.rotate(-math.degrees(c["rot"]), resample=Image.BICUBIC)
            target.alpha_composite(img, (int(c["x"] + ox), int(c["y"] + oy)))
        ct = st.child("component_text")
        if c["text"] and ct is not None:
            size = int(float(ct.get("font_m_size") or 12))
            f = font(size)
            plain = PG.MARKUP.sub("", c["text"])
            tw = draw.textlength(plain, font=f)
            align = (c["halign"] or ct.get("texthalign") or "Left").lower()
            x = c["x"] if align == "left" else (c["x"] + w - tw if align == "right" else c["x"] + (w - tw) / 2)
            draw.text((max(x, c["x"]), c["y"] + (h - size) / 2 - 3), plain, fill=_rgba(ct.get("font_m_colour")),
                      font=f)
        if comp.get("clipchildren") == "true":
            stack.append((c["depth"], (c["x"], c["y"], w, h), Image.new("RGBA", SCREEN, (0, 0, 0, 0))))
    close_to(0)
    pnl = comps[0]
    pw, ph = pnl["w"] or 0, pnl["h"] or 0
    crop = canvas.crop((int(pnl["x"]) - 40, int(pnl["y"]) - 40, int(pnl["x"] + pw) + 40, int(pnl["y"] + ph) + 40))
    out = path or os.path.join(PG.CACHE, "mr_%s.png" % tab)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    crop.convert("RGB").save(out)
    return out


def tab_faults(comps):
    """Every tab button drawn, none on another tab or on anything else at the panel's top level.
    Returns a list of faults."""
    pnl = comps[0]
    top = [c for c in comps if c["depth"] == 1 and c["w"] is not None]
    tabs = [c for c in top if c["name"].startswith("derpy_mr_tab_")]
    out = []
    want = sum(1 for k in _gen().L if k.startswith("tab_"))   # the layout's tabs, not a typed count
    if len(tabs) != want:
        out.append("%d tabs drawn, not %d" % (len(tabs), want))
    for t in tabs:
        for o in top:
            if o is t or o["w"] >= pnl["w"] - 1:
                continue
            if (t["x"] < o["x"] + o["w"] and o["x"] < t["x"] + t["w"]
                    and t["y"] < o["y"] + o["h"] and o["y"] < t["y"] + t["h"]):
                out.append("%s overlaps %s" % (t["name"], o["name"]))
    return out


def selftest():
    got = snapshot()
    fails = []
    for tab in TABS:
        if not got[tab] or got[tab][0]["name"] != "derpy_mr_stores_panel":
            fails.append("%s: no panel dumped" % tab)
            continue
        fails += ["%s: %s" % (tab, f) for f in tab_faults(got[tab])]
    # the check can fail: a Map tab dropped onto the title is reported
    probe = [dict(c) for c in got["map"]]
    for c in probe:
        if c["name"] == "derpy_mr_tab_map":
            c["x"], c["y"] = probe[0]["x"] + 16, probe[0]["y"] + 8
    if not any("derpy_mr_tab_map" in f for f in tab_faults(probe)):
        fails.append("a Map tab moved onto the title is not reported")
    for f in fails:
        print("FAIL", f)
    print("preview_resource_vault selftest %s: %d views" % ("ok" if not fails else "FAILED", len(TABS)))
    return not fails


def main(argv):
    if "--selftest" in argv:
        return 0 if selftest() else 1
    got = snapshot()
    docs = _docs()
    imgs = {c["img"] for cs in got.values() for c in cs if c["img"]}
    _n, missing = PG.extract_art(PREFIX, sorted(p for p in imgs if p.startswith("ui/")))
    missing += fetch_maps(sorted(p for p in imgs if not p.startswith("ui/")))
    for p in missing:
        print("missing art:", p)
    for tab in TABS:
        print(render(tab, got[tab], docs), " ".join(tab_faults(got[tab])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
