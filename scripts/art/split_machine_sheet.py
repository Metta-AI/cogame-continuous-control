#!/usr/bin/env python3
"""Keys, splits and pads scripts/art/source/machines_sheet.png into one
128 px chip per morphology.

    python3 scripts/art/split_machine_sheet.py

Gemini does not return alpha and the "pure green" comes back as SOME green with
a tinted edge, so the backdrop colour is taken as the MEDIAN OF THE BORDER
(corners sometimes carry a smudge) and flood-filled from the image border -
which is what lets a green accent INSIDE a machine survive. The row is then
split on empty columns and each part padded to a square.
"""

import os
import statistics
from collections import deque

from PIL import Image

SOURCE = "scripts/art/source/machines_sheet.png"
OUT_DIR = "data/art"
MORPHS = ["hopper", "cheetah", "walker"]
SIZE = 128
TOLERANCE = 62


def border_colour(image):
    w, h = image.size
    px = image.load()
    reds, greens, blues = [], [], []
    for x in range(w):
        for y in (0, h - 1):
            r, g, b = px[x, y][:3]
            reds.append(r); greens.append(g); blues.append(b)
    for y in range(h):
        for x in (0, w - 1):
            r, g, b = px[x, y][:3]
            reds.append(r); greens.append(g); blues.append(b)
    return (int(statistics.median(reds)), int(statistics.median(greens)),
            int(statistics.median(blues)))


def key(image):
    """Flood-fills the backdrop from the border, so an interior accent of the
    same colour is kept."""
    image = image.convert("RGBA")
    w, h = image.size
    px = image.load()
    target = border_colour(image)
    seen = bytearray(w * h)
    queue = deque()
    for x in range(w):
        queue.append((x, 0)); queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y)); queue.append((w - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        r, g, b, _ = px[x, y]
        if (abs(r - target[0]) + abs(g - target[1]) +
                abs(b - target[2])) > TOLERANCE:
            continue
        seen[y * w + x] = 1
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return image


def columns_with_ink(image):
    w, h = image.size
    px = image.load()
    filled = []
    for x in range(w):
        ink = 0
        for y in range(h):
            if px[x, y][3] > 24:
                ink += 1
        filled.append(ink > h // 80)
    return filled


def spans(filled, count):
    runs = []
    start = None
    for x, has in enumerate(filled):
        if has and start is None:
            start = x
        elif not has and start is not None:
            if x - start > 12:
                runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, len(filled)))
    runs.sort(key=lambda r: r[1] - r[0], reverse=True)
    return sorted(runs[:count])


def pad(image):
    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)
    side = max(image.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - image.width) // 2,
                         (side - image.height) // 2))
    return square.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    sheet = key(Image.open(SOURCE))
    runs = spans(columns_with_ink(sheet), len(MORPHS))
    if len(runs) != len(MORPHS):
        raise SystemExit("found %d machines, expected %d: %r" %
                         (len(runs), len(MORPHS), runs))
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, (x0, x1) in zip(MORPHS, runs):
        chip = pad(sheet.crop((x0, 0, x1, sheet.height)))
        path = os.path.join(OUT_DIR, "machine_%s.png" % name)
        chip.save(path)
        print("wrote", path, chip.size)


if __name__ == "__main__":
    main()
