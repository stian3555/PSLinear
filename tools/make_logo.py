"""Draws the PSLinear logo from geometry: a PowerShell prompt over a small issue list.

Writes assets/PSLinear.svg (the vector source) and PNGs rendered from the same coordinates
with Pillow, drawn at 4x and scaled down for smooth edges.

Run it after changing the geometry or colors: pip install pillow; python tools/make_logo.py
"""
import os
from PIL import Image, ImageChops, ImageDraw

# The assets folder at the repository root, next to this tools folder.
TARGET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets')
SIZE = 512

# Geometry in a 512 x 512 box.
TILE = (24, 24, 488, 488)
TILE_RADIUS = 104
GRADIENT = ((0x25, 0x63, 0xEB), (0x0B, 0x16, 0x3A))   # top left -> bottom right
CHEVRON = [(120, 110), (196, 174), (120, 238)]
CHEVRON_WIDTH = 34
CURSOR = (224, 206, 320, 240)
CURSOR_COLOR = (0x7D, 0xD3, 0xFC)
ROWS = [
    # (y, bar width, bar opacity, dot color, dot is a ring)
    (310, 232, 0.95, (0x4A, 0xDE, 0x80), False),  # done
    (358, 188, 0.70, (0xFA, 0xCC, 0x15), False),  # in progress
    (406, 136, 0.45, (0x94, 0xA3, 0xB8), True),   # to do
]
DOT_X, DOT_RADIUS, RING_WIDTH = 138, 16, 6
BAR_X, BAR_HEIGHT = 176, 28


def hex_color(rgb):
    return '#%02X%02X%02X' % rgb


def write_svg(path):
    rows = []
    for y, width, opacity, color, ring in ROWS:
        if ring:
            rows.append(f'  <circle cx="{DOT_X}" cy="{y}" r="{DOT_RADIUS - RING_WIDTH / 2}" fill="none" stroke="{hex_color(color)}" stroke-width="{RING_WIDTH}"/>')
        else:
            rows.append(f'  <circle cx="{DOT_X}" cy="{y}" r="{DOT_RADIUS}" fill="{hex_color(color)}"/>')
        rows.append(f'  <rect x="{BAR_X}" y="{y - BAR_HEIGHT // 2}" width="{width}" height="{BAR_HEIGHT}" rx="{BAR_HEIGHT // 2}" fill="#FFFFFF" fill-opacity="{opacity}"/>')
    x0, y0, x1, y1 = TILE
    cx0, cy0, cx1, cy1 = CURSOR
    points = ' '.join(f'{x},{y}' for x, y in CHEVRON)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">
  <title>PSLinear</title>
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{hex_color(GRADIENT[0])}"/>
      <stop offset="1" stop-color="{hex_color(GRADIENT[1])}"/>
    </linearGradient>
  </defs>
  <rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="{TILE_RADIUS}" fill="url(#tile)"/>
  <polyline points="{points}" fill="none" stroke="#FFFFFF" stroke-width="{CHEVRON_WIDTH}" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="{cx0}" y="{cy0}" width="{cx1 - cx0}" height="{cy1 - cy0}" rx="{(cy1 - cy0) // 2}" fill="{hex_color(CURSOR_COLOR)}"/>
{chr(10).join(rows)}
</svg>
'''
    with open(path, 'w', encoding='utf-8', newline='\n') as file:
        file.write(svg)


def render(scale=4):
    size = SIZE * scale
    s = lambda value: int(round(value * scale))

    # Diagonal gradient: the mean of a horizontal and a vertical ramp.
    vertical = Image.linear_gradient('L').resize((size, size))
    horizontal = vertical.transpose(Image.Transpose.TRANSPOSE)
    ramp = ImageChops.add(horizontal, vertical, scale=2.0)
    gradient = Image.composite(Image.new('RGB', (size, size), GRADIENT[1]), Image.new('RGB', (size, size), GRADIENT[0]), ramp)

    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([s(v) for v in TILE], radius=s(TILE_RADIUS), fill=255)
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    image.paste(gradient, (0, 0), mask)

    draw = ImageDraw.Draw(image)
    chevron = [(s(x), s(y)) for x, y in CHEVRON]
    draw.line(chevron, fill='white', width=s(CHEVRON_WIDTH), joint='curve')
    for x, y in (chevron[0], chevron[-1]):
        radius = s(CHEVRON_WIDTH / 2)
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill='white')
    cx0, cy0, cx1, cy1 = CURSOR
    draw.rounded_rectangle([s(cx0), s(cy0), s(cx1), s(cy1)], radius=s((cy1 - cy0) / 2), fill=CURSOR_COLOR)

    overlay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    for y, width, opacity, color, ring in ROWS:
        box = [s(DOT_X - DOT_RADIUS), s(y - DOT_RADIUS), s(DOT_X + DOT_RADIUS), s(y + DOT_RADIUS)]
        if ring:
            overlay_draw.ellipse(box, outline=color + (255,), width=s(RING_WIDTH))
        else:
            overlay_draw.ellipse(box, fill=color + (255,))
        overlay_draw.rounded_rectangle([s(BAR_X), s(y - BAR_HEIGHT / 2), s(BAR_X + width), s(y + BAR_HEIGHT / 2)],
                                       radius=s(BAR_HEIGHT / 2), fill=(255, 255, 255, int(255 * opacity)))
    return Image.alpha_composite(image, overlay)


os.makedirs(TARGET, exist_ok=True)
write_svg(os.path.join(TARGET, 'PSLinear.svg'))
large = render()
for pixels, name in ((512, 'PSLinear.png'), (128, 'PSLinear-icon.png')):
    path = os.path.join(TARGET, name)
    large.resize((pixels, pixels), Image.LANCZOS).save(path, optimize=True)
    print(name, os.path.getsize(path), 'bytes')
print('PSLinear.svg', os.path.getsize(os.path.join(TARGET, 'PSLinear.svg')), 'bytes')
