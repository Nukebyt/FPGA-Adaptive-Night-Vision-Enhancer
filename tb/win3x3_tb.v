`timescale 1ns/1ps
// win3x3_tb.v -- self-checking test of win3x3 against an independently written expected-window model.
// Verdict line: "RESULT: PASS" / "RESULT: FAIL".
//
// Stimulus: NF frames of W x H random pixels (full entropy, checklist 3.1), random gaps in in_valid with
// probability GAPP percent per clock (checklist 1.7; GAPP sweeps via the plusarg +gap), frames separated by
// FGAP idle clocks (>= W+2 required by the DUT).
// Latency ledger: outputs are compared in ORDER by output index (no latency assumption); the only timing facts
// checked are (a) exactly W*H outputs per frame, (b) sof/eof on the first/last, (c) no output before W+2 ticks.
// Expected taps: clamp(x+dx), clamp(y+dy) into the frame (replicate border), computed with integer arithmetic here.
module win3x3_tb;
    parameter W = 8, H = 6, DW = 10, NF = 4, CW = 10;
    integer GAPP, FGAP;
    reg clk = 1'b0, rst_n = 1'b0;
    always #20 clk = ~clk;

    reg          in_valid = 1'b0, in_sof = 1'b0;
    reg [DW-1:0] in_data  = {DW{1'b0}};
    wire         out_valid, out_sof, out_eof, out_fc, out_lc, out_fr, out_lr, overrun;
    wire [DW-1:0] t0, t1, t2, t3, t4, t5, t6, t7, t8;

    win3x3 #(.DW(DW), .W(W), .H(H), .CW(CW)) dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_sof(in_sof),
        .in_data(in_data), .out_valid(out_valid), .out_sof(out_sof), .out_eof(out_eof), .out_fc(out_fc), .out_lc(out_lc),
        .out_fr(out_fr), .out_lr(out_lr), .t0(t0), .t1(t1), .t2(t2), .t3(t3), .t4(t4), .t5(t5), .t6(t6), .t7(t7), .t8(t8),
        .overrun(overrun));

    reg [DW-1:0] fr_mem [0:NF*W*H-1];
    integer seed = 12345;
    integer errors = 0;
    integer outcnt = 0;
    integer i, f, k;

    // ---------------- stimulus (non-blocking drives, checklist 3.6) ----------------
    initial begin
        if (!$value$plusargs("gap=%d", GAPP)) GAPP = 0;
        FGAP = W + 4;
        for (i = 0; i < NF * W * H; i = i + 1) fr_mem[i] = $random(seed) & ((1 << DW) - 1);
        #100 rst_n = 1'b1;
        repeat (3) @(posedge clk);
        for (f = 0; f < NF; f = f + 1) begin
            k = 0;
            while (k < W * H) begin
                @(posedge clk);
                if (($random(seed) & 32'h7fffffff) % 100 < GAPP) begin
                    in_valid <= 1'b0; in_sof <= 1'b0;
                end else begin
                    in_valid <= 1'b1;
                    in_sof   <= (k == 0);
                    in_data  <= fr_mem[f * W * H + k];
                    k = k + 1;
                end
            end
            @(posedge clk);
            in_valid <= 1'b0; in_sof <= 1'b0;
            repeat (FGAP) @(posedge clk);
        end
        repeat (4 * W) @(posedge clk);
        if (overrun) begin errors = errors + 1; $display("FAIL: overrun flagged"); end
        if (outcnt != NF * W * H) begin errors = errors + 1; $display("FAIL: %0d outputs, expected %0d", outcnt, NF * W * H); end
        if (errors == 0) $display("RESULT: PASS (gap=%0d%%, outputs=%0d)", GAPP, outcnt);
        else             $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end

    // ---------------- checker ----------------
    integer m, fi, xx, yy, dy, dx, ex, ey, exp_v;
    reg [DW-1:0] got [0:8];
    reg [DW-1:0] want;
    integer q;
    always @(posedge clk) if (rst_n && out_valid) begin
        m  = outcnt % (W * H);
        fi = outcnt / (W * H);
        yy = m / W;
        xx = m % W;
        got[0] = t0; got[1] = t1; got[2] = t2; got[3] = t3; got[4] = t4; got[5] = t5; got[6] = t6; got[7] = t7; got[8] = t8;
        for (dy = -1; dy <= 1; dy = dy + 1)
            for (dx = -1; dx <= 1; dx = dx + 1) begin
                ex = xx + dx; if (ex < 0) ex = 0; if (ex > W - 1) ex = W - 1;
                ey = yy + dy; if (ey < 0) ey = 0; if (ey > H - 1) ey = H - 1;
                want = fr_mem[fi * W * H + ey * W + ex];
                q = (dy + 1) * 3 + (dx + 1);
                if (got[q] !== want) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH out %0d (f%0d x%0d y%0d) tap %0d: got %0d want %0d", outcnt, fi, xx, yy, q, got[q], want);
                end
            end
        if (out_sof !== (m == 0))          begin errors = errors + 1; if (errors < 10) $display("sof wrong at out %0d", outcnt); end
        if (out_eof !== (m == W * H - 1))  begin errors = errors + 1; if (errors < 10) $display("eof wrong at out %0d", outcnt); end
        if (out_fc !== (xx == 0) || out_lc !== (xx == W - 1) || out_fr !== (yy == 0) || out_lr !== (yy == H - 1)) begin
            errors = errors + 1; if (errors < 10) $display("flags wrong at out %0d", outcnt);
        end
        outcnt = outcnt + 1;
    end

    initial begin #(40 * 200000); $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
