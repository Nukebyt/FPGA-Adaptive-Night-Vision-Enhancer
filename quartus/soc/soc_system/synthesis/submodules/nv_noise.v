`timescale 1ns/1ps
// nv_noise.v -- noise-level statistic: sum of |3x3 Laplacian-of-Laplacian| over the INTERIOR pixels (roadmap 4.4).
//   r = (t0 + t2 + t6 + t8) - 2*(t1 + t3 + t5 + t7) + 4*t4 ;  noise_sum = sum over interior centres of |r|
// Bit-exact to model/stats.noise_sum (Immerkaer). Interior = not first/last row/column of the centre (border taps are
// replicated by win3x3 and must not be counted). Fed by the raw window already built inside nv_temporal.
// Pipeline: s1 grouped sums, s2 combine, s3 absolute value + accumulate. noise_done is a one-clock pulse after the last
// pixel; noise_sum then holds the frame total until the next frame's first pixel.
module nv_noise (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire        in_eof,
    input  wire        fc, lc, fr, lr,
    input  wire [71:0] taps,          // {t8,...,t0}
    output reg  [31:0] noise_sum,
    output reg         noise_done
);
    wire [7:0] t0 = taps[7:0],   t1 = taps[15:8],  t2 = taps[23:16];
    wire [7:0] t3 = taps[31:24], t4 = taps[39:32], t5 = taps[47:40];
    wire [7:0] t6 = taps[55:48], t7 = taps[63:56], t8 = taps[71:64];

    reg        s1_v, s1_sof, s1_eof, s1_int;
    reg [9:0]  s1_corner;
    reg [9:0]  s1_edge;
    reg [7:0]  s1_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_v <= 1'b0; s1_sof <= 1'b0; s1_eof <= 1'b0; s1_int <= 1'b0; s1_corner <= 0; s1_edge <= 0; s1_c <= 0; end
        else begin
            s1_v <= in_valid; s1_sof <= in_sof; s1_eof <= in_eof;
            s1_int <= in_valid & ~fc & ~lc & ~fr & ~lr;
            s1_corner <= t0 + t2 + t6 + t8;
            s1_edge   <= t1 + t3 + t5 + t7;
            s1_c      <= t4;
        end
    end
    reg        s2_v, s2_sof, s2_eof, s2_int;
    reg signed [13:0] s2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_v <= 1'b0; s2_sof <= 1'b0; s2_eof <= 1'b0; s2_int <= 1'b0; s2_r <= 0; end
        else begin
            s2_v <= s1_v; s2_sof <= s1_sof; s2_eof <= s1_eof; s2_int <= s1_int;
            s2_r <= $signed({4'b0000, s1_corner}) + $signed({4'b0000, s1_c, 2'b00}) - $signed({3'b000, s1_edge, 1'b0});
        end
    end
    reg [31:0] acc;
    wire [13:0] mag = s2_r[13] ? (~s2_r + 14'd1) : s2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin acc <= 32'd0; noise_sum <= 32'd0; noise_done <= 1'b0; end
        else begin
            noise_done <= 1'b0;
            if (s2_v && s2_sof) acc <= 32'd0;                       // first centre of a frame is a corner: never interior
            else if (s2_int)    acc <= acc + {18'd0, mag};
            if (s2_v && s2_eof) begin noise_sum <= acc; noise_done <= 1'b1; end   // last centre is a corner too
        end
    end
endmodule
