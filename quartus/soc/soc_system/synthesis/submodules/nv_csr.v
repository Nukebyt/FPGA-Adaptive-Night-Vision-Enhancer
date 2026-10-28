`timescale 1ns/1ps
// nv_csr.v -- control/status registers (Avalon-MM slave, 32 bit, word addresses, fixed read latency 1, no waitrequest).
// Sits on the HPS lightweight bridge. See docs/csr_map.md for the table (generated from this file's header by hand: keep in sync).
//
//  word  name           access  meaning
//   0    VERSION        RO      build id (checklist: host software refuses a mismatching bitstream)
//   1    CONTROL        RW      [0] enable  [1] frame_reset (write 1: pulse, also zeroes the three sequence counters)
//                               [2] en_temporal [3] en_spatial [4] en_sharpen [5] passthru (reset: enable 0, stages 1)
//   2    STATUS         RO      [0] ready [1] ctrl_busy [8] err_overrun [9] err_notready [10] underrun [11] wr_overflow
//   3    STATUS_CLR     W1C     clears the sticky bits of STATUS
//   4    IN_BASE        RW      physical byte address of the input ring (HPS SDRAM space), 512 KiB slots x 4
//   5    OUT_BASE       RW      physical byte address of the output ring
//   6    IN_WR_SEQ      RW      frames written into the input ring by software (software increments)
//   7    IN_RD_SEQ      RO      frames consumed by the FPGA
//   8    OUT_SEQ        RO      frames completed (pixels written AND statistics final); frame n sits in slot n % 4
//   9    SKIPPED        RO      frame periods with enable set but no new input frame
//  10    CLOCK_HZ       RO      datapath clock frequency
//  11    SCRATCH        RW      bus echo test (checklist 4.6)
//  12    FRAME_CYCLES   RO      clocks per frame period (timing generator)
//  16..30 telemetry (snapshot taken when OUT_SEQ increments): 16 lg_q12, 17 sigma_q8, 18 black, 19 a_q8, 20 lam_q4, 21 sharp_q4,
//         22 core_q4, 23 k_mot, 24 thr, 25 p1, 26 p50, 27 p99, 28 mean_q4, 29 flags (bit0 underrun seen, bit1 overrun seen)
//  64..127 hist64: input histogram of the last frame in 4-grey-level bins (count >> 4), written by the controller scan
module nv_csr #(
    parameter [31:0] BUILD_ID  = 32'h4E560001,
    parameter [31:0] CLOCK_HZ  = 32'd25000000,
    parameter [31:0] FRAME_CYC = 32'd420000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output wire [31:0] avs_readdata,
    // control outputs
    output reg         enable,
    output reg         frame_reset,        // one-clock pulse
    output reg         en_temporal,
    output reg         en_spatial,
    output reg         en_sharpen,
    output reg         passthru,
    output reg  [31:0] in_base,
    output reg  [31:0] out_base,
    output reg  [31:0] in_wr_seq,
    output reg         clr_sticky,         // one-clock pulse
    // status inputs
    input  wire        ready,
    input  wire        ctrl_busy,
    input  wire        st_overrun,
    input  wire        st_notready,
    input  wire        st_underrun,
    input  wire        st_wr_overflow,
    input  wire [31:0] in_rd_seq,
    input  wire [31:0] out_seq,
    input  wire [31:0] skipped,
    // telemetry snapshot inputs (already latched by the engine at the OUT_SEQ increment)
    input  wire [15:0] s_lg,
    input  wire [15:0] s_sigma,
    input  wire [4:0]  s_b,
    input  wire [8:0]  s_a,
    input  wire [4:0]  s_lam,
    input  wire [4:0]  s_sharp,
    input  wire [15:0] s_core,
    input  wire [15:0] s_kmot,
    input  wire [11:0] s_thr,
    input  wire [7:0]  s_p1,
    input  wire [7:0]  s_p50,
    input  wire [7:0]  s_p99,
    input  wire [31:0] s_mean_q4,
    input  wire [1:0]  s_flags,
    // histogram window written by the controller scan
    input  wire        th_we,
    input  wire [5:0]  th_addr,
    input  wire [15:0] th_data
);
    reg [31:0] scratch;
    reg [31:0] reg_q;
    reg        sel_ram_q;
    wire [15:0] hist_rd;
    ram_sdp #(.DW(16), .AW(6), .DEPTH(64)) hist_ram (
        .clk(clk), .we(th_we), .waddr(th_addr), .wdata(th_data), .raddr(avs_address[5:0]), .rdata(hist_rd));

    wire [31:0] status = {20'd0, st_wr_overflow, st_underrun, st_notready, st_overrun, 6'd0, ctrl_busy, ready};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable <= 1'b0; frame_reset <= 1'b0; en_temporal <= 1'b1; en_spatial <= 1'b1; en_sharpen <= 1'b1; passthru <= 1'b0;
            in_base <= 32'd0; out_base <= 32'd0; in_wr_seq <= 32'd0; clr_sticky <= 1'b0; scratch <= 32'd0;
            reg_q <= 32'd0; sel_ram_q <= 1'b0;
        end else begin
            frame_reset <= 1'b0;
            clr_sticky  <= 1'b0;
            if (avs_write) begin
                case (avs_address)
                    8'd1: begin
                        enable <= avs_writedata[0];
                        if (avs_writedata[1]) begin frame_reset <= 1'b1; in_wr_seq <= 32'd0; end
                        en_temporal <= avs_writedata[2]; en_spatial <= avs_writedata[3];
                        en_sharpen <= avs_writedata[4]; passthru <= avs_writedata[5];
                    end
                    8'd3: clr_sticky <= 1'b1;
                    8'd4: in_base <= avs_writedata;
                    8'd5: out_base <= avs_writedata;
                    8'd6: in_wr_seq <= avs_writedata;
                    8'd11: scratch <= avs_writedata;
                    default: ;
                endcase
            end
            // read mux, registered: data appears one clock after avs_read (fixed latency 1)
            sel_ram_q <= (avs_address[7:6] == 2'b01);
            case (avs_address)
                8'd0:  reg_q <= BUILD_ID;
                8'd1:  reg_q <= {26'd0, passthru, en_sharpen, en_spatial, en_temporal, 1'b0, enable};
                8'd2:  reg_q <= status;
                8'd4:  reg_q <= in_base;
                8'd5:  reg_q <= out_base;
                8'd6:  reg_q <= in_wr_seq;
                8'd7:  reg_q <= in_rd_seq;
                8'd8:  reg_q <= out_seq;
                8'd9:  reg_q <= skipped;
                8'd10: reg_q <= CLOCK_HZ;
                8'd11: reg_q <= scratch;
                8'd12: reg_q <= FRAME_CYC;
                8'd16: reg_q <= {16'd0, s_lg};
                8'd17: reg_q <= {16'd0, s_sigma};
                8'd18: reg_q <= {27'd0, s_b};
                8'd19: reg_q <= {23'd0, s_a};
                8'd20: reg_q <= {27'd0, s_lam};
                8'd21: reg_q <= {27'd0, s_sharp};
                8'd22: reg_q <= {16'd0, s_core};
                8'd23: reg_q <= {16'd0, s_kmot};
                8'd24: reg_q <= {20'd0, s_thr};
                8'd25: reg_q <= {24'd0, s_p1};
                8'd26: reg_q <= {24'd0, s_p50};
                8'd27: reg_q <= {24'd0, s_p99};
                8'd28: reg_q <= s_mean_q4;
                8'd29: reg_q <= {30'd0, s_flags};
                default: reg_q <= 32'd0;
            endcase
        end
    end
    assign avs_readdata = sel_ram_q ? {16'd0, hist_rd} : reg_q;
endmodule
