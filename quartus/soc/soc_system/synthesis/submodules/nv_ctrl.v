`timescale 1ns/1ps
// nv_ctrl.v -- per-frame statistics reduction, closed-loop gain controller and tone-LUT generator (roadmap 4.2-4.6).
// Bit-exact to model/pipeline_int.py IntPipeline.update() (+ make_lut and the derived k_mot/thr of step()).
//
// Runs once per frame in the vertical blanking, started by `start` (the frame's statistics are final). Sequential,
// one operation per state; dividers are shared (seq_div). Order and formulas (all integer):
//   scan   : walk the 256 histogram bins, cumulative sum -> p1,p50,p95,p99 (first bin whose cdf >= ceil(N*pct/100));
//            every bin is cleared as it is read (single bank; the blanking is long enough, so no ping-pong needed);
//            4-bin group sums go to the telemetry histogram (th_*).
//   sigma  : s_frame = (noise_sum*C_SIG + 2^23) >> 24;  sigma = first ? s_frame : sigma + ((s_frame - sigma) >>> 2)
//   black  : b = min(p1, 16, (sigma + 128) >> 8)
//   loop   : mean_q4 = (out_sum*16 + N/2) / N;  e = log2(2048) - log2(mean_q4)  (Q12)
//            dlg = 0 if |e| < 295 else clip(e >>> 1, -2364, +1182);  cap = log2(255) - log2(max(p95 - b, 8))
//            lg  = clip(lg + dlg, 0, clip(cap, 0, 6<<12))
//   LUT    : g_q12 = exp2(lg); gl = (g_q12*1023 + 510)/1020; LUT[i] = GAMMA[clip(((i - 4b)*gl + 2048) >> 12, 0, 1023)]
//            (i - 4b <= 0 -> 0). passthru = 1 writes the identity table LUT[i] = i >> 2 instead.
//   couple : nq = max((sigma * max(LUT[4*p50+8] - LUT[4*p50-8], 1)) >> 2, 1)      output noise, Q8
//            a   = clip((147456*256 + n2/2) / n2, 32, 256), n2 = nq*nq            temporal blend floor, Q8
//            lam = clip((nq+24)/48 - 8, 0, 16);   sharp = nq >= 3072 ? 0 : clip(((3072-nq)*16 + 1536)/3072, 0, 16)
//            core = max((nq * isqrt((a<<16)/(512-a)) + 2048) >> 12, 16)
//   derive : sig_eff = max(sigma,128); k_mot = (2^26 + 9*sig_eff/2) / (9*sig_eff); thr = (sig_eff*20 + 256) >> 9
// Reset / soft_reset run the same flow from the initial state (lg = 2<<12, sigma = 3.0, b = 0, a = 64, lam = 8,
// sharp = 8, core = 16) up to LUT generation and derive, then `ready` goes high.
//
// Q formats: lg Q12 log2; sigma Q8; a Q8; lam, sharp Q4; core Q4 (saturated to 16 bit); mean_q4 Q4; k_mot Q16 multiplier.
module nv_ctrl #(
    parameter W     = 640,
    parameter H     = 480,
    parameter C_SIG = 2942       // round(2^24 * 256 * sqrt(pi/2) / (6*(W-2)*(H-2))), from scripts/export_vectors.py
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soft_reset,
    input  wire        start,
    input  wire [31:0] out_sum,
    input  wire [31:0] noise_sum,
    input  wire        passthru,
    // histogram RAM (read port owned while scanning; bins are cleared as they are read)
    output wire [7:0]  h_raddr,
    input  wire [18:0] h_rdata,
    output wire        h_clr_en,
    output wire [7:0]  h_clr_addr,
    // telemetry histogram (64 bins of 4 grey levels, count >> 4 saturated)
    output reg         th_we,
    output reg  [5:0]  th_addr,
    output reg  [15:0] th_data,
    // tone LUT shadow bank
    output reg         lut_we,
    output reg  [9:0]  lut_waddr,
    output reg  [7:0]  lut_wdata,
    output reg  [9:0]  lut_raddr,
    input  wire [7:0]  lut_rdata,
    // status
    output reg         busy,
    output reg         ready,
    output reg         done,
    // results (shadow parameter set, stable while !busy)
    output reg  [15:0] r_lg,
    output reg  [15:0] r_sigma,
    output reg  [4:0]  r_b,
    output reg  [8:0]  r_a,
    output reg  [4:0]  r_lam,
    output reg  [4:0]  r_sharp,
    output reg  [15:0] r_core,
    output reg  [15:0] r_kmot,
    output reg  [11:0] r_thr,
    output reg  [7:0]  r_p1,
    output reg  [7:0]  r_p50,
    output reg  [7:0]  r_p99,
    output reg  [31:0] r_mean_q4
);
    localparam NPIX = W * H;
    localparam [18:0] T1  = (NPIX * 1  + 99) / 100;
    localparam [18:0] T50 = (NPIX * 50 + 99) / 100;
    localparam [18:0] T95 = (NPIX * 95 + 99) / 100;
    localparam [18:0] T99 = (NPIX * 99 + 99) / 100;

    localparam signed [23:0] LOG2_2048 = 24'sd45056;      // log2_q12(2048) = 11 << 12
    localparam signed [23:0] LOG2_255  = 24'sd32745;      // log2_q12(255), checked against model/roms.py in the testbench
    localparam signed [23:0] DEADBAND  = 24'sd295;
    localparam signed [23:0] RL_UP     = 24'sd1182;
    localparam signed [23:0] RL_DN     = 24'sd2364;
    localparam signed [23:0] LG_MAX    = 24'sd24576;      // 6 << 12
    localparam [15:0] LG_INIT = 16'd8192;                 // 2 << 12
    localparam [19:0] SIGMA_INIT = 20'd768;
    localparam [31:0] SIGT2A = 32'd37748736;              // 147456 * 256

    // ---------------------------------------------------------------- states
    localparam [5:0]
        ST_IDLE = 0,  ST_INIT = 1,  ST_SC0 = 2,  ST_SCAN = 3,  ST_SIG1 = 4,  ST_SIG2 = 5,  ST_B = 6,
        ST_MEAN_D = 7, ST_MEAN_W = 8, ST_LOGM_A = 9, ST_LOGM_B = 10, ST_LOGM_C = 11, ST_DLG = 12,
        ST_CAP_A = 13, ST_CAP_B = 14, ST_CAP_C = 15, ST_LG = 16, ST_GL_A = 17, ST_GL_B = 18, ST_GL_W = 19,
        ST_LUT = 20, ST_SLP_A = 21, ST_SLP_B = 22, ST_SLP_C = 23, ST_SLP_D = 24, ST_SLP_E = 25, ST_NQ = 26,
        ST_N2 = 27, ST_A_D = 28, ST_A_W = 29, ST_LAM_D = 30, ST_LAM_W = 31, ST_SH_D = 32, ST_SH_W = 33,
        ST_RAT_D = 34, ST_RAT_W = 35, ST_SQRT = 36, ST_CORE = 37, ST_K_D = 38, ST_K_W = 39, ST_THR = 40, ST_DONE = 41;
    reg [5:0] st;

    reg        first_frame, init_flow;
    // working registers
    reg [18:0] lg;                      // Q12 log2 gain, 0..24576 (kept wide for the add)
    reg [19:0] sigma;                   // Q8
    reg [4:0]  b;
    reg [7:0]  p1, p50, p95, p99;
    reg [31:0] mean_q4;
    reg [18:0] cdf, grp;
    reg [8:0]  sc_i;
    reg        sc_v1;
    reg [7:0]  sc_a1;
    reg        f1, f50, f95, f99;
    reg [45:0] sig_prod;
    reg [31:0] lx;                      // log2 unit input
    reg signed [23:0] lm, lc;
    reg signed [23:0] dlg;
    reg [19:0] g_q12;
    reg [19:0] gl;
    reg [7:0]  l_hi;
    reg        lo_neg;
    reg [7:0]  diffv;
    reg [31:0] nq;
    reg [63:0] n2;
    reg [8:0]  a_r;
    reg [4:0]  lam_r, sharp_r;
    reg [15:0] core_r;
    reg [16:0] ratio;
    reg [8:0]  sq_s;
    reg [3:0]  sq_bit;
    reg [15:0] kmot_r;
    reg [11:0] thr_r;
    reg [19:0] sig_eff;

    // ---------------------------------------------------------------- shared units
    reg         div_start;
    reg  [63:0] div_num;
    reg  [47:0] div_den;
    wire        div_busy, div_done;
    wire [63:0] div_q;
    seq_div #(.NW(64), .DW(48)) u_div (.clk(clk), .rst_n(rst_n), .start(div_start), .num(div_num), .den(div_den),
                                       .busy(div_busy), .done(div_done), .q(div_q));

    // log2 unit: leading-one position + 8-bit mantissa ROM (matches roms.log2_q12)
    function [4:0] msb;
        input [31:0] x;
        integer k;
        begin
            msb = 5'd0;
            for (k = 0; k < 32; k = k + 1) if (x[k]) msb = k[4:0];
        end
    endfunction
    wire [4:0]  lx_ip   = msb(lx);
    wire [31:0] lx_sh   = (lx_ip < 8) ? (lx << (8 - lx_ip)) : (lx >> (lx_ip - 8));
    wire [7:0]  lx_mant = lx_sh[7:0];
    wire [12:0] log2_rd;
    rom_log2 u_log2 (.clk(clk), .addr(lx_mant), .data(log2_rd));

    wire [16:0] exp2_rd;
    rom_exp2 u_exp2 (.clk(clk), .addr(lg[11:4]), .data(exp2_rd));

    // ---------------------------------------------------------------- LUT generation pipeline
    reg         gen_active;
    reg         gen_start;          // one-clock request from the FSM; gen_active/gen_i have ONE driver (the pipeline block)
    reg [10:0]  gen_i;
    reg         gv0, gv1, gv2, gv3;
    reg [9:0]   gi0, gi1, gi2, gi3;
    reg signed [11:0] gd0;
    reg signed [32:0] gprod1;
    reg         gnp1;                    // d <= 0
    reg [9:0]   gidx2;
    wire [7:0]  gam_rd;
    rom_gamma u_gamma (.clk(clk), .addr(gidx2), .data(gam_rd));
    wire gen_busy = gen_start | gen_active | gv0 | gv1 | gv2 | gv3 | lut_we;
    wire signed [32:0] gp_rnd = (gprod1 + 33'sd2048) >>> 12;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_active <= 1'b0; gen_i <= 0; gv0 <= 1'b0; gv1 <= 1'b0; gv2 <= 1'b0; gv3 <= 1'b0;
            gi0 <= 0; gi1 <= 0; gi2 <= 0; gi3 <= 0; gd0 <= 0; gprod1 <= 0; gnp1 <= 1'b0; gidx2 <= 0;
            lut_we <= 1'b0; lut_waddr <= 0; lut_wdata <= 0;
        end else begin
            // stage 0: issue entry gen_i
            gv0 <= gen_active;
            gi0 <= gen_i[9:0];
            gd0 <= $signed({2'b00, gen_i[9:0]}) - $signed({5'b00000, b, 2'b00});
            if (gen_start) begin
                gen_active <= 1'b1;
                gen_i <= 0;
            end else if (gen_active) begin
                gen_i <= gen_i + 1'b1;
                if (gen_i == 11'd1023) gen_active <= 1'b0;
            end
            // stage 1: multiply
            gv1 <= gv0; gi1 <= gi0;
            gprod1 <= gd0 * $signed({1'b0, gl});
            gnp1 <= (gd0 <= 0);
            // stage 2: index
            gv2 <= gv1; gi2 <= gi1;
            gidx2 <= gnp1 ? 10'd0 : (gp_rnd > 33'sd1023) ? 10'd1023 : gp_rnd[9:0];
            // stage 3: ROM output valid
            gv3 <= gv2; gi3 <= gi2;
            // write
            lut_we    <= gv3;
            lut_waddr <= gi3;
            lut_wdata <= passthru ? gi3[9:2] : gam_rd;
        end
    end

    // ---------------------------------------------------------------- histogram scan helpers
    assign h_raddr    = sc_i[7:0];
    assign h_clr_en   = (st == ST_SCAN) && sc_v1;
    assign h_clr_addr = sc_a1;
    wire [18:0] cdf_n = cdf + h_rdata;
    wire [18:0] grp_n = (sc_a1[1:0] == 2'd0) ? h_rdata : (grp + h_rdata);

    // ---------------------------------------------------------------- misc comb
    wire signed [23:0] e_val  = LOG2_2048 - lm;
    wire signed [23:0] e_abs  = e_val[23] ? -e_val : e_val;
    wire signed [23:0] e_half = e_val >>> 1;
    wire signed [23:0] capv   = LOG2_255 - lc;
    wire signed [23:0] caphi  = (capv > LG_MAX) ? LG_MAX : capv;
    wire signed [23:0] hi_c   = (caphi < 0) ? 24'sd0 : caphi;
    wire signed [23:0] lg_t   = $signed({5'b00000, lg}) + dlg;
    wire [19:0] sigma_b = (sigma + 20'd128) >> 8;
    wire [7:0]  lo_v    = lo_neg ? 8'd0 : lut_rdata;
    wire [31:0] thr_full = (sig_eff * 20 + 256) >> 9;
    wire [31:0] nq_raw  = (sigma * diffv) >> 2;
    wire [31:0] nq_c    = (nq_raw == 0) ? 32'd1 : (nq_raw > 32'h00800000) ? 32'h00800000 : nq_raw;   // saturate: downstream outputs are already pinned there
    wire [47:0] core_full = (nq * sq_s + 2048) >> 12;
    wire [31:0] sf = (sig_prod + 46'd8388608) >> 24;
    wire signed [31:0] sig_iir = $signed({12'b0, sigma}) + ((($signed({1'b0, sf}) - $signed({12'b0, sigma}))) >>> 2);
    wire [63:0] sqt = ({55'd0, (sq_s | (9'd1 << sq_bit))}) * ({55'd0, (sq_s | (9'd1 << sq_bit))});

    // ---------------------------------------------------------------- main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_INIT; busy <= 1'b1; ready <= 1'b0; done <= 1'b0; div_start <= 1'b0; gen_start <= 1'b0; div_num <= 0; div_den <= 1;
            first_frame <= 1'b1; init_flow <= 1'b1;
            lg <= 0; sigma <= 0; b <= 0; p1 <= 0; p50 <= 0; p95 <= 0; p99 <= 0; mean_q4 <= 0; cdf <= 0; grp <= 0;
            sc_i <= 0; sc_v1 <= 1'b0; sc_a1 <= 0; f1 <= 0; f50 <= 0; f95 <= 0; f99 <= 0; sig_prod <= 0; lx <= 1;
            lm <= 0; lc <= 0; dlg <= 0; g_q12 <= 0; gl <= 0; l_hi <= 0; lo_neg <= 0; diffv <= 0; nq <= 1; n2 <= 1;
            a_r <= 64; lam_r <= 8; sharp_r <= 8; core_r <= 16; ratio <= 0; sq_s <= 0; sq_bit <= 0; kmot_r <= 0; thr_r <= 0;
            sig_eff <= 128; lut_raddr <= 0; th_we <= 1'b0; th_addr <= 0; th_data <= 0;
            r_lg <= 0; r_sigma <= 0; r_b <= 0; r_a <= 0; r_lam <= 0; r_sharp <= 0; r_core <= 0; r_kmot <= 0; r_thr <= 0;
            r_p1 <= 0; r_p50 <= 0; r_p99 <= 0; r_mean_q4 <= 0;
        end else begin
            div_start <= 1'b0;
            gen_start <= 1'b0;
            done      <= 1'b0;
            th_we     <= 1'b0;
            if (soft_reset) begin
                st <= ST_INIT; busy <= 1'b1; ready <= 1'b0;
            end else begin
                case (st)
                ST_IDLE: if (start) begin busy <= 1'b1; st <= ST_SC0; end
                ST_INIT: begin
                    lg <= {3'b000, LG_INIT}; sigma <= SIGMA_INIT; b <= 5'd0;
                    a_r <= 9'd64; lam_r <= 5'd8; sharp_r <= 5'd8; core_r <= 16'd16;
                    first_frame <= 1'b1; init_flow <= 1'b1; busy <= 1'b1; ready <= 1'b0;
                    st <= ST_GL_A;
                end
                // ---- statistics
                ST_SC0: begin
                    sc_i <= 0; sc_v1 <= 1'b0; cdf <= 0; grp <= 0; f1 <= 0; f50 <= 0; f95 <= 0; f99 <= 0;
                    p1 <= 0; p50 <= 0; p95 <= 0; p99 <= 0; st <= ST_SCAN;
                end
                ST_SCAN: begin
                    sc_v1 <= (sc_i < 9'd256);
                    sc_a1 <= sc_i[7:0];
                    if (sc_i < 9'd256) sc_i <= sc_i + 1'b1;
                    if (sc_v1) begin
                        cdf <= cdf_n;
                        grp <= grp_n;
                        if (!f1  && cdf_n >= T1)  begin p1  <= sc_a1; f1  <= 1'b1; end
                        if (!f50 && cdf_n >= T50) begin p50 <= sc_a1; f50 <= 1'b1; end
                        if (!f95 && cdf_n >= T95) begin p95 <= sc_a1; f95 <= 1'b1; end
                        if (!f99 && cdf_n >= T99) begin p99 <= sc_a1; f99 <= 1'b1; end
                        if (sc_a1[1:0] == 2'd3) begin
                            th_we <= 1'b1; th_addr <= sc_a1[7:2];
                            th_data <= {1'b0, grp_n[18:4]};          // 4 bins <= 307200 -> >>4 <= 19200: never saturates
                        end
                        if (sc_a1 == 8'd255) st <= ST_SIG1;
                    end
                end
                ST_SIG1: begin sig_prod <= noise_sum * C_SIG; st <= ST_SIG2; end
                ST_SIG2: begin
                    sigma <= first_frame ? sf[19:0] : (sig_iir[31] ? 20'd0 : sig_iir[19:0]);
                    st <= ST_B;
                end
                ST_B: begin
                    b <= (p1 < 8'd16 && p1 < sigma_b) ? p1[4:0] :
                         (sigma_b < 20'd16)           ? sigma_b[4:0] : 5'd16;
                    st <= ST_MEAN_D;
                end
                ST_MEAN_D: begin
                    div_num <= {28'd0, out_sum, 4'd0} + (NPIX >> 1);
                    div_den <= NPIX;
                    div_start <= 1'b1; st <= ST_MEAN_W;
                end
                ST_MEAN_W: if (div_done) begin mean_q4 <= div_q[31:0]; st <= ST_LOGM_A; end
                ST_LOGM_A: begin lx <= (mean_q4 == 0) ? 32'd1 : mean_q4; st <= ST_LOGM_B; end
                ST_LOGM_B: st <= ST_LOGM_C;
                ST_LOGM_C: begin lm <= $signed({6'd0, lx_ip, 12'd0}) + $signed({11'd0, log2_rd}); st <= ST_DLG; end
                ST_DLG: begin
                    if (e_abs < DEADBAND) dlg <= 24'sd0;
                    else dlg <= (e_half < -RL_DN) ? -RL_DN : (e_half > RL_UP) ? RL_UP : e_half;
                    st <= ST_CAP_A;
                end
                ST_CAP_A: begin
                    lx <= ({24'd0, p95} > {27'd0, b} + 32'd8) ? ({24'd0, p95} - {27'd0, b}) : 32'd8;
                    st <= ST_CAP_B;
                end
                ST_CAP_B: st <= ST_CAP_C;
                ST_CAP_C: begin lc <= $signed({6'd0, lx_ip, 12'd0}) + $signed({11'd0, log2_rd}); st <= ST_LG; end
                ST_LG: begin
                    lg <= (lg_t < 0) ? 19'd0 : (lg_t > hi_c) ? hi_c[18:0] : lg_t[18:0];
                    st <= ST_GL_A;
                end
                // ---- LUT
                ST_GL_A: st <= ST_GL_B;                         // exp2 ROM captures its address (lg is stable)
                ST_GL_B: begin
                    g_q12 <= ({15'd0, exp2_rd} << lg[14:12]) >> 4;      // 32-bit context: the shifted value needs 23 bits
                    st <= ST_GL_W;                              // (division started next state)
                end
                ST_GL_W: begin
                    if (!div_busy && !div_done) begin
                        div_num <= {44'd0, g_q12} * 1023 + 510;
                        div_den <= 1020;
                        div_start <= 1'b1;
                        st <= ST_LUT;
                    end
                end
                ST_LUT: begin
                    if (div_done) begin
                        gl <= div_q[19:0];
                        gen_start <= 1'b1;
                        st <= ST_SLP_A;                         // waits for gen_busy to clear there
                    end
                end
                // ---- slope at the median (reads the freshly written shadow bank)
                ST_SLP_A: if (!gen_busy && !gen_active) begin
                    if (init_flow) st <= ST_K_D;
                    else begin
                        lut_raddr <= (({1'b0, p50, 2'b00} + 11'd8) > 11'd1023) ? 10'd1023 : ({1'b0, p50, 2'b00} + 11'd8);
                        st <= ST_SLP_B;
                    end
                end
                ST_SLP_B: st <= ST_SLP_C;
                ST_SLP_C: begin
                    l_hi <= lut_rdata;
                    lo_neg <= ({p50, 2'b00} < 10'd8);
                    lut_raddr <= ({p50, 2'b00} < 10'd8) ? 10'd0 : ({p50, 2'b00} - 10'd8);
                    st <= ST_SLP_D;
                end
                ST_SLP_D: st <= ST_SLP_E;
                ST_SLP_E: begin
                    diffv <= (l_hi > lo_v) ? (l_hi - lo_v) : 8'd1;        // max(diff, 1); the LUT is monotone
                    st <= ST_NQ;
                end
                ST_NQ: begin
                    nq <= nq_c;
                    st <= ST_N2;
                end
                ST_N2: begin n2 <= nq * nq; st <= ST_A_D; end
                ST_A_D: begin
                    div_num <= {32'd0, SIGT2A} + (n2 >> 1);
                    div_den <= n2[47:0];
                    div_start <= 1'b1; st <= ST_A_W;
                end
                ST_A_W: if (div_done) begin
                    a_r <= (div_q < 64'd32) ? 9'd32 : (div_q > 64'd256) ? 9'd256 : div_q[8:0];
                    st <= ST_LAM_D;
                end
                ST_LAM_D: begin div_num <= nq + 24; div_den <= 48; div_start <= 1'b1; st <= ST_LAM_W; end
                ST_LAM_W: if (div_done) begin
                    lam_r <= (div_q < 64'd8) ? 5'd0 : (div_q > 64'd24) ? 5'd16 : (div_q[4:0] - 5'd8);
                    st <= ST_SH_D;
                end
                ST_SH_D: begin
                    if (nq >= 32'd3072) begin sharp_r <= 5'd0; st <= ST_RAT_D; end
                    else begin
                        div_num <= (32'd3072 - nq) * 16 + 1536; div_den <= 3072; div_start <= 1'b1; st <= ST_SH_W;
                    end
                end
                ST_SH_W: if (div_done) begin
                    sharp_r <= (div_q > 64'd16) ? 5'd16 : div_q[4:0];
                    st <= ST_RAT_D;
                end
                ST_RAT_D: begin div_num <= {39'd0, a_r, 16'd0}; div_den <= 10'd512 - a_r; div_start <= 1'b1; st <= ST_RAT_W; end
                ST_RAT_W: if (div_done) begin ratio <= div_q[16:0]; sq_s <= 0; sq_bit <= 4'd8; st <= ST_SQRT; end
                ST_SQRT: begin
                    if (sqt <= {47'd0, ratio}) sq_s <= sq_s | (9'd1 << sq_bit);
                    if (sq_bit == 0) st <= ST_CORE; else sq_bit <= sq_bit - 1'b1;
                end
                ST_CORE: begin
                    core_r <= (core_full < 48'd16) ? 16'd16 : (core_full > 48'd65535) ? 16'd65535 : core_full[15:0];
                    st <= ST_K_D;
                end
                // ---- derived frame constants
                ST_K_D: begin
                    sig_eff <= (sigma < 20'd128) ? 20'd128 : sigma;
                    st <= ST_K_W;
                end
                ST_K_W: begin
                    div_num <= (64'd1 << 26) + ((sig_eff * 9) >> 1);
                    div_den <= sig_eff * 9;
                    div_start <= 1'b1;
                    st <= ST_THR;
                end
                ST_THR: if (div_done) begin
                    kmot_r <= div_q[15:0];
                    thr_r  <= (thr_full > 32'd4095) ? 12'd4095 : thr_full[11:0];
                    st <= ST_DONE;
                end
                ST_DONE: begin
                    r_lg <= lg[15:0]; r_sigma <= (sigma > 20'd65535) ? 16'd65535 : sigma[15:0]; r_b <= b;
                    r_a <= a_r; r_lam <= lam_r; r_sharp <= sharp_r; r_core <= core_r; r_kmot <= kmot_r; r_thr <= thr_r;
                    r_p1 <= p1; r_p50 <= p50; r_p99 <= p99; r_mean_q4 <= mean_q4;
                    if (!init_flow) first_frame <= 1'b0;
                    init_flow <= 1'b0;
                    busy <= 1'b0; ready <= 1'b1; done <= 1'b1;
                    st <= ST_IDLE;
                end
                default: st <= ST_IDLE;
                endcase
            end
        end
    end
endmodule
