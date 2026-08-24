#!/usr/bin/env python3
"""Generate small, legible brand-identification marks for CouponKok demo coupons.

These are deliberately compact wordmarks for in-app merchant identification. They
do not claim partnership or reproduce full advertising artwork.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "CouponPilot/Resources/Assets.xcassets"
FONT = "/System/Library/Fonts/Supplemental/AppleGothic.ttf"


def font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size)


def centered(draw: ImageDraw.ImageDraw, text: str, y: int, face: ImageFont.FreeTypeFont, fill: str) -> None:
    left, top, right, bottom = draw.textbbox((0, 0), text, font=face)
    draw.text(((512 - (right - left)) / 2, y - top), text, font=face, fill=fill)


def rounded(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], fill: str, radius: int = 68) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def image_set(asset: str, filename: str, painter) -> None:
    directory = ASSETS / f"{asset}.imageset"
    directory.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGBA", (512, 512), (255, 255, 255, 0))
    painter(image)
    image.save(directory / filename)
    (directory / "Contents.json").write_text(
        json.dumps(
            {
                "images": [{"filename": filename, "idiom": "universal", "scale": "1x"}],
                "info": {"author": "xcode", "version": 1},
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def gongcha(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#A6252A", 84)
    centered(draw, "공차", 126, font(116), "#FFFFFF")
    centered(draw, "GONG CHA", 292, font(51), "#FFFFFF")


def theventi(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#273F49", 84)
    centered(draw, "THE", 112, font(74), "#FFFFFF")
    centered(draw, "VENTI", 207, font(82), "#FFFFFF")
    centered(draw, "COFFEE", 316, font(38), "#C5E8DF")


def coffeebean(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#4E2D5B", 84)
    draw.ellipse((132, 92, 380, 340), outline="#E9D8BE", width=18)
    centered(draw, "COFFEE", 173, font(48), "#FFFFFF")
    centered(draw, "BEAN", 237, font(58), "#FFFFFF")
    centered(draw, "& TEA", 343, font(32), "#E9D8BE")


def paiks(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#FFE400", 84)
    centered(draw, "빽다방", 136, font(104), "#192024")
    centered(draw, "PAIK'S COFFEE", 298, font(38), "#192024")


def compose(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#FDD800", 84)
    centered(draw, "COMPOSE", 134, font(74), "#1C242B")
    centered(draw, "COFFEE", 227, font(60), "#1C242B")
    centered(draw, "TAKE-OUT CULTURE", 324, font(27), "#1C242B")


def mega(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rounded(draw, (54, 54, 458, 458), "#FFDD00", 84)
    centered(draw, "MEGA", 120, font(88), "#18365F")
    centered(draw, "MGC", 218, font(86), "#18365F")
    centered(draw, "COFFEE", 321, font(42), "#18365F")


def main() -> None:
    image_set("BrandGongCha", "brand-gong-cha.png", gongcha)
    image_set("BrandTheVenti", "brand-the-venti.png", theventi)
    image_set("BrandCoffeeBean", "brand-coffee-bean.png", coffeebean)
    image_set("BrandPaiksCoffee", "brand-paiks-coffee.png", paiks)
    image_set("BrandComposeCoffee", "brand-compose-coffee.png", compose)
    image_set("BrandMegaMGC", "brand-mega-mgc.png", mega)


if __name__ == "__main__":
    main()
