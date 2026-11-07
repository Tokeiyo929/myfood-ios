# -*- coding: utf-8 -*-
"""把 ios/icon/icon.svg 的设计栅格化为 iOS AppIcon（1024x1024，不透明方图）。

Windows 本机缺 cairo 原生库（cairosvg/svglib+pycairo 均依赖），故用 PIL 按
icon.svg 的设计稿 1:1 复刻绘制。SVG 仍是设计源：改设计时先改 SVG，再同步此脚本。
用法：python render_icon.py [输出.png]（默认覆盖 AppIcon.appiconset/AppIcon-512@2x.png）
"""
import math
import os
import sys

from PIL import Image, ImageDraw

SIZE = 1024
OUT_DEFAULT = os.path.join(os.path.dirname(__file__), "..", "App", "App", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-512@2x.png")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", size, top)
    d = ImageDraw.Draw(img)
    for y in range(size[1]):
        d.line([(0, y), (size[0], y)], fill=lerp(top, bottom, y / (size[1] - 1)))
    return img.convert("RGBA")


def s_curve_points(x0, y0, height, span, n=60):
    # 与 SVG path M x0 y0 C(x0-span)(y0-h*0.45) (x0+span)(y0-h*0.75) x0 y0-h 近似的 S 形
    pts = []
    for i in range(n + 1):
        t = i / n
        x = x0 + span * math.sin(t * math.pi * 1.0) * (1 - t * 0.4) * (1 if t < 0.5 else -0.9)
        y = y0 - height * t
        pts.append((x, y))
    return pts


def rounded_stick(d, layer_size, x, y, w, h, r, color, angle, pivot):
    stick = Image.new("RGBA", layer_size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(stick)
    sd.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=color)
    rotated = stick.rotate(angle, resample=Image.BICUBIC, center=pivot)
    return rotated


def main(out_path):
    W = H = SIZE
    img = vertical_gradient((W, H), (0x3A, 0x85, 0x60), (0x1D, 0x47, 0x33))
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)

    # 蒸汽两条 S 曲线：沿路径密集盖圆盘（不透明重叠无痕，避免线段接缝毛刺）
    steam_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(steam_layer)
    steam = (0xD3, 0xE8, 0xDB, 255)
    r = 13
    for x0 in (392, 632):
        pts = []
        for i in range(220):
            t = i / 219
            x = x0 + 30 * math.sin(2 * math.pi * t)
            y = 400 - 114 * t
            pts.append((x, y))
        for (x, y) in pts:
            sd.ellipse([x - r, y - r, x + r, y + r], fill=steam)
    overlay = Image.alpha_composite(overlay, steam_layer)
    d = ImageDraw.Draw(overlay)

    # 筷子两根（旋转圆角矩形）
    for (cx, angle, color) in ((632, 30, (0xE9, 0xD9, 0xB5, 255)), (688, 38, (0xDC, 0xC7, 0x9C, 255))):
        stick = rounded_stick(d, (W, H), cx - 12, 330, 24, 330, 12, color, angle, (cx, 495))
        overlay = Image.alpha_composite(overlay, stick)
        d = ImageDraw.Draw(overlay)

    # 定位针（黄色水滴：圆头 + 内收三角尖 + 深色圆心）
    pin = (0xF2, 0xB3, 0x3D, 255)
    d.ellipse([512 - 94, 150 - 94, 512 + 94, 150 + 94], fill=pin)
    d.polygon([(452, 176), (572, 176), (512, 300)], fill=pin)
    d.ellipse([512 - 36, 150 - 36, 512 + 36, 150 + 36], fill=(0x1D, 0x47, 0x33, 255))

    # 碗沿（白色圆角横条）
    d.rounded_rectangle([236, 428, 236 + 552, 428 + 60], radius=30, fill=(255, 255, 255, 255))
    # 碗身（下半椭圆白）
    d.pieslice([280, 488 - 260, 744, 488 + 292], 0, 180, fill=(255, 255, 255, 255))
    # 碗身内阴影
    d.pieslice([312, 488 - 230, 712, 488 + 260], 0, 180, fill=(201, 216, 206, 90))
    # 碗口重盖回白色条带（保持沿口干净）
    d.rounded_rectangle([236, 428, 236 + 552, 428 + 34], radius=17, fill=(255, 255, 255, 255))
    # 碗底
    d.rounded_rectangle([448, 780, 448 + 128, 780 + 52], radius=16, fill=(217, 229, 221, 255))

    img = Image.alpha_composite(img, overlay).convert("RGB")
    img.save(out_path, "PNG")
    print("saved", out_path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(OUT_DEFAULT)
    main(out)
