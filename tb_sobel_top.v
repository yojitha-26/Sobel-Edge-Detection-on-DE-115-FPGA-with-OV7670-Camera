// ============================================================================
// tb_sobel_top.v  -  full-system testbench: colour / gray / blur / edges
//   * OV7670 model streams camA.hex / camB.hex (exact YUYV bytes) continuously
//     at ~25 MHz PCLK, asynchronous to CLOCK_50; it ACKs every SCCB byte
//   * every view is checked by sampling R, G, B at the VGA DAC pins for a
//     whole frame and comparing against the Python golden model (check.py)
//   * scenario: live colour -> gray -> edges -> blur 3x3 / 5x5 -> binary
//               -> freeze (camera changes, image must not) -> KEY1 new
//               snapshot -> view change while frozen re-captures the frame
// ============================================================================
`timescale 1ns/1ps
module tb_sobel_top;
    localparam W = 640, H = 480;

    reg         clk50 = 0;
    always #10 clk50 = ~clk50;

    reg  [3:0]  KEY = 4'b1110;
    reg  [17:0] SW  = 18'd0;
    wire [17:0] LEDR;
    wire [8:0]  LEDG;

    reg         pclk = 0;
    always #19.85 pclk = ~pclk;          // 25.19 MHz, drifts against CLOCK_50
    reg         vsync = 1, href = 0;
    reg  [7:0]  cam_d = 0;

    wire xclk, sioc, cam_reset, cam_pwdn;
    wire siod;
    pullup (siod);                       // models the FPGA's weak internal pull-up only

    // camera side of SCCB: drives ACK low during the 9th bit of every byte
    reg  cam_ack = 0;
    assign siod = cam_ack ? 1'b0 : 1'bz;
    integer sccb_conflicts = 0;
    always @(siod) if (siod === 1'bx) sccb_conflicts = sccb_conflicts + 1;

    wire [7:0] VGA_R, VGA_G, VGA_B;
    wire VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N;

    sobel_top #(.SETTLE_FRAMES(0)) dut (
        .CLOCK_50(clk50), .KEY(KEY), .SW(SW), .LEDR(LEDR), .LEDG(LEDG),
        .CAM_XCLK(xclk), .CAM_PCLK(pclk), .CAM_VSYNC(vsync), .CAM_HREF(href),
        .CAM_D(cam_d), .CAM_SIOC(sioc), .CAM_SIOD(siod),
        .CAM_RESET(cam_reset), .CAM_PWDN(cam_pwdn),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_CLK(VGA_CLK),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_BLANK_N(VGA_BLANK_N),
        .VGA_SYNC_N(VGA_SYNC_N)
    );

    integer errors = 0;

    // ---------------- camera model ----------------
    reg [7:0] camA [0:W*H*2-1];
    reg [7:0] camB [0:W*H*2-1];
    initial begin $readmemh("camA.hex", camA); $readmemh("camB.hex", camB); end
    reg scene = 0;                       // 0 = A, 1 = B

    // OV7670 drives data on PCLK falling edge; FPGA samples on rising edge
    task send_frame;
        integer r, c;
        reg sel;
        begin
            sel = scene;                 // scene is fixed for the whole frame
            @(negedge pclk) vsync = 1;   // frame start
            repeat (3 * 1568) @(negedge pclk);
            vsync = 0;
            repeat (200) @(negedge pclk);
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W*2; c = c + 1) begin
                    @(negedge pclk);
                    href  = 1;
                    cam_d = sel ? camB[r*W*2 + c] : camA[r*W*2 + c];
                end
                @(negedge pclk) href = 0; cam_d = 8'hxx;
                repeat (40) @(negedge pclk);
            end
            repeat (100) @(negedge pclk);
        end
    endtask
    initial begin #300; forever send_frame; end

    // ---------------- SCCB monitor + ACK ----------------
    reg [7:0]  sccb_byte; reg [3:0] sccb_bit; reg [7:0] sccb_bytes [0:2];
    integer    sccb_bc = 0, sccb_writes = 0;
    reg        in_xfer = 0;
    always @(negedge siod) if (sioc === 1'b1) begin in_xfer = 1; sccb_bit = 0; sccb_bc = 0; end
    always @(posedge siod) if (sioc === 1'b1 && in_xfer) begin
        in_xfer = 0;
        if (sccb_bc == 3) begin
            sccb_writes = sccb_writes + 1;
            if (sccb_bytes[0] !== 8'h42) begin $display("ERROR: bad SCCB id"); errors = errors + 1; end
        end else begin
            $display("ERROR: SCCB transfer with %0d bytes", sccb_bc); errors = errors + 1;
        end
    end
    always @(negedge sioc) begin         // camera drives ACK ~200 ns after SCL falls
        if (in_xfer && sccb_bit == 8 && !cam_ack) #200 cam_ack = 1;
        else if (cam_ack)                         #200 cam_ack = 0;
    end
    always @(posedge sioc) if (in_xfer) begin
        if (sccb_bit < 8) sccb_byte = {sccb_byte[6:0], (siod === 1'b0) ? 1'b0 : 1'b1};
        sccb_bit = sccb_bit + 1;
        if (sccb_bit == 9) begin sccb_bytes[sccb_bc] = sccb_byte; sccb_bc = sccb_bc + 1; sccb_bit = 0; end
    end

    // ---------------- VGA timing monitor ----------------
    time t_hs = 0, t_vs = 0; integer hs_bad = 0, vs_bad = 0, hs_n = 0, vs_n = 0;
    always @(negedge VGA_HS) begin
        if (t_hs != 0) begin hs_n = hs_n + 1; if ($time - t_hs != 32000) hs_bad = hs_bad + 1; end
        t_hs = $time;
    end
    always @(negedge VGA_VS) begin
        if (t_vs != 0) begin vs_n = vs_n + 1; if ($time - t_vs != 32000*525) vs_bad = vs_bad + 1; end
        t_vs = $time;
    end

    // ---------------- helpers ----------------
    reg [23:0] vga_cap [0:W*H-1];

    task wait_frames(input integer n);   // camera frame starts seen by the FPGA
        integer k;
        for (k = 0; k < n; k = k + 1) @(posedge dut.frame_start);
    endtask

    // sample one full VGA frame at the DAC pins (R,G,B on VGA_CLK rising)
    task capture_vga(input [8*24-1:0] fname);
        integer n;
        begin
            @(negedge VGA_VS); @(posedge VGA_VS);
            n = 0;
            while (n < W*H) begin
                @(posedge VGA_CLK);
                if (VGA_BLANK_N) begin
                    vga_cap[n] = {VGA_R, VGA_G, VGA_B};
                    n = n + 1;
                end
            end
            $writememh(fname, vga_cap);
            $display("   captured %0s", fname);
        end
    endtask

    // set switches, let one complete camera frame land in the new format, sample
    task view(input [17:0] sw, input [8*24-1:0] fname);
        begin
            SW = sw;
            wait_frames(2);
            capture_vga(fname);
        end
    endtask

    localparam S_GRAY = 18'h1, S_EDGE = 18'h2, S_BIN = 18'h4, S_FRZ = 18'h8,
               S_BLUR = 18'h10, S_B5 = 18'h20;
    localparam [17:0] THR64 = 18'd64 << 10;

    initial begin
        $display("== reset, camera streaming scene A");
        #200 KEY[0] = 1;
        @(posedge LEDG[0]);
        $display("   camera configured: SCCB writes=%0d  SIOD bus conflicts=%0d", sccb_writes, sccb_conflicts);
        if (sccb_writes != 17 || sccb_conflicts != 0) errors = errors + 1;

        $display("== live views of scene A");
        view(18'd0,                          "out_A_color.hex");
        view(S_GRAY,                         "out_A_gray.hex");
        view(S_EDGE,                         "out_A_edge.hex");
        view(S_EDGE | S_BIN | THR64,         "out_A_bin_64.hex");
        view(S_EDGE | S_BLUR,                "out_A_edge_b3.hex");
        view(S_GRAY | S_BLUR,                "out_A_gray_b3.hex");
        view(S_GRAY | S_BLUR | S_B5,         "out_A_gray_b5.hex");
        view(S_EDGE | S_BLUR | S_B5,         "out_A_edge_b5.hex");
        view(S_EDGE | S_BLUR | S_B5 | S_BIN | THR64, "out_A_bin_b5_64.hex");

        $display("== freeze (SW3) on edges+blur5, then camera switches to scene B");
        SW = S_EDGE | S_BLUR | S_B5 | S_FRZ;
        wait_frames(2);
        if (LEDG[3] !== 1'b1) begin $display("ERROR: freeze LED"); errors = errors + 1; end
        scene = 1;
        wait_frames(3);
        capture_vga("out_A_frozen.hex");      // must still be scene A

        $display("== KEY1 -> new snapshot of scene B");
        KEY[1] = 0; #2000 KEY[1] = 1;
        wait_frames(3);
        capture_vga("out_B_edge_b5.hex");

        $display("== change view while frozen -> colour frame of B is captured automatically");
        SW = S_FRZ;
        wait_frames(3);
        capture_vga("out_B_color.hex");

        $display("== back to live, gray of scene B");
        view(S_GRAY,                         "out_B_gray.hex");

        $display("== VGA lines checked %0d (bad %0d), frames %0d (bad %0d)", hs_n, hs_bad, vs_n, vs_bad);
        if (hs_bad || vs_bad || vs_n < 10) errors = errors + 1;
        $display("== TB internal errors: %0d", errors);
        $finish;
    end
endmodule
