`timescale 1ns/1ps
// nv_core.v -- the adaptive night-vision enhancement core (frame-driven, no dependence on VGA timing).
//
//   in stream --> nv_temporal --> nv_spatial --> nv_tone --> nv_sharpen --> out stream
//        |             \--> nv_noise                |
//        \--> nv_hist                               \--> out_sum
//                         nv_ctrl (blanking) <-- {hist, noise_sum, out_sum}, writes shadow LUT + shadow parameter set
//
// Input: in_valid/in_sof/in_data (raw 8-bit luma, raster order, W x H, arbitrary gaps inside a frame).
// Requirement between frames (roadmap Architecture decision 9): at least FRAME_GAP clocks without in_valid after the last
// pixel; the VGA timing gives 36,000, the minimum needed is about 4*(W+2) for the window flushes plus the controller run
// (~2,500 clocks for the LUT and divisions). A frame that starts too early sets err_overrun (sticky).
//
// Parameter timeline (matches model/pipeline_int.py): frame t is processed with the parameter set computed by nv_ctrl after
// frame t-1. The shadow set (r_*) and the shadow LUT bank are latched / swapped at the first pixel of frame t, when nothing
// of frame t-1 is still in flight, so every stage sees constants for the whole frame.
//
// Stage controls (applied at frame start): en_temporal = 0 forces alpha = 1 (output = input); en_spatial = 0 forces lam = 0;
// en_sharpen = 0 forces sharp = 0; passthru = 1 additionally makes the next generated LUT the identity (v = i >> 2), so with
// all of them the core is an exact pixel passthrough (one frame after the control change for the LUT).
module nv_core #(
    parameter W     = 640,
    parameter H     = 480,
    parameter CW    = 10,
    parameter AW    = 19,
    parameter C_SIG = 2942
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soft_reset,        // FRAME_RESET: forget the previous frame and re-initialise the controller
    input  wire        en_temporal,
    input  wire        en_spatial,
    input  wire        en_sharpen,
    input  wire        passthru,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire [7:0]  in_data,
    output wire        out_valid,
    output wire        out_sof,
    output wire        out_eof,
    output wire [7:0]  out_data,
    // status
    output wire        ready,             // controller initialised (first frame may start)
    output reg         err_overrun,       // sticky: frame started before the previous one finished, or window overrun
    output reg         err_notready,      // sticky: frame started before the controller was ready / still busy
    // telemetry of the frame being / last processed (live parameter set + measured statistics)
    output reg  [15:0] t_lg,
    output reg  [15:0] t_sigma,
    output reg  [4:0]  t_b,
    output reg  [8:0]  t_a,
    output reg  [4:0]  t_lam,
    output reg  [4:0]  t_sharp,
    output reg  [15:0] t_core,
    output reg  [15:0] t_kmot,
    output reg  [11:0] t_thr,
    output wire [7:0]  t_p1,
    output wire [7:0]  t_p50,
    output wire [7:0]  t_p99,
    output wire [31:0] t_mean_q4,
    output wire        th_we,
    output wire [5:0]  th_addr,
    output wire [15:0] th_data,
    output wire        ctrl_done,         // one-clock pulse: new shadow parameter set available
    // debug / verification taps (stage streams)
    output wire        dbg_tp_valid, dbg_tp_sof, dbg_tp_eof,
    output wire [9:0]  dbg_tp_data,
    output wire        dbg_sp_valid, dbg_sp_sof, dbg_sp_eof,
    output wire [9:0]  dbg_sp_data,
    output wire        dbg_v_valid, dbg_v_sof, dbg_v_eof,
    output wire [7:0]  dbg_v_data,
    output wire [31:0] dbg_noise_sum,
    output wire [31:0] dbg_out_sum,
    output wire        dbg_lut_sel
);
    wire frame_start = in_valid & in_sof;

    // ------------------------------------------------------------------ live (frame constant) parameters
    reg        lut_sel;
    reg        use_prev, have_prev;
    reg        pending;                  // a new parameter set + LUT bank is waiting for the next frame start
    reg [8:0]  l_a;
    reg [15:0] l_kmot;
    reg [11:0] l_thr;
    reg [4:0]  l_lam, l_sharp;
    reg [15:0] l_core;

    // controller results
    wire        c_busy, c_ready, c_done;
    wire [15:0] r_lg, r_sigma, r_core, r_kmot;
    wire [4:0]  r_b, r_lam, r_sharp;
    wire [8:0]  r_a;
    wire [11:0] r_thr;
    assign ready = c_ready;
    assign ctrl_done = c_done;

    // ------------------------------------------------------------------ stages
    wire        tp_valid, tp_sof, tp_eof;
    wire [9:0]  tp_data;
    wire        nz_valid, nz_sof, nz_eof, nz_fc, nz_lc, nz_fr, nz_lr;
    wire [71:0] nz_taps;
    wire        ov_t, ov_s, ov_h;
    nv_temporal #(.W(W), .H(H), .CW(CW), .AW(AW)) u_temporal (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_sof(in_sof), .in_data(in_data),
        .use_prev(use_prev), .a_q8(l_a), .k_mot(l_kmot),
        .tp_valid(tp_valid), .tp_sof(tp_sof), .tp_eof(tp_eof), .tp_data(tp_data),
        .nz_valid(nz_valid), .nz_sof(nz_sof), .nz_eof(nz_eof), .nz_fc(nz_fc), .nz_lc(nz_lc), .nz_fr(nz_fr), .nz_lr(nz_lr),
        .nz_taps(nz_taps), .overrun(ov_t));

    wire        sp_valid, sp_sof, sp_eof;
    wire [9:0]  sp_data;
    nv_spatial #(.W(W), .H(H), .CW(CW)) u_spatial (
        .clk(clk), .rst_n(rst_n), .in_valid(tp_valid), .in_sof(tp_sof), .in_data(tp_data), .thr(l_thr), .lam(l_lam),
        .sp_valid(sp_valid), .sp_sof(sp_sof), .sp_eof(sp_eof), .sp_data(sp_data), .overrun(ov_s));

    wire        v_valid, v_sof, v_eof;
    wire [7:0]  v_data;
    wire [31:0] out_sum;
    wire        out_sum_valid;
    wire        lut_we;
    wire [9:0]  lut_waddr, lut_raddr;
    wire [7:0]  lut_wdata, lut_rdata;
    nv_tone u_tone (
        .clk(clk), .rst_n(rst_n), .lut_sel(lut_sel), .in_valid(sp_valid), .in_sof(sp_sof), .in_eof(sp_eof), .in_data(sp_data),
        .lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata), .lut_raddr(lut_raddr), .lut_rdata(lut_rdata),
        .v_valid(v_valid), .v_sof(v_sof), .v_eof(v_eof), .v_data(v_data), .out_sum(out_sum), .out_sum_valid(out_sum_valid));

    nv_sharpen #(.W(W), .H(H), .CW(CW)) u_sharpen (
        .clk(clk), .rst_n(rst_n), .in_valid(v_valid), .in_sof(v_sof), .in_data(v_data), .sharp(l_sharp), .core(l_core),
        .out_valid(out_valid), .out_sof(out_sof), .out_eof(out_eof), .out_data(out_data), .overrun(ov_h));

    // ------------------------------------------------------------------ statistics
    wire [31:0] noise_sum;
    wire        noise_done;
    nv_noise u_noise (.clk(clk), .rst_n(rst_n), .in_valid(nz_valid), .in_sof(nz_sof), .in_eof(nz_eof),
        .fc(nz_fc), .lc(nz_lc), .fr(nz_fr), .lr(nz_lr), .taps(nz_taps), .noise_sum(noise_sum), .noise_done(noise_done));

    wire [7:0]  h_raddr, h_clr_addr;
    wire [18:0] h_rdata;
    wire        h_clr_en, hist_clearing;
    nv_hist u_hist (.clk(clk), .rst_n(rst_n), .clear_all(soft_reset), .in_valid(in_valid), .in_data(in_data), .scan(c_busy),
        .h_raddr(h_raddr), .h_rdata(h_rdata), .h_clr_en(h_clr_en), .h_clr_addr(h_clr_addr), .clearing(hist_clearing));

    // ------------------------------------------------------------------ controller trigger: noise sum AND output sum final
    reg got_noise, got_osum;
    wire ctrl_start = (got_noise | noise_done) & (got_osum | out_sum_valid) & ~c_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin got_noise <= 1'b0; got_osum <= 1'b0; end
        else if (soft_reset) begin got_noise <= 1'b0; got_osum <= 1'b0; end
        else if (ctrl_start) begin got_noise <= 1'b0; got_osum <= 1'b0; end
        else begin
            if (noise_done)    got_noise <= 1'b1;
            if (out_sum_valid) got_osum  <= 1'b1;
        end
    end

    nv_ctrl #(.W(W), .H(H), .C_SIG(C_SIG)) u_ctrl (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .start(ctrl_start), .out_sum(out_sum), .noise_sum(noise_sum),
        .passthru(passthru),
        .h_raddr(h_raddr), .h_rdata(h_rdata), .h_clr_en(h_clr_en), .h_clr_addr(h_clr_addr),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data),
        .lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata), .lut_raddr(lut_raddr), .lut_rdata(lut_rdata),
        .busy(c_busy), .ready(c_ready), .done(c_done),
        .r_lg(r_lg), .r_sigma(r_sigma), .r_b(r_b), .r_a(r_a), .r_lam(r_lam), .r_sharp(r_sharp), .r_core(r_core),
        .r_kmot(r_kmot), .r_thr(r_thr), .r_p1(t_p1), .r_p50(t_p50), .r_p99(t_p99), .r_mean_q4(t_mean_q4));

    // ------------------------------------------------------------------ frame-boundary latching
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lut_sel <= 1'b0; use_prev <= 1'b0; have_prev <= 1'b0; pending <= 1'b0;
            l_a <= 9'd256; l_kmot <= 16'd0; l_thr <= 12'd0; l_lam <= 5'd0; l_sharp <= 5'd0; l_core <= 16'd16;
            t_lg <= 0; t_sigma <= 0; t_b <= 0; t_a <= 0; t_lam <= 0; t_sharp <= 0; t_core <= 0; t_kmot <= 0; t_thr <= 0;
            err_overrun <= 1'b0; err_notready <= 1'b0;
        end else begin
            if (soft_reset) begin have_prev <= 1'b0; pending <= 1'b0; end
            if (c_done) pending <= 1'b1;
            if (tp_valid && tp_eof) have_prev <= 1'b1;
            if (frame_start) begin
                if (!c_ready || c_busy) err_notready <= 1'b1;
                if (ov_t | ov_s | ov_h)  err_overrun <= 1'b1;
                use_prev <= have_prev & en_temporal;
                if (pending) begin
                    lut_sel <= ~lut_sel;
                    pending <= 1'b0;
                    l_a     <= (en_temporal & ~passthru) ? r_a : 9'd256;
                    l_kmot  <= r_kmot;
                    l_thr   <= r_thr;
                    l_lam   <= (en_spatial & ~passthru) ? r_lam : 5'd0;
                    l_sharp <= (en_sharpen & ~passthru) ? r_sharp : 5'd0;
                    l_core  <= r_core;
                    t_lg <= r_lg; t_sigma <= r_sigma; t_b <= r_b; t_a <= r_a; t_lam <= r_lam; t_sharp <= r_sharp;
                    t_core <= r_core; t_kmot <= r_kmot; t_thr <= r_thr;
                end else begin
                    // no new parameter set (e.g. soft reset in between): keep, but still honour the stage controls
                    l_a     <= (en_temporal & ~passthru) ? t_a : 9'd256;
                    l_lam   <= (en_spatial & ~passthru) ? t_lam : 5'd0;
                    l_sharp <= (en_sharpen & ~passthru) ? t_sharp : 5'd0;
                end
            end
        end
    end

    assign dbg_tp_valid = tp_valid; assign dbg_tp_sof = tp_sof; assign dbg_tp_eof = tp_eof; assign dbg_tp_data = tp_data;
    assign dbg_sp_valid = sp_valid; assign dbg_sp_sof = sp_sof; assign dbg_sp_eof = sp_eof; assign dbg_sp_data = sp_data;
    assign dbg_v_valid  = v_valid;  assign dbg_v_sof  = v_sof;  assign dbg_v_eof  = v_eof;  assign dbg_v_data  = v_data;
    assign dbg_noise_sum = noise_sum;
    assign dbg_out_sum   = out_sum;
    assign dbg_lut_sel   = lut_sel;
endmodule
