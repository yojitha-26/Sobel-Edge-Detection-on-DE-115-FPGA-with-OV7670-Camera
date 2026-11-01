#!/bin/sh
# Usage: ./run_sim.sh      (needs iverilog, python3, numpy, pillow)
set -e
cd "$(dirname "$0")"
python3 gen_image.py .
iverilog -g2005 -o tb.vvp tb_sobel_top.v ../rtl/*.v
vvp -n tb.vvp | grep -v "^ *captured"
python3 check.py
