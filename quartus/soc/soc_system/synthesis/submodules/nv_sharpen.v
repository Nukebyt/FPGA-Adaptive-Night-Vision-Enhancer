`timescale 1ns/1ps
// nv_sharpen.v -- gain-aware unsharp mask with coring (roadmap 5.8), bit-exact to pipeline_int.py "unsharp" block.
//   s9 = sum of the 3x3 window;  blur_q4 = (s9*1820 + 512) >> 10;  d = 16*v - blur_q4
//   dc = sign(d) * max(|d| - core, 0);   out = clip(v + ((sharp * dc + 128) >>> 8), 0, 255)
// sharp = 0 is an exact bypass (out = v). sharp (Q4, 0..16) and core (Q4 grey levels) are frame constants.
// Latency: win3x3 (W+1 ticks) + 7 stages: s1 sums, s2 total, s3 blur, s4 d, s5 coring, s6 multiply, s7 clip.
module nv_sharpen #(
    parameter W  = 640,
    parameter H  = 480,
    parameter CW = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire [7:0]  in_data,
    input  wire [4:0]  sharp,
    input  wire [15:0] core,
    output reg         out_valid,
    output reg         out_sof,
    output reg         out_eof,
    output reg  [7:0]  out_data,
    output wire        overrun
);
    wire        w_valid, w_sof, w_eof, w_fc, w_lc, w_fr, w_lr;
    wire [7:0]  t0, t1, t2, t3, t4, t5, t6, t7, t8;
    win3x3 #(.DW(8), .W(W), .H(H), .CW(CW)) win (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_sof(in_sof), .in_data(in_data),
        .out_valid(w_valid), .out_sof(w_sof), .out_eof(w_eof), .out_fc(w_fc), .out_lc(w_lc), .out_fr(w_fr), .out_lr(w_lr),
        .t0(t0), .t1(t1), .t2(t2), .t3(t3), .t4(t4), .t5(t5), .t6(t6), .t7(t7), .t8(t8), .overrun(overrun));

    // s1: row sums
    reg        s1_v, s1_sof, s1_eof;
    reg [9:0]  s1_a, s1_b, s1_c;
    reg [7:0]  s1_v8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_v <= 1'b0; s1_sof <= 1'b0; s1_eof <= 1'b0; s1_a <= 0; s1_b <= 0; s1_c <= 0; s1_v8 <= 0; end
        else begin
            s1_v <= w_valid; s1_sof <= w_sof; s1_eof <= w_eof;
            s1_a <= t0 + t1 + t2; s1_b <= t3 + t4 + t5; s1_c <= t6 + t7 + t8; s1_v8 <= t4;
        end
    end
    // s2: total
    reg        s2_v, s2_sof, s2_eof;
    reg [11:0] s2_s9;
    reg [7:0]  s2_v8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_v <= 1'b0; s2_sof <= 1'b0; s2_eof <= 1'b0; s2_s9 <= 0; s2_v8 <= 0; end
        else begin s2_v <= s1_v; s2_sof <= s1_sof; s2_eof <= s1_eof; s2_s9 <= s1_a + s1_b + s1_c; s2_v8 <= s1_v8; end
    end
    // s3: blur in Q4 (constant multiply)
    reg        s3_v, s3_sof, s3_eof;
    reg [12:0] s3_blur;
    reg [7:0]  s3_v8;
    wire [23:0] blur_full = s2_s9 * 12'd1820 + 24'd512;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s3_v <= 1'b0; s3_sof <= 1'b0; s3_eof <= 1'b0; s3_blur <= 0; s3_v8 <= 0; end
        else begin s3_v <= s2_v; s3_sof <= s2_sof; s3_eof <= s2_eof; s3_blur <= blur_full[22:10]; s3_v8 <= s2_v8; end
    end
    // s4: d = 16 v - blur
    reg        s4_v, s4_sof, s4_eof;
    reg signed [13:0] s4_d;
    reg [7:0]  s4_v8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s4_v <= 1'b0; s4_sof <= 1'b0; s4_eof <= 1'b0; s4_d <= 0; s4_v8 <= 0; end
        else begin
            s4_v <= s3_v; s4_sof <= s3_sof; s4_eof <= s3_eof;
            s4_d <= $signed({1'b0, s3_v8, 4'b0000}) - $signed({1'b0, s3_blur});
            s4_v8 <= s3_v8;
        end
    end
    // s5: coring
    reg        s5_v, s5_sof, s5_eof;
    reg signed [13:0] s5_dc;
    reg [7:0]  s5_v8;
    wire [13:0] mag    = s4_d[13] ? (~s4_d + 14'd1) : s4_d;
    wire [15:0] mag16  = {2'b00, mag};
    wire [13:0] mag_c  = (mag16 > core) ? (mag16 - core) : 14'd0;    // |d| < 4096, so the result fits 14 bits
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s5_v <= 1'b0; s5_sof <= 1'b0; s5_eof <= 1'b0; s5_dc <= 0; s5_v8 <= 0; end
        else begin
            s5_v <= s4_v; s5_sof <= s4_sof; s5_eof <= s4_eof;
            s5_dc <= s4_d[13] ? -$signed({1'b0, mag_c}) : $signed({1'b0, mag_c});
            s5_v8 <= s4_v8;
        end
    end
    // s6: sharp * dc
    reg        s6_v, s6_sof, s6_eof;
    reg signed [19:0] s6_p;
    reg [7:0]  s6_v8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s6_v <= 1'b0; s6_sof <= 1'b0; s6_eof <= 1'b0; s6_p <= 0; s6_v8 <= 0; end
        else begin
            s6_v <= s5_v; s6_sof <= s5_sof; s6_eof <= s5_eof;
            s6_p <= $signed({1'b0, sharp}) * s5_dc; s6_v8 <= s5_v8;
        end
    end
    // s7: add and clip
    wire signed [19:0] s6_rnd = (s6_p + 20'sd128) >>> 8;
    wire signed [20:0] s6_sum = $signed({1'b0, s6_v8}) + s6_rnd;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_valid <= 1'b0; out_sof <= 1'b0; out_eof <= 1'b0; out_data <= 0; end
        else begin
            out_valid <= s6_v; out_sof <= s6_sof; out_eof <= s6_eof;
            out_data <= (s6_sum < 0) ? 8'd0 : (s6_sum > 255) ? 8'd255 : s6_sum[7:0];
        end
    end
endmodule
