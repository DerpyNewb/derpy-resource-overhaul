"""Generate new Zharr Exchange commodity icons with the Codex CLI bundled in the VS Code
ChatGPT extension, styled after CA's own commodity icons.

    py tools/gen_commodity_icons.py                 # every icon not already generated
    py tools/gen_commodity_icons.py brimstone coal  # (re)generate just these
    py tools/gen_commodity_icons.py --resize        # redo 54/24 from the raw files only
    py tools/gen_commodity_icons.py --check         # measure 54/24 against CA's set
    py tools/gen_commodity_icons.py --selftest

The 54/24 files are cropped, toned down and given CA's black halo, all fitted to CA's own
icons (see SIZES); raw/ stays exactly what Codex drew.

Writes Modding Files/source/exchange_icons/new_commodities/{raw,large,small}/<name>.png.
Codex must run with -s read-only: workspace-write fails on this machine's unelevated Windows
sandbox and generates nothing. So Codex only draws; this script copies the file out of
~/.codex/generated_images, using the path Codex prints in its last message.
"""
import glob, os, re, statistics as st, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageChops, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..")
CA = os.path.join(ROOT, "Modding Files", "source", "exchange_icons", "commodities")
OUT = os.path.join(ROOT, "Modding Files", "source", "exchange_icons", "new_commodities")

# Subject lines. Each one is drawn to stay apart from CA's seventeen at 24px: no burlap
# sacks (Spices), no plain bars (Iron), no black rock (Carved Obsidian), no teapot (Pottery).
ICONS = {
    "brimstone":   "a jagged lump of raw yellow brimstone (sulphur) crystal",
    "blackpowder": "a small wooden powder keg with dark iron bands, a heap of black gunpowder spilling from its open top",
    "brass":       "a heavy cast brass cog wheel with thick teeth, warm polished brass",
    "coal":        "a small heap of black coal lumps with glowing orange-red ember cracks",
    "gromril":     "a squat trapezoid dwarf-forged ingot of dark blue-grey steel with one large engraved dwarf rune glowing pale blue",
    "pipeweed":    "a long-stemmed wooden smoking pipe lying across a small bundle of dried brown pipeweed leaves",
    "grain":       "a sheaf of golden wheat ears bound with twine",
    "amber":       "a polished orange amber teardrop with a small insect trapped inside",
    "ithilmar":    "an elegant curved plate of pale silver-blue elven metal with flowing filigree edges",
    "black_lotus": "a single black lotus flower with deep purple sheen on its dark petals",
    "dragon_bone": "a horned dragon skull of weathered ivory-coloured bone",
    "silk":        "a rolled bolt of shining crimson silk cloth, partly unrolled",
    "jade":        "a small carved green jade statuette of a seated guardian lion",
    "tea":         "an open small red lacquered wooden box filled with dried green tea leaves",
    # second batch - kept apart from Furs, Spices, Wine's jug, the Blackpowder keg, Iron's bar
    "sea_dragon_hide": "a folded piece of scaly sea dragon hide, dark teal scales with a pale fin edge",
    "lustrian_plumes": "a fan of three long bright tropical feathers, scarlet, emerald and gold, tied at the quills",
    "incense":     "an ornate brass incense burner on three short legs with a domed pierced lid",
    "salted_meat": "a large cured ham hock with a white bone end and a crust of salt",
    "rum":         "a squat dark green glass rum bottle with a cork stopper and a frayed rope tied around the neck",
    "whale_oil":   "a small round-bellied ceramic oil flask sealed with wax, a single golden drip of oil running down its side",
    "warhorses":   "the head and neck of a proud white warhorse wearing a blue and gold caparison and steel chanfron",
    "books":       "a thick closed leather-bound tome with brass corner guards and a brass clasp",
    "silver":      "a chunk of raw rock ore with thick bright silver veins and nuggets",
    "salted_fish": "a whole dried salted fish, silver-grey with salt crystals, slightly curved",
    "quicksilver": "a round glass alchemist's flask with a stopper, filled with shining liquid mercury",
    "olive_oil":   "a small olive branch with green and black olives lying against a stoppered glass cruet of golden oil",
    # second batch, 2026-10-01
    "carpets":     "a rolled Arabyan carpet tied with cord, its end unfurled to show a rich red and gold geometric pattern",
    "kvas":        "a squat wooden kvas jug with a cork stopper beside a dark rye bread crust",
    "rhinox_hides": "a folded thick grey rhinox hide with a leathery wrinkled texture and a single curved horn tied to it",
    "mead":        "a carved drinking horn with a silver rim, golden honey mead in it and a honeycomb piece beside it",
    "glassware":   "an elegant blown-glass goblet in clear pale blue glass with a thin swirled stem, catching light",
    "wool":        "a fluffy bundle of cream white sheep wool tied with twine, a wound skein of spun yarn beside it",
    "porcelain":   "a white porcelain vase with blue painted dragon pattern, glossy glaze",
    "pearls":      "an opened oyster shell holding a large lustrous white pearl, two more pearls beside it",
    "starwood":    "a short length of pale silver-white elven wood with faint glowing blue star-like flecks in the grain",
    "feathers":    "two large feathers crossed, one tawny griffon feather with dark bars and one pure white pegasus feather",
    "wyvern_scales": "a few large overlapping dark green wyvern scales with a purple sheen, tied with a leather strap",
}

PROMPT = """Use the built-in image_gen tool (not the CLI fallback). Do not run shell commands
and do not copy files.

The attached image is a strip of existing game icons from Total War: WARHAMMER III (trade
commodity icons). It is a STYLE REFERENCE only.

Generate ONE new icon in exactly that style:
Use case: stylized-concept
Asset type: game UI commodity icon, will be downscaled to 54x54 and 24x24 pixels
Subject: {subject}
Style/medium: painterly hand-painted game icon matching the reference: single object, 3/4 view,
soft top-left lighting, thin dark outline, saturated but not neon colours
Composition/framing: object centred and filling about 85% of a square canvas, chunky readable
silhouette that survives downscaling to 24 pixels
Background: fully transparent (real alpha), no ground shadow plate, no frame, no border
Avoid: text, letters, watermark, extra objects, smoke wisps, thin floating effects, fine detail
that vanishes at small sizes

Reply with the full path of the saved image only."""


def codex_exe():
    hits = glob.glob(os.path.expanduser(
        r"~\.vscode\extensions\openai.chatgpt-*\bin\windows-x86_64\codex.exe"))
    if not hits:
        sys.exit("codex.exe not found - is the ChatGPT VS Code extension installed?")
    return max(hits, key=os.path.getmtime)


def reference_sheet(path):
    fs = sorted(glob.glob(os.path.join(CA, "* large.png")))
    sheet = Image.new("RGBA", (162 * len(fs), 162), (40, 40, 40, 255))
    for i, f in enumerate(fs):
        sheet.alpha_composite(Image.open(f).convert("RGBA").resize((162, 162), Image.NEAREST), (i * 162, 0))
    sheet.save(path)


def generate(name, exe, sheet, work):
    last = os.path.join(work, name + ".txt")
    r = subprocess.run([exe, "exec", "--skip-git-repo-check", "-s", "read-only", "-C", work,
                        "-i", sheet, "-o", last, "-"],
                       input=PROMPT.format(subject=ICONS[name]), text=True, encoding="utf-8",
                       capture_output=True, timeout=900)
    msg = open(last, encoding="utf-8").read() if os.path.exists(last) else r.stdout[-2000:]
    m = re.search(r"[A-Za-z]:\\[^`\n]*?generated_images\\[^`\n]*?\.png", msg)
    if not m or not os.path.exists(m.group(0)):
        return name, "FAILED: " + msg.strip()[-300:]
    Image.open(m.group(0)).save(os.path.join(OUT, "raw", name + ".png"))
    resize(name)
    return name, "ok"


def fit(im, size, margin=0.04):
    """Crop to the opaque pixels, centre on a square with a small margin, scale to size."""
    im = im.convert("RGBA")
    bb = im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    im = im.crop(bb)
    side = int(max(im.size) * (1 + 2 * margin))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    return sq.resize((size, size), Image.LANCZOS)


def tone(im, sat, bri):
    """Scale HSV saturation and value - Codex paints far more saturated than CA does."""
    h, s, v = im.convert("RGB").convert("HSV").split()
    out = Image.merge("HSV", (h, s.point(lambda x: min(255, int(x * sat))),
                              v.point(lambda x: min(255, int(x * bri))))).convert("RGBA")
    out.putalpha(im.getchannel("A"))
    return out


def glow(im, blur=1.0, gain=3):
    """CA's black halo: the icon's own alpha, blurred and boosted, in pure black underneath."""
    base = Image.new("RGBA", im.size, (0, 0, 0, 0))
    base.putalpha(im.getchannel("A").filter(ImageFilter.GaussianBlur(blur)).point(lambda x: min(255, x * gain)))
    base.alpha_composite(im)
    return base


# (margin, saturation x, brightness x) fitted 2026-10-01 against the median of CA's seventeen
# at each size, glow included: halo alpha at 1/2/3px out (CA 202/52/5 large, 164/30/1 small),
# the object's share of the frame (72% / 83%), and saturation/brightness (110/114, 95/118).
# --check re-measures all of it.
SIZES = {"large": (54, 0.16, 0.69, 1.00), "small": (24, 0.08, 0.59, 1.13)}


def resize(name):
    raw = Image.open(os.path.join(OUT, "raw", name + ".png"))
    for folder, (px, margin, sat, bri) in SIZES.items():
        glow(tone(fit(raw, px, margin), sat, bri)).save(os.path.join(OUT, folder, name + ".png"))


def measure(files):
    """Median (halo alpha at 1/2/3px, object share of frame, saturation, brightness)."""
    halo, share, S, V = [], [], [], []
    for f in files:
        im = Image.open(f).convert("RGBA")
        a = im.getchannel("A")
        lum = im.convert("RGB").convert("HSV").getchannel("V")
        obj = ImageChops.multiply(a.point(lambda x: 255 if x > 200 else 0), lum.point(lambda x: 255 if x > 24 else 0))
        b = obj.getbbox()
        share.append(max(b[2] - b[0], b[3] - b[1]) / im.width)
        rings, prev, ad = [], obj, list(a.getdata())
        for _ in range(3):
            cur = prev.filter(ImageFilter.MaxFilter(3))
            ring = [ad[i] for i, (c, p) in enumerate(zip(cur.getdata(), prev.getdata())) if c and not p]
            rings.append(st.mean(ring) if ring else 0)
            prev = cur
        halo.append(rings)
        px = [p for p, al in zip(im.convert("RGB").convert("HSV").getdata(), ad) if al > 200]
        S.append(st.mean(p[1] for p in px))
        V.append(st.mean(p[2] for p in px))
    return ([round(st.median(h[d] for h in halo)) for d in range(3)],
            round(st.median(share), 2), round(st.median(S)), round(st.median(V)))


# The 26 icons SIZES' colour factors were fitted on. Colour is a property of the SUBJECT as much
# as of the processing: the second batch is wool, porcelain, glass, pearls and starwood, and
# measured over all 37 the median saturation fell 110 -> 88 with no change to tone(). So colour
# is compared on this fixed set; halo and share, which are pure processing, on every icon.
FITTED = tuple(list(ICONS)[:26])


def check():
    bad = False
    for folder in SIZES:
        ca = measure(glob.glob(os.path.join(CA, "* %s.png" % folder)))
        ours = measure(glob.glob(os.path.join(OUT, folder, "*.png")))
        fitted = measure([os.path.join(OUT, folder, n + ".png") for n in FITTED])
        print("%s  CA halo %s share %.2f sat %d bri %d" % ((folder,) + ca))
        print("%s ours halo %s share %.2f (all %d)" % (folder, ours[0], ours[1], len(ICONS)))
        print("%s ours sat %d bri %d (the %d fitted)" % (folder, fitted[2], fitted[3], len(FITTED)))
        # the halo's first pixel within 20 of CA's; share and colour within 10%
        bad |= abs(ours[0][0] - ca[0][0]) > 20
        bad |= abs(ours[1] - ca[1]) > 0.1 * ca[1]
        bad |= any(abs(o - c) > 0.1 * c for o, c in zip(fitted[2:], ca[2:]))
    sys.exit("icons drifted from CA's set" if bad else 0)


def selftest():
    im = Image.new("RGBA", (400, 200), (0, 0, 0, 0))
    im.paste((255, 0, 0, 255), (300, 50, 380, 90))  # 80x40 box, off-centre
    out = fit(im, 54)
    assert out.size == (54, 54)
    a = out.getchannel("A")
    bb = a.point(lambda v: 255 if v > 128 else 0).getbbox()
    assert bb[0] <= 3 and bb[2] >= 51, bb            # widest edge fills the frame minus margin
    assert abs((bb[1] + bb[3]) / 2 - 27) <= 1, bb     # recentred vertically
    assert a.getpixel((27, 2)) == 0                   # padding stays transparent
    plain = fit(im, 54, margin=0.16)
    g = glow(plain)
    edge = next(x for x in range(54) if plain.getpixel((x, 27))[3] > 128)  # unhaloed left edge
    halo = g.getpixel((edge - 1, 27))
    assert halo[3] > 100 and max(halo[:3]) < 20, halo   # dark, strong halo just outside the object
    assert g.getpixel((0, 0))[3] == 0                   # and it fades out before the corner
    t = tone(Image.new("RGBA", (2, 2), (200, 50, 50, 255)), 0.5, 1.0)
    h, s, v = t.convert("RGB").convert("HSV").getpixel((0, 0))
    assert 90 <= s <= 100 and v == 200, (s, v)          # saturation halved, value kept
    print("selftest ok")


def main(args):
    if "--selftest" in args:
        return selftest()
    if "--check" in args:
        return check()
    for d in ("raw", "large", "small"):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
    if "--resize" in args:
        for f in glob.glob(os.path.join(OUT, "raw", "*.png")):
            resize(os.path.splitext(os.path.basename(f))[0])
        return
    unknown = [a for a in args if a not in ICONS]
    if unknown:
        sys.exit("unknown icon(s): %s" % unknown)
    names = args or [n for n in ICONS if not os.path.exists(os.path.join(OUT, "raw", n + ".png"))]
    work = tempfile.mkdtemp(prefix="icongen_")
    sheet = os.path.join(work, "ca_reference.png")
    reference_sheet(sheet)
    exe = codex_exe()
    with ThreadPoolExecutor(4) as pool:
        for name, status in pool.map(lambda n: generate(n, exe, sheet, work), names):
            print(name, status, flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
