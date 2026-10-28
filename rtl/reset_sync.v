`timescale 1ns/1ps
// reset_sync.v -- asynchronous-assert, synchronous-release reset synchroniser.
// rst_n_in is any async source (KEY0 AND pll_locked in the top level).
// rst_n_out asserts immediately and releases STAGES clocks after rst_n_in releases.
module reset_sync #(
    parameter STAGES = 3
) (
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n_out
);
    reg [STAGES-1:0] sr;
    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) sr <= {STAGES{1'b0}};
        else           sr <= {sr[STAGES-2:0], 1'b1};
    end
    assign rst_n_out = sr[STAGES-1];
endmodule
