// vga_timing_tb.v -- self-checking structural test of vga_timing (640x480, 800x525).
// Verdict line: "RESULT: PASS" or "RESULT: FAIL" (scripts/run_regression.py treats anything else as FAIL).
//
// Latency ledger: every checked signal is an output of vga_timing, all registered the same number of
// clocks after the internal counters; checks are relative (counts, widths, periods), so no offset applies.
`timescale 1ns/1ps
module vga_timing_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    wire        hs_n, vs_n, de, sof, vblank;
    wire [10:0] x, y;
    vga_timing dut (.clk(clk), .rst_n(rst_n), .hs_n(hs_n), .vs_n(vs_n), .de(de), .sof(sof),
                    .vblank(vblank), .x(x), .y(y));

    integer errors = 0;
    integer cyc = 0;            // clocks since first sof
    integer frames = 0;
    integer last_sof_cyc = -1;
    integer de_cnt = 0, vblank_cnt = 0;
    integer hs_low_run = 0, vs_low_run = 0;
    integer hs_fall_cyc = -1, last_hs_fall = -1;
    integer hs_widths_bad = 0, hs_period_bad = 0, vs_width_bad = 0;
    integer vs_seen = 0;
    reg hs_prev = 1'b1, vs_prev = 1'b1;
    integer maxx = 0, maxy = 0;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            $display("FAIL @%0t: %0s", $time, msg);
        end
    endtask

    initial begin
        #100 rst_n = 1'b1;
    end

    always @(posedge clk) if (rst_n) begin
        cyc <= cyc + 1;
        if (de) begin
            de_cnt = de_cnt + 1;
            if (x > maxx) maxx = x;
            if (y > maxy) maxy = y;
            if (x > 639 || y > 479) fail("active pixel outside 640x480");
        end
        if (vblank) vblank_cnt = vblank_cnt + 1;
        if (sof) begin
            if (!de || x != 0 || y != 0) fail("sof not on first active pixel");
            if (last_sof_cyc >= 0) begin
                if (cyc - last_sof_cyc != 420000) begin
                    fail("frame period != 420000 clocks");
                    $display("  got %0d", cyc - last_sof_cyc);
                end
                if (de_cnt != 307200) begin
                    fail("active pixels per frame != 307200");
                    $display("  got %0d", de_cnt);
                end
                if (vblank_cnt != 45 * 800) begin
                    fail("vblank clocks per frame != 36000");
                    $display("  got %0d", vblank_cnt);
                end
                frames = frames + 1;
            end
            last_sof_cyc = cyc;
            de_cnt = 0;
            vblank_cnt = 0;
        end
        // hsync: 96-clock low pulse, 800-clock period
        if (hs_prev && !hs_n) begin
            if (last_hs_fall >= 0 && cyc - last_hs_fall != 800) hs_period_bad = hs_period_bad + 1;
            last_hs_fall = cyc;
            hs_low_run = 0;
        end
        if (!hs_n) hs_low_run = hs_low_run + 1;
        if (!hs_prev && hs_n && hs_low_run != 96) hs_widths_bad = hs_widths_bad + 1;
        // vsync: 2 lines = 1600 clocks low
        if (vs_prev && !vs_n) vs_low_run = 0;
        if (!vs_n) vs_low_run = vs_low_run + 1;
        if (!vs_prev && vs_n) begin
            vs_seen = vs_seen + 1;
            if (vs_low_run != 1600) vs_width_bad = vs_width_bad + 1;
        end
        hs_prev = hs_n;
        vs_prev = vs_n;
    end

    initial begin
        wait (frames == 3);
        #1;
        if (maxx != 639) fail("max x != 639");
        if (maxy != 479) fail("max y != 479");
        if (hs_widths_bad != 0) fail("hsync width != 96");
        if (hs_period_bad != 0) fail("hsync period != 800");
        if (vs_width_bad != 0) fail("vsync width != 1600 clocks");
        if (vs_seen < 3) fail("fewer than 3 vsync pulses seen");
        if (errors == 0) $display("RESULT: PASS (frames=%0d)", frames);
        else             $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end

    // watchdog: 4 frames + margin
    initial begin
        #(40 * 420000 * 5);
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
