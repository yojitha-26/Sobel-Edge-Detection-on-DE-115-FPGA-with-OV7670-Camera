# ---------------- clocks ----------------
create_clock -name clk50    -period 20.000 [get_ports CLOCK_50]
create_clock -name cam_pclk -period 40.000 [get_ports CAM_PCLK]   ;# ~25 MHz from the OV7670
derive_clock_uncertainty

# The two domains only meet inside the dual-clock frame buffer
set_clock_groups -asynchronous -group {clk50} -group {cam_pclk}

# ---------------- camera inputs ----------------
# OV7670 launches data on PCLK falling edge (tPDV ~5 ns); FPGA captures on rising
set_input_delay -clock cam_pclk -clock_fall -max 5.0 [get_ports {CAM_D[*] CAM_HREF CAM_VSYNC}]
set_input_delay -clock cam_pclk -clock_fall -min 0.0 [get_ports {CAM_D[*] CAM_HREF CAM_VSYNC}]

# ---------------- slow / static I/O ----------------
# VGA data changes on the 50 MHz edge where VGA_CLK falls; the DAC samples on the
# VGA_CLK rising edge 20 ns later (by construction), so no output constraint needed.
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LEDR[*] LEDG[*] VGA_* CAM_XCLK CAM_SIOC CAM_SIOD CAM_RESET CAM_PWDN}]
