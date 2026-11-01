// ============================================================================
// frame_buffer.v
// 640 x 480 x 8-bit simple dual-port, dual-clock RAM (on-chip M9K).
//   Write port : camera PCLK domain   (Sobel output)
//   Read  port : 50 MHz VGA domain
// 307,200 bytes = 2.46 Mbit  (~300 of the 432 M9K blocks in the EP4CE115)
// The two clock domains only share this RAM, so no other CDC logic is needed.
// ============================================================================
module frame_buffer (
    input  wire        wclk,
    input  wire        we,
    input  wire [18:0] waddr,
    input  wire [7:0]  wdata,

    input  wire        rclk,
    input  wire [18:0] raddr,
    output reg  [7:0]  rdata
);
    localparam DEPTH = 640 * 480;
    (* ramstyle = "M9K" *) reg [7:0] mem [0:DEPTH-1];

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always @(posedge rclk)
        rdata <= mem[raddr];
endmodule
