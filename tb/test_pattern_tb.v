// test_pattern_tb.v -- self-checking test of test_pattern driven by the real vga_timing (includes blanking gaps).
// Verdict line: "RESULT: PASS" / "RESULT: FAIL".
//
// Latency ledger
//   test_pattern.pix is registered once: pix at edge N+1 is the value for inputs sampled at edge N.
//   Expected value and pix are both read pre-NBA at the same edge, so exp_q (computed one edge
//   earlier) is compared with pix directly. LATENCY = 1 (mirrors test_pattern's localparam).
//
// The expected-pixel model is written independently of the RTL expressions (integer arithmetic, no
// shared wires). Constants mirrored from rtl/test_pattern.v: ramp 102>>8, block step 4 / wrap 576,
// LFSR seed 32'hACE12468, mask 32'h80200003.
//
// Frame plan (0-based): modes 0,1,2,3,2,1. Frames 2 and 4 are both mode 2 (noise) and must hash equal.
`timescale 1ns/1ps
module test_pattern_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;

    wire        hs_n, vs_n, de, sof, vblank;
    wire [10:0] x, y;
    vga_timing u_t (.clk(clk), .rst_n(rst_n), .hs_n(hs_n), .vs_n(vs_n), .de(de), .sof(sof),
                    .vblank(vblank), .x(x), .y(y));

    reg  [1:0] mode;
    reg  [7:0] level = 8'h5A;
    wire [7:0] pix;
    test_pattern dut (.clk(clk), .rst_n(rst_n), .de(de), .sof(sof), .x(x), .y(y),
                      .mode(mode), .level(level), .pix(pix));

    function [1:0] mode_of;
        input integer f;
        begin
            case (f)
                0: mode_of = 2'd0;
                1: mode_of = 2'd1;
                2: mode_of = 2'd2;
                3: mode_of = 2'd3;
                4: mode_of = 2'd2;
                default: mode_of = 2'd1;
            endcase
        end
    endfunction

    integer    errors = 0;
    integer    fcnt = 0;             // sof pulses seen so far (frame k's sof makes fcnt = k+1)
    integer    cmp_cnt = 0;
    reg [7:0]  exp_q = 8'd0;
    reg        exp_valid = 1'b0;
    reg        de_q = 1'b0;          // de sampled one edge earlier = "pix is an active pixel"
    integer    bx_m = 0;
    reg [31:0] lf_m = 32'hACE12468;
    reg [31:0] lf_cur;
    reg [7:0]  e;
    reg [31:0] hash_acc = 32'd0;
    reg [31:0] hash_f2 = 32'd0, hash_f4 = 32'd0;

    initial begin
        mode = mode_of(0);
        #100 rst_n = 1'b1;
    end

    // mode changes only in vertical blanking, so each frame has a single mode
    always @(posedge clk) if (rst_n && vblank) mode <= mode_of(fcnt);

    always @(posedge clk) if (rst_n) begin
        // 1) check the value produced from last edge's inputs
        if (exp_valid) begin
            cmp_cnt = cmp_cnt + 1;
            if (pix !== exp_q) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH @%0t frame=%0d exp=%0d got=%0d", $time, fcnt - 1, exp_q, pix);
            end
        end
        // 2) per-frame hash of active pixels (pix is active when de_q), closed at the next sof
        if (de_q) hash_acc = hash_acc * 32'd33 + {24'd0, pix};
        if (sof) begin
            if (fcnt == 3) hash_f2 = hash_acc;      // closes frame 2
            if (fcnt == 5) hash_f4 = hash_acc;      // closes frame 4
            hash_acc = 32'd0;
            fcnt = fcnt + 1;
        end
        // 3) compute expectation for the inputs sampled at this edge
        exp_valid = 1'b1;
        lf_cur = sof ? 32'hACE12468 : lf_m;
        if (!de) e = 8'd0;
        else case (mode)
            2'd0: e = (x * 102) >> 8;
            2'd1: begin
                if ((x >= bx_m) && (x < bx_m + 64) && (y >= 208) && (y < 272)) e = 8'd255;
                else if (((x / 64) % 2) != ((y / 64) % 2)) e = 8'd200;
                else e = 8'd40;
            end
            2'd2: e = lf_cur[7:0];
            2'd3: e = level;
        endcase
        exp_q = e;
        de_q = de;
        // 4) state advance (same ordering as the RTL: state used first, then updated)
        if (de) lf_m = lf_cur[0] ? ((lf_cur >> 1) ^ 32'h80200003) : (lf_cur >> 1);
        if (sof) bx_m = (bx_m + 4 >= 576) ? 0 : bx_m + 4;
    end

    initial begin
        wait (fcnt == 6);
        #200;
        if (hash_f2 !== hash_f4) begin
            errors = errors + 1;
            $display("FAIL: noise frames 2 and 4 differ (%h vs %h)", hash_f2, hash_f4);
        end
        if (hash_f2 === 32'd0) begin
            errors = errors + 1;
            $display("FAIL: noise hash is zero (hash logic dead)");
        end
        if (cmp_cnt < 5 * 420000) begin
            errors = errors + 1;
            $display("FAIL: only %0d comparisons made", cmp_cnt);
        end
        if (errors == 0) $display("RESULT: PASS (comparisons=%0d, noise hash=%h)", cmp_cnt, hash_f2);
        else             $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end

    initial begin
        #(40 * 420000 * 9);
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
