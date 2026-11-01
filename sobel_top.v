// ============================================================================
// sobel_top.v  -  DE2-115 top level
//   Live colour / grayscale / Sobel-edge video from an OV7670, with optional
//   Gaussian noise filtering and a freeze (snapshot) mode.
//
//   OV7670 -> capture (Y,U,V) -+-> gauss_blur --+
//                              +-----------------+-> fb_writer -> frame buffer
//                                                   (RGB332 or gray)    |
//                         VGA <- colour / gray / Sobel 3x3 (vga_sobel) <+
//
// Controls (all switches down = live colour video)
//   SW[0]      : grayscale view
//   SW[1]      : edge view (Sobel)                 - has priority over SW[0]
//   SW[2]      : binary edges, threshold SW[17:10]
//   SW[3]      : freeze (snapshot mode); KEY[1] takes a new snapshot
//   SW[4]      : Gaussian blur ON (noise filter for grayscale & edge views)
//   SW[5]      : blur strength  0 = 3x3 (light)  1 = 5x5 (strong)
//   SW[6]      : luma byte phase (flip if the image looks striped/garbled)
//   SW[7]      : swap U/V (flip if red and blue look swapped)
//   SW[17:10]  : edge threshold (0..255)
//   KEY[0]     : reset (re-configures the camera)
//   KEY[1]     : new snapshot (while frozen)
// Status
//   LEDG[0] camera configured   LEDG[1] image stored     LEDG[2] blur active
//   LEDG[3] frozen              LEDR[0] frame heartbeat  LEDR[1] PCLK alive
//   LEDR[2] writing a frame
// ============================================================================
module sobel_top #(
    parameter SETTLE_FRAMES = 15
)(
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    output wire [17:0] LEDR,
    output wire [8:0]  LEDG,

    // OV7670 on the JP5 (GPIO) header
    output wire        CAM_XCLK,
    input  wire        CAM_PCLK,
    input  wire        CAM_VSYNC,
    input  wire        CAM_HREF,
    input  wire [7:0]  CAM_D,
    output wire        CAM_SIOC,
    inout  wire        CAM_SIOD,
    output wire        CAM_RESET,   // active low on the module
    output wire        CAM_PWDN,    // active high on the module

    // VGA (ADV7123)
    output wire [7:0]  VGA_R,
    output wire [7:0]  VGA_G,
    output wire [7:0]  VGA_B,
    output wire        VGA_CLK,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire        VGA_BLANK_N,
    output wire        VGA_SYNC_N
);
    // ---------------- reset synchronisers ----------------
    reg [1:0] rst50_s;
    always @(posedge CLOCK_50 or negedge KEY[0])
        if (!KEY[0]) rst50_s <= 2'b00;
        else         rst50_s <= {rst50_s[0], 1'b1};
    wire rst50_n = rst50_s[1];

    reg [1:0] rstp_s;
    always @(posedge CAM_PCLK or negedge KEY[0])
        if (!KEY[0]) rstp_s <= 2'b00;
        else         rstp_s <= {rstp_s[0], 1'b1};
    wire rstp_n = rstp_s[1];

    // ---------------- camera clock: 25 MHz ----------------
    reg xclk_r = 1'b0;
    always @(posedge CLOCK_50) xclk_r <= ~xclk_r;
    assign CAM_XCLK  = xclk_r;
    assign CAM_RESET = 1'b1;
    assign CAM_PWDN  = 1'b0;

    // ---------------- SCCB configuration ----------------
    wire cfg_done;
    ov7670_config u_cfg (
        .clk(CLOCK_50), .rst_n(rst50_n),
        .sioc(CAM_SIOC), .siod(CAM_SIOD), .done(cfg_done)
    );

    // ---------------- synchronisers: PCLK domain ----------------
    reg [8:0] p_s1, p_s2;
    always @(posedge CAM_PCLK) begin
        p_s1 <= {cfg_done, KEY[1], SW[7:0]};
        p_s2 <= p_s1;
    end
    wire p_gray   = p_s2[0];
    wire p_edge   = p_s2[1];
    wire p_freeze = p_s2[3];
    wire p_blur   = p_s2[4];
    wire p_blur5  = p_s2[5];
    wire y_phase  = p_s2[6];
    wire uv_swap  = p_s2[7];
    wire key1_n   = p_s2[8];
    reg  cfg_done_p1, cfg_done_p;
    always @(posedge CAM_PCLK) begin cfg_done_p1 <= cfg_done; cfg_done_p <= cfg_done_p1; end

    wire store_color = !p_edge && !p_gray;
    wire blur_on     = p_blur && !store_color;

    // ---------------- synchronisers: 50 MHz domain ----------------
    reg [12:0] v_s1, v_s2;
    always @(posedge CLOCK_50) begin
        v_s1 <= {SW[17:10], SW[4], SW[2:0]};
        v_s2 <= v_s1;
    end
    wire       mode_gray = v_s2[0];
    wire       mode_edge = v_s2[1];
    wire       mode_bin  = v_s2[2];
    wire       blur_disp = v_s2[3];
    wire [7:0] thresh    = v_s2[11:4];

    // ---------------- capture ----------------
    wire       pix_valid, frame_tick, frame_start;
    wire [7:0] pix_y, pix_u, pix_v;
    wire [9:0] pix_x, next_col;
    wire [8:0] pix_row;

    ov7670_capture u_cap (
        .pclk(CAM_PCLK), .rst_n(rstp_n),
        .vsync(CAM_VSYNC), .href(CAM_HREF), .d(CAM_D),
        .y_phase(y_phase), .uv_swap(uv_swap),
        .pix_valid(pix_valid), .pix_y(pix_y), .pix_u(pix_u), .pix_v(pix_v),
        .pix_x(pix_x), .pix_row(pix_row),
        .next_col(next_col), .frame_tick(frame_tick), .frame_start(frame_start)
    );

    // ---------------- Gaussian blur ----------------
    wire       g_valid;
    wire [9:0] g_x;
    wire [8:0] g_y;
    wire [7:0] g_data;

    gauss_blur u_blur (
        .clk(CAM_PCLK), .rst_n(rstp_n), .size5(p_blur5), .rd_col(next_col),
        .pix_valid(pix_valid), .pix_in(pix_y), .pix_x(pix_x), .pix_row(pix_row),
        .out_valid(g_valid), .out_x(g_x), .out_y(g_y), .out_data(g_data)
    );

    // ---------------- live / snapshot control ----------------
    wire capturing, snap_valid;
    snapshot_ctrl #(.SETTLE_FRAMES(SETTLE_FRAMES)) u_snap (
        .pclk(CAM_PCLK), .rst_n(rstp_n),
        .frame_start(frame_start), .cfg_done(cfg_done_p),
        .capture_req_n(key1_n), .live(!p_freeze),
        .fmt({store_color, blur_on, blur_on & p_blur5}),
        .capturing(capturing), .snap_valid(snap_valid)
    );

    // ---------------- frame-buffer writer ----------------
    wire        fb_we;
    wire [18:0] fb_waddr;
    wire [7:0]  fb_wdata;

    fb_writer u_wr (
        .clk(CAM_PCLK), .rst_n(rstp_n),
        .capturing(capturing), .store_color(store_color), .blur_on(blur_on),
        .pix_valid(pix_valid), .pix_y(pix_y), .pix_u(pix_u), .pix_v(pix_v),
        .pix_x(pix_x), .pix_row(pix_row),
        .g_valid(g_valid), .g_x(g_x), .g_y(g_y), .g_data(g_data),
        .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata)
    );

    // ---------------- frame buffer ----------------
    wire [18:0] fb_raddr;
    wire [7:0]  fb_rdata;

    frame_buffer u_fb (
        .wclk(CAM_PCLK), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .rclk(CLOCK_50), .raddr(fb_raddr), .rdata(fb_rdata)
    );

    // ---------------- display: colour / gray / Sobel + VGA ----------------
    vga_sobel u_vga (
        .clk(CLOCK_50), .rst_n(rst50_n),
        .mode_edge(mode_edge), .mode_gray(mode_gray), .mode_bin(mode_bin),
        .wide_border(blur_disp), .thresh(thresh),
        .fb_raddr(fb_raddr), .fb_rdata(fb_rdata),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B),
        .vga_hs(VGA_HS), .vga_vs(VGA_VS),
        .vga_blank_n(VGA_BLANK_N), .vga_sync_n(VGA_SYNC_N), .vga_clk(VGA_CLK)
    );

    // ---------------- status LEDs ----------------
    reg [23:0] pclk_div = 24'd0;
    always @(posedge CAM_PCLK) pclk_div <= pclk_div + 24'd1;

    assign LEDG = {5'd0, p_freeze, blur_on, snap_valid, cfg_done};
    assign LEDR = {15'd0, capturing, pclk_div[23], frame_tick};
endmodule
