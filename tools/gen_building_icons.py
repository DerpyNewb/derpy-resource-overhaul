"""The rare-good buildings' icons (Derpy Resource Overhaul), in CA's resource-building style.

    py tools/gen_building_icons.py                  # draw any missing glyph, then compose all
    py tools/gen_building_icons.py gromril feathers # (re)draw just these glyphs, then compose
    py tools/gen_building_icons.py --compose        # compose from the glyphs on disk only
    py tools/gen_building_icons.py --check          # measure the shipped icons against CA's
    py tools/gen_building_icons.py --selftest

CA's resource-building icons (ui/buildings/icons/, 74x74) are ONE flat colour, (85,31,0), at
alpha ~200 - never 255 - on transparency: a race frame (Dwarf chains, High Elf horns, ...)
around a solid cog, with the resource cut into the cog as a solid glyph ringed by a
transparent gap. The race-neutral ones (resource_wood, resource_furs) are the glyph alone, a
silhouette with its detail cut in as transparent lines.

So: Codex draws each glyph as a black stencil on white, with CA's own generic glyphs as the
style reference (painted art run through edge detection gave speckle, not lines). This script
then takes the race frame from CA's own icon - RARE[good]["frame"] in gen_resource_overhaul -
fills its cog solid, and cuts the glyph in. Colour and alpha are read off that CA icon, so a
shipped icon matches its frame exactly.

Writes Modding Files/source/building_icons/raw/<good>.png (what Codex drew) and
Modding Files/pack/ui/buildings/icons/derpy_mr_bld_<good>.png (what ships).
"""
import io
import os
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_commodity_icons as gci       # noqa: E402  the Codex driver
import gen_resource_overhaul as gmr        # noqa: E402  RARE: goods, frames, chain keys
import read_pack_index as rpi           # noqa: E402
import read_vanilla_loc as rvl          # noqa: E402

UI = os.path.join(os.path.dirname(gmr.rvd.DB_PACK), "ui.pack")
RAW = os.path.join(gmr.ROOT, "Modding Files", "source", "building_icons", "raw")
N, S = 74, 4           # CA's size; work at 4x and box-downsample so the cuts anti-alias
CUT = 1.4              # the gap ringing a glyph in its cog, in 74px pixels
FILL = 0.66            # glyph size / cog size, measured off CA's ingot and oval
NEUTRAL = "resource_gold"   # colour and alpha for a frameless icon
STYLE = ("resource_wood", "resource_furs", "resource_gems", "resource_ivory", "resource_medicine",
         "resource_iron", "resource_dyes", "resource_spices", "resource_wine", "resource_pottery")

GLYPHS = {
    "gromril": "a squat trapezoid ingot of dwarf metal, seen from slightly above, with one angular "
               "dwarf rune cut into its top face",
    "ithilmar": "a tall slender elven ingot with a pointed arched top and a single flowing elven rune",
    "dragon_bone": "a horned dragon skull in side profile, jaws slightly open, two swept-back horns",
    "sea_dragon_hide": "a scaly sea dragon hide stretched flat, with a spiny fin along one edge and "
                       "the scales drawn as rows of cut lines",
    "black_lotus": "a single lotus flower in full bloom, pointed petals, seen from the side",
    "starwood": "a short length of slender branch with three leaves sprouting from it and a small "
                "four-pointed star on the bark",
    "feathers": "two large long feathers crossed at the quills, vanes drawn with a few cut lines",
    "wyvern_scales": "five large pointed scales overlapping in a fan",
}

PROMPT = """Use the built-in image_gen tool (not the CLI fallback). Do not run shell commands
and do not copy files.

The attached image is a strip of existing building emblems from Total War: WARHAMMER III. Each
is a flat single-colour STENCIL: one solid silhouette, its details cut out as thin white lines.
It is a STYLE REFERENCE only.

Generate ONE new emblem in exactly that style:
Subject: {subject}
Style: flat stencil, pure black (#000000) shape on a pure white (#FFFFFF) background. No grey,
no shading, no gradient, no texture. Interior detail ONLY as clean white cut lines, few and
bold, each about 2% of the canvas wide.
Composition: the subject centred, filling about 85% of a square canvas, a chunky silhouette
that still reads at 32 pixels.
Avoid: text, letters, a frame or border, a circle behind it, extra objects, thin floating bits.

Reply with the full path of the saved image only."""


def ca(name):
    for _p, _c, data in rpi.read(UI, "ui/buildings/icons/%s.png" % name):
        try:
            data = rvl._decompress(data)
        except Exception:   # some ui art is stored uncompressed
            pass
        return Image.open(io.BytesIO(data)).convert("RGBA")
    raise KeyError(name)


def ink(im):
    """CA's colour and top alpha: the commonest colour among the opaque pixels, and max alpha."""
    px = [p[:3] for p in im.get_flattened_data() if p[3] > 150]
    return max(set(px), key=px.count), max(im.getchannel("A").get_flattened_data())


def odd(n):
    n = max(1, int(round(n)))
    return n if n % 2 else n + 1


def fill_holes(mask):
    bg = mask.copy()
    ImageDraw.floodfill(bg, (0, 0), 128)
    return bg.point(lambda v: 0 if v == 128 else 255)


def cog(frame, top):
    """The frame's alpha with its cog made solid (CA's glyph gone), and the cog's box."""
    a = frame.getchannel("A")
    comp = fill_holes(a.point(lambda v: 255 if v > 60 else 0))
    ImageDraw.floodfill(comp, (N // 2, N // 2 + 3), 77)          # the component under the centre
    comp = comp.point(lambda v: 255 if v == 77 else 0)
    solid = ImageChops.lighter(a, comp.filter(ImageFilter.MinFilter(3)).point(lambda v: top if v else 0))
    return solid, comp.getbbox()


def stencil(good, size):
    """The glyph Codex drew: black on white -> a mask, cropped and scaled to size."""
    im = Image.open(os.path.join(RAW, good + ".png")).convert("RGBA")
    flat = Image.new("RGBA", im.size, (255, 255, 255, 255))
    flat.alpha_composite(im)                                     # transparent counts as white
    mask = flat.convert("L").point(lambda v: 255 if v < 128 else 0)
    mask = mask.crop(mask.getbbox())
    k = size / max(mask.size)
    return mask.resize((max(1, round(mask.width * k)), max(1, round(mask.height * k))), Image.LANCZOS) \
               .point(lambda v: 255 if v > 127 else 0)


def compose(good):
    frame_name = gmr.RARE[good]["frame"]
    ref = ca(frame_name or NEUTRAL)
    col, top = ink(ref)
    if frame_name:
        solid, box = cog(ref, top)
        base = solid.resize((N * S, N * S), Image.BICUBIC)
        cx, cy = (box[0] + box[2]) / 2 * S, (box[1] + box[3]) / 2 * S
        size = min(box[2] - box[0], box[3] - box[1]) * FILL * S
    else:
        base, cx, cy, size = None, N * S / 2, N * S / 2, N * S * 0.86
    g = stencil(good, int(size))
    glyph = Image.new("L", (N * S, N * S), 0)
    glyph.paste(g, (int(cx - g.width / 2), int(cy - g.height / 2)))
    if base is None:   # the stencil alone, its cut lines included
        a = glyph.point(lambda v: top if v else 0)
    else:              # solid cog, minus a gap around the glyph's outline, minus its cut lines
        body = fill_holes(glyph)
        ring = ImageChops.subtract(body.filter(ImageFilter.MaxFilter(odd(S * CUT * 2))), body)
        a = ImageChops.subtract(base, ImageChops.lighter(ring, ImageChops.subtract(body, glyph)))
    out = Image.new("RGBA", (N, N), col + (0,))
    out.putalpha(a.resize((N, N), Image.BOX).point(lambda v: min(v, top)))   # bicubic overshoots
    return out


def shipped(good):
    return os.path.join(gmr.PACK, *gmr.bld_icon(good).split("/"))


def compose_all():
    for good in gmr.RARE:
        out = compose(good)
        os.makedirs(os.path.dirname(shipped(good)), exist_ok=True)
        out.save(shipped(good))
    print("composed", len(gmr.RARE), "icons into", os.path.dirname(shipped(next(iter(gmr.RARE)))))


def measure(im, frame_name):
    """What check() compares: size, colour, top alpha, and the share of the cog the glyph cut."""
    col, top = ink(ca(frame_name or NEUTRAL))
    a = im.getchannel("A")
    px = [p for p in im.get_flattened_data() if p[3] > 0]
    return dict(size=im.size, colours={p[:3] for p in px}, top=max(a.get_flattened_data()),
                want_colour=col, want_top=top,
                cut=sum(1 for v in a.get_flattened_data() if v == 0) / float(N * N))


def check(icons=None):
    bad = []
    for good in gmr.RARE:
        im = (icons or {}).get(good) or Image.open(shipped(good)).convert("RGBA")
        m = measure(im, gmr.RARE[good]["frame"])
        if m["size"] != (N, N):
            bad.append("%s: %s, not %dx%d" % (good, m["size"], N, N))
        if m["colours"] != {m["want_colour"]}:
            bad.append("%s: colours %s, CA's is %s" % (good, sorted(m["colours"])[:3], m["want_colour"]))
        if abs(m["top"] - m["want_top"]) > 2:
            bad.append("%s: top alpha %d, CA's is %d" % (good, m["top"], m["want_top"]))
        # in a cog, a missing cut means the glyph never landed; frameless, an empty icon
        ref = measure(ca(gmr.RARE[good]["frame"] or NEUTRAL), gmr.RARE[good]["frame"])
        if abs(m["cut"] - ref["cut"]) > 0.25:
            bad.append("%s: %.0f%% transparent, CA's frame is %.0f%%" % (good, 100 * m["cut"], 100 * ref["cut"]))
    for b in bad:
        print(b)
    print("check: %d finding(s) over %d icons" % (len(bad), len(gmr.RARE)))
    return not bad


def selftest():
    icons = {g: compose(g) for g in gmr.RARE}
    assert check(icons), "the composed icons fail their own check"
    g = next(iter(gmr.RARE))
    for breakit, why in ((lambda im: im.resize((64, 64)), "wrong size"),
                         (lambda im: Image.merge("RGBA", (*Image.new("RGB", im.size, (200, 0, 0)).split(),
                                                         im.getchannel("A"))), "wrong colour"),
                         (lambda im: Image.merge("RGBA", (*im.convert("RGB").split(),
                                                         im.getchannel("A").point(lambda v: 255 if v else 0))),
                          "full alpha")):
        if check(dict(icons, **{g: breakit(icons[g])})):
            raise SystemExit("selftest: check passed an icon with %s" % why)
    # the cog really was emptied: a composed frame with no glyph has no transparent pixel inside it
    solid, box = cog(ca("dwarf_gold"), ink(ca("dwarf_gold"))[1])
    cx, cy, r = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2, (box[2] - box[0]) // 4   # a round cog's
    inside = solid.crop((cx - r, cy - r, cx + r, cy + r)).get_flattened_data()          # middle, not corners
    raw_inside = ca("dwarf_gold").getchannel("A").crop((cx - r, cy - r, cx + r, cy + r)).get_flattened_data()
    assert min(raw_inside) < 100, "probe misplaced: CA's own cog shows no glyph there"
    assert min(inside) > 150, "the cog still shows CA's glyph"
    print("selftest ok")


def draw(names):
    os.makedirs(RAW, exist_ok=True)
    work = tempfile.mkdtemp(prefix="bldicon_")
    sheet = os.path.join(work, "ca_reference.png")
    strip = Image.new("RGBA", (222 * len(STYLE), 222), (255, 255, 255, 255))
    for i, n in enumerate(STYLE):   # CA's glyphs as black stencils on white, what we ask for
        a = ca(n).getchannel("A").point(lambda v: 255 if v > 100 else 0).resize((222, 222), Image.LANCZOS)
        strip.paste((0, 0, 0, 255), (i * 222, 0), a)
    strip.save(sheet)
    exe = gci.codex_exe()

    # generate() reads its subject, prompt and output folder from module globals and resizes
    # into large/small: point it at ours for the whole run, skip the resize, and put them back
    real = (gci.ICONS, gci.OUT, gci.PROMPT, gci.resize)
    gci.ICONS, gci.OUT, gci.PROMPT, gci.resize = GLYPHS, os.path.dirname(RAW), PROMPT, (lambda _n: None)
    try:
        with ThreadPoolExecutor(4) as pool:
            for name, status in pool.map(lambda n: gci.generate(n, exe, sheet, work), names):
                print(name, status, flush=True)
    finally:
        gci.ICONS, gci.OUT, gci.PROMPT, gci.resize = real


def main(args):
    if "--selftest" in args:
        return selftest()
    if "--check" in args:
        return 0 if check() else 1
    if "--compose" not in args:
        unknown = [a for a in args if a not in GLYPHS]
        if unknown:
            sys.exit("unknown glyph(s): %s" % unknown)
        assert set(GLYPHS) == set(gmr.RARE), set(GLYPHS) ^ set(gmr.RARE)
        names = args or [g for g in GLYPHS if not os.path.exists(os.path.join(RAW, g + ".png"))]
        if names:
            draw(names)
    compose_all()
    return 0 if check() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
