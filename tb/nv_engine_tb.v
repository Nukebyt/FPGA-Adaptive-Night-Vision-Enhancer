`timescale 1ns/1ps
// nv_engine_tb.v -- system-level twin of the hardware test: a testbench playing the role of the HPS software around nv_engine.
// Verdict: "RESULT: PASS" / "RESULT: FAIL".
//
// Memory model: 4 MiB of 64-bit words, Avalon-MM read channel with LAT clocks of latency + random waitrequest (+rstall %),
// write channel with random waitrequest (+wstall %). Input ring at 0x000000, output ring at 0x200000, 4 slots of 512 KiB each.
// "Software" (this testbench) writes frames into input slots with a backdoor, bumps IN_WR_SEQ over the CSR bus, keeps at most
// 3 frames queued (+burst=1) or waits for each result (+burst=0), and verifies every completed frame as OUT_SEQ increments:
//   * output frame bytes in the output slot == exp_out.hex   (bit exact vs pipeline_int.py)
//   * telemetry registers: parameters USED for the frame == exp_state[f], measured stats == exp_state[f+1]
//   * hist64 window == histogram of the input frame computed here
// Then FRAME_RESET and the first +rerun frames are processed again and must give the SAME outputs (checklist Gate 0).
// Finally: no sticky error flags, IN_RD_SEQ == OUT_SEQ == frames processed, SCRATCH echo and VERSION read correctly.
// Latency ledger: not needed, results are compared by frame number through the sequence counters.
module nv_engine_tb;
    parameter W = 32, H = 24, T = 8, C_SIG = 1359329, NS = 15, LAT = 4;
    localparam NPIX = W * H;
    localparam NWORD = NPIX / 8;
    localparam IN_BASE = 32'h000000, OUT_BASE = 32'h200000, STRIDE = 32'h080000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #20 clk = ~clk;

    // CSR bus
    reg  [7:0]  csr_address = 0;
    reg         csr_read = 0, csr_write = 0;
    reg  [31:0] csr_writedata = 0;
    wire [31:0] csr_readdata;
    // memory buses
    wire [31:0] rd_address, wr_address;
    wire        rd_read, wr_write;
    reg         rd_waitrequest = 0, wr_waitrequest = 0;
    reg  [63:0] rd_readdata = 0;
    reg         rd_readdatavalid = 0;
    wire [63:0] wr_writedata;
    wire [7:0]  wr_byteenable;
    wire [15:0] st_lg;
    wire        st_ready, st_enabled, st_error;
    wire [31:0] st_frames;

    nv_engine #(.W(W), .H(H), .C_SIG(C_SIG)) dut (
        .clk(clk), .rst_n(rst_n),
        .csr_address(csr_address), .csr_read(csr_read), .csr_write(csr_write), .csr_writedata(csr_writedata), .csr_readdata(csr_readdata),
        .rd_address(rd_address), .rd_read(rd_read), .rd_waitrequest(rd_waitrequest), .rd_readdata(rd_readdata), .rd_readdatavalid(rd_readdatavalid),
        .wr_address(wr_address), .wr_write(wr_write), .wr_writedata(wr_writedata), .wr_byteenable(wr_byteenable), .wr_waitrequest(wr_waitrequest),
        .st_lg(st_lg), .st_ready(st_ready), .st_enabled(st_enabled), .st_error(st_error), .st_frames(st_frames));

    // ------------------------------------------------------------------ memory model
    reg [63:0] mem [0:524287];
    integer rstall, wstall, seed = 4711;
    reg [63:0] pipe_d [0:15];
    reg        pipe_v [0:15];
    integer    pi;
    wire rd_acc = rd_read & ~rd_waitrequest;
    wire wr_acc = wr_write & ~wr_waitrequest;
    always @(posedge clk) begin
        // read channel: fixed LAT-clock latency pipeline
        for (pi = 15; pi > 0; pi = pi - 1) begin pipe_d[pi] <= pipe_d[pi - 1]; pipe_v[pi] <= pipe_v[pi - 1]; end
        pipe_v[0] <= rd_acc;
        pipe_d[0] <= mem[rd_address[22:3]];
        rd_readdatavalid <= pipe_v[LAT - 1];
        rd_readdata      <= pipe_d[LAT - 1];
        rd_waitrequest   <= (($random(seed) & 32'h7fffffff) % 100) < rstall;
        // write channel
        if (wr_acc) mem[wr_address[22:3]] <= wr_writedata;
        wr_waitrequest   <= (($random(seed) & 32'h7fffffff) % 100) < wstall;
    end
    initial for (pi = 0; pi < 16; pi = pi + 1) pipe_v[pi] = 1'b0;

    // ------------------------------------------------------------------ vectors
    reg [7:0]  in_mem   [0:T*NPIX-1];
    reg [7:0]  exp_out  [0:T*NPIX-1];
    reg [31:0] exp_state[0:(T+1)*NS-1];
    reg [8*200:1] vecdir;
    reg [8*240:1] fname;
    integer gap_dummy, burst, rerun;
    integer errors = 0;
    integer f, i, w;

    // ------------------------------------------------------------------ CSR bus tasks (one process at a time)
    reg csr_lock = 1'b0;
    reg [31:0] rd_val;
    task csr_wr;
        input [7:0] a;
        input [31:0] d;
        begin
            while (csr_lock) @(posedge clk);
            csr_lock = 1'b1;
            @(posedge clk); csr_address <= a; csr_writedata <= d; csr_write <= 1'b1;
            @(posedge clk); csr_write <= 1'b0;
            csr_lock = 1'b0;
        end
    endtask
    task csr_rd;
        input [7:0] a;
        begin
            while (csr_lock) @(posedge clk);
            csr_lock = 1'b1;
            @(posedge clk); csr_address <= a; csr_read <= 1'b1;
            @(posedge clk); csr_read <= 1'b0;
            @(posedge clk); rd_val = csr_readdata;
            csr_lock = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ backdoor frame access
    reg [63:0] wv;
    task put_frame;                         // software copies frame f into input slot (f % 4)
        input integer fr;
        integer ww, bb;
        begin
            for (ww = 0; ww < NWORD; ww = ww + 1) begin
                for (bb = 0; bb < 8; bb = bb + 1) wv[8 * bb +: 8] = in_mem[fr * NPIX + ww * 8 + bb];
                mem[(IN_BASE + (fr % 4) * STRIDE) / 8 + ww] = wv;
            end
        end
    endtask

    task check_frame;                       // after OUT_SEQ shows frame fr: compare bytes, telemetry, histogram window
        input integer fr;                   // frame index as in the vector files
        input integer ref_fr;               // which expected frame to compare with (fr, or fr again after FRAME_RESET)
        integer ww, bb, bad, q;
        reg [63:0] got;
        reg [31:0] eh [0:63];
        begin
            bad = 0;
            for (ww = 0; ww < NWORD; ww = ww + 1) begin
                got = mem[(OUT_BASE + (fr % 4) * STRIDE) / 8 + ww];
                for (bb = 0; bb < 8; bb = bb + 1)
                    if (got[8 * bb +: 8] !== exp_out[ref_fr * NPIX + ww * 8 + bb]) begin
                        bad = bad + 1;
                        if (bad < 4) $display("OUT f%0d px%0d: got %0d want %0d", ref_fr, ww * 8 + bb, got[8 * bb +: 8], exp_out[ref_fr * NPIX + ww * 8 + bb]);
                    end
            end
            if (bad != 0) errors = errors + 1;
            // telemetry (words 16..29), compared with the vector files
            csr_rd(8'd16); if (rd_val !== exp_state[ref_fr * NS + 0]) begin errors = errors + 1; $display("TEL lg f%0d got %0d want %0d", ref_fr, rd_val, exp_state[ref_fr * NS + 0]); end
            csr_rd(8'd17); if (rd_val !== exp_state[ref_fr * NS + 1]) begin errors = errors + 1; $display("TEL sigma f%0d got %0d want %0d", ref_fr, rd_val, exp_state[ref_fr * NS + 1]); end
            csr_rd(8'd18); if (rd_val !== exp_state[ref_fr * NS + 2]) begin errors = errors + 1; $display("TEL b f%0d", ref_fr); end
            csr_rd(8'd19); if (rd_val !== exp_state[ref_fr * NS + 3]) begin errors = errors + 1; $display("TEL a f%0d got %0d want %0d", ref_fr, rd_val, exp_state[ref_fr * NS + 3]); end
            csr_rd(8'd20); if (rd_val !== exp_state[ref_fr * NS + 4]) begin errors = errors + 1; $display("TEL lam f%0d", ref_fr); end
            csr_rd(8'd21); if (rd_val !== exp_state[ref_fr * NS + 5]) begin errors = errors + 1; $display("TEL sharp f%0d", ref_fr); end
            csr_rd(8'd22); if (rd_val !== exp_state[ref_fr * NS + 6]) begin errors = errors + 1; $display("TEL core f%0d", ref_fr); end
            csr_rd(8'd23); if (rd_val !== exp_state[ref_fr * NS + 7]) begin errors = errors + 1; $display("TEL kmot f%0d", ref_fr); end
            csr_rd(8'd24); if (rd_val !== exp_state[ref_fr * NS + 8]) begin errors = errors + 1; $display("TEL thr f%0d", ref_fr); end
            csr_rd(8'd25); if (rd_val !== exp_state[(ref_fr + 1) * NS + 9])  begin errors = errors + 1; $display("TEL p1 f%0d", ref_fr); end
            csr_rd(8'd26); if (rd_val !== exp_state[(ref_fr + 1) * NS + 10]) begin errors = errors + 1; $display("TEL p50 f%0d", ref_fr); end
            csr_rd(8'd27); if (rd_val !== exp_state[(ref_fr + 1) * NS + 11]) begin errors = errors + 1; $display("TEL p99 f%0d", ref_fr); end
            csr_rd(8'd28); if (rd_val !== exp_state[(ref_fr + 1) * NS + 12]) begin errors = errors + 1; $display("TEL mean f%0d got %0d want %0d", ref_fr, rd_val, exp_state[(ref_fr + 1) * NS + 12]); end
            // histogram window: independent computation from the input frame
            for (q = 0; q < 64; q = q + 1) eh[q] = 0;
            for (q = 0; q < NPIX; q = q + 1) eh[in_mem[ref_fr * NPIX + q] >> 2] = eh[in_mem[ref_fr * NPIX + q] >> 2] + 1;
            for (q = 0; q < 64; q = q + 1) begin
                csr_rd(8'd64 + q);
                if (rd_val !== (eh[q] >> 4)) begin errors = errors + 1; if (errors < 12) $display("HIST64[%0d] f%0d got %0d want %0d", q, ref_fr, rd_val, eh[q] >> 4); end
            end
        end
    endtask

    // ------------------------------------------------------------------ main flow
    reg [31:0] out_seq_v, in_rd_v;
    integer queued;
    task run_frames;                        // process frames [first, last) in order; seq counters were zeroed by FRAME_RESET / reset
        input integer first;
        input integer last;
        integer fr, nxt_w, done_o;
        begin
            nxt_w = first; done_o = first;
            while (done_o < last) begin
                // software: queue frames while fewer than 3 are outstanding
                csr_rd(8'd8); out_seq_v = rd_val;
                while (nxt_w < last && (nxt_w - first) - out_seq_v < ((burst != 0) ? 3 : 1)) begin
                    put_frame(nxt_w);
                    csr_wr(8'd6, (nxt_w - first) + 1);
                    nxt_w = nxt_w + 1;
                end
                csr_rd(8'd8); out_seq_v = rd_val;
                while ((done_o - first) < out_seq_v) begin
                    check_frame(done_o - first, done_o);        // output slot index = sequence number % 4 (relative to the reset)
                    done_o = done_o + 1;
                end
                repeat (200) @(posedge clk);
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("vec=%s", vecdir)) begin $display("RESULT: FAIL (no +vec)"); $finish; end
        if (!$value$plusargs("rstall=%d", rstall)) rstall = 0;
        if (!$value$plusargs("wstall=%d", wstall)) wstall = 0;
        if (!$value$plusargs("burst=%d", burst)) burst = 1;
        if (!$value$plusargs("rerun=%d", rerun)) rerun = 2;
        $sformat(fname, "%0s/in.hex", vecdir);        $readmemh(fname, in_mem);
        $sformat(fname, "%0s/exp_out.hex", vecdir);   $readmemh(fname, exp_out);
        $sformat(fname, "%0s/exp_state.hex", vecdir); $readmemh(fname, exp_state);
        for (i = 0; i < 524288; i = i + 1) mem[i] = 64'd0;
        #100 rst_n = 1'b1;
        repeat (20) @(posedge clk);
        // bus sanity: VERSION, SCRATCH echo, CLOCK_HZ
        csr_rd(8'd0);  if (rd_val !== 32'h4E560001) begin errors = errors + 1; $display("VERSION %h", rd_val); end
        csr_wr(8'd11, 32'hA5C3_1E7F); csr_rd(8'd11); if (rd_val !== 32'hA5C3_1E7F) begin errors = errors + 1; $display("SCRATCH echo 1 %h", rd_val); end
        csr_wr(8'd11, 32'h5A3C_E180); csr_rd(8'd11); if (rd_val !== 32'h5A3C_E180) begin errors = errors + 1; $display("SCRATCH echo 2 %h", rd_val); end
        csr_rd(8'd10); if (rd_val !== 32'd25000000) begin errors = errors + 1; $display("CLOCK_HZ %0d", rd_val); end
        // wait until the controller is initialised
        rd_val = 0;
        while (!rd_val[0]) csr_rd(8'd2);
        csr_wr(8'd4, IN_BASE); csr_wr(8'd5, OUT_BASE);
        csr_wr(8'd1, 32'h0000_001D);                 // enable, temporal, spatial, sharpen on (bits 0,2,3,4)
        run_frames(0, T);
        csr_rd(8'd7); if (rd_val !== T) begin errors = errors + 1; $display("IN_RD_SEQ %0d expected %0d", rd_val, T); end
        csr_rd(8'd8); if (rd_val !== T) begin errors = errors + 1; $display("OUT_SEQ %0d expected %0d", rd_val, T); end
        csr_rd(8'd2); if (rd_val[11:8] !== 4'd0) begin errors = errors + 1; $display("sticky status %h", rd_val); end
        // Gate 0: FRAME_RESET, then the first frames again must reproduce the same outputs
        if (rerun > 0) begin
            csr_wr(8'd1, 32'h0000_001F);             // frame_reset pulse (bit 1) with the same enables
            repeat (50) @(posedge clk);
            rd_val = 0;
            while (!rd_val[0]) csr_rd(8'd2);
            csr_wr(8'd1, 32'h0000_001D);
            csr_rd(8'd8); if (rd_val !== 0) begin errors = errors + 1; $display("OUT_SEQ after reset %0d", rd_val); end
            run_frames(0, rerun);
            csr_rd(8'd7); if (rd_val !== rerun) begin errors = errors + 1; $display("IN_RD_SEQ after reset run %0d expected %0d", rd_val, rerun); end
            csr_rd(8'd8); if (rd_val !== rerun) begin errors = errors + 1; $display("OUT_SEQ after reset run %0d expected %0d", rd_val, rerun); end
            csr_rd(8'd2); if (rd_val[11:8] !== 4'd0) begin errors = errors + 1; $display("sticky status after rerun %h", rd_val); end
        end
        if (errors == 0) $display("RESULT: PASS (%0dx%0d, %0d frames + %0d after reset, burst=%0d rstall=%0d%% wstall=%0d%%)", W, H, T, rerun, burst, rstall, wstall);
        else             $display("RESULT: FAIL (errors=%0d)", errors);
        $finish;
    end

    initial begin #(40 * 4000000 * (T + 6)); $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
