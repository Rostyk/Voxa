#!/usr/bin/env python3
"""Generate macOS AppIcon PNGs from Art/voxa-1024.png (squircle + dock-safe margin)."""

from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "Art" / "voxa-1024.png"
OUT = REPO / "Voxa" / "Assets.xcassets" / "AppIcon.appiconset"
# Slightly inset so Dock size matches system icons; squircle clips the blue shape.
MARGIN_SCALE = 0.86


def squircle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = max(2, round(size * 0.223))
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def mac_icon(size: int, src: Image.Image) -> Image.Image:
    logo = src.resize((size, size), Image.Resampling.LANCZOS)
    mask = squircle_mask(size)
    rounded = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rounded.paste(logo, (0, 0), mask)

    inner = max(1, int(size * MARGIN_SCALE))
    scaled = rounded.resize((inner, inner), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = (size - inner) // 2
    canvas.paste(scaled, (offset, offset), scaled)
    return canvas


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"Missing source art: {SRC}")
    src = Image.open(SRC).convert("RGBA")
    specs = [
        (16, "icon-mac-16x16.png"),
        (32, "icon-mac-16x16@2x.png"),
        (32, "icon-mac-32x32.png"),
        (64, "icon-mac-32x32@2x.png"),
        (128, "icon-mac-128x128.png"),
        (256, "icon-mac-128x128@2x.png"),
        (256, "icon-mac-256x256.png"),
        (512, "icon-mac-512x512.png"),
        (1024, "icon-mac-512x512@2x.png"),
    ]
    for px, name in specs:
        mac_icon(px, src).save(OUT / name, format="PNG")
        print(f"wrote {name} ({px}px)")
    mac_icon(1024, src).save(OUT / "icon-ios-1024x1024.png", format="PNG")
    print("wrote icon-ios-1024x1024.png")


if __name__ == "__main__":
    main()
