#!/usr/bin/env python3
"""writes the colored marks of popular sites as app/icons/ui/yz-logo-<name>.png

usage: make_site_logos.py [SVG_DIRECTORY [OUTPUT_DIRECTORY]]
the svg files are single color marks of simple-icons (CC0). each one is drawn in the color of its brand, the shapes cut out of a plate
(the triangle of youtube, the plane of telegram) are filled white so the mark reads on a dark tile too. needs rsvg-convert and pillow
"""
import io
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

PIXELS = 128
# drawn four times larger, so the edges stay smooth after the white fill and the downscale
WORK = PIXELS * 4
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# name: (color, how the mark is finished). "holes" fills what the plate encloses with white, "disc" lays a white disc under the mark,
# "gradient" paints the mark with the instagram gradient, "glitch" adds the cyan and red offsets of tiktok
MARKS = {
    "bluesky": ("#0285FF", None),
    "discord": ("#5865F2", "holes"),
    "duolingo": ("#58CC02", "holes"),
    "facebook": ("#0866FF", "disc"),
    "github": ("#181717", None),
    "gmail": ("#EA4335", None),
    "instagram": (None, "gradient"),
    "kinopoisk": ("#FF5500", None),
    "linkedin": ("#0A66C2", "holes"),
    "maildotru": ("#005FF9", None),
    "netflix": ("#E50914", None),
    "odnoklassniki": ("#EE8208", None),
    "openai": ("#000000", None),
    "pinterest": ("#BD081C", "disc"),
    "reddit": ("#FF4500", "holes"),
    "soundcloud": ("#FF5500", None),
    "spotify": ("#1ED760", "holes"),
    "stackoverflow": ("#F58025", None),
    "steam": ("#1B2838", "disc"),
    "telegram": ("#26A5E4", "holes"),
    "threads": ("#000000", None),
    "tiktok": ("#000000", "glitch"),
    "tumblr": ("#36465D", None),
    "twitch": ("#9146FF", "holes"),
    "vk": ("#0077FF", "holes"),
    "whatsapp": ("#25D366", None),
    "wikipedia": ("#000000", None),
    "x": ("#000000", None),
    "youtube": ("#FF0000", "holes"),
}


def render(path, side):
    png = subprocess.run(["rsvg-convert", "-w", str(side), "-h", str(side), path], check=True, capture_output=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA").getchannel("A")


def enclosed(alpha):
    """the parts the mark surrounds: everything that is not the mark and cannot be reached from the border"""
    solid = alpha.point(lambda a: 255 if a >= 128 else 0)
    outside = solid.copy()
    side = outside.size[0]
    seeds = [(x, y) for x in range(0, side, 16) for y in (0, side - 1)] + [(x, y) for y in range(0, side, 16) for x in (0, side - 1)]
    for seed in seeds:
        if outside.getpixel(seed) == 0:
            ImageDraw.floodfill(outside, seed, 128)
    # 0 is now only what the border cannot reach
    holes = outside.point(lambda a: 255 if a == 0 else 0)
    # grown under the antialiased edge of the mark, so no dark seam shows between the two
    return holes.filter(ImageFilter.MaxFilter(5))


def gradient(side):
    """the instagram gradient: yellow at the lower left through orange and pink to violet at the upper right"""
    stops = [(0.0, (0xFE, 0xDA, 0x75)), (0.25, (0xFA, 0x7E, 0x1E)), (0.5, (0xD6, 0x29, 0x76)), (0.75, (0x96, 0x2F, 0xBF)), (1.0, (0x4F, 0x5B, 0xD5))]
    small = 64
    image = Image.new("RGB", (small, small))
    for y in range(small):
        for x in range(small):
            t = (x + (small - 1 - y)) / (2 * (small - 1))
            for (a, ca), (b, cb) in zip(stops, stops[1:]):
                if a <= t <= b:
                    f = (t - a) / (b - a)
                    image.putpixel((x, y), tuple(round(ca[i] + (cb[i] - ca[i]) * f) for i in range(3)))
                    break
    return image.resize((side, side), Image.BICUBIC)


def shifted(alpha, dx, dy):
    moved = Image.new("L", alpha.size, 0)
    moved.paste(alpha, (dx, dy))
    return moved


def colored(alpha, color):
    layer = Image.new("RGBA", alpha.size, color)
    layer.putalpha(alpha)
    return layer


def mark(path, color, finish):
    if finish == "glitch":
        # the offsets need room inside the square, so the mark is drawn smaller
        alpha = shifted(render(path, WORK * 7 // 8), WORK // 16, WORK // 16)
    else:
        alpha = render(path, WORK)
    canvas = Image.new("RGBA", alpha.size, (0, 0, 0, 0))
    if finish == "holes":
        canvas.alpha_composite(colored(enclosed(alpha), "#FFFFFF"))
    elif finish == "disc":
        # the cut of the f of facebook, the p of pinterest and the arm of steam reach the edge of their disc, so it is not enclosed:
        # a white disc a little inside the colored one
        disc = Image.new("L", alpha.size, 0)
        inset = WORK // 64
        ImageDraw.Draw(disc).ellipse((inset, inset, WORK - inset, WORK - inset), fill=255)
        canvas.alpha_composite(colored(disc, "#FFFFFF"))
    if finish == "gradient":
        layer = gradient(WORK).convert("RGBA")
        layer.putalpha(alpha)
        canvas.alpha_composite(layer)
    elif finish == "glitch":
        shift = WORK // 40
        canvas.alpha_composite(colored(shifted(alpha, -shift, -shift), "#25F4EE"))
        canvas.alpha_composite(colored(shifted(alpha, shift, shift), "#FE2C55"))
        canvas.alpha_composite(colored(alpha, color))
    else:
        canvas.alpha_composite(colored(alpha, color))
    return canvas.resize((PIXELS, PIXELS), Image.LANCZOS)


def main():
    if len(sys.argv) > 3:
        raise SystemExit("usage: make_site_logos.py [SVG_DIRECTORY [OUTPUT_DIRECTORY]]")
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tools", "site-logos")
    output = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "app", "icons", "ui")
    present = sorted(name[:-4] for name in os.listdir(source) if name.endswith(".svg"))
    if present != sorted(MARKS):
        raise SystemExit("make_site_logos: the svg files of " + source + " and the table differ: " + " ".join(sorted(set(present) ^ set(MARKS))))
    os.makedirs(output, exist_ok=True)
    for name, (color, finish) in sorted(MARKS.items()):
        mark(os.path.join(source, name + ".svg"), color, finish).save(os.path.join(output, "yz-logo-" + name + ".png"), optimize=True)


if __name__ == "__main__":
    main()
