`timescale 1ns/1ps
// nv_spatial.v -- 3x3 sigma filter on the temporal output (roadmap 5.7), bit-exact to pipeline_int.py "spatial" block.
//   sel_i = |t_i - t4| <= thr (centre always selected);  n = count;  s = sum of selected
//   mean  = (s * RECIP[n] + 32768) >> 16;   out = t4 + ((lam * (mean - t4) + 8) >>> 4)
// lam = 0 is an exact bypass (out = t4). thr and lam are frame constants.
//
// Latency: win3x3 (W+1 ticks) then 7 pipeline stages: s1 compare, s2a triple sums, s2b total, s3 reciprocal ROM,
// s4 multiply, s5 mean/difference, s6 mix multiply, s7 add  (one multiply or wide add per stage, checklist 1.10).
// Q formats: input/output Q8.2 (10 bit), thr Q8.2 (12 bit), lam Q4 (0..16), RECIP Q16.
module nv_spatial #(
    parameter W  = 640,
    parameter H  = 480,
    parameter CW = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire [9:0]  in_data,
    input  wire [11:0] thr,
    input  wire [4:0]  lam,
    output reg         sp_valid,
    output reg         sp_sof,
    output reg         sp_eof,
    output reg  [9:0]  sp_data,
    output wire        overrun
);
    wire        w_valid, w_sof, w_eof, w_fc, w_lc, w_fr, w_lr;
    wire [9:0]  t0, t1, t2, t3, t4, t5, t6, t7, t8;
    win3x3 #(.DW(10), .W(W), .H(H), .CW(CW)) win (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_sof(in_sof), .in_data(in_data),
        .out_valid(w_valid), .out_sof(w_sof), .out_eof(w_eof), .out_fc(w_fc), .out_lc(w_lc), .out_fr(w_fr), .out_lr(w_lr),
        .t0(t0), .t1(t1), .t2(t2), .t3(t3), .t4(t4), .t5(t5), .t6(t6), .t7(t7), .t8(t8), .overrun(overrun));

    function sel_f;
        input [9:0] a, c;
        input [11:0] th;
        reg [9:0] d;
        begin
            d = (a >= c) ? (a - c) : (c - a);
            sel_f = ({2'b00, d} <= th);
        end
    endfunction

    // ---- s1: compare, keep the taps
    reg        s1_v, s1_sof, s1_eof;
    reg [8:0]  s1_sel;
    reg [9:0]  s1_t0, s1_t1, s1_t2, s1_t3, s1_t4, s1_t5, s1_t6, s1_t7, s1_t8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v <= 1'b0; s1_sof <= 1'b0; s1_eof <= 1'b0; s1_sel <= 9'd0;
            {s1_t0, s1_t1, s1_t2, s1_t3, s1_t4, s1_t5, s1_t6, s1_t7, s1_t8} <= 90'd0;
        end else begin
            s1_v <= w_valid; s1_sof <= w_sof; s1_eof <= w_eof;
            s1_sel <= {sel_f(t8, t4, thr), sel_f(t7, t4, thr), sel_f(t6, t4, thr), sel_f(t5, t4, thr), 1'b1,
                       sel_f(t3, t4, thr), sel_f(t2, t4, thr), sel_f(t1, t4, thr), sel_f(t0, t4, thr)};
            s1_t0 <= t0; s1_t1 <= t1; s1_t2 <= t2; s1_t3 <= t3; s1_t4 <= t4; s1_t5 <= t5; s1_t6 <= t6; s1_t7 <= t7; s1_t8 <= t8;
        end
    end

    // ---- s2a: partial sums and counts of three taps each
    reg        s2a_v, s2a_sof, s2a_eof;
    reg [11:0] s2a_sa, s2a_sb, s2a_sc;
    reg [1:0]  s2a_na, s2a_nb, s2a_nc;
    reg [9:0]  s2a_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2a_v <= 1'b0; s2a_sof <= 1'b0; s2a_eof <= 1'b0; s2a_sa <= 0; s2a_sb <= 0; s2a_sc <= 0;
            s2a_na <= 0; s2a_nb <= 0; s2a_nc <= 0; s2a_c <= 0;
        end else begin
            s2a_v <= s1_v; s2a_sof <= s1_sof; s2a_eof <= s1_eof;
            s2a_sa <= (s1_sel[0] ? s1_t0 : 10'd0) + (s1_sel[1] ? s1_t1 : 10'd0) + (s1_sel[2] ? s1_t2 : 10'd0);
            s2a_sb <= (s1_sel[3] ? s1_t3 : 10'd0) + (s1_sel[4] ? s1_t4 : 10'd0) + (s1_sel[5] ? s1_t5 : 10'd0);
            s2a_sc <= (s1_sel[6] ? s1_t6 : 10'd0) + (s1_sel[7] ? s1_t7 : 10'd0) + (s1_sel[8] ? s1_t8 : 10'd0);
            s2a_na <= s1_sel[0] + s1_sel[1] + s1_sel[2];
            s2a_nb <= s1_sel[3] + s1_sel[4] + s1_sel[5];
            s2a_nc <= s1_sel[6] + s1_sel[7] + s1_sel[8];
            s2a_c  <= s1_t4;
        end
    end

    // ---- s2b: totals
    reg        s2b_v, s2b_sof, s2b_eof;
    reg [13:0] s2b_s;
    reg [3:0]  s2b_n;
    reg [9:0]  s2b_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2b_v <= 1'b0; s2b_sof <= 1'b0; s2b_eof <= 1'b0; s2b_s <= 0; s2b_n <= 0; s2b_c <= 0; end
        else begin
            s2b_v <= s2a_v; s2b_sof <= s2a_sof; s2b_eof <= s2a_eof;
            s2b_s <= s2a_sa + s2a_sb + s2a_sc;
            s2b_n <= s2a_na + s2a_nb + s2a_nc;
            s2b_c <= s2a_c;
        end
    end

    // ---- s3: reciprocal ROM (registered read, 1 clock) -> data lines up with the s3 registers
    wire [16:0] s3_rec;
    rom_recip u_recip (.clk(clk), .addr(s2b_n), .data(s3_rec));
    reg        s3_v, s3_sof, s3_eof;
    reg [13:0] s3_s;
    reg [9:0]  s3_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s3_v <= 1'b0; s3_sof <= 1'b0; s3_eof <= 1'b0; s3_s <= 0; s3_c <= 0; end
        else begin s3_v <= s2b_v; s3_sof <= s2b_sof; s3_eof <= s2b_eof; s3_s <= s2b_s; s3_c <= s2b_c; end
    end

    // ---- s4: s * recip
    reg        s4_v, s4_sof, s4_eof;
    reg [30:0] s4_prod;
    reg [9:0]  s4_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s4_v <= 1'b0; s4_sof <= 1'b0; s4_eof <= 1'b0; s4_prod <= 0; s4_c <= 0; end
        else begin s4_v <= s3_v; s4_sof <= s3_sof; s4_eof <= s3_eof; s4_prod <= s3_s * s3_rec; s4_c <= s3_c; end
    end

    // ---- s5: mean and (mean - centre)
    reg        s5_v, s5_sof, s5_eof;
    reg signed [10:0] s5_d;
    reg [9:0]  s5_c;
    wire [30:0] s4_rnd = s4_prod + 31'd32768;
    wire [9:0]  s4_mean = s4_rnd[25:16];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s5_v <= 1'b0; s5_sof <= 1'b0; s5_eof <= 1'b0; s5_d <= 0; s5_c <= 0; end
        else begin
            s5_v <= s4_v; s5_sof <= s4_sof; s5_eof <= s4_eof;
            s5_d <= $signed({1'b0, s4_mean}) - $signed({1'b0, s4_c});
            s5_c <= s4_c;
        end
    end

    // ---- s6: lam * d
    reg        s6_v, s6_sof, s6_eof;
    reg signed [16:0] s6_m;
    reg [9:0]  s6_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s6_v <= 1'b0; s6_sof <= 1'b0; s6_eof <= 1'b0; s6_m <= 0; s6_c <= 0; end
        else begin
            s6_v <= s5_v; s6_sof <= s5_sof; s6_eof <= s5_eof;
            s6_m <= $signed({1'b0, lam}) * s5_d; s6_c <= s5_c;
        end
    end

    // ---- s7: output
    wire signed [16:0] s6_rnd = (s6_m + 17'sd8) >>> 4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sp_valid <= 1'b0; sp_sof <= 1'b0; sp_eof <= 1'b0; sp_data <= 0; end
        else begin
            sp_valid <= s6_v; sp_sof <= s6_sof; sp_eof <= s6_eof;
            sp_data  <= s6_c + s6_rnd[9:0];
        end
    end
endmodule
