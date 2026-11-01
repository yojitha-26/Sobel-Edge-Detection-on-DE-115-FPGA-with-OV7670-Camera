// ============================================================================
// vga_sobel.v
// Reads the frame buffer, runs the 3x3 Sobel filter on the fly while the
// screen is scanned, and drives the DE2-115 ADV7123 VGA DAC.
// 640x480 @ 60 Hz, all logic on CLOCK_50 with a 25 MHz pixel clock-enable.
//
// Read-ahead scheme
//   While display line v is being scanned, row v+1 is read from the frame
//   buffer (row 0 is read during the last blanking line).  Two line buffers
//   hold rows v and v-1, so the 3x3 window is centred exactly on (h, v) once
//   the sync/blank signals are delayed by the 2-pixel pipeline.
//
//   Views (the frame buffer holds the matching format, see fb_writer):
//     mode_edge = 1             : Sobel edges of the stored grayscale image
//                                 (mode_bin = 1 -> 255 if |G| >= thresh, else 0)
//     mode_edge = 0, mode_gray=1: grayscale image
//     mode_edge = 0, mode_gray=0: colour image, RGB332 expanded to 8:8:8
//   The 1-pixel border (no full 3x3 neighbourhood) is shown black; with
//   wide_border = 1 (edges of a blurred image) a 3-pixel border is used, so
//   the un-blurred 2-pixel rim does not show up as a false edge.
//
// H: 640 visible + 16 FP + 96 sync + 48 BP = 800    (negative sync)
// V: 480 visible + 10 FP +  2 sync + 33 BP = 525    (negative sync)
// ============================================================================
module vga_sobel (
    input  wire        clk,          // 50 MHz
    input  wire        rst_n,
    input  wire        mode_edge,
    input  wire        mode_gray,
    input  wire        mode_bin,
    input  wire        wide_border,
    input  wire [7:0]  thresh,

    output wire [18:0] fb_raddr,
    input  wire [7:0]  fb_rdata,     // 1-cycle (50 MHz) read latency

    output reg  [7:0]  vga_r,
    output reg  [7:0]  vga_g,
    output reg  [7:0]  vga_b,
    output reg         vga_hs,
    output reg         vga_vs,
    output reg         vga_blank_n,
    output wire        vga_sync_n,
    output wire        vga_clk
);
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

    // ---------------- 25 MHz pixel enable / VGA_CLK ----------------
    reg pix_ce;
    always @(posedge clk) begin
        if (!rst_n) pix_ce <= 1'b0;
        else        pix_ce <= ~pix_ce;
    end
    assign vga_clk    = pix_ce;      // rises mid-pixel: 20 ns setup / hold
    assign vga_sync_n = 1'b0;

    // ---------------- scan counters ----------------
    reg [9:0] h, v;
    always @(posedge clk) begin
        if (!rst_n) begin
            h <= 10'd0; v <= 10'd0;
        end else if (pix_ce) begin
            if (h == H_TOT-1) begin
                h <= 10'd0;
                v <= (v == V_TOT-1) ? 10'd0 : v + 10'd1;
            end else
                h <= h + 10'd1;
        end
    end

    // ---------------- frame-buffer read, one row ahead ----------------
    wire [9:0] rr    = (v == V_TOT-1) ? 10'd0 : v + 10'd1;
    wire       rd_ok = (h < H_VIS) && (rr < V_VIS);
    assign fb_raddr  = rd_ok ? ({rr[8:0], 9'b0} + {2'b0, rr[8:0], 7'b0} + {9'b0, h})
                             : 19'd0;
    // fb_rdata for (h, rr) is valid at the next pix_ce edge, while h is unchanged
    wire [7:0] new_px = rd_ok ? fb_rdata : 8'd0;

    // ---------------- line buffers (rows v and v-1) ----------------
    (* ramstyle = "M9K" *) reg [7:0] lb1 [0:1023];   // row v
    (* ramstyle = "M9K" *) reg [7:0] lb2 [0:1023];   // row v-1
    reg [7:0] lb1_q, lb2_q;
    wire      shift = pix_ce && (h <= H_VIS);        // 641 columns per line

    always @(posedge clk) begin
        lb1_q <= lb1[h];                             // ready by the pix_ce edge
        lb2_q <= lb2[h];
        if (shift) begin
            lb1[h] <= new_px;
            lb2[h] <= lb1_q;
        end
    end

    // ---------------- 3x3 window ----------------
    reg [7:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    always @(posedge clk) begin
        if (!rst_n)
            {w00,w01,w02,w10,w11,w12,w20,w21,w22} <= 72'd0;
        else if (shift) begin
            w00 <= w01;  w01 <= w02;  w02 <= lb2_q;    // row v-1
            w10 <= w11;  w11 <= w12;  w12 <= lb1_q;    // row v
            w20 <= w21;  w21 <= w22;  w22 <= new_px;   // row v+1
        end
    end

    wire [7:0] mag;
    sobel3x3 u_sobel (
        .p00(w00), .p01(w01), .p02(w02),
        .p10(w10), .p11(w11), .p12(w12),
        .p20(w20), .p21(w21), .p22(w22),
        .mag(mag)
    );
    wire [7:0] edge_v = mode_bin ? ((mag >= thresh) ? 8'd255 : 8'd0) : mag;

    // ---------------- display timing, delayed 2 pixels to match ----------------
    reg [9:0] h1, v1, hd, vd;
    always @(posedge clk) begin
        if (!rst_n) begin
            h1 <= 10'd0; v1 <= 10'd0; hd <= 10'd0; vd <= 10'd0;
        end else if (pix_ce) begin
            h1 <= h;  v1 <= v;
            hd <= h1; vd <= v1;
        end
    end

    wire visible = (hd < H_VIS) && (vd < V_VIS);
    wire [9:0] bw = (mode_edge && wide_border) ? 10'd3 : 10'd1;
    wire border  = (hd < bw) || (hd >= H_VIS - bw) || (vd < bw) || (vd >= V_VIS - bw);
    wire show    = visible && !border;

    // RGB332 -> 8:8:8 by bit replication
    wire [7:0] c_r = {w11[7:5], w11[7:5], w11[7:6]};
    wire [7:0] c_g = {w11[4:2], w11[4:2], w11[4:3]};
    wire [7:0] c_b = {w11[1:0], w11[1:0], w11[1:0], w11[1:0]};

    wire [7:0] gray_px = mode_edge ? edge_v : w11;
    wire [7:0] out_r = !show ? 8'd0 : (mode_edge || mode_gray) ? gray_px : c_r;
    wire [7:0] out_g = !show ? 8'd0 : (mode_edge || mode_gray) ? gray_px : c_g;
    wire [7:0] out_b = !show ? 8'd0 : (mode_edge || mode_gray) ? gray_px : c_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            vga_r <= 8'd0; vga_g <= 8'd0; vga_b <= 8'd0;
            vga_hs <= 1'b1; vga_vs <= 1'b1; vga_blank_n <= 1'b0;
        end else if (pix_ce) begin
            vga_hs      <= ~((hd >= H_VIS + H_FP) && (hd < H_VIS + H_FP + H_SYNC));
            vga_vs      <= ~((vd >= V_VIS + V_FP) && (vd < V_VIS + V_FP + V_SYNC));
            vga_blank_n <= visible;
            vga_r <= out_r;  vga_g <= out_g;  vga_b <= out_b;
        end
    end
endmodule
