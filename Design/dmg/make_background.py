#!/usr/bin/env python3
"""dmg を開いたときのウィンドウの背景（Design/dmg/background.tiff）を書き出す。

ウィンドウの中身は 600×370pt。Finder でパスバーを出している人は下の 22pt ほどが隠れるので、下を空けておく。
左にアプリ、右に Applications を置き（中心の座標は Config/dmg_settings.py の icon_locations と同じ）、
間に矢印、下に一言を入れる。色はアプリのアイコン（make_appicon.py）に合わせる。
Retina 用に 2 倍の絵も描き、tiffutil で 1 つの TIFF にまとめる。要るもの：Pillow。
"""
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "background.tiff")

W, H = 600, 370
APP_X, APPS_X, ICON_Y = 150, 450, 160
CAPTION_Y = 300
CAPTION = "MDよみとき を Applications へドラッグしてください"

PAPER0, PAPER1 = (0xFF, 0xFA, 0xF0), (0xF2, 0xE7, 0xCE)
CORAL = (0xE2, 0x5C, 0x4B)
TEXT = (0x6E, 0x58, 0x46)
MARK = (0xFF, 0xD8, 0x4A)
FONT = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"


def draw(scale):
    s = lambda v: round(v * scale)
    img = Image.new("RGB", (s(W), s(H)))
    d = ImageDraw.Draw(img)
    # 紙の色の上から下へのグラデーション
    for y in range(s(H)):
        t = y / (s(H) - 1)
        d.line([(0, y), (s(W), y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(PAPER0, PAPER1)))

    # 矢印（アイコンの間。アイコンは 128pt なので左右に余白を取る）
    x0, x1, y = APP_X + 86, APPS_X - 86, ICON_Y
    d.rounded_rectangle([s(x0), s(y - 5), s(x1 - 22), s(y + 5)], radius=s(5), fill=CORAL)
    d.polygon([(s(x1 - 30), s(y - 18)), (s(x1), s(y)), (s(x1 - 30), s(y + 18))], fill=CORAL)

    # 一言（アイコンの蛍光ペンのように、下に黄色の帯を引く）
    font = ImageFont.truetype(FONT, s(15))
    box = d.textbbox((0, 0), CAPTION, font=font)
    tw, th = box[2] - box[0], box[3] - box[1]
    tx, ty = (s(W) - tw) / 2, s(CAPTION_Y) - th / 2 - box[1]
    d.rounded_rectangle([tx - s(6), s(CAPTION_Y) + th / 2 - s(5), tx + tw + s(6), s(CAPTION_Y) + th / 2 + s(3)],
                        radius=s(4), fill=MARK)
    d.text((tx, ty), CAPTION, font=font, fill=TEXT)
    return img


with tempfile.TemporaryDirectory() as tmp:
    one, two = os.path.join(tmp, "bg.png"), os.path.join(tmp, "bg@2x.png")
    draw(1).save(one, dpi=(72, 72))
    draw(2).save(two, dpi=(144, 144))
    subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", OUT], check=True)
print(OUT)
