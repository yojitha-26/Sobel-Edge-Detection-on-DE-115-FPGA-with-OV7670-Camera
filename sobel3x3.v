// ============================================================================
// sobel3x3.v  -  purely combinational Sobel operator on a 3x3 window
//
//          | -1  0 +1 |          | -1 -2 -1 |
//     Gx = | -2  0 +2 |     Gy = |  0  0  0 |     |G| ~ |Gx| + |Gy|  (sat. 255)
//          | -1  0 +1 |          | +1 +2 +1 |
//
//   p<row><col> : row 0 = top, col 0 = left
// ============================================================================
module sobel3x3 (
    input  wire [7:0] p00, p01, p02,
    input  wire [7:0] p10, p11, p12,
    input  wire [7:0] p20, p21, p22,
    output wire [7:0] mag
);
    wire [9:0] gx_p = {2'b0,p02} + {1'b0,p12,1'b0} + {2'b0,p22};
    wire [9:0] gx_n = {2'b0,p00} + {1'b0,p10,1'b0} + {2'b0,p20};
    wire [9:0] gy_p = {2'b0,p20} + {1'b0,p21,1'b0} + {2'b0,p22};
    wire [9:0] gy_n = {2'b0,p00} + {1'b0,p01,1'b0} + {2'b0,p02};

    wire [9:0]  ax  = (gx_p >= gx_n) ? (gx_p - gx_n) : (gx_n - gx_p);   // |Gx| <= 1020
    wire [9:0]  ay  = (gy_p >= gy_n) ? (gy_p - gy_n) : (gy_n - gy_p);   // |Gy| <= 1020
    wire [10:0] sum = {1'b0,ax} + {1'b0,ay};

    assign mag = (sum > 11'd255) ? 8'd255 : sum[7:0];
endmodule
