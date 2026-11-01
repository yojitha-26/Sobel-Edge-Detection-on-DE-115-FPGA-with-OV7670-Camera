// ============================================================================
// gauss_blur.v   (camera PCLK domain)
// Streaming Gaussian blur on the luma pixels, 3x3 or 5x5, selected at run time.
//
//                 | 1 2 1 |                    | 1  4  6  4 1 |
//   3x3 = 1/16 *  | 2 4 2 |      5x5 = 1/256 * | 4 16 24 16 4 |
//                 | 1 2 1 |                    | 6 24 36 24 6 |
//                                              | 4 16 24 16 4 |
//                                              | 1  4  6  4 1 |
//
// Both kernels are separable, so each new column is first summed vertically
// (rows y-4..y from four line buffers + the incoming pixel) and the column
// sums are then combined horizontally.  Both outputs are centred on
// (x-2, y-2), so switching size does not move the image.  Results are rounded.
//
// out_valid / out_x / out_y / out_data are valid one PCLK after the input
// pixel, only where the full 5x5 neighbourhood exists (centre 2..W-3, 2..H-3).
// ============================================================================
module gauss_blur (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        size5,       // 0 = 3x3, 1 = 5x5
    input  wire [9:0]  rd_col,      // next column (line-buffer prefetch address)
    input  wire        pix_valid,
    input  wire [7:0]  pix_in,
    input  wire [9:0]  pix_x,
    input  wire [8:0]  pix_row,

    output wire        out_valid,
    output wire [9:0]  out_x,
    output wire [8:0]  out_y,
    output wire [7:0]  out_data
);
    // ---------------- line buffers: rows y-1 .. y-4 ----------------
    (* ramstyle = "M9K" *) reg [7:0] lb1 [0:1023];
    (* ramstyle = "M9K" *) reg [7:0] lb2 [0:1023];
    (* ramstyle = "M9K" *) reg [7:0] lb3 [0:1023];
    (* ramstyle = "M9K" *) reg [7:0] lb4 [0:1023];
    reg [7:0] q1, q2, q3, q4;

    // read for column c is issued one PCLK before pixel c arrives (chroma slot)
    always @(posedge clk) begin
        q1 <= lb1[rd_col];
        q2 <= lb2[rd_col];
        q3 <= lb3[rd_col];
        q4 <= lb4[rd_col];
        if (pix_valid) begin
            lb1[pix_x] <= pix_in;
            lb2[pix_x] <= q1;
            lb3[pix_x] <= q2;
            lb4[pix_x] <= q3;
        end
    end

    // ---------------- vertical (column) sums for the new column ----------------
    // r0 = row y-4 (top) ... r4 = row y (incoming)
    wire [7:0] r0 = q4, r1 = q3, r2 = q2, r3 = q1, r4 = pix_in;
    wire [11:0] col5 = {4'd0,r0} + {2'd0,r1,2'd0} + ({3'd0,r2,1'b0} + {2'd0,r2,2'd0})
                     + {2'd0,r3,2'd0} + {4'd0,r4};                       // 1 4 6 4 1
    wire [9:0]  col3 = {2'd0,r1} + {1'd0,r2,1'b0} + {2'd0,r3};          // 1 2 1

    // column sum of the PREVIOUS column (x-1): keep one extra register
    reg [9:0] col3_d;
    always @(posedge clk) begin
        if (!rst_n)         col3_d <= 10'd0;
        else if (pix_valid) col3_d <= col3;
    end

    // ---------------- column-sum shift registers (index 4 = newest) ----------------
    reg [11:0] c5_0, c5_1, c5_2, c5_3, c5_4;
    reg [9:0]  c3_1, c3_2, c3_3;
    reg        s_valid;
    reg [9:0]  s_x;
    reg [8:0]  s_y;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_valid <= 1'b0; s_x <= 10'd0; s_y <= 9'd0;
            {c5_0, c5_1, c5_2, c5_3, c5_4} <= 60'd0;
            {c3_1, c3_2, c3_3} <= 30'd0;
        end else begin
            s_valid <= pix_valid;
            if (pix_valid) begin
                c5_0 <= c5_1; c5_1 <= c5_2; c5_2 <= c5_3; c5_3 <= c5_4; c5_4 <= col5;
                // 3x3 uses columns x-3, x-2, x-1 -> the column sum is delayed one slot
                c3_1 <= c3_2; c3_2 <= c3_3; c3_3 <= col3_d;
                s_x <= pix_x;
                s_y <= pix_row;
            end
        end
    end
    // After the update for pixel x:  c3_3 = col x-1, c3_2 = col x-2, c3_1 = col x-3
    //                                c5_4 = col x,   c5_2 = col x-2, c5_0 = col x-4
    // c3 uses rows y-3..y-1 (r1..r3), centred on row y-2 like the 5x5.

    // ---------------- horizontal sums, rounding ----------------
    wire [15:0] h5 = {4'd0,c5_0} + {2'd0,c5_1,2'd0} + ({3'd0,c5_2,1'b0} + {2'd0,c5_2,2'd0})
                   + {2'd0,c5_3,2'd0} + {4'd0,c5_4} + 16'd128;            // /256
    wire [11:0] h3 = {2'd0,c3_1} + {1'd0,c3_2,1'b0} + {2'd0,c3_3} + 12'd8; // /16

    assign out_data  = size5 ? h5[15:8] : h3[11:4];
    assign out_valid = s_valid && (s_x >= 10'd4) && (s_y >= 9'd4);
    assign out_x     = s_x - 10'd2;
    assign out_y     = s_y - 9'd2;
endmodule
