`timescale 1ns/1ps
// nv_tone.v -- tone-map LUT lookup with a double-buffered table, plus the output-sum statistic (roadmap 5.1, 4.6).
//
// Two 1024 x 8 RAMs. The ACTIVE bank (lut_sel) is read by the pixel path; the controller writes the OTHER bank
// (generation) and reads it back for the slope computation, so a table swap is glitch free: nv_core flips lut_sel
// at the first pixel of a frame, when no pixel of the previous frame is still in flight.
//
//   v = LUT[active][sp]    (Q8.2 index, 0..1023)    out_sum = sum of v over the frame (before sharpening)
//
// Latency: 1 clock (registered RAM read). Controller side: lut_we/lut_waddr/lut_wdata write the shadow bank;
// lut_raddr reads the shadow bank, lut_rdata valid 1 clock later.
module nv_tone (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        lut_sel,          // active bank (0/1), frame constant
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire        in_eof,
    input  wire [9:0]  in_data,
    // controller port (shadow bank)
    input  wire        lut_we,
    input  wire [9:0]  lut_waddr,
    input  wire [7:0]  lut_wdata,
    input  wire [9:0]  lut_raddr,
    output wire [7:0]  lut_rdata,
    // output stream
    output reg         v_valid,
    output reg         v_sof,
    output reg         v_eof,
    output wire [7:0]  v_data,
    output reg  [31:0] out_sum,          // valid with out_sum_valid
    output reg         out_sum_valid
);
    wire [7:0] rd0, rd1;
    wire [9:0] ra0 = (lut_sel == 1'b0) ? in_data : lut_raddr;
    wire [9:0] ra1 = (lut_sel == 1'b1) ? in_data : lut_raddr;
    ram_sdp #(.DW(8), .AW(10), .DEPTH(1024)) bank0 (.clk(clk), .we(lut_we &  lut_sel), .waddr(lut_waddr), .wdata(lut_wdata), .raddr(ra0), .rdata(rd0));
    ram_sdp #(.DW(8), .AW(10), .DEPTH(1024)) bank1 (.clk(clk), .we(lut_we & ~lut_sel), .waddr(lut_waddr), .wdata(lut_wdata), .raddr(ra1), .rdata(rd1));

    assign v_data    = (lut_sel == 1'b0) ? rd0 : rd1;     // pixel path reads the active bank
    assign lut_rdata = (lut_sel == 1'b0) ? rd1 : rd0;     // controller reads the shadow bank

    reg [31:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_valid <= 1'b0; v_sof <= 1'b0; v_eof <= 1'b0; acc <= 32'd0; out_sum <= 32'd0; out_sum_valid <= 1'b0;
        end else begin
            v_valid <= in_valid; v_sof <= in_sof; v_eof <= in_eof;
            out_sum_valid <= 1'b0;
            if (v_valid) begin
                if (v_sof) acc <= {24'd0, v_data};
                else       acc <= acc + {24'd0, v_data};
                if (v_eof) begin
                    out_sum <= (v_sof ? 32'd0 : acc) + {24'd0, v_data};
                    out_sum_valid <= 1'b1;
                end
            end
        end
    end
endmodule
