"""Renders the Stream Deck plugin's images from the app's FontAwesome glyphs.

    pip install pillow
    python streamdeck/assets/generate_images.py

Writes into streamdeck/com.streamsmith.remote.sdPlugin/images/. The PNGs are
committed, so this only has to be run when an icon changes.

Sizes come from Elgato's manifest reference:
  key images   72x72 and 144x144 (@2x)
  action icons 20x20 and 40x40 (@2x), shown in the actions list
  plugin icon  256x256 and 512x512 (@2x)
  category     28x28 and 56x56 (@2x), monochrome white
"""
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FONT = os.path.join(REPO, "assets", "fonts", "fa-solid-900.otf")
OUT = os.path.join(HERE, "..", "com.streamsmith.remote.sdPlugin", "images")

# src/ui/theme.odin
SURFACE = (19, 27, 46)
TEXT = (218, 226, 253)
PRIMARY = (59, 130, 246)
DANGER = (239, 68, 68)
MUTED = (100, 116, 139)

SS = 4  # supersample factor

GLYPHS = {
    "broadcast": 0xF519,
    "record": 0xF111,
    "volume_high": 0xF028,
    "volume_mute": 0xF6A9,
    "eye": 0xF06E,
    "eye_slash": 0xF070,
    "layers": 0xF5FD,
    "volume_up": 0xF028,
    "volume_down": 0xF027 if True else 0,  # volume-low
}


def render(glyph: int, fg, bg, size: int, pad: float = 0.22, ring=None) -> Image.Image:
    """One square image: optional background, glyph centred."""
    d = size * SS
    img = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    if bg is not None:
        radius = int(d * 0.18)
        draw.rounded_rectangle([0, 0, d - 1, d - 1], radius=radius, fill=bg)
    if ring is not None:
        width = max(1, int(d * 0.045))
        radius = int(d * 0.18)
        draw.rounded_rectangle(
            [width // 2, width // 2, d - 1 - width // 2, d - 1 - width // 2],
            radius=radius, outline=ring, width=width,
        )

    font = ImageFont.truetype(FONT, int(d * (1 - 2 * pad)))
    ch = chr(glyph)
    box = draw.textbbox((0, 0), ch, font=font)
    x = (d - (box[2] - box[0])) / 2 - box[0]
    y = (d - (box[3] - box[1])) / 2 - box[1]
    draw.text((x, y), ch, font=font, fill=fg)

    return img.resize((size, size), Image.LANCZOS)


def write(name: str, glyph: int, fg, bg, sizes=(72, 144), **kw):
    for size in sizes:
        suffix = "" if size == sizes[0] else "@2x"
        path = os.path.join(OUT, f"{name}{suffix}.png")
        render(glyph, fg, bg, size, **kw).save(path)
        print("wrote", os.path.relpath(path, REPO))


def main():
    os.makedirs(OUT, exist_ok=True)

    # Key images: state 0 is idle, state 1 is "on" and takes the accent colour.
    write("key_scene_off", GLYPHS["layers"], TEXT, SURFACE)
    write("key_scene_on", GLYPHS["layers"], SURFACE, PRIMARY)

    write("key_streaming_off", GLYPHS["broadcast"], TEXT, SURFACE)
    write("key_streaming_on", GLYPHS["broadcast"], TEXT, DANGER)

    write("key_recording_off", GLYPHS["record"], TEXT, SURFACE)
    write("key_recording_on", GLYPHS["record"], TEXT, DANGER)

    write("key_mute_off", GLYPHS["volume_high"], TEXT, SURFACE)
    write("key_mute_on", GLYPHS["volume_mute"], TEXT, DANGER)

    write("key_volume_up", GLYPHS["volume_high"], TEXT, SURFACE)
    write("key_volume_down", GLYPHS["volume_down"], TEXT, SURFACE)

    write("key_visibility_on", GLYPHS["eye"], TEXT, SURFACE)   # shown
    write("key_visibility_off", GLYPHS["eye_slash"], MUTED, SURFACE)  # hidden

    # Action icons for the actions list: glyph only, no plate.
    for name, glyph in (
        ("action_scene", GLYPHS["layers"]),
        ("action_streaming", GLYPHS["broadcast"]),
        ("action_recording", GLYPHS["record"]),
        ("action_mute", GLYPHS["volume_high"]),
        ("action_volume", GLYPHS["volume_high"]),
        ("action_visibility", GLYPHS["eye"]),
    ):
        write(name, glyph, TEXT, None, sizes=(20, 40), pad=0.05)

    # Category icon: monochrome white, per the manifest reference.
    write("category", GLYPHS["broadcast"], (255, 255, 255), None, sizes=(28, 56), pad=0.05)

    # Plugin icon: reuse the app icon so the Marketplace entry matches.
    app_icon = os.path.join(REPO, "assets", "icons", "streamsmith.png")
    src = Image.open(app_icon).convert("RGBA")
    for size in (256, 512):
        suffix = "" if size == 256 else "@2x"
        path = os.path.join(OUT, f"plugin{suffix}.png")
        src.resize((size, size), Image.LANCZOS).save(path)
        print("wrote", os.path.relpath(path, REPO))


if __name__ == "__main__":
    main()
