`timescale 1ns/1ps
// bringup_top.v -- DE10-Standard bring-up design (roadmap task 0.5b), seed of the real top level.
//
// What it proves: PLL 50 -> 25 MHz locks and gates reset, VGA timing/DAC path shows a pattern,
// heartbeats prove both clocks are alive, KEY/SW/LED/HEX pin assignments are right.
//
// Controls
//   KEY[0]    : reset (press = reset)
//   SW[1:0]   : pattern mode (0 ramp, 1 checker+moving block, 2 LFSR noise, 3 flat grey)
//   SW[9:2]   : flat grey level for mode 3
// Indicators
//   LEDR[0]   : CLOCK_50 heartbeat (bit 25 of a free counter, ~1.34 s period, same as board_check)
//   LEDR[1]   : clk25 heartbeat (bit 24, ~1.34 s period)
//   LEDR[2]   : PLL locked
//   LEDR[3]   : design out of reset
//   LEDR[9:4] : SW[9:4] mirror
//   HEX5..HEX0: 24-bit frame counter in hex (increments once per frame, 59.5 Hz)
//
// Output alignment: pattern latency is 1 clock, so de/hs/vs are delayed 1 clock to match.
module bringup_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire        VGA_CLK,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire [7:0]  VGA_R,
    output wire [7:0]  VGA_G,
    output wire [7:0]  VGA_B,
    output wire        VGA_BLANK_N,
    output wire        VGA_SYNC_N
);
    // ---------------- clocks and reset ----------------
    wire clk25;
    wire pll_locked;

    pll25 pll_inst (
        .refclk   (CLOCK_50),
        .rst      (1'b0),
        .outclk_0 (clk25),
        .locked   (pll_locked)
    );

    // Reset for everything on clk25 is gated by PLL lock (checklist 2.6).
    wire rst_n;
    reset_sync #(.STAGES(3)) u_rst (
        .clk       (clk25),
        .rst_n_in  (KEY[0] & pll_locked),
        .rst_n_out (rst_n)
    );

    // ---------------- video timing + source ----------------
    wire        hs_n, vs_n, de, sof, vblank;
    wire [10:0] x, y;

    vga_timing u_timing (
        .clk(clk25), .rst_n(rst_n),
        .hs_n(hs_n), .vs_n(vs_n), .de(de), .sof(sof), .vblank(vblank),
        .x(x), .y(y)
    );

    wire [7:0] pix;
    test_pattern u_pat (
        .clk(clk25), .rst_n(rst_n),
        .de(de), .sof(sof), .x(x), .y(y),
        .mode(SW[1:0]), .level(SW[9:2]),
        .pix(pix)
    );

    // Align control signals with pix (test_pattern LATENCY = 1).
    reg hs_d, vs_d, de_d;
    always @(posedge clk25 or negedge rst_n) begin
        if (!rst_n) begin
            hs_d <= 1'b1; vs_d <= 1'b1; de_d <= 1'b0;
        end else begin
            hs_d <= hs_n; vs_d <= vs_n; de_d <= de;
        end
    end

    assign VGA_CLK     = clk25;
    assign VGA_HS      = hs_d;
    assign VGA_VS      = vs_d;
    assign VGA_R       = pix;
    assign VGA_G       = pix;
    assign VGA_B       = pix;
    assign VGA_BLANK_N = de_d;
    assign VGA_SYNC_N  = 1'b0;      // sync-on-green unused (separate HS/VS)

    // ---------------- debug / status ----------------
    reg [25:0] hb50 = 26'd0;
    always @(posedge CLOCK_50) hb50 <= hb50 + 26'd1;

    reg [24:0] hb25;
    always @(posedge clk25 or negedge rst_n) begin
        if (!rst_n) hb25 <= 25'd0;
        else        hb25 <= hb25 + 25'd1;
    end

    reg [23:0] frame_cnt;
    always @(posedge clk25 or negedge rst_n) begin
        if (!rst_n)    frame_cnt <= 24'd0;
        else if (sof)  frame_cnt <= frame_cnt + 24'd1;
    end

    assign LEDR[0]   = hb50[25];
    assign LEDR[1]   = hb25[24];
    assign LEDR[2]   = pll_locked;
    assign LEDR[3]   = rst_n;
    assign LEDR[9:4] = SW[9:4];

    hex7seg h0 (.d(frame_cnt[3:0]),   .seg_n(HEX0));
    hex7seg h1 (.d(frame_cnt[7:4]),   .seg_n(HEX1));
    hex7seg h2 (.d(frame_cnt[11:8]),  .seg_n(HEX2));
    hex7seg h3 (.d(frame_cnt[15:12]), .seg_n(HEX3));
    hex7seg h4 (.d(frame_cnt[19:16]), .seg_n(HEX4));
    hex7seg h5 (.d(frame_cnt[23:20]), .seg_n(HEX5));
endmodule
