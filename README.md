# Live Colour / Grayscale / Sobel Edge Video — OV7670 → DE2-115 → VGA

Real-time video from an OV7670 camera, shown on a VGA monitor at 640×480 in
three views chosen with switches: **colour**, **grayscale** and **Sobel edges**.
A switchable **Gaussian blur** (3×3 or 5×5) removes sensor noise before edge
detection, and a **freeze** switch turns the live feed into a snapshot.
Pure Verilog: no Nios II, no SDRAM, no IP cores, no PLL.

```
                 SCCB config (unchanged, YUV422 640×480)        CLOCK_50 domain
 ┌────────┐ ◄─────────────────────────── ov7670_config ◄──────────────────────────┐
 │ OV7670 │ ◄── XCLK 25 MHz                                                      │
 └───┬────┘ PCLK, VSYNC, HREF, D[7:0]                 CAM_PCLK domain            │
     ▼                                                                           │
 ov7670_capture ──Y,U,V──┬──────────────────────► fb_writer ──► frame_buffer ──► vga_sobel ──► ADV7123 ──► monitor
 bytes → pixels          └──Y──► gauss_blur ─────►  colour: YUV→RGB,   640×480×8   colour: RGB332 → 8:8:8
                                 3×3 / 5×5          dither, RGB332      (M9K)       gray:   Y
                                                    gray:  Y or blurred Y           edges:  Sobel 3×3 on the fly
                         snapshot_ctrl ─ live / freeze / re-capture ─┘
```

## Controls

**All switches down = live colour video.**

| Control | Function |
|---|---|
| **SW[0]** | **Grayscale** view |
| **SW[1]** | **Edge** view (Sobel), has priority over SW[0] |
| SW[2] | Binary (black/white) edges, using threshold SW[17:10] |
| **SW[3]** | **Freeze**: hold the current frame (snapshot mode) |
| **SW[4]** | **Gaussian blur ON**: noise filter for the grayscale and edge views |
| SW[5] | Blur strength: 0 = 3×3 (light) · 1 = 5×5 (strong) |
| SW[6] | Luma byte phase: flip if the picture looks striped or garbled |
| SW[7] | Swap U/V: flip if red and blue look swapped in colour view |
| SW[17:10] | Edge threshold 0–255 (SW17 = 128 … SW10 = 1) |
| KEY[0] | Reset: reconfigures the camera |
| KEY[1] | New snapshot (while frozen) |

| LED | Meaning |
|---|---|
| LEDG[0] | Camera configured |
| LEDG[1] | A complete frame has been stored |
| LEDG[2] | Gaussian blur active |
| LEDG[3] | Frozen (SW[3] up) |
| LEDR[0] | Toggles every camera frame |
| LEDR[1] | Blinks while PCLK is running |
| LEDR[2] | Writing a frame to memory |

**Demo sequence:** colour (all down) → SW0 up (grayscale) → SW1 up (edges, noisy
background) → SW4 up (blur: background noise disappears) → SW5 up (stronger blur)
→ SW2 up + threshold 64 (SW16) for clean black/white outlines → SW3 up to freeze.

## How it works

* **Colour without changing the camera.** The camera stays in YUV422 mode,
  which was already proven on the board. The FPGA converts each pixel to RGB with
  integer BT.601 maths (3 constant multipliers), then stores it as **RGB332**
  (3+3+2 bits) so a 640×480 colour frame fits in on-chip RAM. A 4×4 ordered
  (Bayer) **dither** before truncation hides most of the colour banding.
* **One buffer, three views.** On-chip RAM holds one 640×480×8 frame. In
  colour view it holds RGB332; in grayscale and edge views it holds luma (raw or
  blurred). The feed is live, so after a switch change the very next camera frame
  (≤ 1/30 s) is stored in the new format. While frozen, a view change triggers
  one automatic re-capture.
* **Gaussian blur on the way in.** `gauss_blur` uses four line buffers and a
  separable kernel: vertical column sums first, then horizontal. It outputs the
  3×3 (1-2-1)/16 or 5×5 (1-4-6-4-1)²/256 result, rounded, centred on the same
  pixel. Both sizes are always computed, so switching size is instant. The 2-pixel
  image rim keeps raw values, and edge view blanks a 3-pixel border when blur is
  on so the rim never shows as a false edge.
* **Sobel on the way out.** `vga_sobel` reads one row ahead of the display, keeps
  two line buffers and a 3×3 window, and computes |Gx| + |Gy| (saturated to 255)
  while the screen is drawn.
* **Every address is written once per frame** (raw or blurred, never both), so
  the display never shows a half-updated pixel.

## Files

| Path | Purpose |
|---|---|
| `rtl/sobel_top.v` | Top level: ports, resets, XCLK, switch synchronisers, LEDs |
| `rtl/ov7670_config.v` | SCCB master + camera register table (push-pull, no pull-ups needed) |
| `rtl/ov7670_capture.v` | Byte stream → pixels (Y + latest U/V) with column/row |
| `rtl/gauss_blur.v` | 3×3 / 5×5 Gaussian blur, 4 line buffers, separable |
| `rtl/fb_writer.v` | YUV→RGB, dither, RGB332 / gray / blurred-gray write selection |
| `rtl/snapshot_ctrl.v` | Live / freeze / KEY1 / view-change re-capture control |
| `rtl/frame_buffer.v` | 640×480×8 dual-clock RAM |
| `rtl/vga_sobel.v` | VGA timing, colour expansion, 3×3 Sobel window, borders |
| `rtl/sobel3x3.v` | Combinational Sobel operator |
| `quartus/` | `.qpf`, `.qsf` (all pins), `.sdc` (timing), `sobel_pins.tcl` |
| `sim/` | Full-system testbench, camera model, golden Python model |

## Wiring: OV7670 → DE2-115 JP5 (unchanged)

| OV7670 pin | FPGA signal | GPIO | JP5 header pin |
|---|---|---|---|
| 3.3V | — | — | **29** (3.3 V) |
| GND | — | — | **30** (or 12) |
| SIOC (SCL) | CAM_SIOC | GPIO[0] | 1 |
| SIOD (SDA) | CAM_SIOD | GPIO[1] | 2 |
| VSYNC | CAM_VSYNC | GPIO[2] | 3 |
| HREF | CAM_HREF | GPIO[3] | 4 |
| PCLK | CAM_PCLK | GPIO[4] | 5 |
| XCLK | CAM_XCLK | GPIO[5] | 6 |
| D7 / D6 / D5 / D4 | CAM_D[7:4] | GPIO[6..9] | 7 / 8 / 9 / 10 |
| D3 / D2 / D1 / D0 | CAM_D[3:0] | GPIO[10..13] | 13 / 14 / 15 / 16 |
| RESET | CAM_RESET (driven 1) | GPIO[14] | 17 |
| PWDN | CAM_PWDN (driven 0) | GPIO[15] | 18 |

* **Do not use header pin 11 — it is 5 V.** Leave JP6 at **3.3 V**.
* No pull-up resistors are needed.

## Build & run

1. Open `quartus/sobel_edge.qpf`, then Processing → Start Compilation.
2. Tools → Programmer → USB-Blaster → `output_files/sobel_edge.sof` → Start.
3. With all switches down, live colour video appears about half a second later.

## Bring-up checklist

| Symptom | Likely cause / fix |
|---|---|
| Monitor says "no signal" | VGA cable, monitor input, or bitstream not loaded |
| LEDR[1] not blinking | No PCLK → XCLK wire, 3.3 V/GND, PWDN low, RESET high |
| Grayscale striped / garbled | Flip **SW[6]** (byte phase) |
| Colours wrong: red ↔ blue swapped | Flip **SW[7]** (U/V swap) |
| Colours all green/purple tinted | Byte phase wrong → flip SW[6] first |
| Grainy speckles in edge view | **SW[4]** blur on; SW[5] for 5×5; then SW[2] + threshold 64–96 |
| Edges too faint with 5×5 blur | Use 3×3 (SW[5] down) or lower the threshold |
| Brief flicker when changing view | Normal: one frame is written in the new format |
| Tearing on fast motion (live) | Normal: camera 30 fps vs monitor 60 Hz; freeze with SW[3] |

## Simulation

```
cd sim && ./run_sim.sh        # needs iverilog, python3, numpy, pillow  (~10 min)
```

A camera model streams two noisy colour scenes as exact YUYV bytes at ~25 MHz,
asynchronous to CLOCK_50. R, G and B are sampled at the VGA pins for a full frame
in every view and compared against a Python golden model that uses the same
integer maths.

Results (every pixel of every view, R, G and B, bit-exact):

```
camera configured: SCCB writes=17  SIOD bus conflicts=0
VGA lines checked 28303 (bad 0), frames 52 (bad 0)
VGA A_color      : 307200/307200 pixels match   PASS
VGA A_gray       : 307200/307200 pixels match   PASS
VGA A_edge       : 307200/307200 pixels match   PASS
VGA A_bin_64     : 307200/307200 pixels match   PASS
VGA A_edge_b3    : 307200/307200 pixels match   PASS
VGA A_gray_b3    : 307200/307200 pixels match   PASS
VGA A_gray_b5    : 307200/307200 pixels match   PASS
VGA A_edge_b5    : 307200/307200 pixels match   PASS
VGA A_bin_b5_64  : 307200/307200 pixels match   PASS
VGA A_frozen     : 307200/307200 pixels match   PASS   (camera showed B, screen kept A)
VGA B_edge_b5    : 307200/307200 pixels match   PASS   (after KEY1)
VGA B_color      : 307200/307200 pixels match   PASS   (view change while frozen)
VGA B_gray       : 307200/307200 pixels match   PASS
```

Noise test (binary edges, threshold 64, plain background strip): 1427 false edge
pixels without blur, 297 with 5×5 blur (about 80 % fewer).

![simulation result](docs/sim_result.png)
