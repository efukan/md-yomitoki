#!/usr/bin/env python3
"""本番のアプリアイコン（Icon Composer 形式の MDYomitoki/AppIcon.icon）を書き出す。

角丸の形・光沢・影はシステムが付けるので、ここでは平らな図形だけを SVG のレイヤーにする。
座標は 1024 のアイコン座標（本体が 100〜924）で書き、viewBox で本体の範囲をキャンバス全体（1024pt）に広げる。
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ICON = os.path.join(HERE, "..", "..", "MDYomitoki", "AppIcon.icon")

SPINE_X = 100 + 824 * 0.22
DY = 32  # 中身を下げた量

PAPER0, PAPER1 = "#FFFAF0", "#F2E7CE"
FRAME0, FRAME1 = "#70503A", "#432E20"
INK = "#4A3628"
TEXT = "#8E7661"
MARK = "#FFD84A"
CORAL0, CORAL1 = "#EE6B58", "#D7473C"
SIDEBAR_INK = "#F6ECD8"
DARK_PAPER0, DARK_PAPER1 = "#3B332C", "#26211D"
DARK_INK = "#F2E7CE"
DARK_TEXT = "#A38D77"


def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="100 100 824 824">\n'
            f'<defs>{defs}</defs>\n{body}</svg>\n')


def vgrad(gid, c0, c1, y0, y1, o0=1, o1=1):
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="0" y1="{y0}" x2="0" y2="{y1}">'
            f'<stop offset="0" stop-color="{c0}" stop-opacity="{o0}"/>'
            f'<stop offset="1" stop-color="{c1}" stop-opacity="{o1}"/></linearGradient>')


def hgrad(gid, c0, c1, x0, x1, o0=1, o1=1):
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{x0}" y1="0" x2="{x1}" y2="0">'
            f'<stop offset="0" stop-color="{c0}" stop-opacity="{o0}"/>'
            f'<stop offset="1" stop-color="{c1}" stop-opacity="{o1}"/></linearGradient>')


def bar(x0, x1, y, w, fill, opacity=1):
    """本文の行（丸い端を含めた見た目の範囲が x0〜x1）"""
    return (f'<rect x="{x0}" y="{y - w / 2}" width="{x1 - x0}" height="{w}" rx="{w / 2}" '
            f'fill="{fill}" opacity="{round(opacity, 3)}"/>\n')


def hash_mark(cx, cy, size, w, slant, gx, gy, fill):
    h, gx, gy = size / 2, size * gx, size * gy
    lines = []
    for sx in (-gx, gx):
        lines.append((cx + sx + slant, cy - h, cx + sx - slant, cy + h))
    for sy in (-gy, gy):
        lines.append((cx - h * 0.98, cy + sy, cx + h * 0.98, cy + sy))
    return "".join(f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" stroke="{fill}" '
                   f'stroke-width="{w}" stroke-linecap="round"/>\n' for x1, y1, x2, y2 in lines)


def sidebar_svg():
    """左の帯（サイドバー）と、紙面との境目の仕切り線"""
    defs = (vgrad("band", FRAME0, FRAME1, 100, 924)
            + hgrad("shade", "#3A2516", "#3A2516", SPINE_X, SPINE_X + 18, 0.086, 0))
    body = (f'<rect x="0" y="0" width="{SPINE_X}" height="1024" fill="url(#band)"/>\n'
            f'<rect x="{SPINE_X}" y="0" width="18" height="1024" fill="url(#shade)"/>\n'
            f'<rect x="{SPINE_X}" y="0" width="3" height="1024" fill="#2E1D12" opacity="0.43"/>\n')
    return svg(body, defs)


def sidebar_rows_svg():
    """サイドバーの見出しの行。今読んでいる行（蛍光ペンの行と同じ高さ）だけ濃く、帯を敷く"""
    active = 680 + DY
    body = f'<rect x="116" y="{active - 28}" width="152" height="56" rx="28" fill="#FFFFFF" opacity="0.17"/>\n'
    for y, x0, length, alpha in ((350 + DY, 132, 112, 0.35), (530 + DY, 154, 88, 0.35), (active, 154, 84, 1)):
        body += bar(x0, x0 + length, y, 28, SIDEBAR_INK, alpha)
    return svg(body)


# 紙面は色ごとにレイヤーを分ける（ダークモードで色だけを差し替えるため）

def page_ink_svg():
    """真ん中を広く開けた # と見出し"""
    return svg(hash_mark(414, 350 + DY, 170, 36, 8, 0.25, 0.225, INK) + bar(542, 714, 350 + DY, 60, INK))


def page_text_svg():
    """本文の2行（下の行は蛍光ペンの上）"""
    return svg(bar(342, 680, 530 + DY, 52, TEXT) + bar(342, 818, 680 + DY, 52, TEXT))


def page_mark_svg():
    return svg(f'<rect x="324" y="{630 + DY}" width="528" height="100" rx="18" fill="{MARK}"/>\n')


def ribbon_svg():
    """上の縁から垂れる栞（下端に V の切れ込み）"""
    y1 = 482 + DY
    defs = vgrad("ribbon", CORAL1, CORAL0, 100, y1)
    body = f'<polygon points="742,40 848,40 848,{y1} 795,{y1 - 48} 742,{y1}" fill="url(#ribbon)"/>\n'
    return svg(body, defs)


def srgb(hex_color):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def layer(name, dark=None):
    """dark を渡すと、ダークモードではレイヤー全体をその色で塗る"""
    d = {"image-name": f"{name}.svg", "name": name}
    if dark:
        d["fill-specializations"] = [{"appearance": "dark", "value": {"solid": srgb(dark)}}]
    return d


def group(name, *layers, shadow=0.5, specular=True):
    g = {
        "name": name,
        "layers": list(layers),
        "shadow": {"kind": "neutral", "opacity": shadow},
        "translucency": {"enabled": False, "value": 0.5},
    }
    if not specular:
        g["specular"] = False
    return g


def main():
    assets = os.path.join(ICON, "Assets")
    os.makedirs(assets, exist_ok=True)
    files = {"sidebar": sidebar_svg(), "sidebar-rows": sidebar_rows_svg(), "page-ink": page_ink_svg(),
             "page-text": page_text_svg(), "page-mark": page_mark_svg(), "ribbon": ribbon_svg()}
    for old in os.listdir(assets):
        if old.endswith(".svg") and old[:-4] not in files:
            os.remove(os.path.join(assets, old))
    for name, text in files.items():
        with open(os.path.join(assets, f"{name}.svg"), "w", encoding="utf-8") as f:
            f.write(text)
    doc = {
        # ダークモードでは紙を暗い焦げ茶にし、紙面の墨と本文を明るい色に差し替える
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb(PAPER0), srgb(PAPER1)]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb(DARK_PAPER0), srgb(DARK_PAPER1)]}},
        ],
        # 先頭が一番手前
        "groups": [
            group("Ribbon", layer("ribbon")),
            group("Page", layer("page-ink", dark=DARK_INK), layer("page-text", dark=DARK_TEXT),
                  layer("page-mark"), shadow=0.15, specular=False),
            group("Sidebar", layer("sidebar-rows"), layer("sidebar")),
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON, "icon.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", os.path.normpath(ICON))


if __name__ == "__main__":
    main()
