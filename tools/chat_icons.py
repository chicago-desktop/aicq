#!/usr/bin/env python3
"""Draw aICQ's pictures — assets/images/{32,16}/<name>.png.

The image pack `chicago.aicq:images` of the Chicago shell (the contract is
../windows-module/docs/icons.md, "Image packs of other modules"): the shell
finds the pack in the registry when a picture is asked for, so a redrawn file
shows within seconds, without a restart. Own pixel art in the Windows 95
palette, drawn the way tools/weather_icons.py draws: flat fills, a one-pixel
black outline, a figure as a stack of masks from the farthest to the nearest.

- `aicq` — the "aICQ" window, the contact list, a person online: a green
  daisy. A nod to ICQ, not its logo: petals of two greens, no red petal, a
  yellow middle.
- `aicq_off` — the same flower in grey: offline (the tray, a person offline).
- `chat` — the agent dialog window: a speech bubble with a tail and three dots.
- `agent` — an agent in the contact list: a small grey robot head with an
  antenna, cyan eyes and a grille for a mouth.
- `message` — unread messages and the message window: a white envelope.

    python3 tools/chat_icons.py        # rewrites both sizes
"""
import math
import os
import sys

from PIL import Image

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)
GRAY = (192, 192, 192, 255)
DGRAY = (128, 128, 128, 255)
GREEN = (0, 255, 0, 255)
DGREEN = (0, 128, 0, 255)
YELLOW = (255, 255, 0, 255)
RED = (255, 0, 0, 255)
CYAN = (0, 255, 255, 255)
CLEAR = (0, 0, 0, 0)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "images")


def disc(cx, cy, r):
    return lambda x, y: (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r


def box(x0, y0, x1, y1):
    return lambda x, y: x0 <= x < x1 and y0 <= y < y1


def union(*masks):
    return lambda x, y: any(m(x, y) for m in masks)


def petal(cx, cy, angle, reach, along, across):
    """A petal's ellipse: its centre `reach` from the flower's middle at `angle`."""
    ca, sa = math.cos(angle), math.sin(angle)

    def inside(x, y):
        px, py = x + 0.5 - cx, y + 0.5 - cy
        u = px * ca + py * sa - reach
        v = -px * sa + py * ca
        return (u / along) ** 2 + (v / across) ** 2 <= 1
    return inside


def triangle(a, b, c):
    def side(p, q, r):
        return (p[0] - r[0]) * (q[1] - r[1]) - (q[0] - r[0]) * (p[1] - r[1])

    def inside(x, y):
        p = (x + 0.5, y + 0.5)
        d1, d2, d3 = side(p, a, b), side(p, b, c), side(p, c, a)
        return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))
    return inside


def paint(img, mask, color, outline=BLACK):
    w, h = img.size
    px = img.load()
    for y in range(h):
        for x in range(w):
            if mask(x, y):
                px[x, y] = color
    if outline is None:
        return
    for y in range(h):
        for x in range(w):
            if not mask(x, y):
                continue
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if not (0 <= nx < w and 0 <= ny < h) or not mask(nx, ny):
                    px[x, y] = outline
                    break


def draw_flower(img, s, light, dark, middle):
    k = s / 32
    c = 16 * k
    # Eight petals, light and dark in turn.
    count = 8
    petals = []
    for index in range(count):
        angle = index * 2 * math.pi / count - math.pi / 2
        petals.append((index, petal(c, c, angle, 9 * k, 6.5 * k, 3.8 * k)))
    if s >= 32:
        # The dark ones first — they are farther; the light ones lie over them
        # and keep their own outline.
        for index, mask in sorted(petals, key=lambda item: item[0] % 2 == 0):
            paint(img, mask, light if index % 2 == 0 else dark)
    else:
        # At 16 pixels each petal's outline eats the petal: one outline for the
        # silhouette, the dark petals inside without their own.
        paint(img, union(*(mask for _, mask in petals)), light)
        for index, mask in petals:
            if index % 2 == 1:
                paint(img, lambda x, y, m=mask: m(x, y) and 0 < x < s - 1 and 0 < y < s - 1
                      and img.getpixel((x, y)) != BLACK, dark, None)
    paint(img, disc(c, c, 4.5 * k), middle)
    if s < 32:
        # At 16 pixels a petal's tip closes into outline with no fill and sticks
        # out as a black spike at the picture's edge: a black pixel on the edge
        # with no filled (non-black) neighbour is removed. The outline over a
        # fill stays.
        w, h = img.size
        px = img.load()

        def filled(x, y):
            return 0 <= x < w and 0 <= y < h and px[x, y][3] > 0 and px[x, y] != BLACK
        spikes = [(x, y) for y in range(h) for x in range(w) if px[x, y] == BLACK
                  and (x in (0, w - 1) or y in (0, h - 1))
                  and not any(filled(nx, ny) for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)))]
        for x, y in spikes:
            px[x, y] = CLEAR


def draw_aicq(img, s):
    draw_flower(img, s, GREEN, DGREEN, YELLOW)


def draw_aicq_off(img, s):
    draw_flower(img, s, GRAY, DGRAY, WHITE)


def draw_chat(img, s):
    k = s / 32
    r = 6 * k
    x0, y0, x1, y1 = 2 * k, 4 * k, 30 * k, 22 * k
    body = union(
        box(round(x0 + r), round(y0), round(x1 - r), round(y1)),
        box(round(x0), round(y0 + r), round(x1), round(y1 - r)),
        disc(x0 + r, y0 + r, r), disc(x1 - r, y0 + r, r),
        disc(x0 + r, y1 - r, r), disc(x1 - r, y1 - r, r),
    )
    # The tail reaches into the bubble: at 16 pixels a narrow tail stayed a
    # lone outline, apart from the bubble.
    tail = (triangle((7 * k, 18 * k), (16 * k, 18 * k), (4 * k, 30 * k)) if s >= 32
            else triangle((5 * k, 17 * k), (18 * k, 17 * k), (3 * k, 31 * k)))
    paint(img, union(body, tail), WHITE)
    dot = max(1, round(2 * k))
    for col in (10, 16, 22):
        cx, cy = round(col * k) - dot // 2, round(13 * k) - dot // 2
        paint(img, box(cx, cy, cx + dot, cy + dot), DGRAY, None)


def draw_robot(img, s, light, eyes):
    if s >= 32:
        paint(img, box(15, 3, 17, 8), DGRAY)            # the antenna's stalk
        paint(img, disc(16, 3.5, 2.5), light)           # its light
        paint(img, box(3, 13, 7, 21), DGRAY)            # the ears
        paint(img, box(25, 13, 29, 21), DGRAY)
        paint(img, box(11, 25, 21, 30), DGRAY)          # the neck
        paint(img, box(6, 7, 26, 26), GRAY)             # the head
        paint(img, box(9, 11, 15, 17), eyes)            # the eyes
        paint(img, box(17, 11, 23, 17), eyes)
        paint(img, box(11, 19, 21, 23), BLACK, None)    # the grille
        for x in (12, 14, 17, 19):
            paint(img, box(x, 20, x + 1, 22), DGRAY, None)
        return
    # At 16 pixels an outline around a feature eats the feature: the features
    # are flat colour inside the head's own outline.
    paint(img, box(7, 0, 9, 2), light, None)            # the antenna's light
    paint(img, box(7, 2, 9, 3), BLACK, None)            # its stalk
    paint(img, box(1, 6, 3, 10), DGRAY, None)           # the ears
    paint(img, box(13, 6, 15, 10), DGRAY, None)
    paint(img, box(5, 13, 11, 16), DGRAY)               # the neck
    paint(img, box(3, 3, 13, 14), GRAY)                 # the head
    paint(img, box(5, 6, 7, 8), eyes, None)             # the eyes
    paint(img, box(9, 6, 11, 8), eyes, None)
    paint(img, box(6, 10, 10, 11), BLACK, None)         # the mouth


def draw_agent(img, s):
    draw_robot(img, s, RED, CYAN)


def draw_agent_off(img, s):
    # Offline: the light out and the eyes dark, the way the flower goes grey.
    draw_robot(img, s, DGRAY, DGRAY)


def draw_message(img, s):
    if s < 32:
        # At 16 pixels a triangle's outline steps into a bowl, not a V: the
        # flap is drawn pixel by pixel, two lines meeting in the middle.
        paint(img, box(1, 4, 15, 12), WHITE)
        px = img.load()
        for x, y in ((2, 5), (3, 5), (4, 6), (5, 7), (6, 7), (7, 8)):
            px[x, y] = BLACK
            px[15 - x, y] = BLACK
        return
    body = box(2, 7, 30, 25)
    paint(img, body, WHITE)
    # The flap: a V from the top corners to the middle — the outline of a
    # triangle inside the body.
    flap = triangle((2, 7), (30, 7), (16, 17.8))
    paint(img, lambda x, y: flap(x, y) and body(x, y), WHITE)


ICONS = {
    "aicq": draw_aicq,
    "aicq_off": draw_aicq_off,
    "chat": draw_chat,
    "agent": draw_agent,
    "agent_off": draw_agent_off,
    "message": draw_message,
}


def main():
    for size in (32, 16):
        folder = os.path.join(ROOT, str(size))
        os.makedirs(folder, exist_ok=True)
        for name, draw in ICONS.items():
            img = Image.new("RGBA", (size, size), CLEAR)
            draw(img, size)
            img.save(os.path.join(folder, name + ".png"))
            print(f"{size:>2} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
