`timescale 1ns/1ps
// nv_synth_top.v -- synthesis-only wrapper around nv_core (resource / timing / memory-inference checks before the HPS
// system exists, roadmap 5.11). Inputs and outputs are registered so that I/O does not distort the internal timing numbers.
module nv_synth_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soft_reset,
    input  wire [3:0]  ctl,
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire [7:0]  in_data,
    output reg         out_valid,
    output reg         out_sof,
    output reg         out_eof,
    output reg  [7:0]  out_data,
    output reg         ready,
    output reg         err_overrun,
    output reg         err_notready,
    output reg  [15:0] t_lg
);
    reg        i_valid, i_sof, sr;
    reg [7:0]  i_data;
    reg [3:0]  c;
    always @(posedge clk) begin i_valid <= in_valid; i_sof <= in_sof; i_data <= in_data; sr <= soft_reset; c <= ctl; end
    wire o_valid, o_sof, o_eof, rdy, eo, en;
    wire [7:0] o_data;
    wire [15:0] lg;
    nv_core #(.W(640), .H(480), .CW(10), .AW(19), .C_SIG(2942)) core (
        .clk(clk), .rst_n(rst_n), .soft_reset(sr), .en_temporal(c[0]), .en_spatial(c[1]), .en_sharpen(c[2]), .passthru(c[3]),
        .in_valid(i_valid), .in_sof(i_sof), .in_data(i_data),
        .out_valid(o_valid), .out_sof(o_sof), .out_eof(o_eof), .out_data(o_data),
        .ready(rdy), .err_overrun(eo), .err_notready(en), .t_lg(lg));
    always @(posedge clk) begin
        out_valid <= o_valid; out_sof <= o_sof; out_eof <= o_eof; out_data <= o_data;
        ready <= rdy; err_overrun <= eo; err_notready <= en; t_lg <= lg;
    end
endmodule
