`timescale 1ns/1ps
// ram_sdp.v -- simple dual-port RAM, one clock, REGISTERED read (checklist 1.1: the only read shape Quartus
// 21.1 maps to M10K). Always its own module, never inline in a generate body.
// Read-during-write at the same address returns the OLD data (nonblocking semantics) -- callers avoid
// depending on it (line buffers read one address ahead of the write).
module ram_sdp #(
    parameter DW    = 8,
    parameter AW    = 10,
    parameter DEPTH = 1024
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    reg [DW-1:0] mem [0:DEPTH-1];

    // simulation only: defined contents instead of X (Quartus ignores this block)
    // synthesis translate_off
    integer i;
    initial for (i = 0; i < DEPTH; i = i + 1) mem[i] = {DW{1'b0}};
    // synthesis translate_on

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
