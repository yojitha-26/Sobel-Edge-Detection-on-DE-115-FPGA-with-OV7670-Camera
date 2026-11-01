// ============================================================================
// snapshot_ctrl.v   (camera PCLK domain)
// Decides WHEN camera frames are written into the frame buffer.
//
//   live = 1   : every frame is written  -> real-time video (default)
//   live = 0   : frozen - the stored frame stays on screen
//
//   While frozen, ONE new complete frame (VSYNC -> VSYNC) is captured when
//     * the camera has just been configured (after SETTLE_FRAMES frames)
//     * KEY1 is pressed
//     * the stored format changes (colour <-> gray, blur on/off/size),
//       because the frame buffer can hold only one format at a time
// ============================================================================
module snapshot_ctrl #(
    parameter SETTLE_FRAMES = 15        // ~0.5 s at 30 fps before the first auto-capture
)(
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        frame_start,     // pulse at VSYNC rising edge
    input  wire        cfg_done,        // already synchronised to pclk
    input  wire        capture_req_n,   // KEY[1], synchronised, active low
    input  wire        live,
    input  wire [2:0]  fmt,             // stored-format bits (synchronised)

    output wire        capturing,       // write enable for the frame buffer
    output reg         snap_valid       // at least one complete frame stored
);
    localparam S_IDLE = 2'd0, S_ARMED = 2'd1, S_CAP = 2'd2;
    reg [1:0] st;
    reg [4:0] skip;
    reg       cfg_d, key_d;
    reg [2:0] fmt_d;

    assign capturing = (st == S_CAP);

    wire cfg_rise   = cfg_done && !cfg_d;
    wire key_press  = !capture_req_n && key_d;      // falling edge of KEY[1]
    wire fmt_change = (fmt != fmt_d);

    always @(posedge pclk) begin
        if (!rst_n) begin
            st <= S_IDLE; skip <= 5'd0; cfg_d <= 1'b0; key_d <= 1'b1;
            fmt_d <= 3'd0; snap_valid <= 1'b0;
        end else begin
            cfg_d <= cfg_done;
            key_d <= capture_req_n;
            fmt_d <= fmt;
            case (st)
                S_IDLE: begin
                    if (key_press || live || fmt_change)
                        begin st <= S_ARMED; skip <= 5'd0; end
                end
                S_ARMED: begin
                    if (frame_start) begin
                        if (skip == 5'd0) st   <= S_CAP;
                        else              skip <= skip - 5'd1;
                    end
                end
                S_CAP: begin
                    if (frame_start) begin           // a complete frame has been written
                        snap_valid <= 1'b1;
                        if (!live) st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
            // a format change during a frozen capture restarts it cleanly
            if (st == S_CAP && !live && fmt_change) begin st <= S_ARMED; skip <= 5'd0; end
            // camera (re)configured: always wait for exposure to settle, then capture
            if (cfg_rise) begin st <= S_ARMED; skip <= SETTLE_FRAMES; end
        end
    end
endmodule
