#!/usr/bin/env python3
"""Golden model for the OV7670 colour / gray / blur / Sobel design.

Builds two colour test scenes (A, B), turns them into the exact YUYV byte
stream the camera model sends, and computes - with the same integer maths
as the RTL - what the VGA pins must show for every view:

  colour      : YUV -> RGB, 4x4 Bayer dither, RGB332, expanded to 8:8:8
  gray        : luma (raw / 3x3 Gaussian / 5x5 Gaussian)
  edge        : Sobel |Gx|+|Gy| on the stored image, optional binary threshold
"""
import numpy as np
from PIL import Image, ImageDraw
import sys, os

W, H = 640, 480
out = sys.argv[1] if len(sys.argv) > 1 else "."
rng = np.random.default_rng(7)

# ----------------------------------------------------------------- scenes
def scene_a():
    img = Image.new("RGB", (W, H), (60, 70, 90))
    d = ImageDraw.Draw(img)
    for x in range(W):                                   # hue ramp band
        t = x / (W - 1)
        d.line([(x, 0), (x, 60)], fill=(int(255 * t), int(255 * (1 - abs(2 * t - 1))), int(255 * (1 - t))))
    d.rectangle([60, 100, 260, 300], fill=(220, 40, 40))
    d.ellipse([330, 120, 560, 350], fill=(40, 180, 60), outline=(250, 250, 80), width=4)
    d.polygon([(100, 460), (300, 330), (420, 460)], fill=(50, 90, 230))
    d.line([(20, 470), (620, 380)], fill=(255, 255, 255), width=3)
    d.text((450, 410), "DE2-115 COLOUR", fill=(255, 255, 0))
    return img

def scene_b():
    img = Image.new("RGB", (W, H), (200, 190, 170))
    d = ImageDraw.Draw(img)
    for i in range(8):
        d.rectangle([i * 80, 380, i * 80 + 39, 470], fill=(20, 20, 120))
    d.ellipse([60, 60, 300, 300], fill=(240, 140, 30))
    d.rectangle([360, 80, 600, 320], outline=(0, 0, 0), width=6)
    d.line([(0, 0), (639, 360)], fill=(160, 0, 160), width=2)
    d.text((380, 190), "SNAPSHOT B", fill=(0, 0, 0))
    return img

def noisy(img):           # sensor-like noise, so the Gaussian blur has work to do
    a = np.asarray(img, dtype=np.int32)
    return np.clip(a + rng.integers(-14, 15, a.shape), 0, 255).astype(np.uint8)

def rgb_to_yuyv(a):
    a = a.astype(np.float64)
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    Y = 0.299 * R + 0.587 * G + 0.114 * B
    U = -0.169 * R - 0.331 * G + 0.5 * B + 128
    V = 0.5 * R - 0.419 * G - 0.081 * B + 128
    Y = np.clip(np.round(Y), 0, 255).astype(np.int32)
    Up = np.clip(np.round((U[:, 0::2] + U[:, 1::2]) / 2), 0, 255).astype(np.int32)
    Vp = np.clip(np.round((V[:, 0::2] + V[:, 1::2]) / 2), 0, 255).astype(np.int32)
    stream = np.zeros((H, W * 2), np.int32)
    stream[:, 0::4] = Y[:, 0::2]
    stream[:, 1::4] = Up
    stream[:, 2::4] = Y[:, 1::2]
    stream[:, 3::4] = Vp
    return stream

# ----------------------------------------------------------------- RTL models
BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]])

def capture(stream):
    """Per-pixel (Y, latest U, latest V) exactly like ov7670_capture.v
    (U/V carry over from the previous line; the scene repeats every frame)."""
    Y = stream[:, 0::2]
    u_lat = v_lat = 128
    # run twice so frame-to-frame carry-over matches a repeating camera
    for _ in range(2):
        Ua = np.zeros((H, W), np.int32); Va = np.zeros((H, W), np.int32)
        for r in range(H):
            for c in range(W):
                Ua[r, c], Va[r, c] = u_lat, v_lat
                ch = stream[r, 2 * c + 1]
                if c % 2 == 0: u_lat = ch
                else:          v_lat = ch
    return Y, Ua, Va

def to_rgb332(Y, U, V):
    uu, vv = U - 128, V - 128
    R = np.clip(Y + ((359 * vv) >> 8), 0, 255)
    G = np.clip(Y - ((88 * uu + 183 * vv) >> 8), 0, 255)
    B = np.clip(Y + ((454 * uu) >> 8), 0, 255)
    yy, xx = np.mgrid[0:H, 0:W]
    b = BAYER[yy & 3, xx & 3]
    r3 = np.minimum(R + 2 * b, 511); r3 = np.where(r3 > 255, 7, r3 >> 5)
    g3 = np.minimum(G + 2 * b, 511); g3 = np.where(g3 > 255, 7, g3 >> 5)
    b2 = np.minimum(B + 4 * b, 511); b2 = np.where(b2 > 255, 3, b2 >> 6)
    return (r3 << 5) | (g3 << 2) | b2

def expand332(p):
    r3, g3, b2 = (p >> 5) & 7, (p >> 2) & 7, p & 3
    return np.stack([(r3 << 5) | (r3 << 2) | (r3 >> 1),
                     (g3 << 5) | (g3 << 2) | (g3 >> 1),
                     (b2 << 6) | (b2 << 4) | (b2 << 2) | b2], -1)

def gauss(Y, size5):
    Y = Y.astype(np.int64)
    out = Y.copy()                                       # 2-px rim stays raw
    k = [1, 4, 6, 4, 1] if size5 else [0, 1, 2, 1, 0]
    sh, rnd = (8, 128) if size5 else (4, 8)
    acc = np.zeros((H - 4, W - 4), np.int64)
    for dy in range(5):
        for dx in range(5):
            acc += k[dy] * k[dx] * Y[dy:H - 4 + dy, dx:W - 4 + dx]
    out[2:H - 2, 2:W - 2] = (acc + rnd) >> sh
    return out

def sobel(a):
    a = a.astype(np.int64)
    p = lambda dy, dx: a[1 + dy:H - 1 + dy, 1 + dx:W - 1 + dx]
    gx = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
    gy = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
    o = np.zeros((H, W), np.int64)
    o[1:H - 1, 1:W - 1] = np.minimum(np.abs(gx) + np.abs(gy), 255)
    return o

def border(img, bw):
    o = np.zeros_like(img)
    o[bw:H - bw, bw:W - bw] = img[bw:H - bw, bw:W - bw]
    return o

def gray3(img):  return np.repeat(img[..., None], 3, -1)

# ----------------------------------------------------------------- expected views
for name, fn in (("A", scene_a), ("B", scene_b)):
    a = noisy(fn())
    Image.fromarray(a).save(os.path.join(out, f"scene_{name}.png"))
    s = rgb_to_yuyv(a)
    with open(os.path.join(out, f"cam{name}.hex"), "w") as f:
        f.write("\n".join(f"{v:02x}" for v in s.flatten()))
    Y, U, V = capture(s)
    exp = {
        "color":      border(expand332(to_rgb332(Y, U, V)), 1),
        "gray":       gray3(border(Y, 1)),
        "edge":       gray3(border(sobel(Y), 1)),
        "gray_b3":    gray3(border(gauss(Y, False), 1)),
        "gray_b5":    gray3(border(gauss(Y, True), 1)),
        "edge_b3":    gray3(border(sobel(gauss(Y, False)), 3)),
        "edge_b5":    gray3(border(sobel(gauss(Y, True)), 3)),
        "bin_b5_64":  gray3(border(np.where(sobel(gauss(Y, True)) >= 64, 255, 0), 3)),
        "bin_64":     gray3(border(np.where(sobel(Y) >= 64, 255, 0), 1)),
    }
    for k, v in exp.items():
        np.save(os.path.join(out, f"exp_{name}_{k}.npy"), v.astype(np.int32))
print("scenes A, B + golden views written")
