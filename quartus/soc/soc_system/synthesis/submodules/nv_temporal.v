`timescale 1ns/1ps
// nv_temporal.v -- motion-adaptive temporal denoiser with the in-place frame store (roadmap 5.3-5.5, Architecture decision 2).
//
// Per pixel (matches model/pipeline_int.py IntPipeline.step, "temporal" block):
//   C = raw << 2 (Q8.2)           P = stored previous value (Q8.2, 10 bit)
//   sad9 = sum over the 3x3 window of |C - P|
//   u    = min(63, (sad9 * k_mot) >> 16)            motion index
//   f    = MOTION_ROM[u]                            Q8, 0..256
//   alpha= a_q8 + (((256 - a_q8) * f + 128) >> 8)   Q8, a_q8..256
//   out  = P + ((alpha * (C - P) + 128) >>> 8)      (use_prev = 0: out = C, first frame after reset)
// The output stream is also written back to the frame store (in place). Reads run W+1 pixels AHEAD of the writes,
// so a pixel is always read before its slot is overwritten, and a read never touches the slot being written.
//
// Latency ledger (clocks from in_valid of pixel k, gap-free): see win3x3 (W+2) then PIPE = 8 stages -> tp_valid.
//   registered RAM read       +1   (in_valid_d / in_data_d)
//   win3x3 (cur and prev)     +W+1 ticks
//   s1 |diff|  s2a triple sums  s2b sad9  s3 multiply  s4 index+ROM  s5 alpha multiply  s6 alpha/diff  s7 blend multiply  s8 out
//   Each stage has at most one multiply / wide add (checklist 1.10).
//
// Parameters are frame constants (nv_core latches them at frame start). Q formats: a_q8 Q8 (32..256), k_mot Q16 (>>16).
module nv_temporal #(
    parameter W  = 640,
    parameter H  = 480,
    parameter CW = 10,
    parameter AW = 19            // frame store address bits: W*H <= 2**AW
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire [7:0]  in_data,
    input  wire        use_prev,     // 0 for the first frame after reset / FRAME_RESET
    input  wire [8:0]  a_q8,         // blend floor, Q8
    input  wire [15:0] k_mot,        // motion normalisation, multiplier for (sad9 * k_mot) >> 16
    // temporal output stream (Q8.2)
    output reg         tp_valid,
    output reg         tp_sof,
    output reg         tp_eof,
    output reg  [9:0]  tp_data,
    // raw 3x3 window of the input, for the noise estimator
    output wire        nz_valid,
    output wire        nz_sof, nz_eof,
    output wire        nz_fc, nz_lc, nz_fr, nz_lr,
    output wire [71:0] nz_taps,      // {t8,...,t0}, 8 bit each
    output wire        overrun
);
    localparam NPIX = W * H;

    // ------------------------------------------------------------- frame store read side (index runs with in_valid)
    reg [AW-1:0] rd_idx;
    reg [AW-1:0] wr_idx;
    wire [9:0]   prev_rd;
    wire         wr_en;
    wire [9:0]   wr_data;

    ram_sdp #(.DW(10), .AW(AW), .DEPTH(NPIX)) store (
        .clk(clk), .we(wr_en), .waddr(wr_idx), .wdata(wr_data), .raddr(rd_idx), .rdata(prev_rd));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_idx <= 0;
        else if (in_valid) rd_idx <= (rd_idx == NPIX - 1) ? {AW{1'b0}} : rd_idx + 1'b1;
    end

    // align the input with the RAM's registered read (1 clock)
    reg        v_d, sof_d;
    reg [7:0]  d_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v_d <= 1'b0; sof_d <= 1'b0; d_d <= 8'd0; end
        else begin v_d <= in_valid; sof_d <= in_sof; d_d <= in_data; end
    end

    // ------------------------------------------------------------- the two windows (identical control -> lockstep)
    wire        wc_valid, wc_sof, wc_eof, wc_fc, wc_lc, wc_fr, wc_lr, ovc;
    wire [7:0]  c0, c1, c2, c3, c4, c5, c6, c7, c8;
    wire        wp_valid, wp_sof, wp_eof, wp_fc, wp_lc, wp_fr, wp_lr, ovp;
    wire [9:0]  p0, p1, p2, p3, p4, p5, p6, p7, p8;

    win3x3 #(.DW(8),  .W(W), .H(H), .CW(CW)) win_cur  (.clk(clk), .rst_n(rst_n), .in_valid(v_d), .in_sof(sof_d), .in_data(d_d),
        .out_valid(wc_valid), .out_sof(wc_sof), .out_eof(wc_eof), .out_fc(wc_fc), .out_lc(wc_lc), .out_fr(wc_fr), .out_lr(wc_lr),
        .t0(c0), .t1(c1), .t2(c2), .t3(c3), .t4(c4), .t5(c5), .t6(c6), .t7(c7), .t8(c8), .overrun(ovc));
    win3x3 #(.DW(10), .W(W), .H(H), .CW(CW)) win_prev (.clk(clk), .rst_n(rst_n), .in_valid(v_d), .in_sof(sof_d), .in_data(prev_rd),
        .out_valid(wp_valid), .out_sof(wp_sof), .out_eof(wp_eof), .out_fc(wp_fc), .out_lc(wp_lc), .out_fr(wp_fr), .out_lr(wp_lr),
        .t0(p0), .t1(p1), .t2(p2), .t3(p3), .t4(p4), .t5(p5), .t6(p6), .t7(p7), .t8(p8), .overrun(ovp));

    assign nz_valid = wc_valid;
    assign nz_sof = wc_sof; assign nz_eof = wc_eof;
    assign nz_fc = wc_fc; assign nz_lc = wc_lc; assign nz_fr = wc_fr; assign nz_lr = wc_lr;
    assign nz_taps = {c8, c7, c6, c5, c4, c3, c2, c1, c0};
    assign overrun = ovc | ovp;

    // ------------------------------------------------------------- s1: absolute differences (10 bit each)
    function [9:0] absd;
        input [9:0] a, b;
        begin absd = (a >= b) ? (a - b) : (b - a); end
    endfunction

    reg        s1_v, s1_sof, s1_eof;
    reg [9:0]  s1_d0, s1_d1, s1_d2, s1_d3, s1_d4, s1_d5, s1_d6, s1_d7, s1_d8;
    reg [9:0]  s1_c, s1_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v <= 1'b0; s1_sof <= 1'b0; s1_eof <= 1'b0; s1_c <= 0; s1_p <= 0;
            {s1_d0, s1_d1, s1_d2, s1_d3, s1_d4, s1_d5, s1_d6, s1_d7, s1_d8} <= 90'd0;
        end else begin
            s1_v <= wc_valid; s1_sof <= wc_sof; s1_eof <= wc_eof;
            s1_d0 <= absd({c0, 2'b00}, p0); s1_d1 <= absd({c1, 2'b00}, p1); s1_d2 <= absd({c2, 2'b00}, p2);
            s1_d3 <= absd({c3, 2'b00}, p3); s1_d4 <= absd({c4, 2'b00}, p4); s1_d5 <= absd({c5, 2'b00}, p5);
            s1_d6 <= absd({c6, 2'b00}, p6); s1_d7 <= absd({c7, 2'b00}, p7); s1_d8 <= absd({c8, 2'b00}, p8);
            s1_c <= {c4, 2'b00}; s1_p <= p4;
        end
    end

    // ------------------------------------------------------------- s2a: triple sums, s2b: sad9
    reg        s2a_v, s2a_sof, s2a_eof;
    reg [11:0] s2a_a, s2a_b, s2a_c;
    reg [9:0]  s2a_cc, s2a_pp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2a_v <= 1'b0; s2a_sof <= 1'b0; s2a_eof <= 1'b0; s2a_a <= 0; s2a_b <= 0; s2a_c <= 0; s2a_cc <= 0; s2a_pp <= 0; end
        else begin
            s2a_v <= s1_v; s2a_sof <= s1_sof; s2a_eof <= s1_eof;
            s2a_a <= s1_d0 + s1_d1 + s1_d2; s2a_b <= s1_d3 + s1_d4 + s1_d5; s2a_c <= s1_d6 + s1_d7 + s1_d8;
            s2a_cc <= s1_c; s2a_pp <= s1_p;
        end
    end
    reg        s2b_v, s2b_sof, s2b_eof;
    reg [13:0] s2b_sad;
    reg [9:0]  s2b_c, s2b_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2b_v <= 1'b0; s2b_sof <= 1'b0; s2b_eof <= 1'b0; s2b_sad <= 0; s2b_c <= 0; s2b_p <= 0; end
        else begin
            s2b_v <= s2a_v; s2b_sof <= s2a_sof; s2b_eof <= s2a_eof;
            s2b_sad <= s2a_a + s2a_b + s2a_c; s2b_c <= s2a_cc; s2b_p <= s2a_pp;
        end
    end

    // ------------------------------------------------------------- s3: sad9 * k_mot
    reg        s3_v, s3_sof, s3_eof;
    reg [29:0] s3_prod;
    reg [9:0]  s3_c, s3_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s3_v <= 1'b0; s3_sof <= 1'b0; s3_eof <= 1'b0; s3_prod <= 0; s3_c <= 0; s3_p <= 0; end
        else begin
            s3_v <= s2b_v; s3_sof <= s2b_sof; s3_eof <= s2b_eof;
            s3_prod <= s2b_sad * k_mot; s3_c <= s2b_c; s3_p <= s2b_p;
        end
    end

    // ------------------------------------------------------------- s4: motion index and ROM (registered read)
    wire [13:0] s3_x = s3_prod[29:16];
    wire [5:0]  s3_u = (s3_x > 14'd63) ? 6'd63 : s3_x[5:0];
    wire [8:0]  s4_f;
    rom_motion u_motion (.clk(clk), .addr(s3_u), .data(s4_f));
    reg        s4_v, s4_sof, s4_eof;
    reg [9:0]  s4_c, s4_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s4_v <= 1'b0; s4_sof <= 1'b0; s4_eof <= 1'b0; s4_c <= 0; s4_p <= 0; end
        else begin s4_v <= s3_v; s4_sof <= s3_sof; s4_eof <= s3_eof; s4_c <= s3_c; s4_p <= s3_p; end
    end

    // ------------------------------------------------------------- s5: (256 - a) * f
    reg        s5_v, s5_sof, s5_eof;
    reg [17:0] s5_prod;
    reg [9:0]  s5_c, s5_p;
    wire [8:0] one_minus_a = 9'd256 - a_q8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s5_v <= 1'b0; s5_sof <= 1'b0; s5_eof <= 1'b0; s5_prod <= 0; s5_c <= 0; s5_p <= 0; end
        else begin
            s5_v <= s4_v; s5_sof <= s4_sof; s5_eof <= s4_eof;
            s5_prod <= one_minus_a * s4_f; s5_c <= s4_c; s5_p <= s4_p;
        end
    end

    // ------------------------------------------------------------- s6: alpha and difference
    reg        s6_v, s6_sof, s6_eof;
    reg [8:0]  s6_alpha;
    reg signed [10:0] s6_diff;
    reg [9:0]  s6_c, s6_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s6_v <= 1'b0; s6_sof <= 1'b0; s6_eof <= 1'b0; s6_alpha <= 0; s6_diff <= 0; s6_c <= 0; s6_p <= 0; end
        else begin
            s6_v <= s5_v; s6_sof <= s5_sof; s6_eof <= s5_eof;
            s6_alpha <= a_q8 + ((s5_prod + 18'd128) >> 8);
            s6_diff  <= $signed({1'b0, s5_c}) - $signed({1'b0, s5_p});
            s6_c <= s5_c; s6_p <= s5_p;
        end
    end

    // ------------------------------------------------------------- s7: alpha * diff
    reg        s7_v, s7_sof, s7_eof;
    reg signed [20:0] s7_prod;
    reg [9:0]  s7_c, s7_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s7_v <= 1'b0; s7_sof <= 1'b0; s7_eof <= 1'b0; s7_prod <= 0; s7_c <= 0; s7_p <= 0; end
        else begin
            s7_v <= s6_v; s7_sof <= s6_sof; s7_eof <= s6_eof;
            s7_prod <= $signed({1'b0, s6_alpha}) * s6_diff; s7_c <= s6_c; s7_p <= s6_p;
        end
    end

    // ------------------------------------------------------------- s8: output
    wire signed [20:0] s7_rnd = (s7_prod + 21'sd128) >>> 8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tp_valid <= 1'b0; tp_sof <= 1'b0; tp_eof <= 1'b0; tp_data <= 0; end
        else begin
            tp_valid <= s7_v; tp_sof <= s7_sof; tp_eof <= s7_eof;
            tp_data  <= use_prev ? (s7_p + s7_rnd[9:0]) : s7_c;
        end
    end

    // ------------------------------------------------------------- write back (in place)
    assign wr_en   = tp_valid;
    assign wr_data = tp_data;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wr_idx <= 0;
        else if (tp_valid) wr_idx <= (wr_idx == NPIX - 1) ? {AW{1'b0}} : wr_idx + 1'b1;
    end
endmodule
