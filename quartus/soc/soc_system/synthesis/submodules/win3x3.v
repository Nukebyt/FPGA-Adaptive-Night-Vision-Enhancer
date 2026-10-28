`timescale 1ns/1ps
// win3x3.v -- streaming 3x3 window generator with replicate borders, shared by every filter stage.
//
// Input : in_valid/in_sof/in_data, raster order, W x H pixels per frame, ARBITRARY gaps in in_valid.
// Output: for every pixel of the frame, in raster order, the 3x3 neighbourhood centred on it (t0..t8 =
//         (x-1,y-1) (x,y-1) (x+1,y-1) (x-1,y) (x,y) (x+1,y) (x-1,y+1) (x,y+1) (x+1,y+1)), with coordinates
//         outside the frame replaced by the nearest edge pixel (identical to model/pipeline_int.win9).
//
// Timing (latency ledger, checklist 3.3). A "tick" is a clock edge with en = in_valid | flushing.
//   Output m (centre index m = 0..W*H-1) is produced by tick n = m + W + 1 (0-based tick count within the
//   frame), registered, so it is visible after that edge together with out_valid. Ticks 0..W*H-1 are real
//   input pixels, the last W+1 ticks are FLUSH ticks the module generates by itself right after the last real
//   pixel (dummy data), one per clock. So for gap-free input the first output appears W+2 clocks after the first
//   pixel; with gaps, latency in clocks grows by the number of gap clocks before tick W+1.
//   Between frames at least W+2 clocks without in_valid are required after the last pixel (overrun flag otherwise).
//   LATENCY_TICKS = W + 1 (exported as a localparam for testbench ledgers).
//
// Line buffers are two ram_sdp instances (registered read). Each reads ONE ADDRESS AHEAD of the write address,
// so a same-address read/write never happens (no dependence on read-during-write behaviour).
//
// Flags are aligned with the output taps: out_fc/out_lc first/last column of the centre, out_fr/out_lr first/last row.
module win3x3 #(
    parameter DW = 8,
    parameter W  = 640,
    parameter H  = 480,
    parameter CW = 10            // column counter width, W <= 2**CW
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_valid,
    input  wire          in_sof,
    input  wire [DW-1:0] in_data,
    output reg           out_valid,
    output reg           out_sof,
    output reg           out_eof,
    output reg           out_fc,
    output reg           out_lc,
    output reg           out_fr,
    output reg           out_lr,
    output reg  [DW-1:0] t0, t1, t2, t3, t4, t5, t6, t7, t8,
    output reg           overrun   // sticky: in_valid arrived while a previous frame was still flushing
);
    localparam LATENCY_TICKS = W + 1;

    reg [CW-1:0] col;              // column of the NEXT tick = line buffer address
    reg [CW-1:0] last_row_cnt;     // counts real input rows (0..H-1)
    reg [CW:0]   flush_left;       // remaining flush ticks
    reg [CW:0]   warm_cnt;
    reg          warm;
    reg [CW-1:0] ox;
    reg [CW-1:0] oy;

    wire flushing = (flush_left != 0);
    wire en       = in_valid | flushing;
    wire [DW-1:0] din = in_valid ? in_data : {DW{1'b0}};
    wire [CW-1:0] col_next = (col == W - 1) ? {CW{1'b0}} : col + 1'b1;
    wire [CW-1:0] raddr    = en ? col_next : col;
    wire last_real = in_valid && (col == W - 1) && (last_row_cnt == H - 1);

    wire [DW-1:0] a_rd, b_rd;
    ram_sdp #(.DW(DW), .AW(CW), .DEPTH(W)) lb_a (.clk(clk), .we(en), .waddr(col), .wdata(din),  .raddr(raddr), .rdata(a_rd));
    ram_sdp #(.DW(DW), .AW(CW), .DEPTH(W)) lb_b (.clk(clk), .we(en), .waddr(col), .wdata(a_rd), .raddr(raddr), .rdata(b_rd));

    // column registers: (top, mid, bot) of the two previous columns
    reg [DW-1:0] a_top, a_mid, a_bot;   // column x-2 (older)
    reg [DW-1:0] b_top, b_mid, b_bot;   // column x-1 (centre column)

    // flags of the output being produced at this edge (pre-increment counters)
    wire fc = (ox == 0);
    wire lc = (ox == W - 1);
    wire fr = (oy == 0);
    wire lr = (oy == H - 1);

    // new column (x) and replicate-row substitutions
    wire [DW-1:0] n_top = b_rd, n_mid = a_rd, n_bot = din;
    wire [DW-1:0] a_t = fr ? a_mid : a_top, a_b = lr ? a_mid : a_bot;
    wire [DW-1:0] b_t = fr ? b_mid : b_top, b_b = lr ? b_mid : b_bot;
    wire [DW-1:0] n_t = fr ? n_mid : n_top, n_b = lr ? n_mid : n_bot;
    // left/right replicate (centre column is b)
    wire [DW-1:0] l_t = fc ? b_t : a_t, l_m = fc ? b_mid : a_mid, l_b = fc ? b_b : a_b;
    wire [DW-1:0] r_t = lc ? b_t : n_t, r_m = lc ? b_mid : n_mid, r_b = lc ? b_b : n_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col <= 0; last_row_cnt <= 0; flush_left <= 0; warm_cnt <= 0; warm <= 1'b0; ox <= 0; oy <= 0;
            out_valid <= 1'b0; out_sof <= 1'b0; out_eof <= 1'b0; out_fc <= 1'b0; out_lc <= 1'b0; out_fr <= 1'b0; out_lr <= 1'b0;
            {t0, t1, t2, t3, t4, t5, t6, t7, t8} <= {9*DW{1'b0}};
            {a_top, a_mid, a_bot, b_top, b_mid, b_bot} <= {6*DW{1'b0}};
            overrun <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_sof   <= 1'b0;
            out_eof   <= 1'b0;
            if (in_valid && flushing) overrun <= 1'b1;
            if (en) begin
                // ---- column registers shift (new column enters)
                a_top <= b_top; a_mid <= b_mid; a_bot <= b_bot;
                b_top <= n_top; b_mid <= n_mid; b_bot <= n_bot;
                // ---- output for centre column b
                if (warm) begin
                    out_valid <= 1'b1;
                    out_sof   <= fc && fr;
                    out_eof   <= lc && lr;
                    out_fc <= fc; out_lc <= lc; out_fr <= fr; out_lr <= lr;
                    t0 <= l_t; t1 <= b_t; t2 <= r_t;
                    t3 <= l_m; t4 <= b_mid; t5 <= r_m;
                    t6 <= l_b; t7 <= b_b; t8 <= r_b;
                    if (lc) begin
                        ox <= 0;
                        oy <= lr ? {CW{1'b0}} : oy + 1'b1;
                    end else ox <= ox + 1'b1;
                end
                // ---- warm-up: first output after W+1 ticks
                if (!warm) begin
                    warm_cnt <= warm_cnt + 1'b1;
                    if (warm_cnt == W) warm <= 1'b1;
                end
                // ---- input row/column bookkeeping and flush
                if (in_valid) begin
                    if (col == W - 1) last_row_cnt <= (last_row_cnt == H - 1) ? {CW{1'b0}} : last_row_cnt + 1'b1;
                end
                if (last_real) flush_left <= W + 1;
                else if (flushing) flush_left <= flush_left - 1'b1;
                // ---- column pointer
                col <= (flushing && flush_left == 1) ? {CW{1'b0}} : col_next;
                if (flushing && flush_left == 1) begin
                    warm <= 1'b0; warm_cnt <= 0; ox <= 0; oy <= 0;
                end
            end
        end
    end
endmodule
