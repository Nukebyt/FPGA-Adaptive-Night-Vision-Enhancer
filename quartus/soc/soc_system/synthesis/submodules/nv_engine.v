`timescale 1ns/1ps
// nv_engine.v -- the complete video engine behind the HPS: CSR slave, frame scheduler, input DMA + byte FIFO, nv_core,
// output DMA. One clock domain (the 25 MHz pixel clock) end to end; the only external interfaces are Avalon-MM.
//
//   HPS DDR3 input ring --dma_rd--> fifo_64to8 --scheduler--> nv_core --dma_wr--> HPS DDR3 output ring
//                                                   ^   |
//                         CSR (lightweight bridge) --+---+--> telemetry / status
//
// Scheduler (Architecture decision 9). A timing generator (vga_timing, only used as the frame/line pacer: its sync outputs
// are not connected) defines the frame period (default 800 x 525 clocks = 420,000, 59.5 Hz). At the START of every vertical
// blanking it decides for the NEXT frame: if enabled, the controller is ready and software has queued a frame
// (IN_WR_SEQ != IN_RD_SEQ), the FIFO is flushed and dma_rd is started on slot (IN_RD_SEQ % 4); otherwise the whole frame
// period is skipped (SKIPPED++). During the frame's active pixels one byte per clock is popped from the FIFO. Underrun (FIFO
// empty on a pop) feeds zeros and sets a sticky flag. IN_RD_SEQ increments after the last pixel.
// Output: the core's output stream is written to slot (OUT_SEQ % 4) of the output ring. OUT_SEQ increments when BOTH the
// last word of the frame has been accepted by the memory AND the controller finished the frame's statistics, at which point
// the telemetry registers are snapshotted, so software that sees OUT_SEQ change reads a consistent frame + telemetry pair.
// A frame_reset (CSR) re-initialises the core/controller and zeroes IN_RD_SEQ / OUT_SEQ / IN_WR_SEQ.
module nv_engine #(
    parameter W       = 640,
    parameter H       = 480,
    parameter C_SIG   = 2942,
    parameter H_FP    = 16,
    parameter H_SYNC  = 96,
    parameter H_BP    = 48,
    parameter V_FP    = 10,
    parameter V_SYNC  = 2,
    parameter V_BP    = 33,
    parameter [31:0] BUILD_ID = 32'h4E560001,
    parameter [31:0] CLOCK_HZ = 32'd25000000
) (
    input  wire        clk,
    input  wire        rst_n,
    // CSR slave (lightweight bridge)
    input  wire [7:0]  csr_address,
    input  wire        csr_read,
    input  wire        csr_write,
    input  wire [31:0] csr_writedata,
    output wire [31:0] csr_readdata,
    // input DMA master (64-bit, byte addresses) -> F2H SDRAM port
    output wire [31:0] rd_address,
    output wire        rd_read,
    input  wire        rd_waitrequest,
    input  wire [63:0] rd_readdata,
    input  wire        rd_readdatavalid,
    // output DMA master
    output wire [31:0] wr_address,
    output wire        wr_write,
    output wire [63:0] wr_writedata,
    output wire [7:0]  wr_byteenable,
    input  wire        wr_waitrequest,
    // status for LEDs / HEX
    output wire [15:0] st_lg,
    output wire        st_ready,
    output wire        st_enabled,
    output wire        st_error,
    output wire [31:0] st_frames
);
    localparam NWORDS     = W * H / 8;
    localparam FRAME_CYC  = (W + H_FP + H_SYNC + H_BP) * (H + V_FP + V_SYNC + V_BP);

    // ------------------------------------------------------------------ frame pacer
    wire        t_hs, t_vs, t_de, t_sof, t_vblank;
    wire [10:0] t_x, t_y;
    vga_timing #(.H_ACTIVE(W), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP), .V_ACTIVE(H), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)) u_tim (
        .clk(clk), .rst_n(rst_n), .hs_n(t_hs), .vs_n(t_vs), .de(t_de), .sof(t_sof), .vblank(t_vblank), .x(t_x), .y(t_y));

    // ------------------------------------------------------------------ CSR
    wire        c_enable, c_frame_reset, c_en_t, c_en_s, c_en_h, c_passthru, c_clr;
    wire [31:0] c_in_base, c_out_base, c_in_wr_seq;
    reg  [31:0] in_rd_seq, out_seq, skipped;
    reg         st_overrun, st_notready, st_underrun, st_wr_overflow;
    wire        core_ready, ctrl_busy_w;

    // telemetry snapshot registers
    reg  [15:0] s_lg, s_sigma, s_core, s_kmot;
    reg  [4:0]  s_b, s_lam, s_sharp;
    reg  [8:0]  s_a;
    reg  [11:0] s_thr;
    reg  [7:0]  s_p1, s_p50, s_p99;
    reg  [31:0] s_mean;
    reg  [1:0]  s_flags;

    wire        th_we;
    wire [5:0]  th_addr;
    wire [15:0] th_data;

    nv_csr #(.BUILD_ID(BUILD_ID), .CLOCK_HZ(CLOCK_HZ), .FRAME_CYC(FRAME_CYC)) u_csr (
        .clk(clk), .rst_n(rst_n), .avs_address(csr_address), .avs_read(csr_read), .avs_write(csr_write),
        .avs_writedata(csr_writedata), .avs_readdata(csr_readdata),
        .enable(c_enable), .frame_reset(c_frame_reset), .en_temporal(c_en_t), .en_spatial(c_en_s), .en_sharpen(c_en_h),
        .passthru(c_passthru), .in_base(c_in_base), .out_base(c_out_base), .in_wr_seq(c_in_wr_seq), .clr_sticky(c_clr),
        .ready(core_ready), .ctrl_busy(ctrl_busy_w), .st_overrun(st_overrun), .st_notready(st_notready),
        .st_underrun(st_underrun), .st_wr_overflow(st_wr_overflow), .in_rd_seq(in_rd_seq), .out_seq(out_seq), .skipped(skipped),
        .s_lg(s_lg), .s_sigma(s_sigma), .s_b(s_b), .s_a(s_a), .s_lam(s_lam), .s_sharp(s_sharp), .s_core(s_core), .s_kmot(s_kmot),
        .s_thr(s_thr), .s_p1(s_p1), .s_p50(s_p50), .s_p99(s_p99), .s_mean_q4(s_mean), .s_flags(s_flags),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data));

    // ------------------------------------------------------------------ input path
    wire [9:0]  f_lvl;
    wire [7:0]  f_byte;
    wire        f_empty;
    wire        f_wr_en;
    wire [63:0] f_wr_data;
    reg         f_flush, go, dma_start, pre_start;
    reg  [31:0] dma_base;
    wire        rd_busy, rd_done;
    reg         vb_d;
    wire        vb_rise = t_vblank & ~vb_d;

    fifo_64to8 #(.AW(8)) u_fifo (.clk(clk), .rst_n(rst_n), .flush(f_flush), .wr_en(f_wr_en), .wr_data(f_wr_data), .lvl(f_lvl),
        .rd_en(go & t_de & ~f_empty), .rd_data(f_byte), .empty(f_empty));
    dma_rd #(.NWORDS(NWORDS), .AW(8), .LIMIT(252)) u_rd (.clk(clk), .rst_n(rst_n), .start(dma_start), .base(dma_base), .lvl(f_lvl),
        .busy(rd_busy), .done(rd_done), .fifo_wr_en(f_wr_en), .fifo_wr_data(f_wr_data),
        .m_address(rd_address), .m_read(rd_read), .m_waitrequest(rd_waitrequest), .m_readdata(rd_readdata),
        .m_readdatavalid(rd_readdatavalid));

    wire        in_valid = go & t_de;
    wire        in_sof   = go & t_sof;
    wire [7:0]  in_data  = f_empty ? 8'd0 : f_byte;
    wire        in_last  = in_valid & (t_x == W - 1) & (t_y == H - 1);

    // ------------------------------------------------------------------ core
    wire        o_valid, o_sof, o_eof;
    wire [7:0]  o_data;
    wire        c_err_over, c_err_nr, c_done;
    wire [15:0] t_lg, t_sigma, t_core, t_kmot;
    wire [4:0]  t_b, t_lam, t_sharp;
    wire [8:0]  t_a;
    wire [11:0] t_thr;
    wire [7:0]  t_p1, t_p50, t_p99;
    wire [31:0] t_mean;
    nv_core #(.W(W), .H(H), .C_SIG(C_SIG)) u_core (
        .clk(clk), .rst_n(rst_n), .soft_reset(c_frame_reset), .en_temporal(c_en_t), .en_spatial(c_en_s), .en_sharpen(c_en_h),
        .passthru(c_passthru), .in_valid(in_valid), .in_sof(in_sof), .in_data(in_data),
        .out_valid(o_valid), .out_sof(o_sof), .out_eof(o_eof), .out_data(o_data),
        .ready(core_ready), .err_overrun(c_err_over), .err_notready(c_err_nr),
        .t_lg(t_lg), .t_sigma(t_sigma), .t_b(t_b), .t_a(t_a), .t_lam(t_lam), .t_sharp(t_sharp), .t_core(t_core), .t_kmot(t_kmot),
        .t_thr(t_thr), .t_p1(t_p1), .t_p50(t_p50), .t_p99(t_p99), .t_mean_q4(t_mean),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data), .ctrl_done(c_done));
    assign ctrl_busy_w = ~core_ready;

    // ------------------------------------------------------------------ output path
    wire        w_done, w_ovf;
    dma_wr u_wr (.clk(clk), .rst_n(rst_n), .in_valid(o_valid), .in_sof(o_sof), .in_eof(o_eof), .in_data(o_data),
        .base(c_out_base + {out_seq[1:0], 19'd0}), .frame_done(w_done), .overflow(w_ovf), .clr_overflow(c_clr),
        .m_address(wr_address), .m_write(wr_write), .m_writedata(wr_writedata), .m_byteenable(wr_byteenable),
        .m_waitrequest(wr_waitrequest));

    // ------------------------------------------------------------------ sequencing
    reg wr_seen, ctrl_seen, init_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go <= 1'b0; dma_start <= 1'b0; pre_start <= 1'b0; f_flush <= 1'b0; dma_base <= 32'd0; vb_d <= 1'b0;
            in_rd_seq <= 32'd0; out_seq <= 32'd0; skipped <= 32'd0;
            st_overrun <= 1'b0; st_notready <= 1'b0; st_underrun <= 1'b0; st_wr_overflow <= 1'b0;
            wr_seen <= 1'b0; ctrl_seen <= 1'b0; init_pending <= 1'b1;
            s_lg <= 0; s_sigma <= 0; s_b <= 0; s_a <= 0; s_lam <= 0; s_sharp <= 0; s_core <= 0; s_kmot <= 0; s_thr <= 0;
            s_p1 <= 0; s_p50 <= 0; s_p99 <= 0; s_mean <= 0; s_flags <= 0;
        end else begin
            vb_d      <= t_vblank;
            dma_start <= 1'b0;
            f_flush   <= 1'b0;
            if (c_clr) begin st_overrun <= 1'b0; st_notready <= 1'b0; st_underrun <= 1'b0; st_wr_overflow <= 1'b0; end
            if (c_err_over) st_overrun  <= 1'b1;
            if (c_err_nr)   st_notready <= 1'b1;
            if (w_ovf)      st_wr_overflow <= 1'b1;

            if (c_frame_reset) begin
                go <= 1'b0; pre_start <= 1'b0; in_rd_seq <= 32'd0; out_seq <= 32'd0; wr_seen <= 1'b0; ctrl_seen <= 1'b0; init_pending <= 1'b1;
                f_flush <= 1'b1;
            end else begin
                // ---- decision for the next frame, at the start of vertical blanking
                if (vb_rise) begin
                    if (c_enable && core_ready && (c_in_wr_seq != in_rd_seq)) begin
                        go <= 1'b1; f_flush <= 1'b1; pre_start <= 1'b1;
                        dma_base <= c_in_base + {in_rd_seq[1:0], 19'd0};
                    end else begin
                        go <= 1'b0;
                        if (c_enable && core_ready) skipped <= skipped + 1'b1;
                    end
                end
                if (pre_start && !vb_rise) begin dma_start <= 1'b1; pre_start <= 1'b0; end    // one clock after the flush
                // ---- frame consumed
                if (in_last) in_rd_seq <= in_rd_seq + 1'b1;
                if (in_valid && f_empty) st_underrun <= 1'b1;
                // ---- frame completed: pixels written and statistics final
                if (w_done) wr_seen <= 1'b1;
                if (c_done) begin
                    if (init_pending) init_pending <= 1'b0;
                    else ctrl_seen <= 1'b1;
                end
                if (wr_seen && ctrl_seen) begin
                    wr_seen <= 1'b0; ctrl_seen <= 1'b0;
                    out_seq <= out_seq + 1'b1;
                    s_lg <= t_lg; s_sigma <= t_sigma; s_b <= t_b; s_a <= t_a; s_lam <= t_lam; s_sharp <= t_sharp;
                    s_core <= t_core; s_kmot <= t_kmot; s_thr <= t_thr; s_p1 <= t_p1; s_p50 <= t_p50; s_p99 <= t_p99;
                    s_mean <= t_mean; s_flags <= {st_overrun, st_underrun};
                end
            end
        end
    end

    assign st_lg      = t_lg;
    assign st_ready   = core_ready;
    assign st_enabled = c_enable;
    assign st_error   = st_overrun | st_notready | st_underrun | st_wr_overflow;
    assign st_frames  = out_seq;
endmodule
