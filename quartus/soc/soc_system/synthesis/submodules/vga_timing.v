`timescale 1ns/1ps
// vga_timing.v -- VGA timing master (default 640x480, 800x525 total, 25.0 MHz -> 59.52 Hz).
//
// This module is the frame/line clock of the whole design: every datapath stage downstream
// is lockstep with it (roadmap Architecture decision 1). `de` is low during blanking, so
// consumers MUST tolerate gaps (checklist 1.7).
//
// Latency: all outputs are registered from the internal counters, i.e. one clock after the
// counter value they describe. They are mutually aligned.
//
//   x, y   : position in the active area, unsigned integers (Q0). Valid only when de=1.
//   de     : 1 during active video.
//   hs_n/vs_n : sync pulses, active low (standard 640x480@60).
//   sof    : single-cycle pulse aligned with the first active pixel (x=0,y=0,de=1).
//   vblank : 1 for all lines at/after V_ACTIVE (controller/LUT work window, ~V_BLANK*H_TOTAL clocks).
//
// Counters are 11 bits wide so parameter overrides up to 2047 total are legal.
module vga_timing #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         hs_n,
    output reg         vs_n,
    output reg         de,
    output reg         sof,
    output reg         vblank,
    output reg  [10:0] x,
    output reg  [10:0] y
);
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [10:0] hcnt;
    reg [10:0] vcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 11'd0;
            vcnt <= 11'd0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 11'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 11'd0 : vcnt + 11'd1;
        end else begin
            hcnt <= hcnt + 11'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_n   <= 1'b1;
            vs_n   <= 1'b1;
            de     <= 1'b0;
            sof    <= 1'b0;
            vblank <= 1'b0;
            x      <= 11'd0;
            y      <= 11'd0;
        end else begin
            de     <= (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);
            hs_n   <= ~((hcnt >= H_ACTIVE + H_FP) && (hcnt < H_ACTIVE + H_FP + H_SYNC));
            vs_n   <= ~((vcnt >= V_ACTIVE + V_FP) && (vcnt < V_ACTIVE + V_FP + V_SYNC));
            sof    <= (hcnt == 0) && (vcnt == 0);
            vblank <= (vcnt >= V_ACTIVE);
            x      <= hcnt;
            y      <= vcnt;
        end
    end
endmodule
