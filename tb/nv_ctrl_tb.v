`timescale 1ns/1ps
// nv_ctrl_tb.v -- nv_ctrl against random and directed statistics (scripts/export_ctrl_vectors.py). "RESULT: PASS/FAIL".
// Behavioural histogram RAM (registered read, clear-on-read port) and shadow-LUT RAM (registered read) stand in for the real
// ones. Every case checks: the 15 result fields, all 1024 LUT entries, the 64 telemetry histogram bins, and that every
// histogram bin was cleared. Latency ledger: none needed (the test waits for `done` after each `start`).
module nv_ctrl_tb;
    parameter W = 24, H = 16, N = 400, C_SIG = 1000, NS = 15;
    localparam NPIX = W * H;

    reg clk = 1'b0, rst_n = 1'b0;
    always #20 clk = ~clk;

    reg        soft_reset = 1'b0, start = 1'b0, passthru = 1'b0;
    reg [31:0] out_sum = 0, noise_sum = 0;
    wire [7:0] h_raddr, h_clr_addr;
    reg  [18:0] h_rdata;
    wire       h_clr_en, th_we, lut_we, busy, ready, done;
    wire [5:0] th_addr;
    wire [15:0] th_data;
    wire [9:0] lut_waddr, lut_raddr;
    wire [7:0] lut_wdata;
    reg  [7:0] lut_rdata;
    wire [15:0] r_lg, r_sigma, r_core, r_kmot;
    wire [4:0] r_b, r_lam, r_sharp;
    wire [8:0] r_a;
    wire [11:0] r_thr;
    wire [7:0] r_p1, r_p50, r_p99;
    wire [31:0] r_mean_q4;

    nv_ctrl #(.W(W), .H(H), .C_SIG(C_SIG)) dut (.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .start(start),
        .out_sum(out_sum), .noise_sum(noise_sum), .passthru(passthru),
        .h_raddr(h_raddr), .h_rdata(h_rdata), .h_clr_en(h_clr_en), .h_clr_addr(h_clr_addr),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data),
        .lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata), .lut_raddr(lut_raddr), .lut_rdata(lut_rdata),
        .busy(busy), .ready(ready), .done(done),
        .r_lg(r_lg), .r_sigma(r_sigma), .r_b(r_b), .r_a(r_a), .r_lam(r_lam), .r_sharp(r_sharp), .r_core(r_core),
        .r_kmot(r_kmot), .r_thr(r_thr), .r_p1(r_p1), .r_p50(r_p50), .r_p99(r_p99), .r_mean_q4(r_mean_q4));

    // behavioural RAMs
    reg [18:0] hram [0:255];
    reg [7:0]  lram [0:1023];
    reg [15:0] th_cap [0:63];
    always @(posedge clk) begin
        if (h_clr_en) hram[h_clr_addr] <= 19'd0;
        h_rdata <= hram[h_raddr];
        if (lut_we) lram[lut_waddr] <= lut_wdata;
        lut_rdata <= lram[lut_raddr];
        if (th_we) th_cap[th_addr] <= th_data;
    end

    reg [18:0] hist_mem [0:N*256-1];
    reg [31:0] in_mem   [0:N*3-1];
    reg [31:0] exp_state[0:(N+1)*NS-1];
    reg [7:0]  exp_lut  [0:(N+1)*1024-1];
    reg [15:0] exp_th   [0:N*64-1];
    reg [8*200:1] vecdir;
    reg [8*240:1] fname;
    integer errors = 0, c, q, bad_lut;

    task cmp;
        input integer k;
        input integer idx;
        input [31:0] got;
        input [8*8:1] nm;
        begin
            if (got !== exp_state[k * NS + idx]) begin
                errors = errors + 1;
                if (errors < 12) $display("case %0d %0s: got %0d want %0d", k, nm, got, exp_state[k * NS + idx]);
            end
        end
    endtask

    task check_case;
        input integer k;           // 0 = initial state
        begin
            cmp(k, 0, r_lg, "lg");     cmp(k, 1, r_sigma, "sigma"); cmp(k, 2, r_b, "b");       cmp(k, 3, r_a, "a");
            cmp(k, 4, r_lam, "lam");   cmp(k, 5, r_sharp, "sharp"); cmp(k, 6, r_core, "core"); cmp(k, 7, r_kmot, "kmot");
            cmp(k, 8, r_thr, "thr");
            if (k > 0) begin
                cmp(k, 9, r_p1, "p1"); cmp(k, 10, r_p50, "p50"); cmp(k, 11, r_p99, "p99"); cmp(k, 12, r_mean_q4, "mean_q4");
            end
            bad_lut = 0;
            for (q = 0; q < 1024; q = q + 1)
                if (lram[q] !== exp_lut[k * 1024 + q]) begin
                    bad_lut = bad_lut + 1;
                    if (bad_lut < 3 && errors < 12) $display("case %0d LUT[%0d]: got %0d want %0d", k, q, lram[q], exp_lut[k * 1024 + q]);
                end
            if (bad_lut != 0) errors = errors + 1;
            if (k > 0) begin
                for (q = 0; q < 64; q = q + 1)
                    if (th_cap[q] !== exp_th[(k - 1) * 64 + q]) begin
                        errors = errors + 1;
                        if (errors < 12) $display("case %0d th[%0d]: got %0d want %0d", k, q, th_cap[q], exp_th[(k - 1) * 64 + q]);
                    end
                for (q = 0; q < 256; q = q + 1)
                    if (hram[q] !== 19'd0) begin errors = errors + 1; if (errors < 12) $display("case %0d: bin %0d not cleared", k, q); q = 256; end
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("vec=%s", vecdir)) begin $display("RESULT: FAIL (no +vec)"); $finish; end
        $sformat(fname, "%0s/hist.hex", vecdir);      $readmemh(fname, hist_mem);
        $sformat(fname, "%0s/in.hex", vecdir);        $readmemh(fname, in_mem);
        $sformat(fname, "%0s/exp_state.hex", vecdir); $readmemh(fname, exp_state);
        $sformat(fname, "%0s/exp_lut.hex", vecdir);   $readmemh(fname, exp_lut);
        $sformat(fname, "%0s/exp_th.hex", vecdir);    $readmemh(fname, exp_th);
        for (q = 0; q < 256; q = q + 1) hram[q] = 19'd0;
        for (q = 0; q < 1024; q = q + 1) lram[q] = 8'd0;
        #100 rst_n = 1'b1;
        wait (done);                        // initial flow
        @(posedge clk); #1;
        check_case(0);
        for (c = 1; c <= N; c = c + 1) begin
            for (q = 0; q < 256; q = q + 1) hram[q] = hist_mem[(c - 1) * 256 + q];
            out_sum    = in_mem[(c - 1) * 3 + 0];
            noise_sum  = in_mem[(c - 1) * 3 + 1];
            passthru   = in_mem[(c - 1) * 3 + 2][0];
            for (q = 0; q < 64; q = q + 1) th_cap[q] = 16'hxxxx;
            @(posedge clk); start <= 1'b1;
            @(posedge clk); start <= 1'b0;
            wait (done);
            @(posedge clk); #1;
            check_case(c);
        end
        if (errors == 0) $display("RESULT: PASS (%0d cases, %0dx%0d)", N, W, H);
        else             $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end

    initial begin #(40 * 20000 * (N + 2)); $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
