// ============================================================================
// ov7670_config.v
// Configures the OV7670 over SCCB (I2C-like, write-only) after reset.
//   * SCL ~100 kHz from a 50 MHz clock
//   * Register table: YUV422 output, VGA 640x480, full-range 00-FF
//   * Waits ~10 ms after power-up and after the soft reset (COM7 = 0x80)
//   * SIOD is driven push-pull (high AND low) except during the 9th
//     "don't-care/ACK" bit of each byte, where it is released, and is held
//     high while idle.  This makes external pull-up resistors unnecessary.
//     SIOC is always push-pull.
// ============================================================================
module ov7670_config (
    input  wire clk,          // 50 MHz
    input  wire rst_n,        // synchronous, active low
    output reg  sioc,         // SCCB clock (push-pull)
    inout  wire siod,         // SCCB data  (push-pull, released on ACK bits)
    output reg  done          // high once every register has been written
);

    // ---------------- register table: {reg_addr, value} ----------------
    // 16'hFFFF terminates the list.
    reg  [4:0]  idx;
    reg  [15:0] rom;
    always @(*) begin
        case (idx)
            5'd0 : rom = 16'h12_80; // COM7  : soft reset (followed by a delay)
            5'd1 : rom = 16'h12_00; // COM7  : YUV output, VGA
            5'd2 : rom = 16'h11_00; // CLKRC : internal clock = XCLK (PCLK ~25 MHz)
            5'd3 : rom = 16'h0C_00; // COM3  : no scaling / DCW
            5'd4 : rom = 16'h3E_00; // COM14 : normal PCLK, no scaling
            5'd5 : rom = 16'h04_00; // COM1  : no CCIR656
            5'd6 : rom = 16'h40_C0; // COM15 : full output range 00..FF
            5'd7 : rom = 16'h3A_04; // TSLB  : byte order Y U Y V (with COM13[0]=0)
            5'd8 : rom = 16'h3D_C0; // COM13 : gamma on, UV auto adjust, no UV swap
            5'd9 : rom = 16'h15_00; // COM10 : VSYNC active high, PCLK free running
            5'd10: rom = 16'h14_18; // COM9  : AGC ceiling 4x (less noise -> fewer false edges)
            5'd11: rom = 16'h17_11; // HSTART  \
            5'd12: rom = 16'h18_61; // HSTOP    | exact 640-pixel line
            5'd13: rom = 16'h32_A4; // HREF    /
            5'd14: rom = 16'h19_03; // VSTART  \
            5'd15: rom = 16'h1A_7B; // VSTOP    | exact 480-line frame
            5'd16: rom = 16'h03_0A; // VREF    /
            default: rom = 16'hFFFF;
        endcase
    end

    // ---------------- SCCB bit engine ----------------
    // One "step" = quarter of an SCL period = 125 clocks @ 50 MHz (2.5 us)
    localparam QDIV = 7'd124;
    reg  [6:0]  qcnt;
    wire        tick = (qcnt == QDIV);
    always @(posedge clk) begin
        if (!rst_n || tick) qcnt <= 7'd0;
        else                qcnt <= qcnt + 7'd1;
    end

    reg         busy;
    reg  [6:0]  step;           // 0..115
    reg  [26:0] sh;             // {0x42,X, addr,X, data,X}  (X = 1 -> released)
    reg         start_req;
    reg         xfer_done;

    // decode SCL / SDA level for the current step
    reg scl_n, sda_n;
    wire [6:0] bstep = step - 7'd4;
    wire [4:0] bit_i = bstep[6:2];
    wire [1:0] q     = bstep[1:0];
    always @(*) begin
        scl_n = 1'b1; sda_n = 1'b1;
        if (busy) begin
            if (step == 7'd0)        begin scl_n = 1'b1; sda_n = 1'b1; end
            else if (step == 7'd1)   begin scl_n = 1'b1; sda_n = 1'b0; end  // START
            else if (step <= 7'd3)   begin scl_n = 1'b0; sda_n = 1'b0; end
            else if (step <= 7'd111) begin
                sda_n = sh[5'd26 - bit_i];
                scl_n = (q == 2'd1) || (q == 2'd2);
            end
            else if (step == 7'd112) begin scl_n = 1'b0; sda_n = 1'b0; end
            else if (step == 7'd113) begin scl_n = 1'b1; sda_n = 1'b0; end
            else                     begin scl_n = 1'b1; sda_n = 1'b1; end  // STOP
        end
    end

    // Release SIOD for the 9th (ACK) bit of each byte (bits 8, 17, 26).
    // The camera starts driving ACK right after SCL falls at the end of the
    // 8th bit, so release from that falling edge (q = 3 of bits 7, 16, 25).
    wire in_bits  = busy && (step >= 7'd4) && (step <= 7'd111);
    wire ack_bit  = in_bits && ((bit_i == 5'd8)  || (bit_i == 5'd17) || (bit_i == 5'd26) ||
                                (q == 2'd3 && ((bit_i == 5'd7) || (bit_i == 5'd16) || (bit_i == 5'd25))));
    reg sda_oe, sda_val;
    assign siod = sda_oe ? sda_val : 1'bz;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; step <= 7'd0; xfer_done <= 1'b0;
            sioc <= 1'b1; sda_oe <= 1'b1; sda_val <= 1'b1; sh <= 27'h7FF_FFFF;  // idle: drive SIOD high
        end else begin
            xfer_done <= 1'b0;
            if (start_req && !busy) begin
                busy <= 1'b1;
                step <= 7'd0;
                sh   <= {8'h42, 1'b1, rom[15:8], 1'b1, rom[7:0], 1'b1};
            end else if (busy && tick) begin
                sioc    <= scl_n;
                sda_val <= sda_n;
                sda_oe  <= ~ack_bit;                       // stays driven high when idle
                if (step == 7'd115) begin
                    busy <= 1'b0; xfer_done <= 1'b1;
                end
                step <= step + 7'd1;
            end
        end
    end

    // ---------------- sequencer ----------------
    localparam S_PWRUP = 3'd0, S_SEND = 3'd1, S_WAIT = 3'd2,
               S_GAP   = 3'd3, S_DONE = 3'd4;
    reg [2:0]  st;
    reg [19:0] dly;     // 2^19 * 20 ns ~ 10.5 ms

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_PWRUP; idx <= 5'd0; dly <= 20'd0;
            start_req <= 1'b0; done <= 1'b0;
        end else begin
            start_req <= 1'b0;
            case (st)
                S_PWRUP: begin
                    dly <= dly + 20'd1;
                    if (dly[19]) begin dly <= 20'd0; st <= S_SEND; end
                end
                S_SEND: begin
                    if (rom == 16'hFFFF) st <= S_DONE;
                    else begin start_req <= 1'b1; st <= S_WAIT; end
                end
                S_WAIT: if (xfer_done) begin dly <= 20'd0; st <= S_GAP; end
                S_GAP: begin
                    // long delay after the soft reset, short gap otherwise
                    dly <= dly + 20'd1;
                    if ((idx == 5'd0) ? dly[19] : dly[10]) begin
                        idx <= idx + 5'd1; st <= S_SEND;
                    end
                end
                S_DONE: done <= 1'b1;
                default: st <= S_PWRUP;
            endcase
        end
    end
endmodule
