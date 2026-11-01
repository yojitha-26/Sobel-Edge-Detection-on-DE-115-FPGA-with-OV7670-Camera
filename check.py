#!/usr/bin/env python3
"""Compare frames sampled at the VGA DAC pins (R,G,B) against the golden model."""
import numpy as np, sys, os
from PIL import Image
W, H = 640, 480

def load(f):
    v = [int(l, 16) if 'x' not in l.lower() else -1
         for l in open(f) if l.strip() and not l.startswith('//')]
    a = np.array(v, np.int64).reshape(H, W)
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.int32)

CHECKS = [("A_color", "A_color"), ("A_gray", "A_gray"), ("A_edge", "A_edge"),
          ("A_bin_64", "A_bin_64"), ("A_edge_b3", "A_edge_b3"), ("A_gray_b3", "A_gray_b3"),
          ("A_gray_b5", "A_gray_b5"), ("A_edge_b5", "A_edge_b5"),
          ("A_bin_b5_64", "A_bin_b5_64"),
          ("A_frozen", "A_edge_b5"),          # frozen: camera shows B, screen keeps A
          ("B_edge_b5", "B_edge_b5"), ("B_color", "B_color"), ("B_gray", "B_gray")]
ok = True
for got_name, exp_name in CHECKS:
    got = load(f"out_{got_name}.hex")
    ref = np.load(f"exp_{exp_name}.npy")
    bad = np.argwhere(np.any(got != ref, axis=-1))
    print(f"VGA {got_name:12s} vs {exp_name:12s}: {H*W - len(bad):6d}/{H*W} pixels match  ",
          "PASS" if not len(bad) else f"FAIL e.g. {bad[:3].tolist()}")
    ok &= not len(bad)
    Image.fromarray(np.clip(got, 0, 255).astype(np.uint8)).save(f"rtl_{got_name}.png")
sys.exit(0 if ok else 1)
