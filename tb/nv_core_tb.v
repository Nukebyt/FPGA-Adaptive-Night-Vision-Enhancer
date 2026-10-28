`timescale 1ns/1ps
// nv_core_tb.v -- end-to-end bit-exact test of nv_core against model/pipeline_int.py vectors (roadmap 4.7, 5.10, 6.2 sim twin).
// Verdict line: "RESULT: PASS" / "RESULT: FAIL".
//
// Plusargs: +vec=<dir with the exported vectors>  +gap=<percent of idle clocks inside a frame>  +fgap=<idle clocks between frames>
//           +reset_at=<frame index before which FRAME_RESET is pulsed, -1 = never>   (see scripts/export_vectors.py for the files)
//
// Latency ledger (checklist 3.3). Nothing is compared by absolute latency; every stream is compared IN ORDER by index:
//   tp  : temporal stage output   (W*H per frame)    sp : spatial stage output   v : tone-mapped values   out : final output
//   Expected-value files are indexed by absolute stream position (frame*W*H + pixel), with sof/eof checked on the first/last.
//   Controller results and the shadow LUT are compared at every ctrl_done pulse k (k = 0 initial, k = f+1 after frame f).
// Stimulus drives with non-blocking assignments (checklist 3.6) and random gaps (checklist 1.7).
module nv_core_tb;
    parameter W = 32, H = 24, T = 8, C_SIG = 1359329, NS = 15;
    localparam NPIX = W * H;

    reg clk = 1'b0, rst_n = 1'b0;
    always #20 clk = ~clk;

    reg        soft_reset = 1'b0;
    reg        in_valid = 1'b0, in_sof = 1'b0;
    reg [7:0]  in_data = 8'd0;
    wire       out_valid, out_sof, out_eof;
    wire [7:0] out_data;
    wire       ready, err_overrun, err_notready, ctrl_done;
    wire [15:0] t_lg, t_sigma, t_core, t_kmot;
    wire [4:0]  t_b, t_lam, t_sharp;
    wire [8:0]  t_a;
    wire [11:0] t_thr;
    wire [7:0]  t_p1, t_p50, t_p99;
    wire [31:0] t_mean_q4;
    wire        th_we;
    wire [5:0]  th_addr;
    wire [15:0] th_data;
    wire        tp_v, tp_s, tp_e, sp_v, sp_s, sp_e, v_v, v_s, v_e, lut_sel;
    wire [9:0]  tp_d, sp_d;
    wire [7:0]  v_d;
    wire [31:0] noise_sum, out_sum;

    nv_core #(.W(W), .H(H), .C_SIG(C_SIG)) dut (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .en_temporal(1'b1), .en_spatial(1'b1), .en_sharpen(1'b1), .passthru(1'b0),
        .in_valid(in_valid), .in_sof(in_sof), .in_data(in_data),
        .out_valid(out_valid), .out_sof(out_sof), .out_eof(out_eof), .out_data(out_data),
        .ready(ready), .err_overrun(err_overrun), .err_notready(err_notready),
        .t_lg(t_lg), .t_sigma(t_sigma), .t_b(t_b), .t_a(t_a), .t_lam(t_lam), .t_sharp(t_sharp), .t_core(t_core), .t_kmot(t_kmot),
        .t_thr(t_thr), .t_p1(t_p1), .t_p50(t_p50), .t_p99(t_p99), .t_mean_q4(t_mean_q4),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data), .ctrl_done(ctrl_done),
        .dbg_tp_valid(tp_v), .dbg_tp_sof(tp_s), .dbg_tp_eof(tp_e), .dbg_tp_data(tp_d),
        .dbg_sp_valid(sp_v), .dbg_sp_sof(sp_s), .dbg_sp_eof(sp_e), .dbg_sp_data(sp_d),
        .dbg_v_valid(v_v), .dbg_v_sof(v_s), .dbg_v_eof(v_e), .dbg_v_data(v_d),
        .dbg_noise_sum(noise_sum), .dbg_out_sum(out_sum), .dbg_lut_sel(lut_sel));

    reg [7:0]  in_mem   [0:T*NPIX-1];
    reg [9:0]  exp_tp   [0:T*NPIX-1];
    reg [9:0]  exp_sp   [0:T*NPIX-1];
    reg [7:0]  exp_v    [0:T*NPIX-1];
    reg [7:0]  exp_out  [0:T*NPIX-1];
    reg [31:0] exp_state[0:(T+1)*NS-1];
    reg [7:0]  exp_lut  [0:(T+1)*1024-1];

    reg [8*200:1] vecdir;
    reg [8*240:1] fname;
    integer gap_pct, fgap, reset_at;
    integer errors = 0;
    integer n_tp = 0, n_sp = 0, n_v = 0, n_out = 0, n_done = 0;
    integer seed = 20261026;
    integer i, f, k;

    task bad;
        input [8*24:1] what;
        begin
            errors = errors + 1;
        end
    endtask

    // ------------------------------------------------------------------ stimulus
    initial begin
        if (!$value$plusargs("vec=%s", vecdir)) begin $display("RESULT: FAIL (no +vec)"); $finish; end
        if (!$value$plusargs("gap=%d", gap_pct)) gap_pct = 0;
        if (!$value$plusargs("fgap=%d", fgap)) fgap = 8192;
        if (!$value$plusargs("reset_at=%d", reset_at)) reset_at = -1;
        $sformat(fname, "%0s/in.hex", vecdir);        $readmemh(fname, in_mem);
        $sformat(fname, "%0s/exp_tp.hex", vecdir);    $readmemh(fname, exp_tp);
        $sformat(fname, "%0s/exp_sp.hex", vecdir);    $readmemh(fname, exp_sp);
        $sformat(fname, "%0s/exp_v.hex", vecdir);     $readmemh(fname, exp_v);
        $sformat(fname, "%0s/exp_out.hex", vecdir);   $readmemh(fname, exp_out);
        $sformat(fname, "%0s/exp_state.hex", vecdir); $readmemh(fname, exp_state);
        $sformat(fname, "%0s/exp_lut.hex", vecdir);   $readmemh(fname, exp_lut);
        #100 rst_n = 1'b1;
        wait (ready);
        repeat (50) @(posedge clk);
        for (f = 0; f < T; f = f + 1) begin
            k = 0;
            while (k < NPIX) begin
                @(posedge clk);
                if (($random(seed) & 32'h7fffffff) % 100 < gap_pct) begin
                    in_valid <= 1'b0; in_sof <= 1'b0;
                end else begin
                    in_valid <= 1'b1;
                    in_sof   <= (k == 0);
                    in_data  <= in_mem[f * NPIX + k];
                    k = k + 1;
                end
            end
            @(posedge clk);
            in_valid <= 1'b0; in_sof <= 1'b0;
            repeat (fgap) @(posedge clk);
        end
        repeat (200) @(posedge clk);
        finish_check;
    end

    task finish_check;
        begin
            if (n_tp != T * NPIX)  begin errors = errors + 1; $display("FAIL: tp stream %0d of %0d", n_tp, T * NPIX); end
            if (n_sp != T * NPIX)  begin errors = errors + 1; $display("FAIL: sp stream %0d of %0d", n_sp, T * NPIX); end
            if (n_v  != T * NPIX)  begin errors = errors + 1; $display("FAIL: v stream %0d of %0d", n_v, T * NPIX); end
            if (n_out != T * NPIX) begin errors = errors + 1; $display("FAIL: out stream %0d of %0d", n_out, T * NPIX); end
            if (n_done != T + 1)   begin errors = errors + 1; $display("FAIL: %0d ctrl_done pulses, expected %0d", n_done, T + 1); end
            if (err_overrun)       begin errors = errors + 1; $display("FAIL: err_overrun set"); end
            if (err_notready)      begin errors = errors + 1; $display("FAIL: err_notready set"); end
            if (errors == 0) $display("RESULT: PASS (gap=%0d%%, %0dx%0d x %0d frames)", gap_pct, W, H, T);
            else             $display("RESULT: FAIL (errors=%0d)", errors);
            $finish;
        end
    endtask

    // ------------------------------------------------------------------ stage stream checkers (in order)
    always @(posedge clk) if (rst_n) begin
        if (tp_v) begin
            if (tp_d !== exp_tp[n_tp]) begin errors = errors + 1; if (errors < 12) $display("TP MISMATCH f%0d x%0d y%0d: got %0d want %0d", n_tp / NPIX, (n_tp % NPIX) % W, (n_tp % NPIX) / W, tp_d, exp_tp[n_tp]); end
            if (tp_s !== ((n_tp % NPIX) == 0) || tp_e !== ((n_tp % NPIX) == NPIX - 1)) begin errors = errors + 1; if (errors < 12) $display("TP sof/eof wrong at %0d", n_tp); end
            n_tp = n_tp + 1;
        end
        if (sp_v) begin
            if (sp_d !== exp_sp[n_sp]) begin errors = errors + 1; if (errors < 12) $display("SP MISMATCH f%0d x%0d y%0d: got %0d want %0d", n_sp / NPIX, (n_sp % NPIX) % W, (n_sp % NPIX) / W, sp_d, exp_sp[n_sp]); end
            if (sp_s !== ((n_sp % NPIX) == 0) || sp_e !== ((n_sp % NPIX) == NPIX - 1)) begin errors = errors + 1; if (errors < 12) $display("SP sof/eof wrong at %0d", n_sp); end
            n_sp = n_sp + 1;
        end
        if (v_v) begin
            if (v_d !== exp_v[n_v]) begin errors = errors + 1; if (errors < 12) $display("V MISMATCH f%0d x%0d y%0d: got %0d want %0d", n_v / NPIX, (n_v % NPIX) % W, (n_v % NPIX) / W, v_d, exp_v[n_v]); end
            if (v_s !== ((n_v % NPIX) == 0) || v_e !== ((n_v % NPIX) == NPIX - 1)) begin errors = errors + 1; if (errors < 12) $display("V sof/eof wrong at %0d", n_v); end
            n_v = n_v + 1;
        end
        if (out_valid) begin
            if (out_data !== exp_out[n_out]) begin errors = errors + 1; if (errors < 12) $display("OUT MISMATCH f%0d x%0d y%0d: got %0d want %0d", n_out / NPIX, (n_out % NPIX) % W, (n_out % NPIX) / W, out_data, exp_out[n_out]); end
            if (out_sof !== ((n_out % NPIX) == 0) || out_eof !== ((n_out % NPIX) == NPIX - 1)) begin errors = errors + 1; if (errors < 12) $display("OUT sof/eof wrong at %0d", n_out); end
            n_out = n_out + 1;
        end
    end

    // ------------------------------------------------------------------ controller result + shadow LUT at every ctrl_done
    reg [31:0] e [0:NS-1];
    integer q, base;
    reg [7:0] lutv;
    task cmp;
        input integer idx;
        input [31:0] got;
        input [8*10:1] nm;
        begin
            if (got !== e[idx]) begin errors = errors + 1; if (errors < 12) $display("CTRL k=%0d %0s: got %0d want %0d", n_done, nm, got, e[idx]); end
        end
    endtask
    always @(posedge clk) if (rst_n && ctrl_done) begin
        base = n_done * NS;
        for (q = 0; q < NS; q = q + 1) e[q] = exp_state[base + q];
        cmp(0, dut.r_lg, "lg");     cmp(1, dut.r_sigma, "sigma"); cmp(2, dut.r_b, "b");       cmp(3, dut.r_a, "a");
        cmp(4, dut.r_lam, "lam");   cmp(5, dut.r_sharp, "sharp"); cmp(6, dut.r_core, "core"); cmp(7, dut.r_kmot, "kmot");
        cmp(8, dut.r_thr, "thr");
        if (n_done > 0) begin
            cmp(9, t_p1, "p1");  cmp(10, t_p50, "p50"); cmp(11, t_p99, "p99"); cmp(12, t_mean_q4, "mean_q4");
            cmp(13, out_sum, "out_sum"); cmp(14, noise_sum, "noise_sum");
        end
        for (q = 0; q < 1024; q = q + 1) begin
            lutv = lut_sel ? dut.u_tone.bank0.mem[q] : dut.u_tone.bank1.mem[q];     // shadow bank = the one NOT active
            if (lutv !== exp_lut[n_done * 1024 + q]) begin
                errors = errors + 1;
                if (errors < 12) $display("LUT k=%0d [%0d]: got %0d want %0d", n_done, q, lutv, exp_lut[n_done * 1024 + q]);
            end
        end
        n_done = n_done + 1;
    end

    initial begin #(40 * 3000000 * 4); $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
