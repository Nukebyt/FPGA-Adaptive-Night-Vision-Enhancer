`timescale 1ns/1ps
// test_pattern.v -- on-chip video source for bring-up and Phase 3a (roadmap task 3a.2).
//
// Pixel format: 8-bit luma, Q0 unsigned (0..255). Latency from (de,x,y) to pix: LATENCY clocks.
// All pattern content is a pure function of (x, y, mode, level, bx, lfsr state), and the LFSR is
// re-seeded on every frame start, so every frame of a given mode is identical (needed for the
// "same input -> bit-identical output" hardware gate, checklist 4.1).
//
//   mode 0: horizontal ramp, pix = (x*102)>>8   (x=0..639 -> 0..254)
//   mode 1: 64-px checkerboard (40/200) with a 64x64 white block moving 4 px/frame, wrapping at 576
//   mode 2: pseudo-random noise, 32-bit Galois LFSR (taps 32,22,2,1), re-seeded at sof
//   mode 3: flat grey = level
// Outside the active area (de=0) pix is 0.
//
// Constants duplicated elsewhere: ramp multiplier 102 / shift 8 and block step 4 / wrap 576 are
// mirrored in tb/test_pattern_tb.v. LFSR seed/mask mirrored in tb/test_pattern_tb.v.
module test_pattern (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        sof,       // first active pixel of the frame (aligned with de/x/y)
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire [1:0]  mode,
    input  wire [7:0]  level,
    output reg  [7:0]  pix
);
    localparam LATENCY   = 1;
    localparam LFSR_SEED = 32'hACE1_2468;
    localparam LFSR_MASK = 32'h8020_0003;
    localparam BLOCK_STEP = 4;
    localparam BLOCK_WRAP = 576;

    reg  [9:0]  bx;
    reg  [31:0] lfsr;

    // lfsr value used for the current pixel; at sof it is the seed (re-seed happens in the same cycle)
    wire [31:0] lfsr_cur = sof ? LFSR_SEED : lfsr;
    wire [31:0] lfsr_nxt = lfsr_cur[0] ? ((lfsr_cur >> 1) ^ LFSR_MASK) : (lfsr_cur >> 1);

    wire [17:0] ramp_full = x * 18'd102;           // 11b * 7b, Q0
    wire [7:0]  ramp      = ramp_full[15:8];       // >>8; max 639*102>>8 = 254, fits 8 bits
    wire        in_block  = (x >= bx) && (x < bx + 64) && (y >= 208) && (y < 272);
    wire        chk       = x[6] ^ y[6];           // 64-px squares

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bx   <= 10'd0;
            lfsr <= LFSR_SEED;
            pix  <= 8'd0;
        end else begin
            if (de) lfsr <= lfsr_nxt;
            if (sof) bx <= (bx + BLOCK_STEP >= BLOCK_WRAP) ? 10'd0 : bx + BLOCK_STEP;
            if (!de) pix <= 8'd0;
            else case (mode)
                2'd0: pix <= ramp;
                2'd1: pix <= in_block ? 8'd255 : (chk ? 8'd200 : 8'd40);
                2'd2: pix <= lfsr_cur[7:0];
                2'd3: pix <= level;
            endcase
        end
    end
endmodule
